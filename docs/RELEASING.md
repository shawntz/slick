# Releases

Versions are `X.Y.Z`. Changes that people will notice go under `## Unreleased` in `CHANGELOG.md` as
they land. While the major version is 0, every release is a GitHub pre-release.

A release takes two commands, with a stop after each for you to look:

```sh
NOTARYTOOL_PROFILE=slick-notary make release VERSION=0.1.0   # build, sign, notarize and staple into dist/
make release-publish VERSION=0.1.0                            # tag, push the tag, draft the release, write the cask
```

The first publishes nothing. The second leaves the release as a draft and never touches the
Homebrew tap. You publish the draft and update the tap yourself, with commands it prints. Splay does
all of this in one script. Slick stops twice, because a published version can never be replaced.

To run Slick every day from your own checkout without a release, see
[Install from a checkout](#install-from-a-checkout) at the end.

Agents never run `make release`, `make release-publish`, `make install` or `make uninstall`. Each
one changes your Mac, your keychain or the public repository. An agent may run
`make release-dry-run`, which builds and signs ad hoc in a temporary folder and shows nothing.

## One-time setup

Do these once, before the first release.

1. The Developer ID Application certificate and its private key are in the login keychain. This
   lists it, and reads no key:

   ```sh
   security find-identity -v -p codesigning
   ```

   The list must hold a line with `"Developer ID Application: `. If it holds two, set
   `DEVELOPER_ID_APPLICATION` to the 40-character hash of the one to use.
2. A notarytool profile is in the keychain. This guide names it `slick-notary`, the profile the
   maintainer stored. A profile belongs to the team, not to one app, so one made for another app
   works too: use its name wherever this guide says `slick-notary`. Without one, make one. It asks
   for an app-specific password from account.apple.com:

   ```sh
   xcrun notarytool store-credentials slick-notary --apple-id <Apple ID> --team-id <team ID>
   ```

3. `gh` is signed in. `gh auth status` says so, and `gh auth login` signs in.
4. Your SSH key can push to the tap, the public repository
   [shawntz/homebrew-tap](https://github.com/shawntz/homebrew-tap). `ssh -T git@github.com` greets
   you by name.
5. Private vulnerability reporting is on, because `SECURITY.md` sends reports there. Turn it on in
   the repository's settings, under Code security.
6. The cask's homepage, https://slick.computer/, loads. The cask installs without it, but
   `brew home slick` and `brew audit --online` fail until it does.

## Cut a release

These are the steps for 0.1.0, in order. For a later version, change the number everywhere.

1. Commit and push to `main` everything that belongs in the release. For the first release, that
   includes the release files themselves, such as `scripts/release.sh` and this guide. Then release
   from a fresh clone, so nothing uncommitted can slip in. A fresh clone is also a full clone, and
   the build number counts commits:

   ```sh
   git clone https://github.com/shawntz/slick.git ~/Developer/slick-release
   cd ~/Developer/slick-release
   ```

   For a later release, reuse that clone: `cd ~/Developer/slick-release && git switch main && git pull --ff-only`.
2. Run the checks that `make release` does not run:

   ```sh
   make lint && make -j4 test
   ```

3. In `CHANGELOG.md`, change the heading `## Unreleased` to `## 0.1.0`. Add a new, empty
   `## Unreleased` above it. The notes under `## 0.1.0` become the release notes. Then:

   ```sh
   git add CHANGELOG.md && git commit -m "Release 0.1.0" && git push origin main
   ```

4. Rehearse. The dry run is the same script without the Developer ID key or the notary service,
   and takes one to two minutes on this M5:

   ```sh
   make release-dry-run VERSION=0.1.0
   ```

   It must end with `dry run of 0.1.0 passed` and print no line that says `a release would stop
   here`. Fix each such line first.
5. Build the release:

   ```sh
   NOTARYTOOL_PROFILE=slick-notary make release VERSION=0.1.0
   ```

   macOS may ask once whether `codesign` may use the Developer ID key. Enter your login password
   and choose Always Allow. Then the script sends the app to Apple and waits, usually a few
   minutes, and prints nothing while it waits. It ends with a list of what is in `dist/`.
6. Check `dist/` as [Before you publish](#before-you-publish) says.
7. Draft the GitHub release:

   ```sh
   make release-publish VERSION=0.1.0
   ```

8. Look at the draft, its notes and its three files:

   ```sh
   gh release view v0.1.0 --repo shawntz/slick --web
   ```

9. Publish it. From here on, version 0.1.0 is spent:

   ```sh
   gh release edit v0.1.0 --repo shawntz/slick --draft=false
   ```

10. Put the cask in the tap with the two commands step 7 printed, in the same terminal. The first
    downloads the public zip and goes on only when its SHA-256 matches `dist/`. It prints
    `?? Casks/slick.rb` for the first release. The second commits and pushes.
11. Check it as a user would:

    ```sh
    brew update
    brew install --cask shawntz/tap/slick
    brew audit --cask --online shawntz/tap/slick
    brew livecheck shawntz/tap/slick
    ```

    `brew livecheck` should show 0.1.0 on both sides of its arrow.

## When a step fails

Every message starts with the script's name and says what to do. Nothing is published until step
7, and nothing is public until step 9.

| Where it stops | What it leaves | What to do |
| --- | --- | --- |
| A refusal in step 5 | Nothing | Fix what it names, then run step 5 again. |
| Build, bundle or signing | The partial build in `dist/` | Fix the cause, commit and push, then run step 5 again. It starts `dist/` over. |
| Notarization rejected | `dist/notary.json` and `dist/notary-log.json`, with each problem printed | As above. |
| Stapling, after 5 tries over 2 minutes | The notarized but unstapled build in `dist/` | Wait, then run step 5 again. It builds and notarizes again. |
| The last check | A `dist/` that `make release-publish` refuses | As for a build failure. |
| Step 7, part way | Maybe a tag on GitHub, maybe a draft | Run step 7 again. It reuses a matching tag and draft. |
| Step 10, first command | Nothing in the tap | The release is not published yet, or its zip differs from `dist/`. Look at the release page. |

To stop the notary wait, press Ctrl-C. Apple keeps working on the submission. A later run sends a
new one.

## What make release does

`scripts/release.sh` refuses to start on a tree with changes, on a shallow clone, off `main`, when
`HEAD` is not `origin/main` as last fetched or pushed, on a version that is not higher than the last
`vX.Y.Z` tag, on a `CHANGELOG.md` without a `## X.Y.Z` section, and without `NOTARYTOOL_PROFILE`.
It signs with the one Developer ID Application identity in the keychain, or the one that
`DEVELOPER_ID_APPLICATION` names. Then it:

- deletes `dist/` and builds the Rust core and the app in release configuration from nothing, in
  `dist/build`, so a copy of the app running from `build/` keeps running
- bundles the app with `scripts/bundle.sh`, with the version you gave and the build number, strips
  the executable and keeps the dSYM beside the bundle
- puts `THIRD-PARTY-NOTICES.md` in `Contents/Resources`, after checking that it lists the crates
  this build links
- signs every nested piece of code, deepest first, then the bundle, each with the hardened runtime
  and a secure timestamp, and the bundle with `support/release.entitlements`. Today the bundle has
  one piece of code, its executable, with the Rust library linked in.
- verifies the signature strictly, zips the bundle with `ditto`, sends the zip to the notary
  service and waits for the verdict
- staples the ticket to the bundle, trying for about two minutes while Apple publishes it, and asks
  Gatekeeper about it with `spctl`
- zips the stapled bundle again, as the file to publish, and zips the dSYM
- writes `SHA256SUMS.txt`, `release-notes.md` from the changelog, and `release.env`, which the
  publish step reads
- unpacks the zip it is about to ship and checks it with `scripts/check-release.sh`, then marks
  `release.env` complete

The build number is the number of commits in `HEAD`'s history, so each release has a higher one
than the last. `dist/` holds its own `.gitignore`, so git never lists it.

## What make release-publish does

`scripts/release-publish.sh` checks `dist/` again: a complete, real release of this version, built
from `HEAD` on a clean tree, with every file intact. It checks that `HEAD` is on `origin/main` and
that `gh` is signed in. Then it:

- writes the cask to `dist/slick.rb` from `support/homebrew/slick.rb.in`, with the version and the
  zip's SHA-256
- tags `HEAD` as `vX.Y.Z` and pushes the tag
- creates the GitHub release as a draft, marked as a pre-release while the major version is 0, with
  the zip, the dSYM zip and `SHA256SUMS.txt`
- prints the commands that publish the draft and update the tap

It never replaces a release that is already published. `RELEASE_PRERELEASE=0` or `1` overrides the
pre-release mark.

## Dry run

```sh
make release-dry-run                  # version 0.0.0, into a temporary folder that is removed after
make release-dry-run VERSION=0.1.0    # the same for the version you are about to release
make release-dry-run OUT=build/dry    # keeps the result in build/dry
```

The dry run is the same script with three steps switched off. It signs ad hoc instead of with
Developer ID, and it skips notarization and stapling. So it needs no credentials, never touches the
Developer ID key and never contacts the notary service. The checks that stop a release only warn,
so it runs on a tree with changes too. Then `scripts/check-release.sh` checks every artifact: the
zip unpacks to a bundle that passes strict signature verification, `Info.plist` carries the
version, the checksums match, the dSYM matches the executable, and the cask renders and parses as
Ruby. It needs Ruby and Python 3 on the path, as the release does. `OUT` must name a new or empty
folder, or one an earlier dry run wrote.

CI runs `make release-dry-run` after the tests on every push to main and every pull request, so a
change that breaks the release pipeline fails there, not on release day.

## Before you publish

`make release` has checked the signature, the ticket, the checksums and the cask. These checks need
a person:

- Read `dist/release-notes.md`. It is what the release page shows.
- Quit any development build of the app first, because both use the same bundle ID and hotkey.
- Try the zip as a downloaded file. Copy it somewhere new, mark it as downloaded, then open it from
  Finder:

  ```sh
  mkdir -p ~/Desktop/release-check && cp dist/Slick-0.1.0.zip ~/Desktop/release-check/
  xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" ~/Desktop/release-check/Slick-0.1.0.zip
  open ~/Desktop/release-check
  ```

  Double-click the zip, then open the app. macOS should ask only whether to open an app downloaded
  from the internet. Any other warning means the release is not ready.
- Open Settings, then About. It should read "Version 0.1.0" with the build number from the release
  output.
- Grant Accessibility when asked. macOS ties the grant to the signature, so a Developer ID build asks
  again even when a development build already had it.
- Quit the app and delete `~/Desktop/release-check`.

## Homebrew

People install with `brew install --cask shawntz/tap/slick`. The cask is `Casks/slick.rb` in the
tap. It says the app needs macOS 26 or later on Apple silicon, because the build is arm64 only.

Slick has no updater of its own. People get a new version with `brew upgrade --cask slick` once the
tap has the new cask, so the cask has no `auto_updates` line. Its `livecheck` reads the GitHub
releases and keeps pre-releases, which the default strategy would skip. Once releases are no longer
pre-releases, `strategy :github_latest` without a block is enough.

What each command does to a person's data:

- `brew upgrade --cask slick` quits Slick, replaces `/Applications/Slick.app` and opens Slick
  again. It keeps everything else. Everything Slick learned stays, and so do the clipboard
  history, aliases, hotkeys, favorites and themes, in `~/Library/Application Support/Slick`. The
  settings stay, in `~/Library/Preferences/com.shawnschwartz.slick.plist`. API keys stay in the
  login keychain. The Accessibility grant and the login item stay too, because every release has
  the same bundle ID and the same Developer ID team.
- `brew uninstall --cask slick` removes the app and keeps all of the above. A later install picks
  up where it left off.
- `brew uninstall --zap --cask slick` removes the app and deletes, for good, the data folder, the
  settings file and the saved window state. That is everything Slick learned, the clipboard
  history with its copied images, the aliases, hotkeys, favorites, themes and every setting.
  macOS may keep the settings in memory until the next login, so `defaults delete
  com.shawnschwartz.slick` clears them at once. Zap cannot remove the API keys, which stay in the
  login keychain under the service `com.shawnschwartz.slick.secrets`, the login item, or the
  permission grants. Keychain Access, System Settings under General and then Login Items, and
  System Settings under Privacy and Security remove those.

A development build uses the same bundle ID and data folder as a release. So on your own Mac, a zap
also deletes what the development build learned.

## Pull a bad release

Never replace the files of a published release. The cask pins the zip's SHA-256, so a new zip under
the same version breaks every install with a checksum error. Fix forward with a higher version.

- A draft that was never published: delete it and its tag with
  `gh release delete v0.1.0 --repo shawntz/slick --cleanup-tag --yes`, then `git tag -d v0.1.0`.
  Nobody saw it, so the version number can be used again.
- A published release that the tap does not point to yet: delete it the same way, but do not use
  the version number again.
- A release the tap points to: revert the cask commit in the tap and push, so new installs get the
  previous version. For the first release, remove `Casks/slick.rb` from the tap instead. Then edit
  the GitHub release notes to say what is wrong, and ship a fixed version as soon as you can. People
  who already upgraded stay on the bad version until then.
- A security problem: also publish a GitHub security advisory, as `SECURITY.md` describes.

## Version and build number

`make release VERSION=X.Y.Z` passes the version and the build number to `scripts/bundle.sh`, and
`scripts/info-plist.sh` writes them into `Info.plist` as `CFBundleShortVersionString` and
`CFBundleVersion`. The About pane in settings reads both from the running bundle and shows them as
"Version 0.1.0 (N)", where N is the build number. A plain `make app` gets the defaults in
`scripts/info-plist.sh`: version 0.1.0, build 1.

## Third-party notices

`make notices` rewrites `THIRD-PARTY-NOTICES.md` from the crates linked into the Rust library, the
Rust standard library and the emoji data's license. It works offline from the local cargo registry.
Run it and commit the result whenever `core/Cargo.lock` changes. `make release` refuses a stale
file. `scripts/bundle.sh` copies the file into `Contents/Resources` of every bundle it makes,
including those of `make app` and `make install`. The About pane in settings links to the copy in
the repository.

## Install from a checkout

`make install` builds the release configuration of the app and copies `build/Slick.app` to
`/Applications` with `ditto`. `INSTALL_DIR` picks another folder:

```sh
make install                                # build, then copy to /Applications
make install INSTALL_DIR=~/Applications     # or to a folder of your own
make uninstall                              # remove the installed copy
```

- Quit the installed copy first, with Quit Slick in its menu bar menu. `make install` refuses while
  a copy from that folder is running and says so. It also refuses to replace a `Slick.app` there that
  carries another bundle ID.
- The new copy goes into a hidden folder beside the old one and replaces it only once it is whole,
  so a failed copy leaves the old install as it was.
- Afterwards the system knows one launcher. The installed copy is registered with LaunchServices, so
  links and Spotlight open it, and `build/Slick.app` is unregistered. While an installed copy
  exists, `scripts/launch.sh` unregisters build's copy after each `make selftest`, `make bench` or
  `make scenario`. `make run` still starts build's copy, which registers it again until the next
  `make install`.
- One copy runs at a time per data folder. Quit any copy started from `build/` before you open the
  installed one, or the installed one opens the other's panel and quits. Both copies share the data
  folder and the settings.
- Turn on Open at Login in the installed copy's General settings. The switch registers the copy
  that is running, so turning it on in a copy started from `build/` makes every login open that
  copy, which `make clean` deletes. If you did, turn it off there and on again in the installed copy.
- Permission grants carry over between the two copies only when both are signed with the same Apple
  Development identity. An ad hoc copy asks again.

`make uninstall` removes `Slick.app` from `/Applications`, or from `INSTALL_DIR`, only when it carries
this app's bundle ID and is not running. It unregisters the copy first. The data folder in
`~/Library/Application Support/Slick` and the settings stay. Turn Open at Login off before you
uninstall, or its entry may stay in System Settings with nothing to open.

`scripts/test-scripts.sh`, part of `make test`, checks both targets against a temporary folder with
a stand-in bundle made of plain files, and with a recorder in place of `lsregister`, so nothing
reaches LaunchServices.
