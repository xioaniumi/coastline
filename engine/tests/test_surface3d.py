"""3D finishing on the pendant's dome (30 mm disc, 5 mm thick, domed top)."""

from pathlib import Path

import numpy as np
import pytest

from coastline_engine.cad_import import import_part
from coastline_engine.cam import geometry as g
from coastline_engine.cam import surface3d as S3
from coastline_engine.cam.ops import Op
from coastline_engine.cam.toolpath import Toolpath

RES = Path(__file__).resolve().parents[2] / "resources"
BALL = {"diameter": 3.175, "flute_length": 9.5, "kind": "ballEndMill"}
DATA = {"feed": 900, "plunge_feed": 300, "ramp_feed": 700, "stepdown": 0.3, "stepover": 0.3}


@pytest.fixture(scope="module")
def geo():
    p = import_part(RES / "samples/pendant.step")
    M = np.eye(4)
    M[2, 3] = -5.5
    return g.PartGeometry(p.mesh.vertices, p.mesh.indices, M)


def _run(geo, strategy, params=None, z_min=None):
    d = {"id": strategy, "kind": strategy, "tool": BALL, "data": DATA}
    if z_min is not None:
        d["z_min"] = z_min
    op = Op(d)
    tp = Toolpath()
    S3.finish(op, geo, [-20, -30, -7], [20, 30, 0], tp, strategy, params or {})
    a = tp.array()
    return op, a, a[a[:, 0] == 1]


@pytest.mark.parametrize("strategy", ["parallel", "spiral", "scallop"])
def test_finishing_never_gouges_and_covers_the_dome(geo, strategy):
    op, rows, cut = _run(geo, strategy)
    assert len(cut) > 300
    surf = S3.Surface(geo, S3.cutter_for("ballEndMill", 3.175, 0, 9.5), geo.zmin)
    true = surf.drop(cut[:, 2:4].astype(float))
    # Cutter-location heights come from the exact drop-cutter: never below the surface.
    assert np.all(cut[:, 4] >= true - 2e-3)
    # It reaches the top of the dome and the rim.
    assert cut[:, 4].max() > geo.zmax - 0.3
    xy = cut[:, 2:4]
    assert np.hypot(xy[:, 0], xy[:, 1]).max() > 14.5
    # Nothing traced on the floor around the part.
    assert cut[:, 4].min() > geo.zmin + 0.01


def test_waterline_steps_down_the_walls(geo):
    _, _, cut = _run(geo, "waterline")
    levels = np.unique(np.round(cut[:, 4], 2))
    assert len(levels) >= 8


def test_depth_window_is_respected(geo):
    _, _, cut = _run(geo, "parallel", z_min=-2.0)
    assert cut[:, 4].min() >= -2.0 - 1e-4


def test_scallop_stepover_from_cusp_height():
    s = S3.scallop_stepover("ballEndMill", 3.175, 0.008)
    assert abs(s - 2 * np.sqrt(2 * 1.5875 * 0.008 - 0.008**2)) < 1e-12


def test_holder_clearance_needs_more_stickout_when_cutting_deep(geo):
    _, rows, cut = _run(geo, "parallel")
    band, _ = g.outer_and_holes(g.offset(geo.shadow(geo.zmin), 3.175 + 1.0))
    need = S3.min_stickout(geo, rows, 0.0, band)
    # The frame around the band is still at the face (z 0): the nut must clear it from the
    # deepest cut, plus 1 mm.
    deepest = -float(cut[:, 4].min())
    assert deepest + 0.9 < need < deepest + 1.6


def test_waterline_survives_an_opencamlib_crash(geo, monkeypatch):
    """OpenCAMLib can segfault in its waterline weave: the level runs in a worker, so the
    engine survives, does that level from the drop-cutter field, and keeps every other level."""
    _, _, cut = _run(geo, "waterline")
    good = np.unique(np.round(cut[:, 4], 2))
    z = float(geo.zmax - 0.02)  # the first level
    monkeypatch.setenv("COASTLINE_WL_CRASH_Z", repr(z))
    _, _, cut2 = _run(geo, "waterline")
    levels = np.unique(np.round(cut2[:, 4], 2))
    assert len(levels) >= 8 and levels.min() <= good.min() + 0.05, levels
    assert np.isclose(levels, z, atol=0.011).any(), "the crashed level is still cut"


def test_field_waterline_matches_opencamlib(geo):
    """The fallback contour lies on OpenCAMLib's own to a few µm (bisection on the drop cutter)."""
    import opencamlib as ocl
    cutter = S3.cutter_for("ballEndMill", 3.175, 1.5875, 9.5)
    surf = S3.Surface(geo, cutter, geo.zmin, ("ballEndMill", 3.175, 1.5875, 9.5))
    z = -2.0
    wl = ocl.AdaptiveWaterline()
    wl.setSTL(surf.stl)
    wl.setCutter(cutter)
    wl.setZ(z)
    wl.setSampling(0.1)
    wl.setMinSampling(0.0125)
    wl.run2()
    loops = [np.array([[p.x, p.y] for p in lp]) for lp in wl.getLoops()]
    ref = np.vstack(loops)
    grid = S3.CLGrid(surf, ref.min(0) - 3, ref.max(0) + 3, 0.15)
    mine = np.vstack([pts for pts, _ in S3.field_waterline(surf, grid, z)])[:, :2]
    # Never inside the part: the tool at z on every point stays clear (within 2 µm).
    assert (surf.drop(mine) - z <= 0.002).all()
    a = np.vstack([l for l in loops]); b = np.vstack([np.roll(l, -1, 0) for l in loops])  # OCL's polyline segments

    def seg_dist(q):
        d = b - a
        t = np.clip(((q - a) * d).sum(1) / np.maximum((d * d).sum(1), 1e-12), 0, 1)
        return np.hypot(*(a + d * t[:, None] - q).T).min()

    d = np.array([seg_dist(q) for q in mine[::5]])
    assert np.percentile(d, 95) < 0.02 and d.max() < 0.08, (np.percentile(d, 95), d.max())


def test_engraving_follows_the_dome_at_its_depth(geo):
    """Text on a domed face: every cutting point is the set depth below where the tool touches."""
    d = {"id": "e", "kind": "engrave", "tool": {"diameter": 0.5, "flute_length": 1.5, "kind": "flatEndMill"},
         "data": {"feed": 300, "plunge_feed": 100, "ramp_feed": 200, "stepdown": 0.1, "stepover": 0.1}}
    op = Op(d)
    tp = Toolpath()
    square = [[-4, -4], [-4, 4], [4, 4], [4, -4], [-4, -4]]
    S3.engrave(op, geo, tp, [square], 0.2)
    a = tp.array()
    cut = a[a[:, 0] == 1]
    assert len(cut) > 50
    cutter = S3.cutter_for("flatEndMill", 0.5, 0, 1.5)
    surf = S3.Surface(geo, cutter, geo.zmin - 1)
    deepest = cut[cut[:, 4] < cut[:, 4].max() - 0.05] if False else cut
    top = surf.drop(deepest[:, 2:4].astype(float))
    gap = top - deepest[:, 4]
    # Two passes (0.1 + 0.2): every point is 0.1 or 0.2 mm below the surface, never deeper.
    assert gap.max() < 0.2 + 1e-3 and gap.min() > 0.1 - 1e-3, (gap.min(), gap.max())
    # On a dome the text isn't flat: it follows the surface.
    assert cut[:, 4].max() - cut[:, 4].min() > 0.2
