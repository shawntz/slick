# Targets for the app, bundling and signing (Packages/App, support/, scenarios/). The Makefile
# includes every mk/*.mk, so add targets here without editing it. Document each new target with a
# "#   make <target>  <what it does>" line, which make help prints.
#
#   make scenarios        every scenario in scenarios/, one after another, through LaunchServices
#   make app-size         the bundle's size, its largest parts and the dSYM beside it

.PHONY: scenarios app-size

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
