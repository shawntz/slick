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

Only the latest release gets fixes. Slick has no updater of its own, so a fix arrives through
Homebrew, with `brew upgrade --cask slick`, or as a download from the GitHub release.

## Scope

Slick runs with the permissions you grant it, such as Accessibility, and it runs scripts you set
up. A way for something else to misuse those permissions, read what Slick stores, or run code
through Slick is in scope. So is a problem in the release files: the signed app, its zip and the
Homebrew cask.
