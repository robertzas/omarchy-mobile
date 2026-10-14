#!/bin/bash
# SPDX-License-Identifier: MIT
# Inside the conformance container: the reference walk of one widget with a
# fixture, printing each Text's text (for probes of expression semantics).
set -euo pipefail
cd /ref/omarchy-widgets/runtimes/quickshell/test
node walk.js ../Owl.js "$1" "$2"
