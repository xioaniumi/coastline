"""Exact machining features from the B-rep (in the work frame): holes along the tool axis
and flat up-facing floors."""

from __future__ import annotations

import math

import numpy as np
from OCP.BRep import BRep_Tool
from OCP.BRepAdaptor import BRepAdaptor_Surface
from OCP.BRepBuilderAPI import BRepBuilderAPI_Transform
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.BRepBndLib import BRepBndLib
from OCP.Bnd import Bnd_Box
from OCP.GeomAbs import GeomAbs_Cylinder, GeomAbs_Plane
from OCP.GeomAdaptor import GeomAdaptor_Surface
from OCP.GeomConvert import GeomConvert_SurfToAnaSurf
from OCP.TopAbs import TopAbs_FACE, TopAbs_REVERSED
from OCP.TopExp import TopExp_Explorer
from OCP.TopLoc import TopLoc_Location
from OCP.TopoDS import TopoDS
from OCP.gp import gp_Trsf

from . import geometry as g


def transformed(shape, m: np.ndarray):
    t = gp_Trsf()
    t.SetValues(*[float(m[r, c]) for r in range(3) for c in range(4)])
    return BRepBuilderAPI_Transform(shape, t, True).Shape()


def _analytic(face):
    surf = BRepAdaptor_Surface(face)
    t = surf.GetType()
    if t in (GeomAbs_Plane, GeomAbs_Cylinder):
        return surf, t
    conv = GeomConvert_SurfToAnaSurf(BRep_Tool.Surface_s(face))
    a = conv.ConvertToAnalytical(1e-4)
    if a is not None:
        s = GeomAdaptor_Surface(a)
        return s, s.GetType()
    return surf, t


def _bounds(face):
    b = Bnd_Box()
    BRepBndLib.AddOptimal_s(face, b, False, False)
    lo, hi = b.CornerMin(), b.CornerMax()
    return np.array([lo.X(), lo.Y(), lo.Z()]), np.array([hi.X(), hi.Y(), hi.Z()])


def find_features(shape_work, part_zmin: float) -> dict:
    holes: dict = {}
    angles: dict = {}   # key → angles (deg) of the face's mesh points around the axis
    floors = []
    BRepMesh_IncrementalMesh(shape_work, 0.01, False, 0.2, True)
    exp = TopExp_Explorer(shape_work, TopAbs_FACE)
    while exp.More():
        face = TopoDS.Face(exp.Current())
        exp.Next()
        surf, t = _analytic(face)
        lo, hi = _bounds(face)
        reversed_ = face.Orientation() == TopAbs_REVERSED
        if t == GeomAbs_Cylinder:
            cyl = surf.Cylinder()
            ax = cyl.Axis().Direction()
            if abs(ax.Z()) < 0.999:
                continue
            loc = cyl.Location()
            # A hole if the face normal points toward the axis (concave).
            u = (surf.FirstUParameter() + surf.LastUParameter()) / 2
            v = (surf.FirstVParameter() + surf.LastVParameter()) / 2
            p = surf.Value(u, v)
            radial = np.array([p.X() - loc.X(), p.Y() - loc.Y()])
            # The cylinder's natural normal points outward; a REVERSED face points inward.
            if not reversed_:
                continue
            key = (round(loc.X(), 3), round(loc.Y(), 3), round(cyl.Radius(), 3))
            h = holes.setdefault(key, {"x": loc.X(), "y": loc.Y(), "diameter": 2 * cyl.Radius(),
                                       "z_top": hi[2], "z_bottom": lo[2]})
            h["z_top"] = max(h["z_top"], hi[2])
            h["z_bottom"] = min(h["z_bottom"], lo[2])
            angles.setdefault(key, []).extend(_angles_around(face, loc.X(), loc.Y()))
        elif t == GeomAbs_Plane:
            n = surf.Plane().Axis().Direction()
            nz = -n.Z() if reversed_ else n.Z()
            if nz > 0.999 and hi[2] - lo[2] < 1e-4:
                poly = _face_polygon(face)
                if poly:
                    floors.append({"z": float(hi[2]), "paths": poly, "area": sum(abs(_area(p)) for p in poly)})
    # A hole goes (nearly) all the way round. Concave arcs that don't (inside corner fillets,
    # the curved walls of a pocket) aren't holes: boring them would cut the part.
    hole_list = [h for k, h in holes.items() if _coverage(angles.get(k, [])) >= 300.0]
    for h in hole_list:
        # Plain Python types: numpy scalars aren't JSON serialisable.
        for k in ("x", "y", "diameter", "z_top", "z_bottom"):
            h[k] = float(h[k])
        h["through"] = bool(h["z_bottom"] <= part_zmin + 1e-3)
    return {"holes": hole_list, "floors": floors}


def _angles_around(face, cx: float, cy: float) -> list:
    loc = TopLoc_Location()
    tri = BRep_Tool.Triangulation_s(face, loc)
    if tri is None:
        return []
    trsf = loc.Transformation()
    out = []
    for i in range(1, tri.NbNodes() + 1):
        q = tri.Node(i).Transformed(trsf)
        out.append(math.degrees(math.atan2(q.Y() - cy, q.X() - cx)))
    return out


def _coverage(angles: list) -> float:
    """How far round the axis the points reach, degrees (360 minus the widest gap)."""
    if len(angles) < 3:
        return 0.0
    a = sorted(x % 360.0 for x in angles)
    gaps = [b - c for c, b in zip(a, a[1:])] + [a[0] + 360.0 - a[-1]]
    return 360.0 - max(gaps)


def _face_polygon(face) -> list:
    loc = TopLoc_Location()
    tri = BRep_Tool.Triangulation_s(face, loc)
    if tri is None:
        return []
    trsf = loc.Transformation()
    pts = []
    for i in range(1, tri.NbNodes() + 1):
        p = tri.Node(i).Transformed(trsf)
        pts.append((p.X(), p.Y()))
    import pyclipper
    pc = pyclipper.Pyclipper()
    for i in range(1, tri.NbTriangles() + 1):
        a, b, c = tri.Triangle(i).Get()
        t = [pts[a - 1], pts[b - 1], pts[c - 1]]
        if abs(_area(t)) > 1e-12:
            pc.AddPath(g.to_int(t), pyclipper.PT_SUBJECT, True)
    try:
        return pc.Execute(pyclipper.CT_UNION, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)
    except pyclipper.ClipperException:
        return []


def _area(p) -> float:
    p = np.asarray(p, float)
    return 0.5 * float(np.sum(p[:, 0] * np.roll(p[:, 1], -1) - np.roll(p[:, 0], -1) * p[:, 1]))
