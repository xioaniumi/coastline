"""Calibrates where in its travel the CR-1 assembly STEP is modelled, by moving it.

The STEP shows the machine at one arbitrary pose. To know which machine coordinates that pose
is, each motion group is slid along its axis until it first touches a part it wasn't already
touching (a bearing reaching a stepper mount, the spindle mount reaching the electronics
cover…). That gives the mechanical free range around the modelled pose. The firmware's travel
(soft-limit window X −86…−0.5, Y −241.5…−0.5, Z −78.5…−0.5; homed at X up, Y right, Z out) has to fit inside that range;
centring it there gives MODEL_POSE in machine_model.py.

Collision is tested on 0.5 mm voxels of every part's surface: fast (seconds per axis), and it
matches an exact B-rep distance sweep to ~0.5 mm. Parts touching at the modelled pose (rods
in their bearings, screws in their holes) are joined or sliding, so those pairs are ignored.

Run:  uv run python -m coastline_engine.machine_travel [path/to/cr1.step]
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import trimesh

PITCH = 0.5
# Groups that move with each axis (Z rides on the Y translator).
AXIS_GROUPS = {"x": ({"x"}, 0), "y": ({"y", "z"}, 1), "z": ({"z"}, 2)}
# A stationary reinforcement plate the CAD places 0.1 mm into the X switch tab's path; the real
# machine travels past it (the firmware's X travel would be impossible otherwise).
IGNORE = ("Outer Enclosure",)
IGNORE_FOR = {"x": ("X Linkage",)}


@dataclass
class Voxels:
    group: str
    name: str
    cells: np.ndarray  # (n, 3) int64


def voxelise(step_path: str | Path) -> list[Voxels]:
    from OCP.STEPCAFControl import STEPCAFControl_Reader
    from OCP.TCollection import TCollection_ExtendedString
    from OCP.TDF import TDF_Label
    from OCP.TDocStd import TDocStd_Document
    from OCP.TopLoc import TopLoc_Location
    from OCP.XCAFDoc import XCAFDoc_DocumentTool
    from OCP.collections import Sequence_TDF_Label

    from .cad_import import tessellate
    from .machine_model import GROUPS, _name

    doc = TDocStd_Document(TCollection_ExtendedString("cr1"))
    reader = STEPCAFControl_Reader()
    reader.SetNameMode(True)
    reader.ReadFile(str(step_path))
    reader.Transfer(doc)
    st = XCAFDoc_DocumentTool.ShapeTool_s(doc.Main())
    out: list[Voxels] = []
    rng = np.random.default_rng(0)

    def visit(label, loc, group):
        comps = Sequence_TDF_Label()
        st.GetComponents_s(label, comps)
        for c in comps:
            ref = TDF_Label()
            st.GetReferredShape_s(c, ref)
            name = _name(ref)
            l = loc.Multiplied(st.GetLocation_s(c))
            g = GROUPS.get(name, group)
            sub = Sequence_TDF_Label()
            st.GetComponents_s(ref, sub)
            if len(sub):
                visit(ref, l, g)
                continue
            if name in IGNORE:
                continue
            m, _ = tessellate(st.GetShape_s(ref).Moved(l), 0.1, 0.5)
            if len(m.indices) == 0:
                continue
            tm = trimesh.Trimesh(m.vertices, m.indices.reshape(-1, 3), process=False)
            n = max(200, int(tm.area / (PITCH * PITCH * 0.25)))
            pts, _ = trimesh.sample.sample_surface(tm, n, seed=rng)
            cells = np.unique(np.floor(np.vstack([pts, tm.vertices]) / PITCH).astype(np.int64), axis=0)
            out.append(Voxels(g, name, cells))

    roots = Sequence_TDF_Label()
    st.GetFreeShapes(roots)
    for root in roots:
        visit(root, TopLoc_Location(), "static")
    return out


def free_travel(parts: list[Voxels], axis: str, sign: int, offsets: dict[str, np.ndarray] | None = None,
                max_mm: float = 330) -> tuple[float, str, str]:
    """How far (mm) the groups moving with `axis` slide in direction `sign` before touching a
    new part. `offsets` shifts groups first (cells), e.g. the spindle retracted for X."""
    moving, k_axis = AXIS_GROUPS[axis]
    offsets = offsets or {}
    skip = IGNORE_FOR.get(axis, ())
    allc = np.vstack([p.cells for p in parts])
    base = allc.min(0) - 2000
    span = allc.max(0) - base + 4000

    def key(v):
        return ((v[:, 0] - base[0]) * span[1] + (v[:, 1] - base[1])) * span[2] + (v[:, 2] - base[2])

    def cells(p):
        return p.cells + offsets.get(p.group, 0)

    stat = [(i, p) for i, p in enumerate(parts) if p.group not in moving and not any(w in p.name for w in skip)]
    keys = np.concatenate([key(cells(p)) for _, p in stat])
    ids = np.concatenate([np.full(len(p.cells), i) for i, p in stat])
    order = np.argsort(keys)
    keys, ids = keys[order], ids[order]
    mv = [(i, p) for i, p in enumerate(parts) if p.group in moving]
    mvk = np.concatenate([key(cells(p)) for _, p in mv])
    mvid = np.concatenate([np.full(len(p.cells), i) for i, p in mv])
    stride = [span[1] * span[2], span[2], 1][k_axis]

    def hits(k):
        q = mvk + sign * k * stride
        j = np.searchsorted(keys, q)
        j[j >= len(keys)] = 0
        m = keys[j] == q
        return set(zip(mvid[m].tolist(), ids[j[m]].tolist()))

    touching = set()
    for k in range(-3, 4):
        touching |= hits(k)
    for k in range(1, int(max_mm / PITCH)):
        new = hits(k) - touching
        if new:
            a, b = min(new)
            return k * PITCH, parts[a].name, parts[b].name
    return max_mm, "", ""


def calibrate(step_path: str | Path, envelope_low=(-86.0, -241.5, -78.5)) -> dict:
    """Mechanical free range per axis around the modelled pose, and the machine position that
    centres the firmware travel inside it. Machine directions: X+ lowers the table (world −x),
    Y+ moves right (world +y), Z+ retracts (world +z). Envelope: envelope_low … −0.5
    (MachineProfile.cr1.machineEnvelope)."""
    parts = voxelise(step_path)
    retract = {"z": np.array([0, 0, int(80 / PITCH)])}  # spindle out of the table's way for X
    up, _, _ = free_travel(parts, "x", +1, retract)
    down, _, _ = free_travel(parts, "x", -1, retract)
    right, _, _ = free_travel(parts, "y", +1)
    left, _, _ = free_travel(parts, "y", -1)
    out_, _, _ = free_travel(parts, "z", +1)
    in_, _, _ = free_travel(parts, "z", -1)
    # Machine coordinate of each mechanical end, relative to the pose P: X: P−up … P+down;
    # Y: P−left … P+right; Z: P−in … P+out. Centre the envelope (−T … −0.5) in that range.
    def centre(lo_rel, hi_rel, low):
        env_mid = (low + -0.5) / 2
        return env_mid - (hi_rel + lo_rel) / 2
    pose = (centre(-up, down, envelope_low[0]), centre(-left, right, envelope_low[1]), centre(-in_, out_, envelope_low[2]))
    return {"x": (up, down), "y": (left, right), "z": (in_, out_), "pose": pose}


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "resources/machine/cr1_mechanicals_v1.3.step"
    r = calibrate(path)
    for a in "xyz":
        print(f"{a}: free {r[a][0]:.1f} / {r[a][1]:.1f} mm")
    print("pose", tuple(round(v, 2) for v in r["pose"]))
