"""The CR-1 clamp kit, from a hand-modelled Rhino file (CR-1 Clamp Kit - Accessories.3dm).

The file is a reference scene on the CR-1 bed (z = 0 is the bed top, −y points at the spindle,
x runs left–right), with two universal clamps, spacers, an acetal squaring brick and hex
eccentric clamps laid out along the bed. This module cuts it into kits, each in its own local
frame, and stores the meshes in `resources/fixtures/cr1_clamp_kit.npz` for the app:

    clamp       universal clamp: body, soft jaw, feet, insulators, bolts, washers, T-slot nuts
    spacer_u    U-shaped spacer block (raises thin stock in the clamp)
    spacer_cube 1" spacer cube
    brick       acetal squaring brick with its bolts, washers and T-slot nuts
    eccentric   hex eccentric clamp on its T-slot nut (one per slot)

Kit-local frame: x toward the spindle (−y in the file), y across (x in the file, centred on
the kit), z up from the bed top. Measurements used by the app (UniversalClamp.swift) come from
the same geometry.

Rebuild after editing the Rhino file:
    uv run python -m coastline_engine.fixture_kit "/path/to/CR-1 Clamp Kit - Accessories.3dm"
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

from .cad_import import Mesh, tessellate

OUT = Path(__file__).resolve().parents[2] / "resources/fixtures/cr1_clamp_kit.npz"

# Linear RGB.
ALUMINIUM = (0.50, 0.52, 0.56)
JAW = (0.62, 0.64, 0.68)
INSULATOR = (0.45, 0.16, 0.04)
BLACK_OXIDE = (0.05, 0.05, 0.055)
STEEL = (0.32, 0.33, 0.35)
ACETAL = (0.80, 0.79, 0.74)

# (layer leaf name) → (role, colour)
ROLES = {
    "Universal Clamp Body": ("body", ALUMINIUM),
    "Universal Soft Jaw": ("soft_jaw", JAW),
    "Clamp Feet": ("feet", ALUMINIUM),
    "Insulator Sheet": ("insulator", INSULATOR),
    "Insulator Washer": ("insulator", INSULATOR),
    "M4x90 Socket Bolt Partially Threaded": ("fastener", BLACK_OXIDE),
    "M4x20 Socket Bolt Fully Threaded": ("fastener", BLACK_OXIDE),
    "M4x35 Socket Bolt Fully Threaded": ("fastener", BLACK_OXIDE),
    "M5x6 Socket Bolt Fully Threaded": ("fastener", BLACK_OXIDE),
    "M4x25 Socket Bolt Fully Threaded": ("fastener", BLACK_OXIDE),
    "M4 Washer": ("fastener", STEEL),
    "M4 Washers": ("fastener", STEEL),
    "M4 Single Nut with Offset Hole Flanged Button Head": ("fastener", STEEL),
    "Spacer Block U Shape": ("spacer", ALUMINIUM),
    "Spacer Cube 1\"": ("spacer", ALUMINIUM),
    "Acetate Brick": ("brick", ACETAL),
    "Vise Hexagonal Eccentric Fixture Clamps": ("eccentric", STEEL),
}

# File x of each kit's centre, and which objects belong to it (by file x range).
CLAMP_X = 109.525        # right-hand clamp (the left one is its mirror)
BRICK_X = -141.03
ECCENTRIC_X = 141.08


def _kit_of(layer_path: str, cx: float) -> tuple[str, float] | None:
    leaf = layer_path.split("::")[-1]
    if "Vise Hexagonal" in layer_path:
        return "eccentric", ECCENTRIC_X
    if layer_path.startswith("Acetate"):
        return "brick", BRICK_X
    if leaf == "Spacer Block U Shape":
        return "spacer_u", -CLAMP_X
    if leaf == 'Spacer Cube 1"':
        return "spacer_cube", CLAMP_X
    if layer_path.startswith("Universal Clamp Kit Assembly"):
        # The brick's and the eccentric clamps' T-slot nuts live on the clamp kit's nut layer.
        if "M4 Single Nut" in leaf and cx < -125:
            return "brick", BRICK_X
        if "M4 Single Nut" in leaf and cx > 125:
            return "eccentric", ECCENTRIC_X
        if 90 < cx < 130:
            return "clamp", CLAMP_X
        return None  # the mirrored left clamp: same parts
    return None


def extract(path: str | Path) -> list[dict]:
    import rhino3dm

    from .rhino_exact import _brep_to_shape

    f = rhino3dm.File3dm.Read(str(path))
    parts: list[dict] = []
    for o in f.Objects:
        a = o.Attributes
        if getattr(a, "IsInstanceDefinitionObject", False):
            continue
        layer = f.Layers[a.LayerIndex].FullPath
        leaf = layer.split("::")[-1]
        g = o.Geometry
        if leaf not in ROLES:
            continue
        b = g.GetBoundingBox()
        kit = _kit_of(layer, (b.Min.X + b.Max.X) / 2)
        if kit is None:
            continue
        name, cx = kit
        brep = g.ToBrep(True) if type(g).__name__ == "Extrusion" else g
        shape = _brep_to_shape(brep)
        if shape is None:
            continue
        mesh, _ = tessellate(shape, 0.04, 0.35)
        v = mesh.vertices.astype(np.float64)
        n = mesh.normals.astype(np.float64)
        # File (x, y, z) → kit (−y, x − cx, z): a proper rotation about z.
        local = np.c_[-v[:, 1], v[:, 0] - cx, v[:, 2]].astype(np.float32)
        normals = np.c_[-n[:, 1], n[:, 0], n[:, 2]].astype(np.float32)
        role, colour = ROLES[leaf]
        parts.append({"kit": name, "name": leaf, "role": role, "color": colour,
                      "mesh": Mesh(local, normals, mesh.indices)})
    return parts


def save(parts: list[dict], out: Path = OUT) -> None:
    arrays, meta = {}, []
    for i, p in enumerate(parts):
        arrays[f"v{i}"], arrays[f"n{i}"], arrays[f"t{i}"] = p["mesh"].vertices, p["mesh"].normals, p["mesh"].indices
        meta.append({k: p[k] for k in ("kit", "name", "role", "color")})
    arrays["meta"] = np.frombuffer(json.dumps(meta).encode(), np.uint8)
    out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(out, **arrays)


def load(path: Path = OUT) -> list[dict]:
    data = np.load(path)
    meta = json.loads(bytes(data["meta"]).decode())
    return [dict(m, mesh=Mesh(data[f"v{i}"], data[f"n{i}"], data[f"t{i}"])) for i, m in enumerate(meta)]


if __name__ == "__main__":
    src = sys.argv[1]
    parts = extract(src)
    step = OUT.parent / "c_clamp.step"
    if step.exists():
        parts += c_clamp_parts(step)
    save(parts)
    kits: dict[str, int] = {}
    for p in parts:
        kits[p["kit"]] = kits.get(p["kit"], 0) + len(p["mesh"].indices)
    print(f"{len(parts)} parts → {OUT.name} ({OUT.stat().st_size / 1e6:.1f} MB):",
          ", ".join(f"{k} {v} triangles" for k, v in kits.items()))


# ---------------------------------------------------------------- 3" C-clamp

ZINC = (0.62, 0.64, 0.66)
CAST_IRON = (0.04, 0.04, 0.045)

# The C-clamp model (resources/fixtures/c_clamp.step: frame, screw, swivel pad, T-handle)
# is a generic clamp: 60 mm from the fixed jaw to the screw boss, 47.5 mm throat. Coast Runner's
# kit has 3" clamps: scaled along the screw to open 76.2 mm with the pad (9 mm) on, and in depth
# to a 50 mm throat (FlatPrep.clampOpening / clampThroat).
C_JAW_X, C_AXIS_Y = 11.0, 24.55      # fixed jaw face, screw axis (model file)
C_SCALE = (85.2 / 60.0, 50.0 / 47.5, 1.0)


def c_clamp_parts(step_path: str | Path) -> list[dict]:
    """Kit "cclamp" in its own frame: x along the screw from the fixed jaw's face (the pad
    side is +x), y from the screw axis toward the frame's spine, z across. The screw, pad and
    handle are role "screw" (the app slides them along x to the stock); the frame is fixed."""
    from OCP.STEPControl import STEPControl_Reader
    from OCP.TopAbs import TopAbs_SOLID
    from OCP.TopExp import TopExp_Explorer

    r = STEPControl_Reader()
    r.ReadFile(str(step_path))
    r.TransferRoots()
    e = TopExp_Explorer(r.OneShape(), TopAbs_SOLID)
    solids = []
    while e.More():
        solids.append(e.Current())
        e.Next()
    names = ["C-clamp frame", "C-clamp screw", "C-clamp swivel pad", "C-clamp T-handle"]
    out = []
    for k, solid in enumerate(solids[:4]):
        mesh, _ = tessellate(solid, 0.05, 0.3)
        v = mesh.vertices.astype(np.float64).copy()
        zc = 78.05
        v = np.stack([(v[:, 0] - C_JAW_X) * C_SCALE[0], (v[:, 1] - C_AXIS_Y) * C_SCALE[1], (v[:, 2] - zc) * C_SCALE[2]], 1)
        n = mesh.normals.astype(np.float64) / np.array(C_SCALE)
        n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)
        out.append({"kit": "cclamp", "name": names[k], "role": "frame" if k == 0 else "screw",
                    "color": CAST_IRON if k == 0 else ZINC,
                    "mesh": Mesh(v.astype(np.float32), n.astype(np.float32), mesh.indices)})
    return out


def add_c_clamp(step_path: str | Path, out: Path = OUT) -> None:
    parts = [p for p in load(out) if p["kit"] != "cclamp"] + c_clamp_parts(step_path)
    save(parts, out)
