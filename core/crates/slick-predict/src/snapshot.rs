//! The versioned snapshot of a learning state.
//!
//! A snapshot is a dump of the derived state plus the number of log records it covers. Startup
//! loads it and replays only the log records after that point. Layout: the magic `VTRS`, a `u32`
//! version, a `u64` record count, the payload, then a CRC-32 of everything before it. Every number
//! is little endian and floats keep their exact bits, so a loaded state equals the saved one.
//!
//! Versions:
//! - 1: the first layout.
//! - 2: each affinity row also stores its band holder and the item of its last credit, two `u32`
//!   after its entries. A version 1 row loads with neither, so its band goes to its strongest entry
//!   as it did before, and rule 4 applies from the next pick on.

use crate::affinity::{Entry, Row as AffinityRow};
use crate::context::{NF, NONE};
use crate::counts::Row as CountRow;
use crate::decay::DecayCounter;
use crate::hash::fnv1a;
use crate::learner::{Learner, LearnerParams};
use crate::zero_query::K;

const MAGIC: &[u8; 4] = b"VTRS";
/// Format version written. Bump it when the layout changes and keep reading the older ones: once
/// the log is compacted, the snapshot is the only copy of the history it covers.
pub const VERSION: u32 = 2;
/// The oldest version `decode` still reads.
pub const OLDEST_VERSION: u32 = 1;

/// Why a snapshot could not be loaded. The caller falls back to a full replay of the log.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SnapshotError {
    /// Not a snapshot, or one from another format version.
    Version,
    /// The checksum does not match.
    Checksum,
    /// The payload ends early or holds impossible values.
    Malformed,
}

const fn crc32_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut c = i as u32;
        let mut k = 0;
        while k < 8 {
            c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
            k += 1;
        }
        table[i] = c;
        i += 1;
    }
    table
}

static CRC32: [u32; 256] = crc32_table();

/// CRC-32 (IEEE), as used by zip and PNG.
fn crc32(bytes: &[u8]) -> u32 {
    let mut c = !0u32;
    for &b in bytes {
        c = CRC32[((c ^ b as u32) & 0xFF) as usize] ^ (c >> 8);
    }
    !c
}

struct Writer(Vec<u8>);

impl Writer {
    fn u8(&mut self, v: u8) {
        self.0.push(v);
    }
    fn u32(&mut self, v: u32) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn u64(&mut self, v: u64) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn f32(&mut self, v: f32) {
        self.u32(v.to_bits());
    }
    fn f64(&mut self, v: f64) {
        self.u64(v.to_bits());
    }
    fn len(&mut self, n: usize) {
        self.u32(n as u32);
    }
}

struct Reader<'a> {
    b: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn take(&mut self, n: usize) -> Result<&[u8], SnapshotError> {
        let end = self.at.checked_add(n).ok_or(SnapshotError::Malformed)?;
        let s = self.b.get(self.at..end).ok_or(SnapshotError::Malformed)?;
        self.at = end;
        Ok(s)
    }
    fn u8(&mut self) -> Result<u8, SnapshotError> {
        Ok(self.take(1)?[0])
    }
    fn u32(&mut self) -> Result<u32, SnapshotError> {
        let s = self.take(4)?;
        Ok(u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
    }
    fn u64(&mut self) -> Result<u64, SnapshotError> {
        let s = self.take(8)?;
        let mut a = [0u8; 8];
        a.copy_from_slice(s);
        Ok(u64::from_le_bytes(a))
    }
    fn f32(&mut self) -> Result<f32, SnapshotError> {
        Ok(f32::from_bits(self.u32()?))
    }
    fn f64(&mut self) -> Result<f64, SnapshotError> {
        Ok(f64::from_bits(self.u64()?))
    }
    /// A length, refused when even one byte per element would not fit in what is left.
    fn len(&mut self) -> Result<usize, SnapshotError> {
        let n = self.u32()? as usize;
        if n > self.b.len() - self.at {
            return Err(SnapshotError::Malformed);
        }
        Ok(n)
    }
    fn id(&mut self, below: usize) -> Result<u32, SnapshotError> {
        let id = self.u32()?;
        if id as usize >= below {
            return Err(SnapshotError::Malformed);
        }
        Ok(id)
    }
    /// An id below `below`, or `NONE`.
    fn id_or_none(&mut self, below: usize) -> Result<u32, SnapshotError> {
        let id = self.u32()?;
        if id != NONE && id as usize >= below {
            return Err(SnapshotError::Malformed);
        }
        Ok(id)
    }
}

/// Serializes `l`, recording that it covers the first `covered` log records.
pub fn encode(l: &Learner, covered: u64) -> Vec<u8> {
    encode_as(l, covered, VERSION)
}

/// Serializes `l` in the layout of `version` (1 or 2). Version 1 drops the band holders; tests use
/// it to check that old snapshots still load.
pub fn encode_as(l: &Learner, covered: u64, version: u32) -> Vec<u8> {
    let mut w = Writer(Vec::with_capacity(64 * 1024));
    w.0.extend_from_slice(MAGIC);
    w.u32(version);
    w.u64(covered);
    w.len(l.keys.len());
    l.keys.iter().for_each(|&k| w.u64(k));
    w.len(l.queries.len());
    for q in &l.queries {
        w.u8(q.len() as u8);
        w.0.extend_from_slice(q.as_bytes());
    }
    match l.prev {
        Some((id, t)) => {
            w.u8(1);
            w.u32(id);
            w.u32(t);
        }
        None => w.u8(0),
    }
    let c = &l.counts;
    for v in [c.events, c.undone, c.forgotten, c.seeds].iter().chain(&c.by_source) {
        w.u64(*v);
    }
    // zero-query model
    let zq = &l.zq;
    zq.w.iter().for_each(|&x| w.f64(x));
    w.f64(zq.n_updates);
    w.len(zq.prior.len());
    for i in 0..zq.prior.len() {
        w.f32(zq.prior[i].l);
        w.f32(zq.short[i].l);
        w.f64(zq.last_used[i]);
        w.f64(zq.first_used[i]);
    }
    w.len(zq.cands.len());
    zq.cands.iter().for_each(|&i| w.u32(i));
    w.f64(zq.cc.t0);
    for table in &zq.cc.tables {
        let mut values: Vec<&u32> = table.keys().collect();
        values.sort_unstable();
        w.len(values.len());
        for v in values {
            let row = &table[v];
            w.u32(*v);
            w.f32(row.total);
            w.len(row.items.len());
            for &(item, count) in &row.items {
                w.u32(item);
                w.f32(count);
            }
        }
    }
    // affinity
    let mut keys: Vec<&u64> = l.affinity.rows.keys().collect();
    keys.sort_unstable();
    w.len(keys.len());
    for k in keys {
        let row = &l.affinity.rows[k];
        w.u64(*k);
        w.u8(row.entries.len() as u8);
        for e in &row.entries {
            w.u32(e.item);
            w.f32(e.w);
            w.f32(e.t);
        }
        if version >= 2 {
            w.u32(row.holder);
            w.u32(row.last);
        }
    }
    // frecency
    w.f64(l.frecency.max_l);
    w.len(l.frecency.counters.len());
    l.frecency.counters.iter().for_each(|c| w.f32(c.l));
    let crc = crc32(&w.0);
    w.u32(crc);
    w.0
}

/// Loads a snapshot. Returns the state and the number of log records it covers.
pub fn decode(bytes: &[u8], p: &LearnerParams) -> Result<(Learner, u64), SnapshotError> {
    if bytes.len() < 20 || &bytes[..4] != MAGIC {
        return Err(SnapshotError::Version);
    }
    let (body, tail) = bytes.split_at(bytes.len() - 4);
    let mut r = Reader { b: body, at: 4 };
    let version = r.u32()?;
    if !(OLDEST_VERSION..=VERSION).contains(&version) {
        return Err(SnapshotError::Version);
    }
    if crc32(body) != u32::from_le_bytes([tail[0], tail[1], tail[2], tail[3]]) {
        return Err(SnapshotError::Checksum);
    }
    let covered = r.u64()?;
    let mut l = Learner::new(p);
    let n = r.len()?;
    for id in 0..n {
        let key = r.u64()?;
        l.keys.push(key);
        if l.ids.insert(key, id as u32).is_some() {
            return Err(SnapshotError::Malformed);
        }
    }
    for id in 0..r.len()? {
        let len = r.u8()? as usize;
        let q = std::str::from_utf8(r.take(len)?).map_err(|_| SnapshotError::Malformed)?;
        // An empty text is a query whose row was forgotten; it is never looked up again.
        if !q.is_empty() {
            l.query_ids.insert(fnv1a(q.as_bytes()), id as u32);
        }
        l.queries.push(q.to_string());
    }
    if r.u8()? == 1 {
        l.prev = Some((r.id(n)?, r.u32()?));
    }
    let c = &mut l.counts;
    c.events = r.u64()?;
    c.undone = r.u64()?;
    c.forgotten = r.u64()?;
    c.seeds = r.u64()?;
    for s in c.by_source.iter_mut() {
        *s = r.u64()?;
    }
    let zq = &mut l.zq;
    for x in zq.w.iter_mut().take(K) {
        *x = r.f64()?;
    }
    zq.n_updates = r.f64()?;
    let items = r.len()?;
    if items > n {
        return Err(SnapshotError::Malformed);
    }
    zq.ensure_items(n);
    for i in 0..items {
        zq.prior[i] = DecayCounter { l: r.f32()? };
        zq.short[i] = DecayCounter { l: r.f32()? };
        zq.last_used[i] = r.f64()?;
        zq.first_used[i] = r.f64()?;
    }
    let cands = (0..r.len()?).map(|_| r.id(n)).collect::<Result<Vec<u32>, _>>()?;
    zq.set_candidates(cands);
    zq.cc.t0 = r.f64()?;
    for table in zq.cc.tables.iter_mut().take(NF) {
        for _ in 0..r.len()? {
            let value = r.u32()?;
            let total = r.f32()?;
            let items = (0..r.len()?)
                .map(|_| Ok((r.id(n)?, r.f32()?)))
                .collect::<Result<Vec<(u32, f32)>, SnapshotError>>()?;
            table.insert(value, CountRow { total, items });
        }
    }
    for _ in 0..r.len()? {
        let key = r.u64()?;
        let entries = (0..r.u8()?)
            .map(|_| {
                Ok(Entry {
                    item: r.id(n)?,
                    w: r.f32()?,
                    t: r.f32()?,
                })
            })
            .collect::<Result<Vec<Entry>, SnapshotError>>()?;
        let (holder, last) = if version >= 2 {
            (r.id_or_none(n)?, r.id_or_none(n)?)
        } else {
            (NONE, NONE)
        };
        l.affinity.rows.insert(key, AffinityRow { entries, holder, last });
    }
    l.frecency.max_l = r.f64()?;
    let counters = r.len()?;
    if counters > n {
        return Err(SnapshotError::Malformed);
    }
    l.frecency.counters = (0..counters)
        .map(|_| Ok(DecayCounter { l: r.f32()? }))
        .collect::<Result<Vec<_>, SnapshotError>>()?;
    if r.at != body.len() {
        return Err(SnapshotError::Malformed);
    }
    Ok((l, covered))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::learner::{Execution, Situation};
    use crate::log::Source;
    use crate::time::EPOCH_UNIX;

    fn learner() -> Learner {
        let mut l = Learner::new(&LearnerParams::default());
        l.seed(99, 0.5, EPOCH_UNIX);
        for k in 0..200u64 {
            l.execute(&Execution {
                key: k % 9,
                query: ["sa", "term", "é"][k as usize % 3],
                source: if k % 5 == 0 { Source::Suggestion } else { Source::Typed },
                rank: 1,
                unix: EPOCH_UNIX + 3_600.0 + k as f64 * 300.0,
                situation: Situation {
                    hour: (k % 24) as u8,
                    weekday: (k % 7) as u8,
                    frontmost: 1_000 + k % 3,
                    flags: (k % 32) as u16,
                },
            });
        }
        l.forget(4);
        l
    }

    #[test]
    fn a_snapshot_round_trips_exactly() {
        let l = learner();
        let bytes = encode(&l, 1_234);
        let (back, covered) = decode(&bytes, &LearnerParams::default()).expect("valid snapshot");
        assert_eq!(covered, 1_234);
        assert_eq!(encode(&back, 1_234), bytes);
        assert_eq!(back.zq.cc, l.zq.cc);
        assert_eq!(back.affinity.rows, l.affinity.rows);
        assert_eq!(back.counts, l.counts);
    }

    #[test]
    fn damage_is_detected_and_never_panics() {
        let bytes = encode(&learner(), 7);
        for cut in [0, 3, 19, bytes.len() / 2, bytes.len() - 1] {
            assert!(decode(&bytes[..cut], &LearnerParams::default()).is_err());
        }
        for at in (0..bytes.len()).step_by(37) {
            let mut b = bytes.clone();
            b[at] ^= 0x40;
            assert!(decode(&b, &LearnerParams::default()).is_err(), "byte {at}");
        }
        for version in [0u8, 3, 0xFF] {
            let mut other = bytes.clone();
            other[4] = version;
            assert_eq!(
                decode(&other, &LearnerParams::default()).err(),
                Some(SnapshotError::Version),
                "version {version}"
            );
        }
    }

    /// A snapshot written before the band holders existed loads with no holders, so each row's
    /// band goes to its strongest entry, as it did when that snapshot was written.
    #[test]
    fn a_version_1_snapshot_still_loads() {
        let l = learner();
        let p = LearnerParams::default();
        let old = encode_as(&l, 77, 1);
        assert!(old.len() < encode(&l, 77).len());
        let (back, covered) = decode(&old, &p).expect("version 1 loads");
        assert_eq!(covered, 77);
        assert_eq!(encode_as(&back, 77, 1), old);
        assert_eq!(back.counts, l.counts);
        assert_eq!(back.zq.cc, l.zq.cc);
        assert_eq!(back.affinity.rows.len(), l.affinity.rows.len());
        let a = &p.affinity;
        let t = (back.affinity.rows.values())
            .flat_map(|r| r.entries.iter().map(|e| e.t as f64))
            .fold(0.0, f64::max);
        let mut banded = 0;
        for (key, row) in &back.affinity.rows {
            assert_eq!(row.entries, l.affinity.rows[key].entries);
            assert_eq!((row.holder, row.last), (NONE, NONE));
            let strongest = row
                .entries
                .iter()
                .map(|e| (e.item, e.w as f64 * (-(t - e.t as f64).max(0.0) / a.half_life).exp2()))
                .fold(None, |top: Option<(u32, f64)>, x| match top {
                    Some(b) if b.1 >= x.1 => Some(b),
                    _ => Some(x),
                })
                .filter(|x| x.1 >= a.band_weight);
            assert_eq!(row.band(a.half_life, a.band_weight, t), strongest);
            banded += strongest.is_some() as usize;
        }
        assert!(banded > 0, "some rows hold a band");
    }
}
