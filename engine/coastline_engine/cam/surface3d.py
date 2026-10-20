"""3D finishing on freeform surfaces, tool from +Z, work frame.

Every strategy works the same way:
1. Make guide curves in XY: raster lines, spiral, radial spokes, or isolines of a 3D distance
   field (scallop).
2. Drop every guide point onto the part with OpenCAMLib's exact drop-cutter for the real cutter
   (ball, bull or flat). That gives cutter-location (CL) points: the tool tip never gouges.
3. Keep only the points that belong to the strategy (steep vs shallow areas, rest material,
   above the depth window), split the curves there, simplify within tolerance, and link them.

Waterline uses OpenCAMLib's adaptive waterline (true Z-level contours of the CL surface).

The CL grid (a drop-cutter height field) also drives slope (steep/shallow), the scallop
distance field and rest-material detection.
"""

from __future__ import annotations

import heapq
import math

import os

import numpy as np
import opencamlib as ocl
import pyclipper

from . import geometry as g
from .toolpath import CUT, LEAD, Toolpath


# --------------------------------------------------------------------------- cutter + surface

def cutter_for(kind: str, d: float, corner_r: float, length: float):
    """OpenCAMLib cutter. Length is the flute/stick-out length the cutter may use."""
    if kind == "ballEndMill":
        return ocl.BallCutter(d, length)
    if kind == "bullNoseEndMill" and corner_r > 1e-3:
        return ocl.BullCutter(d, min(corner_r, d / 2 - 1e-3), length)
    return ocl.CylCutter(d, length)


def stl_surface(geo: g.PartGeometry):
    s = ocl.STLSurf()
    v, t = geo.mesh.vertices, geo.mesh.faces
    for a, b, c in t:
        s.addTriangle(ocl.Triangle(ocl.Point(*v[a]), ocl.Point(*v[b]), ocl.Point(*v[c])))
    return s


def _inside(poly: np.ndarray, pts: np.ndarray) -> np.ndarray:
    """Points inside a polygon (even-odd ray casting, vectorised over the points)."""
    x, y = pts[:, 0], pts[:, 1]
    inside = np.zeros(len(pts), dtype=bool)
    lo, hi = poly.min(axis=0), poly.max(axis=0)
    near = (x >= lo[0]) & (x <= hi[0]) & (y >= lo[1]) & (y <= hi[1])
    if not near.any():
        return inside
    xs, ys = x[near], y[near]
    hit = np.zeros(len(xs), dtype=bool)
    a = poly
    b = np.roll(poly, -1, axis=0)
    for (x1, y1), (x2, y2) in zip(a, b):
        cross = ((y1 > ys) != (y2 > ys)) & (xs < (x2 - x1) * (ys - y1) / ((y2 - y1) if y2 != y1 else 1e-12) + x1)
        hit ^= cross
    inside[near] = hit
    return inside


class Surface:
    """The part (work frame) as an OpenCAMLib surface with a drop-cutter for one cutter."""

    def __init__(self, geo: g.PartGeometry, cutter, floor: float, cutter_args: tuple | None = None,
                 shank: tuple | None = None):
        self.geo = geo
        self.stl = stl_surface(geo)
        self.cutter = cutter
        self.floor = floor  # never below this (part bottom / depth window)
        # (kind, diameter, corner radius, length): to rebuild the cutter in a worker process.
        self.cutter_args = cutter_args
        # (diameter, flute length) when the shank is wider than the cutter: the shank, a
        # cylinder from the top of the flutes up, mustn't touch the part either. Counted where
        # it held the tool up (it leaves material there).
        self.shank = shank
        self.shank_cutter = ocl.CylCutter(shank[0], 60.0) if shank else None
        self.drops = 0
        self.shank_held = 0
        # Holding tabs (side B of a through-cut) aren't in the part's mesh: wherever the cutter
        # would touch one, it stays on the tab's top. Zones: the tabs grown by the cutter's
        # radius (mm polygons) and that top.
        self.tab_zones: list[np.ndarray] = []
        self.tab_top = None
        if getattr(geo, "tabs", None) and cutter_args is not None:
            polys, _, z_hi = geo.tabs
            r = float(cutter_args[1]) / 2
            self.tab_zones = [g.to_mm(p) for p in g.offset(polys, r + 0.05)]
            self.tab_top = float(z_hi)

    def _drop(self, cutter, xy: np.ndarray) -> np.ndarray:
        bdc = ocl.BatchDropCutter()
        bdc.setSTL(self.stl)
        bdc.setCutter(cutter)
        for x, y in xy:
            bdc.appendPoint(ocl.CLPoint(float(x), float(y), float(self.floor)))
        bdc.run()
        return np.array([p.z for p in bdc.getCLPoints()])

    def drop(self, xy: np.ndarray) -> np.ndarray:
        """Exact CL z for each XY point: the tip height where the cutter touches the part, or
        higher where the shank above the flutes would touch it first."""
        if len(xy) == 0:
            return np.zeros(0)
        z = self._drop(self.cutter, xy)
        if self.shank_cutter is not None:
            zs = self._drop(self.shank_cutter, xy) - self.shank[1]
            self.shank_held += int(np.count_nonzero(zs > z + 0.01))
            z = np.maximum(z, zs)
        for zone in self.tab_zones:
            inside = _inside(zone, np.asarray(xy, dtype=float))
            if inside.any():
                z = np.where(inside, np.maximum(z, self.tab_top), z)
        self.drops += len(xy)
        return np.maximum(z, self.floor)

    def drop_many(self, curves: list[np.ndarray]) -> list[np.ndarray]:
        """One batched drop for many curves (building the search tree once is most of the cost)."""
        if not curves:
            return []
        z = self.drop(np.vstack(curves))
        out, k = [], 0
        for c in curves:
            out.append(z[k:k + len(c)])
            k += len(c)
        return out


class CLGrid:
    """Drop-cutter height field over a rectangle: slope, masks, distance fields."""

    def __init__(self, surf: Surface, lo, hi, step: float):
        self.step = step
        self.xs = np.arange(lo[0], hi[0] + step * 0.5, step)
        self.ys = np.arange(lo[1], hi[1] + step * 0.5, step)
        X, Y = np.meshgrid(self.xs, self.ys, indexing="ij")
        self.z = surf.drop(np.c_[X.ravel(), Y.ravel()]).reshape(X.shape)
        gx, gy = np.gradient(self.z, step)
        self.slope = np.degrees(np.arctan(np.hypot(gx, gy)))

    def index(self, x, y):
        i = np.clip(np.rint((np.asarray(x) - self.xs[0]) / self.step).astype(int), 0, len(self.xs) - 1)
        j = np.clip(np.rint((np.asarray(y) - self.ys[0]) / self.step).astype(int), 0, len(self.ys) - 1)
        return i, j

    def sample(self, field: np.ndarray, xy: np.ndarray) -> np.ndarray:
        i, j = self.index(xy[:, 0], xy[:, 1])
        return field[i, j]


# --------------------------------------------------------------------------- regions + curves

def finish_region(geo: g.PartGeometry, r: float, stock_min, stock_max, margin: float = 0.3) -> list:
    """Where the tool centre may go: the part's silhouette grown by the tool radius, inside the
    stock (integer pyclipper paths)."""
    sil = geo.shadow(geo.zmin)
    grown = g.offset(sil, r + margin)
    pc = pyclipper.Pyclipper()
    pc.AddPaths(grown, pyclipper.PT_SUBJECT, True)
    pc.AddPath(g.to_int(g.rect(stock_min[0] - r, stock_min[1] - r, stock_max[0] + r, stock_max[1] + r)), pyclipper.PT_CLIP, True)
    return pc.Execute(pyclipper.CT_INTERSECTION, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)


def clip_lines(lines: list[np.ndarray], region: list) -> list[np.ndarray]:
    """Clips open polylines to the region."""
    if not region:
        return []
    pc = pyclipper.Pyclipper()
    pc.AddPaths(region, pyclipper.PT_CLIP, True)
    for ln in lines:
        if len(ln) >= 2:
            pc.AddPath(g.to_int(ln), pyclipper.PT_SUBJECT, False)
    tree = pc.Execute2(pyclipper.CT_INTERSECTION, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)
    return [g.to_mm(p) for p in pyclipper.OpenPathsFromPolyTree(tree) if len(p) >= 2]


def resample(pts: np.ndarray, spacing: float) -> np.ndarray:
    """The polyline with points evenly `spacing` mm apart along it (ends kept)."""
    if len(pts) < 2:
        return pts
    d = np.r_[0.0, np.cumsum(np.linalg.norm(np.diff(pts, axis=0), axis=1))]
    if d[-1] <= 0:
        return pts[:1]
    t = np.linspace(0.0, d[-1], max(int(math.ceil(d[-1] / spacing)), 1) + 1)
    return np.c_[np.interp(t, d, pts[:, 0]), np.interp(t, d, pts[:, 1])]


def densify(pts: np.ndarray, spacing: float, closed: bool = False) -> np.ndarray:
    if closed:
        pts = np.vstack([pts, pts[:1]])
    out = [pts[0]]
    for a, b in zip(pts[:-1], pts[1:]):
        n = max(int(math.ceil(np.linalg.norm(b - a) / spacing)), 1)
        for k in range(1, n + 1):
            out.append(a + (b - a) * k / n)
    return np.array(out)


def region_bounds(region: list):
    pts = np.vstack([g.to_mm(p) for p in region])
    return pts.min(0), pts.max(0)


def raster(region: list, stepover: float, angle_deg: float) -> list[np.ndarray]:
    """Parallel lines across the region at `angle_deg`, zig-zag ordered."""
    lo, hi = region_bounds(region)
    c = (lo + hi) / 2
    R = np.linalg.norm(hi - lo) / 2 + stepover
    a = math.radians(angle_deg)
    d, n = np.array([math.cos(a), math.sin(a)]), np.array([-math.sin(a), math.cos(a)])
    lines = []
    k = 0
    for off in np.arange(-R, R + 1e-9, stepover):
        p0, p1 = c + n * off - d * R, c + n * off + d * R
        lines.append(np.array([p0, p1]) if k % 2 == 0 else np.array([p1, p0]))
        k += 1
    clipped = clip_lines(lines, region)
    # Clipping loses the zig-zag order: put each piece back in its line's direction and sort by
    # offset then along the line, alternating.
    def key(p):
        off = float(np.dot(p.mean(0) - c, n))
        return off
    out = []
    for pts in sorted(clipped, key=key):
        k = int(round((np.dot(pts[0] - c, n) + R) / stepover))
        if np.dot(pts[-1] - pts[0], d) * (1 if k % 2 == 0 else -1) < 0:
            pts = pts[::-1]
        out.append(pts)
    return out


def spiral(region: list, stepover: float, centre=None) -> list[np.ndarray]:
    """Archimedean spiral outward from the centre (domes, cabochons), clipped to the region."""
    lo, hi = region_bounds(region)
    c = np.array(centre) if centre is not None else (lo + hi) / 2
    rmax = max(np.linalg.norm(hi - c), np.linalg.norm(lo - c), np.linalg.norm([hi[0] - c[0], lo[1] - c[1]]),
               np.linalg.norm([lo[0] - c[0], hi[1] - c[1]]))
    turns = rmax / stepover
    th = np.linspace(0, 2 * math.pi * turns, max(int(turns * 90), 10))
    r = stepover * th / (2 * math.pi)
    pts = c + np.c_[r * np.cos(th), r * np.sin(th)]
    return clip_lines([pts], region)


def radial(region: list, stepover: float, centre=None) -> list[np.ndarray]:
    """Spokes from the centre, spaced so the outer ends are `stepover` apart."""
    lo, hi = region_bounds(region)
    c = np.array(centre) if centre is not None else (lo + hi) / 2
    rmax = float(np.max(np.linalg.norm(np.array([lo, hi, [lo[0], hi[1]], [hi[0], lo[1]]]) - c, axis=1)))
    n = max(int(math.ceil(2 * math.pi * rmax / stepover)), 8)
    lines = []
    for k in range(n):
        a = 2 * math.pi * k / n
        p = c + rmax * np.array([math.cos(a), math.sin(a)])
        lines.append(np.array([c, p]) if k % 2 == 0 else np.array([p, c]))
    return clip_lines(lines, region)


# --------------------------------------------------------------------------- scallop (3D offsets)

def geodesic_distance(grid: CLGrid, inside: np.ndarray) -> np.ndarray:
    """Distance along the CL surface from the region's edge (Dijkstra on the grid, 8-connected,
    3D edge lengths). Isolines of it are constant-3D-stepover passes."""
    nx, ny = inside.shape
    dist = np.full(inside.shape, np.inf)
    heap = []
    edge = inside & ~(np.roll(inside, 1, 0) & np.roll(inside, -1, 0) & np.roll(inside, 1, 1) & np.roll(inside, -1, 1))
    edge[0, :] |= inside[0, :]
    edge[-1, :] |= inside[-1, :]
    edge[:, 0] |= inside[:, 0]
    edge[:, -1] |= inside[:, -1]
    for i, j in zip(*np.nonzero(edge)):
        dist[i, j] = 0.0
        heap.append((0.0, int(i), int(j)))
    heapq.heapify(heap)
    s = grid.step
    nbrs = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]
    z = grid.z
    while heap:
        d0, i, j = heapq.heappop(heap)
        if d0 > dist[i, j]:
            continue
        for di, dj in nbrs:
            a, b = i + di, j + dj
            if 0 <= a < nx and 0 <= b < ny and inside[a, b]:
                step = math.sqrt((di * s) ** 2 + (dj * s) ** 2 + (z[a, b] - z[i, j]) ** 2)
                nd = d0 + step
                if nd < dist[a, b]:
                    dist[a, b] = nd
                    heapq.heappush(heap, (nd, a, b))
    return dist


def isolines(grid: CLGrid, field: np.ndarray, level: float) -> list[np.ndarray]:
    """Marching squares: the curves where `field` = level (XY polylines)."""
    f = np.where(np.isfinite(field), field, -1e9)
    xs, ys = grid.xs, grid.ys
    segs = []
    a, b, c, d = f[:-1, :-1], f[1:, :-1], f[1:, 1:], f[:-1, 1:]  # corners: (i,j),(i+1,j),(i+1,j+1),(i,j+1)
    code = (a > level).astype(int) | ((b > level) << 1) | ((c > level) << 2) | ((d > level) << 3)
    ii, jj = np.nonzero((code != 0) & (code != 15))

    def interp(p0, p1, v0, v1):
        t = (level - v0) / (v1 - v0) if v1 != v0 else 0.5
        return p0 + (p1 - p0) * t

    for i, j in zip(ii, jj):
        P = [np.array([xs[i], ys[j]]), np.array([xs[i + 1], ys[j]]), np.array([xs[i + 1], ys[j + 1]]), np.array([xs[i], ys[j + 1]])]
        V = [f[i, j], f[i + 1, j], f[i + 1, j + 1], f[i, j + 1]]
        cuts = []
        for k in range(4):
            v0, v1 = V[k], V[(k + 1) % 4]
            if (v0 > level) != (v1 > level):
                cuts.append(interp(P[k], P[(k + 1) % 4], v0, v1))
        for k in range(0, len(cuts) - 1, 2):
            segs.append([cuts[k], cuts[k + 1]])
    if not segs:
        return []
    chains = g.chain_segments(np.array(segs), tol=grid.step * 1e-3)
    return [ch for ch in chains if len(ch) >= 3]


# --------------------------------------------------------------------------- path assembly

def simplify(pts3: np.ndarray, tol: float) -> np.ndarray:
    """Removes points that lie within `tol` of the line through their neighbours (3D)."""
    if len(pts3) <= 2:
        return pts3
    keep = [0]
    anchor = 0
    for k in range(2, len(pts3)):
        a, b = pts3[anchor], pts3[k]
        seg = b - a
        L = np.linalg.norm(seg)
        if L < 1e-9:
            continue
        mid = pts3[anchor + 1:k]
        dev = np.linalg.norm(np.cross(mid - a, seg), axis=1) / L if len(mid) else np.zeros(0)
        if len(dev) and dev.max() > tol:
            keep.append(k - 1)
            anchor = k - 1
    keep.append(len(pts3) - 1)
    return pts3[keep]


def split_by_mask(xy: np.ndarray, z: np.ndarray, keep: np.ndarray, min_len: int = 3) -> list[np.ndarray]:
    out, cur = [], []
    for p, zz, k in zip(xy, z, keep):
        if k:
            cur.append((p[0], p[1], zz))
        elif cur:
            if len(cur) >= min_len:
                out.append(np.array(cur))
            cur = []
    if len(cur) >= min_len:
        out.append(np.array(cur))
    return out


def emit(tp: Toolpath, passes: list[np.ndarray], feed: float, plunge: float, link_feed: float, tol: float = 0.004,
         stay_down: float = 0.0, surf: "Surface | None" = None, entry_margin: float = 1.2):
    """Cuts each 3D pass. Between nearby passes it stays down: the hop runs at the highest
    drop-cutter height along it (plus 0.02 mm), so it can't gouge; otherwise it retracts, rapids
    over, and feeds the last `entry_margin` mm down at the plunge feed (roughing leaves terraces)."""
    passes = [q for q in (simplify(p, tol) for p in passes) if len(q) >= 2]
    # All the stay-down hops checked in one batched drop.
    hops: dict[int, float] = {}
    if stay_down > 0 and surf is not None:
        samples, owners = [], []
        for k in range(1, len(passes)):
            a, b = passes[k - 1][-1], passes[k][0]
            if np.linalg.norm(b[:2] - a[:2]) <= stay_down:
                n = max(int(np.linalg.norm(b[:2] - a[:2]) / 0.05), 2)
                samples.append(a[:2] + (b[:2] - a[:2]) * np.linspace(0, 1, n)[:, None])
                owners.append(k)
        for k, z in zip(owners, surf.drop_many(samples)):
            hops[k] = max(float(z.max()), passes[k - 1][-1][2], passes[k][0][2]) + 0.02
    for k, p in enumerate(passes):
        s = p[0]
        if k in hops:
            last = passes[k - 1][-1]
            tp.line(last[0], last[1], hops[k], plunge, CUT)
            tp.line(s[0], s[1], hops[k], feed, CUT)
            tp.line(s[0], s[1], s[2], plunge, CUT)
        else:
            tp.go_to(s[0], s[1], s[2], plunge, link_feed, cleared_down_to=s[2] + entry_margin)
        for q in p[1:]:
            tp.line(q[0], q[1], q[2], feed, CUT)
    tp.retract()


def order_passes(passes: list[np.ndarray]) -> list[np.ndarray]:
    """Greedy nearest-neighbour ordering, reversing open passes when that's shorter."""
    left = list(passes)
    out = []
    pos = np.array([0.0, 0.0])
    while left:
        best, bi, rev = None, 0, False
        for i, p in enumerate(left):
            d0 = np.linalg.norm(p[0, :2] - pos)
            d1 = np.linalg.norm(p[-1, :2] - pos)
            if best is None or d0 < best:
                best, bi, rev = d0, i, False
            if d1 < best:
                best, bi, rev = d1, i, True
        p = left.pop(bi)
        p = p[::-1] if rev else p
        out.append(p)
        pos = p[-1, :2]
    return out


# --------------------------------------------------------------------------- strategies

def scallop_stepover(tool_kind: str, d: float, h: float) -> float:
    """Stepover that leaves cusps `h` high (flat areas) with a ball of diameter d."""
    R = d / 2
    if tool_kind == "ballEndMill":
        return 2 * math.sqrt(max(2 * R * h - h * h, 1e-9))
    return 0.3 * d


def finish(op, geo: g.PartGeometry, stock_min, stock_max, tp: Toolpath, strategy: str, params: dict) -> Toolpath:
    """Generates one 3D finishing operation. `params`: scallop (mm), angle (deg), steep_angle
    (deg), ref_tool {kind, diameter, corner_radius} for rest finishing."""
    r = op.tool_d / 2
    op.warnings = tp.warnings  # waterline levels that had to be skipped are reported here
    cutter_args = (op.tool_kind, op.tool_d, op.corner_r, op.flute)
    cutter = cutter_for(*cutter_args)
    floor = max(geo.zmin - 0.0, op.z_min)
    shank = (op.shank_d, op.flute) if op.shank_d > op.tool_d + 0.02 else None
    surf = Surface(geo, cutter, floor, cutter_args, shank=shank)
    region = finish_region(geo, r, stock_min, stock_max)
    tile = getattr(op, "tile", None)
    if tile and region:
        # One strip of the job (the engines share a long finish): the region within it.
        pc = pyclipper.Pyclipper()
        pc.AddPaths(region, pyclipper.PT_SUBJECT, True)
        pc.AddPath(g.to_int(g.rect(-1e4, tile[0], 1e4, tile[1])), pyclipper.PT_CLIP, True)
        region = pc.Execute(pyclipper.CT_INTERSECTION, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)
        if not region:
            return tp  # nothing of the part in this strip
    # Only over the curved faces (and a tool radius around them): flat floors and vertical walls
    # are the floor and contour passes' (rest finishing keeps its own rest-material mask).
    mask = params.get("freeform_mask")
    if mask is not None and strategy != "rest" and region:
        pc = pyclipper.Pyclipper()
        pc.AddPaths(region, pyclipper.PT_SUBJECT, True)
        grown = g.offset(mask, r + 0.5) if mask else []
        if grown:
            pc.AddPaths(grown, pyclipper.PT_CLIP, True)
            region = pc.Execute(pyclipper.CT_INTERSECTION, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)
        else:
            region = []
        if not region:
            return tp  # no curved surfaces here: the floor and contour passes finish it
    if not region:
        tp.warnings.append("Nothing to finish here.")
        return tp
    h = float(params.get("scallop", 0.008))
    # The stepover from the app (FeedsEngine, set from the scallop height) unless it's missing or
    # nonsensical; then from the scallop height directly.
    s = op.stepover if op.stepover >= 0.02 else scallop_stepover(op.tool_kind, op.tool_d, h)
    sampling = min(max(s / 2, 0.05), 0.25)
    steep = float(params.get("steep_angle", 45.0))
    lo, hi = region_bounds(region)
    grid = CLGrid(surf, lo, hi, step=max(min(s / 2, 0.25), 0.08)) if strategy in ("steep_shallow", "scallop", "rest") else None

    def dropped(curves, closed=False):
        pts = [densify(c, sampling, closed) for c in curves]
        return list(zip(pts, surf.drop_many(pts)))

    passes: list[np.ndarray] = []
    if strategy == "parallel":
        for xy, z in dropped(raster(region, s, float(params.get("angle", 0)))):
            passes += split_by_mask(xy, z, z >= op.z_min - 1e-6)
    elif strategy in ("spiral", "radial"):
        curves = spiral(region, s) if strategy == "spiral" else radial(region, s)
        for xy, z in dropped(curves):
            passes += split_by_mask(xy, z, z >= op.z_min - 1e-6)
    elif strategy == "waterline":
        if surf.shank or surf.tab_zones:
            # OpenCAMLib's weave knows only the cutter: with a wider shank, levels come from the
            # height field, which includes it.
            grid = CLGrid(surf, lo, hi, step=max(min(s / 2, 0.25), 0.08))
            zs = waterline_levels(geo.zmax - 0.02, max(geo.zmin, op.z_min) + 0.01, s)
            passes = climb_loops([item for lv in field_waterlines(surf, grid, zs) for item in lv])
        else:
            passes = waterline(surf, geo, op, s, sampling)
    elif strategy == "steep_shallow":
        # Shallow areas: raster; steep: waterline. A few degrees of overlap avoids witness lines.
        for xy, z in dropped(raster(region, s, float(params.get("angle", 0)))):
            slope = grid.sample(grid.slope, xy)
            passes += split_by_mask(xy, z, (slope <= steep + 3) & (z >= op.z_min - 1e-6))
        # Waterline from the height field already computed for the slopes: no OpenCAMLib weave
        # per level (on a lattice that was 20+ min for one side).
        zs = waterline_levels(geo.zmax - 0.02, max(geo.zmin, op.z_min) + 0.01, s)
        for loop in climb_loops([item for lv in field_waterlines(surf, grid, zs) for item in lv]):
            slope = grid.sample(grid.slope, loop[:, :2])
            passes += split_by_mask(loop[:, :2], loop[:, 2], slope >= steep - 3)
    elif strategy == "scallop":
        X, Y = np.meshgrid(grid.xs, grid.ys, indexing="ij")
        pts = np.c_[X.ravel(), Y.ravel()]
        inside = np.array([any(pyclipper.PointInPolygon(q, p) != 0 for p in region) for q in g.to_int(pts)]).reshape(X.shape)
        dist = geodesic_distance(grid, inside)
        dmax = float(np.nanmax(np.where(np.isfinite(dist), dist, np.nan)))
        level = s / 2
        curves = []
        while level < dmax:
            curves += isolines(grid, np.where(inside, dist, -1.0), level)
            level += s
        for xy, z in dropped(curves):
            passes += split_by_mask(xy, z, z >= op.z_min - 1e-6)
    elif strategy == "rest":
        passes = rest(surf, grid, geo, op, params, region, s, sampling)
    else:
        tp.warnings.append(f"Unknown 3D strategy {strategy}.")
        return tp
    # Nothing on the floor around the part (the part's bottom or the depth window): the flat
    # end mills already finished it, and a ball there would only trace the outline.
    trimmed = []
    for p in passes:
        trimmed += split_by_mask(p[:, :2], p[:, 2], p[:, 2] > surf.floor + 0.02, min_len=2)
    passes = trimmed
    if not passes:
        if not tile:
            tp.warnings.append("This strategy found nothing to cut on this part.")
        return tp
    if surf.shank and surf.shank_held > 0.002 * max(surf.drops, 1):
        tp.warnings.append(f"In narrow places the ⌀{surf.shank[0]:g} mm shank doesn't fit below the {surf.shank[1]:g} mm flutes: "
                           "the tool stays higher there and leaves material. A long-reach tool goes deeper.")
    ordered = order_passes(passes)
    emit(tp, ordered, op.feed, op.plunge, op.link_feed, stay_down=s * 1.6, surf=surf)
    return tp


def waterline(surf: Surface, geo: g.PartGeometry, op, s: float, sampling: float) -> list[np.ndarray]:
    """Z-level contours of the CL surface, spaced so steep walls get the same cusp as `s` gives
    on flat ground (stepdown = s for walls near vertical). Runs in a worker process (wl_worker):
    a level that crashes OpenCAMLib is retried a hair higher, then skipped with a warning."""
    top = geo.zmax - 0.02
    bottom = max(geo.zmin, op.z_min) + 0.01
    zs = []
    z = top
    while z >= bottom:
        zs.append(float(z))
        z -= s
    loops = []
    for _, raw in _waterline_levels(surf, geo, zs, sampling, op):
        loops += climb_loops(raw)
    return loops


def field_waterline(surf: Surface, grid: "CLGrid", z: float) -> list:
    """One level of field_waterlines."""
    return field_waterlines(surf, grid, [z])[0]


def field_waterlines(surf: Surface, grid: "CLGrid", zs: list[float], iterations: int = 8,
                     spacing: float = 0.25) -> list[list]:
    """Waterline levels from the drop-cutter height field instead of OpenCAMLib's weave: the
    contours where the CL surface crosses each z (marching squares), each point then moved
    along the field's gradient by bisection to the crossing, on its safe side (within 2 µm).
    It can't crash, and all points of all levels are refined together: each drop call builds
    OpenCAMLib's search tree, so one batch per bisection step instead of one per loop (a
    lattice side: 20 min → about a minute). Points every `spacing` mm (0.25: under 3 µm of
    chord error round a 1/4" tool's corners).

    Returns per level a list of (points n×3, closed). A point that can't be bracketed (a
    corner where the gradient means little) moves to the nearest safe spot; if there's none
    within 1.6 mm the loop is split there instead of cutting across."""
    gx, gy = np.gradient(grid.z, grid.step)
    curves, owner = [], []
    for li, z in enumerate(zs):
        for c in isolines(grid, grid.z, z):
            curves.append(resample(c, spacing))
            owner.append(li)
    out: list[list] = [[] for _ in zs]
    if not curves:
        return out
    c = np.vstack(curves)
    m = len(c)
    zt = np.concatenate([np.full(len(cv), zs[li]) for cv, li in zip(curves, owner)])
    n = np.c_[grid.sample(gx, c), grid.sample(gy, c)]
    ln = np.linalg.norm(n, axis=1)
    n = np.where(ln[:, None] > 1e-9, n / np.maximum(ln, 1e-9)[:, None], 0.0)
    # Bracket: one and a half cells either side, along the gradient (uphill is +): f ≤ 0 is
    # where the tool may be at z, f ≥ 0 is inside the part.
    b = 1.5 * grid.step
    lo_t, hi_t = np.full(m, -b), np.full(m, b)
    ends = surf.drop(np.vstack([c - n * b, c + n * b])) - np.r_[zt, zt]
    ok = (ends[:m] <= 0) & (ends[m:] >= 0) & (ln > 1e-9)
    bad = np.flatnonzero(~ok)
    if len(bad):
        # Try the axis and diagonal directions for those.
        dirs = np.array([[1, 0], [0, 1], [1, 1], [1, -1]], float)
        dirs /= np.linalg.norm(dirs, axis=1)[:, None]
        q = np.vstack([c[bad] + sg * d * b for d in dirs for sg in (-1, 1)])
        f = (surf.drop(q) - np.tile(zt[bad], 8)).reshape(4, 2, len(bad))
        for k, d in enumerate(dirs):
            fwd = (f[k, 0] <= 0) & (f[k, 1] >= 0)
            rev = (f[k, 0] >= 0) & (f[k, 1] <= 0)
            take = (fwd | rev) & ~ok[bad]
            n[bad[take]] = np.where(fwd[take, None], d, -d)
            ok[bad[take]] = True
    if os.environ.get("COASTLINE_WL_DEBUG"):
        print(f"field waterline: {m} points, {np.mean(~ok) * 100:.2f}% not bracketed", flush=True)
    for _ in range(iterations):
        mid = (lo_t + hi_t) / 2
        up = surf.drop(c + n * mid[:, None]) - zt >= 0
        hi_t = np.where(ok & up, mid, hi_t)
        lo_t = np.where(ok & ~up, mid, lo_t)
    xy = c + n * np.where(ok, lo_t, 0.0)[:, None]
    safe = ok.copy()
    rest = np.flatnonzero(~ok)
    if len(rest):
        # The rest: is the point itself safe? Otherwise the nearest safe spot around it.
        f0 = surf.drop(c[rest]) - zt[rest]
        safe[rest[f0 <= 1e-4]] = True
        rest = rest[f0 > 1e-4]
    if len(rest):
        ang = np.linspace(0, 2 * np.pi, 16, endpoint=False)
        ring = np.c_[np.cos(ang), np.sin(ang)]
        for dist in (0.1, 0.2, 0.4, 0.8, 1.6):
            if not len(rest):
                break
            q = (c[rest][:, None, :] + ring[None] * dist).reshape(-1, 2)
            f = (surf.drop(q) - np.repeat(zt[rest], 16)).reshape(len(rest), 16)
            hit = (f <= 1e-4).any(axis=1)
            first = np.argmax(f <= 1e-4, axis=1)
            xy[rest[hit]] = c[rest[hit]] + ring[first[hit]] * dist
            safe[rest[hit]] = True
            rest = rest[~hit]
    k = 0
    for cv, li in zip(curves, owner):
        pts = np.c_[xy[k:k + len(cv)], np.full(len(cv), zs[li])]
        good = safe[k:k + len(cv)]
        k += len(cv)
        if good.all():
            out[li].append((pts, True))
            continue
        # Split at unsafe points; the pieces are open (a closed contour starting anywhere).
        start = int(np.argmin(good))
        pts, good = np.roll(pts, -start, axis=0), np.roll(good, -start)
        idx = np.flatnonzero(good)
        for run in np.split(idx, np.flatnonzero(np.diff(idx) > 1) + 1):
            if len(run) >= 2:
                out[li].append((pts[run], False))
    return out


def waterline_levels(top: float, bottom: float, s: float) -> list[float]:
    zs = []
    z = top
    while z >= bottom:
        zs.append(float(z))
        z -= s
    return zs


def climb_loops(raw: list) -> list[np.ndarray]:
    """Closed loops, clockwise seen from the tool (climb on outside walls with an M3 spindle),
    explicitly closed. Items: point arrays (closed loops, as OpenCAMLib gives them) or
    (points, closed) pairs; open pieces are kept as they are."""
    loops = []
    for item in raw:
        pts, closed = item if isinstance(item, tuple) else (item, True)
        if len(pts) < 2 or (closed and len(pts) < 3):
            continue
        if not closed:
            loops.append(pts)
            continue
        area = 0.5 * np.sum(pts[:-1, 0] * pts[1:, 1] - pts[1:, 0] * pts[:-1, 1])
        if area > 0:
            pts = pts[::-1]
        loops.append(np.vstack([pts, pts[:1]]))
    return loops


def _waterline_levels(surf: Surface, geo: g.PartGeometry, zs: list[float], sampling: float, op):
    """(z, loops) per level. OpenCAMLib's weave runs in a worker process, one level after the
    other, each with a time limit: a level that crashes the worker or hangs is done from the
    drop-cutter field instead (field_waterline), so no height is left unfinished."""
    import pickle
    import queue
    import subprocess
    import sys
    import tempfile
    import threading
    import time

    if surf.cutter_args is None:  # no way to rebuild the cutter: run here
        for z in zs:
            wl = ocl.AdaptiveWaterline()
            wl.setSTL(surf.stl)
            wl.setCutter(surf.cutter)
            wl.setZ(z)
            wl.setSampling(float(sampling))
            wl.setMinSampling(float(sampling / 8))
            wl.run2()
            yield z, [np.array([[p.x, p.y, p.z] for p in lp]) for lp in wl.getLoops()]
        return
    base = {"vertices": np.asarray(geo.mesh.vertices, float), "faces": np.asarray(geo.mesh.faces),
            "cutter": surf.cutter_args, "sampling": float(sampling)}
    pending = list(zs)
    if os.environ.get("COASTLINE_WL_DUMP"):  # debugging: keep the job to replay it
        with open(os.environ["COASTLINE_WL_DUMP"], "wb") as fh:
            pickle.dump({**base, "zs": pending}, fh)
    grid = None
    slowest = 0.0

    def fallback(z):
        nonlocal grid
        if grid is None:
            v = base["vertices"]
            pad = surf.cutter_args[1] / 2 + 1.0
            step = min(max(sampling, 0.05), 0.2)
            grid = CLGrid(surf, v[:, :2].min(0) - pad, v[:, :2].max(0) + pad, step)
        return field_waterline(surf, grid, z)

    while pending:
        err = tempfile.TemporaryFile()  # OpenCAMLib prints a lot on stderr: never into a pipe
        proc = subprocess.Popen([sys.executable, "-m", "coastline_engine.cam.wl_worker"],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err)
        results: queue.Queue = queue.Queue()

        def read(stream=proc.stdout, q=results):
            while True:
                try:
                    q.put(pickle.load(stream))
                except Exception:
                    q.put(None)
                    return

        threading.Thread(target=read, daemon=True).start()
        proc.stdin.write(pickle.dumps({**base, "zs": pending}))
        proc.stdin.close()
        failed = False
        while pending:
            t0 = time.time()
            # A level normally takes a second or two; give it plenty, scaled to the slowest so far.
            limit = max(30.0, slowest * 8)
            try:
                item = results.get(timeout=limit)
            except queue.Empty:
                item = "timeout"
            if item is None or item == "timeout":
                failed = True
                break
            z, raw = item
            slowest = max(slowest, time.time() - t0)
            pending.pop(0)
            yield z, raw
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        if not failed:
            break
        if proc.returncode and proc.returncode > 0 and item is None:  # a Python error, not a crash
            err.seek(0)
            raise RuntimeError("Waterline worker failed: " + err.read().decode(errors="replace")[-600:])
        bad = pending.pop(0)
        loops = fallback(bad)
        if hasattr(op, "warnings") and not loops:
            op.warnings.append(f"Waterline at Z{bad:.3f} found nothing (OpenCAMLib failed there; the height field had no wall either).")
        yield bad, loops


def envelope(grid: CLGrid, d: float, kind: str) -> np.ndarray:
    """Lowest height a cutter reaches at each grid point (the surface it leaves): the CL tip
    height field 'eroded' by the cutter's profile (ball: R − √(R² − r²))."""
    R = d / 2
    k = int(math.ceil(R / grid.step))
    out = np.full(grid.z.shape, np.inf)
    zc = np.pad(grid.z, k, mode="edge")
    nx, ny = grid.z.shape
    for di in range(-k, k + 1):
        for dj in range(-k, k + 1):
            rr = math.hypot(di, dj) * grid.step
            if rr > R:
                continue
            prof = R - math.sqrt(R * R - rr * rr) if kind == "ballEndMill" else 0.0
            shifted = zc[k + di:k + di + nx, k + dj:k + dj + ny] + prof
            np.minimum(out, shifted, out=out)
    return out


def rest(surf: Surface, grid: CLGrid, geo: g.PartGeometry, op, params: dict, region, s: float, sampling: float) -> list[np.ndarray]:
    """Rest / pencil finishing: only where a larger reference tool left material (inside
    corners, creases, under-radius fillets). Raster in two directions over those areas."""
    ref = params.get("ref_tool") or {"kind": "ballEndMill", "diameter": op.tool_d * 2, "corner_radius": 0}
    ref_cutter = cutter_for(ref["kind"], float(ref["diameter"]), float(ref.get("corner_radius", 0)), op.flute)
    ref_surf = Surface(geo, ref_cutter, surf.floor)
    ref_grid = CLGrid.__new__(CLGrid)
    ref_grid.step, ref_grid.xs, ref_grid.ys = grid.step, grid.xs, grid.ys
    X, Y = np.meshgrid(grid.xs, grid.ys, indexing="ij")
    ref_grid.z = ref_surf.drop(np.c_[X.ravel(), Y.ravel()]).reshape(X.shape)
    left = envelope(ref_grid, float(ref["diameter"]), ref["kind"]) - envelope(grid, op.tool_d, op.tool_kind)
    mask = left > float(params.get("rest_threshold", 0.01))
    # Grow the mask a little so passes run out of the corner onto finished surface.
    grow = max(int(math.ceil(op.tool_d / 2 / grid.step)), 1)
    m = mask.copy()
    for _ in range(grow):
        m = m | np.roll(m, 1, 0) | np.roll(m, -1, 0) | np.roll(m, 1, 1) | np.roll(m, -1, 1)
    passes = []
    curves = []
    for ang in (float(params.get("angle", 0)), float(params.get("angle", 0)) + 90):
        for c in raster(region, s, ang):
            xy = densify(c, sampling)
            if grid.sample(m, xy).any():
                curves.append(xy)
    for xy, z in zip(curves, surf.drop_many(curves)):
        passes += split_by_mask(xy, z, grid.sample(m, xy) & (z >= op.z_min - 1e-6))
    return passes


# --------------------------------------------------------------------------- holder clearance

NUT_RADIUS = 8.0  # ER-11 "A" nut, Ø16


def min_stickout(geo: g.PartGeometry, moves: np.ndarray, material_top: float, band: list, step: float = 0.5) -> float:
    """The shortest stick-out (tip to collet-nut face) that keeps the nut 1 mm above everything
    within its radius at every cutting move. Material outside the cleared band is still at the
    material top; inside it, the part's own height."""
    cut = moves[(moves[:, 0] != 0)] if len(moves) else moves
    if len(cut) == 0:
        return 0.0
    lo = cut[:, 2:4].min(0) - NUT_RADIUS - 1
    hi = cut[:, 2:4].max(0) + NUT_RADIUS + 1
    xs = np.arange(lo[0], hi[0] + step, step)
    ys = np.arange(lo[1], hi[1] + step, step)
    X, Y = np.meshgrid(xs, ys, indexing="ij")
    pts = np.c_[X.ravel(), Y.ravel()]
    tiny = Surface(geo, ocl.CylCutter(0.05, 100), geo.zmin - 1)
    H = tiny.drop(pts).reshape(X.shape)
    H = np.where(H <= geo.zmin - 0.5, -1e9, H)  # off the part
    if band:
        inside = np.array([any(pyclipper.PointInPolygon(q, b) != 0 for b in band) for q in g.to_int(pts)]).reshape(X.shape)
        H = np.where(inside, H, np.maximum(H, material_top))
    k = int(math.ceil((NUT_RADIUS + 1) / step))
    need = 0.0
    # Max height within the nut's radius, per cutting point (sub-sampled for speed).
    sample = cut[:: max(len(cut) // 4000, 1)]
    for row in sample:
        x, y, z = row[2], row[3], row[4]
        i = int(round((x - xs[0]) / step))
        j = int(round((y - ys[0]) / step))
        win = H[max(i - k, 0):i + k + 1, max(j - k, 0):j + k + 1]
        if win.size:
            need = max(need, float(win.max()) - z + 1.0)
    return need


# --------------------------------------------------------------------------- engraving


def engrave(op, geo: g.PartGeometry, tp: Toolpath, curves: list, depth: float) -> Toolpath:
    """Text (glyph outlines, work XY) traced `depth` below the part's surface: every point is
    dropped onto the part with the real cutter first, so engraving on a dome keeps its depth.
    Deeper than one stepdown goes in passes. Points off the part are skipped (lifted over)."""
    cutter_args = (op.tool_kind, op.tool_d, op.corner_r, op.flute)
    surf = Surface(geo, cutter_for(*cutter_args), geo.zmin - 1.0, cutter_args)
    loops = [densify(np.asarray(c, float), 0.1) for c in curves if len(c) >= 2]
    if not loops:
        tp.warnings.append("No text to engrave.")
        return tp
    zs = surf.drop_many(loops)
    passes = max(1, int(np.ceil(depth / max(op.stepdown, 0.02) - 1e-9)))
    for xy, z in zip(loops, zs):
        on = z > geo.zmin - 0.5  # the cutter touched the part there
        for k in range(1, passes + 1):
            cut = z - depth * k / passes
            for seg in split_by_mask(xy, cut, on, min_len=2):
                # Rapid to just above the surface there, plunge, then follow the outline in 3D.
                top = float(seg[0, 2]) + depth * k / passes
                tp.go_to(seg[0, 0], seg[0, 1], seg[0, 2], op.plunge, op.link_feed, cleared_down_to=top + 0.3)
                for p in seg[1:]:
                    tp.line(p[0], p[1], p[2], op.feed, CUT)
                tp.retract()
    return tp
