#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# audit_licenses.sh — the LICENSE FIREWALL gate. Blocking check (run in CI + pre-commit hook).
#
# Guarantees for every SHIPPED package under Packages/ :
#   1. Every source file (swift/c/c++/obj-c/metal/glsl) under Sources/ has a permissive
#      SPDX-License-Identifier header (MIT/Apache-2.0/BSD) — never copyleft.
#   2. Every such file has a `// Provenance:` line.
#   3. No Package.swift / Package.resolved references a copyleft SPDX token or a blocklisted GPL
#      reference repo (linux-wallpaperengine, wallpaper-engine-mac, wallpaper-player-mac).
#   4. CONTENT-based GPL scan across the WHOLE tree (not just *.swift, not just a magic dir name):
#        - no file carries an SPDX copyleft identifier
#        - no LICENSE/COPYING file contains the GNU GPL text
#        - no directory named we-refs is checked in
#      This catches a GPL reference clone under ANY name, and GPL .cpp/.h/.glsl/.metal sources.
#   5. No shipped package depends on the quarantined test tooling (WEParityTools/WEOracle).
#
# Quarantined test tooling (Packages/WEParityTools, Packages/WEOracle) is exempt from the SPDX
# header rule (rule 1/2) — it never ships — but it is STILL subject to rules 3, 4 and 5.
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

echo "── License firewall audit ───────────────────────────────────────────────"

# 1 & 2: per-file permissive SPDX + Provenance on shipped sources (any source language).
src_files=$(find Packages -type f -path '*/Sources/*' 2>/dev/null | grep -E "$SRC_EXT" \
            | grep -Ev "$QUARANTINE_RE" || true)
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
  if echo "$manifests" | tr '\n' '\0' | xargs -0 grep -nEi 'linux-wallpaperengine|wallpaper-engine-mac|wallpaper-player-mac|A?GPL-[0-9]' 2>/dev/null; then
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

# 4b: CONTENT scan — no GNU GPL license text in any LICENSE/COPYING file (catches a GPL clone
#     committed under any directory name).
license_files=$(find . -path ./.git -prune -o -type d -name .build -prune -o \
                -type f \( -name 'LICENSE' -o -name 'LICENSE.*' -o -name 'COPYING' -o -name 'COPYING.*' \) -print 2>/dev/null || true)
gpl_license=""
if [ -n "$license_files" ]; then
  while IFS= read -r lf; do
    [ -z "$lf" ] && continue
    if grep -qi 'GNU GENERAL PUBLIC LICENSE\|GNU AFFERO\|GNU LESSER GENERAL PUBLIC' "$lf"; then
      gpl_license="${gpl_license}${lf}\n"
    fi
  done <<< "$license_files"
fi
if [ -n "$gpl_license" ]; then
  err "GNU GPL license text found in a checked-in LICENSE/COPYING file:"; printf '%b' "$gpl_license"
else
  ok "no GNU GPL license text in checked-in LICENSE/COPYING files"
fi

# 4c: no GPL reference material directory checked in.
if find . -type d -name 'we-refs' -not -path './.git/*' 2>/dev/null | grep -q .; then
  err "GPL reference material (we-refs/) found inside the repo — it must live under ~/we-refs"
else
  ok "no we-refs/ reference material checked into the tree"
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
