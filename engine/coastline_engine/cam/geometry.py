"""Part geometry in the work frame: slices, the part's "shadow" seen from the tool, and
polygon booleans (pyclipper, integer units of 10 nm).

Work frame: the tool comes from +Z; Z = 0 is the stock face; the part is below it.
"""

from __future__ import annotations

import math

import numpy as np
import pyclipper
import trimesh

SCALE = 1e5  # pyclipper integer units per mm


def to_int(path) -> list[tuple[int, int]]:
    return [(int(round(x * SCALE)), int(round(y * SCALE))) for x, y in path]


def to_mm(path) -> np.ndarray:
    return np.asarray(path, dtype=float) / SCALE


class PartGeometry:
    def __init__(self, vertices: np.ndarray, triangles: np.ndarray, transform: np.ndarray):
        """vertices/triangles: the part mesh in part coordinates; transform: 4×4 part→work."""
        v = np.c_[vertices, np.ones(len(vertices))] @ transform.T
        self.mesh = trimesh.Trimesh(v[:, :3], triangles, process=False)
        self.zmin = float(self.mesh.vertices[:, 2].min())
        self.zmax = float(self.mesh.vertices[:, 2].max())
        self._slice_cache: dict[float, list] = {}
        # Holding tabs (cam/tabs.py): (paths, z_lo, z_hi), added to every region in that range.
        self.tabs: tuple[list, float, float] | None = None

    # ---------------------------------------------------------------- slices

    def slice_loops(self, z: float) -> list[np.ndarray]:
        """Closed loops where the plane Z = z cuts the part (n×2 arrays)."""
        segs = trimesh.intersections.mesh_plane(self.mesh, [0, 0, 1], [0, 0, z])
        if len(segs) == 0:
            return []
        return chain_segments(segs[:, :, :2])

    def region(self, z: float) -> list:
        """The part's cross-section at z as pyclipper paths (even-odd filled, simplified)."""
        key = round(z, 6)
        if key not in self._slice_cache:
            loops = [to_int(l) for l in self.slice_loops(z) if len(l) >= 3]
            if loops:
                pc = pyclipper.Pyclipper()
                pc.AddPaths(loops, pyclipper.PT_SUBJECT, True)
                self._slice_cache[key] = pc.Execute(pyclipper.CT_UNION, pyclipper.PFT_EVENODD, pyclipper.PFT_EVENODD)
            else:
                self._slice_cache[key] = []
        r = self._slice_cache[key]
        if self.tabs and self.tabs[1] - 1e-6 <= z <= self.tabs[2] + 1e-6:
            pc = pyclipper.Pyclipper()
            if r:
                pc.AddPaths(r, pyclipper.PT_SUBJECT, True)
            pc.AddPaths(self.tabs[0], pyclipper.PT_SUBJECT if not r else pyclipper.PT_CLIP, True)
            r = pc.Execute(pyclipper.CT_UNION, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)
        return r

    def shadow(self, z: float, step: float = 0.25) -> list:
        """Everything the tool must avoid at height z: the union of the part's cross-sections
        from z up to its top (a 3-axis tool can't reach under overhangs). Sampled every
        `step` mm plus just above z."""
        top = self.zmax
        if z >= top:
            return []
        levels = list(np.arange(top - 1e-3, z, -step)) + [z + 1e-3]
        if self.tabs and self.tabs[1] > z:
            levels.append(min(self.tabs[2], top - 1e-3))
        regions = [self.region(l) for l in levels if l < top]
        regions = [r for r in regions if r]
        if not regions:
            return []
        pc = pyclipper.Pyclipper()
        for r in regions:
            pc.AddPaths(r, pyclipper.PT_SUBJECT, True)
        return pc.Execute(pyclipper.CT_UNION, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)


def chain_segments(segs: np.ndarray, tol: float = 1e-5) -> list[np.ndarray]:
    """Joins line segments (n×2×2) into closed loops by matching endpoints."""
    key = lambda p: (round(p[0] / tol), round(p[1] / tol))
    ends: dict = {}
    for i, (a, b) in enumerate(segs):
        ends.setdefault(key(a), []).append((i, 0))
        ends.setdefault(key(b), []).append((i, 1))
    used = np.zeros(len(segs), bool)
    loops = []
    for start in range(len(segs)):
        if used[start]:
            continue
        used[start] = True
        loop = [segs[start][0], segs[start][1]]
        cur = segs[start][1]
        for _ in range(len(segs)):
            nxt = None
            for (j, end) in ends.get(key(cur), []):
                if not used[j]:
                    nxt = (j, end)
                    break
            if nxt is None:
                break
            j, end = nxt
            used[j] = True
            cur = segs[j][1 - end]
            loop.append(cur)
        if len(loop) >= 4 and np.linalg.norm(loop[0] - loop[-1]) < 1e-3:
            loops.append(np.array(loop[:-1]))
    return loops


def offset(paths: list, delta: float, arc_tol: float = 0.002) -> list:
    """Round-joined offset (mm, + = grow)."""
    if not paths:
        return []
    po = pyclipper.PyclipperOffset(2.0, arc_tol * SCALE)
    po.AddPaths(paths, pyclipper.JT_ROUND, pyclipper.ET_CLOSEDPOLYGON)
    return po.Execute(delta * SCALE)


def outer_and_holes(paths: list) -> tuple[list, list]:
    """Splits paths into outer boundaries (CCW, positive area) and holes (CW)."""
    outers, holes = [], []
    for p in paths:
        (outers if pyclipper.Orientation(p) else holes).append(p)
    return outers, holes


def rect(xmin, ymin, xmax, ymax) -> list:
    return [(xmin, ymin), (xmax, ymin), (xmax, ymax), (xmin, ymax)]
