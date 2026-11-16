# Entitlements

AMFI's entitlement parser rejects XML comments ("AMFIUnserializeXML: syntax error"), so the
reasons live here instead of in the `.entitlements` files.

- `release.entitlements` is used for release builds and Developer ID distribution. The app is not
  sandboxed: a launcher needs global hotkeys, Accessibility for window management and text
  expansion, search across the whole disk and script execution. `scripts/bundle.sh` turns on the
  hardened runtime with `codesign --options runtime`. The one exception it asks for is
  `com.apple.security.automation.apple-events`, which pairs with `NSAppleEventsUsageDescription`
  in `Info.plist.in`.
- Under the hardened runtime, Contacts, and Calendars and Reminders, need their
  `com.apple.security.personal-information` entitlements as well as the usage text in
  `Info.plist.in`. Without them the system refuses access and never asks. `addressbook` (Contacts)
  and `calendars` (Schedule's events and reminders) are in both files. None of them asks for
  anything by itself; a feature still has to request access, and Platform does that only after the
  user presses a button. No feature uses Location, so neither file grants it and `Info.plist.in`
  has no location text. A feature that needs it adds both, and `InfoPlistTests` fails until it does.
- Every usage text in `Info.plist.in` matches a permission some feature lists in its manifest:
  folders, removable and network volumes and iCloud Drive for File Search, Contacts, Calendars and
  Reminders, and Apple Events for System and Media Controls. `NSLocalNetworkUsageDescription` is for
  AI's local model server. `InfoPlistTests` checks both directions.
- macOS shows one text for a guarded folder, whatever reads it. So each folder text also names a
  notes folder the user chose there and the shell commands and scripts the user runs, and the Apple
  Events and local network texts name shell commands too. `InfoPlistTests` checks those words.
- A keychain access group would let Platform's `SecItemKeychain` use the data protection keychain
  in every build. It needs a team ID and a provisioning profile, so it is not here. Builds fall
  back to the login keychain.
- `debug.entitlements` is used for debug builds. It adds `com.apple.security.get-task-allow` so
  lldb and Instruments can attach under the hardened runtime. Notarization rejects it.
- Neither file turns off library validation. Under the hardened runtime the app may load only code
  signed with its own Team ID, and `Sparkle.framework` in `Contents/Frameworks` is signed with the
  app's identity, so Apple Development and Developer ID builds load it. Ad hoc code has no Team ID,
  so `scripts/bundle.sh` and the release dry run add `com.apple.security.cs.disable-library-validation`
  to an ad hoc build when they sign it. `scripts/release.sh` refuses `release.entitlements` with it,
  and `scripts/check-release.sh` fails a Developer ID release that carries it. With library
  validation off, any ad hoc framework put in place of Sparkle's loads with the app's permission
  grants, so an ad hoc build must not hold Accessibility or Input Monitoring for daily use.
  `scripts/bundle.sh` says so whenever it signs ad hoc, also when it falls back to ad hoc.
- Sparkle's helpers, its two XPC services, its Updater app and Autoupdate, are signed with no
  entitlements. Sparkle's own ad hoc signature gives Autoupdate an application identifier
  entitlement, and re-signing drops it, as the owner's other app's build does. Autoupdate runs only
  while an update installs, which no test or dry run reaches, so that has not run here.
