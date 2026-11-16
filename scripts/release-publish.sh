#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# Publishes the release that scripts/release.sh left in dist/, as a draft, and writes its cask.
#   scripts/release-publish.sh <version>
#
# Run it after you have checked dist/. It:
#   1 checks dist/ again: a finished real release of this version, built from HEAD, every
#     artifact intact
#   2 checks that HEAD is on origin/main and that gh is signed in
#   3 writes the Homebrew cask for this version to dist/<token>.rb
#   4 tags HEAD vX.Y.Z and pushes the tag
#   5 creates the GitHub release as a draft, with the zip, the dSYM zip and SHA256SUMS.txt
#   6 prints how to publish the draft and how to put the cask in the tap, once the public download
#     matches dist/
# It never touches the tap and never publishes the draft. Run it again after a failure: a tag or
# draft that already matches is reused. A release that is already published is never replaced.
#
# Env:
#   RELEASE_PRERELEASE  1 marks the release as a pre-release, 0 does not. Default: 1 while the major
#                       version is 0.
#   RELEASE_REPO        owner/name on GitHub. Default: the origin remote.
#   HOMEBREW_TAP        owner/name of the tap. Default: <owner>/homebrew-tap.
set -euo pipefail
# shellcheck source=lib/env.sh
. "$(dirname "$0")/lib/env.sh"
# shellcheck source=lib/release.sh
. "$(dirname "$0")/lib/release.sh"
LOG_TAG=release-publish

VERSION=${1:-}
[ -n "$VERSION" ] || fail "usage: make release-publish VERSION=<x.y.z>"
VERSION=${VERSION#v}
is_version "$VERSION" || fail "version '$VERSION' is not of the form X.Y.Z."
TAG="v$VERSION"
DIST="$ROOT/dist"
cd "$ROOT"

# 1. dist/ holds a real release of this version, built from HEAD.
say "== 1/6 check dist/"
read_release_env "$DIST/release.env"
[ "${RELEASE_MODE:-}" = release ] || fail "dist/ holds a ${RELEASE_MODE:-unknown} build, not a release. Run make release VERSION=$VERSION."
[ "${RELEASE_VERSION:-}" = "$VERSION" ] || fail "dist/ holds version ${RELEASE_VERSION:-unknown}, not $VERSION."
[ "${RELEASE_COMPLETE:-}" = 1 ] || fail "dist/ holds a release that stopped before its last check. Run make release VERSION=$VERSION again."
[ "${RELEASE_TREE_CLEAN:-}" = 1 ] || fail "dist/ was built from a tree with changes. Run make release again from a clean tree."
COMMIT=$(git rev-parse HEAD)
[ "${RELEASE_COMMIT:-}" = "$COMMIT" ] || fail "dist/ was built from ${RELEASE_COMMIT:-unknown}, but HEAD is $COMMIT. Run make release again."
[ -z "$(git status --porcelain)" ] || fail "the tree has changes. Publish from the clean tree the release was built from."
"$ROOT/scripts/check-release.sh" "$DIST"

# 2. The commit is on origin/main, and gh can reach the repository.
say "== 2/6 check the repository"
command -v gh > /dev/null || fail "gh not found. Install it with: brew install gh, then run: gh auth login"
REPO=$(github_repo)
gh auth status > /dev/null 2>&1 || fail "gh is not signed in. Run: gh auth login"
git fetch --quiet origin main || fail "could not fetch origin main."
git merge-base --is-ancestor "$COMMIT" origin/main \
    || fail "HEAD is not on origin/main. Push it first, so the tag points at a commit everyone can see."
RELEASE_STATE=$(gh release view "$TAG" --repo "$REPO" --json isDraft --jq 'if .isDraft then "draft" else "published" end' 2> /dev/null || echo none)
[ "$RELEASE_STATE" != published ] \
    || fail "$TAG is already published on GitHub. A published release is never replaced; release a higher version."
HIGHEST=$(last_released_version) || fail "could not list the tags."
if [ -n "$HIGHEST" ] && version_gt "$HIGHEST" "$VERSION"; then
    fail "version $VERSION is not higher than the last release tag, v$HIGHEST."
fi
PREVIOUS=$(tagged_version_below "$VERSION") || fail "could not list the tags."
PRERELEASE=${RELEASE_PRERELEASE:-}
if [ -z "$PRERELEASE" ]; then
    if [ "${VERSION%%.*}" = 0 ]; then PRERELEASE=1; else PRERELEASE=0; fi
fi
case $PRERELEASE in
    0 | 1) ;;
    *) fail "RELEASE_PRERELEASE must be 0 or 1, not '$PRERELEASE'." ;;
esac

# 3. The cask, written before anything is published so a problem stops the script early.
say "== 3/6 write the cask"
TOKEN=$(cask_token)
CASK="$DIST/$TOKEN.rb"
"$ROOT/scripts/render-cask.sh" "$DIST" "$CASK"

# 4. The tag, made and pushed unless it already points at this commit.
say "== 4/6 tag $TAG"
if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
    [ "$(git rev-list -n 1 "$TAG")" = "$COMMIT" ] || fail "tag $TAG exists and points at another commit."
    say "tag $TAG already points at HEAD"
else
    git tag -a "$TAG" -m "Release $VERSION" "$COMMIT"
fi
# An annotated tag shows twice: as the tag object, and peeled, with ^{}, as the commit it names.
REMOTE_REFS=$(git ls-remote --tags origin "refs/tags/$TAG*") || fail "could not list the tags on origin."
REMOTE_TAG=$(awk -v ref="refs/tags/$TAG^{}" '$2 == ref {print $1}' <<< "$REMOTE_REFS")
[ -n "$REMOTE_TAG" ] || REMOTE_TAG=$(awk -v ref="refs/tags/$TAG" '$2 == ref {print $1}' <<< "$REMOTE_REFS")
if [ -z "$REMOTE_TAG" ]; then
    git push origin "refs/tags/$TAG" || fail "could not push $TAG. Run make release-publish VERSION=$VERSION again."
elif [ "$REMOTE_TAG" != "$COMMIT" ]; then
    fail "origin has a tag $TAG that points at $REMOTE_TAG, not at HEAD."
fi

# 5. The draft release with its files.
say "== 5/6 draft the GitHub release"
FILES=("$DIST/$RELEASE_ZIP" "$DIST/$RELEASE_DSYM_ZIP" "$DIST/SHA256SUMS.txt")
if [ "$RELEASE_STATE" = draft ]; then
    if [ "$PRERELEASE" = 1 ]; then IS_PRERELEASE=true; else IS_PRERELEASE=false; fi
    gh release edit "$TAG" --repo "$REPO" --notes-file "$DIST/release-notes.md" --prerelease="$IS_PRERELEASE" \
        || fail "could not update the draft $TAG."
    gh release upload "$TAG" --repo "$REPO" --clobber "${FILES[@]}" || fail "could not upload the files to the draft $TAG."
else
    FLAGS=(--repo "$REPO" --verify-tag --draft --title "$BRAND_NAME $VERSION" --notes-file "$DIST/release-notes.md")
    [ "$PRERELEASE" = 0 ] || FLAGS+=(--prerelease)
    gh release create "$TAG" "${FLAGS[@]}" "${FILES[@]}" \
        || fail "could not create the draft. Run make release-publish VERSION=$VERSION again; the tag is reused."
fi

# 6. What the owner does next.
say "== 6/6 done"
TAP=${HOMEBREW_TAP:-${REPO%%/*}/homebrew-tap}
TAP_NAME=${TAP#*/}
TAP_NAME=${TAP_NAME#homebrew-}
if [ -n "$PREVIOUS" ]; then
    MESSAGE="Update $TOKEN to $VERSION"
else
    MESSAGE="Add $TOKEN $VERSION"
fi
KIND="a draft"
[ "$PRERELEASE" = 0 ] || KIND="a draft pre-release"
# The address the cask downloads from. The first tap command checks that it serves the zip in
# dist/, so the cask cannot reach the tap while the release is still a draft.
DOWNLOAD="https://github.com/$REPO/releases/download/$TAG/$RELEASE_ZIP"
cat >&2 << EOF

[release-publish] $TAG is $KIND on GitHub. Nothing is public yet.

Next:
  1. Look at the draft, its notes and its three files:
       gh release view $TAG --repo $REPO --web
  2. Publish it. The cask's download only works once the release is public:
       gh release edit $TAG --repo $REPO --draft=false
  3. Put the cask in the tap with these two commands. The first downloads the public zip and
     goes on only when its SHA-256 matches dist/. It prints the tap's pending change.

curl -fsSL "$DOWNLOAD" | shasum -a 256 | grep -q "^$RELEASE_SHA256 " && TAP_DIR="\$(mktemp -d)/homebrew-tap" && git clone --quiet --depth 1 git@github.com:$TAP.git "\$TAP_DIR" && mkdir -p "\$TAP_DIR/Casks" && cp "$CASK" "\$TAP_DIR/Casks/$TOKEN.rb" && git -C "\$TAP_DIR" status --short || echo "Stopped. Either the download does not match dist/$RELEASE_ZIP yet, or the clone failed."
git -C "\${TAP_DIR:?run the first command first}" add "Casks/$TOKEN.rb" && git -C "\$TAP_DIR" commit -m "$MESSAGE" && git -C "\$TAP_DIR" push

  4. Check it as a user would: brew update && brew install --cask ${TAP%%/*}/$TAP_NAME/$TOKEN
EOF
