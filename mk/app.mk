# Targets for the app, bundling and signing (Packages/App, support/, scenarios/). The Makefile
# includes every mk/*.mk, so add targets here without editing it. Document each new target with a
# "#   make <target>  <what it does>" line, which make help prints.
#
#   make scenarios        every scenario in scenarios/, one after another, through LaunchServices
#   make app-size         the bundle's size, its largest parts and the dSYM beside it
#   make install          build the release app and copy it to /Applications, or INSTALL_DIR=<folder>;
#                         for people, never for agents. Quit the installed copy first
#   make uninstall        remove the installed app from /Applications, or INSTALL_DIR=<folder>; the
#                         data folder and settings stay. For people, never for agents

.PHONY: scenarios app-size install uninstall

# Each scenario shows the panel in a corner for well under two seconds. Run this while nobody types.
scenarios: app
	@status=0; for file in $(ROOT)/scenarios/*.json; do \
	    out=$$($(SCRIPTS)/scenario.sh "$(APP)" "$$file" 2>&1); \
	    echo "$$(basename $$file .json): $$(grep -E '^scenario (PASS|FAIL)' <<< "$$out" || echo 'no verdict')"; \
	    grep -q '^scenario PASS' <<< "$$out" || status=1; \
	done; exit $$status

app-size: app
	@du -sh "$(APP)" "$(APP)/Contents/MacOS/$(BRAND_NAME)" "$(APP)/Contents/Resources/Assets.car" \
	    "$(APP)/Contents/Resources/AppIcon.icns"
	@[ ! -d "$(APP).dSYM" ] || du -sh "$(APP).dSYM"
	@size -m "$(APP)/Contents/MacOS/$(BRAND_NAME)" | grep -E '^Segment __(TEXT|DATA|DATA_CONST|LINKEDIT):'

# The installed copy is the one the system knows: scripts/install.sh registers it and unregisters
# build's copy, and scripts/launch.sh keeps build's copy unregistered while an installed copy exists.
# docs/RELEASING.md, "Installing from a checkout".
install: override CONFIG := release
install: app
	@$(if $(INSTALL_DIR),INSTALL_DIR="$(INSTALL_DIR)") $(SCRIPTS)/install.sh install "$(APP)"

uninstall:
	@$(if $(INSTALL_DIR),INSTALL_DIR="$(INSTALL_DIR)") $(SCRIPTS)/install.sh uninstall
