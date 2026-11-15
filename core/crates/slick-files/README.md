# slick-files

The launcher's own index of file names. Spotlight took 130 to 1,600 ms to return a first batch of name matches, with outliers past 8 s, so the launcher walks its roots itself, keeps a compact store in memory, and answers name queries in well under a millisecond. Content search stays with Spotlight.

The crate is pure Rust. `slick-ffi` will wrap it in a C ABI later; the API below is shaped for that.

## What it does

- **Walker.** Enumerates the caller's roots with `getattrlistbulk` on several threads. It applies the caller's rules, never follows a symbolic link, and keeps going through permission errors and files that vanish mid-walk.
- **Store.** 40 bytes of columns per entry plus the name. A path is rebuilt by walking parents.
- **Updates.** Takes FSEvents paths and flags and rescans only the folders they touch.
- **Search.** Name tiers from `slick-match`, a folder tier, extensions and path fragments, ranked by tier, then by recency, depth and kind. A bounded top k, narrowing as the query grows, and parallel parts on threads the caller owns.
- **Browse.** Lists a folder's children for queries that start with `/` or `~`.
- **Persistence.** One memory-mapped file with a versioned header and a checksum, written atomically.
- **Threads.** Readers take an immutable snapshot. The writer never blocks them for more than one pointer swap.

## Using it

```rust
use std::sync::Arc;
use slick_files::{Config, Event, FileIndex, Rayon, Rules, SearchOptions, Searcher};

// Build, or open the saved file and fall back to a build.
let config = Config::new(vec![home.join("Documents"), home.join("Projects")], Rules::recommended(Some(&home)));
let (index, meta, error) = FileIndex::open_or_build(&index_path, config);
// Resume the FSEvents stream from meta.event_id when the file opened.

// On a worker thread, per keystroke.
let mut searcher = Searcher::new(); // one per search field; call reset() when the panel opens
let mut hits = Vec::new();
let snap = index.snapshot();
let opts = SearchOptions { now: unix_now(), home: Some(home_bytes), ..SearchOptions::default() };
searcher.search(&snap, "docs readme", &opts, &Rayon, &mut hits);
for h in &hits {
    let path = snap.path(h.id);          // or path_to_slice into a caller buffer
    let mut ranges = Vec::new();
    searcher.highlight(h, "docs readme", &opts, &mut ranges); // visible rows only
}

// From the FSEvents callback, on the writer's queue.
index.apply(&[Event::new(changed_path, flags)]);

// Now and then, off the main thread.
index.save(&index_path, last_event_id)?;
```

Rules are the caller's: `Rules::recommended` skips hidden names, dependency and build folders such as `node_modules`, `.git`, `build` and `target`, the user's Library folder, and other volumes, and treats bundles such as `.app` and `.photoslibrary` as leaves. The app should add every folder extension that Launch Services declares as a package.

## Query language

| typed | finds |
|---|---|
| `readme` | names, by the `slick-match` tiers: exact, prefix, word-prefix, unordered, substring, subsequence, and typos when nothing matches well |
| `docs readme` | the same, and also `README.md` inside a folder whose name starts a word with `docs`, in the folder tier |
| `report pdf` | the same, and `report.pdf` ranked as if only `report` was typed against `report` |
| `.pdf` | every name whose extension starts with `pdf` |
| `report .pdf` | names with that extension whose stem matches `report` |
| `src/main` | names starting a word with `main` below a folder starting a word with `src` |
| `proj/src main` | `main` in a name, below `proj…/src…`, two folders right next to each other |
| `proj/` | everything below a folder starting with `proj`, shallow first |
| `~/Proj` or `/Users/x/Proj` | the children of that folder that match `Proj`; a trailing slash lists them all |

The parts of a path fragment are consecutive folders. A space allows gaps: `proj main` finds `projects/app/src/main.rs`. A token of ASCII punctuation alone, such as the `.` typed on the way to `.pdf`, is ignored.

## Ranking

A rank is one `i32`: `10,000 × tier + quality + lift`. Quality is 0 to 999 from `slick-match`. The lift is at most 8,000, so it never moves a hit into another tier.

| tier | name |
|---|---|
| 7 | exact |
| 6 | prefix |
| 5 | word-prefix |
| 4 | unordered |
| 3 | substring |
| 2 | folder: some tokens match the name, the others start words of folders above it |
| 1 | typo |
| 0 | subsequence |

The folder tier sits below every contiguous match on the name and above scattered ones. The lift adds up to 1,200 for recency, falling in log time from an hour to 17 years, up to 800 for shallow entries, and 400 for the kind the caller prefers. `RankParams` holds the constants. Equal ranks break by entry id, so the same query on the same snapshot always returns the same order.

## How search stays fast

1. **First stage.** Per chunk of 4,096 entries, a tight loop over the presence-mask column picks the candidates. Everything else is never touched.
2. **Prefix pass.** For one-token queries, only names whose first word starts with the query's first char can be prefix or exact matches. When `limit` of them land in those tiers, the search stops there.
3. **Strict pass.** `slick-match`'s NEON bit path classifies candidates. A running top k with a threshold shared by all parts skips entries that cannot enter it, using the tier floor, the name length, the word-initials mask and the lift.
4. **Folder memo.** Per search, each folder's bits record which tokens and path fragments it or a folder above it matches. Siblings share their parent's bits.
5. **Narrowing.** When the query grows by characters that are not spaces or slashes, only the previous matches are scored again. Typo matches narrow the same way.
6. **Typo pass.** Runs as `slick-match` does: four chars or more, and no hit at word-prefix or better. After a full scan it costs nothing extra, because the strict pass collects typo candidates until any part finds a strong hit.

`Searcher::search` takes a `ParallelFor`. `Serial` runs on the calling thread and `Rayon` on rayon's pool; the app can implement it over Grand Central Dispatch.

## Store layout

| column | bytes | meaning |
|---|---|---|
| parent | 4 | parent entry |
| next | 4 | next sibling |
| aux | 4 | a folder's first child, or a file's size, exact below 2 GiB and in MiB above |
| mtime | 4 | modification time, Unix seconds |
| name_off | 4 | offset of the name in the chunk's arena |
| mask | 4 | presence mask of the folded name, packed to 32 bits |
| initials | 4 | presence mask of the chars that start words |
| ws | 8 | word-start bits of the folded name |
| name_len, first, flags, depth | 4 | one byte each |
| name | n | the name; a name that does not fold byte for byte also keeps its folded form |

Entries are appended. A parent's id is always smaller than its children's. A deleted entry stays as a dead slot until the writer compacts, which it does when a quarter of the slots are dead.

## Threads

`FileIndex::snapshot` clones an `Arc` under a read lock, so readers never wait for each other. The writer works on a private copy that shares every chunk with the published snapshot. It copies a chunk only when it changes it, then swaps the pointer under the write lock. Searches never take a lock. Entry ids are only meaningful with the snapshot they came from, so keep the `Arc<Snapshot>` of a result list; `Searcher::snapshot` returns the one the last search used.

## Updates

| event | rescan |
|---|---|
| a path the index holds | its parent folder's listing, and the path itself when it is a folder |
| a path the index lacks | the deepest folder it holds; new folders are walked in full, which covers moved subtrees |
| `MustScanSubDirs`, `RootChanged` | the whole subtree below the path |
| `UserDropped`, `KernelDropped`, `EventIdsWrapped` | every root, from scratch |
| a skipped name or a package's direct child that came or went | only the facts of the folder that holds it |
| anything else below a skipped name, a hidden name or a package, or outside the roots | nothing |

A rescan compares one listing with the index by name and changes only what differs. Property tests check that after random creates, deletes, renames, moves, kind changes, links, permission changes and dependency churn, the index equals a fresh walk.

## Index file

One file: a 128-byte header with magic, format version, counts, a hash of the roots and rules, the FSEvents id the file is current to and a 64-bit checksum, then every column as one array, each on a 64-byte boundary, then the names. Section offsets follow from the counts. Opening maps the file, checks the size, the header and the checksum, then checks every parent, sibling, child and name offset. A damaged file, another version, or a file for other roots or rules is refused, and the caller builds a new index. The columns stay in the mapped file until the writer changes them. Files are written to a temporary name with mode 0600, synced, and renamed over the old one.

## Measured

Apple M5, macOS 27.2, release build, search threads at the user-interactive QoS class. Every tree was made under cargo's target temporary folder. Numbers are from `cargo bench -p slick-files --bench files`.

MEASURED_TABLES

## Limits

- The typo pass applies to queries without filters, folder tokens or fragments; the prefix pass to one-token queries.
- Narrowing does not cross a new token, so the first keystroke after a space is a full scan. With a one-char second token almost every name is a candidate; at 100,000 entries on one thread that keystroke is the slowest one.
- Queries where nothing matches well but much matches weakly, such as `rae`, classify every weak match, because the threshold stays in a low tier.
- A folder that becomes unreadable is noticed when it is listed itself. A folder-level FSEvents stream may report only its parent; file-level streams report the folder.
- A moved subtree is walked again rather than relinked. Moves of very large folders cost a walk.
- Entries deeper than 250 levels are not entered.
- The index file is mapped read-only. Another process that truncates it while it is mapped would crash the reader; the index itself only ever replaces the file by rename.
- Walking a privacy-protected folder such as Documents can raise a permission prompt for the app. Walk only after onboarding, on a background queue.
