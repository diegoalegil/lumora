<!-- GENERATED/maintained alongside Scripts/audit_licenses.sh. Do not add GPL entries. -->
# Third-party components & their licenses

This project ships **permissive code only**. The table is the auditable ledger of every
package's license posture and any external component reused.

## Local packages (this repo)
| Package | License posture | Provenance |
|---|---|---|
| LumoraApp | MIT (own) | clean-room (thin menu-bar shell) |
| WECore | MIT | clean-room (WE public docs + observed project.json) |
| WallpaperShell | MIT | clean-room (Apple docs) |
| WEImporter | Apache-2.0 | permissive-adapted + clean-room |
| WEShaderKit | Apache-2.0 | clean-room front-end + permissive vendored back-end |
| WEScene | MIT | clean-room (WE docs + behavioral oracle) |
| WESceneDynamics | MIT | clean-room (WE docs + Apple frameworks) |
| WEPlayers | MIT | clean-room (Apple frameworks) |
| Direct/FFmpegHelper | LGPL (out-of-process, **Direct build only**, never statically linked) | external |
| WEParityTools / WEOracle | test-only, **never shipped** (may run the GPL oracle as a black box) | quarantined |

## External components (planned)
| Component | License | Use | Integration |
|---|---|---|---|
| glslang | BSD/Apache-2.0 | GLSL→SPIR-V | prebuilt xcframework in WEShaderKit |
| SPIRV-Cross | Apache-2.0 / MIT | SPIR-V→MSL | prebuilt xcframework in WEShaderKit |
| SPIRV-Tools | Apache-2.0 | SPIR-V opt | prebuilt xcframework in WEShaderKit |
| qwertyadrian/wextractor | MIT | importer reference | docs/adaptation only, attributed |
| trinityhades/WallpaperExtractor | Apache-2.0 | importer reference | docs/adaptation only, NOTICE attribution |
| FFmpeg (libav*) | LGPL-2.1+ | webm→mp4 transcode | separate sandboxed process, Direct build only |

## Forbidden (oracle + public docs ONLY — never source)
- `Almamu/linux-wallpaperengine` — GPL-3.0
- `Unayung/wallpaper-engine-mac`, `MrWindDog/wallpaper-engine-mac` — GPL-3.0
