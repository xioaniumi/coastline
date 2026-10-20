# Third-party code and libraries

| Component | Where | Licence | Use |
|---|---|---|---|
| FreeCAD `Adaptive.cpp/.hpp` | `engine/native/third_party/freecad_adaptive/` | LGPL-2.1 (`LICENSE_FreeCAD_LGPL.txt`) | Constant-engagement adaptive clearing. Built as a separate dynamic module (`_native`). |
| Clipper 6 (`clipper.cpp/.hpp`, as shipped with FreeCAD) | same folder | Boost Software License | Polygon offsets for Adaptive. |
| Clipper2 2.0.1 | `engine/native/third_party/clipper2/` | Boost Software License (`LICENSE`) | Polygon clipping and offsets. |
| OpenCASCADE, via `cadquery-ocp` | pip | LGPL-2.1 with exception | STEP/IGES import and B-rep. |
| rhino3dm (openNURBS) | pip | MIT | Rhino `.3dm` import. |
| OpenCAMLib | pip | LGPL-2.1 | Drop-cutter and waterline. |
| pyclipper, numpy, trimesh | pip | MIT / BSD | 2D offsets, arrays, mesh utilities. |
| CRCore | `CRCore/` | GPL-3.0 (this project); a Swift port of Coast Runner's CRWrite v2, which is CC0 | `.crproj` model/writer, G-code classifier, GRBL protocol. |

## Coast Runner design files

Coast Runner, Inc. licenses "all design files and models by Coast Runner" under CC0 1.0 Universal
([archived licence page, June 2025](https://web.archive.org/web/20250619071646/https://coastrunner.net/license/)).
Included here with their geometry unchanged:

| File | What |
|---|---|
| `resources/machine/cr1_mechanicals_v1.3.step` | CR-1 mechanical assembly v1.3 |
| `resources/fixtures/universal_clamp_v96.step` | Universal clamp |
| `resources/fixtures/quick_release_jig_plate.step` | Quick release jig plate, Rev D (metric) |
| `resources/libraries/CR-tools-for-Aluminum.tools`, `CR-tools-for-Steel.tools` | Fusion tool libraries |
| `resources/libraries/Coast-Runner-CR-1-Machine-Model.mch` | Fusion machine definition |
| `docs/cr1_feeds_speeds_aluminum.pdf` | Feeds and speeds guide |

Coast Runner's Fusion post-processor is not included: it is copyright Autodesk, Inc. `CR1Post`
in CoastlineCore is an independent implementation.

