#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Point git at the version-controlled hooks so the license-firewall pre-commit runs locally.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
git config core.hooksPath .githooks
echo "✓ core.hooksPath set to .githooks (pre-commit firewall active)"
