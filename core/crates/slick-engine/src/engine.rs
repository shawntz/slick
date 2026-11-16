//! The engine: the one object the app talks to for root search.

use crate::catalog::{Catalog, Item, flags};
use crate::context::Context;
use crate::index::{Index, top_positions};
use crate::rank::{self, RankParams, TIER_ALIAS_EXACT, TIER_ALIAS_PREFIX, TIER_LEARNED};
use crate::session::{FIELD_NONE, FIELD_USER_ALIAS, Hit, Session, Special, hit_flags, is_band};
use crate::store::Store;
use slick_match::Query;
use slick_predict::affinity;
use slick_predict::context::NONE;
use slick_predict::{Execution, Learner, LearnerParams, Source};
use std::path::Path;
use std::sync::{Arc, Mutex, RwLock, RwLockReadGuard, RwLockWriteGuard};

/// How many suggestions are kept ready.
pub const SUGGESTIONS: usize = 16;

/// Why an engine call failed.
#[derive(Debug)]
pub enum EngineError {
    /// A lock was poisoned by an earlier panic. Rebuild the engine.
    Poisoned,
    /// The data directory could not be opened or read.
    Io(std::io::Error),
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EngineError::Poisoned => write!(f, "a lock was poisoned by an earlier panic"),
            EngineError::Io(e) => write!(f, "data directory: {e}"),
        }
    }
}

impl std::error::Error for EngineError {}

/// Constants of ranking and learning.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct EngineParams {
    /// The ranking formula.
    pub rank: RankParams,
    /// The learning components.
    pub learner: LearnerParams,
    /// When the store writes snapshots and compacts the log.
    pub store: StoreParams,
}

/// When the store writes snapshots and compacts the log. Both happen on the store's thread.
#[derive(Clone, Debug, PartialEq)]
pub struct StoreParams {
    /// A snapshot is written after this many logged executions.
    pub snapshot_every: u64,
    /// The log is compacted once the previous snapshot covers this many records past the log's
    /// start. The log then stays under about this many records plus two snapshot intervals: 512 KB
    /// at the default.
    pub compact_after: u64,
}

impl Default for StoreParams {
    fn default() -> Self {
        StoreParams {
            snapshot_every: 500,
            compact_after: 16_384,
        }
    }
}

/// A user alias: typing it ranks its item first.
#[derive(Clone, Debug)]
pub(crate) struct UserAlias {
    pub(crate) folded: String,
    pub(crate) text: String,
    pub(crate) key: u64,
}

/// Everything a query reads, behind one lock.
pub(crate) struct State {
    pub(crate) index: Arc<Index>,
    pub(crate) learner: Learner,
    pub(crate) context: Context,
    pub(crate) aliases: Vec<UserAlias>,
    /// Within-tier lift per index position: static prior plus learned frecency and context.
    pub(crate) lifts: Vec<i32>,
    /// The positions with the largest lifts, which a query visits first.
    pub(crate) seeds: Vec<u32>,
    seed_scratch: Vec<(i32, u32)>,
    /// Index position per learn id (`NONE` when the item is not in the catalog).
    pos_of_id: Vec<u32>,
    pos_of_id_generation: u64,
    /// Zero-query probability relative to the most likely item, per learn id.
    ctx_prior: Vec<f32>,
    pub(crate) suggestions: Vec<(u64, f32)>,
    pub(crate) paused: bool,
    since_snapshot: u64,
    scratch: Vec<(u32, f64)>,
}

impl State {
    pub(crate) fn new(learner: Learner) -> State {
        let index = Arc::new(Index::build([], |_| 0));
        State {
            index,
            learner,
            context: Context::default(),
            aliases: Vec::new(),
            lifts: Vec::new(),
            seeds: Vec::new(),
            seed_scratch: Vec::new(),
            pos_of_id: Vec::new(),
            pos_of_id_generation: 0,
            ctx_prior: Vec::new(),
            suggestions: Vec::new(),
            paused: false,
            since_snapshot: 0,
            scratch: Vec::new(),
        }
    }

    fn position_of_id(&self, id: u32) -> Option<u32> {
        self.pos_of_id.get(id as usize).copied().filter(|&p| p != NONE)
    }

    /// Recomputes everything derived from the index, the learner and the context: the zero-query
    /// scores, the suggestions, the context prior and the lifts.
    fn refresh(&mut self, p: &RankParams) {
        let ix = Arc::clone(&self.index);
        if self.pos_of_id_generation != ix.generation || self.pos_of_id.len() > self.learner.len() {
            self.pos_of_id.clear();
            self.pos_of_id_generation = ix.generation;
        }
        // New learn ids only append, so only they need a lookup.
        for id in self.pos_of_id.len() as u32..self.learner.len() as u32 {
            self.pos_of_id
                .push(ix.position(self.learner.key_of(id)).unwrap_or(NONE));
        }
        let ctx = self.zero_query_context();
        self.learner.zq.compute(&ctx);
        let front = self.context.frontmost;
        let pos_of_id = &self.pos_of_id;
        let learner = &self.learner;
        let suggestible = |id: u32| {
            pos_of_id.get(id as usize).is_some_and(|&p| {
                p != NONE && ix.keys[p as usize] != front && ix.flags[p as usize] & flags::NO_SUGGEST == 0
            })
        };
        learner.zq.top(SUGGESTIONS, suggestible, &mut self.scratch);
        self.suggestions.clear();
        for &(id, score) in &self.scratch {
            self.suggestions.push((learner.key_of(id), score as f32));
        }
        let rankable = |id: u32| learner.key_of(id) != front;
        let pmax = learner.zq.probabilities(rankable, &mut self.scratch);
        self.ctx_prior.clear();
        self.ctx_prior.resize(learner.len(), 0.0);
        if pmax > 0.0 {
            for &(id, prob) in &self.scratch {
                self.ctx_prior[id as usize] = (prob / pmax) as f32;
            }
        }
        self.lifts.clear();
        self.lifts.extend_from_slice(&ix.static_lift);
        for (id, &pos) in self.pos_of_id.iter().enumerate() {
            if pos != NONE {
                let learned = p.learned_lift(learner.frecency.score(id as u32), self.ctx_prior[id] as f64);
                self.lifts[pos as usize] += learned;
            }
        }
        // Only learned items gain lift over their static one, so the largest lifts are among them
        // and the index's static seeds.
        let learned = self.pos_of_id.iter().copied().filter(|&p| p != NONE);
        top_positions(
            &self.lifts,
            learned.chain(ix.static_seeds.iter().copied()),
            &mut self.seed_scratch,
            &mut self.seeds,
        );
    }

    /// The model context for predictions now. A previous item from the app overrides the
    /// engine's own record.
    fn zero_query_context(&self) -> slick_predict::context::Ctx {
        let c = &self.context;
        let mut ctx = self.learner.context(c.now, &c.situation());
        if c.previous != 0 {
            ctx.prev = self.learner.id_of(c.previous).unwrap_or(NONE);
            ctx.since_prev = if c.since_previous.is_finite() {
                (c.since_previous / 60.0).max(0.0)
            } else {
                f64::INFINITY
            };
        }
        ctx
    }

    /// Minutes since the epoch at the current context time.
    fn now_minutes(&self) -> f64 {
        slick_predict::time::minutes(slick_predict::time::log_seconds(self.context.now))
    }
}

/// The root search engine: a catalog, the learning state, user aliases and persistence.
///
/// Every method takes `&self` and is safe to call from any thread. Queries take a read lock;
/// catalog changes, context changes and learning take the write lock briefly. File writes happen
/// on the store's own thread.
pub struct Engine {
    params: EngineParams,
    catalog: Mutex<Catalog>,
    state: Arc<RwLock<State>>,
    store: Option<Store>,
}

impl Engine {
    /// An engine that keeps everything in memory.
    pub fn in_memory(params: EngineParams) -> Engine {
        let state = State::new(Learner::new(&params.learner));
        Engine::with_state(params, state, None)
    }

    /// An engine that persists its learning under `dir`, which is created when missing. A corrupt
    /// log tail is truncated and an unreadable snapshot ignored; neither is an error. A directory
    /// that another open engine owns, in this process or another, is an `Io` error.
    pub fn open(dir: &Path, params: EngineParams) -> Result<Engine, EngineError> {
        let recovered = crate::store::recover(dir, &params.learner).map_err(EngineError::Io)?;
        let state = State::new(recovered.learner.clone());
        let state = Arc::new(RwLock::new(state));
        let store = Store::start(dir, recovered, &params);
        let engine = Engine {
            params,
            catalog: Mutex::new(Catalog::default()),
            state,
            store: Some(store),
        };
        engine.write()?.refresh(&engine.params.rank);
        Ok(engine)
    }

    fn with_state(params: EngineParams, state: State, store: Option<Store>) -> Engine {
        let engine = Engine {
            params,
            catalog: Mutex::new(Catalog::default()),
            state: Arc::new(RwLock::new(state)),
            store,
        };
        if let Ok(mut st) = engine.state.write() {
            st.refresh(&engine.params.rank);
        }
        engine
    }

    /// The constants this engine ranks and learns with.
    pub fn params(&self) -> &EngineParams {
        &self.params
    }

    fn read(&self) -> Result<RwLockReadGuard<'_, State>, EngineError> {
        self.state.read().map_err(|_| EngineError::Poisoned)
    }

    fn write(&self) -> Result<RwLockWriteGuard<'_, State>, EngineError> {
        self.state.write().map_err(|_| EngineError::Poisoned)
    }

    fn log(&self, records: Vec<[u8; 32]>) {
        if records.is_empty() {
            return;
        }
        if let Some(store) = &self.store {
            store.append(records);
        }
    }

    // ---- catalog

    /// Applies `change` to the catalog and swaps in a new index built from it.
    fn change_catalog(&self, change: impl FnOnce(&mut Catalog)) -> Result<(), EngineError> {
        let mut catalog = self.catalog.lock().map_err(|_| EngineError::Poisoned)?;
        change(&mut catalog);
        let p = &self.params.rank;
        let index = Arc::new(Index::build(catalog.items(), |i| p.static_lift(i.kind, i.prior)));
        let mut st = self.write()?;
        st.index = index;
        st.refresh(p);
        Ok(())
    }

    /// Replaces every item of `source`.
    pub fn replace_source(&self, source: u32, items: Vec<Item>) -> Result<(), EngineError> {
        self.change_catalog(|c| c.replace_source(source, items))
    }

    /// Adds or replaces one item of `source`.
    pub fn upsert(&self, source: u32, item: Item) -> Result<(), EngineError> {
        self.change_catalog(|c| c.upsert(source, item))
    }

    /// Removes the item with `key` from the catalog. Its learning is kept.
    pub fn remove(&self, key: u64) -> Result<(), EngineError> {
        self.change_catalog(|c| {
            c.remove(key);
        })
    }

    /// Number of items in the catalog.
    pub fn len(&self) -> Result<usize, EngineError> {
        Ok(self.read()?.index.len())
    }

    /// True when the catalog is empty.
    pub fn is_empty(&self) -> Result<bool, EngineError> {
        Ok(self.len()? == 0)
    }

    // ---- user aliases

    /// Sets the user alias of `key`; an empty alias removes it. Aliases are not persisted: the app
    /// sets them at launch from its settings.
    pub fn set_alias(&self, key: u64, alias: &str) -> Result<(), EngineError> {
        let folded = Query::new(alias).full;
        let folded = String::from_utf8(folded).unwrap_or_default();
        let mut st = self.write()?;
        st.aliases.retain(|a| a.key != key);
        if !folded.is_empty() {
            st.aliases.push(UserAlias {
                folded,
                text: alias.trim().to_string(),
                key,
            });
        }
        Ok(())
    }

    // ---- context

    /// Sets the context and recomputes the suggestions and the context prior.
    pub fn set_context(&self, context: Context) -> Result<(), EngineError> {
        let mut st = self.write()?;
        st.context = context;
        st.refresh(&self.params.rank);
        Ok(())
    }

    // ---- queries

    /// Ranks the catalog for `text` and returns the best `k` hits. The session narrows from its
    /// previous query, so typing one more character rescans only the previous matches.
    pub fn query<'s>(&self, session: &'s mut Session, text: &str, k: usize) -> Result<&'s [Hit], EngineError> {
        let st = self.read()?;
        let ix = &*st.index;
        // Root search ranks a query equal to a whole later word with literal prefixes.
        session.begin(ix, text, true);
        if session.query.is_empty() || k == 0 {
            return Ok(&session.hits);
        }
        let p = &self.params.rank;
        // Rule 1: user aliases, exact or by prefix.
        let q = std::str::from_utf8(&session.query.full).unwrap_or("");
        for a in &st.aliases {
            if let Some(rest) = a.folded.strip_prefix(q)
                && let Some(pos) = ix.position(a.key)
            {
                let exact = rest.is_empty();
                let rank = rank::alias_band(exact, rest.chars().count(), st.lifts[pos as usize]);
                let tier = if exact { TIER_ALIAS_EXACT } else { TIER_ALIAS_PREFIX };
                Session::add_special(
                    &mut session.specials,
                    Special::Fixed {
                        pos,
                        rank,
                        tier,
                        field: FIELD_USER_ALIAS,
                        flags: hit_flags::ALIAS,
                    },
                );
            }
        }
        // Rules 2, 3 and 4: the affinity row for exactly this query. The row's band holder takes
        // the learned band; every other entry gets the affinity lift.
        let key = affinity::truncate(q, st.learner.affinity.p.max_query_bytes);
        let row = st.learner.affinity.summary(key.as_bytes(), st.now_minutes());
        for &(id, w) in row.entries() {
            let Some(pos) = st.position_of_id(id) else { continue };
            if row.band.is_some_and(|(holder, _)| holder == id) {
                Session::add_special(
                    &mut session.specials,
                    Special::Fixed {
                        pos,
                        rank: rank::learned_band(st.lifts[pos as usize]),
                        tier: TIER_LEARNED,
                        field: FIELD_NONE,
                        flags: hit_flags::LEARNED,
                    },
                );
            } else {
                let lift = p.affinity_lift(w, row.total);
                if lift > 0 {
                    Session::add_special(&mut session.specials, Special::Affinity { pos, lift });
                }
            }
        }
        session.run(ix, k, Some(&st.lifts), &st.seeds);
        Ok(&session.hits)
    }

    /// Highlight ranges of `key`'s title for the session's last query, as UTF-16 (start, length)
    /// pairs. Empty when the title does not match (the hit came from an alias or keyword).
    pub fn ranges<'s>(&self, session: &'s mut Session, key: u64) -> Result<&'s [(u32, u32)], EngineError> {
        let st = self.read()?;
        session.ranges.clear();
        let ix = &*st.index;
        match ix.position(key) {
            Some(pos) if session.target == ix.generation => Ok(session.title_ranges(ix, pos)),
            _ => Ok(&session.ranges),
        }
    }

    /// The inline completion for the session's top hit: the rest of its title or alias after
    /// what was typed. `None` unless the top hit is decisive (a band, or ahead of the second hit
    /// by the completion margin) and its text literally starts with the query.
    pub fn completion<'s>(&self, session: &'s mut Session) -> Result<Option<(u64, &'s str)>, EngineError> {
        let st = self.read()?;
        let Some(&top) = session.hits.first() else {
            return Ok(None);
        };
        let decisive = is_band(&top)
            || session
                .hits
                .get(1)
                .is_none_or(|second| top.rank - second.rank >= self.params.rank.completion_margin);
        let ix = &*st.index;
        if !decisive || session.target != ix.generation {
            return Ok(None);
        }
        let completes = if top.field == FIELD_USER_ALIAS {
            let alias = st.aliases.iter().find(|a| a.key == top.key).map(|a| a.text.as_str());
            alias.is_some_and(|a| session.complete_with(a))
        } else {
            let entries = ix.arena.entry_range(top.pos as usize);
            entries
                .filter(|&e| ix.arena.field(e) != slick_match::Field::Keyword)
                .any(|e| session.complete_with(ix.entry_text(e)))
        };
        Ok(completes.then_some((top.key, session.completion.as_str())))
    }

    // ---- suggestions

    /// The zero-query suggestions for the current context, best first, as (key, score). They are
    /// computed when the context or the learning changes, so this only copies.
    pub fn suggestions(&self, out: &mut Vec<(u64, f32)>) -> Result<(), EngineError> {
        let st = self.read()?;
        out.clear();
        out.extend_from_slice(&st.suggestions);
        Ok(())
    }

    // ---- learning

    /// Learns that `key` ran after typing `query` (the raw text in the field), reached by
    /// `source`, at Unix time `now`. Returns false when nothing was learned: learning is paused or
    /// the item opts out.
    pub fn record(&self, key: u64, query: &str, source: Source, rank: u8, now: f64) -> Result<bool, EngineError> {
        let folded = String::from_utf8(Query::new(query).full).unwrap_or_default();
        let mut st = self.write()?;
        let opted_out = st
            .index
            .position(key)
            .is_some_and(|p| st.index.flags[p as usize] & flags::NO_LEARN != 0);
        if st.paused || opted_out {
            return Ok(false);
        }
        let situation = st.context.situation();
        let records = st.learner.execute(&Execution {
            key,
            query: &folded,
            source,
            rank,
            unix: now,
            situation,
        });
        self.log(records);
        st.since_snapshot += 1;
        if st.since_snapshot >= self.params.store.snapshot_every {
            st.since_snapshot = 0;
            if let Some(store) = &self.store {
                store.snapshot();
            }
        }
        st.refresh(&self.params.rank);
        Ok(true)
    }

    /// Removes the learning of the last execution when it was `key` and ran at most five seconds
    /// before `now`. Returns whether anything was undone.
    pub fn undo(&self, key: u64, now: f64) -> Result<bool, EngineError> {
        let mut st = self.write()?;
        let Some(records) = st.learner.undo(key, now) else {
            return Ok(false);
        };
        self.log(records);
        st.refresh(&self.params.rank);
        Ok(true)
    }

    /// Forgets everything learned about `key`.
    pub fn forget(&self, key: u64) -> Result<(), EngineError> {
        let mut st = self.write()?;
        let records = st.learner.forget(key);
        self.log(records);
        st.refresh(&self.params.rank);
        Ok(())
    }

    /// Forgets the learned row of one query (the raw text, folded here), so typing it ranks by
    /// text again. The rows of shorter queries it is a prefix of keep their credit. Returns
    /// whether the query had a row.
    ///
    /// The learner drops the forgotten query's text. A shorter row that only that text named, such
    /// as "ter" after forgetting "term", gets its own text back through a logged query definition,
    /// so the inspector can still list and forget it.
    pub fn forget_query(&self, query: &str) -> Result<bool, EngineError> {
        let folded = String::from_utf8(Query::new(query).full).unwrap_or_default();
        let mut st = self.write()?;
        let before: Vec<String> = st.learner.queries().to_vec();
        let mut records = st.learner.forget_query(&folded);
        if records.is_empty() {
            return Ok(false);
        }
        records.extend(crate::stats::rename_orphan_rows(&mut st.learner, &before));
        self.log(records);
        st.refresh(&self.params.rank);
        Ok(true)
    }

    /// The headline numbers of the learning inspector.
    pub fn summary(&self) -> Result<crate::stats::Summary, EngineError> {
        Ok(crate::stats::summary(&self.read()?.learner))
    }

    /// A first-run seed: a light virtual use of `key` at Unix time `at`.
    pub fn seed(&self, key: u64, weight: f32, at: f64) -> Result<(), EngineError> {
        let mut st = self.write()?;
        let records = st.learner.seed(key, weight, at);
        self.log(records);
        st.refresh(&self.params.rank);
        Ok(())
    }

    /// Pauses or resumes learning. While paused, executions are neither learned nor logged.
    pub fn set_learning_paused(&self, paused: bool) -> Result<(), EngineError> {
        self.write()?.paused = paused;
        Ok(())
    }

    /// Erases all learning, in memory and on disk.
    pub fn reset_learning(&self) -> Result<(), EngineError> {
        let mut st = self.write()?;
        st.learner = Learner::new(&self.params.learner);
        st.since_snapshot = 0;
        if let Some(store) = &self.store {
            store.reset();
        }
        st.refresh(&self.params.rank);
        Ok(())
    }

    /// Waits until every log record so far is on disk.
    pub fn flush(&self) {
        if let Some(store) = &self.store {
            store.flush();
        }
    }

    /// Learning statistics as JSON, for the settings inspector.
    pub fn stats_json(&self) -> Result<String, EngineError> {
        // Lock order is catalog, then state (see `change_catalog`). Taking them the other way
        // round deadlocks against a catalog change, so the catalog lock is released first.
        let catalog_sources = self.catalog.lock().map_err(|_| EngineError::Poisoned)?.sources();
        let st = self.read()?;
        let io_errors = self.store.as_ref().map_or(0, Store::errors);
        Ok(crate::stats::render(&st, catalog_sources, io_errors))
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        if let Some(store) = self.store.take() {
            store.close();
        }
    }
}
