//! Read-only memory maps of index files, and the typed views the store reads through.
//!
//! This module and `walk::bulk` hold the crate's only `unsafe` code.

use std::fs::File;
use std::io;
use std::os::fd::AsRawFd;
use std::ptr::NonNull;

/// Plain integer types that any bit pattern makes valid. Sealed: only the types below.
pub(crate) trait Pod: Copy + Default + Send + Sync + 'static + private::Sealed {}

mod private {
    pub trait Sealed {}
    impl Sealed for u8 {}
    impl Sealed for u16 {}
    impl Sealed for u32 {}
    impl Sealed for u64 {}
}

impl Pod for u8 {}
impl Pod for u16 {}
impl Pod for u32 {}
impl Pod for u64 {}

/// A read-only mapping of a whole file. It is unmapped when dropped.
pub(crate) struct Map {
    ptr: NonNull<u8>,
    len: usize,
}

// SAFETY: the mapping is read-only, mapped with PROT_READ, and this type never writes through it, so shared
// references to its bytes may cross threads like any `&[u8]`.
unsafe impl Send for Map {}
// SAFETY: as above; every access is a read.
unsafe impl Sync for Map {}

impl Map {
    /// Maps the first `len` bytes of `file` read-only. `len` must be the file's size.
    pub(crate) fn new(file: &File, len: usize) -> io::Result<Map> {
        if len == 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "empty file"));
        }
        // SAFETY: a fresh read-only private mapping of an open file descriptor. The kernel picks
        // the address. Nothing else aliases it, and `Drop` unmaps exactly this range.
        let p = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                len,
                libc::PROT_READ,
                libc::MAP_PRIVATE,
                file.as_raw_fd(),
                0,
            )
        };
        if p == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }
        let ptr = NonNull::new(p.cast::<u8>()).ok_or_else(|| io::Error::other("mmap returned null"))?;
        Ok(Map { ptr, len })
    }

    /// The mapped bytes.
    pub(crate) fn bytes(&self) -> &[u8] {
        // SAFETY: `ptr..ptr + len` is a live read-only mapping owned by `self`, and the returned
        // slice borrows `self`, so it cannot outlive the mapping.
        unsafe { std::slice::from_raw_parts(self.ptr.as_ptr(), self.len) }
    }

    /// `count` values of `T` starting at byte `off`, or `None` when the range leaves the mapping
    /// or `off` is not aligned for `T`.
    pub(crate) fn typed<T: Pod>(&self, off: usize, count: usize) -> Option<&[T]> {
        let size = count.checked_mul(size_of::<T>())?;
        let end = off.checked_add(size)?;
        if end > self.len || !(self.ptr.as_ptr() as usize + off).is_multiple_of(align_of::<T>()) {
            return None;
        }
        // SAFETY: the range is inside the mapping and its start is aligned for `T`, both checked
        // above. `T` is a plain integer type for which every bit pattern is valid, and
        // the slice borrows `self`, so it cannot outlive the mapping.
        Some(unsafe { std::slice::from_raw_parts(self.ptr.as_ptr().add(off).cast::<T>(), count) })
    }
}

impl Drop for Map {
    fn drop(&mut self) {
        // SAFETY: unmaps exactly the range `mmap` returned. Every view borrows `self`, so none is
        // alive here.
        unsafe {
            libc::munmap(self.ptr.as_ptr().cast(), self.len);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp_file(bytes: &[u8]) -> (std::path::PathBuf, File) {
        let dir = std::env::temp_dir().join(format!("slick-files-mmap-{}-{}", std::process::id(), fastrand::u64(..)));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("f");
        let mut f = File::create(&path).expect("create");
        f.write_all(bytes).expect("write");
        drop(f);
        (dir, File::open(&path).expect("open"))
    }

    #[test]
    fn maps_and_views_typed_ranges() {
        let bytes: Vec<u8> = (0u8..64).collect();
        let (dir, f) = temp_file(&bytes);
        let m = Map::new(&f, bytes.len()).expect("map");
        assert_eq!(m.bytes(), &bytes[..]);
        let words = m.typed::<u32>(4, 3).expect("aligned view");
        assert_eq!(words[0], u32::from_le_bytes([4, 5, 6, 7]));
        assert!(m.typed::<u32>(2, 1).is_none(), "misaligned start");
        assert!(m.typed::<u64>(56, 2).is_none(), "past the end");
        assert!(m.typed::<u64>(usize::MAX - 3, 1).is_none(), "overflow");
        assert_eq!(m.typed::<u8>(64, 0).map(<[u8]>::len), Some(0));
        drop(m);
        std::fs::remove_dir_all(dir).expect("cleanup");
    }

    #[test]
    fn refuses_an_empty_file() {
        let (dir, f) = temp_file(&[]);
        assert!(Map::new(&f, 0).is_err());
        std::fs::remove_dir_all(dir).expect("cleanup");
    }
}
