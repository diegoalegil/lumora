#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Provenance: clean-room. Negative self-test for the license-firewall gate (Scripts/audit_licenses.sh).
# It plants each kind of GPL breach the firewall must catch, asserts the audit FAILS with the right message,
# then asserts the restored clean tree PASSES. Wired into check_all.sh so CI proves the gate actually bites —
# a firewall that is only ever exercised on a clean tree can silently rot when the audit is edited. Every
# planted file is removed on exit (even on failure). NOTE: the GNU GPL license title is assembled from two
# fragments at runtime so THIS script's own source never carries the contiguous phrase (which would make the
# audit's content scan flag the self-test itself).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

AUDIT=(bash Scripts/audit_licenses.sh)
TMP="__firewall_selftest__"                                   # a throwaway dir for path/dir/license plants
PLANT_SRC="Packages/WECore/Sources/WECore/__firewall_selftest__.swift"  # a plant under real shipped Sources/
cleanup() { rm -rf "$ROOT/$TMP" "$ROOT/$PLANT_SRC"; }
trap cleanup EXIT
cleanup                                                       # known-clean slate before we start

RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'
fail=0

# Run the audit with a breach already planted; assert it exits non-zero AND prints $2. Then clean up.
expect_fail() { # description  needle
  local out rc
  out=$("${AUDIT[@]}" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "${RED}✗ self-test: '$1' did NOT fail the audit${RST}"; fail=1
  elif ! printf '%s' "$out" | grep -qF "$2"; then
    echo "${RED}✗ self-test: '$1' failed, but without the expected message ($2)${RST}"; fail=1
  else
    echo "${GRN}✓ firewall catches: $1${RST}"
  fi
  cleanup
}
expect_pass() { # description
  local out rc
  out=$("${AUDIT[@]}" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "${RED}✗ self-test: clean tree did NOT pass ($1)${RST}"; printf '%s\n' "$out" | tail -4; fail=1
  else
    echo "${GRN}✓ clean tree passes ($1)${RST}"
  fi
}

echo "── License firewall SELF-TEST ───────────────────────────────────────────"
expect_pass "baseline (before any plant)"

# 1) A GPL source dropped OUTSIDE Packages/*/Sources/* (a vendored clone) with no permissive SPDX header.
mkdir -p "$TMP/wpe"; printf '// gpl source\nint renderFrame() { return 0; }\n' > "$TMP/wpe/CWallpaper.cpp"
expect_fail "GPL source under a vendor-like dir (no SPDX header)" "missing SPDX header"

# 2) GNU GPL license text anywhere in the tree (here a clone's LICENSE under an innocuous dir name).
gpl_title="GNU GENERAL PUBLIC"; gpl_title="$gpl_title LICENSE"      # assembled so this file lacks the phrase
mkdir -p "$TMP/clone"; printf '%s\nVersion 3, 29 June 2007\n' "$gpl_title" > "$TMP/clone/LICENSE"
expect_fail "GNU GPL license text in the tree" "GNU GPL license text found"

# 3) A directory cloned under a known GPL oracle repo name.
mkdir -p "$TMP/linux-wallpaperengine"; printf 'readme\n' > "$TMP/linux-wallpaperengine/README.md"
expect_fail "GPL oracle repo directory" "GPL reference material directory"

# 4) A forged-permissive-header source whose Provenance admits a GPL translation (passes rule 1, caught by 4d).
printf '// SPDX-License-Identifier: MIT\n// Provenance: Verbatim translation of Almamu/linux-wallpaperengine renderFrame.\nenum FirewallSelfTest { static let marker = 42 }\n' > "$PLANT_SRC"
expect_fail "forged-header source naming a GPL oracle repo" "names a GPL oracle repo"

expect_pass "after all plants removed (tree restored)"

echo "─────────────────────────────────────────────────────────────────────────"
if [ "$fail" -ne 0 ]; then echo "${RED}FIREWALL SELF-TEST: FAILED${RST}"; exit 1; fi
echo "${GRN}FIREWALL SELF-TEST: PASSED${RST}"
