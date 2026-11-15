//! What the walker skips and where it stops.

use std::collections::HashSet;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// Exclusion rules, given by the caller.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Rules {
    /// Index dot names and names with the hidden flag. Off by default.
    pub include_hidden: bool,
    /// Names skipped wherever they appear, compared without ASCII case: `node_modules`, `.git`.
    pub skip_names: Vec<String>,
    /// Absolute paths skipped with everything below them: the user's Library folder.
    pub skip_paths: Vec<PathBuf>,
    /// Folders with these extensions are indexed but not entered: `app`, `photoslibrary`. The app
    /// should add every extension that Launch Services declares as a package.
    pub leaf_extensions: Vec<String>,
    /// Do not enter folders on another volume.
    pub one_filesystem: bool,
}

/// Folder names a launcher should never descend into: caches, dependency folders, build output.
pub const SKIP_NAMES: &[&str] = &[
    "node_modules",
    ".git",
    ".hg",
    ".svn",
    "DerivedData",
    "__pycache__",
    "Pods",
    "venv",
    ".venv",
    "site-packages",
    "target",
    "build",
    ".build",
    "Caches",
    ".cache",
    "bower_components",
    "vendor",
    ".Trash",
];

/// Folder extensions that are bundles or document packages.
pub const LEAF_EXTENSIONS: &[&str] = &[
    "app",
    "appex",
    "bundle",
    "framework",
    "plugin",
    "kext",
    "xpc",
    "prefpane",
    "saver",
    "qlgenerator",
    "mdimporter",
    "component",
    "photoslibrary",
    "photolibrary",
    "musiclibrary",
    "tvlibrary",
    "imovielibrary",
    "theater",
    "fcpbundle",
    "logicx",
    "band",
    "xcodeproj",
    "xcworkspace",
    "xcassets",
    "xcarchive",
    "playground",
    "docset",
    "pkg",
    "mpkg",
    "rtfd",
    "pages",
    "numbers",
    "key",
    "sparsebundle",
    "scptd",
    "workflow",
    "action",
    "textbundle",
];

impl Default for Rules {
    fn default() -> Self {
        Rules::recommended(None)
    }
}

impl Rules {
    /// The recommended rules: no hidden names, the folders in [`SKIP_NAMES`], the packages in
    /// [`LEAF_EXTENSIONS`], one volume, and `<home>/Library` when `home` is given.
    pub fn recommended(home: Option<&Path>) -> Rules {
        Rules {
            include_hidden: false,
            skip_names: SKIP_NAMES.iter().map(|s| s.to_string()).collect(),
            skip_paths: home.map(|h| vec![h.join("Library")]).unwrap_or_default(),
            leaf_extensions: LEAF_EXTENSIONS.iter().map(|s| s.to_string()).collect(),
            one_filesystem: true,
        }
    }

    /// Rules that skip nothing.
    pub fn everything() -> Rules {
        Rules {
            include_hidden: true,
            skip_names: Vec::new(),
            skip_paths: Vec::new(),
            leaf_extensions: Vec::new(),
            one_filesystem: false,
        }
    }

    pub(crate) fn compile(&self) -> Compiled {
        let paths: Vec<Vec<u8>> = self
            .skip_paths
            .iter()
            .map(|p| trim(p.as_os_str().as_bytes()).to_vec())
            .collect();
        Compiled {
            include_hidden: self.include_hidden,
            names: self
                .skip_names
                .iter()
                .map(|s| s.to_ascii_lowercase().into_bytes())
                .collect(),
            path_tails: paths
                .iter()
                .filter_map(|p| p.rsplit(|&b| b == b'/').next().map(|t| t.to_ascii_lowercase()))
                .collect(),
            paths,
            leaf: self
                .leaf_extensions
                .iter()
                .map(|s| s.trim_start_matches('.').to_ascii_lowercase().into_bytes())
                .collect(),
            one_filesystem: self.one_filesystem,
        }
    }

    /// A stable 64-bit hash of the rules, stored in index files.
    pub(crate) fn fingerprint(&self) -> u64 {
        let mut h = crate::hash::Fnv::new();
        h.write(&[u8::from(self.include_hidden), u8::from(self.one_filesystem)]);
        for group in [&self.skip_names, &self.leaf_extensions] {
            let mut v: Vec<&String> = group.iter().collect();
            v.sort();
            h.write(&(v.len() as u64).to_le_bytes());
            for s in v {
                h.write(&(s.len() as u64).to_le_bytes());
                h.write(s.as_bytes());
            }
        }
        let mut p: Vec<&[u8]> = self.skip_paths.iter().map(|p| p.as_os_str().as_bytes()).collect();
        p.sort();
        h.write(&(p.len() as u64).to_le_bytes());
        for s in p {
            h.write(&(s.len() as u64).to_le_bytes());
            h.write(s);
        }
        h.finish()
    }
}

fn trim(p: &[u8]) -> &[u8] {
    let mut end = p.len();
    while end > 1 && p[end - 1] == b'/' {
        end -= 1;
    }
    &p[..end]
}

/// Rules in the form the walker checks per entry.
#[derive(Clone, Debug, Default)]
pub(crate) struct Compiled {
    pub(crate) include_hidden: bool,
    names: HashSet<Vec<u8>>,
    paths: Vec<Vec<u8>>,
    path_tails: HashSet<Vec<u8>>,
    leaf: HashSet<Vec<u8>>,
    pub(crate) one_filesystem: bool,
}

impl Compiled {
    /// True when the entry `name` in folder `dir` is not indexed at all.
    pub(crate) fn skips(&self, dir: &[u8], name: &[u8], hidden: bool) -> bool {
        if hidden && !self.include_hidden {
            return true;
        }
        let lower = name.to_ascii_lowercase();
        if self.names.contains(&lower) {
            return true;
        }
        if self.path_tails.contains(&lower) {
            let mut full = trim(dir).to_vec();
            if full.last() != Some(&b'/') {
                full.push(b'/');
            }
            full.extend_from_slice(name);
            if self.paths.iter().any(|p| p.eq_ignore_ascii_case(&full)) {
                return true;
            }
        }
        false
    }

    /// True when a folder with this name is indexed but not entered.
    pub(crate) fn is_leaf(&self, name: &[u8]) -> bool {
        match crate::names::stem_len(name) {
            Some(s) => self.leaf.contains(&name[s + 1..].to_ascii_lowercase()),
            None => false,
        }
    }

    /// True when a walk of `root` enters the folder at `dir`, a path below it: no component on the
    /// way is skipped, hidden or a package, and `dir` itself is not skipped. A package at `dir`
    /// counts as entered, because the walk indexes it as one item.
    pub(crate) fn enters(&self, root: &[u8], dir: &[u8]) -> bool {
        self.route(root, dir) == Route::Index
    }

    /// What an event at `path` below `root` can change.
    pub(crate) fn route(&self, root: &[u8], path: &[u8]) -> Route {
        let root = trim(root);
        let Some(rest) = path.strip_prefix(root) else {
            return Route::Ignore;
        };
        let comps: Vec<&[u8]> = rest.split(|&b| b == b'/').filter(|c| !c.is_empty()).collect();
        let mut dir = root.to_vec();
        for (i, c) in comps.iter().enumerate() {
            let last = i + 1 == comps.len();
            let hidden = c.first() == Some(&b'.');
            if self.skips(&dir, c, hidden) {
                // The skipped entry itself came or went: its folder's time changed.
                return if last { Route::Refresh(dir.len()) } else { Route::Ignore };
            }
            if dir.last() != Some(&b'/') {
                dir.push(b'/');
            }
            dir.extend_from_slice(c);
            if !last && self.is_leaf(c) {
                // Inside a package: only a direct child changes the package's own time.
                return if i + 2 == comps.len() {
                    Route::Refresh(dir.len())
                } else {
                    Route::Ignore
                };
            }
        }
        Route::Index
    }
}

/// What an event can change.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Route {
    /// Nothing the index holds.
    Ignore,
    /// Only the facts of the entry at the first `n` bytes of the path, when the event changed
    /// the folder's structure.
    Refresh(usize),
    /// Entries the index holds.
    Index,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skips_names_paths_hidden_and_stops_at_leaves() {
        let r = Rules::recommended(Some(Path::new("/home/someone"))).compile();
        assert!(r.skips(b"/x", b"node_modules", false));
        assert!(r.skips(b"/x", b"Node_Modules", false));
        assert!(r.skips(b"/x", b".zshrc", true));
        assert!(r.skips(b"/home/someone", b"Library", false));
        assert!(!r.skips(b"/home/someone/proj", b"Library", false));
        assert!(!r.skips(b"/x", b"notes.md", false));
        assert!(r.is_leaf(b"Editor.app"));
        assert!(r.is_leaf(b"Shots.PhotosLibrary"));
        assert!(!r.is_leaf(b"src"));
        let h = b"/home/someone";
        assert_eq!(r.route(h, b"/home/someone/p/node_modules/x/y.js"), Route::Ignore);
        assert_eq!(r.route(h, b"/home/someone/p/node_modules"), Route::Refresh(h.len() + 2));
        assert_eq!(r.route(h, b"/home/someone/Editor.app/Contents/x"), Route::Ignore);
        assert_eq!(
            r.route(h, b"/home/someone/Editor.app/Contents"),
            Route::Refresh(h.len() + 11)
        );
        assert_eq!(r.route(h, b"/home/someone/Editor.app"), Route::Index);
        assert_eq!(r.route(h, b"/home/someone/p/notes.md"), Route::Index);
        assert_eq!(r.route(h, b"/home/someone/.DS_Store"), Route::Refresh(h.len()));
        assert_eq!(r.route(h, b"/elsewhere/x"), Route::Ignore);
    }

    #[test]
    fn fingerprints_ignore_order_but_not_content() {
        let a = Rules::recommended(None);
        let mut b = a.clone();
        b.skip_names.reverse();
        assert_eq!(a.fingerprint(), b.fingerprint());
        b.include_hidden = true;
        assert_ne!(a.fingerprint(), b.fingerprint());
    }
}
