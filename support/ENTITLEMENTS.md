# Entitlements

AMFI's entitlement parser rejects XML comments ("AMFIUnserializeXML: syntax error"), so the
reasons live here instead of in the `.entitlements` files.

- `release.entitlements` is used for release builds and Developer ID distribution. The app is not
  sandboxed: a launcher needs global hotkeys, Accessibility for window management and text
  expansion, search across the whole disk and script execution. `scripts/bundle.sh` turns on the
  hardened runtime with `codesign --options runtime`. The one exception it asks for is
  `com.apple.security.automation.apple-events`, which pairs with `NSAppleEventsUsageDescription`
  in `Info.plist.in`.
- Under the hardened runtime, Contacts, Calendars and Reminders, and Location need their
  `com.apple.security.personal-information` entitlements as well as the usage text in
  `Info.plist.in`. Without them the system refuses access and never asks. `addressbook`,
  `calendars` and `location` are in both files. None of them asks for anything by itself; a feature
  still has to request access, and Platform does that only after the user presses a button.
- A keychain access group would let Platform's `SecItemKeychain` use the data protection keychain
  in every build. It needs a team ID and a provisioning profile, so it is not here. Builds fall
  back to the login keychain.
- `debug.entitlements` is used for debug builds. It adds `com.apple.security.get-task-allow` so
  lldb and Instruments can attach under the hardened runtime. Notarization rejects it.
