//! Incremental updates from FSEvents.
//!
//! The caller feeds the paths and flags of an FSEvents batch. Each path becomes a rescan of one
//! folder's listing, compared by name against what the index holds:
//!
//! - a path the index holds: its parent folder is listed again, which catches a create, a delete,
//!   a rename, a metadata change and a kind change; a folder is also listed itself, which covers
//!   folder-level streams;
//! - a path the index does not hold: the deepest folder it does hold is listed again, so a new
//!   folder, or a moved subtree, is found and walked in full;
//! - `MustScanSubDirs` rescans the whole subtree below the path;
//! - `UserDropped`, `KernelDropped` and `EventIdsWrapped` mean history was lost: every root is
//!   walked again from scratch;
//! - paths below a skipped name, a hidden name or a package, and paths outside the roots, are
//!   ignored before any disk access;
//! - a root kept inside another root, below a folder that root skips, is listed again when an
//!   event above it inside the outer root creates, removes or renames something, and rescanned
//!   whole with `MustScanSubDirs`, because the event may have moved it.

use crate::cancel::Cancel;
use crate::rules::{Compiled, Route};
use crate::store::{EntryId, NONE, NewEntry, Snapshot, flags};
use crate::walk::{self, ListError, Method, Scratch};
use std::collections::HashMap;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::time::Duration;

/// FSEvents flags (`kFSEventStreamEventFlag…`) that the index reads.
pub mod event_flags {
    pub const MUST_SCAN_SUB_DIRS: u32 = 0x0000_0001;
    pub const USER_DROPPED: u32 = 0x0000_0002;
    pub const KERNEL_DROPPED: u32 = 0x0000_0004;
    pub const EVENT_IDS_WRAPPED: u32 = 0x0000_0008;
    pub const HISTORY_DONE: u32 = 0x0000_0010;
    pub const ROOT_CHANGED: u32 = 0x0000_0020;
    pub const MOUNT: u32 = 0x0000_0040;
    pub const UNMOUNT: u32 = 0x0000_0080;
    pub const ITEM_CREATED: u32 = 0x0000_0100;
    pub const ITEM_REMOVED: u32 = 0x0000_0200;
    pub const ITEM_RENAMED: u32 = 0x0000_0800;
    pub const ITEM_MODIFIED: u32 = 0x0000_1000;
    pub const ITEM_IS_FILE: u32 = 0x0001_0000;
    pub const ITEM_IS_DIR: u32 = 0x0002_0000;
    pub const ITEM_IS_SYMLINK: u32 = 0x0004_0000;
    /// Any of these means events were lost.
    pub const HISTORY_LOST: u32 = USER_DROPPED | KERNEL_DROPPED | EVENT_IDS_WRAPPED;
}

/// One FSEvents event: an absolute path and its flags.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Event {
    pub path: Vec<u8>,
    pub flags: u32,
}

impl Event {
    pub fn new(path: impl AsRef<Path>, flags: u32) -> Event {
        Event {
            path: path.as_ref().as_os_str().as_bytes().to_vec(),
            flags,
        }
    }
}

/// What one batch of events did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct UpdateStats {
    pub events: usize,
    /// Events that could not change the index.
    pub ignored: usize,
    /// Folders listed again.
    pub rescans: usize,
    /// Every root was walked again.
    pub full: bool,
    pub added: usize,
    pub removed: usize,
    pub changed: usize,
    /// The writer published a new snapshot.
    pub published: bool,
    pub elapsed: Duration,
}

/// What the writer will rescan.
#[derive(Debug, Default)]
pub(crate) struct Targets {
    pub(crate) full: bool,
    /// Folder or entry, and whether to rescan its whole subtree.
    pub(crate) list: Vec<(EntryId, bool)>,
}

fn trim(p: &[u8]) -> &[u8] {
    let mut end = p.len();
    while end > 1 && p[end - 1] == b'/' {
        end -= 1;
    }
    &p[..end]
}

/// Turns events into rescan targets.
pub(crate) fn targets(w: &Snapshot, rules: &Compiled, events: &[Event], stats: &mut UpdateStats) -> Targets {
    let mut t = Targets::default();
    let mut deep: HashMap<EntryId, bool> = HashMap::new();
    for ev in events {
        stats.events += 1;
        if ev.flags & event_flags::HISTORY_LOST != 0 {
            t.full = true;
            return t;
        }
        let path = trim(&ev.path);
        if path.is_empty() || ev.flags & !event_flags::HISTORY_DONE == 0 && ev.flags != 0 {
            stats.ignored += 1;
            continue;
        }
        let root = w
            .roots
            .iter()
            .filter(|r| {
                let rp = trim(&r.path);
                path.starts_with(rp) && (path.len() == rp.len() || path[rp.len()] == b'/' || rp == b"/")
            })
            .max_by_key(|r| r.path.len());
        let Some(root) = root else {
            // A path above a root: the root itself may have moved or vanished.
            let mut hit = false;
            for r in w.roots.iter() {
                let rp = trim(&r.path);
                if rp.starts_with(path) && rp.get(path.len()) == Some(&b'/') {
                    *deep.entry(r.id).or_default() = true;
                    hit = true;
                }
            }
            if !hit {
                stats.ignored += 1;
            }
            continue;
        };
        let sub = ev.flags & (event_flags::MUST_SCAN_SUB_DIRS | event_flags::ROOT_CHANGED) != 0;
        let structural = ev.flags == 0
            || ev.flags & (event_flags::ITEM_CREATED | event_flags::ITEM_REMOVED | event_flags::ITEM_RENAMED) != 0;
        let mut nested = false;
        if (sub || structural) && w.roots.len() > 1 {
            // Roots nested below this path: the outer root's walk never reaches them.
            for r in w.roots.iter() {
                let rp = trim(&r.path);
                if rp.len() > path.len() && rp.starts_with(path) && (rp[path.len()] == b'/' || path == b"/") {
                    *deep.entry(r.id).or_default() |= sub;
                    nested = true;
                }
            }
        }
        match rules.route(&root.path, path) {
            Route::Index => {}
            Route::Ignore => {
                stats.ignored += usize::from(!nested);
                continue;
            }
            Route::Refresh(n) => {
                // A skipped name or a package's direct child came or went: refresh the time of
                // the entry that holds it. Content edits of such files change nothing indexed.
                match w.lookup(&path[..n]) {
                    Some((id, true)) if structural => {
                        deep.entry(id).or_default();
                    }
                    _ => stats.ignored += 1,
                }
                continue;
            }
        }
        let Some((id, exact)) = w.lookup(path) else {
            stats.ignored += 1;
            continue;
        };
        if exact {
            let parent = w.parent_of(id);
            if parent != NONE {
                deep.entry(parent).or_default();
            }
            let f = w.flags_of(id);
            if f & flags::DIR != 0 && f & flags::PACKAGE == 0 || parent == NONE {
                *deep.entry(id).or_default() |= sub;
            }
        } else {
            *deep.entry(id).or_default() |= sub;
        }
    }
    // Drop targets below a subtree rescan.
    let mut list: Vec<(EntryId, bool)> = deep.iter().map(|(&k, &v)| (k, v)).collect();
    list.sort_unstable();
    list.retain(|&(id, _)| {
        let mut cur = w.parent_of(id);
        let mut guard = 0;
        while cur != NONE && guard <= crate::store::MAX_DEPTH {
            if deep.get(&cur) == Some(&true) {
                return false;
            }
            cur = w.parent_of(cur);
            guard += 1;
        }
        true
    });
    t.list = list;
    t
}

/// Rescans `dir`, a folder or an entry whose parent is then rescanned, and with `subtree`
/// every folder below it. Checks `stop` before each folder it lists and returns true when it
/// stopped early, leaving `w` half updated; the caller then drops `w`.
#[allow(clippy::too_many_arguments)]
pub(crate) fn rescan(
    w: &mut Snapshot,
    dir: EntryId,
    subtree: bool,
    rules: &Compiled,
    root_dev: &dyn Fn(&Snapshot, EntryId) -> u64,
    s: &mut Scratch,
    stats: &mut UpdateStats,
    stop: &Cancel,
) -> bool {
    let mut work = vec![(dir, subtree)];
    let mut olds: Vec<EntryId> = Vec::new();
    let mut kids: Vec<EntryId> = Vec::new();
    let mut path = Vec::new();
    let mut guard = w.slots() * 2 + 16;
    while let Some((d, deep)) = work.pop() {
        guard = guard.saturating_sub(1);
        if guard == 0 {
            break;
        }
        let Some(info) = w.entry(d) else { continue };
        let (info_flags, info_parent, info_depth, dot_name) =
            (info.flags, info.parent, info.depth, info.name.first() == Some(&b'.'));
        let is_root = info_flags & flags::ROOT != 0;
        if info_flags & flags::DIR == 0 || (info_flags & flags::PACKAGE != 0 && !is_root) {
            if info_parent != NONE {
                work.push((info_parent, false));
            }
            continue;
        }
        path.clear();
        if !w.path_into(d, &mut path) {
            continue;
        }
        if stop.check() {
            return true;
        }
        stats.rescans += 1;
        let dev = root_dev(w, d);
        let listed = walk::list_dir(&path, rules, Method::Bulk, s);
        let (meta, listing) = match listed {
            Ok(x) => x,
            Err(ListError::Gone) | Err(ListError::NotDir) => {
                if is_root {
                    clear_children(w, d, stats);
                    mark_unreadable(w, d, stats);
                } else {
                    work.push((info_parent, false));
                }
                continue;
            }
            Err(_) => {
                clear_children(w, d, stats);
                mark_unreadable(w, d, stats);
                continue;
            }
        };
        // The folder's own facts, as its parent's listing would report them.
        let hidden = if is_root {
            info_flags & flags::HIDDEN
        } else if dot_name || meta.hidden_flag {
            flags::HIDDEN
        } else {
            0
        };
        let own = (info_flags & !(flags::HIDDEN | flags::UNREADABLE)) | hidden;
        let before = w.entry(d).map(|e| (e.flags, e.mtime));
        w.set_meta(d, own, meta.mtime, 0);
        if w.entry(d).map(|e| (e.flags, e.mtime)) != before {
            stats.changed += 1;
        }
        if rules.one_filesystem && dev != 0 && meta.dev != dev {
            clear_children(w, d, stats);
            continue;
        }
        if listing.unreadable {
            mark_unreadable(w, d, stats);
        }
        let depth = info_depth as usize;
        olds.clear();
        olds.extend(w.children(d));
        olds.sort_by(|&a, &b| w.name_of(a).cmp(w.name_of(b)));
        kids.clear();
        let mut oi = 0;
        for i in 0..listing.items.len() {
            let name = listing.name(i);
            let item = listing.items[i];
            while oi < olds.len() && w.name_of(olds[oi]) < name {
                remove(w, olds[oi], stats);
                oi += 1;
            }
            if oi < olds.len() && w.name_of(olds[oi]) == name {
                let id = olds[oi];
                oi += 1;
                let old = w.flags_of(id);
                const KIND: u8 = flags::DIR | flags::PACKAGE | flags::SYMLINK;
                if old & KIND == item.flags & KIND {
                    let changed = w.entry(id).is_some_and(|e| {
                        e.mtime != item.mtime
                            || e.flags & flags::HIDDEN != item.flags & flags::HIDDEN
                            || (item.flags & flags::DIR == 0
                                && e.size != Some(crate::store::decode_size(crate::store::encode_size(item.size))))
                    });
                    if changed {
                        let keep = old & (flags::UNREADABLE | flags::ROOT);
                        w.set_meta(id, (item.flags & flags::PUBLIC) | keep, item.mtime, item.size);
                        stats.changed += 1;
                    }
                    kids.push(id);
                    if deep && item.flags & KIND == flags::DIR {
                        work.push((id, true));
                    }
                    continue;
                }
                remove(w, id, stats);
            }
            let id = w.push(NewEntry {
                parent: d,
                name,
                flags: item.flags,
                mtime: item.mtime,
                size: item.size,
            });
            stats.added += 1;
            kids.push(id);
            if item.flags & (flags::DIR | flags::PACKAGE | flags::SYMLINK) == flags::DIR
                && depth + 1 < crate::store::MAX_DEPTH
            {
                let mut child = path.clone();
                if child.last() != Some(&b'/') {
                    child.push(b'/');
                }
                child.extend_from_slice(name);
                match walk::walk(&child, depth + 1, rules, 1, Method::Bulk, Some(dev), stop) {
                    Ok(tree) => stats.added += walk::graft(w, id, &tree),
                    Err(ListError::Cancelled) => return true,
                    Err(_) => {}
                }
            }
        }
        while oi < olds.len() {
            remove(w, olds[oi], stats);
            oi += 1;
        }
        w.link_children(d, &kids);
    }
    false
}

fn mark_unreadable(w: &mut Snapshot, d: EntryId, stats: &mut UpdateStats) {
    if w.flags_of(d) & flags::UNREADABLE == 0 {
        w.add_flags(d, flags::UNREADABLE);
        stats.changed += 1;
    }
}

fn remove(w: &mut Snapshot, id: EntryId, stats: &mut UpdateStats) {
    let before = w.len();
    w.kill_subtree(id);
    stats.removed += before - w.len();
}

fn clear_children(w: &mut Snapshot, d: EntryId, stats: &mut UpdateStats) {
    let kids: Vec<EntryId> = w.children(d).collect();
    for k in kids {
        remove(w, k, stats);
    }
    w.link_children(d, &[]);
}
