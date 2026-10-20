"""Coastline's example parts, modelled in OpenCASCADE: `cd engine && uv run python ../scripts/support/make_examples.py`.

Writes resources/examples/*.step. Each part shows a different way of holding the stock on the
CR-1 and has real engineering details (fits, countersinks, counterbores, jewel sinks, slots),
all millable with the tools Coastline knows. Units: mm. The face to machine points +Z; the
part's own origin is unimportant (Coastline places it in the stock).

1. Watch bridge      brass, tiny: one universal clamp, micro end mills, 2.5D detail.
2. Signet pendant    aluminium, domed: two sides (back hollowed), holding tabs, 3D finishing.
3. Pocket rule       aluminium, long and shallow: the whole job flat on the bed, a 0–95 mm scale.
4. Motor mount       NEMA 17 plate taller than the clamp kit grips: shoulders at the bar's ends.
"""
import math
import sys
from pathlib import Path

from OCP.BRepAlgoAPI import BRepAlgoAPI_Cut, BRepAlgoAPI_Fuse, BRepAlgoAPI_Common
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakeWire
from OCP.BRepFilletAPI import BRepFilletAPI_MakeChamfer, BRepFilletAPI_MakeFillet
from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCone, BRepPrimAPI_MakeCylinder, BRepPrimAPI_MakePrism, BRepPrimAPI_MakeSphere
from OCP.BRepCheck import BRepCheck_Analyzer
from OCP.BRepGProp import BRepGProp
from OCP.GC import GC_MakeArcOfCircle, GC_MakeSegment
from OCP.GProp import GProp_GProps
from OCP.IFSelect import IFSelect_RetDone
from OCP.Interface import Interface_Static
from OCP.STEPControl import STEPControl_AsIs, STEPControl_Writer
from OCP.ShapeUpgrade import ShapeUpgrade_UnifySameDomain
from OCP.TopAbs import TopAbs_EDGE
from OCP.TopExp import TopExp_Explorer
from OCP.TopoDS import TopoDS, TopoDS_Shape
from OCP.BRepAdaptor import BRepAdaptor_Curve
from OCP.GeomAbs import GeomAbs_Line, GeomAbs_Circle
from OCP.gp import gp_Ax2, gp_Dir, gp_Elips, gp_Pnt, gp_Vec

OUT = Path(__file__).resolve().parents[2] / "resources" / "examples"


# --- Building blocks -----------------------------------------------------------------------

def box(x0, y0, z0, x1, y1, z1) -> TopoDS_Shape:
    return BRepPrimAPI_MakeBox(gp_Pnt(x0, y0, z0), gp_Pnt(x1, y1, z1)).Shape()


def cyl(x, y, z0, h, r) -> TopoDS_Shape:
    """A cylinder along Z from z0 up h."""
    return BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(x, y, z0), gp_Dir(0, 0, 1)), r, h).Shape()


def countersink(x, y, top, d_top, d_hole, angle=90.0) -> TopoDS_Shape:
    """A cone opening upward to d_top at z = top, down to the hole's diameter."""
    depth = (d_top - d_hole) / 2 / math.tan(math.radians(angle / 2))
    return BRepPrimAPI_MakeCone(gp_Ax2(gp_Pnt(x, y, top - depth), gp_Dir(0, 0, 1)), d_hole / 2, d_top / 2, depth + 0.01).Shape()


def prism(wire, z0, h) -> TopoDS_Shape:
    face = BRepBuilderAPI_MakeFace(wire).Face()
    from OCP.gp import gp_Trsf
    from OCP.BRepBuilderAPI import BRepBuilderAPI_Transform
    t = gp_Trsf()
    t.SetTranslation(gp_Vec(0, 0, z0))
    face = TopoDS.Face(BRepBuilderAPI_Transform(face, t).Shape())
    return BRepPrimAPI_MakePrism(face, gp_Vec(0, 0, h)).Shape()


def rounded_rect(cx, cy, w, h, r):
    """A rectangle w × h centred on (cx, cy), corners rounded to r (r = h/2: a slot)."""
    r = min(r, w / 2, h / 2)
    x0, x1, y0, y1 = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
    mk = BRepBuilderAPI_MakeWire()

    def seg(a, b):
        if (abs(a[0] - b[0]) + abs(a[1] - b[1])) > 1e-9:
            mk.Add(BRepBuilderAPI_MakeEdge(GC_MakeSegment(gp_Pnt(*a, 0), gp_Pnt(*b, 0)).Value()).Edge())

    def arc(c, a0):
        p = lambda a: gp_Pnt(c[0] + r * math.cos(a), c[1] + r * math.sin(a), 0)
        mk.Add(BRepBuilderAPI_MakeEdge(GC_MakeArcOfCircle(p(a0), p(a0 + math.pi / 4), p(a0 + math.pi / 2)).Value()).Edge())

    seg((x0 + r, y0), (x1 - r, y0)); arc((x1 - r, y0 + r), -math.pi / 2)
    seg((x1, y0 + r), (x1, y1 - r)); arc((x1 - r, y1 - r), 0)
    seg((x1 - r, y1), (x0 + r, y1)); arc((x0 + r, y1 - r), math.pi / 2)
    seg((x0, y1 - r), (x0, y0 + r)); arc((x0 + r, y0 + r), math.pi)
    return mk.Wire()


def ellipse(cx, cy, a, b):
    """An ellipse with semi-axes a (X) and b (Y)."""
    ax = gp_Ax2(gp_Pnt(cx, cy, 0), gp_Dir(0, 0, 1), gp_Dir(1, 0, 0) if a >= b else gp_Dir(0, 1, 0))
    e = gp_Elips(ax, max(a, b), min(a, b))
    return BRepBuilderAPI_MakeWire(BRepBuilderAPI_MakeEdge(e).Edge()).Wire()


def fuse(*shapes):
    s = shapes[0]
    for t in shapes[1:]:
        s = BRepAlgoAPI_Fuse(s, t).Shape()
    return s


def cut(s, *tools):
    for t in tools:
        s = BRepAlgoAPI_Cut(s, t).Shape()
    return s


def clean(s):
    u = ShapeUpgrade_UnifySameDomain(s, True, True, True)
    u.Build()
    return u.Shape()


def edges(s):
    ex = TopExp_Explorer(s, TopAbs_EDGE)
    while ex.More():
        yield TopoDS.Edge(ex.Current())
        ex.Next()


def vertical_lines(s, z0, z1, tol=1e-6):
    """Straight edges running in Z from z0 to z1 (the outline's sharp corners)."""
    out = []
    for e in edges(s):
        c = BRepAdaptor_Curve(e)
        if c.GetType() != GeomAbs_Line:
            continue
        a, b = c.Value(c.FirstParameter()), c.Value(c.LastParameter())
        if abs(a.X() - b.X()) < tol and abs(a.Y() - b.Y()) < tol and {round(a.Z(), 4), round(b.Z(), 4)} == {round(z0, 4), round(z1, 4)}:
            out.append(e)
    return out


def fillet(s, es, r):
    mk = BRepFilletAPI_MakeFillet(s)
    for e in es:
        mk.Add(r, e)
    mk.Build()
    if not mk.IsDone():
        raise RuntimeError("fillet failed")
    return mk.Shape()


def edges_at_z(s, z, tol=1e-6, kinds=(GeomAbs_Line, GeomAbs_Circle), within=None):
    """Edges lying in the plane Z = z (an outline at that height)."""
    out = []
    for e in edges(s):
        c = BRepAdaptor_Curve(e)
        if c.GetType() not in kinds:
            continue
        pts = [c.Value(c.FirstParameter() + (c.LastParameter() - c.FirstParameter()) * k / 4) for k in range(5)]
        if all(abs(p.Z() - z) < tol for p in pts) and (within is None or all(within(p.X(), p.Y()) for p in pts)):
            out.append(e)
    return out


def chamfer(s, es, d):
    mk = BRepFilletAPI_MakeChamfer(s)
    for e in es:
        mk.Add(d, e)
    mk.Build()
    if not mk.IsDone():
        raise RuntimeError("chamfer failed")
    return mk.Shape()


def write_step(shape, name):
    if not BRepCheck_Analyzer(shape).IsValid():
        raise RuntimeError(f"{name}: invalid solid")
    OUT.mkdir(parents=True, exist_ok=True)
    w = STEPControl_Writer()
    Interface_Static.SetCVal_s("write.step.unit", "MM")
    Interface_Static.SetCVal_s("write.step.product.name", name)
    w.Transfer(shape, STEPControl_AsIs)
    path = OUT / f"{name}.step"
    if w.Write(str(path)) != IFSelect_RetDone:
        raise RuntimeError(f"couldn't write {path}")
    props = GProp_GProps()
    BRepGProp.VolumeProperties_s(shape, props)
    print(f"{path.name}: {props.Mass():.1f} mm³")


# --- 1. Watch bridge ---------------------------------------------------------------------------

def watch_bridge():
    """A two-jewel bridge for a small movement, 2.5 mm brass. Two lobes joined by an arm; each
    lobe carries a jewel hole (Ø1.0 through, 90° oil sink to Ø1.9), a screw seat (Ø1.3 through,
    counterbore Ø2.4 × 0.8) and a steady pin hole (Ø0.8). A decorative relief slot (0.3 deep) runs
    along the arm; R0.6 inside corners where the arm meets the lobes (a 1 mm end mill fits)."""
    t = 2.5
    a, b = (-10.0, 0.0), (10.5, 0.5)
    body = fuse(cyl(*a, 0, t, 6.5), cyl(*b, 0, t, 5.5),
                prism(rounded_rect(0, 0.2, 21, 7, 0.01), 0, t))
    body = clean(body)
    body = fillet(body, vertical_lines(body, 0, t), 0.6)
    holes = [
        cyl(*a, -1, t + 2, 0.5), countersink(*a, t, 1.9, 1.0),               # jewel A
        cyl(*b, -1, t + 2, 0.5), countersink(*b, t, 1.9, 1.0),               # jewel B
        cyl(-12.6, -3.0, -1, t + 2, 0.65), cyl(-12.6, -3.0, t - 0.8, 1, 1.2),  # screw A
        cyl(12.6, 2.9, -1, t + 2, 0.65), cyl(12.6, 2.9, t - 0.8, 1, 1.2),      # screw B
        cyl(-7.2, -4.3, -1, t + 2, 0.4), cyl(8.0, -2.9, -1, t + 2, 0.4),       # steady pins
        prism(rounded_rect(0.3, 0.2, 7.5, 2.6, 1.3), t - 0.3, 1),              # relief slot
    ]
    return clean(cut(body, *holes))


# --- 2. Signet pendant -------------------------------------------------------------------------

def signet_pendant():
    """An oval signet pendant, 24 × 18 mm, 6 mm high: a domed front (R30 sphere) with a flat
    oval table for engraving, a bail lug with a Ø3 hole, and a hollow back (an oval pocket
    2.5 mm deep, 1.2 mm walls), so it's cut from both sides and held by tabs between them."""
    h = 6.0
    body = prism(ellipse(0, 0, 12, 9), 0, h + 1)
    dome = BRepPrimAPI_MakeSphere(gp_Pnt(0, 0, h - 30), 30).Shape()
    body = BRepAlgoAPI_Common(body, dome).Shape()
    body = cut(body, box(-20, -20, h - 0.5, 20, 20, h + 2))                 # the engraving table
    lug = fuse(cyl(0, 11.6, 0, 3.0, 3.4), box(-3.4, 7.0, 0, 3.4, 11.6, 3.0))
    body = clean(fuse(body, lug))
    body = cut(body, cyl(0, 11.6, -1, 6, 1.5))                               # bail hole
    body = cut(body, prism(ellipse(0, 0, 10.8, 7.8), -1, 3.5))               # hollow back, 2.5 deep
    return clean(body)


# --- 3. Pocket rule ---------------------------------------------------------------------------

def pocket_rule():
    """A 110 × 16 × 2.5 pocket rule with a 0–95 mm scale: tick slots every 5 mm (1.0 wide,
    0.3 deep, round-ended; 6 mm long at the centimetres, 3.5 mm between), a hanging hole
    (Ø4, 90° countersink to Ø5.6), a 0.3 mm recessed name field, R2 corners and 0.3 mm
    chamfers round the face. Long and shallow: cut into the edge of a bar lying flat on the bed."""
    t = 2.5
    body = prism(rounded_rect(0, 0, 110, 16, 2), 0, t)
    cuts = []
    for k in range(20):                                     # 0, 5, …, 95 mm
        x = -50 + 5 * k
        long = k % 2 == 0
        length = 6.0 if long else 3.5
        cuts.append(prism(rounded_rect(x, -8 + 1.0 + length / 2, 1.0, length, 0.5), t - 0.3, 1))
    cuts += [cyl(50.5, 2.5, -1, t + 2, 2.0), countersink(50.5, 2.5, t, 5.6, 4.0)]
    cuts.append(prism(rounded_rect(-5, 3.5, 40, 6, 1.5), t - 0.3, 1))       # name field
    body = clean(cut(body, *cuts))
    outline = edges_at_z(body, t, within=lambda x, y: abs(x) > 54.9 or abs(y) > 7.9 or (abs(x) > 52.9 and abs(y) > 5.9))
    return clean(chamfer(body, outline, 0.3))


# --- 4. NEMA 17 motor mount --------------------------------------------------------------------

def motor_mount():
    """A NEMA 17 stepper face plate, 72 × 46 × 8: Ø22.5 pilot bore for the motor's boss (0.5
    chamfer), four Ø3.4 holes on the 31 mm square with Ø6.5 × 3.5 counterbores (M3 caps sit
    flush), and two 3.4 × 10 tension slots in the ears. Too tall for the clamp kit as a 50 mm
    bar: the kit grips milled shoulders at the bar's ends."""
    t = 8.0
    body = prism(rounded_rect(0, 0, 72, 46, 5), 0, t)
    holes = [cyl(0, 0, -1, t + 2, 11.25)]
    for x in (-15.5, 15.5):
        for y in (-15.5, 15.5):
            holes += [cyl(x, y, -1, t + 2, 1.7), cyl(x, y, t - 3.5, 4, 3.25)]
    for x in (-30, 30):
        holes.append(prism(rounded_rect(x, 0, 3.4, 13.4, 1.7), -1, t + 2))     # 10 mm of travel
    body = clean(cut(body, *holes))
    bore = edges_at_z(body, t, kinds=(GeomAbs_Circle,), within=lambda x, y: math.hypot(x, y) < 11.4)
    return clean(chamfer(body, bore, 0.5))


# --- 5. First-cut test coupon ------------------------------------------------------------------

def first_cut():
    """The coupon for the first cut on the CR-1 (docs/FIRST_CUT.md), 34 × 24 × 6 with R3
    corners: every kind of operation once, each leaving something to measure with calipers.
    Facing (thickness), the outline (34 × 24), a 14 × 8 pocket 2.5 deep with R1.6 corners (a
    1/8" end mill fits), Ø4 and Ø6 through holes (bored with a 1/8" you have) and a 1.5 mm step along the
    front edge, 3.5 wide. Cut in machinable wax first, then POM, then aluminium."""
    t = 6.0
    body = prism(rounded_rect(0, 0, 34, 24, 3), 0, t)
    cuts = [
        prism(rounded_rect(-4, 3, 14, 8, 1.6), t - 2.5, 3),    # pocket
        cyl(11, 5, -1, t + 2, 2.0),                             # Ø4 through
        cyl(8, -3, -1, t + 2, 3.0),                             # Ø6 through
        box(-20, -15, t - 1.5, 20, -8.5, t + 1),                # the step along the front edge
    ]
    return clean(cut(body, *cuts))


if __name__ == "__main__":
    parts = {"watch_bridge": watch_bridge, "signet_pendant": signet_pendant,
             "pocket_rule": pocket_rule, "motor_mount": motor_mount, "first_cut": first_cut}
    for name, make in parts.items():
        if len(sys.argv) > 1 and name not in sys.argv[1:]:
            continue
        write_step(make(), name)
