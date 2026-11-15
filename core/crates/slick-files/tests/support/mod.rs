//! Temporary trees for the walker and update tests. Every tree lives under cargo's target
//! temporary folder, never the home folder, and is removed on drop.

#![allow(dead_code)]

use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

pub struct TempTree {
    pub root: PathBuf,
}

impl TempTree {
    pub fn new(tag: &str) -> TempTree {
        let base = PathBuf::from(env!("CARGO_TARGET_TMPDIR"));
        let root = base.join(format!("vf-{tag}-{}-{:x}", std::process::id(), fastrand::u64(..)));
        fs::create_dir_all(&root).expect("create temp tree");
        let root = fs::canonicalize(&root).expect("canonical root");
        TempTree { root }
    }

    pub fn path(&self, rel: &str) -> PathBuf {
        self.root.join(rel)
    }

    pub fn file(&self, rel: &str, bytes: usize) -> PathBuf {
        let p = self.path(rel);
        if let Some(d) = p.parent() {
            fs::create_dir_all(d).expect("mkdir");
        }
        fs::write(&p, vec![b'x'; bytes]).expect("write");
        p
    }

    pub fn dir(&self, rel: &str) -> PathBuf {
        let p = self.path(rel);
        fs::create_dir_all(&p).expect("mkdir");
        p
    }

    pub fn bytes(&self) -> Vec<u8> {
        self.root.as_os_str().as_bytes().to_vec()
    }
}

impl Drop for TempTree {
    fn drop(&mut self) {
        // Locked folders from permission tests must be opened again before removal.
        unlock_all(&self.root);
        let _ = fs::remove_dir_all(&self.root);
    }
}

pub fn unlock_all(root: &Path) {
    let mut stack = vec![root.to_path_buf()];
    while let Some(d) = stack.pop() {
        let _ = fs::set_permissions(&d, fs::Permissions::from_mode(0o755));
        if let Ok(rd) = fs::read_dir(&d) {
            for e in rd.flatten() {
                if e.file_type().is_ok_and(|t| t.is_dir()) {
                    stack.push(e.path());
                }
            }
        }
    }
}

pub fn set_mtime(p: &Path, secs_ago: u64) {
    let t = SystemTime::now() - Duration::from_secs(secs_ago);
    if let Ok(f) = fs::File::options().write(true).open(p) {
        let _ = f.set_modified(t);
    }
}

pub fn rel(root: &Path, p: &[u8]) -> String {
    let r = root.as_os_str().as_bytes();
    String::from_utf8_lossy(p.strip_prefix(r).unwrap_or(p)).into_owned()
}
