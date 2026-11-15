#!/bin/bash
# Launches the app through LaunchServices, as a person would.
#   scripts/run.sh <App.app>
#
# This is for the person at the keyboard. Agents and tests use --selftest, --bench or --scenario
# (see "Working on a live desktop" in docs/ARCHITECTURE.md).
set -euo pipefail
APP=${1:?usage: run.sh <App.app>}
open "$APP"
