//! `getattrlistbulk`: one system call returns the names and attributes of many directory
//! entries, so the walker never calls `lstat` per file.
//!
//! The call itself is the only `unsafe` code here. The buffer it fills is parsed by safe code that
//! checks every offset, and the tests feed that parser damaged buffers.

use std::fs::File;
use std::io;
use std::ops::Range;
use std::os::fd::AsRawFd;

/// `ATTR_CMN_ERROR`, which the libc crate does not define.
const ATTR_CMN_ERROR: u32 = 0x2000_0000;
/// `fsobj_type_t` values (`enum vtype`).
const VREG: u32 = 1;
const VDIR: u32 = 2;
const VLNK: u32 = 5;

/// What kind of object an entry is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Kind {
    File,
    Dir,
    Symlink,
    /// Sockets, FIFOs, devices. Indexed like files.
    Other,
}

/// One parsed entry. `name` indexes the names buffer passed to [`parse`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Raw {
    pub(crate) name: Range<usize>,
    pub(crate) kind: Kind,
    /// The `UF_HIDDEN` flag.
    pub(crate) hidden_flag: bool,
    pub(crate) mtime: u32,
    pub(crate) size: u64,
}

/// A malformed buffer.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Malformed;

fn u32_at(b: &[u8], at: usize) -> Result<u32, Malformed> {
    let s = b.get(at..at.checked_add(4).ok_or(Malformed)?).ok_or(Malformed)?;
    Ok(u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
}

fn i64_at(b: &[u8], at: usize) -> Result<i64, Malformed> {
    let s = b.get(at..at.checked_add(8).ok_or(Malformed)?).ok_or(Malformed)?;
    let mut w = [0u8; 8];
    w.copy_from_slice(s);
    Ok(i64::from_le_bytes(w))
}

/// The attributes the walker asks for.
fn attr_list() -> libc::attrlist {
    libc::attrlist {
        bitmapcount: libc::ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: libc::ATTR_CMN_RETURNED_ATTRS
            | ATTR_CMN_ERROR
            | libc::ATTR_CMN_NAME
            | libc::ATTR_CMN_OBJTYPE
            | libc::ATTR_CMN_MODTIME
            | libc::ATTR_CMN_FLAGS,
        volattr: 0,
        dirattr: 0,
        fileattr: libc::ATTR_FILE_DATALENGTH,
        forkattr: 0,
    }
}

/// Reads every entry of the open directory `dir`, appending names to `names` and entries to
/// `out`. `buf` is scratch space for the kernel; 64 KiB or more is a good size.
pub(crate) fn read_all(dir: &File, buf: &mut Vec<u8>, names: &mut Vec<u8>, out: &mut Vec<Raw>) -> io::Result<()> {
    if buf.len() < 16 * 1024 {
        buf.resize(64 * 1024, 0);
    }
    let mut list = attr_list();
    loop {
        // SAFETY: `dir` is an open file descriptor that outlives the call. `list` is a valid
        // `attrlist` on the stack, and `buf` is `buf.len()` writable bytes; the kernel writes at
        // most that many. Nothing else holds a reference to either while the call runs.
        let n = unsafe {
            libc::getattrlistbulk(
                dir.as_raw_fd(),
                (&mut list as *mut libc::attrlist).cast(),
                buf.as_mut_ptr().cast(),
                buf.len(),
                0,
            )
        };
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(e);
        }
        if n == 0 {
            return Ok(());
        }
        parse(buf, n as usize, names, out)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "bad getattrlistbulk"))?;
    }
}

/// Parses `count` entries from a `getattrlistbulk` buffer. Entries without a usable name, and
/// `.` and `..`, are skipped. A malformed buffer stops the parse with an error; the entries before
/// it are kept.
pub(crate) fn parse(buf: &[u8], count: usize, names: &mut Vec<u8>, out: &mut Vec<Raw>) -> Result<(), Malformed> {
    let mut at = 0usize;
    for _ in 0..count {
        let len = u32_at(buf, at)? as usize;
        let end = at.checked_add(len).ok_or(Malformed)?;
        if len < 24 || end > buf.len() {
            return Err(Malformed);
        }
        let e = &buf[at..end];
        at = end;
        let common = u32_at(e, 4)?;
        let file = u32_at(e, 4 + 12)?;
        let mut p = 4 + 20;
        if common & ATTR_CMN_ERROR != 0 {
            p += 4;
        }
        let mut name: Option<Range<usize>> = None;
        if common & libc::ATTR_CMN_NAME != 0 {
            let off = u32_at(e, p)? as i32 as i64;
            let nlen = u32_at(e, p + 4)? as i64;
            let start = p as i64 + off;
            let stop = start + nlen;
            if start < 0 || nlen < 0 || stop > e.len() as i64 {
                return Err(Malformed);
            }
            let mut bytes = &e[start as usize..stop as usize];
            while let [rest @ .., 0] = bytes {
                bytes = rest;
            }
            if !bytes.is_empty() && bytes != b"." && bytes != b".." && !bytes.contains(&b'/') && !bytes.contains(&0) {
                let s = names.len();
                names.extend_from_slice(bytes);
                name = Some(s..names.len());
            }
            p += 8;
        }
        let mut kind = Kind::Other;
        if common & libc::ATTR_CMN_OBJTYPE != 0 {
            kind = match u32_at(e, p)? {
                VREG => Kind::File,
                VDIR => Kind::Dir,
                VLNK => Kind::Symlink,
                _ => Kind::Other,
            };
            p += 4;
        }
        let mut mtime = 0u32;
        if common & libc::ATTR_CMN_MODTIME != 0 {
            mtime = i64_at(e, p)?.clamp(0, u32::MAX as i64) as u32;
            p += 16;
        }
        let mut hidden_flag = false;
        if common & libc::ATTR_CMN_FLAGS != 0 {
            hidden_flag = u32_at(e, p)? & libc::UF_HIDDEN != 0;
            p += 4;
        }
        let mut size = 0u64;
        if file & libc::ATTR_FILE_DATALENGTH != 0 {
            size = i64_at(e, p)?.max(0) as u64;
        }
        if let Some(name) = name {
            out.push(Raw {
                name,
                kind,
                hidden_flag,
                mtime,
                size,
            });
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds one entry the way the kernel lays it out.
    fn entry(name: &[u8], objtype: u32, mtime: i64, flags: u32, size: Option<i64>) -> Vec<u8> {
        let mut body = Vec::new();
        let common = libc::ATTR_CMN_RETURNED_ATTRS
            | ATTR_CMN_ERROR
            | libc::ATTR_CMN_NAME
            | libc::ATTR_CMN_OBJTYPE
            | libc::ATTR_CMN_MODTIME
            | libc::ATTR_CMN_FLAGS;
        let file = if size.is_some() { libc::ATTR_FILE_DATALENGTH } else { 0 };
        for v in [common, 0, 0, file, 0] {
            body.extend_from_slice(&v.to_le_bytes());
        }
        body.extend_from_slice(&0u32.to_le_bytes()); // error
        let name_ref_at = 4 + body.len();
        let fixed_after_ref = 4 + 16 + 4 + size.map_or(0, |_| 8);
        let name_off = 8 + fixed_after_ref;
        body.extend_from_slice(&(name_off as u32).to_le_bytes());
        body.extend_from_slice(&((name.len() + 1) as u32).to_le_bytes());
        body.extend_from_slice(&objtype.to_le_bytes());
        body.extend_from_slice(&mtime.to_le_bytes());
        body.extend_from_slice(&0i64.to_le_bytes());
        body.extend_from_slice(&flags.to_le_bytes());
        if let Some(s) = size {
            body.extend_from_slice(&s.to_le_bytes());
        }
        assert_eq!(4 + body.len(), name_ref_at + name_off);
        body.extend_from_slice(name);
        body.push(0);
        while (body.len() + 4) % 4 != 0 {
            body.push(0);
        }
        let mut out = ((body.len() + 4) as u32).to_le_bytes().to_vec();
        out.extend_from_slice(&body);
        out
    }

    #[test]
    fn parses_what_the_kernel_writes() {
        let mut buf = entry(b"notes.md", VREG, 1_700_000_000, 0, Some(42));
        buf.extend(entry(b"src", VDIR, 5, libc::UF_HIDDEN, None));
        buf.extend(entry(b"link", VLNK, -3, 0, None));
        buf.extend(entry(b".", VDIR, 0, 0, None));
        let mut names = Vec::new();
        let mut out = Vec::new();
        parse(&buf, 4, &mut names, &mut out).expect("parse");
        assert_eq!(out.len(), 3);
        assert_eq!(&names[out[0].name.clone()], b"notes.md");
        assert_eq!(
            (out[0].kind, out[0].mtime, out[0].size),
            (Kind::File, 1_700_000_000, 42)
        );
        assert_eq!((out[1].kind, out[1].hidden_flag), (Kind::Dir, true));
        assert_eq!((out[2].kind, out[2].mtime), (Kind::Symlink, 0));
    }

    #[test]
    fn damaged_buffers_are_errors_not_panics() {
        let good = entry(b"report.pdf", VREG, 9, 0, Some(1));
        let mut rng = fastrand::Rng::with_seed(11);
        for _ in 0..20_000 {
            let mut b = good.clone();
            match rng.u8(0..4) {
                0 => {
                    let i = rng.usize(..b.len());
                    b[i] = rng.u8(..);
                }
                1 => b.truncate(rng.usize(..b.len())),
                2 => {
                    let i = rng.usize(..b.len().saturating_sub(4));
                    b[i..i + 4].copy_from_slice(&rng.u32(..).to_le_bytes());
                }
                _ => b.extend((0..rng.usize(0..40)).map(|_| rng.u8(..))),
            }
            let mut names = Vec::new();
            let mut out = Vec::new();
            let _ = parse(&b, rng.usize(0..4), &mut names, &mut out);
            for r in &out {
                assert!(r.name.end <= names.len());
            }
        }
    }

    #[test]
    fn reads_a_real_folder_like_read_dir() {
        let dir = std::env::temp_dir().join(format!("slick-files-bulk-{}-{}", std::process::id(), fastrand::u64(..)));
        std::fs::create_dir_all(dir.join("sub")).expect("mkdir");
        for i in 0..300 {
            std::fs::write(dir.join(format!("file-{i:03}.txt")), vec![b'x'; i]).expect("write");
        }
        std::os::unix::fs::symlink("/nonexistent-target", dir.join("dangling")).expect("symlink");
        let f = File::open(&dir).expect("open");
        let mut buf = vec![0u8; 16 * 1024];
        let mut names = Vec::new();
        let mut out = Vec::new();
        read_all(&f, &mut buf, &mut names, &mut out).expect("read");
        let mut got: Vec<(String, Kind, u64)> = out
            .iter()
            .map(|r| {
                let size = if r.kind == Kind::File { r.size } else { 0 };
                (
                    String::from_utf8_lossy(&names[r.name.clone()]).into_owned(),
                    r.kind,
                    size,
                )
            })
            .collect();
        got.sort_by(|a, b| a.0.cmp(&b.0));
        let mut want: Vec<(String, Kind, u64)> = std::fs::read_dir(&dir)
            .expect("read_dir")
            .map(|e| {
                let e = e.expect("entry");
                let m = e.path().symlink_metadata().expect("lstat");
                let kind = if m.file_type().is_symlink() {
                    Kind::Symlink
                } else if m.is_dir() {
                    Kind::Dir
                } else {
                    Kind::File
                };
                let size = if kind == Kind::File { m.len() } else { 0 };
                (e.file_name().to_string_lossy().into_owned(), kind, size)
            })
            .collect();
        want.sort_by(|a, b| a.0.cmp(&b.0));
        assert_eq!(got, want);
        std::fs::remove_dir_all(&dir).expect("cleanup");
    }
}
