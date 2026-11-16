# Contacts

Find a person in Contacts and call, message, email or FaceTime them. The package is People and the module is People, because macOS already has a framework named Contacts. The feature ID is `contacts`.

## What it declares

| Kind | What |
|---|---|
| Command `search` | Search Contacts: everyone in one list, sorted by name, with a detail pane. Requires Contacts. Also a fallback and a Tab candidate, which open the list with the typed text |
| Catalog source `contact` | people in root search by name, with nicknames and companies as keywords, once access is allowed and while the setting is on |
| Settings pane | people in root search, what Return does, the app for calls, and a button that asks for access |
| Permission | Contacts, asked only from Search Contacts, the list's Allow Access button or the settings button |

Rows use the namespace `contact` and the store's identifier as the key, such as `contact:410FE041-...:ABPerson`. Root search already treats `contact` rows as contacts. Rows are `.learnOnly` and carry no payload, so root learns which person a query leads to and keeps no copy of a name or number.

## Actions

Only the actions a person has something for are offered. A person with several numbers, email addresses or postal addresses gets a submenu, one entry per value, titled with its label.

| Action | ID | URL or effect |
|---|---|---|
| Open in Contacts | `open-in-contacts` | `addressbook://<identifier>`, Command-O |
| Call | `call` | `tel:+15550100101,7`, a pause before the extension; opens with the app chosen in settings |
| Message | `message` | `sms:+15550100101` |
| Email | `email` | `mailto:ana@example.com` |
| FaceTime | `facetime` | `facetime:` with a number or an email address |
| FaceTime Audio | `facetime-audio` | `facetime-audio:` with a number or an email address |
| Open Address in Maps | `open-address-in-maps` | `maps://?address=...` |
| Show Phone Number in Large Type | `large-type-phone` | Command-L; a submenu for several numbers |
| Copy Name | `copy-name` | Shift-Command-C |
| Copy Phone Number, Copy Email Address, Copy Address | `copy-phone`, `copy-email`, `copy-address` | |

The action chosen for Return comes first. When the person has nothing for it, Open in Contacts comes first. The same number written two ways, or the same address in another case, is offered once. A number with a star or hash that is not an extension is offered for copying only, since a dialer reads those as codes. So is a number whose words leave the digits unclear: a word joined to the digits that is not keypad capitals, as in "1-800-flowers", or digits after a note, as in "555 0100 fax 2". Call never dials a number the card does not clearly hold.

## Privacy and threads

- Nothing reads contacts at activation. The first read follows the user: running Search Contacts, pressing Allow Access, or root search asking for its rows once the user allowed access earlier.
- The live service, `LiveContacts`, checks `CNContactStore.authorizationStatus(for:)` before every read, so it never raises a prompt. It asks only for the keys the feature shows. Notes are never read. Photos are read one at a time for the detail pane, scaled to 256 pixels off the main thread, and kept in memory for the last 64 people.
- Contacts stay in memory while the feature is on. The feature writes no name, number or address to disk and sends nothing over the network. Root search learns which person a query leads to, by the row's ID, as it does for apps; the settings pane says so.
- After the first read the feature follows `CNContactStoreDidChange` and reads again off the main thread. When access goes away it forgets everyone.
- It holds no permission stream. A grant made in settings, onboarding or on the permission card reaches it as `permissionGranted(_:)`, and the list and root search read people at once. A grant made straight in System Settings is read the next time Search Contacts opens.

## Where to look

| File | Holds |
|---|---|
| `PeopleFeature.swift` | manifest, command, settings pane, access flow |
| `Service/PeopleService.swift` | the service protocol and its key |
| `Service/LiveContacts.swift` | `CNContactStore`, never run in tests |
| `Service/InMemoryPeople.swift` | the isolated store, with invented people for scenarios |
| `Directory/PeopleDirectory.swift` | the people in memory, store changes, photos |
| `Directory/PeopleSnapshot.swift` | sorting and rows, built in parallel off the main thread |
| `Model/PersonName.swift` | titles, subtitles, keywords and Latin spellings |
| `Model/ContactLinks.swift` | every URL builder |
| `PeopleActions.swift`, `PeopleList.swift`, `PeopleCatalog.swift` | actions, the list and root search |
| `Detail/` | the detail pane and the photo thumbnail |
| `Strings.swift` | every string a person reads |

## Benchmark

```
PEOPLE_BENCHMARK=1 scripts/swiftpm.sh Packages/Features/People test -c release \
    -Xswiftc -enable-testing --filter PeopleBenchmark
```
