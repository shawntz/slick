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
  Reminders, and Apple Events for System. `NSLocalNetworkUsageDescription` is for AI's local model
  server. `InfoPlistTests` checks both directions.
- A keychain access group would let Platform's `SecItemKeychain` use the data protection keychain
  in every build. It needs a team ID and a provisioning profile, so it is not here. Builds fall
  back to the login keychain.
- `debug.entitlements` is used for debug builds. It adds `com.apple.security.get-task-allow` so
  lldb and Instruments can attach under the hardened runtime. Notarization rejects it.
