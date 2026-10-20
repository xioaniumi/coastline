"""Exact Rhino .3dm import: rebuilds Rhino Breps as OpenCASCADE solids.

rhino3dm exposes each face's NURBS surface, its trim loops, and the 3D NURBS curve of every
edge, but not the 2D trim curves. So for every face we:
  1. convert the surface to Geom_BSplineSurface (homogeneous control points → weights),
  2. build its loops as wires from the 3D edge curves (respecting trim direction),
  3. let ShapeFix compute the 2D pcurves by projecting the edges onto the surface,
then sew all faces of a Brep into a shell and, when closed, a solid.

The geometry stays exact NURBS, so machining tolerances are not limited by a render mesh.
Extrusions are converted with Rhino's own ToBrep first.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import rhino3dm

from OCP.BRep import BRep_Builder
from OCP.BRepBuilderAPI import (
    BRepBuilderAPI_MakeEdge,
    BRepBuilderAPI_MakeFace,
    BRepBuilderAPI_MakeSolid,
    BRepBuilderAPI_MakeWire,
    BRepBuilderAPI_Sewing,
    BRepBuilderAPI_Transform,
)
from OCP.Geom import Geom_BSplineCurve, Geom_BSplineSurface
from OCP.ShapeFix import ShapeFix_Face, ShapeFix_Shape
# OCP 8 exposes NCollection arrays as OCP.collections.Array{1,2}_<type>.
from OCP.collections import Array1_double as TColStd_Array1OfReal
from OCP.collections import Array1_gp_Pnt as TColgp_Array1OfPnt
from OCP.collections import Array1_int as TColStd_Array1OfInteger
from OCP.collections import Array2_double as TColStd_Array2OfReal
from OCP.collections import Array2_gp_Pnt as TColgp_Array2OfPnt
from OCP.TopAbs import TopAbs_SHELL
from OCP.TopExp import TopExp_Explorer
from OCP.TopoDS import TopoDS, TopoDS_Compound, TopoDS_Shape
from OCP.gp import gp_Pnt, gp_Trsf

TOLERANCE = 0.001  # model units; Rhino's default absolute tolerance


def _knots(rhino_knots, scale_count: int) -> tuple[TColStd_Array1OfReal, TColStd_Array1OfInteger]:
    """Rhino stores n+p-1 knots (no superfluous end knots). OCCT wants distinct knots with
    multiplicities summing to n+p+1, so the first and last knots are repeated once more."""
    flat = [rhino_knots[i] for i in range(len(rhino_knots))]
    flat = [flat[0]] + flat + [flat[-1]]
    values, mults = [], []
    for k in flat:
        if values and abs(k - values[-1]) <= 1e-12 * max(1.0, abs(k)):
            mults[-1] += 1
        else:
            values.append(k)
            mults.append(1)
    kv = TColStd_Array1OfReal(1, len(values))
    km = TColStd_Array1OfInteger(1, len(mults))
    for i, (v, m) in enumerate(zip(values, mults), 1):
        kv.SetValue(i, v)
        km.SetValue(i, m)
    return kv, km


def _surface(s: rhino3dm.NurbsSurface) -> Geom_BSplineSurface:
    nu, nv = s.Points.CountU, s.Points.CountV
    poles = TColgp_Array2OfPnt(1, nu, 1, nv)
    weights = TColStd_Array2OfReal(1, nu, 1, nv)
    for i in range(nu):
        for j in range(nv):
            p = s.Points[i, j]  # homogeneous (x·w, y·w, z·w, w)
            w = p.W if p.W != 0 else 1.0
            poles.SetValue(i + 1, j + 1, gp_Pnt(p.X / w, p.Y / w, p.Z / w))
            weights.SetValue(i + 1, j + 1, w)
    ku, mu = _knots(s.KnotsU, nu)
    kv, mv = _knots(s.KnotsV, nv)
    return Geom_BSplineSurface(poles, weights, ku, kv, mu, mv, s.Degree(0), s.Degree(1))


def _curve(c: rhino3dm.NurbsCurve) -> Geom_BSplineCurve:
    n = len(c.Points)
    poles = TColgp_Array1OfPnt(1, n)
    weights = TColStd_Array1OfReal(1, n)
    for i in range(n):
        p = c.Points[i]
        w = p.W if p.W != 0 else 1.0
        poles.SetValue(i + 1, gp_Pnt(p.X / w, p.Y / w, p.Z / w))
        weights.SetValue(i + 1, w)
    k, m = _knots(c.Knots, n)
    return Geom_BSplineCurve(poles, weights, k, m, c.Degree)


def _brep_to_shape(brep: rhino3dm.Brep) -> TopoDS_Shape | None:
    edges = []
    for i in range(len(brep.Edges)):
        nc = brep.Edges[i].ToNurbsCurve()
        edges.append(BRepBuilderAPI_MakeEdge(_curve(nc)).Edge() if nc is not None else None)

    sewing = BRepBuilderAPI_Sewing(TOLERANCE * 10)
    faces_added = 0
    for fi in range(len(brep.Faces)):
        face = brep.Faces[fi]
        surface = _surface(face.ToNurbsSurface())
        wires = []
        for li in range(len(face.Loops)):
            loop = face.Loops[li]
            mw = BRepBuilderAPI_MakeWire()
            for ti in range(loop.TrimCount):
                trim = loop.Trims[ti]
                ei = trim.EdgeIndex
                if ei < 0 or edges[ei] is None:  # singular trim (pole of a sphere/cone)
                    continue
                e = edges[ei]
                mw.Add(TopoDS.Edge(e.Reversed()) if trim.IsReversed else e)
            if mw.IsDone():
                outer = loop.LoopType == rhino3dm.BrepLoopType.Outer
                wires.insert(0, mw.Wire()) if outer else wires.append(mw.Wire())
        if wires:
            mf = BRepBuilderAPI_MakeFace(surface, wires[0], True)
            for w in wires[1:]:
                mf.Add(w)
        else:
            mf = BRepBuilderAPI_MakeFace(surface, TOLERANCE)
        if not mf.IsDone():
            continue
        fix = ShapeFix_Face(mf.Face())
        fix.SetPrecision(TOLERANCE)
        fix.Perform()  # computes pcurves, fixes wire order/orientation
        f = fix.Face()
        if face.OrientationIsReversed:
            f = TopoDS.Face(f.Reversed())
        sewing.Add(f)
        faces_added += 1
    if faces_added == 0:
        return None
    sewing.Perform()
    sewn = sewing.SewedShape()
    # Closed shell → solid, so volumes and "inside" tests work for CAM.
    exp = TopExp_Explorer(sewn, TopAbs_SHELL)
    if brep.IsSolid and exp.More():
        ms = BRepBuilderAPI_MakeSolid()
        while exp.More():
            ms.Add(TopoDS.Shell(exp.Current()))
            exp.Next()
        if ms.IsDone():
            sewn = ms.Solid()
    fixer = ShapeFix_Shape(sewn)
    fixer.Perform()
    return fixer.Shape()


def load_3dm_exact(path: str | Path, unit_scale: float) -> tuple[TopoDS_Shape, int, int, int]:
    """Returns (compound in mm, objects converted, objects skipped, converted-but-invalid)."""
    from OCP.BRepCheck import BRepCheck_Analyzer
    f = rhino3dm.File3dm.Read(str(path))
    builder = BRep_Builder()
    compound = TopoDS_Compound()
    builder.MakeCompound(compound)
    converted = skipped = invalid = 0
    for obj in f.Objects:
        g = obj.Geometry
        if isinstance(g, rhino3dm.Extrusion):
            g = g.ToBrep(True)
        if not isinstance(g, rhino3dm.Brep):
            continue  # meshes, curves, annotations aren't solids to machine
        try:
            shape = _brep_to_shape(g)
        except Exception:
            shape = None
        if shape is None or shape.IsNull():
            skipped += 1
            continue
        if not BRepCheck_Analyzer(shape).IsValid():
            invalid += 1  # still usable for display; CAM will warn and suggest a STEP export
        builder.Add(compound, shape)
        converted += 1
    if unit_scale != 1.0:
        t = gp_Trsf()
        t.SetScaleFactor(unit_scale)
        compound = BRepBuilderAPI_Transform(compound, t, True).Shape()
    return compound, converted, skipped, invalid
