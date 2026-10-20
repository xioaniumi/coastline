"""Spike: FreeCAD's Adaptive2d clears a pocket with constant engagement."""

import math

from coastline_engine import _native as N


def _circle(cx, cy, r, n=180):
    return [(cx + r * math.cos(2 * math.pi * i / n), cy + r * math.sin(2 * math.pi * i / n)) for i in range(n)]


def test_adaptive_clears_a_30mm_pocket_with_an_island():
    a = N.Adaptive2d()
    a.tool_diameter = 6.0
    a.step_over_factor = 0.15  # 15% radial engagement: adaptive territory
    a.helix_ramp_target_diameter = 4.5
    a.helix_ramp_min_diameter = 1.0
    a.tolerance = 0.1
    a.op_type = N.OperationType.ClearingInside
    square = [(0, 0), (30, 0), (30, 30), (0, 30)]
    island = list(reversed(_circle(15, 15, 4)))
    out = a.execute(stock_paths=[square], paths=[square, island])
    assert out, "no regions"
    cut = [p for r in out for (mt, p) in r.paths if mt == int(N.MotionType.Cutting)]
    pts = [pt for p in cut for pt in p]
    assert len(pts) > 200
    # Tool centre stays ≥ radius from the walls and outside the island.
    for x, y in pts:
        assert 3.0 - 0.15 <= x <= 27.0 + 0.15 and 3.0 - 0.15 <= y <= 27.0 + 0.15
        assert math.hypot(x - 15, y - 15) >= 7.0 - 0.15
    assert not any(r.uncleared_area_remains for r in out)
