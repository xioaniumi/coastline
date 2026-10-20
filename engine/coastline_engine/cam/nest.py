"""A printable nest: a block with a cavity shaped like one face of the part, so a part already
cut free sits face-down in it and its other face can be machined (the Operator Manual's "custom
clamshell", printed on a Formlabs printer in Rigid 10K or Tough 2000). The nest goes into the
universal clamp like stock.

Built from height fields, as a mesh (watertight, written as binary STL):

- the part's lowest surface at each point, in the work frame of the setup that machines it
  (that face down, the face to machine toward the spindle), grown sideways by the clearance
  and lowered by it: the cavity;
- the rim at the part's widest section (no higher than 70 % of its height, and 1 mm below its
  top), so everything above stands free for the tool;
- two lift notches across the rim at the ends of the part, to get it out again;
- a block around it, `wall` thick, at least `min_height` tall (the clamp kit's jaw grips
  23.6–40.6 mm), with `floor` below the deepest point.
"""

from __future__ import annotations

import struct

import numpy as np

from . import geometry as g


def _bottom_field(geo_flipped, xs, ys) -> np.ndarray:
    """The part's lowest Z at each grid point (rows × cols, NaN off the part), from the part
    turned over about X ((x, y, z) → (x, −y, −z)): its top at (x, −y) is minus our bottom."""
    import opencamlib as ocl

    from . import surface3d as S3

    X, Y = np.meshgrid(xs, ys)
    floor = geo_flipped.zmin - 1.0
    surf = S3.Surface(geo_flipped, ocl.CylCutter(0.02, 100), floor)
    z = surf.drop(np.c_[X.ravel(), -Y.ravel()]).reshape(X.shape)
    return np.where(z <= floor + 1e-6, np.nan, -z)


def _grow_min(a: np.ndarray, r: int) -> np.ndarray:
    """Minimum over a disc of r cells (the cavity grown sideways by the clearance)."""
    if r <= 0:
        return a
    out = a.copy()
    h, w = a.shape
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            if dx * dx + dy * dy > r * r:
                continue
            shifted = np.full_like(a, np.inf)
            ys = slice(max(dy, 0), h + min(dy, 0)), slice(max(-dy, 0), h + min(-dy, 0))
            xs = slice(max(dx, 0), w + min(dx, 0)), slice(max(-dx, 0), w + min(-dx, 0))
            shifted[ys[0], xs[0]] = a[ys[1], xs[1]]
            out = np.minimum(out, shifted)
    return out


def widest_level(geo: g.PartGeometry, steps: int = 40) -> float:
    """The Z where the part's cross-section is largest (it narrows above and below)."""
    import pyclipper

    best, best_z = -1.0, (geo.zmin + geo.zmax) / 2
    for z in np.linspace(geo.zmin + 0.05, geo.zmax - 0.05, steps):
        area = sum(abs(pyclipper.Area(p)) for p in geo.region(float(z))) / g.SCALE ** 2
        if area > best + 1e-6:
            best, best_z = area, float(z)
    return best_z


def build(geo: g.PartGeometry, geo_flipped: g.PartGeometry, cell: float = 0.15, clearance: float = 0.1, wall: float = 4.0,
          floor: float = 3.0, min_height: float = 24.0, notch: float = 6.0) -> dict:
    """The nest as triangles in the work frame (x, y, z; Z up toward the spindle) and its facts."""
    top, bottom = geo.zmax, geo.zmin
    height = top - bottom
    rim = min(widest_level(geo), bottom + 0.7 * height, top - 1.0)
    # The footprint (with room for the clearance and the notches), then the block around it.
    xs_part = geo.mesh.vertices[:, 0]
    ys_part = geo.mesh.vertices[:, 1]
    lo = np.array([xs_part.min(), ys_part.min()]) - clearance - cell
    hi = np.array([xs_part.max(), ys_part.max()]) + clearance + cell
    blo, bhi = lo - wall, hi + wall
    # Tall enough for the clamp kit's jaw (X is up in the clamp).
    if bhi[0] - blo[0] < min_height:
        grow = (min_height - (bhi[0] - blo[0])) / 2
        blo[0] -= grow
        bhi[0] += grow
    cols = int(np.ceil((bhi[0] - blo[0]) / cell)) + 1
    rows = int(np.ceil((bhi[1] - blo[1]) / cell)) + 1
    xs = blo[0] + cell * np.arange(cols)
    ys = blo[1] + cell * np.arange(rows)
    b = _bottom_field(geo_flipped, xs, ys)  # rows × cols
    cav = np.where(np.isnan(b), np.inf, b - clearance)
    cav = _grow_min(cav, int(np.ceil(clearance / cell)))
    h = np.minimum(np.where(np.isfinite(cav), cav, rim), rim)
    deepest = float(h.min())
    # Lift notches: across the rim at the part's two ends along Y (its length), down to the
    # cavity there, so a fingernail or a pick gets under it.
    inside = np.isfinite(cav) & (cav < rim)
    if inside.any() and notch > 0:
        cols_in = np.where(inside.any(axis=0))[0]
        rows_in = np.where(inside.any(axis=1))[0]
        cx = (xs[cols_in[0]] + xs[cols_in[-1]]) / 2
        band = np.abs(xs - cx) <= notch / 2
        reach = int(np.ceil(2.5 / cell))  # 2.5 mm into the rim: the outer wall stays whole
        for end, step in ((rows_in[0], -1), (rows_in[-1], 1)):
            depth = float(np.nanmin(np.where(inside[end], h[end], np.nan)))
            floor_z = max(depth, rim - 0.6 * (rim - deepest))
            for k in range(0, reach + 1):
                r = end + step * k
                if 1 <= r < rows - 1:
                    h[r, band] = np.minimum(h[r, band], floor_z)
    h[0, :] = h[-1, :] = rim  # the outer edge stays whole: the walls stand on it
    h[:, 0] = h[:, -1] = rim
    z0 = deepest - floor
    tris = _mesh(xs, ys, h, z0)
    return {"triangles": tris, "size": [float(bhi[0] - blo[0]), float(bhi[1] - blo[1]), float(rim - z0)],
            "rim": float(rim), "base": float(z0), "proud": float(top - rim), "min": [float(blo[0]), float(blo[1]), float(z0)],
            "part_height": float(height)}


def _mesh(xs, ys, h, z0) -> np.ndarray:
    """A closed solid: the height-field top, walls down from its border, a flat base."""
    rows, cols = h.shape
    X, Y = np.meshgrid(xs, ys)
    top = np.stack([X, Y, h], axis=-1)
    idx = lambda r, c: top[r, c]  # noqa: E731
    tris = []
    # Top: two triangles a cell, counter-clockwise seen from above.
    a = top[:-1, :-1].reshape(-1, 3)
    b = top[:-1, 1:].reshape(-1, 3)
    c = top[1:, 1:].reshape(-1, 3)
    d = top[1:, :-1].reshape(-1, 3)
    tris.append(np.stack([a, b, c], axis=1))
    tris.append(np.stack([a, c, d], axis=1))
    # The border, counter-clockwise seen from above.
    ring = ([(0, j) for j in range(cols)] + [(i, cols - 1) for i in range(1, rows)]
            + [(rows - 1, j) for j in range(cols - 2, -1, -1)] + [(i, 0) for i in range(rows - 2, 0, -1)])
    border = np.array([idx(r, c) for r, c in ring])
    base = border.copy()
    base[:, 2] = z0
    nxt = np.roll(np.arange(len(border)), -1)
    # Walls: outward (the ring runs counter-clockwise, so outward is to its right).
    wall1 = np.stack([border, base, base[nxt]], axis=1)
    wall2 = np.stack([border, base[nxt], border[nxt]], axis=1)
    tris += [wall1, wall2]
    # Base: a fan from its centre, facing down (clockwise seen from above).
    centre = np.array([(xs[0] + xs[-1]) / 2, (ys[0] + ys[-1]) / 2, z0])
    fan = np.stack([np.repeat(centre[None], len(base), 0), base[nxt], base], axis=1)
    tris.append(fan)
    return np.concatenate(tris).astype(np.float32)


def stl_bytes(tris: np.ndarray, name: str = "Coastline nest") -> bytes:
    """Binary STL (normals from the winding)."""
    v0, v1, v2 = tris[:, 0], tris[:, 1], tris[:, 2]
    n = np.cross(v1 - v0, v2 - v0)
    ln = np.linalg.norm(n, axis=1, keepdims=True)
    n = np.where(ln > 0, n / np.maximum(ln, 1e-12), 0).astype(np.float32)
    rec = np.zeros(len(tris), dtype=[("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")])
    rec["n"] = n
    rec["v"] = tris
    header = name.encode()[:80].ljust(80, b" ")
    return header + struct.pack("<I", len(tris)) + rec.tobytes()
