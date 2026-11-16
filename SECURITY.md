# Security

Please report a security problem privately, not in a public issue.

## How to report

Use GitHub's private vulnerability reporting. Open
[a new advisory](https://github.com/shawntz/slick/security/advisories/new), or go to the
repository's Security tab and choose "Report a vulnerability". Only the repository's maintainers
can read the report.

Say what you found, how to reproduce it, and which version you used. The About pane in Slick's
settings shows the version and build number. Say too whether you want credit when the advisory is
published.

## What happens next

The reply comes in the advisory itself. Once a fix ships, the advisory is published with it.

## Supported versions

Only the latest release gets fixes. A fix arrives through Slick's own updater, through Homebrew, or
as a download from the GitHub release.

## How an update is verified

Slick installs an update only after Sparkle checks the downloaded zip's EdDSA signature against the
public key inside the copy you run. The private key stays in the maintainer's keychain, and the app
inside the zip is also signed with Developer ID and notarized by Apple. If the key is ever lost,
Sparkle takes an update signed with a new key only when its app carries the same Developer ID team.
Sparkle never installs a lower build number. So a download that someone else changed cannot be
installed.

The update feed itself, `appcast.xml` on the latest GitHub release, is not signed. Anyone who could
publish a release on the repository could change what Slick's update window shows and where its
links lead, offer a zip that Slick downloads and then refuses, or hold back real updates. They could
not get code installed. Slick takes the feed address only from its own `Info.plist`, never from its
settings, and never downloads or installs an update on its own: you choose Install in the update
window. Until you turn on update checks, Slick asks for nothing.

## Scope

Slick runs with the permissions you grant it, such as Accessibility, and it runs scripts you set
up. A way for something else to misuse those permissions, read what Slick stores, or run code
through Slick is in scope. So is a problem in the release files: the signed app, its zip, the update
feed with its signature, and the Homebrew cask.
