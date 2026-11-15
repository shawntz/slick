//! The index file: one file, memory-mapped, with a versioned header and a checksum.
//!
//! ```text
//! header, 128 bytes, little-endian
//!   0  magic        8 bytes
//!   8  version      u32
//!  12  header size  u32 (128)
//!  16  byte order   u32 (0x01020304)
//!  20  chunk bits   u32 (12)
//!  24  slots        u32
//!  28  live         u32
//!  32  roots        u32
//!  36  reserved     u32
//!  40  names bytes  u64, without padding
//!  48  body bytes   u64
//!  56  fingerprint  u64 of the roots and rules
//!  64  event id     u64, the FSEvents id the index is current to
//!  72  saved at     u64, Unix seconds
//!  80  reserved     40 bytes
//! 120  checksum     u64 over bytes 0..120 and the whole body
//! body, every section starting on a 64-byte boundary
//!   roots: id u32 and path length u32 per root, then the paths
//!   parent, next, aux, mtime, name_off, mask, initials: u32 per slot each
//!   ws: u64 per slot
//!   name_len, first, flags, depth: u8 per slot each
//!   names: the arena, then 64 zero bytes
//! ```
//!
//! Every section's offset follows from the counts, so there is no offset table to trust. A file is
//! written to a temporary name, synced and renamed over the old one, so a reader never sees a
//! half-written file. Opening checks the size, the header, the checksum and then every link and
//! name offset; anything wrong is an error and the caller rebuilds.

use crate::col::Col;
use crate::hash::Checksum;
use crate::mmap::Map;
use crate::store::{CHUNK, Chunk, EntryId, NONE, PAD, Root, Snapshot, flags};
use std::fs::{File, OpenOptions};
use std::io::{self, BufWriter, Seek, SeekFrom, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::sync::Arc;

const MAGIC: [u8; 8] = [0x89, b'F', b'I', b'D', b'X', 0x0D, 0x0A, 0x1A];
/// Format version. Bump it whenever the layout or the meaning of a column changes.
pub const VERSION: u32 = 1;
const HEADER: usize = 128;
const ORDER: u32 = 0x0102_0304;
const ALIGN: usize = 64;

/// Why an index file was refused.
#[derive(Debug)]
pub enum LoadError {
    Io(io::Error),
    /// The file is damaged: wrong size, bad header, bad checksum or a broken link.
    Corrupt(&'static str),
    /// The file has another format version.
    Version(u32),
    /// The file was built for other roots or rules.
    Mismatch,
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LoadError::Io(e) => write!(f, "index file I/O: {e}"),
            LoadError::Corrupt(why) => write!(f, "index file damaged: {why}"),
            LoadError::Version(v) => write!(f, "index file version {v}, expected {VERSION}"),
            LoadError::Mismatch => write!(f, "index file built for other roots or rules"),
        }
    }
}

impl std::error::Error for LoadError {}

impl From<io::Error> for LoadError {
    fn from(e: io::Error) -> Self {
        LoadError::Io(e)
    }
}

/// Facts from an index file's header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FileMeta {
    pub event_id: u64,
    pub saved_at: u64,
    pub entries: usize,
}

fn align(x: usize) -> usize {
    x.div_ceil(ALIGN) * ALIGN
}

/// Byte offsets of every section, computed from the counts.
#[derive(Debug, PartialEq, Eq)]
struct Layout {
    roots: usize,
    u32s: [usize; 7],
    ws: usize,
    u8s: [usize; 4],
    names: usize,
    end: usize,
}

fn layout(slots: usize, roots: usize, root_bytes: usize, names: usize) -> Option<Layout> {
    let mut at = HEADER;
    let roots_off = at;
    at = align(at.checked_add(roots.checked_mul(8)?)?.checked_add(root_bytes)?);
    let mut u32s = [0usize; 7];
    for o in &mut u32s {
        *o = at;
        at = align(at.checked_add(slots.checked_mul(4)?)?);
    }
    let ws = at;
    at = align(at.checked_add(slots.checked_mul(8)?)?);
    let mut u8s = [0usize; 4];
    for o in &mut u8s {
        *o = at;
        at = align(at.checked_add(slots)?);
    }
    let names_off = at;
    at = align(at.checked_add(names)?.checked_add(PAD)?);
    Some(Layout {
        roots: roots_off,
        u32s,
        ws,
        u8s,
        names: names_off,
        end: at,
    })
}

fn put32(h: &mut [u8], at: usize, v: u32) {
    h[at..at + 4].copy_from_slice(&v.to_le_bytes());
}

fn put64(h: &mut [u8], at: usize, v: u64) {
    h[at..at + 8].copy_from_slice(&v.to_le_bytes());
}

fn get32(h: &[u8], at: usize) -> u32 {
    h.get(at..at + 4)
        .map_or(0, |b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

fn get64(h: &[u8], at: usize) -> u64 {
    h.get(at..at + 8).map_or(0, |b| {
        let mut w = [0u8; 8];
        w.copy_from_slice(b);
        u64::from_le_bytes(w)
    })
}

/// A writer that checksums what it writes and pads sections.
struct Out<W: Write> {
    w: W,
    sum: Checksum,
    at: usize,
}

impl<W: Write> Out<W> {
    fn bytes(&mut self, b: &[u8]) -> io::Result<()> {
        self.sum.write(b);
        self.at += b.len();
        self.w.write_all(b)
    }

    fn pad_to(&mut self, target: usize) -> io::Result<()> {
        const Z: [u8; ALIGN] = [0; ALIGN];
        while self.at < target {
            let n = (target - self.at).min(ALIGN);
            self.bytes(&Z[..n])?;
        }
        Ok(())
    }
}

/// Reads one column of a chunk.
type Col32<'a> = &'a dyn Fn(&Chunk) -> &[u32];
type Col8<'a> = &'a dyn Fn(&Chunk) -> &[u8];

/// Writes `snap` to `path` atomically, with mode 0600.
pub(crate) fn write(path: &Path, snap: &Snapshot, event_id: u64) -> io::Result<()> {
    let n = snap.slots();
    // Global record offsets and name lengths: dead slots keep no record.
    let mut name_off = Vec::with_capacity(n);
    let mut name_len = Vec::with_capacity(n);
    let mut names_total = 0usize;
    for id in 0..n as EntryId {
        name_off.push(names_total as u32);
        if snap.flags_of(id) & flags::DEAD != 0 {
            name_len.push(0u8);
            continue;
        }
        let nl = snap.name_of(id).len();
        name_len.push(if nl < 255 { nl as u8 } else { 255 });
        names_total += snap.record_of(id).len();
    }
    if names_total > u32::MAX as usize {
        return Err(io::Error::other("names exceed 4 GiB"));
    }
    let root_bytes: usize = snap.roots.iter().map(|r| r.path.len()).sum();
    let lay =
        layout(n, snap.roots.len(), root_bytes, names_total).ok_or_else(|| io::Error::other("index too large"))?;

    let dir = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let tmp = dir.join(format!(
        ".{}.tmp-{}-{:x}",
        path.file_name().map_or_else(|| "index".into(), |n| n.to_string_lossy()),
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos() as u64)
    ));
    let file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
    let result = (|| -> io::Result<File> {
        let mut header = [0u8; HEADER];
        header[..8].copy_from_slice(&MAGIC);
        put32(&mut header, 8, VERSION);
        put32(&mut header, 12, HEADER as u32);
        put32(&mut header, 16, ORDER);
        put32(&mut header, 20, crate::store::CHUNK_BITS);
        put32(&mut header, 24, n as u32);
        put32(&mut header, 28, snap.len() as u32);
        put32(&mut header, 32, snap.roots.len() as u32);
        put64(&mut header, 40, names_total as u64);
        put64(&mut header, 48, (lay.end - HEADER) as u64);
        put64(&mut header, 56, snap.rules_hash);
        put64(&mut header, 64, event_id);
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        put64(&mut header, 72, now);
        let mut out = Out {
            w: BufWriter::with_capacity(1 << 20, file),
            sum: Checksum::new(),
            at: 0,
        };
        out.bytes(&header[..120])?;
        out.w.write_all(&[0u8; 8])?;
        out.at += 8;
        for r in snap.roots.iter() {
            out.bytes(&r.id.to_le_bytes())?;
            out.bytes(&(r.path.len() as u32).to_le_bytes())?;
        }
        for r in snap.roots.iter() {
            out.bytes(&r.path)?;
        }
        let cols32: [Col32; 7] = [
            &|c| c.parent.as_slice(),
            &|c| c.next.as_slice(),
            &|c| c.aux.as_slice(),
            &|c| c.mtime.as_slice(),
            &|c| c.name_off.as_slice(),
            &|c| c.mask.as_slice(),
            &|c| c.initials.as_slice(),
        ];
        for (k, col) in cols32.iter().enumerate() {
            out.pad_to(lay.u32s[k])?;
            if k == 4 {
                for &v in &name_off {
                    out.bytes(&u32::to_le_bytes(v))?;
                }
                continue;
            }
            for c in &snap.chunks {
                let mut buf = Vec::with_capacity(c.len() * 4);
                for &v in col(c) {
                    buf.extend_from_slice(&v.to_le_bytes());
                }
                out.bytes(&buf)?;
            }
        }
        out.pad_to(lay.ws)?;
        for c in &snap.chunks {
            let mut buf = Vec::with_capacity(c.len() * 8);
            for &v in c.ws.as_slice() {
                buf.extend_from_slice(&v.to_le_bytes());
            }
            out.bytes(&buf)?;
        }
        out.pad_to(lay.u8s[0])?;
        out.bytes(&name_len)?;
        let cols8: [Col8; 3] = [&|c| c.first.as_slice(), &|c| c.flags.as_slice(), &|c| {
            c.depth.as_slice()
        }];
        for (k, col) in cols8.iter().enumerate() {
            out.pad_to(lay.u8s[k + 1])?;
            for c in &snap.chunks {
                out.bytes(col(c))?;
            }
        }
        out.pad_to(lay.names)?;
        for id in 0..n as EntryId {
            if snap.flags_of(id) & flags::DEAD == 0 {
                out.bytes(snap.record_of(id))?;
            }
        }
        out.bytes(&[0u8; PAD])?;
        out.pad_to(lay.end)?;
        let sum = out.sum.finish();
        let mut file = out.w.into_inner().map_err(|e| e.into_error())?;
        file.seek(SeekFrom::Start(120))?;
        file.write_all(&sum.to_le_bytes())?;
        file.sync_all()?;
        Ok(file)
    })();
    match result {
        Ok(file) => {
            drop(file);
            std::fs::rename(&tmp, path).inspect_err(|_| {
                let _ = std::fs::remove_file(&tmp);
            })?;
            if let Ok(d) = File::open(dir) {
                let _ = d.sync_all();
            }
            Ok(())
        }
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            Err(e)
        }
    }
}

/// Opens and checks an index file. `fingerprint` must match the one it was saved with.
pub(crate) fn read(path: &Path, fingerprint: u64) -> Result<(Snapshot, FileMeta), LoadError> {
    let file = File::open(path)?;
    let size = file.metadata()?.len();
    if size < HEADER as u64 {
        return Err(LoadError::Corrupt("shorter than a header"));
    }
    let size = usize::try_from(size).map_err(|_| LoadError::Corrupt("too large"))?;
    let map = Arc::new(Map::new(&file, size)?);
    drop(file);
    let snap = check(&map, fingerprint)?;
    let b = map.bytes();
    let meta = FileMeta {
        event_id: get64(b, 64),
        saved_at: get64(b, 72),
        entries: snap.len(),
    };
    Ok((snap, meta))
}

/// Validates a mapped file and builds a snapshot that reads through it.
fn check(map: &Arc<Map>, fingerprint: u64) -> Result<Snapshot, LoadError> {
    let b = map.bytes();
    if b[..8] != MAGIC {
        return Err(LoadError::Corrupt("magic"));
    }
    let version = get32(b, 8);
    if version != VERSION {
        return Err(LoadError::Version(version));
    }
    if get32(b, 12) != HEADER as u32 || get32(b, 16) != ORDER || get32(b, 20) != crate::store::CHUNK_BITS {
        return Err(LoadError::Corrupt("header"));
    }
    let n = get32(b, 24) as usize;
    let live = get32(b, 28) as usize;
    let n_roots = get32(b, 32) as usize;
    let names_len = usize::try_from(get64(b, 40)).map_err(|_| LoadError::Corrupt("names size"))?;
    let body = usize::try_from(get64(b, 48)).map_err(|_| LoadError::Corrupt("body size"))?;
    if HEADER.checked_add(body) != Some(b.len()) || n_roots > n || live > n || names_len > b.len() {
        return Err(LoadError::Corrupt("sizes"));
    }
    // The checksum covers everything but itself.
    let mut sum = Checksum::new();
    sum.write(&b[..120]);
    sum.write(&b[HEADER..]);
    if sum.finish() != get64(b, 120) {
        return Err(LoadError::Corrupt("checksum"));
    }
    if get64(b, 56) != fingerprint {
        return Err(LoadError::Mismatch);
    }
    // Roots.
    let mut roots = Vec::with_capacity(n_roots);
    let mut root_bytes = 0usize;
    for i in 0..n_roots {
        let id = get32(b, HEADER + i * 8);
        let len = get32(b, HEADER + i * 8 + 4) as usize;
        roots.push((id, len));
        root_bytes = root_bytes.checked_add(len).ok_or(LoadError::Corrupt("roots"))?;
    }
    let lay = layout(n, n_roots, root_bytes, names_len).ok_or(LoadError::Corrupt("layout"))?;
    if lay.end != b.len() {
        return Err(LoadError::Corrupt("layout size"));
    }
    let mut at = HEADER + n_roots * 8;
    let mut root_list = Vec::with_capacity(n_roots);
    for (id, len) in roots {
        let p = b.get(at..at + len).ok_or(LoadError::Corrupt("root path"))?;
        at += len;
        if p.is_empty() || p[0] != b'/' || id as usize >= n {
            return Err(LoadError::Corrupt("root"));
        }
        root_list.push(Root { id, path: p.into() });
    }
    let col32 = |k: usize| map.typed::<u32>(lay.u32s[k], n).ok_or(LoadError::Corrupt("column"));
    let col8 = |k: usize| map.typed::<u8>(lay.u8s[k], n).ok_or(LoadError::Corrupt("column"));
    let parent = col32(0)?;
    let next = col32(1)?;
    let aux = col32(2)?;
    let name_off = col32(4)?;
    // Every column must read in full, so no slot of a chunk can be out of range.
    for k in [3, 5, 6] {
        col32(k)?;
    }
    let _ = map.typed::<u64>(lay.ws, n).ok_or(LoadError::Corrupt("column"))?;
    let name_len = col8(0)?;
    col8(1)?;
    let fl = col8(2)?;
    let depth = col8(3)?;
    let names = map
        .typed::<u8>(lay.names, names_len + PAD)
        .ok_or(LoadError::Corrupt("names"))?;
    if names[names_len..].iter().any(|&x| x != 0) {
        return Err(LoadError::Corrupt("padding"));
    }
    let mut live_count = 0usize;
    for id in 0..n {
        let f = fl[id];
        let p = parent[id];
        if f & flags::DEAD == 0 {
            live_count += 1;
        }
        if f & flags::ROOT != 0 {
            if p != NONE || depth[id] != 0 || !root_list.iter().any(|r| r.id as usize == id) {
                return Err(LoadError::Corrupt("root entry"));
            }
        } else {
            if p == NONE || p as usize >= id {
                return Err(LoadError::Corrupt("parent"));
            }
            if depth[id] != depth[p as usize].saturating_add(1) {
                return Err(LoadError::Corrupt("depth"));
            }
        }
        if next[id] != NONE && next[id] as usize >= n {
            return Err(LoadError::Corrupt("sibling"));
        }
        if f & flags::DIR != 0 && aux[id] != NONE && aux[id] as usize >= n {
            return Err(LoadError::Corrupt("child"));
        }
        let off = name_off[id] as usize;
        let read16 = |at: usize| -> Result<usize, LoadError> {
            match names.get(at..at + 2) {
                Some(b) if at + 2 <= names_len => Ok(u16::from_le_bytes([b[0], b[1]]) as usize),
                _ => Err(LoadError::Corrupt("name")),
            }
        };
        let mut end = match name_len[id] {
            255 => off + 2 + read16(off)?,
            l => off + l as usize,
        };
        if f & flags::DEAD == 0 && f & flags::MULTIBYTE != 0 {
            end += 2 + read16(end)?;
        }
        if end > names_len {
            return Err(LoadError::Corrupt("name"));
        }
    }
    if live_count != live {
        return Err(LoadError::Corrupt("live count"));
    }
    for r in &root_list {
        if fl[r.id as usize] & flags::ROOT == 0 {
            return Err(LoadError::Corrupt("root flag"));
        }
    }
    // Chunks that read through the mapping.
    let mut chunks = Vec::with_capacity(n.div_ceil(CHUNK));
    let mut start = 0usize;
    while start < n {
        let len = CHUNK.min(n - start);
        let c32 = |k: usize| Col::<u32>::mapped(map.clone(), lay.u32s[k] + start * 4, len);
        let c8 = |k: usize| Col::<u8>::mapped(map.clone(), lay.u8s[k] + start, len);
        chunks.push(Arc::new(Chunk {
            parent: c32(0),
            next: c32(1),
            aux: c32(2),
            mtime: c32(3),
            name_off: c32(4),
            mask: c32(5),
            initials: c32(6),
            ws: Col::mapped(map.clone(), lay.ws + start * 8, len),
            name_len: c8(0),
            first: c8(1),
            flags: c8(2),
            depth: c8(3),
            names: Col::mapped(map.clone(), lay.names, names_len + PAD),
            garbage: 0,
        }));
        start += len;
    }
    Ok(Snapshot {
        chunks,
        len: n as u32,
        live: live as u32,
        roots: root_list.into(),
        generation: 0,
        rules_hash: fingerprint,
    })
}

/// The checksum a file of these bytes should carry, for tests that build damaged files with a
/// valid checksum.
#[cfg(test)]
pub(crate) fn reseal(bytes: &mut [u8]) {
    let mut sum = Checksum::new();
    sum.write(&bytes[..120]);
    sum.write(&bytes[HEADER..]);
    let s = sum.finish();
    bytes[120..128].copy_from_slice(&s.to_le_bytes());
}
