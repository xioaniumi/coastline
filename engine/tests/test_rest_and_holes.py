"""Holes must go all the way round; rest roughing knows what larger tools cleared."""
from coastline_engine.cam import geometry as g
from coastline_engine.cam.features import _coverage
from coastline_engine.cam.ops import _difference, _swept_by_earlier, _reach_rect


def test_a_quarter_arc_is_not_a_hole():
    assert _coverage([0, 30, 60, 90]) < 100
    assert _coverage(list(range(0, 360, 10))) > 340
    # Two half-cylinders of one hole together go all the way round.
    assert _coverage(list(range(0, 181, 10)) + list(range(180, 361, 10))) > 340


def test_rest_roughing_works_only_corners_a_larger_tool_left():
    pocket = g.to_int(g.rect(0, 0, 10, 10))[::-1]   # a hole (CW) 10 mm square
    done = _swept_by_earlier(pocket, [{"diameter": 3.175, "min_pocket": 2.5, "leave": 0.2}])
    assert done is not None
    left = _difference([pocket], done)
    area = abs(sum(g.pyclipper.Area(p) for p in left)) / g.SCALE ** 2   # the square with a hole
    assert 0 < area < 0.15 * 100           # a frame of 0.2 mm plus the four corners
    # Too narrow for that tool (min_pocket 2.5 × 3.175 = 7.9 mm): nothing was cleared.
    narrow = g.to_int(g.rect(0, 0, 6, 6))[::-1]
    assert _swept_by_earlier(narrow, [{"diameter": 3.175, "min_pocket": 2.5, "leave": 0.2}]) is None


def test_reach_window_is_centred_on_the_part():
    r = _reach_rect([g.to_int(g.rect(10, 0, 80, 100))], (85.0, 240.0), -(3.175 + 0.3), (0, 0))
    assert abs((r[0] + r[2]) / 2 - 45) < 1e-6 and abs(r[2] - r[0] - (85 - 6.35 - 0.6)) < 1e-6


def test_a_wide_shank_never_goes_into_a_narrow_slot():
    """A 1/32" ball on a 1/8" shank (2.4 mm of flute) over a 2 mm slot 10 mm deep: the tip stops
    where the shank meets the slot's top edges, never 10 mm down (the shank would plough the part)."""
    import numpy as np
    import trimesh
    from coastline_engine.cam import surface3d as S3
    a = trimesh.creation.box(extents=(10, 20, 10)); a.apply_translation((-6, 0, -5))
    b = trimesh.creation.box(extents=(10, 20, 10)); b.apply_translation((6, 0, -5))
    m = trimesh.util.concatenate([a, b])           # two blocks, a 2 mm slot between, top at Z0
    geo = g.PartGeometry(m.vertices, m.faces, np.eye(4))
    args = ("ballEndMill", 0.79, 0.395, 2.4)
    tip_only = S3.Surface(geo, S3.cutter_for(*args), -10.0, args)
    with_shank = S3.Surface(geo, S3.cutter_for(*args), -10.0, args, shank=(3.175, 2.4))
    centre = np.array([[0.0, 0.0]])
    assert tip_only.drop(centre)[0] < -9          # the tip alone would go to the bottom
    z = with_shank.drop(centre)[0]
    assert z >= -2.4 - 1e-6, z                     # the shank sits on the slot's edges
    assert with_shank.shank_held == 1


def test_3d_finishing_rides_over_holding_tabs():
    """Tabs aren't in the part's mesh: a ball finishing next to the part must stay on a tab's
    top, not cut through it (side B would free the part)."""
    import numpy as np
    import trimesh
    from coastline_engine.cam import surface3d as S3
    part = trimesh.creation.box(extents=(10, 10, 4)); part.apply_translation((0, 0, -2))
    geo = g.PartGeometry(part.vertices, part.faces, np.eye(4))
    tab = g.rect(5, -1, 9, 1)                      # 4 mm out from the part's +X side, 2 mm wide
    geo.tabs = ([g.to_int(tab)], -4.0, -3.2)      # from the bottom up 0.8 mm
    args = ("ballEndMill", 1.0, 0.5, 4.0)
    surf = S3.Surface(geo, S3.cutter_for(*args), -4.0, args)
    z = surf.drop(np.array([[7.0, 0.0], [7.0, 5.0]]))
    assert z[0] >= -3.2 - 1e-9, z                  # over the tab: on its top
    assert z[1] <= -3.9, z                         # beside it: down to the floor
