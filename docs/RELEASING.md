# Releases

Versions are `X.Y.Z`. Changes that people will notice go under `## Unreleased` in `CHANGELOG.md` as
they land. No release is marked as a pre-release on GitHub. The app updates itself from the latest
release, and GitHub's latest release skips pre-releases, so a pre-release would reach nobody. The
release notes say instead that the software is early.

A release takes two commands, with a stop after each for you to look:

```sh
NOTARYTOOL_PROFILE=slick-notary make release VERSION=0.1.0   # build, sign, notarize, staple and sign the update into dist/
make release-publish VERSION=0.1.0                            # tag, push the tag, draft the release, write the cask
```

The first publishes nothing. The second leaves the release as a draft and never touches the
Homebrew tap. You publish the draft and update the tap yourself, with commands it prints. Splay does
all of this in one script. Slick stops twice, because a published version can never be replaced.

To run Slick every day from your own checkout without a release, see
[Install from a checkout](#install-from-a-checkout) at the end.

Agents never run `make release`, `make release-publish`, `make update-key`, `make install` or
`make uninstall`. Each one changes your Mac, your keychain or the public repository. An agent may
run `make release-dry-run`, which builds and signs ad hoc in a temporary folder and shows nothing.

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
7. The update key exists, its public half is in `support/brand.env`, and its private half is backed
   up. [Updates](#updates) has the commands. `make release` refuses to start without it.
8. The repository is public, because installed copies fetch the feed and the zip from its releases
   without signing in, and only you can publish releases on it, because whoever can controls what
   the update window shows. This prints `PUBLIC`, then everyone else with access:

   ```sh
   gh repo view shawntz/slick --json visibility --jq .visibility
   gh api repos/shawntz/slick/collaborators --jq '.[].login'
   ```

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
   minutes, and prints nothing while it waits. Near the end macOS may ask once more, whether
   `sign_update` may use the update key. Choose Always Allow again. It ends with a list of what is
   in `dist/`.
6. Check `dist/` as [Before you publish](#before-you-publish) says.
7. Draft the GitHub release:

   ```sh
   make release-publish VERSION=0.1.0
   ```

8. Look at the draft, its notes and its four files: the zip, the dSYM zip, `SHA256SUMS.txt` and
   `appcast.xml`:

   ```sh
   gh release view v0.1.0 --repo shawntz/slick --web
   ```

9. Publish it as the latest release. From here on, version 0.1.0 is spent, and every copy that
   checks for updates is offered it:

   ```sh
   gh release edit v0.1.0 --repo shawntz/slick --draft=false --latest
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

    `brew livecheck` should show 0.1.0 on both sides of its arrow. In the installed app, choose
    Check for Updates… in the menu bar menu. Sparkle's window should say that 0.1.0 is the newest
    version.

    Homebrew loads a cask from a tap like this one only after you trust it. Installing by the full
    name, as above, trusts that one cask, so install before you run the audit and the livecheck.
12. Tell the website and the README. In `site/data/release.json`, set the version and turn the
    download on. Then edit the release sentences by hand: "Turning on the download button" in
    [WEBSITE.md](WEBSITE.md) lists the ones in `site/index.html`, and the README has the line
    under its hero and the Install section. Commit and push to `main`.

## When a step fails

Every message starts with the script's name and says what to do. Nothing is published until step
7, and nothing is public until step 9.

| Where it stops | What it leaves | What to do |
| --- | --- | --- |
| A refusal in step 5 | Nothing | Fix what it names, then run step 5 again. |
| `sign_update`, in step 5 | The partial build in `dist/` | It prints `sign_update`'s own reason above its message. For a denied or cancelled keychain prompt, run step 5 again and choose Always Allow. For a key it cannot find, import the key as [Updates](#updates) says. |
| The update signature, in step 5 | The partial build in `dist/` | The keychain's update key is not the one in `support/brand.env`. `make update-key` prints the keychain's public key. Import the right key, as [Updates](#updates) says, then run step 5 again. |
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
It refuses while a copy of the app is running from `dist/`, because it deletes that folder. Quit
that copy first, or release from another clone.
It also refuses when the copies the last release installed would not take this one: when `HEAD`'s
build number is not higher than that tag's, as after a rewritten history, and when
`support/brand.env` names another update key than that tag did. `UPDATE_KEY_ROTATION=1` allows a
new key on purpose, as [If the key is lost](#if-the-key-is-lost) says.
It signs with the one Developer ID Application identity in the keychain, or the one that
`DEVELOPER_ID_APPLICATION` names. Then it:

- deletes `dist/` and builds the Rust core and the app in release configuration from nothing, in
  `dist/build`, so a copy of the app running from `build/` keeps running
- bundles the app with `scripts/bundle.sh`, with the version you gave and the build number, the
  update feed and the public key in `Info.plist`, and `Sparkle.framework` in `Contents/Frameworks`.
  It strips the executable and keeps the dSYM beside the bundle
- puts `THIRD-PARTY-NOTICES.md` in `Contents/Resources`, after checking that it lists the crates
  this build links and the pinned Sparkle
- signs every nested piece of code, deepest first, then the bundle, each with the hardened runtime
  and a secure timestamp, and the bundle with `support/release.entitlements`. The nested code is
  Sparkle's: its two XPC services, its Updater app, its Autoupdate tool and the framework itself,
  all signed with your Developer ID.
- verifies the signature strictly, zips the bundle with `ditto`, sends the zip to the notary
  service and waits for the verdict
- staples the ticket to the bundle, trying for about two minutes while Apple publishes it, and asks
  Gatekeeper about it with `spctl`
- zips the stapled bundle again, as the file to publish, and zips the dSYM
- signs the zip for Sparkle with `sign_update` and the update key in your login keychain, then
  checks that signature against the public key in `support/brand.env` with
  `scripts/update-signature.swift`, which needs no keychain, and stops when they do not match
- writes `appcast.xml` with one item: the version and build number, the oldest macOS, the address
  the zip will have on GitHub, its length, its signature, the date, and the changelog section as
  plain HTML with every character escaped
- writes `SHA256SUMS.txt`, `release-notes.md` from `support/release-notes.md.in` and the changelog,
  and `release.env`, which the publish step reads
- unpacks the zip it is about to ship and checks it with `scripts/check-release.sh`, which also
  starts the unpacked executable with `--version`, then marks `release.env` complete

It also refuses to start without `BRAND_UPDATE_PUBLIC_KEY` in `support/brand.env`, and when the
origin remote is not the repository `BRAND_REPOSITORY` names, because the feed lives there.

The build number is the number of commits in `HEAD`'s history, so each release has a higher one
than the last. `dist/` holds its own `.gitignore`, so git never lists it.

## What make release-publish does

`scripts/release-publish.sh` checks `dist/` again: a complete, real release of this version, built
from `HEAD` on a clean tree, with every file intact, `appcast.xml` among them. It refuses a `dist/`
without one. It checks that `HEAD` is on `origin/main` and that `gh` is signed in. Then it:

- writes the cask to `dist/slick.rb` from `support/homebrew/slick.rb.in`, with the version and the
  zip's SHA-256
- tags `HEAD` as `vX.Y.Z` and pushes the tag
- creates the GitHub release as a draft, never marked as a pre-release, with the zip, the dSYM zip,
  `SHA256SUMS.txt` and `appcast.xml`. A draft an older run marked as a pre-release loses the mark.
- prints the commands that publish the draft as the latest release and update the tap

It never replaces a release that is already published.

## Dry run

```sh
make release-dry-run                  # version 0.0.0, into a temporary folder that is removed after
make release-dry-run VERSION=0.1.0    # the same for the version you are about to release
make release-dry-run OUT=build/dry    # keeps the result in build/dry
```

The dry run is the same script with four steps switched off. It signs ad hoc instead of with
Developer ID, it skips notarization and stapling, and it signs the update with a throwaway key made
in memory instead of the update key. So it needs no credentials, never touches the keychain and
never contacts the notary service. It still checks the throwaway signature and writes the appcast,
so the whole update path runs. The checks that stop a release only warn, so it runs on a tree with
changes too, and without the update key. Then `scripts/check-release.sh` checks every artifact: the
zip unpacks to a bundle that passes strict signature verification with Sparkle's framework and its
links, `Info.plist` carries the version and the feed with automatic checks and installs off, the
executable starts with `--version`, the
checksums match, the dSYM matches the executable, the appcast describes the zip and its signature
verifies, and the cask renders and parses as Ruby. It needs Ruby, Python 3 and swiftc on the path,
as the release does. `OUT` must name a new or empty folder, or one an earlier dry run wrote.

An ad hoc build has no Team ID, and library validation under the hardened runtime then refuses the
ad hoc Sparkle.framework. So an ad hoc build, a dry run's or `make app`'s without an Apple
Development identity, also carries `com.apple.security.cs.disable-library-validation`. A release
signed with Developer ID never does, and `scripts/check-release.sh` fails one that does.

CI runs `make release-dry-run` after the tests on every push to main and every pull request, so a
change that breaks the release pipeline fails there, not on release day.

## Before you publish

`make release` has checked the signature, the ticket, the checksums and the cask. These checks need
a person:

- Read `dist/release-notes.md`. It is what the release page shows. The description in
  `dist/appcast.xml` is the changelog section alone, as HTML, and is what Sparkle's window shows.
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
- Open Settings, then General. Updates should show Check for Updates Automatically, the time of the
  last check and Check Now. Do not press Check Now yet: until you publish, the feed is the previous
  release, and for the first release there is none.
- Grant Accessibility when asked. macOS ties the grant to the signature, so a Developer ID build asks
  again even when a development build already had it.
- Quit the app and delete `~/Desktop/release-check`.

## Updates

Slick updates itself with [Sparkle](https://sparkle-project.org) 2.9.6. The `Packages/Updates`
package holds it, pinned to that exact version, and `Package.resolved` pins its revision.

- **The feed** is `appcast.xml` of the latest GitHub release:
  `https://github.com/shawntz/slick/releases/latest/download/appcast.xml`. `scripts/bundle.sh`
  writes it into `Info.plist` as `SUFeedURL` only for release packaging. A build from source has no
  feed, so it never offers to replace itself with a release, and its General pane says that git
  updates it. Publishing a release is what ships the update.
- **The key.** Sparkle installs an update only when the zip's EdDSA signature matches the public key
  in the installed copy's `Info.plist`, `SUPublicEDKey`. That public key is
  `BRAND_UPDATE_PUBLIC_KEY` in `support/brand.env`. The private key lives in your login keychain under the account
  `com.shawnschwartz.slick`, the bundle ID, and only `make release` uses it, through Sparkle's
  `sign_update`.
- **What the app sends.** Nothing until the person agrees. The last step of onboarding has a switch,
  Check for Updates Automatically, that starts on, and the General pane has the same switch with
  Check Now. Once it is on, Slick asks for the feed once a day. The request names the versions of
  Slick and Sparkle and nothing else: no system profile, no extra parameter. The zip downloads only
  when the person chooses Install, because `Info.plist` turns off Sparkle's automatic installs.
- **What the person sees.** A check the person asks for shows Sparkle's window. While the menu bar
  item is shown, a check on the schedule opens no window, and the menu bar menu says that an update
  waits until the person looks. While the item is hidden, Sparkle shows its window behind other
  apps, or in front just after launch. The General pane names a waiting update either way.
- **The feed is not signed.** The zip's signature is what protects an install. Whoever can publish a
  release on the repository can change what the update window shows, but cannot get code installed.
  `SECURITY.md` says more. Only you should be able to publish releases, and CI's token can only
  read.

### Make the update key

Once, on the Mac you release from:

```sh
make update-key
```

It runs Sparkle's `generate_keys --account com.shawnschwartz.slick` from the Updates package's
SwiftPM artifact. It makes the key pair, keeps the private key in your login keychain, and prints
the public key. If the keychain already holds a key for that account, it prints that key's public
half and makes none. Put the public key into `support/brand.env`, then commit and push:

```sh
BRAND_UPDATE_PUBLIC_KEY=<the public key it printed>
```

### Back it up

Without the private key you cannot sign an update that installed copies accept. Export it into a
new private folder, move the file into your password manager or an encrypted backup, and delete the
folder. Run these in the same terminal, from the checkout where you ran `make update-key`:

```sh
D=$(mktemp -d) && echo "$D"
Packages/Updates/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.shawnschwartz.slick -x "$D/slick-update-key"
```

Move `slick-update-key` from the folder it printed into your password manager, then:

```sh
rm -rf "$D"
```

The file holds the private key itself, the same secret as the keychain item. `generate_keys` writes
it readable by every account on the Mac, so it goes only into that folder: `mktemp -d` makes it for
you alone, under your temporary folder, where Spotlight and Time Machine do not look.
`generate_keys` will not write over a file that exists.

### Use it on another Mac

On the other Mac, in a clone of the repository, make a private folder:

```sh
make bootstrap
D=$(mktemp -d) && echo "$D"
```

Put the backup from your password manager into the folder it printed, as `slick-update-key`. Then,
in the same terminal, import it, delete the folder and check the public key:

```sh
Packages/Updates/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.shawnschwartz.slick -f "$D/slick-update-key"
rm -rf "$D"
Packages/Updates/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.shawnschwartz.slick -p
```

The last command prints the public key, which must equal `BRAND_UPDATE_PUBLIC_KEY`. Sparkle says an
item for the account that is already in the keychain may need removing in Keychain Access first.

### If the key is lost

Installed copies keep their public key and refuse an update whose signature does not match it.
Sparkle 2.9.6 then tries one fallback: it accepts the update when the zip's app is signed with
Developer ID by the same team as the installed copy, and when the new app's own public key matches
the signature. So a lost key can be replaced: make a new one with `make update-key`, after removing
any old item for the account in Keychain Access, put its public key into `support/brand.env`, and
release a higher version signed with the same Developer ID team. `make release` refuses a key that
differs from the last release's unless you say the change is on purpose, so run step 5 of
[Cut a release](#cut-a-release) as
`UPDATE_KEY_ROTATION=1 NOTARYTOOL_PROFILE=slick-notary make release VERSION=X.Y.Z`. Every later
release uses the new key and needs no such setting. Sparkle allows a new key but not none: a
release without `SUPublicEDKey` is refused, which `make release` already prevents. If the
Developer ID team is lost too, installed copies can never update again, and people have to
download the new version or install it with Homebrew.

These facts come from Sparkle 2.9.6's own files: the help text inside `generate_keys` and
`sign_update`, and the messages inside its `Autoupdate` tool.

## Homebrew

People install with `brew install --cask shawntz/tap/slick`. The cask is `Casks/slick.rb` in the
tap. It says the app needs macOS 26 or later on Apple silicon, because the build is arm64 only.

Slick updates itself with Sparkle, so the cask says `auto_updates true`. `brew upgrade` then leaves
an installed copy alone unless it is asked with `--greedy`, and the copy updates itself. Its
`livecheck` uses `strategy :github_latest`, because no release is a pre-release.

What each command does to a person's data:

- `brew upgrade --greedy --cask slick` quits Slick, replaces `/Applications/Slick.app` and opens
  Slick again. An update Sparkle installs does the same. Both keep everything else. Everything
  Slick learned stays, and so do the clipboard history, aliases, hotkeys, favorites and themes, in
  `~/Library/Application Support/Slick`. The settings stay, in
  `~/Library/Preferences/com.shawnschwartz.slick.plist`. API keys stay in the login keychain. The
  Accessibility grant and the login item stay too, because every release has the same bundle ID
  and the same Developer ID team.
- `brew uninstall --cask slick` removes the app and keeps all of the above. A later install picks
  up where it left off.
- `brew uninstall --zap --cask slick` removes the app and deletes, for good, the data folder, the
  settings file, the saved window state and the cache folder
  `~/Library/Caches/com.shawnschwartz.slick`, where Sparkle keeps downloaded updates. That is
  everything Slick learned, the clipboard history with its copied images, the aliases, hotkeys,
  favorites, themes and every setting. macOS may keep the settings in memory until the next login,
  so `defaults delete com.shawnschwartz.slick` clears them at once. Zap cannot remove the API keys,
  which stay in the login keychain under the service `com.shawnschwartz.slick.secrets`, the login
  item, or the permission grants. Keychain Access, System Settings under General and then Login
  Items, and System Settings under Privacy and Security remove those.

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
- Every published release is offered to every copy that checks, because the feed is the latest
  release's `appcast.xml`. To stop that offer at once, make the previous release the latest again
  with `gh release edit v<previous> --repo shawntz/slick --latest`. Copies that already updated stay
  on the bad version, and Sparkle never moves a copy back to a lower build number, so the fix is a
  higher version.
- A security problem: also publish a GitHub security advisory, as `SECURITY.md` describes.

## Version and build number

`make release VERSION=X.Y.Z` passes the version and the build number to `scripts/bundle.sh`, and
`scripts/info-plist.sh` writes them into `Info.plist` as `CFBundleShortVersionString` and
`CFBundleVersion`. The About pane in settings reads both from the running bundle and shows them as
"Version 0.1.0 (N)", where N is the build number. A plain `make app` gets the defaults in
`scripts/info-plist.sh`: version 0.1.0, build 1. Sparkle compares build numbers to decide what is
newer, which is one more reason the build number is the commit count. The executable prints both
with `--version` and exits before it makes any window, which `scripts/check-release.sh` and CI use
to prove that a bundle starts.

## Third-party notices

`make notices` rewrites `THIRD-PARTY-NOTICES.md` from the crates linked into the Rust library, the
Rust standard library, the emoji data's license and Sparkle's `LICENSE`, which also holds the
licenses of the code Sparkle carries. It works offline from the local cargo registry and from
Sparkle's SwiftPM artifact, which `make bootstrap` or `scripts/swiftpm.sh Packages/Updates package
resolve` fills. Run it and commit the result whenever `core/Cargo.lock` changes or the Sparkle pin
in `Packages/Updates` moves. `make release` refuses a stale file, and the file names Sparkle's
version, so a moved pin makes it stale. `scripts/bundle.sh` copies the file into
`Contents/Resources` of every bundle it makes, including those of `make app` and `make install`.
The About pane in settings links to the copy in the repository.

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
