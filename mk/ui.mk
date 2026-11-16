# Targets for the Swift UI packages (LauncherUI, Host, SettingsUI). The Makefile includes every
# mk/*.mk, so add targets here without editing it. Document each new target with a
# "#   make <target>  <what it does>" line, which make help prints.
#
# LauncherUI's demo runs as an app through LaunchServices without taking focus. Captures go to
# UI_DEMO_OUT (default build/ui-demo). UI_ARGS passes options to the mode, such as
# UI_ARGS="themes=beam states=form".
#   make ui-shots           LauncherUI capture matrix, contact sheets and contrast table
#   make ui-components      LauncherUI grid, detail, cards, form, chips, empty state and HUD sheets
#   make ui-bench           LauncherUI latency tables and budget verdicts, measured as an app
#   make ui-type            LauncherUI synthetic typing through the real keystroke path
#   make ui-accessibility   LauncherUI panel read through the accessibility API, in process
#   make ui-legibility      LauncherUI contrast over a sweep of glass tints
#   make test-LauncherUI-budget  LauncherUI main-thread budget tests in a release build
#   make ui-showcase        regenerate the site/media product pictures; SHOTS=a,b and TONES=dark limit it
#   make ui-record          LauncherUI clip in motion after 120 s idle, then MP4 and GIF copies

UI_DEMO_MODES := ui-shots ui-components ui-bench ui-type ui-accessibility ui-legibility
.PHONY: $(UI_DEMO_MODES) test-LauncherUI-budget ui-showcase ui-record

$(UI_DEMO_MODES):
	@$(SCRIPTS)/ui-demo.sh $(patsubst ui-%,%,$@) $(UI_ARGS)

# Both wait for an idle Mac before anything takes key status, so allow up to 35 minutes.
ui-showcase:
	@$(SCRIPTS)/ui-showcase.sh $(if $(SHOTS),shots=$(SHOTS)) $(if $(TONES),tones=$(TONES))

ui-record:
	@UI_DEMO_TIMEOUT=$${UI_DEMO_TIMEOUT:-2100} $(SCRIPTS)/ui-demo.sh record

test-LauncherUI-budget:
	@$(SWIFTPM) $(ROOT)/Packages/LauncherUI test -c release --filter LatencyBudgetTests
