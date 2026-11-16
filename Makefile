# Build entry points. The logic lives in scripts/, so CI, Xcode and people run the same code.
# Each area can add targets in its own mk/<area>.mk, included at the end, without editing this file.
#
# Targets (make help prints this list):
#   make bootstrap        check toolchains, build the Rust core, resolve packages
#   make core             rebuild the Rust static library and its C header
#   make app              build and bundle build/<name>.app (CONFIG=debug for a debug build)
#   make run              build, then launch through LaunchServices (for people, not agents)
#   make selftest         build, then run --selftest directly and through LaunchServices
#   make test             every Rust and Swift test (make -j4 test runs them in parallel)
#   make test-rust        every Rust test, ended after RUST_TEST_TIMEOUT seconds (default 900)
#   make test-<Pkg>       one Swift package's tests, for example make test-Kit
#   make test-scripts     the scripts that install, publish pictures and bound test runs, in a
#                         temporary folder that never reaches the Mac or the site
#   make bench            latency tables from the app bundle (NAME=<bench> picks one)
#   make scenario S=<f>   scripted UI run from scenario file <f>
#   make lint             rustfmt, clippy, swift format, manifest, brand, LaunchServices and media checks
#   make fmt              format Rust and Swift sources in place
#   make xcode            generate the optional Xcode project with XcodeGen
#   make clean            remove every build output

SHELL := /bin/bash
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD := $(ROOT)/build
CONFIG ?= release
SCRIPTS := $(ROOT)/scripts
SWIFTPM := $(SCRIPTS)/swiftpm.sh
CARGO := $(SCRIPTS)/cargo.sh

# BRAND_NAME and friends. Never write the product name in a recipe; use these.
include $(ROOT)/support/brand.env
APP := $(BUILD)/$(BRAND_NAME).app
# SwiftPM's name for the executable. scripts/bundle.sh renames it to BRAND_NAME inside the bundle.
EXECUTABLE := Slick

# Every Swift package, core and feature, by directory and by name.
PACKAGE_DIRS := $(patsubst %/Package.swift,%,$(wildcard $(ROOT)/Packages/*/Package.swift $(ROOT)/Packages/Features/*/Package.swift))
PACKAGES := $(notdir $(PACKAGE_DIRS))
TEST_TARGETS := $(addprefix test-,$(PACKAGES))
# Packages that link the Rust static library, so their tests need it built first.
RUST_LINKED_TESTS := test-CoreBridge test-Root test-App
SWIFT_SOURCES = $(foreach d,$(PACKAGE_DIRS),$(wildcard $(d)/Package.swift $(d)/Sources $(d)/Tests))

.DEFAULT_GOAL := app
.PHONY: help bootstrap core app run selftest test test-rust test-scripts bench scenario lint fmt xcode clean $(TEST_TARGETS)

help:
	@sed -n 's/^#   //p' $(MAKEFILE_LIST)

bootstrap:
	@$(SCRIPTS)/bootstrap.sh

core:
	@$(SCRIPTS)/build-rust.sh release

app: core
	@$(SWIFTPM) $(ROOT)/Packages/App build -c $(CONFIG) --product $(EXECUTABLE)
	@$(SCRIPTS)/bundle.sh "$$($(SWIFTPM) $(ROOT)/Packages/App build -c $(CONFIG) --show-bin-path)/$(EXECUTABLE)" \
	    "$(BUILD)" $(CONFIG)

run: app
	@$(SCRIPTS)/run.sh "$(APP)"

selftest: app
	@$(SCRIPTS)/selftest.sh "$(APP)"

test: test-rust test-scripts $(TEST_TARGETS)

# A hung Rust test fails the run instead of hanging it. time_limit, in scripts/lib/env.sh, ends cargo
# and every test process under it after RUST_TEST_TIMEOUT seconds and returns 124. The workspace
# takes under a minute on a loaded Mac.
RUST_TEST_TIMEOUT ?= 900
test-rust:
	@. $(SCRIPTS)/lib/env.sh && time_limit $(RUST_TEST_TIMEOUT) $(CARGO) test --locked --workspace

test-scripts:
	@$(SCRIPTS)/test-scripts.sh

$(RUST_LINKED_TESTS): core

# Static pattern rule: make never applies a plain pattern rule to a .PHONY target.
$(TEST_TARGETS): test-%:
	@$(SWIFTPM) $(filter %/$*,$(PACKAGE_DIRS)) test

bench: app
	@$(SCRIPTS)/bench.sh "$(APP)" $(NAME)

scenario: app
	@if [ -z "$(S)" ]; then echo "usage: make scenario S=<scenario file>" >&2; exit 2; fi
	@$(SCRIPTS)/scenario.sh "$(APP)" "$(S)"

lint:
	@$(CARGO) fmt --all --check
	@$(CARGO) clippy --locked --workspace --all-targets -- -D warnings
	@swift format lint --strict --recursive $(SWIFT_SOURCES)
	@$(SCRIPTS)/check-manifests.sh
	@$(SCRIPTS)/check-brand.sh
	@$(SCRIPTS)/check-launchservices.sh --self-test
	@$(SCRIPTS)/check-launchservices.sh
	@python3 -I scenarios/media/check.py

fmt:
	@$(CARGO) fmt --all
	@swift format --in-place --recursive $(SWIFT_SOURCES)

xcode: core
	@$(SCRIPTS)/info-plist.sh "$(BUILD)/Info.plist"
	@set -a && . $(ROOT)/support/brand.env && set +a && \
	    xcodegen generate --spec $(ROOT)/project.yml --project $(ROOT) --quiet
	@echo "generated $(BRAND_NAME).xcodeproj"

clean:
	rm -rf "$(BUILD)" "$(ROOT)/core/target" "$(ROOT)/Packages/CoreBridge/Artifacts" "$(ROOT)/$(BRAND_NAME).xcodeproj"
	rm -rf $(addsuffix /.build,$(PACKAGE_DIRS))

include $(wildcard $(ROOT)/mk/*.mk)
