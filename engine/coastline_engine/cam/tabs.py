"""Holding tabs (also called bridges): small bars of uncut material that keep the part attached
to the surrounding stock frame when the last side cuts all the way through. After machining
the part "floats" in the frame on the tabs; a jeweller's saw or flush cutter takes it out and a
file cleans the stubs.

Tabs are rectangles in the work XY plane, from just inside the part's outline out across the
clearing band into the frame, kept for a short Z range at the bottom of the through-cut. The
operations treat them as part of the part (PartGeometry.region adds them), so roughing and
contouring go around them without special cases.
"""

from __future__ import annotations

import numpy as np
import pyclipper

from . import geometry as g


def _turning(pts: np.ndarray, i: int, span: float) -> float:
    """How sharply the outline turns around point i, over ±span mm (radians, 0 = straight)."""
    n = len(pts)
    seg = np.linalg.norm(np.diff(np.vstack([pts, pts[:1]]), axis=0), axis=1)

    def walk(step):
        j, d = i, 0.0
        while d < span:
            k = (j + step) % n
            d += seg[min(j, k) if step > 0 else k]
            j = k
            if j == i:
                break
        return pts[j]

    a, b = pts[i] - walk(-1), walk(1) - pts[i]
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    if na < 1e-9 or nb < 1e-9:
        return np.pi
    return float(np.arccos(np.clip(np.dot(a, b) / (na * nb), -1, 1)))


class Frame:
    """Where the frame stays at the tabs' height once the other side is cut (from the app's
    simulation of it): a boolean grid over the stock."""

    def __init__(self, d: dict):
        import base64
        self.x0, self.y0, self.cell = float(d["x0"]), float(d["y0"]), float(d["cell"])
        self.cols, self.rows = int(d["cols"]), int(d["rows"])
        bits = np.unpackbits(np.frombuffer(base64.b64decode(d["bits"]), dtype=np.uint8))
        self.grid = bits[: self.cols * self.rows].reshape(self.rows, self.cols).astype(bool)

    def at(self, p: np.ndarray) -> np.ndarray:
        """Frame at points (n×2)? Off the grid is not frame."""
        c = np.rint((p[:, 0] - self.x0) / self.cell).astype(int)
        r = np.rint((p[:, 1] - self.y0) / self.cell).astype(int)
        ok = (c >= 0) & (c < self.cols) & (r >= 0) & (r < self.rows)
        out = np.zeros(len(p), dtype=bool)
        out[ok] = self.grid[r[ok], c[ok]]
        return out


# How far into the frame a tab's end goes (mm): enough to stay joined to it however the
# simulated edge is off by a cell or two.
FRAME_GRIP = 1.5


def frame_reach(frame: Frame, p: np.ndarray, normal: np.ndarray, tangent: np.ndarray, width: float, limit: float) -> float | None:
    """How long a tab from p along normal must be to end FRAME_GRIP mm inside the frame, across
    its whole width (None: it never gets there within limit)."""
    across = np.array([-0.5, -0.25, 0.0, 0.25, 0.5]) * width
    step = 0.25
    run = 0.0
    for s in np.arange(0.5, limit + 1e-9, step):
        q = p + normal * s + np.outer(across, tangent)
        run = run + step if frame.at(q).all() else 0.0
        if run >= FRAME_GRIP:
            return float(s)
    return None


def place_tabs(geo: g.PartGeometry, z: float, count: int, width: float, reach: float, stock=None, frame: Frame | None = None,
               avoid: list | None = None, within_x: tuple | None = None) -> list[dict]:
    """Tab rectangles on the part's outer outline at height z, in mirrored pairs about the
    part's centre (a part held unevenly twists and chatters when the last tab cuts free): on
    the sides of its outline box whose tabs end in frame that stays (not an open stock edge),
    opposite sides alike, nudged off sharp corners (a tab there is hard to file clean).
    Returns [{centre, normal, poly (mm, 4×2)}]."""
    region = geo.region(z)
    outers, _ = g.outer_and_holes(region)
    if not outers:
        return []
    outer = max(outers, key=lambda p: abs(pyclipper.Area(p)))
    pts = g.to_mm(outer)
    if pyclipper.Area(outer) < 0:
        pts = pts[::-1]  # CCW
    # Resample at ~0.25 mm so arc length and normals are even.
    closed = np.vstack([pts, pts[:1]])
    seg = np.linalg.norm(np.diff(closed, axis=0), axis=1)
    s = np.r_[0, np.cumsum(seg)]
    perimeter = s[-1]
    if perimeter < 4 * width:
        return []
    ss = np.arange(0, perimeter, 0.25)
    res = np.c_[np.interp(ss, s, closed[:, 0]), np.interp(ss, s, closed[:, 1])]
    n = len(res)

    def outward(j):
        t = res[(j + 2) % n] - res[(j - 2) % n]
        t = t / max(np.linalg.norm(t), 1e-9)
        nrm = np.array([t[1], -t[0]])
        probe = g.to_int([res[j] + nrm * 0.3])[0]
        return -nrm if pyclipper.PointInPolygon(probe, outer) != 0 else nrm

    def tangent(j):
        t = res[(j + 2) % n] - res[(j - 2) % n]
        return t / max(np.linalg.norm(t), 1e-9)

    # How long the tab at j must be: with the frame known (the other side's cut simulated), until
    # it's well into the frame; else the length asked for. None: it can't reach stock that stays.
    lengths_seen: dict[int, float | None] = {}

    def length(j):
        if j not in lengths_seen:
            lengths_seen[j] = _length(j)
        return lengths_seen[j]

    def _length(j):
        if frame is not None:
            if stock is None:
                limit = 40.0
            else:
                (x0, y0), (x1, y1) = stock
                limit = float(np.hypot(x1 - x0, y1 - y0))
            return frame_reach(frame, res[j], outward(j), tangent(j), width, limit)
        return reach

    # Nor may it cross a circle to avoid (a window side B opens over a reference bore).
    def clear_of_avoid(j, L):
        p, nrm, tg = res[j], outward(j), tangent(j)
        for x, y, r in avoid or []:
            d = np.array([x, y]) - p
            u = np.clip(np.dot(d, nrm), -0.4, L)
            v = np.clip(np.dot(d, tg), -width / 2, width / 2)
            if np.linalg.norm(d - nrm * u - tg * v) < r:
                return False
        return True

    # A tab holds only if its outer end lands in stock that stays: at least 1 mm inside it.
    def holds(j):
        L = length(j)
        if L is None or not clear_of_avoid(j, L):
            return False
        if within_x is not None:
            # Its whole end within reach (the tools go round it there).
            e = res[j] + outward(j) * L
            for s in (-0.5, 0.5):
                x = (e + tangent(j) * width * s)[0]
                if not within_x[0] <= x <= within_x[1]:
                    return False
        if stock is None:
            return True
        (x0, y0), (x1, y1) = stock
        e = res[j] + outward(j) * L
        return x0 + 1 <= e[0] <= x1 - 1 and y0 + 1 <= e[1] <= y1 - 1

    lo, hi = res.min(axis=0), res.max(axis=0)
    c = (lo + hi) / 2
    half = (hi - lo) / 2
    # The four sides of the outline box: (axis the side faces along, sign), its length.
    sides = [(1, 1), (1, -1), (0, 1), (0, -1)]  # +Y, −Y, +X, −X

    def side_point(axis, sign, offset):
        """The outline's outermost point toward (axis, sign) on the line `offset` from the
        centre along the other axis."""
        other = 1 - axis
        near = np.where(np.abs(res[:, other] - (c[other] + offset)) < 0.6)[0]
        if len(near) == 0:
            return None
        outmost = (res[near, axis] * sign).max()
        top = near[res[near, axis] * sign > outmost - 0.05]
        return int(top[np.argmin(np.abs(res[top, other] - (c[other] + offset)))])

    def side_ok(axis, sign):
        j = side_point(axis, sign, 0.0)
        return j is not None and holds(j)

    ok = {sd: side_ok(*sd) for sd in sides}
    # Opposite sides go together (mirrored): a pair of sides counts only if both hold.
    pairs = [((1, 1), (1, -1)), ((0, 1), (0, -1))]
    usable = [pr for pr in pairs if ok[pr[0]] and ok[pr[1]]]
    if not usable:
        usable = [pr for pr in pairs if ok[pr[0]] or ok[pr[1]]] or pairs
    count = max(count + (count % 2), 2)  # in pairs
    # Share the tabs between the usable pairs of sides by their length.
    lengths = [2 * half[1 - pr[0][0]] for pr in usable]
    per_side = [0] * len(usable)
    for _ in range(count // 2):
        k = max(range(len(usable)), key=lambda i: lengths[i] / (per_side[i] + 1))
        per_side[k] += 1
    tabs = []
    used: list[int] = []
    for (sa, sb), m in zip(usable, per_side):
        axis = sa[0]
        other = 1 - axis
        # m tabs along each of the two sides, evenly over its middle (not at its corners).
        span = half[other] * 0.9
        offsets = [0.0] if m == 1 else [-span + 2 * span * (k + 0.5) / m for k in range(m)]
        for side in (sa, sb):
            if not ok[side] and stock is not None:
                continue
            for off in offsets:
                j0 = side_point(axis, side[1], off)
                if j0 is None:
                    continue
                # Off a sharp corner, within a few mm, still holding and apart from the others.
                # (Further along, up to 10 mm, where the other side's channel leaves no frame near.)
                cand = []
                for span in ((12, 40) if frame is not None else (12,)):
                    window = [(j0 + d) % n for d in range(-span, span + 1)]
                    cand = [j for j in window if holds(j) and all(min(abs(j - u), n - abs(j - u)) > 4 * width / 0.25 for u in used)]
                    if cand:
                        break
                if not cand:
                    continue
                # Sharpness first (to 0.05 rad), then (with the frame known) the shortest to it,
                # then the nearest to the mirrored spot.
                i = min(cand, key=lambda j: (round(_turning(res, j, width) / 0.05),
                                             round(length(j) / 2) if frame is not None else 0,
                                             min(abs(j - j0), n - abs(j - j0))))
                used.append(i)
                t = res[(i + 2) % n] - res[(i - 2) % n]
                t /= max(np.linalg.norm(t), 1e-9)
                normal = outward(i)
                cpt = res[i]
                a, b = cpt - normal * 0.4, cpt + normal * length(i)
                h = t * width / 2
                poly = np.array([a - h, b - h, b + h, a + h])
                tabs.append({"centre": cpt.tolist(), "normal": normal.tolist(), "poly": poly})
    return tabs


def attach(geo: g.PartGeometry, tabs: list[dict], z_lo: float, z_hi: float) -> None:
    """Makes the tabs part of the geometry between z_lo and z_hi."""
    if tabs:
        geo.tabs = ([g.to_int(t["poly"]) for t in tabs], z_lo, z_hi)
