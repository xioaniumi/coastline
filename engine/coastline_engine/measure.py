"""Exact measurements on an imported part: what surface is under the cursor."""

from __future__ import annotations

from OCP.BRep import BRep_Tool
from OCP.BRepAdaptor import BRepAdaptor_Surface
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeVertex
from OCP.BRepExtrema import BRepExtrema_DistShapeShape
from OCP.BRepLProp import BRepLProp_SLProps
from OCP.GeomAbs import GeomAbs_Cone, GeomAbs_Cylinder, GeomAbs_Plane, GeomAbs_Sphere, GeomAbs_Torus
from OCP.ShapeAnalysis import ShapeAnalysis_Surface
from OCP.GeomAdaptor import GeomAdaptor_Surface
from OCP.GeomConvert import GeomConvert_SurfToAnaSurf
from OCP.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_REVERSED, TopAbs_VERTEX
from OCP.TopExp import TopExp
from OCP.TopoDS import TopoDS, TopoDS_Shape
from OCP.collections import IndexedDataMap_TopoDS_Shape_List_TopoDS_Shape_TopTools_ShapeMapHasher as AncestorMap
from OCP.gp import gp_Pnt

# Rhino and many STEP exporters write planes and cylinders as NURBS. Recognising them as
# analytic surfaces within this tolerance gives exact radii and clean feature recognition.
ANALYTIC_TOLERANCE = 1e-4  # mm


_BOUNDARY_CACHE: dict[int, TopoDS_Shape] = {}


def _boundary(shape: TopoDS_Shape) -> TopoDS_Shape:
    """A compound of the shape's faces (cached per shape)."""
    from OCP.BRep import BRep_Builder
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopoDS import TopoDS_Compound

    key = shape.HashCode(2**31 - 1) if hasattr(shape, "HashCode") else id(shape)
    if key not in _BOUNDARY_CACHE:
        b = BRep_Builder()
        c = TopoDS_Compound()
        b.MakeCompound(c)
        e = TopExp_Explorer(shape, TopAbs_FACE)
        while e.More():
            b.Add(c, e.Current())
            e.Next()
        _BOUNDARY_CACHE[key] = c
    return _BOUNDARY_CACHE[key]


def face_info(shape: TopoDS_Shape, point: tuple[float, float, float]) -> dict:
    """Finds the face nearest `point` (part coordinates, mm) and describes it:
    plane → normal; cylinder/cone → radius and axis; sphere/torus → radii; freeform →
    smallest radius of curvature (useful: it limits the ball-mill size)."""
    vertex = BRepBuilderAPI_MakeVertex(gp_Pnt(*point)).Vertex()
    # Measure against the boundary, not the solid: clicked points come from the tessellated
    # mesh and can sit a hair inside the solid, where the distance to a solid is 0.
    shape = _boundary(shape)
    dist = BRepExtrema_DistShapeShape(vertex, shape)
    if not dist.IsDone() or dist.NbSolution() == 0:
        return {"type": "none"}
    best = None
    for i in range(1, dist.NbSolution() + 1):
        s = dist.SupportOnShape2(i)
        if s.ShapeType() == TopAbs_FACE:
            best = TopoDS.Face(s)
            break
    p = dist.PointOnShape2(1)
    if best is None:
        # The closest point is on an edge or vertex (e.g. a cylinder's seam): take the nearest
        # face that touches it.
        support = dist.SupportOnShape2(1)
        kind = TopAbs_EDGE if support.ShapeType() == TopAbs_EDGE else TopAbs_VERTEX
        ancestors = AncestorMap()
        TopExp.MapShapesAndAncestors_s(shape, kind, TopAbs_FACE, ancestors)
        faces = ancestors.FindFromKey(support) if ancestors.Contains(support) else []
        best_d = float("inf")
        for f in faces:
            d = BRepExtrema_DistShapeShape(vertex, f)
            if d.IsDone() and d.Value() < best_d:
                best_d, best = d.Value(), TopoDS.Face(f)
        if best is None:
            return {"type": "edge", "distance": dist.Value()}
    surf = BRepAdaptor_Surface(best)
    uv = ShapeAnalysis_Surface(BRep_Tool.Surface_s(best)).ValueOfUV(p, 1e-4)
    props = BRepLProp_SLProps(surf, uv.X(), uv.Y(), 2, 1e-6)
    out = {"distance": dist.Value(), "point": [p.X(), p.Y(), p.Z()]}
    if props.IsNormalDefined():
        n = props.Normal()
        sign = -1 if best.Orientation() == TopAbs_REVERSED else 1
        out["normal"] = [sign * n.X(), sign * n.Y(), sign * n.Z()]
    t = surf.GetType()
    recognised = False
    if t not in (GeomAbs_Plane, GeomAbs_Cylinder, GeomAbs_Cone, GeomAbs_Sphere, GeomAbs_Torus):
        conv = GeomConvert_SurfToAnaSurf(BRep_Tool.Surface_s(best))
        analytic = conv.ConvertToAnalytical(ANALYTIC_TOLERANCE)
        if analytic is not None:
            surf = GeomAdaptor_Surface(analytic)
            t = surf.GetType()
            recognised = True
    out["recognised_from_nurbs"] = recognised
    if t == GeomAbs_Plane:
        out["type"] = "plane"
    elif t == GeomAbs_Cylinder:
        c = surf.Cylinder()
        d = c.Axis().Direction()
        out.update(type="cylinder", radius=c.Radius(), axis=[d.X(), d.Y(), d.Z()])
    elif t == GeomAbs_Cone:
        c = surf.Cone()
        out.update(type="cone", radius=c.RefRadius(), half_angle_deg=abs(c.SemiAngle()) * 57.29577951308232)
    elif t == GeomAbs_Sphere:
        out.update(type="sphere", radius=surf.Sphere().Radius())
    elif t == GeomAbs_Torus:
        tor = surf.Torus()
        out.update(type="torus", major_radius=tor.MajorRadius(), minor_radius=tor.MinorRadius())
    else:
        out["type"] = "freeform"
        if props.IsCurvatureDefined():
            k = max(abs(props.MinCurvature()), abs(props.MaxCurvature()))
            if k > 1e-9:
                out["min_radius_of_curvature"] = 1 / k
    return out
