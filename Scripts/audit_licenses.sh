#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# audit_licenses.sh — the LICENSE FIREWALL gate. Blocking check (run in CI + pre-commit hook).
#
# Guarantees (the firewall is TREE-WIDE — a GPL clone dropped under ANY path is caught, not just Sources/):
#   1. Every source file (swift/c/c++/obj-c/metal/glsl) ANYWHERE in the tree has a permissive
#      SPDX-License-Identifier header (MIT/Apache-2.0/BSD) — never copyleft. (Package.swift manifests are
#      exempt — the swift-tools-version line must come first — and are covered by rule 3 instead.)
#   2. Every such file has a `// Provenance:` line.
#   3. No Package.swift / Package.resolved references a copyleft SPDX token or a blocklisted GPL
#      reference repo (linux-wallpaperengine, wallpaper-engine-mac, wallpaper-player-mac, MrWindDog, haren724).
#   4. CONTENT-based GPL scan across the WHOLE tree (not just *.swift, not just a magic dir name):
#        4a. no file carries an SPDX copyleft identifier.
#        4b. no file ANYWHERE contains GNU GPL/AGPL/LGPL license text — catches a GPL .cpp/.h with the
#            classic header block, and a file given a forged permissive SPDX whose body is the GPL license.
#        4c. no directory is a known GPL oracle repo, nor named we-refs.
#        4d. no shipped/own source file NAMES a GPL oracle repo in its content — catches a forged-header
#            file whose Provenance/comments admit a GPL translation. (Docs may name them, to forbid them.)
#   5. No shipped package depends on the quarantined test tooling (WEParityTools/WEOracle).
#
# Quarantined test tooling (Packages/WEParityTools, Packages/WEOracle) is exempt from the per-file header
# rule (1/2) and the oracle-name rule (4d) — it never ships and may invoke the oracle as a black box — but
# it is STILL subject to rules 3, 4a, 4b, 4c and 5.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
fail=0
err()  { echo "${RED}✗ $*${RST}"; fail=1; }
ok()   { echo "${GRN}✓ $*${RST}"; }
warn() { echo "${YEL}! $*${RST}"; }

# Quarantined test tooling: anchored to real package paths (NOT an unanchored substring).
QUARANTINE_RE='Packages/(WEParityTools|WEOracle)/'
# Source file extensions we require headers on.
SRC_EXT='\.(swift|c|cc|cpp|cxx|m|mm|h|hh|hpp|metal|glsl|vert|frag)$'
# GPL "oracle" reference repos. They must never be a checked-in directory, a manifest dependency, or named
# inside a shipped/own source file — the oracle is run as an external black box, never vendored or translated.
GPL_REPOS_RE='linux-wallpaperengine|wallpaper-engine-mac|wallpaper-player-mac|MrWindDog|haren724'

# Every source file in the tree (any language), excluding VCS/build metadata. Used by the header check (1/2)
# and the oracle-name scan (4d). Computed once.
all_src=$(find . -type d \( -name .git -o -name .build -o -name .swiftpm \) -prune -o \
          -type f -print 2>/dev/null | grep -E "$SRC_EXT" | sed 's|^\./||' || true)

echo "── License firewall audit ───────────────────────────────────────────────"

# 1 & 2: per-file permissive SPDX + Provenance on EVERY source file in the tree (any source language, any
# path) — so a GPL source dropped outside Packages/*/Sources/* (vendor/, reference/, repo root) is caught.
# Package.swift manifests are exempt (their swift-tools-version line must come first); rule 3 covers them.
src_files=$(printf '%s\n' "$all_src" | grep -Ev '(^|/)Package\.swift$' | grep -Ev "$QUARANTINE_RE" || true)
if [ -z "$src_files" ]; then
  warn "no shipped source files found yet (ok during early scaffolding)"
else
  while IFS= read -r f; do
    head8=$(head -n 8 "$f")
    spdx=$(printf '%s\n' "$head8" | grep -E 'SPDX-License-Identifier:' || true)
    if [ -z "$spdx" ]; then
      err "missing SPDX header: $f"
    elif printf '%s' "$spdx" | grep -qiE 'GPL|AGPL|LGPL'; then
      err "copyleft SPDX in shipped file: $f  ($spdx)"
    elif ! printf '%s' "$spdx" | grep -qE 'MIT|Apache-2\.0|BSD'; then
      err "non-permissive/unknown SPDX in shipped file: $f  ($spdx)"
    fi
    if ! printf '%s\n' "$head8" | grep -qE 'Provenance:'; then
      err "missing // Provenance: line: $f"
    fi
  done <<< "$src_files"
  [ "$fail" -eq 0 ] && ok "all shipped sources carry permissive SPDX + Provenance"
fi

# 3: no copyleft token / blocklisted reference repo in package manifests.
manifests=$(find Packages -type f \( -name 'Package.swift' -o -name 'Package.resolved' \) 2>/dev/null || true)
if [ -n "$manifests" ]; then
  if echo "$manifests" | tr '\n' '\0' | xargs -0 grep -nEi "${GPL_REPOS_RE}|A?GPL-[0-9]" 2>/dev/null; then
    err "GPL / blocklisted reference in a package manifest (see above)"
  else
    ok "no GPL dependency or blocklisted reference repo in package manifests"
  fi
fi

# 4a: CONTENT scan — no SPDX copyleft identifier anywhere in the tree.
copyleft_hits=$(grep -rIlE 'SPDX-License-Identifier:[[:space:]]*(A|L)?GPL' . \
                --exclude-dir=.git --exclude-dir=.build --exclude-dir=.swiftpm 2>/dev/null || true)
if [ -n "$copyleft_hits" ]; then
  err "copyleft SPDX identifier found in tree:"; echo "$copyleft_hits"
else
  ok "no copyleft SPDX identifier anywhere in the tree"
fi

# 4b: CONTENT scan — no GNU GPL/AGPL/LGPL license text in ANY file in the tree (not just LICENSE/COPYING).
#     Catches a GPL .cpp/.h carrying the classic header comment block, and a file given a forged permissive
#     SPDX whose body is actually the GPL license. The audit script itself names the licenses (as detectors)
#     and is excluded by basename.
gpl_text_hits=$(grep -rIliE 'GNU (AFFERO |LESSER )?GENERAL PUBLIC LICENSE' . \
                --exclude-dir=.git --exclude-dir=.build --exclude-dir=.swiftpm \
                --exclude='audit_licenses.sh' 2>/dev/null || true)
if [ -n "$gpl_text_hits" ]; then
  err "GNU GPL license text found in the tree:"; echo "$gpl_text_hits"
else
  ok "no GNU GPL license text anywhere in the tree"
fi

# 4c: no GPL reference material directory checked in — neither the we-refs staging dir nor a directory named
#     after a known GPL oracle repo (a `git clone` of the oracle into the tree under its own name).
banned_dirs=$(find . -not -path './.git/*' -type d \
              \( -iname 'we-refs' -o -iname 'linux-wallpaperengine' -o -iname 'wallpaper-engine-mac' \
                 -o -iname 'wallpaper-player-mac' -o -iname 'mrwinddog' -o -iname 'haren724' \) \
              2>/dev/null || true)
if [ -n "$banned_dirs" ]; then
  err "GPL reference material directory found inside the repo (must live under ~/we-refs, never vendored):"; echo "$banned_dirs"
else
  ok "no GPL reference material directory checked into the tree"
fi

# 4d: no shipped/own source file NAMES a GPL oracle repo in its content. A forged-permissive-header file
#     whose Provenance/comments admit a translation from the oracle ("ported from linux-wallpaperengine")
#     passes rule 1 but is a firewall breach. Restricted to source files — docs legitimately name the repos
#     to forbid them — and quarantined tooling is exempt (it may invoke the oracle by name as a black box).
name_targets=$(printf '%s\n' "$all_src" | grep -Ev "$QUARANTINE_RE" || true)
if [ -n "$name_targets" ]; then
  oracle_hits=$(printf '%s\n' "$name_targets" | tr '\n' '\0' | xargs -0 grep -lIiE "$GPL_REPOS_RE" 2>/dev/null || true)
  if [ -n "$oracle_hits" ]; then
    err "a source file names a GPL oracle repo in its content (firewall: never translate/vendor the oracle):"; echo "$oracle_hits"
  else
    ok "no source file references a GPL oracle repo"
  fi
fi

# 5: shipped packages must not depend on the quarantined test tooling.
shipped_manifests=$(echo "$manifests" | grep -Ev "$QUARANTINE_RE" || true)
if [ -n "$shipped_manifests" ]; then
  if echo "$shipped_manifests" | tr '\n' '\0' | xargs -0 grep -nE 'WEParityTools|WEOracle' 2>/dev/null; then
    err "a shipped package depends on quarantined test tooling (see above)"
  else
    ok "no shipped package depends on quarantined test tooling"
  fi
fi

echo "─────────────────────────────────────────────────────────────────────────"
if [ "$fail" -ne 0 ]; then
  echo "${RED}LICENSE FIREWALL: FAILED${RST}"
  exit 1
fi
echo "${GRN}LICENSE FIREWALL: PASSED${RST}"
