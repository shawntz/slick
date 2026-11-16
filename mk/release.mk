# Targets for releases: scripts/release*.sh, support/homebrew/ and docs/RELEASING.md. The Makefile
# includes every mk/*.mk, so add targets here without editing it. Document each new target with a
# "#   make <target>  <what it does>" line, which make help prints.
#
#   make release VERSION=<x.y.z>          build, sign, notarize and staple a release into dist/; publishes nothing
#   make release-publish VERSION=<x.y.z>  tag, push the tag, draft the GitHub release from dist/ with
#                                         its appcast, write the cask to dist/; prints how to publish
#                                         and update the tap
#   make release-dry-run [VERSION=0.0.0]  the release signed ad hoc, without notary, into a temporary
#                                         folder, then every artifact checked; OUT=<dir> keeps it
#   make notices                          rewrite THIRD-PARTY-NOTICES.md from the crates the app links
#                                         and Sparkle
#   make update-key                       make the key that signs updates in your login keychain, or
#                                         print its public key; for people, never for agents

.PHONY: release release-publish release-dry-run notices update-key

release:
	@if [ -z "$(VERSION)" ]; then echo "usage: make release VERSION=<x.y.z>" >&2; exit 2; fi
	@EXECUTABLE=$(EXECUTABLE) RELEASE_DRY_RUN=0 $(SCRIPTS)/release.sh "$(VERSION)"

release-publish:
	@if [ -z "$(VERSION)" ]; then echo "usage: make release-publish VERSION=<x.y.z>" >&2; exit 2; fi
	@$(SCRIPTS)/release-publish.sh "$(VERSION)"

release-dry-run:
	@EXECUTABLE=$(EXECUTABLE) RELEASE_DRY_RUN=1 RELEASE_OUT="$(OUT)" $(SCRIPTS)/release.sh "$(or $(VERSION),0.0.0)"

notices:
	@$(SCRIPTS)/third-party-notices.sh

# Runs Sparkle's generate_keys from the Updates package's SwiftPM artifact. It makes the EdDSA key
# that signs updates and keeps its private half in the login keychain under the bundle ID's
# account, or prints the public key of the one already there. For people, never for agents.
update-key:
	@$(SWIFTPM) $(ROOT)/Packages/Updates package resolve
	@$(ROOT)/Packages/Updates/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account $(BRAND_BUNDLE_ID)
