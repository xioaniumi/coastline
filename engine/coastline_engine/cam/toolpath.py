"""Toolpath builder with Coastline's linking rules (mirrored by the Swift G-code validator):

- rapids (G0) that move in X/Y happen only at the clearance height (`safe_z`, above the stock);
- the tool never rapids down below `approach_z` (1 mm above the stock face): from there it
  feeds down, first at the link feed through already-cleared air, then at the plunge feed;
- every operation ends retracted to `safe_z`.

Rows: [role, motion, x, y, z, i, j, feed] as float32 (decoded by OperationToolpath.decode).
"""

from __future__ import annotations

import math

import numpy as np

RAPID, CUT, PLUNGE, RAMP, LEAD, LINK = 0, 1, 2, 3, 4, 5
LINE, CW, CCW = 0, 1, 2


class Toolpath:
    def __init__(self, safe_z: float = 3.0, approach_z: float = 1.0):
        self.rows: list[list[float]] = []
        self.pos: np.ndarray | None = None
        self.safe_z = safe_z
        self.approach_z = approach_z
        self.warnings: list[str] = []

    def _add(self, role, motion, x, y, z, i=0.0, j=0.0, f=0.0):
        self.rows.append([role, motion, x, y, z, i, j, f])
        self.pos = np.array([x, y, z], float)

    def rapid(self, x, y, z):
        self._add(RAPID, LINE, x, y, z)

    def line(self, x, y, z, f, role=CUT):
        if self.pos is not None and np.allclose(self.pos, (x, y, z), atol=1e-6):
            return
        self._add(role, LINE, x, y, z, f=f)

    def arc(self, x, y, z, cx, cy, cw: bool, f, role=CUT):
        """Arc (G2/G3 in XY, optional helical Z) from the current position about (cx, cy)."""
        self._add(role, CW if cw else CCW, x, y, z, cx - self.pos[0], cy - self.pos[1], f)

    def retract(self):
        if self.pos is not None and self.pos[2] < self.safe_z:
            self.rapid(self.pos[0], self.pos[1], self.safe_z)

    def go_to(self, x, y, z, plunge_feed, link_feed, cleared_down_to: float | None = None):
        """Moves to (x, y, z) safely: retract, rapid over at safe Z, rapid down to the approach
        height, feed down through cleared air (to `cleared_down_to`), then plunge feed."""
        self.retract()
        if self.pos is None:
            self.rapid(x, y, self.safe_z)
        else:
            self.rapid(x, y, self.safe_z)
        self.rapid(x, y, max(self.approach_z, z))
        if z < self.approach_z:
            air = self.approach_z if cleared_down_to is None else max(cleared_down_to, z)
            if air < self.approach_z - 1e-6:
                self.line(x, y, air, link_feed, LINK)
            self.line(x, y, z, plunge_feed, PLUNGE)

    def polyline(self, pts: np.ndarray, z: float, f: float, role=CUT, arc_tol: float | None = 0.005):
        """Follows XY points at height z, fitting arcs where they match within `arc_tol`."""
        from .arcfit import fit

        if arc_tol is None or len(pts) < 4:
            for p in pts:
                self.line(p[0], p[1], z, f, role)
            return
        for seg in fit(pts, arc_tol):
            if seg[0] == "line":
                self.line(seg[1][0], seg[1][1], z, f, role)
            else:
                _, end, centre, cw = seg
                self.arc(end[0], end[1], z, centre[0], centre[1], cw, f, role)

    def helix_down(self, cx, cy, r, z_from, z_to, angle_deg, f):
        """Helical ramp (CCW, climb in material) from z_from to z_to on radius r around (cx, cy)."""
        pitch = max(2 * math.pi * r * math.tan(math.radians(angle_deg)), 0.02)
        start = (cx + r, cy)
        if self.pos is None or not np.allclose(self.pos[:2], start, atol=1e-6):
            self.line(start[0], start[1], z_from, f, RAMP)
        z = z_from
        half = pitch / 2
        side = 1
        while z > z_to + 1e-9:
            z = max(z - half, z_to)
            side = -side
            self.arc(cx + side * r, cy, z, cx, cy, False, f, RAMP)
        # One full turn at depth to clear the bottom.
        for _ in range(2):
            side = -side
            self.arc(cx + side * r, cy, z_to, cx, cy, False, f, RAMP)

    def array(self) -> np.ndarray:
        return np.asarray(self.rows, np.float32).reshape(-1, 8)
