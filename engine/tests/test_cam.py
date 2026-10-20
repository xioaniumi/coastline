"""2.5D CAM on the sample pendant (30 mm disc, dome, ⌀2.4 bail hole)."""

from pathlib import Path

import numpy as np
import pytest

from coastline_engine.cad_import import import_part
from coastline_engine.cam import geometry as g
from coastline_engine.cam.arcfit import fit
from coastline_engine.server import PARTS, _features, _generate

RES = Path(__file__).resolve().parents[2] / "resources"

# Pendant placed with its top 0.5 mm below the stock face (Z0), centred.
M = np.eye(4)
M[2, 3] = -5.5
STOCK_MIN, STOCK_MAX = [-40, -75, -20], [40, 75, 0]


def _tool(d, flute=None):
    return {"diameter": d, "flute_length": flute or 3 * d, "kind": "flatEndMill"}


def _data(feed=800, stepdown=1.5, stepover=0.5):
    return {"feed": feed, "plunge_feed": feed * 0.35, "ramp_feed": feed * 0.8,
            "stepdown": stepdown, "stepover": stepover, "ramp_angle": 2}


@pytest.fixture(scope="module")
def pid():
    part = import_part(RES / "samples/pendant.step")
    PARTS["t1"] = part
    return "t1"


def test_features_find_the_bail_hole_and_rim_floor(pid):
    r, _ = _features({"part_id": pid, "transform": M.flatten().tolist()}, [])
    holes = r["holes"]
    assert len(holes) == 1
    assert holes[0]["diameter"] == pytest.approx(2.4, abs=1e-6)
    assert holes[0]["through"]
    assert r["part_z"] == pytest.approx([-5.5, -0.5], abs=1e-3)


def test_shadow_grows_with_depth(pid):
    geo = g.PartGeometry(PARTS[pid].mesh.vertices, PARTS[pid].mesh.indices, M)
    import pyclipper
    a_top = sum(pyclipper.Area(p) for p in geo.shadow(-1.0)) / g.SCALE**2  # holes are negative
    a_bottom = sum(pyclipper.Area(p) for p in geo.shadow(-5.0)) / g.SCALE**2
    assert a_bottom > a_top > 0
    assert a_bottom == pytest.approx(np.pi * 15**2 - np.pi * 1.2**2, rel=0.01)


def _run(pid, ops):
    r, blobs = _generate({"part_id": pid, "transform": M.flatten().tolist(), "stock_min": STOCK_MIN,
                          "stock_max": STOCK_MAX, "safe_z": 3, "ops": ops}, [])
    return r, [np.frombuffer(b, "<f4").reshape(-1, 8) for b in blobs]


def _check_linking(rows, safe=3.0, approach=1.0):
    """No rapid moves in XY below the safe height; no rapid descending below the approach height."""
    prev = None
    for row in rows:
        role, x, y, z = int(row[0]), row[2], row[3], row[4]
        if prev is not None and role == 0:
            moved_xy = abs(x - prev[0]) > 1e-4 or abs(y - prev[1]) > 1e-4
            assert not (moved_xy and min(z, prev[2]) < safe - 1e-4), f"rapid XY at Z{z}"
            assert z >= approach - 1e-4 or z >= prev[2], f"rapid down to Z{z}"
        prev = (x, y, z)


def test_operations_generate_safe_paths_that_never_gouge(pid):
    ops = [
        {"id": "f", "kind": "facing", "tool": _tool(6.35), "data": _data(stepdown=0.15, stepover=2.5), "face_depth": 0.3},
        {"id": "a", "kind": "adaptive", "tool": _tool(6.35), "data": _data(stepdown=1.5, stepover=0.5),
         "leave_radial": 0.2, "leave_axial": 0.1},
        {"id": "c", "kind": "contour", "tool": _tool(3.175), "data": _data(stepdown=4.0, stepover=0.15), "spring_pass": True},
        {"id": "d", "kind": "bore", "tool": _tool(1.5875), "data": _data(feed=300, stepdown=0.3)},
    ]
    r, paths = _run(pid, ops)
    assert [o["moves"] > 10 for o in r["ops"]] == [True] * 4, r
    geo = g.PartGeometry(PARTS[pid].mesh.vertices, PARTS[pid].mesh.indices, M)
    import pyclipper
    adaptive_rows = paths[1]
    cut_levels = np.unique(np.round(adaptive_rows[adaptive_rows[:, 0] == 1][:, 4], 2))
    assert len(cut_levels) >= 4, f"adaptive must cut every level, got {cut_levels}"
    for (op, rows) in zip(ops, paths):
        _check_linking(rows)
        assert rows[:, 4].min() >= STOCK_MIN[2] - 1e-6, "below the stock"
        if op["kind"] in ("adaptive", "contour"):
            # The tool centre must stay at least r + leave from the part at its height.
            r_tool = op["tool"]["diameter"] / 2 + op.get("leave_radial", 0) - 0.03
            cuts = rows[(rows[:, 0] != 0) & (rows[:, 4] < -0.6)]
            for z in np.unique(np.round(cuts[:, 4], 3))[:6]:
                pts = cuts[np.isclose(cuts[:, 4], z, atol=1e-3)][:, 2:4]
                region = g.offset(geo.shadow(z), r_tool)
                inside = [pyclipper.PointInPolygon(tuple(map(int, p * g.SCALE)), poly) for p in pts for poly in region]
                assert not any(v == 1 for v in inside), f"{op['kind']} gouges at Z{z}"


def test_arc_fit_recovers_a_circle():
    t = np.linspace(0, np.pi, 200)
    pts = np.c_[10 + 5 * np.cos(t), 2 + 5 * np.sin(t)]
    segs = fit(pts, 0.002)
    arcs = [s for s in segs if s[0] == "arc"]
    assert len(segs) <= 3 and arcs
    assert arcs[0][2] == pytest.approx([10, 2], abs=1e-3)
    assert arcs[0][3] is False  # counter-clockwise


def test_holding_tabs_keep_material_at_the_bottom_of_a_through_cut(pid):
    """Tabs (bridges) at the bottom of the cut: the contour goes around them there, and only
    there; nothing cuts inside a tab's rectangle within its Z range."""
    zb = -5.0  # the pendant spans Z -5.5…-0.5 here
    ops = [{"id": "c", "kind": "contour", "tool": _tool(3.175), "data": _data(stepdown=0.4),
            "spring_pass": False, "z_min": zb}]
    r, blobs = _generate({"part_id": pid, "transform": M.flatten().tolist(), "stock_min": STOCK_MIN,
                          "stock_max": STOCK_MAX, "ops": ops,
                          "tabs": {"count": 3, "width": 2.0, "height": 0.8, "z_bottom": zb}}, [])
    tabs = r["tabs"]
    # An odd count becomes mirrored pairs: four, 90° apart around the 30 mm disc.
    assert len(tabs) == 4
    angles = sorted(np.degrees(np.arctan2(t["centre"][1], t["centre"][0])) % 360 for t in tabs)
    gaps = np.diff(angles + [angles[0] + 360])
    assert all(80 < gp < 100 for gp in gaps), gaps
    for t in tabs:
        assert abs(np.hypot(*t["centre"]) - 15) < 0.6
    rows = np.frombuffer(blobs[0], "<f4").reshape(-1, 8)
    cuts = rows[rows[:, 0] != 0]
    import pyclipper
    low = cuts[cuts[:, 4] <= zb + 0.8 + 1e-3]
    high = cuts[(cuts[:, 4] > zb + 0.8 + 0.05)]
    assert len(low) and len(high)
    r_tool = 3.175 / 2
    for t in tabs:
        poly = g.to_int(t["poly"])
        grown = g.offset([poly], r_tool - 0.02)
        inside_low = [p for p in low if any(pyclipper.PointInPolygon(g.to_int([p[2:4]])[0], q) for q in grown)]
        assert not inside_low, f"tool centre inside a tab at {inside_low[:2]}"
    # Above the tabs the contour is the plain circle again (tool centre at r = 15 + tool radius).
    rr = np.hypot(high[:, 2], high[:, 3])
    ring = rr[(rr > 14) & (rr < 18)]
    assert len(ring) and abs(np.median(ring) - (15 + r_tool)) < 0.15


def test_holding_tabs_reach_into_the_frame_the_other_side_leaves(pid):
    """With the frame known (side A's cut simulated by the app), every tab runs out until it is
    well into it, however wide side A's channel is on that side (here twice as wide below)."""
    import base64
    zb = -5.0
    cell = 0.2
    x0, y0 = STOCK_MIN[0], STOCK_MIN[1]
    cols = int((STOCK_MAX[0] - x0) / cell) + 1
    rows = int((STOCK_MAX[1] - y0) / cell) + 1
    xs, ys = np.meshgrid(x0 + np.arange(cols) * cell, y0 + np.arange(rows) * cell)
    r = np.hypot(xs, ys)
    frame = np.where(ys >= 0, r >= 18.0, r >= 24.0)
    bits = base64.b64encode(np.packbits(frame.ravel()).tobytes()).decode()
    ops = [{"id": "c", "kind": "contour", "tool": _tool(3.175), "data": _data(stepdown=0.4),
            "spring_pass": False, "z_min": zb}]
    res, _ = _generate({"part_id": pid, "transform": M.flatten().tolist(), "stock_min": STOCK_MIN,
                        "stock_max": STOCK_MAX, "ops": ops,
                        "tabs": {"count": 4, "width": 2.0, "height": 0.8, "z_bottom": zb, "reach": 4.0,
                                 "frame": {"x0": x0, "y0": y0, "cell": cell, "cols": cols, "rows": rows, "bits": bits}}}, [])
    tabs = res["tabs"]
    assert len(tabs) == 4
    for t in tabs:
        c, n = np.array(t["centre"]), np.array(t["normal"])
        far = max(float(np.dot(np.array(p) - c, n)) for p in t["poly"])
        end = c + n * far
        need = 18.0 if end[1] >= 0 else 24.0
        # 1.5 mm into the frame at its end (a cell's rounding either way), not the 4 mm asked.
        assert np.hypot(*end) >= need + 1.5 - 0.3, (t["centre"], far)
        assert far < 24.0 - 15 + 1.5 + 1.0


def test_backing_clears_a_wider_band_and_keeps_the_frame(pid):
    """Side B's backing: adaptive above the part with a wide band clears further out than the
    default band, down to its floor only, and the holder check sees the uncut frame at Z0."""
    def run(band):
        op = {"id": "b", "kind": "adaptive", "tool": _tool(6.35), "data": _data(stepdown=3.0, stepover=0.8),
              "z_min": -0.4}
        if band is not None:
            op["band"] = band
            op["frame_top"] = 0.0
        r, blobs = _run(pid, [op])
        a = blobs[0]
        return r["ops"][0], a[a[:, 0] == 1]
    meta_n, narrow = run(None)
    meta_w, wide = run(22.0)  # the default band is 1.6 diameters + 1 mm (11 mm here)
    rn = np.hypot(narrow[:, 2], narrow[:, 3]).max()
    rw = np.hypot(wide[:, 2], wide[:, 3]).max()
    assert rw > rn + 5, (rn, rw)
    assert wide[:, 4].min() >= -0.4 - 1e-6, "never below the backing's floor"


def test_roughing_stays_within_the_reach_and_the_band(pid):
    """The band is cleared as a pocket: the tool centre never leaves the reach window
    (max_span) and never goes past the band into the frame."""
    op = {"id": "r", "kind": "adaptive", "tool": _tool(6.35), "data": _data(stepdown=2.0, stepover=0.8),
          "max_span": [30.0, 200.0]}
    r, blobs = _run(pid, [op])
    cut = blobs[0][blobs[0][:, 0] != 0]
    assert len(cut) > 100
    span = cut[:, 2].max() - cut[:, 2].min()
    assert span <= 30.0 + 0.05, span


def test_thread_milling_climbs_one_pitch_a_turn_on_the_thread_radius():
    """An M3 × 0.5 thread in a Ø2.5 through hole 6 mm deep, with a Ø2.3 single-form cutter: the
    cutter feeds down the hole's centre, arcs in tangent, climbs (G3) one pitch per turn on the
    radius (major − cutter) / 2, in two radial passes, and arcs back to the centre."""
    import math
    from coastline_engine.cam import ops as O
    from coastline_engine.cam.toolpath import Toolpath, CUT, LEAD, CCW

    op = O.Op({"id": "t", "kind": "thread", "tool": {"diameter": 2.3, "flute_length": 9.5, "kind": "threadMill"},
               "data": _data(feed=300)})
    hole = {"x": 5.0, "y": -2.0, "diameter": 2.5, "z_top": 0.0, "z_bottom": -6.0, "through": True}
    tp = O.thread(op, [hole], Toolpath(), major=3.0, pitch=0.5)
    rows = tp.array()
    assert not tp.warnings
    cuts = rows[rows[:, 0] == CUT]
    assert len(cuts) and (cuts[:, 1] == CCW).all(), "climbing: G3 all the way"
    r_full = 3.0 / 2 - 2.3 / 2
    radii = np.hypot(cuts[:, 2] - 5.0, cuts[:, 3] + 2.0)
    assert abs(radii.max() - r_full) < 1e-4
    # Each pass: 12 turns (6 mm / 0.5), 24 half-turns, each half a pitch up, from the bottom.
    full = cuts[np.abs(radii - r_full) < 1e-4]
    assert len(full) == 24
    assert np.allclose(np.diff(full[:, 4]), 0.25, atol=1e-4)
    assert abs(full[0, 4] - (-6.0 + 0.25)) < 1e-4 and abs(full[-1, 4] - 0.0) < 1e-4
    # Arcs in and out are tangent half circles from and to the centre.
    leads = rows[rows[:, 0] == LEAD]
    assert len(leads) == 4
    assert all(abs(math.hypot(r[5], r[6]) - abs(r[2] - 5.0) / 2) < 1e-3 or abs(math.hypot(r[5], r[6]) - r_full / 2) < 0.2 for r in leads)
    # Never below the thread's bottom; the feed at the centre is scaled to the edge's.
    assert rows[:, 4].min() >= -6.0 - 1e-6
    assert abs(cuts[0, 7] - 300 * r_full / 1.5) < 1e-3


def test_nest_is_a_closed_block_with_the_parts_face_as_its_cavity():
    """The first-cut coupon (34 × 24 × 6, flat back) face-down in its nest: a watertight block
    tall enough for the clamp kit's jaw, its cavity floor the clearance below the part's back,
    the rim below the part's top so it stands free."""
    import io

    import trimesh

    from coastline_engine.server import _nest

    PARTS["coupon"] = import_part(RES / "examples/first_cut.step")
    meta, blobs = _nest({"part_id": "coupon", "transform": np.eye(4).ravel().tolist(), "clearance": 0.1, "wall": 4.0}, [])
    m = trimesh.load(io.BytesIO(blobs[0]), file_type="stl")
    assert m.is_watertight and m.is_winding_consistent and m.volume > 0
    assert meta["size"][0] >= 24.0 - 1e-6, "tall enough for the jaw"
    assert abs(meta["base"] - (0.0 - 0.1 - 3.0)) < 1e-6, "3 mm floor under the cavity, 0.1 below the back"
    assert 0.5 < meta["proud"] < meta["part_height"], meta
    # The cavity is the coupon's outline: at its centre the floor is at the back (−0.1), outside
    # the outline (+ clearance + a cell) the rim.
    z = m.vertices[:, 2]
    centre = m.vertices[(np.abs(m.vertices[:, 0]) < 1) & (np.abs(m.vertices[:, 1]) < 1) & (z > meta["base"] + 1)]
    assert np.allclose(centre[:, 2], -0.1, atol=1e-4)
    assert abs(z.max() - meta["rim"]) < 1e-6
