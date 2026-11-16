# Contributing

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first. It is the contract: the layout, the
dependency rules between packages, the ranking contract, the latency and glass rules, and the rules
for working on a Mac someone is using. If your change and that document disagree, fix one of them
in the same change.

## Make targets

| Target | What it does |
|---|---|
| `make bootstrap` | Check toolchains, build the Rust core, resolve the Swift packages |
| `make core` | Rebuild the Rust static library and its C header |
| `make app` | Build and bundle `build/<name>.app`. `CONFIG=debug` for a debug build |
| `make run` | Build, then launch through LaunchServices. For people, not agents |
| `make selftest` | Build, then run `--selftest` directly and through LaunchServices |
| `make test` | Every Rust and Swift test. `make -j4 test` runs them in parallel |
| `make test-rust` | Every Rust test, ended after `RUST_TEST_TIMEOUT` seconds, 900 by default, so a hung test fails the run |
| `make test-<Pkg>` | One Swift package's tests, for example `make test-Kit` |
| `make test-scripts` | The tests of the install, showcase, bundle and time limit scripts, in a temporary folder |
| `make bench` | Latency tables from the app bundle. `NAME=<bench>` picks one |
| `make scenario S=<file>` | A scripted UI run |
| `make lint` | rustfmt, clippy, `swift format`, the manifest check, the brand check and the LaunchServices check |
| `make fmt` | Format Rust and Swift sources in place |
| `make xcode` | Generate the optional Xcode project with XcodeGen |
| `make clean` | Remove every build output |

An area that needs its own targets adds them to its file in `mk/`. The Makefile includes every
`mk/*.mk`, so nobody has to edit the shared Makefile. `make help` lists them all.

These targets change the Mac, the keychain or the public repository, so only a person runs them,
by hand:

| Target | What it does |
|---|---|
| `make install` | Build the release app and copy it to `/Applications`, or `INSTALL_DIR` |
| `make uninstall` | Remove the installed app |
| `make release VERSION=<x.y.z>` | Build, sign with Developer ID, notarize and staple a release into `dist/`, and sign its update with the update key |
| `make release-publish VERSION=<x.y.z>` | Tag, push the tag and draft the GitHub release from `dist/`, with its update feed |
| `make update-key` | Make the key that signs updates in the login keychain, or print its public key |

Agents never run any of them, nor `make run` or anything else that starts the launcher on the
desktop. An agent may run `make release-dry-run`, which builds the release and signs it ad hoc in
a temporary folder, without the notary service, and shows nothing. [docs/RELEASING.md](docs/RELEASING.md)
covers all of them.

## Working in one package

Every Swift package builds and tests on its own, in its own build directory:

```
scripts/swiftpm.sh Packages/Host test
```

That compiles only the package and its dependencies, so a broken package elsewhere does not stop
you, and two people in different packages never wait on the same lock. Two people in the same
package should each pass their own `--scratch-path`.

For the Rust core, `scripts/cargo.sh test -p slick-match` runs one crate with the pinned toolchain.

## Rules of thumb

- New code goes in a new file. Shared files change one line at a time.
- Swift: tools version 6.2, Swift 6 mode, zero warnings. CI builds with warnings as errors. Pure
  logic is `nonisolated`; background work is `@concurrent nonisolated`. Tests use Swift Testing.
- macOS 27 API goes behind `if #available(macOS 27, *)`. The deployment target is macOS 26, so the
  compiler rejects an unguarded call.
- Rust: `make lint` must pass, which means rustfmt and clippy with `-D warnings`. No `unwrap` or
  `expect` on fallible paths in library code. Every `unsafe` block carries a `// SAFETY:` comment.
- A new C function goes in the matching module of `core/crates/slick-ffi/src`, follows the
  conventions at the top of its `lib.rs`, and gets a Swift wrapper in `Packages/CoreBridge`. Run
  `make core` and commit the regenerated header.
- The product name, bundle identifier, data folder and URL scheme live only in `support/brand.env`
  and `Packages/Kit/Sources/Kit/Brand.swift`. `make lint` fails if they appear anywhere else.
- Only `Packages/Updates` imports Sparkle, the one remote dependency. Code elsewhere reaches the
  updater through KitHosting's `UpdateControl`. Never start Sparkle's updater outside the live
  launcher, and never give a test a bundle with a feed.
- Tests and fixtures use synthetic data only: no real file names, paths, clipboard contents or
  contacts.

## Signing and permissions

`make app` signs with your Apple Development identity when the keychain has one, and ad hoc
otherwise. macOS keeps permission grants such as Accessibility only while each new build satisfies
the code requirement of the build that was granted. An Apple Development signature does; an ad hoc
signature does not, so without a certificate you grant permissions again after every rebuild.
Grants are also tied to the bundle identifier, and a Developer ID release build has a different
requirement, so moving from development builds to a release build asks once more.

`make app` signs `Sparkle.framework` and its helpers with the same identity as the app. An ad hoc
build also carries `com.apple.security.cs.disable-library-validation`, because library validation
under the hardened runtime refuses ad hoc code from another file. With it off, any program running
as you could swap the framework and run with the build's permission grants. So do not give an ad
hoc build Accessibility or Input Monitoring for daily use: use an Apple Development identity. The
bundle step says when a build is ad hoc. A build from source has no update feed, so it never offers
to update itself. Pull and build again instead.
