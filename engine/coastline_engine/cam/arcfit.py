"""Arc fitting: turns dense polylines into G2/G3 arcs and lines.

grbl's planner holds only 16 blocks and every line costs serial bandwidth, so long chains of
tiny segments make the CR-1 stutter. Fitting arcs within a tight tolerance keeps the motion
smooth and the files short, without changing the shape by more than `tol`.
"""

from __future__ import annotations

import math

import numpy as np


def _circle(a, b, c):
    """Centre and radius of the circle through three points, or None if collinear."""
    ax, ay = a
    bx, by = b
    cx, cy = c
    d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
    if abs(d) < 1e-12:
        return None
    ux = ((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay) + (cx * cx + cy * cy) * (ay - by)) / d
    uy = ((ax * ax + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax - cx) + (cx * cx + cy * cy) * (bx - ax)) / d
    return np.array([ux, uy]), math.hypot(ax - ux, ay - uy)


def _fits(pts, i, j, tol):
    """Returns (centre, cw) if points i..j lie on one arc within tol, sweeping < 270°."""
    if j - i < 3:
        return None
    m = (i + j) // 2
    c = _circle(pts[i], pts[m], pts[j])
    if c is None:
        return None
    centre, r = c
    # Near-straight runs stay lines: huge-radius arcs are numerically fragile in grbl
    # (error 33 when the rounded end point misses the radius).
    if r > 200 or r < 0.5:  # tiny arcs gain nothing and are fragile after 3-decimal rounding
        return None
    seg = pts[i : j + 1]
    d = np.abs(np.hypot(seg[:, 0] - centre[0], seg[:, 1] - centre[1]) - r)
    if d.max() > tol:
        return None
    # Midpoints of chords must also be close (catches zig-zags between arc points).
    mids = (seg[1:] + seg[:-1]) / 2
    sag = np.abs(np.hypot(mids[:, 0] - centre[0], mids[:, 1] - centre[1]) - r)
    if sag.max() > tol:
        return None
    v = seg - centre
    cross = v[:-1, 0] * v[1:, 1] - v[:-1, 1] * v[1:, 0]
    if not (np.all(cross > -1e-12) or np.all(cross < 1e-12)):
        return None
    ang = np.arctan2(cross, np.einsum("ij,ij->i", v[:-1], v[1:]))
    if abs(ang.sum()) > 1.5 * math.pi:
        return None
    return centre, bool(cross.sum() < 0)


def fit(pts: np.ndarray, tol: float = 0.005):
    """Yields ("line", end) and ("arc", end, centre, cw) segments from pts[0] onward
    (pts[0] is the current position)."""
    pts = np.asarray(pts, float)
    n = len(pts)
    out = []
    i = 0
    while i < n - 1:
        best = None
        step = 3
        j = i + 3
        # Exponential search for the longest arc, then refine.
        while j < n and _fits(pts, i, j, tol):
            best = j
            step *= 2
            j = i + step
        if best is not None:
            lo, hi = best, min(j, n - 1)
            while lo < hi:
                mid = (lo + hi + 1) // 2
                if _fits(pts, i, mid, tol):
                    lo = mid
                else:
                    hi = mid - 1
            centre, cw = _fits(pts, i, lo, tol)
            out.append(("arc", pts[lo], centre, cw))
            i = lo
        else:
            out.append(("line", pts[i + 1]))
            i += 1
    return out
