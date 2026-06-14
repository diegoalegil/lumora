# Contributing & the License Firewall

This project is **permissively licensed (MIT / Apache-2.0; BSD accepted for vendored permissive
components)** and is built so that a future Mac App Store / commercial release stays legally possible. That is only true
if we never let GPL-licensed code (or paraphrases of it) into the shipped graph.

## The one rule that matters
**Never read GPL source and then write shipped code in the same task.**

The only complete reference renderer for Wallpaper Engine scenes is
`Almamu/linux-wallpaperengine` (GPL-3.0), and the existing macOS port
`Unayung/wallpaper-engine-mac` is GPL-3.0 too. We use them **only** as:
- **Behavioral oracles** — run the binary, capture its output pixels, diff against ours.
- **Public documentation** — e.g. `docs/textures/TEXTURE_FORMAT.md` (prose facts).

We **never** read, copy, translate, or paraphrase their renderer/parser/particle/FFT
source into any shipped package.

### Two-context rule
Whoever inspects GPL/oracle **output** in a task must **not** author code for a
permissive package (`WECore`, `WallpaperShell`, `WEScene`, `WESceneDynamics`,
`WEPlayers`, `WEImporter`, `WEShaderKit`) in that same task. Run the oracle in the
quarantined `WEParityTools`/`WEOracle` test tooling only.

### Where GPL material lives
Outside the repo, under `~/we-refs` (git-ignored). It must never be committed,
grepped, or copied from.

## Allowed reuse (with attribution)
- `qwertyadrian/wextractor` (MIT), `trinityhades/WallpaperExtractor` (Apache-2.0) —
  may guide the **importer** (`WEImporter`); record adaptation in `provenance.json`
  and attribute in `LICENSES/THIRD_PARTY.md`.
- `notscuffed/repkg` — treat as a **format spec** (docs only).
- `glslang`, `SPIRV-Cross`, `SPIRV-Tools` (permissive) — vendored as a prebuilt
  xcframework behind a Swift facade inside `WEShaderKit` so C++ interop never
  propagates upward.

## Per-file hygiene
- Every source file under `Packages/*/Sources/**` starts with an
  `// SPDX-License-Identifier: MIT` (or `Apache-2.0`) header **and** a
  `// Provenance:` line.
- `Scripts/audit_licenses.sh` enforces this and runs as a **blocking** CI gate.
- Keep the SPM dependency graph **acyclic and one-directional**:
  `App → feature packages → core packages`. No package may depend on GPL.

## Trademark
Never name the product "Wallpaper Engine for Mac" and never ship Wallpaper Engine's
name, logo, or default assets. Codename only (currently **Lumora**).
