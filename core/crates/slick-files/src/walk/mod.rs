//! The tree walker: lists folders with `getattrlistbulk` on a few threads, applies the rules, and
//! never follows a symbolic link.
//!
//! - A folder that cannot be opened is kept as an entry with [`flags::UNREADABLE`] and no
//!   children. Files that vanish mid-walk are simply missing from the result.
//! - Symbolic links are indexed as links and never entered, so the walk cannot leave its roots.
//!   Folders are opened with `O_NOFOLLOW`, so a folder swapped for a link mid-walk is not entered
//!   either.
//! - Folders named by [`Rules::leaf_extensions`] are indexed and not entered. With
//!   [`Rules::one_filesystem`], a folder on another volume is indexed and not entered.
//! - Entries of one folder are sorted by name, so a walk always assigns the same ids.
//! - Every walker thread checks the walk's [`Cancel`] before it lists a folder. A cancelled walk
//!   returns [`ListError::Cancelled`] and its partial result is dropped.

pub(crate) mod bulk;

use crate::cancel::{self, Cancel};
use crate::rules::{Compiled, Rules};
use crate::store::{EntryId, MAX_DEPTH, NewEntry, Snapshot, flags};
use std::ffi::OsStr;
use std::fs::{File, OpenOptions};
use std::io;
use std::os::macos::fs::MetadataExt as _;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

/// How the walker enumerates a folder.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Method {
    /// `getattrlistbulk`: names, types, times, sizes and flags in bulk. The default.
    Bulk,
    /// `readdir` with `d_type` only: names and types, no times or sizes. For comparison.
    Readdir,
    /// `readdir` plus one `lstat` per entry: the same facts as `Bulk`. For comparison.
    ReaddirStat,
}

/// One entry of a listing.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Item {
    pub(crate) name_off: u32,
    pub(crate) name_len: u16,
    pub(crate) flags: u8,
    pub(crate) mtime: u32,
    pub(crate) size: u64,
}

/// The indexed entries of one folder, sorted by name.
#[derive(Default, Debug)]
pub(crate) struct Listing {
    pub(crate) names: Vec<u8>,
    pub(crate) items: Vec<Item>,
    /// Item index and listing id of every sub-folder the walk entered.
    pub(crate) children: Vec<(u32, u32)>,
    pub(crate) unreadable: bool,
}

impl Listing {
    pub(crate) fn name(&self, i: usize) -> &[u8] {
        let it = &self.items[i];
        &self.names[it.name_off as usize..it.name_off as usize + it.name_len as usize]
    }
}

/// Facts about an open folder.
#[derive(Clone, Copy, Debug)]
pub(crate) struct DirMeta {
    pub(crate) mtime: u32,
    pub(crate) hidden_flag: bool,
    pub(crate) dev: u64,
}

/// Why a folder could not be listed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ListError {
    /// It does not exist any more.
    Gone,
    /// It is not a folder, or it is a symbolic link.
    NotDir,
    /// Permission denied.
    Denied,
    Other,
    /// The walk's [`Cancel`] was set before every folder was listed.
    Cancelled,
}

fn classify(e: &io::Error) -> ListError {
    match e.raw_os_error() {
        Some(libc::ENOENT) => ListError::Gone,
        Some(libc::ENOTDIR) | Some(libc::ELOOP) => ListError::NotDir,
        Some(libc::EACCES) | Some(libc::EPERM) => ListError::Denied,
        _ => ListError::Other,
    }
}

/// Opens a folder without following a link at its last component.
pub(crate) fn open_dir(path: &[u8]) -> Result<(File, DirMeta), ListError> {
    let f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(OsStr::from_bytes(path))
        .map_err(|e| classify(&e))?;
    let m = f.metadata().map_err(|e| classify(&e))?;
    Ok((
        f,
        DirMeta {
            mtime: m.mtime().clamp(0, u32::MAX as i64) as u32,
            hidden_flag: m.st_flags() & libc::UF_HIDDEN != 0,
            dev: m.dev(),
        },
    ))
}

/// Scratch buffers for one walking thread.
#[derive(Default)]
pub(crate) struct Scratch {
    buf: Vec<u8>,
    raw: Vec<bulk::Raw>,
    raw_names: Vec<u8>,
    order: Vec<u32>,
}

/// Lists the indexed entries of the folder at `path`.
pub(crate) fn list_dir(
    path: &[u8],
    rules: &Compiled,
    method: Method,
    s: &mut Scratch,
) -> Result<(DirMeta, Listing), ListError> {
    s.raw.clear();
    s.raw_names.clear();
    let (meta, read_ok) = match method {
        Method::Bulk => {
            let (f, meta) = open_dir(path)?;
            let ok = bulk::read_all(&f, &mut s.buf, &mut s.raw_names, &mut s.raw).is_ok();
            (meta, ok)
        }
        Method::Readdir | Method::ReaddirStat => {
            let (_, meta) = open_dir(path)?;
            let ok = read_with_std(path, method == Method::ReaddirStat, &mut s.raw_names, &mut s.raw).is_ok();
            (meta, ok)
        }
    };
    let mut l = Listing {
        unreadable: !read_ok,
        ..Listing::default()
    };
    s.order.clear();
    s.order.extend(0..s.raw.len() as u32);
    let names = &s.raw_names;
    let raw = &s.raw;
    s.order
        .sort_unstable_by(|&a, &b| names[raw[a as usize].name.clone()].cmp(&names[raw[b as usize].name.clone()]));
    for &i in &s.order {
        let r = &raw[i as usize];
        let name = &names[r.name.clone()];
        let hidden = name.first() == Some(&b'.') || r.hidden_flag;
        if rules.skips(path, name, hidden) || name.len() > u16::MAX as usize {
            continue;
        }
        let mut f = 0u8;
        match r.kind {
            bulk::Kind::Dir => {
                f |= flags::DIR;
                if rules.is_leaf(name) {
                    f |= flags::PACKAGE;
                }
            }
            bulk::Kind::Symlink => f |= flags::SYMLINK,
            bulk::Kind::File | bulk::Kind::Other => {}
        }
        if hidden {
            f |= flags::HIDDEN;
        }
        let off = l.names.len() as u32;
        l.names.extend_from_slice(name);
        l.items.push(Item {
            name_off: off,
            name_len: name.len() as u16,
            flags: f,
            mtime: r.mtime,
            size: if r.kind == bulk::Kind::File { r.size } else { 0 },
        });
    }
    Ok((meta, l))
}

fn read_with_std(path: &[u8], stat: bool, names: &mut Vec<u8>, out: &mut Vec<bulk::Raw>) -> io::Result<()> {
    for e in std::fs::read_dir(OsStr::from_bytes(path))? {
        let Ok(e) = e else { continue };
        let name = e.file_name();
        let nb = name.as_bytes();
        let s = names.len();
        names.extend_from_slice(nb);
        let (kind, mtime, size, hidden_flag) = if stat {
            match e.metadata() {
                Ok(m) => {
                    let ft = m.file_type();
                    let kind = if ft.is_symlink() {
                        bulk::Kind::Symlink
                    } else if ft.is_dir() {
                        bulk::Kind::Dir
                    } else if ft.is_file() {
                        bulk::Kind::File
                    } else {
                        bulk::Kind::Other
                    };
                    let mtime = m.mtime().clamp(0, u32::MAX as i64) as u32;
                    (kind, mtime, m.len(), m.st_flags() & libc::UF_HIDDEN != 0)
                }
                Err(_) => continue,
            }
        } else {
            let kind = match e.file_type() {
                Ok(t) if t.is_symlink() => bulk::Kind::Symlink,
                Ok(t) if t.is_dir() => bulk::Kind::Dir,
                Ok(t) if t.is_file() => bulk::Kind::File,
                _ => bulk::Kind::Other,
            };
            (kind, 0, 0, false)
        };
        out.push(bulk::Raw {
            name: s..names.len(),
            kind,
            hidden_flag,
            mtime,
            size,
        });
    }
    Ok(())
}

/// What a walk saw.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct WalkStats {
    /// Folders listed.
    pub dirs: usize,
    /// Entries indexed, not counting the start folder.
    pub entries: usize,
    /// Folders that could not be listed.
    pub unreadable: usize,
    pub elapsed: Duration,
}

/// The result of walking one folder: listing 0 is the start folder.
pub(crate) struct Tree {
    pub(crate) listings: Vec<Listing>,
    pub(crate) meta: DirMeta,
    pub(crate) stats: WalkStats,
}

struct Job {
    id: u32,
    path: Vec<u8>,
    depth: usize,
}

struct Queue {
    jobs: Vec<Job>,
    active: usize,
}

/// Lists one job's folder and makes jobs for its sub-folders.
fn process(
    job: &Job,
    rules: &Compiled,
    method: Method,
    dev: u64,
    next: &AtomicU32,
    s: &mut Scratch,
) -> (Listing, Vec<Job>) {
    let (meta, mut l) = match list_dir(&job.path, rules, method, s) {
        Ok(x) => x,
        Err(ListError::Gone) | Err(ListError::NotDir) => return (Listing::default(), Vec::new()),
        Err(_) => {
            return (
                Listing {
                    unreadable: true,
                    ..Listing::default()
                },
                Vec::new(),
            );
        }
    };
    let mut jobs = Vec::new();
    if rules.one_filesystem && dev != 0 && meta.dev != dev {
        l.items.clear();
        l.names.clear();
        return (l, jobs);
    }
    if job.depth + 1 < MAX_DEPTH {
        for i in 0..l.items.len() {
            let f = l.items[i].flags;
            if f & flags::DIR != 0 && f & (flags::PACKAGE | flags::SYMLINK) == 0 {
                let id = next.fetch_add(1, Ordering::Relaxed);
                let mut path = Vec::with_capacity(job.path.len() + 1 + l.items[i].name_len as usize);
                path.extend_from_slice(&job.path);
                if path.last() != Some(&b'/') {
                    path.push(b'/');
                }
                path.extend_from_slice(l.name(i));
                jobs.push(Job {
                    id,
                    path,
                    depth: job.depth + 1,
                });
                l.children.push((i as u32, id));
            }
        }
    }
    (l, jobs)
}

/// Walks the folder at `start`, which sits `depth` levels below its root, with up to `threads`
/// threads. With [`Rules::one_filesystem`], folders on a device other than `dev` (or the start
/// folder's device when `dev` is `None`; 0 means unknown) are not entered. Fails when `start`
/// itself is gone or is not a folder, and with [`ListError::Cancelled`] when `stop` was set before
/// every folder was listed.
pub(crate) fn walk(
    start: &[u8],
    depth: usize,
    rules: &Compiled,
    threads: usize,
    method: Method,
    dev: Option<u64>,
    stop: &Cancel,
) -> Result<Tree, ListError> {
    let began = Instant::now();
    if stop.check() {
        return Err(ListError::Cancelled);
    }
    let meta = match open_dir(start) {
        Ok((_, m)) => m,
        Err(ListError::Denied) | Err(ListError::Other) => {
            return Ok(Tree {
                listings: vec![Listing {
                    unreadable: true,
                    ..Listing::default()
                }],
                meta: DirMeta {
                    mtime: 0,
                    hidden_flag: false,
                    dev: 0,
                },
                stats: WalkStats {
                    dirs: 1,
                    unreadable: 1,
                    elapsed: began.elapsed(),
                    ..WalkStats::default()
                },
            });
        }
        Err(e) => return Err(e),
    };
    let dev = dev.unwrap_or(meta.dev);
    let next = AtomicU32::new(1);
    let first = Job {
        id: 0,
        path: start.to_vec(),
        depth,
    };
    let mut results: Vec<(u32, Listing)> = Vec::new();
    // The start folder passed the check above; every other folder is checked before it is listed.
    let mut checked_first = false;
    let mut check = |stop: &Cancel| std::mem::replace(&mut checked_first, true) && stop.check();
    let mut cut = false;
    if threads <= 1 {
        let mut s = Scratch::default();
        let mut stack = vec![first];
        while let Some(job) = stack.pop() {
            if check(stop) {
                cut = true;
                break;
            }
            let (l, jobs) = process(&job, rules, method, dev, &next, &mut s);
            results.push((job.id, l));
            stack.extend(jobs.into_iter().rev());
        }
    } else {
        let first_done = AtomicBool::new(false);
        let stopped = AtomicBool::new(false);
        let queue = Mutex::new(Queue {
            jobs: vec![first],
            active: 0,
        });
        let ready = Condvar::new();
        let worker = || {
            let mut s = Scratch::default();
            let mut mine = Vec::new();
            loop {
                let job = {
                    let mut q = queue.lock().unwrap_or_else(|e| e.into_inner());
                    loop {
                        if !q.jobs.is_empty() && first_done.swap(true, Ordering::Relaxed) && stop.check() {
                            // Drop the waiting folders. Threads that are listing one finish it and
                            // then find the queue empty.
                            q.jobs.clear();
                            stopped.store(true, Ordering::Relaxed);
                        }
                        if let Some(j) = q.jobs.pop() {
                            q.active += 1;
                            break Some(j);
                        }
                        if q.active == 0 {
                            break None;
                        }
                        q = ready.wait(q).unwrap_or_else(|e| e.into_inner());
                    }
                };
                let Some(job) = job else {
                    ready.notify_all();
                    return mine;
                };
                let (l, jobs) = process(&job, rules, method, dev, &next, &mut s);
                mine.push((job.id, l));
                let mut q = queue.lock().unwrap_or_else(|e| e.into_inner());
                let n = jobs.len();
                q.jobs.extend(jobs);
                q.active -= 1;
                let done = q.active == 0 && q.jobs.is_empty();
                drop(q);
                if done || n > 1 {
                    ready.notify_all();
                } else if n == 1 {
                    ready.notify_one();
                }
            }
        };
        std::thread::scope(|scope| {
            let handles: Vec<_> = (0..threads).map(|_| scope.spawn(worker)).collect();
            for h in handles {
                if let Ok(mut r) = h.join() {
                    results.append(&mut r);
                }
            }
        });
        cut = stopped.load(Ordering::Relaxed);
    }
    if cut {
        return Err(ListError::Cancelled);
    }
    let total = next.load(Ordering::Relaxed) as usize;
    let mut listings: Vec<Listing> = (0..total).map(|_| Listing::default()).collect();
    let mut stats = WalkStats::default();
    for (id, l) in results {
        stats.dirs += 1;
        stats.entries += l.items.len();
        stats.unreadable += usize::from(l.unreadable);
        if let Some(slot) = listings.get_mut(id as usize) {
            *slot = l;
        }
    }
    stats.elapsed = began.elapsed();
    Ok(Tree { listings, meta, stats })
}

/// Appends a walked tree below `dir`, which must have no children yet. Returns the number of
/// entries added.
pub(crate) fn graft(w: &mut Snapshot, dir: EntryId, tree: &Tree) -> usize {
    let mut added = 0;
    let mut stack: Vec<(EntryId, u32)> = vec![(dir, 0)];
    let mut ids: Vec<EntryId> = Vec::new();
    while let Some((d, li)) = stack.pop() {
        let Some(l) = tree.listings.get(li as usize) else {
            continue;
        };
        if l.unreadable {
            w.add_flags(d, flags::UNREADABLE);
        }
        ids.clear();
        for i in 0..l.items.len() {
            let it = l.items[i];
            ids.push(w.push(NewEntry {
                parent: d,
                name: l.name(i),
                flags: it.flags,
                mtime: it.mtime,
                size: it.size,
            }));
        }
        added += ids.len();
        w.link_children(d, &ids);
        for &(i, child) in l.children.iter().rev() {
            if let Some(&id) = ids.get(i as usize) {
                stack.push((id, child));
            }
        }
    }
    added
}

/// Walks `path` with the given rules and method and reports what it saw, without building an
/// index. For measuring enumeration methods.
pub fn measure(path: &Path, rules: &Rules, threads: usize, method: Method) -> io::Result<WalkStats> {
    walk(
        path.as_os_str().as_bytes(),
        0,
        &rules.compile(),
        threads,
        method,
        None,
        &cancel::NEVER,
    )
    .map(|t| t.stats)
    .map_err(|e| io::Error::other(format!("{e:?}")))
}

/// One child of a folder listed straight from disk.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiskEntry {
    pub name: Vec<u8>,
    /// [`flags`] bits.
    pub flags: u8,
    pub mtime: u32,
    pub size: Option<u64>,
}

/// Lists a folder from disk with the rules applied, sorted by name. For folder queries outside
/// the index. Call it off the main thread. A folder that is missing, is not a folder (a symbolic
/// link to one counts as not a folder) or may not be read fails with `NotFound`,
/// `NotADirectory` or `PermissionDenied`.
pub fn list_folder(path: &Path, rules: &Rules) -> io::Result<Vec<DiskEntry>> {
    list_folder_checked(path, rules).map(|l| l.entries)
}

/// What [`list_folder_checked`] read.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FolderListing {
    /// The children the rules keep, sorted by name.
    pub entries: Vec<DiskEntry>,
    /// False when the folder opened but reading its entries failed partway, so some may be
    /// missing.
    pub complete: bool,
}

/// [`list_folder`] that also says whether the listing is complete.
pub fn list_folder_checked(path: &Path, rules: &Rules) -> io::Result<FolderListing> {
    let (_, l) = list_dir(
        path.as_os_str().as_bytes(),
        &rules.compile(),
        Method::Bulk,
        &mut Scratch::default(),
    )
    .map_err(|e| match e {
        ListError::Gone => io::Error::from(io::ErrorKind::NotFound),
        ListError::NotDir => io::Error::from(io::ErrorKind::NotADirectory),
        ListError::Denied => io::Error::from(io::ErrorKind::PermissionDenied),
        ListError::Other | ListError::Cancelled => io::Error::other("the folder could not be listed"),
    })?;
    let entries = (0..l.items.len())
        .map(|i| DiskEntry {
            name: l.name(i).to_vec(),
            flags: l.items[i].flags,
            mtime: l.items[i].mtime,
            size: (l.items[i].flags & flags::DIR == 0).then_some(l.items[i].size),
        })
        .collect();
    Ok(FolderListing {
        entries,
        complete: !l.unreadable,
    })
}
