# Contributing

Lumora is permissively licensed (MIT, with Apache-2.0 for a couple of components) and is built so a
future Mac App Store / commercial release stays possible. That only holds if no copyleft (GPL) code
makes it into the shipped sources.

## License hygiene (please read)
- **Never copy, translate, or adapt GPL-licensed source into this project.** The most complete
  reference implementation of the Wallpaper Engine scene runtime, `linux-wallpaperengine`, is
  GPL-3.0, and the existing macOS port is GPL-3.0 too.
- You may consult those projects only for their **publicly documented file formats** and their
  **observable runtime behavior** (run them, compare output). Don't read their renderer/parser
  source while writing ours, and never paste or port it.
- Keep GPL reference checkouts **outside the repo** (e.g. under `~/we-refs`, which is git-ignored).

## Reuse that's fine (with attribution)
- MIT/Apache projects such as `wextractor` (MIT) and `WallpaperExtractor` (Apache-2.0) may guide the
  importer; record any adaptation in `LICENSES/THIRD_PARTY.md`.
- `repkg` documents the `.pkg`/`.tex` formats — treat it as a format reference.
- `glslang` / `SPIRV-Cross` / `SPIRV-Tools` (permissive) are vendored as a prebuilt xcframework
  behind a Swift facade so their C++ stays contained.

## Per-file hygiene
- Every source file under `Packages/*/Sources/**` starts with an `// SPDX-License-Identifier:`
  header (MIT or Apache-2.0) and a short `// Provenance:` note.
- `Scripts/audit_licenses.sh` enforces this and scans the tree for copyleft. It runs in CI and as a
  pre-commit hook — enable it locally with `bash Scripts/install-hooks.sh`.
- Keep the package dependency graph one-directional: app → feature packages → core packages.

## Trademark
This project is not affiliated with Wallpaper Engine or Valve. Don't ship that product's name, logo,
or bundled assets, and don't market Lumora using its trademark.
