"""part analysis on parts with known answers."""

from pathlib import Path

import numpy as np
import pytest
from OCP.BRepAlgoAPI import BRepAlgoAPI_Cut
from OCP.BRepFilletAPI import BRepFilletAPI_MakeFillet
from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox
from OCP.TopAbs import TopAbs_EDGE
from OCP.TopExp import TopExp_Explorer
from OCP.TopoDS import TopoDS
from OCP.BRepAdaptor import BRepAdaptor_Curve
from OCP.gp import gp_Pnt

from coastline_engine.cad_import import Mesh, tessellate
from coastline_engine.cam import geometry as g
from coastline_engine.cam.analysis import analyse
from coastline_engine.cad_import import import_part

RES = Path(__file__).resolve().parents[2] / "resources"


def _test_block():
    """30×20×8 block: a 10×10×4 pocket with R1.5 vertical corners, a slot leaving a 0.5 mm wall,
    and a ledge cut into one side from below (an undercut from +Z)."""
    body = BRepPrimAPI_MakeBox(gp_Pnt(0, 0, 0), 30, 20, 8).Shape()
    pocket = BRepPrimAPI_MakeBox(gp_Pnt(4, 5, 4), 10, 10, 5).Shape()
    f = BRepFilletAPI_MakeFillet(pocket)
    e = TopExp_Explorer(pocket, TopAbs_EDGE)
    while e.More():
        ed = TopoDS.Edge(e.Current())
        c = BRepAdaptor_Curve(ed)
        a, b = c.Value(c.FirstParameter()), c.Value(c.LastParameter())
        if abs(a.X() - b.X()) < 1e-6 and abs(a.Y() - b.Y()) < 1e-6:  # vertical edge
            f.Add(1.5, ed)
        e.Next()
    body = BRepAlgoAPI_Cut(body, f.Shape()).Shape()
    slot = BRepPrimAPI_MakeBox(gp_Pnt(18, 2, 3), 2, 16, 6).Shape()  # leaves x 20..? wall to the next cut
    body = BRepAlgoAPI_Cut(body, slot).Shape()
    slot2 = BRepPrimAPI_MakeBox(gp_Pnt(20.5, 2, 3), 2, 16, 6).Shape()  # 0.5 mm wall between the slots
    body = BRepAlgoAPI_Cut(body, slot2).Shape()
    ledge = BRepPrimAPI_MakeBox(gp_Pnt(26, -1, 0), 5, 22, 3).Shape()  # cut from below: overhang above it
    return BRepAlgoAPI_Cut(body, ledge).Shape()


def test_block_analysis_finds_corners_thin_wall_and_undercut():
    shape = _test_block()
    mesh, _ = tessellate(shape, 0.01)
    geo = g.PartGeometry(mesh.vertices, mesh.indices, np.eye(4))
    r = analyse(shape, geo)
    assert r["min_corner_radius"] == pytest.approx(1.5, abs=1e-6)
    assert r["undercut_area"] == pytest.approx(5 * 20 + 0, rel=0.25)  # the ledge's ceiling (5 × 20 within the part)
    assert len(r["undercut_triangles"]) > 0
    assert r["thinnest_wall"] is not None and r["thinnest_wall"] == pytest.approx(0.5, abs=0.08)
    assert r["depth"] == pytest.approx(8, abs=1e-3)


def test_spherical_dimple_is_concave():
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeSphere

    body = BRepPrimAPI_MakeBox(gp_Pnt(-10, -10, -6), 20, 20, 6).Shape()
    dimple = BRepPrimAPI_MakeSphere(gp_Pnt(0, 0, 1.5), 3).Shape()  # cuts a 1.5 mm deep dish into the top
    shape = BRepAlgoAPI_Cut(body, dimple).Shape()
    mesh, _ = tessellate(shape, 0.01)
    r = analyse(shape, g.PartGeometry(mesh.vertices, mesh.indices, np.eye(4)))
    assert r["min_concave_radius"] == pytest.approx(3, abs=1e-3)
    assert r["undercut_area"] == 0


def test_pendant_bottom_fillet_is_an_undercut_and_the_dome_is_convex():
    part = import_part(RES / "samples/pendant.step")
    m = np.eye(4)
    m[2, 3] = -5.5
    from coastline_engine.cam.features import transformed

    geo = g.PartGeometry(part.mesh.vertices, part.mesh.indices, m)
    r = analyse(transformed(part.shape, m), geo)
    # The 0.8 mm fillet on the pendant's bottom edge faces away from the spindle: it can only
    # be cut from the back (a second setup). Its area is the torus band (~116 mm²).
    assert r["undercut_area"] == pytest.approx(116.1, abs=1)
    assert r["min_concave_radius"] is None, "the dome is convex"
    assert r["min_corner_radius"] == pytest.approx(1.2, abs=1e-6)  # the bail hole
    assert r["thinnest_wall"] is None


def test_depth_window_and_parting_level():
    from coastline_engine.server import PARTS, _generate

    part = import_part(RES / "samples/pendant.step")
    PARTS["dw"] = part
    m = np.eye(4)
    m[2, 3] = -5.5
    geo = g.PartGeometry(part.mesh.vertices, part.mesh.indices, m)
    from coastline_engine.cam.features import transformed

    r = analyse(transformed(part.shape, m), geo)
    # The pendant is widest at its 3 mm base, just above the bottom fillet.
    assert -5.5 < r["parting_z"] < -2.4
    op = {"id": "a", "kind": "adaptive", "tool": {"diameter": 6.35, "flute_length": 19, "kind": "flatEndMill"},
          "data": {"feed": 800, "plunge_feed": 280, "ramp_feed": 640, "stepdown": 1.5, "stepover": 0.5, "ramp_angle": 2},
          "leave_radial": 0.2, "leave_axial": 0.1, "z_min": -3.0}
    res, blobs = _generate({"part_id": "dw", "transform": m.flatten().tolist(), "stock_min": [-40, -75, -20],
                            "stock_max": [40, 75, 0], "safe_z": 3, "ops": [op]}, [])
    rows = np.frombuffer(blobs[0], "<f4").reshape(-1, 8)
    assert rows[rows[:, 0] != 0][:, 4].min() >= -3.0 - 1e-4, "never below the depth window"
