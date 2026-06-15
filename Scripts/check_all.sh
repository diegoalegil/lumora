#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# check_all.sh — build + verify every package and run the license firewall gate.
# CLT-only friendly: uses executable "Checks" targets instead of `swift test`.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

fail=0
run() { echo; echo "── $1 ───────────────────────────────────────────"; shift; "$@" || fail=1; }

run "Firewall audit" bash Scripts/audit_licenses.sh
run "WECore checks"  bash -c 'cd Packages/WECore && swift run -q WECoreChecks'
run "WallpaperShell checks" bash -c 'cd Packages/WallpaperShell && swift run -q WallpaperShellChecks'
run "WEImporter checks" bash -c 'cd Packages/WEImporter && swift run -q WEImporterChecks'
run "LumoraApp build" bash -c 'cd Packages/LumoraApp && swift build'

echo
if [ "$fail" -ne 0 ]; then echo "RESULT: FAILED"; exit 1; fi
echo "RESULT: ALL GREEN"
