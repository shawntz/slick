//! The compact entry store.
//!
//! Entries live in chunks of 4,096. Each chunk is a structure of arrays plus its own name arena.
//! Per entry the store keeps 40 bytes of columns plus the name:
//!
//! | column | bytes | meaning |
//! |---|---|---|
//! | parent | 4 | parent entry, [`NONE`] for a root |
//! | next | 4 | next sibling, [`NONE`] at the end |
//! | aux | 4 | a directory's first child, or a file's size, exact below 2 GiB and in MiB above |
//! | mtime | 4 | modification time, Unix seconds |
//! | name_off | 4 | offset of the name in the chunk's arena |
//! | mask | 4 | compressed presence mask of the folded name |
//! | initials | 4 | compressed presence mask of the chars that start words |
//! | ws | 8 | word-start bits of the folded name |
//! | name_len | 1 | name length; 255 means a 2-byte length prefix in the arena |
//! | first | 1 | folded first word char, for the prefix pass |
//! | flags | 1 | [`flags`] |
//! | depth | 1 | depth below the root, saturating at 255 |
//!
//! A path is rebuilt by walking parents. Entries are only ever appended, so a parent's id is
//! always smaller than its children's. A deleted entry stays as a dead slot until the writer
//! compacts the store.
//!
//! A [`Snapshot`] is immutable once published. The writer works on a private copy that shares
//! every chunk with the published one and copies a chunk only when it changes it.

use crate::col::Col;
use crate::names::{self, NameInfo};
use std::sync::Arc;

/// Index of an entry inside one snapshot.
pub type EntryId = u32;

/// No entry.
pub const NONE: EntryId = u32::MAX;

pub(crate) const CHUNK_BITS: u32 = 12;
pub(crate) const CHUNK: usize = 1 << CHUNK_BITS;
/// Zero bytes after the last name of an arena, so a 64-byte load at any name start stays inside.
pub(crate) const PAD: usize = 64;
/// Deepest entry the store keeps. Deeper directories are not descended.
pub const MAX_DEPTH: usize = 250;

/// Entry flags.
pub mod flags {
    /// A directory.
    pub const DIR: u8 = 1;
    /// A directory treated as a leaf: a bundle or a document package.
    pub const PACKAGE: u8 = 2;
    /// A dot name or a name with the hidden flag.
    pub const HIDDEN: u8 = 4;
    /// A symbolic link. Never followed.
    pub const SYMLINK: u8 = 8;
    /// The name does not fold one ASCII byte per byte.
    pub(crate) const MULTIBYTE: u8 = 16;
    /// A deleted slot.
    pub(crate) const DEAD: u8 = 32;
    /// One of the index roots.
    pub const ROOT: u8 = 64;
    /// A directory the walker could not list.
    pub const UNREADABLE: u8 = 128;
    /// The flags that describe the file itself, as opposed to the store's bookkeeping.
    pub const PUBLIC: u8 = DIR | PACKAGE | HIDDEN | SYMLINK | ROOT | UNREADABLE;
}

/// Encodes a size in 32 bits: exact below 2 GiB, in MiB above.
pub(crate) fn encode_size(s: u64) -> u32 {
    if s < 1 << 31 {
        s as u32
    } else {
        (1 << 31) | (s >> 20).min((1 << 31) - 1) as u32
    }
}

/// Decodes [`encode_size`].
pub(crate) fn decode_size(v: u32) -> u64 {
    if v & (1 << 31) == 0 {
        v as u64
    } else {
        ((v & 0x7FFF_FFFF) as u64) << 20
    }
}

/// One chunk of entries.
#[derive(Clone, Default)]
pub(crate) struct Chunk {
    pub(crate) parent: Col<u32>,
    pub(crate) next: Col<u32>,
    pub(crate) aux: Col<u32>,
    pub(crate) mtime: Col<u32>,
    pub(crate) name_off: Col<u32>,
    pub(crate) mask: Col<u32>,
    pub(crate) initials: Col<u32>,
    pub(crate) ws: Col<u64>,
    pub(crate) name_len: Col<u8>,
    pub(crate) first: Col<u8>,
    pub(crate) flags: Col<u8>,
    pub(crate) depth: Col<u8>,
    /// Names back to back, then `PAD` zero bytes. A mapped chunk shares the file's global arena.
    pub(crate) names: Col<u8>,
    /// Arena bytes that belong to dead entries.
    pub(crate) garbage: u32,
}

/// Borrowed slices of one chunk, for loops that touch many entries.
pub(crate) struct View<'a> {
    pub(crate) parent: &'a [u32],
    pub(crate) mtime: &'a [u32],
    pub(crate) name_off: &'a [u32],
    pub(crate) mask: &'a [u32],
    pub(crate) initials: &'a [u32],
    pub(crate) ws: &'a [u64],
    pub(crate) name_len: &'a [u8],
    pub(crate) first: &'a [u8],
    pub(crate) flags: &'a [u8],
    pub(crate) depth: &'a [u8],
    pub(crate) names: &'a [u8],
}

impl View<'_> {
    /// Number of slots.
    #[inline(always)]
    pub(crate) fn len(&self) -> usize {
        self.flags.len()
    }

    /// The raw name of `slot`.
    #[inline(always)]
    pub(crate) fn name(&self, slot: usize) -> &[u8] {
        name_at(self.name_off[slot], self.name_len[slot], self.names)
    }

    /// The stored folded form of a name that does not fold byte for byte, one with
    /// [`flags::MULTIBYTE`]. Empty for other names.
    #[inline(always)]
    pub(crate) fn folded(&self, slot: usize) -> &[u8] {
        if self.flags[slot] & flags::MULTIBYTE == 0 {
            return &[];
        }
        folded_at(self.name_off[slot], self.name_len[slot], self.names)
    }

    /// The 64 bytes that start at the name of `slot`, when the arena holds them. It always does
    /// for a name of at most 64 bytes, thanks to the padding.
    #[inline(always)]
    pub(crate) fn block(&self, slot: usize) -> Option<&[u8; 64]> {
        let off = self.name_off[slot] as usize;
        self.names.get(off..off + 64).and_then(|b| b.try_into().ok())
    }
}

impl Chunk {
    pub(crate) fn len(&self) -> usize {
        self.flags.len()
    }

    pub(crate) fn view(&self) -> View<'_> {
        View {
            parent: self.parent.as_slice(),
            mtime: self.mtime.as_slice(),
            name_off: self.name_off.as_slice(),
            mask: self.mask.as_slice(),
            initials: self.initials.as_slice(),
            ws: self.ws.as_slice(),
            name_len: self.name_len.as_slice(),
            first: self.first.as_slice(),
            flags: self.flags.as_slice(),
            depth: self.depth.as_slice(),
            names: self.names.as_slice(),
        }
    }

    /// Rebuilds the arena with only the names of live entries, when it is a mapped view of a
    /// whole file's arena or when dead names take more than half of it.
    fn tidy_names(&mut self) {
        let arena = self.names.len();
        let needs = self.names.is_mapped() || (self.garbage as usize > 16 * 1024 && self.garbage as usize * 2 > arena);
        if !needs {
            return;
        }
        let n = self.len();
        let mut fresh = Vec::with_capacity(arena.saturating_sub(self.garbage as usize).min(n * 64) + PAD);
        let mut offs = Vec::with_capacity(n);
        let mut lens = Vec::with_capacity(n);
        {
            let v = self.view();
            for slot in 0..n {
                offs.push(fresh.len() as u32);
                if v.flags[slot] & flags::DEAD != 0 {
                    lens.push(0);
                    continue;
                }
                let folded = (v.flags[slot] & flags::MULTIBYTE != 0).then(|| v.folded(slot));
                push_record(&mut fresh, &mut lens, v.name(slot), folded);
            }
        }
        fresh.extend_from_slice(&[0u8; PAD]);
        *self.names.to_mut() = fresh;
        *self.name_off.to_mut() = offs;
        *self.name_len.to_mut() = lens;
        self.garbage = 0;
    }

    pub(crate) fn heap_bytes(&self) -> usize {
        self.parent.heap_bytes()
            + self.next.heap_bytes()
            + self.aux.heap_bytes()
            + self.mtime.heap_bytes()
            + self.name_off.heap_bytes()
            + self.mask.heap_bytes()
            + self.initials.heap_bytes()
            + self.ws.heap_bytes()
            + self.name_len.heap_bytes()
            + self.first.heap_bytes()
            + self.flags.heap_bytes()
            + self.depth.heap_bytes()
            + self.names.heap_bytes()
    }
}

/// The name stored at `off` with length byte `len`. Reads as empty when it leaves the arena.
#[inline(always)]
fn name_at(off: u32, len: u8, names: &[u8]) -> &[u8] {
    let off = off as usize;
    if len < 255 {
        return names.get(off..off + len as usize).unwrap_or(&[]);
    }
    let real = match names.get(off..off + 2) {
        Some(b) => u16::from_le_bytes([b[0], b[1]]) as usize,
        None => return &[],
    };
    names.get(off + 2..off + 2 + real).unwrap_or(&[])
}

/// Where the name stored at `off` ends.
#[inline(always)]
fn name_end(off: u32, len: u8, names: &[u8]) -> usize {
    let off = off as usize;
    if len < 255 {
        return off + len as usize;
    }
    match names.get(off..off + 2) {
        Some(b) => off + 2 + u16::from_le_bytes([b[0], b[1]]) as usize,
        None => off,
    }
}

/// The folded copy that follows the name at `off`. Reads as empty when it leaves the arena.
#[inline(always)]
fn folded_at(off: u32, len: u8, names: &[u8]) -> &[u8] {
    let at = name_end(off, len, names);
    let flen = match names.get(at..at + 2) {
        Some(b) => u16::from_le_bytes([b[0], b[1]]) as usize,
        None => return &[],
    };
    names.get(at + 2..at + 2 + flen).unwrap_or(&[])
}

/// Bytes of the whole record at `off`: length prefix, name and folded copy.
pub(crate) fn record_at(off: u32, len: u8, multibyte: bool, names: &[u8]) -> &[u8] {
    let mut end = name_end(off, len, names);
    if multibyte {
        let flen = names
            .get(end..end + 2)
            .map_or(0, |b| u16::from_le_bytes([b[0], b[1]]) as usize);
        end += 2 + flen;
    }
    names.get(off as usize..end).unwrap_or(&[])
}

/// Appends a record to an arena whose padding has been removed, recording its length byte: a
/// 2-byte length before names of 255 bytes or more, then the name, then for names that do not fold
/// byte for byte a 2-byte length and the folded form.
pub(crate) fn push_record(arena: &mut Vec<u8>, lens: &mut Vec<u8>, name: &[u8], folded: Option<&[u8]>) {
    let name = &name[..name.len().min(u16::MAX as usize)];
    if name.len() < 255 {
        lens.push(name.len() as u8);
    } else {
        lens.push(255);
        arena.extend_from_slice(&(name.len() as u16).to_le_bytes());
    }
    arena.extend_from_slice(name);
    if let Some(f) = folded {
        let f = &f[..f.len().min(u16::MAX as usize)];
        arena.extend_from_slice(&(f.len() as u16).to_le_bytes());
        arena.extend_from_slice(f);
    }
}

/// One index root.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Root {
    pub(crate) id: EntryId,
    /// Absolute path of the root directory.
    pub(crate) path: Box<[u8]>,
}

/// Facts about one entry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EntryInfo<'a> {
    pub id: EntryId,
    pub name: &'a [u8],
    pub parent: EntryId,
    /// [`flags`] bits from [`flags::PUBLIC`].
    pub flags: u8,
    pub mtime: u32,
    /// File size in bytes, exact below 2 GiB and rounded down to a MiB above. `None` for a
    /// directory.
    pub size: Option<u64>,
    pub depth: u8,
}

impl EntryInfo<'_> {
    pub fn is_dir(&self) -> bool {
        self.flags & flags::DIR != 0
    }
}

/// An immutable view of the whole index. Cheap to clone: chunks are shared.
#[derive(Clone, Default)]
pub struct Snapshot {
    pub(crate) chunks: Vec<Arc<Chunk>>,
    pub(crate) len: u32,
    pub(crate) live: u32,
    pub(crate) roots: Arc<[Root]>,
    pub(crate) generation: u64,
    pub(crate) rules_hash: u64,
}

/// What an entry is, for [`Snapshot::push`].
#[derive(Clone, Copy, Debug)]
pub(crate) struct NewEntry<'a> {
    pub(crate) parent: EntryId,
    pub(crate) name: &'a [u8],
    pub(crate) flags: u8,
    pub(crate) mtime: u32,
    pub(crate) size: u64,
}

impl Snapshot {
    /// Number of slots, live or dead. Entry ids are below this.
    pub fn slots(&self) -> usize {
        self.len as usize
    }

    /// Number of live entries.
    pub fn len(&self) -> usize {
        self.live as usize
    }

    pub fn is_empty(&self) -> bool {
        self.live == 0
    }

    /// Changes every time the writer publishes. Entry ids are only meaningful together with the
    /// snapshot they came from.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// The root entries and their absolute paths.
    pub fn roots(&self) -> impl Iterator<Item = (EntryId, &[u8])> {
        self.roots.iter().map(|r| (r.id, &*r.path))
    }

    #[inline(always)]
    pub(crate) fn locate(&self, id: EntryId) -> Option<(&Chunk, usize)> {
        if id >= self.len {
            return None;
        }
        let c = self.chunks.get((id >> CHUNK_BITS) as usize)?;
        let slot = id as usize & (CHUNK - 1);
        (slot < c.len()).then_some((&**c, slot))
    }

    #[inline(always)]
    pub(crate) fn flags_of(&self, id: EntryId) -> u8 {
        self.locate(id).map_or(flags::DEAD, |(c, s)| c.flags.as_slice()[s])
    }

    #[inline(always)]
    pub(crate) fn parent_of(&self, id: EntryId) -> EntryId {
        self.locate(id).map_or(NONE, |(c, s)| c.parent.as_slice()[s])
    }

    pub(crate) fn name_of(&self, id: EntryId) -> &[u8] {
        match self.locate(id) {
            Some((c, s)) => name_at(c.name_off.as_slice()[s], c.name_len.as_slice()[s], c.names.as_slice()),
            None => &[],
        }
    }

    /// True when `id` is a live entry.
    pub fn contains(&self, id: EntryId) -> bool {
        self.flags_of(id) & flags::DEAD == 0
    }

    /// The whole stored record of a live entry: name and folded copy.
    pub(crate) fn record_of(&self, id: EntryId) -> &[u8] {
        match self.locate(id) {
            Some((c, s)) => record_at(
                c.name_off.as_slice()[s],
                c.name_len.as_slice()[s],
                c.flags.as_slice()[s] & flags::MULTIBYTE != 0,
                c.names.as_slice(),
            ),
            None => &[],
        }
    }

    /// Facts about a live entry.
    pub fn entry(&self, id: EntryId) -> Option<EntryInfo<'_>> {
        let (c, s) = self.locate(id)?;
        let f = c.flags.as_slice()[s];
        if f & flags::DEAD != 0 {
            return None;
        }
        let aux = c.aux.as_slice()[s];
        Some(EntryInfo {
            id,
            name: self.name_of(id),
            parent: c.parent.as_slice()[s],
            flags: f & flags::PUBLIC,
            mtime: c.mtime.as_slice()[s],
            size: (f & flags::DIR == 0).then(|| decode_size(aux)),
            depth: c.depth.as_slice()[s],
        })
    }

    /// The children of a directory, in name order for a fresh scan. Empty for a file.
    pub fn children(&self, dir: EntryId) -> Children<'_> {
        let first = match self.locate(dir) {
            Some((c, s)) if c.flags.as_slice()[s] & (flags::DIR | flags::DEAD) == flags::DIR => c.aux.as_slice()[s],
            _ => NONE,
        };
        Children {
            snap: self,
            cur: first,
            left: self.len,
        }
    }

    /// The root an entry belongs to, by walking parents.
    pub(crate) fn root_of(&self, id: EntryId) -> Option<&Root> {
        let mut cur = id;
        for _ in 0..=MAX_DEPTH + 1 {
            if self.flags_of(cur) & flags::ROOT != 0 {
                return self.roots.iter().find(|r| r.id == cur);
            }
            cur = self.parent_of(cur);
            if cur == NONE {
                return None;
            }
        }
        None
    }

    /// Appends the absolute path of `id` to `out`. Returns false, leaving `out` unchanged, for an
    /// unknown or dead entry.
    pub fn path_into(&self, id: EntryId, out: &mut Vec<u8>) -> bool {
        let mut chain = [0u32; MAX_DEPTH + 2];
        let mut n = 0;
        let mut cur = id;
        loop {
            if n == chain.len() || self.flags_of(cur) & flags::DEAD != 0 {
                return false;
            }
            chain[n] = cur;
            n += 1;
            if self.flags_of(cur) & flags::ROOT != 0 {
                break;
            }
            cur = self.parent_of(cur);
            if cur == NONE {
                return false;
            }
        }
        let Some(root) = self.roots.iter().find(|r| r.id == chain[n - 1]) else {
            return false;
        };
        out.extend_from_slice(&root.path);
        for &e in chain[..n - 1].iter().rev() {
            if out.last() != Some(&b'/') {
                out.push(b'/');
            }
            out.extend_from_slice(self.name_of(e));
        }
        true
    }

    /// The absolute path of `id` as a new vector.
    pub fn path(&self, id: EntryId) -> Option<Vec<u8>> {
        let mut v = Vec::new();
        self.path_into(id, &mut v).then_some(v)
    }

    /// Writes the absolute path of `id` into `buf`. Returns its length, or `Err(needed)` when the
    /// buffer is too small or `Err(0)` for an unknown entry. Allocation-free up to a depth of 250.
    pub fn path_to_slice(&self, id: EntryId, buf: &mut [u8]) -> Result<usize, usize> {
        let mut chain = [0u32; MAX_DEPTH + 2];
        let mut n = 0;
        let mut cur = id;
        loop {
            if n == chain.len() || self.flags_of(cur) & flags::DEAD != 0 {
                return Err(0);
            }
            chain[n] = cur;
            n += 1;
            if self.flags_of(cur) & flags::ROOT != 0 {
                break;
            }
            cur = self.parent_of(cur);
            if cur == NONE {
                return Err(0);
            }
        }
        let Some(root) = self.roots.iter().find(|r| r.id == chain[n - 1]) else {
            return Err(0);
        };
        let mut len = root.path.len();
        let mut last_slash = root.path.last() == Some(&b'/');
        for &e in chain[..n - 1].iter().rev() {
            let name = self.name_of(e);
            len += usize::from(!last_slash) + name.len();
            last_slash = name.last() == Some(&b'/');
        }
        if len > buf.len() {
            return Err(len);
        }
        let mut at = root.path.len();
        buf[..at].copy_from_slice(&root.path);
        for &e in chain[..n - 1].iter().rev() {
            if at == 0 || buf[at - 1] != b'/' {
                buf[at] = b'/';
                at += 1;
            }
            let name = self.name_of(e);
            buf[at..at + name.len()].copy_from_slice(name);
            at += name.len();
        }
        Ok(at)
    }

    /// Finds the entry for an absolute path. Returns the deepest entry reached and whether it is
    /// the whole path. Components are compared exactly, then without ASCII case, because the
    /// usual macOS volume ignores case.
    pub fn lookup(&self, path: &[u8]) -> Option<(EntryId, bool)> {
        let path = trim_slashes(path);
        let root = self
            .roots
            .iter()
            .filter(|r| {
                let rp = trim_slashes(&r.path);
                path.starts_with(rp) && (path.len() == rp.len() || path[rp.len()] == b'/' || rp.is_empty())
            })
            .max_by_key(|r| r.path.len())?;
        let rest = &path[trim_slashes(&root.path).len()..];
        let mut cur = root.id;
        for comp in rest.split(|&b| b == b'/').filter(|c| !c.is_empty()) {
            let mut found = NONE;
            let mut folded = NONE;
            for child in self.children(cur) {
                let name = self.name_of(child);
                if name == comp {
                    found = child;
                    break;
                }
                if folded == NONE && name.eq_ignore_ascii_case(comp) {
                    folded = child;
                }
            }
            let next = if found != NONE { found } else { folded };
            if next == NONE {
                return Some((cur, false));
            }
            cur = next;
        }
        Some((cur, true))
    }

    /// Every live entry, with its path. Allocates; for tests and diagnostics.
    pub fn entries(&self) -> Vec<(Vec<u8>, EntryInfo<'_>)> {
        let mut out = Vec::with_capacity(self.len());
        for id in 0..self.len {
            if let (Some(info), Some(path)) = (self.entry(id), self.path(id)) {
                out.push((path, info));
            }
        }
        out.sort_by(|a, b| a.0.cmp(&b.0));
        out
    }

    /// Bytes this snapshot holds on the heap, counting shared chunks once per snapshot.
    pub fn heap_bytes(&self) -> usize {
        self.chunks.iter().map(|c| c.heap_bytes()).sum::<usize>()
            + self.chunks.capacity() * size_of::<Arc<Chunk>>()
            + self
                .roots
                .iter()
                .map(|r| r.path.len() + size_of::<Root>())
                .sum::<usize>()
    }

    /// Bytes of mapped file data this snapshot reads through.
    pub fn mapped_bytes(&self) -> usize {
        let mut total = 0;
        for c in &self.chunks {
            if c.flags.is_mapped() {
                total += c.len() * 40;
            }
        }
        total
            + self
                .chunks
                .first()
                .filter(|c| c.names.is_mapped())
                .map_or(0, |c| c.names.len())
    }

    // ---- writer side ----

    /// The chunk at index `c`, made private to this snapshot.
    fn chunk_mut(&mut self, c: usize) -> &mut Chunk {
        let ch = Arc::make_mut(&mut self.chunks[c]);
        ch.tidy_names();
        ch
    }

    #[inline]
    pub(crate) fn update<R>(&mut self, id: EntryId, f: impl FnOnce(&mut Chunk, usize) -> R) -> Option<R> {
        if id >= self.len {
            return None;
        }
        let c = (id >> CHUNK_BITS) as usize;
        let slot = id as usize & (CHUNK - 1);
        if c >= self.chunks.len() || slot >= self.chunks[c].len() {
            return None;
        }
        Some(f(self.chunk_mut(c), slot))
    }

    pub(crate) fn set_next(&mut self, id: EntryId, next: EntryId) {
        self.update(id, |c, s| c.next.to_mut()[s] = next);
    }

    pub(crate) fn set_first_child(&mut self, dir: EntryId, child: EntryId) {
        self.update(dir, |c, s| c.aux.to_mut()[s] = child);
    }

    /// Appends an entry and returns its id. It is not linked into its parent's child list.
    pub(crate) fn push(&mut self, e: NewEntry<'_>) -> EntryId {
        let (info, folded): (NameInfo, Vec<u8>) = names::analyze(e.name);
        let depth = if e.parent == NONE {
            0
        } else {
            self.locate(e.parent)
                .map_or(0, |(c, s)| c.depth.as_slice()[s].saturating_add(1))
        };
        let need_new = self.chunks.last().is_none_or(|c| c.len() >= CHUNK);
        if need_new {
            self.chunks.push(Arc::new(Chunk {
                names: Col::owned(vec![0u8; PAD]),
                ..Chunk::default()
            }));
        }
        let id = self.len;
        let last = self.chunks.len() - 1;
        let c = self.chunk_mut(last);
        let mut fl = e.flags & flags::PUBLIC;
        if info.multibyte {
            fl |= flags::MULTIBYTE;
        }
        c.parent.to_mut().push(e.parent);
        c.next.to_mut().push(NONE);
        c.aux.to_mut().push(if fl & flags::DIR != 0 {
            NONE
        } else {
            encode_size(e.size)
        });
        c.mtime.to_mut().push(e.mtime);
        c.mask.to_mut().push(info.mask);
        c.initials.to_mut().push(info.initials);
        c.ws.to_mut().push(info.ws);
        c.first.to_mut().push(info.first);
        c.flags.to_mut().push(fl);
        c.depth.to_mut().push(depth);
        let arena = c.names.to_mut();
        arena.truncate(arena.len().saturating_sub(PAD));
        let off = arena.len() as u32;
        push_record(
            arena,
            c.name_len.to_mut(),
            e.name,
            info.multibyte.then_some(folded.as_slice()),
        );
        arena.extend_from_slice(&[0u8; PAD]);
        c.name_off.to_mut().push(off);
        self.len += 1;
        self.live += 1;
        id
    }

    /// Marks one entry dead. The caller unlinks it from its parent's list.
    pub(crate) fn kill(&mut self, id: EntryId) {
        let was_live = self
            .update(id, |c, s| {
                let f = c.flags.as_slice()[s];
                if f & flags::DEAD != 0 {
                    return false;
                }
                c.flags.to_mut()[s] = f | flags::DEAD;
                c.mask.to_mut()[s] = 0;
                c.initials.to_mut()[s] = 0;
                c.first.to_mut()[s] = 0;
                let rec = record_at(
                    c.name_off.as_slice()[s],
                    c.name_len.as_slice()[s],
                    f & flags::MULTIBYTE != 0,
                    c.names.as_slice(),
                );
                c.garbage += rec.len() as u32;
                true
            })
            .unwrap_or(false);
        if was_live {
            self.live = self.live.saturating_sub(1);
        }
    }

    /// Marks an entry and everything below it dead.
    pub(crate) fn kill_subtree(&mut self, id: EntryId) {
        let mut stack = vec![id];
        let mut guard = self.len as usize + 1;
        while let Some(e) = stack.pop() {
            guard = guard.saturating_sub(1);
            if guard == 0 {
                break;
            }
            if self.flags_of(e) & flags::DEAD != 0 {
                continue;
            }
            stack.extend(self.children(e));
            self.kill(e);
        }
    }

    /// Sets or clears public flags of an entry.
    pub(crate) fn change_flags(&mut self, id: EntryId, set: u8, clear: u8) {
        if self
            .locate(id)
            .is_some_and(|(c, s)| (c.flags.as_slice()[s] | set) & !clear != c.flags.as_slice()[s])
        {
            self.update(id, |c, s| {
                let f = &mut c.flags.to_mut()[s];
                *f = (*f | set) & !clear;
            });
        }
    }

    pub(crate) fn add_flags(&mut self, id: EntryId, f: u8) {
        self.change_flags(id, f, 0);
    }

    /// Replaces the metadata of a live entry.
    pub(crate) fn set_meta(&mut self, id: EntryId, public_flags: u8, mtime: u32, size: u64) {
        self.update(id, |c, s| {
            let old = c.flags.as_slice()[s];
            let keep = old & !flags::PUBLIC;
            let new = keep | (public_flags & flags::PUBLIC);
            if new != old {
                c.flags.to_mut()[s] = new;
            }
            if c.mtime.as_slice()[s] != mtime {
                c.mtime.to_mut()[s] = mtime;
            }
            if new & flags::DIR == 0 {
                let enc = encode_size(size);
                if c.aux.as_slice()[s] != enc {
                    c.aux.to_mut()[s] = enc;
                }
            }
        });
    }

    /// Links `kids` as the children of `dir`, in that order.
    pub(crate) fn link_children(&mut self, dir: EntryId, kids: &[EntryId]) {
        let first = kids.first().copied().unwrap_or(NONE);
        if self.locate(dir).is_some_and(|(c, s)| c.aux.as_slice()[s] != first) {
            self.set_first_child(dir, first);
        }
        for (i, &k) in kids.iter().enumerate() {
            let next = kids.get(i + 1).copied().unwrap_or(NONE);
            if self.locate(k).is_some_and(|(c, s)| c.next.as_slice()[s] != next) {
                self.set_next(k, next);
            }
        }
    }

    /// Share of slots that are dead.
    pub(crate) fn dead_ratio(&self) -> f64 {
        if self.len == 0 {
            0.0
        } else {
            1.0 - self.live as f64 / self.len as f64
        }
    }

    /// A copy with only live entries, renumbered in depth-first order with siblings together.
    pub(crate) fn compacted(&self) -> Snapshot {
        let mut b = Builder::with_capacity(self.len());
        b.snap.rules_hash = self.rules_hash;
        for root in self.roots.iter() {
            let Some(info) = self.entry(root.id) else { continue };
            let new_root = b.root_with_flags(&root.path, info.flags, info.mtime);
            let mut stack: Vec<(EntryId, EntryId)> = vec![(root.id, new_root)];
            while let Some((old, new)) = stack.pop() {
                let mut kids = Vec::new();
                for child in self.children(old) {
                    let Some(ci) = self.entry(child) else { continue };
                    let id = b.add(new, ci.name, ci.flags, ci.mtime, ci.size.unwrap_or(0));
                    if ci.is_dir() {
                        kids.push((child, id));
                    }
                }
                stack.extend(kids.into_iter().rev());
            }
        }
        let mut s = b.finish();
        s.generation = self.generation;
        s
    }
}

/// Children of a directory.
pub struct Children<'a> {
    snap: &'a Snapshot,
    cur: EntryId,
    left: u32,
}

impl Iterator for Children<'_> {
    type Item = EntryId;

    fn next(&mut self) -> Option<EntryId> {
        if self.cur == NONE || self.left == 0 {
            return None;
        }
        self.left -= 1;
        let id = self.cur;
        self.cur = self.snap.locate(id).map_or(NONE, |(c, s)| c.next.as_slice()[s]);
        Some(id)
    }
}

fn trim_slashes(p: &[u8]) -> &[u8] {
    let mut end = p.len();
    while end > 1 && p[end - 1] == b'/' {
        end -= 1;
    }
    if end == 1 && p[0] == b'/' {
        return &p[..0];
    }
    &p[..end]
}

/// Builds a snapshot from entries fed in directly: the walker's output, a synthetic corpus, a test
/// fixture. Children are linked in the order they are added.
pub struct Builder {
    pub(crate) snap: Snapshot,
    last_child: Vec<EntryId>,
    roots: Vec<Root>,
}

impl Default for Builder {
    fn default() -> Self {
        Builder::new()
    }
}

impl Builder {
    pub fn new() -> Builder {
        Builder::with_capacity(0)
    }

    pub fn with_capacity(entries: usize) -> Builder {
        Builder {
            snap: Snapshot::default(),
            last_child: Vec::with_capacity(entries),
            roots: Vec::new(),
        }
    }

    /// Adds a root directory at an absolute path and returns its id.
    pub fn root(&mut self, path: &[u8], mtime: u32) -> EntryId {
        self.root_with_flags(path, flags::DIR, mtime)
    }

    pub(crate) fn root_with_flags(&mut self, path: &[u8], fl: u8, mtime: u32) -> EntryId {
        let trimmed = trim_slashes(path);
        let name = trimmed.rsplit(|&b| b == b'/').next().unwrap_or(&[]);
        let id = self.snap.push(NewEntry {
            parent: NONE,
            name,
            flags: (fl | flags::DIR | flags::ROOT) & flags::PUBLIC,
            mtime,
            size: 0,
        });
        self.last_child.push(NONE);
        let path: Box<[u8]> = if trimmed.is_empty() {
            Box::from(&b"/"[..])
        } else {
            trimmed.into()
        };
        self.roots.push(Root { id, path });
        id
    }

    /// Adds an entry under `parent` and returns its id. `entry_flags` takes [`flags::DIR`],
    /// [`flags::PACKAGE`], [`flags::HIDDEN`], [`flags::SYMLINK`] and [`flags::UNREADABLE`]. `size`
    /// is ignored for directories.
    pub fn add(&mut self, parent: EntryId, name: &[u8], entry_flags: u8, mtime: u32, size: u64) -> EntryId {
        let id = self.snap.push(NewEntry {
            parent,
            name,
            flags: entry_flags & !flags::ROOT,
            mtime,
            size,
        });
        self.last_child.push(NONE);
        if let Some(&prev) = self.last_child.get(parent as usize) {
            if prev == NONE {
                self.snap.set_first_child(parent, id);
            } else {
                self.snap.set_next(prev, id);
            }
            self.last_child[parent as usize] = id;
        }
        id
    }

    /// Entries added so far.
    pub fn len(&self) -> usize {
        self.snap.len()
    }

    pub fn is_empty(&self) -> bool {
        self.snap.is_empty()
    }

    pub fn finish(mut self) -> Snapshot {
        self.snap.roots = self.roots.into();
        for c in &mut self.snap.chunks {
            if let Some(ch) = Arc::get_mut(c) {
                shrink(ch);
            }
        }
        self.snap
    }
}

fn shrink(c: &mut Chunk) {
    c.parent.to_mut().shrink_to_fit();
    c.next.to_mut().shrink_to_fit();
    c.aux.to_mut().shrink_to_fit();
    c.mtime.to_mut().shrink_to_fit();
    c.name_off.to_mut().shrink_to_fit();
    c.mask.to_mut().shrink_to_fit();
    c.initials.to_mut().shrink_to_fit();
    c.ws.to_mut().shrink_to_fit();
    c.name_len.to_mut().shrink_to_fit();
    c.first.to_mut().shrink_to_fit();
    c.flags.to_mut().shrink_to_fit();
    c.depth.to_mut().shrink_to_fit();
    c.names.to_mut().shrink_to_fit();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tree() -> (Snapshot, Vec<EntryId>) {
        let mut b = Builder::new();
        let r = b.root(b"/tmp/root", 10);
        let docs = b.add(r, b"docs", flags::DIR, 20, 0);
        let readme = b.add(docs, b"README.md", 0, 30, 1234);
        let big = b.add(r, b"big.bin", 0, 40, 5 << 30);
        let long = vec![b'x'; 300];
        let l = b.add(docs, &long, 0, 50, 1);
        (b.finish(), vec![r, docs, readme, big, l])
    }

    #[test]
    fn paths_names_and_children() {
        let (s, ids) = tree();
        assert_eq!(s.len(), 5);
        assert_eq!(s.path(ids[2]).as_deref(), Some(&b"/tmp/root/docs/README.md"[..]));
        assert_eq!(s.path(ids[0]).as_deref(), Some(&b"/tmp/root"[..]));
        assert_eq!(s.children(ids[0]).collect::<Vec<_>>(), vec![ids[1], ids[3]]);
        assert_eq!(s.children(ids[1]).collect::<Vec<_>>(), vec![ids[2], ids[4]]);
        assert_eq!(s.name_of(ids[4]).len(), 300);
        let mut buf = [0u8; 400];
        let n = s.path_to_slice(ids[4], &mut buf).expect("fits");
        assert_eq!(&buf[..n], s.path(ids[4]).expect("path").as_slice());
        assert_eq!(s.path_to_slice(ids[4], &mut buf[..10]), Err(n));
        let e = s.entry(ids[3]).expect("entry");
        assert_eq!(e.size, Some(5 << 30));
        assert_eq!(s.entry(ids[2]).map(|e| (e.size, e.depth)), Some((Some(1234), 2)));
        assert_eq!(s.entry(ids[1]).map(|e| e.size), Some(None));
    }

    #[test]
    fn lookup_is_exact_first_then_case_blind() {
        let (s, ids) = tree();
        assert_eq!(s.lookup(b"/tmp/root/docs/README.md"), Some((ids[2], true)));
        assert_eq!(s.lookup(b"/tmp/root/DOCS/readme.md/"), Some((ids[2], true)));
        assert_eq!(s.lookup(b"/tmp/root/docs/missing/x"), Some((ids[1], false)));
        assert_eq!(s.lookup(b"/tmp/root"), Some((ids[0], true)));
        assert_eq!(s.lookup(b"/tmp/rootx"), None);
        assert_eq!(s.lookup(b"/elsewhere"), None);
    }

    #[test]
    fn writer_copies_shared_chunks_and_compacts() {
        let (s, ids) = tree();
        let published = s.clone();
        let mut w = s;
        w.kill_subtree(ids[1]);
        let kids: Vec<EntryId> = w.children(ids[0]).filter(|&k| k != ids[1]).collect();
        w.link_children(ids[0], &kids);
        assert_eq!(w.len(), 2);
        assert_eq!(published.len(), 5, "the published snapshot is untouched");
        assert!(published.entry(ids[2]).is_some());
        let c = w.compacted();
        assert_eq!(c.len(), 2);
        assert_eq!(c.slots(), 2);
        let paths: Vec<Vec<u8>> = c.entries().into_iter().map(|(p, _)| p).collect();
        assert_eq!(paths, vec![b"/tmp/root".to_vec(), b"/tmp/root/big.bin".to_vec()]);
    }

    #[test]
    fn sizes_round_trip() {
        for s in [0u64, 1, (1 << 31) - 1, 1 << 31, 5 << 30, u64::MAX] {
            let d = decode_size(encode_size(s));
            if s < 1 << 31 {
                assert_eq!(d, s);
            } else {
                assert!(d <= s && s - d < (1 << 20) || s == u64::MAX);
            }
        }
    }

    #[test]
    fn many_entries_span_chunks() {
        let mut b = Builder::new();
        let r = b.root(b"/r", 0);
        let mut last = r;
        for i in 0..10_000u32 {
            let parent = if i % 100 == 0 { r } else { last };
            let f = if i % 100 == 0 { flags::DIR } else { 0 };
            let id = b.add(parent, format!("n{i}").as_bytes(), f, i, i as u64);
            if f != 0 {
                last = id;
            }
        }
        let s = b.finish();
        assert_eq!(s.len(), 10_001);
        assert!(s.chunks.len() >= 3);
        assert_eq!(s.path(9_999).as_deref(), Some(&b"/r/n9900/n9998"[..]));
    }
}
