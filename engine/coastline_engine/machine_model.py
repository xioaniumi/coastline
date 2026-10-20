"""The CR-1 machine model for the viewport, built from Coast Runner's assembly STEP.

The STEP (COAST RUNNER CR-1 MECHANICALS V1.3) is organised by motion group, and its world
axes are the machine axes:
    +x  machine X, physically **up** (the table is a horizontal plate moving vertically)
    +y  machine Y, the gantry, to the operator's right
    +z  machine Z, the spindle axis; the tool points toward -z (plunge = Z-)
So the CR-1 is a horizontal-spindle mill: the stock stands on the table and the spindle comes
at it sideways.

Top-level subassemblies → motion groups:
    "Subassembly X - Table"            → x   (moves with X)
    "Subassembly YZ - Translator"      → y   (moves with Y)
    "Subassembly Z"                    → z   (moves with Y and Z)
    everything else                    → static
Every part is kept (fasteners included). The result is cached on disk.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from OCP.BRepBndLib import BRepBndLib
from OCP.Bnd import Bnd_Box
from OCP.STEPCAFControl import STEPCAFControl_Reader
from OCP.TCollection import TCollection_ExtendedString
from OCP.TDF import TDF_Label
from OCP.TDataStd import TDataStd_Name
from OCP.TDocStd import TDocStd_Document
from OCP.TopLoc import TopLoc_Location
from OCP.XCAFDoc import XCAFDoc_DocumentTool
from OCP.collections import Sequence_TDF_Label

from .cad_import import Mesh, tessellate

GROUPS = {
    "Subassembly X - Table": "x",
    "Subassembly YZ - Translator": "y",
    "Subassembly Z": "z",
}
ENCLOSURE_WORDS = ("outer enclosure", "rear cover", "chip guard - x top", "iec connector")
# Nothing is dropped: The complete machine is kept (fasteners included).
SKIP_WORDS: tuple[str, ...] = ()

# Display colours (linear RGB) by part role. Patterns are regular expressions matched at word
# starts, first match wins ("pin" must not match "spindle", a stepper mount is aluminium).
PALETTE = [
    ((r"enclosure", r"rear cover"), "enclosure", (0.80, 0.80, 0.78)),  # white paint
    ((r"chip guard",), "guard", (0.10, 0.10, 0.11)),
    ((r"spindle mount - lower",), "mirror", (0.90, 0.90, 0.92)),  # the polished plate on the spindle
    ((r"stepper(?! mount)", r"nema", r"spindle motor"), "motor", (0.02, 0.02, 0.022)),
    ((r"belt",), "belt", (0.015, 0.015, 0.015)),
    ((r"shaft", r"ballscrew", r"collet", r"er ?11", r"bearing", r"lm1[26]"), "steel", (0.55, 0.56, 0.58)),
    ((r"bolt", r"screw", r"nut", r"washer", r"pem", r"snap ring", r"pin\b", r"ansi b18", r"iso 7089",
      r"lock ring", r"standoff", r"m\d+x\d"), "fastener", (0.18, 0.18, 0.19)),
    ((r"pcb", r"led\b"), "pcb", (0.022, 0.022, 0.025)),  # black plastic on the real machine
    ((r"estop",), "estop", (0.6, 0.02, 0.01)),
]
DEFAULT_ROLE = ("aluminium", (0.32, 0.33, 0.35))


@dataclass
class MachinePart:
    group: str      # static | x | y | z
    role: str       # enclosure | motor | steel | aluminium | …
    color: tuple
    mesh: Mesh


def _name(label) -> str:
    n = TDataStd_Name()
    return n.Get().ToExtString() if label.FindAttribute(TDataStd_Name.GetID_s(), n) else ""


def _role(name: str) -> tuple[str, tuple]:
    low = name.lower()
    for words, role, color in PALETTE:
        if any(re.search(r"(?<![a-z])" + w, low) for w in words):
            return role, color
    return DEFAULT_ROLE


def _diag(shape) -> float:
    box = Bnd_Box()
    BRepBndLib.Add_s(shape, box, True)
    lo, hi = box.CornerMin(), box.CornerMax()
    return float(np.linalg.norm([hi.X() - lo.X(), hi.Y() - lo.Y(), hi.Z() - lo.Z()]))


def load_machine(step_path: str | Path, cache_dir: str | Path | None = None) -> list[MachinePart]:
    step_path = Path(step_path)
    cache = None
    if cache_dir:
        key = hashlib.sha1(f"{step_path.stat().st_size}-{step_path.stat().st_mtime_ns}-v5".encode()).hexdigest()[:12]
        cache = Path(cache_dir) / f"machine-{key}.npz"
        if cache.exists():
            return _read_cache(cache)

    doc = TDocStd_Document(TCollection_ExtendedString("cr1"))
    reader = STEPCAFControl_Reader()
    reader.SetNameMode(True)
    reader.ReadFile(str(step_path))
    reader.Transfer(doc)
    st = XCAFDoc_DocumentTool.ShapeTool_s(doc.Main())

    leaves: list[dict] = []

    def visit(label, location, group, path_enclosure):
        comps = Sequence_TDF_Label()
        st.GetComponents_s(label, comps)
        for c in comps:
            ref = TDF_Label()
            st.GetReferredShape_s(c, ref)
            name = _name(ref)
            low = name.lower()
            loc = location.Multiplied(st.GetLocation_s(c))
            g = GROUPS.get(name, group)
            # "Subassembly XY - Stationary with Outer Enclosure" holds the frame too; only its
            # "Outer Enclosure" child is the enclosure.
            enclosure = path_enclosure or (not low.startswith("subassembly xy") and any(w in low for w in ENCLOSURE_WORDS))
            sub = Sequence_TDF_Label()
            st.GetComponents_s(ref, sub)
            if len(sub):
                visit(ref, loc, g, enclosure)
                continue
            if SKIP_WORDS and any(w in low for w in SKIP_WORDS):
                continue
            shape = st.GetShape_s(ref).Moved(loc)
            d = _diag(shape)
            role, color = ("enclosure", PALETTE[0][2]) if enclosure else _role(name)
            # Tessellation scaled to the part: ~0.1 % of its size (0.02–0.5 mm), so screws stay
            # round and big panels stay light.
            mesh, _ = tessellate(shape, min(max(0.02, d * 0.001), 0.5), 0.35)
            leaves.append({"group": g, "role": role, "color": color, "mesh": mesh, "name": name, "enclosure": enclosure})

    roots = Sequence_TDF_Label()
    st.GetFreeShapes(roots)
    for root in roots:
        visit(root, TopLoc_Location(), "static", False)

    _attach_to_enclosure(leaves)
    buckets: dict[tuple[str, str], tuple[tuple, list[Mesh]]] = {}
    for leaf in leaves:
        role = leaf["role"]
        if leaf["enclosure"] and role != "enclosure":
            role = "enclosure_" + role  # mounted on the shell: hidden with it, keeps its colour
        buckets.setdefault((leaf["group"], role), (leaf["color"], []))[1].append(leaf["mesh"])
    parts = [MachinePart(g, role, color, Mesh.concat(meshes)) for (g, role), (color, meshes) in buckets.items()]
    if cache:
        cache.parent.mkdir(parents=True, exist_ok=True)
        _write_cache(cache, parts)
    return parts


def _attach_to_enclosure(leaves: list[dict], pitch: float = 1.0) -> None:
    """Marks static parts that are only held by the enclosure (the E-stop, connectors), and the
    screws on it, as part of it, so hiding the shell doesn't leave them floating. A part counts as
    held by the frame when its surface comes within a millimetre of any other static non-enclosure
    part; repeated until nothing changes (a nut on a screw on the shell goes too)."""
    import trimesh

    rng = np.random.default_rng(0)

    def cells(mesh: Mesh) -> np.ndarray:
        tm = trimesh.Trimesh(mesh.vertices, mesh.indices.reshape(-1, 3), process=False)
        n = min(max(100, int(tm.area / (pitch * pitch))), 400_000)
        pts, _ = trimesh.sample.sample_surface(tm, n, seed=rng)
        c = np.unique(np.floor(np.vstack([pts, tm.vertices]) / pitch).astype(np.int64), axis=0)
        # Dilate by one cell (face neighbours) so touching surfaces share cells.
        offs = np.array([[0, 0, 0], [1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]])
        return np.unique((c[:, None, :] + offs[None]).reshape(-1, 3), axis=0)

    static = [i for i, leaf in enumerate(leaves) if leaf["group"] == "static"]
    if not any(leaves[i]["enclosure"] for i in static):
        return
    vox = {i: cells(leaves[i]["mesh"]) for i in static}
    allc = np.vstack(list(vox.values()))
    base, span = allc.min(0) - 2, allc.max(0) - allc.min(0) + 5

    def key(c):
        return ((c[:, 0] - base[0]) * span[1] + (c[:, 1] - base[1])) * span[2] + (c[:, 2] - base[2])

    keys = {i: np.unique(key(v)) for i, v in vox.items()}
    changed = True
    while changed:
        changed = False
        frame = [i for i in static if not leaves[i]["enclosure"]]
        shell = [i for i in static if leaves[i]["enclosure"]]
        shell_keys = np.unique(np.concatenate([keys[i] for i in shell]))
        all_k = np.concatenate([keys[i] for i in frame])
        sizes = np.array([len(keys[i]) for i in frame])
        starts = np.r_[0, np.cumsum(sizes)[:-1]]
        # Cells owned by two or more frame parts: where frame parts touch each other.
        u, counts = np.unique(all_k, return_counts=True)
        shared = u[counts >= 2]
        on_shell = np.add.reduceat(np.isin(all_k, shell_keys).astype(np.int64), starts) > 0
        on_frame = np.add.reduceat(np.isin(all_k, shared).astype(np.int64), starts) > 0
        for i, a, b in zip(frame, on_shell, on_frame):
            # Fasteners on the shell go with it even when they thread into the frame: their
            # heads sit on the shell's surface and would float without it.
            if a and (not b or leaves[i]["role"] == "fastener"):
                leaves[i]["enclosure"] = True
                changed = True


def _write_cache(path: Path, parts: list[MachinePart]) -> None:
    arrays = {}
    meta = []
    for i, p in enumerate(parts):
        arrays[f"v{i}"], arrays[f"n{i}"], arrays[f"t{i}"] = p.mesh.vertices, p.mesh.normals, p.mesh.indices
        meta.append({"group": p.group, "role": p.role, "color": list(p.color)})
    arrays["meta"] = np.frombuffer(json.dumps(meta).encode(), np.uint8)
    np.savez_compressed(path, **arrays)


def _read_cache(path: Path) -> list[MachinePart]:
    data = np.load(path)
    meta = json.loads(bytes(data["meta"]).decode())
    return [MachinePart(m["group"], m["role"], tuple(m["color"]),
                        Mesh(data[f"v{i}"], data[f"n{i}"], data[f"t{i}"])) for i, m in enumerate(meta)]


# Reference geometry measured from the assembly (STEP world = machine axes, mm).
# Collet nut face (tool-holder end), on the spindle axis: ER11A nut spans z -20…-5 around
# (x≈0.5, y≈-82). The table's top face is x = -31.12 (raycast on the mesh, 2026-10-07).
SPINDLE_NOSE = (0.5, -82.0, -20.0)
TABLE_TOP_X = -31.12  # measured on the mesh (the bed top, between the T-slots)
# T-slot centres in the table (model Z), measured from the X Unibody section: 6.1 mm openings,
# 40 mm apart, the front one 11 mm from the table's spindle-side edge (z -2.4). Matches the
# Operator Manual §9.7.3. Fixtures bolt into these with M4 T-slot nuts.
TSLOT_Z = (-53.5, -13.4)
# The machine position (X, Y, Z) the assembly is modelled at, calibrated by moving it
# (machine_travel.py): each axis slides until a part first touches another (0.5 mm voxels), and
# the firmware travel is centred in that mechanical range.
#   X: table free 30.5 mm up (flange bearings reach the stepper mounts) / 58.0 down (shaft
#      supports): 88.5 mm for 85.5 of travel → −57.0. The X home switch tab triggers ~29 mm up.
#   Y: translator free 91.0 right (LM16UU reaches the motor bracket) / 151.5 left (spindle mount
#      reaches the electronics cover): 242.5 for 241.0 → −90.75.
#   Z: spindle free 81.0 out / 4.5 in (it's modelled almost fully plunged): 85.5 for 78.0 → −77.75.
# So the spindle axis sits at world y = machine Y + 8.75. ±1 mm until checked on the real
# machine (docs/FIRST_CUT.md).
MODEL_POSE = (-57.0, -90.75, -77.75)
