"""Part analysis in the work frame (tool from +Z): what limits machining this part on the CR-1.

- smallest inside corner radius around the tool axis (vertical concave cylinders and fillets)
  → the largest end mill that can finish every inside corner;
- smallest concave radius of curvature on freeform faces → the largest ball mill for 3D finishing;
- undercuts: faces turned away from the spindle (other than the part's bottom), which a 3-axis
  machine can't reach from this side;
- thin walls: features thinner than a threshold in any slice (morphological opening);
- depth along the tool axis.
"""

from __future__ import annotations

import numpy as np
import pyclipper
from OCP.BRep import BRep_Tool
from OCP.BRepGProp import BRepGProp
from OCP.BRepLProp import BRepLProp_SLProps
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.BRepAdaptor import BRepAdaptor_Surface
from OCP.GeomAbs import GeomAbs_Cylinder, GeomAbs_Plane
from OCP.GProp import GProp_GProps
from OCP.TopAbs import TopAbs_FACE, TopAbs_REVERSED
from OCP.TopExp import TopExp_Explorer
from OCP.TopLoc import TopLoc_Location
from OCP.TopoDS import TopoDS

from . import geometry as g
from .features import _analytic


def _samples(face, n=6):
    """Sample points inside the trimmed face (UV bounds of the trim, then a point-in-face test),
    not over the whole untrimmed surface (a dome is only a cap of its sphere)."""
    from OCP.BRepClass import BRepClass_FaceClassifier
    from OCP.BRepTools import BRepTools
    from OCP.TopAbs import TopAbs_IN, TopAbs_ON
    from OCP.gp import gp_Pnt2d

    surf = BRepAdaptor_Surface(face)
    u0, u1, v0, v1 = BRepTools.UVBounds_s(face)
    for i in range(n):
        for j in range(n):
            u = u0 + (u1 - u0) * (i + 0.5) / n
            v = v0 + (v1 - v0) * (j + 0.5) / n
            state = BRepClass_FaceClassifier(face, gp_Pnt2d(u, v), 1e-6).State()
            if state in (TopAbs_IN, TopAbs_ON):
                yield surf, u, v


def _face_triangles(face) -> np.ndarray:
    loc = TopLoc_Location()
    tri = BRep_Tool.Triangulation_s(face, loc)
    if tri is None:
        return np.zeros((0, 3, 3), np.float32)
    trsf = loc.Transformation()
    pts = np.array([[p.X(), p.Y(), p.Z()] for p in (tri.Node(i).Transformed(trsf) for i in range(1, tri.NbNodes() + 1))])
    idx = np.array([tri.Triangle(i).Get() for i in range(1, tri.NbTriangles() + 1)]) - 1
    if face.Orientation() == TopAbs_REVERSED:
        idx = idx[:, [0, 2, 1]]
    return pts[idx].astype(np.float32)


def analyse(shape_work, geo: g.PartGeometry, thin_threshold: float = 0.8) -> dict:
    BRepMesh_IncrementalMesh(shape_work, 0.02, False, 0.3, True)
    corner_radii, concave_radii = [], []
    undercut_area = 0.0
    # Faces 2.5D operations can't finish: anything but planes square to the tool axis and
    # cylinders along it (domes, fillets, chamfers, freeform NURBS).
    freeform_area = 0.0
    # Area by what finishes it: flat floors (planes square to the tool), walls (along the tool
    # axis), and freeform area that is steep (> 45°) — waterline territory.
    flat_area = 0.0
    wall_area = 0.0
    steep_area = 0.0
    undercut_tris = []
    zmin = geo.zmin
    exp = TopExp_Explorer(shape_work, TopAbs_FACE)
    while exp.More():
        face = TopoDS.Face(exp.Current())
        exp.Next()
        reversed_ = face.Orientation() == TopAbs_REVERSED
        sign = -1.0 if reversed_ else 1.0
        surf, kind = _analytic(face)
        props = GProp_GProps()
        BRepGProp.SurfaceProperties_s(face, props)
        area = props.Mass()

        is_free = False
        if kind == GeomAbs_Plane:
            nz = abs(surf.Plane().Axis().Direction().Z())
            if 0.001 < nz < 0.999:
                is_free = True
            elif nz >= 0.999:
                flat_area += area
            else:
                wall_area += area
        elif kind == GeomAbs_Cylinder:
            if abs(surf.Cylinder().Axis().Direction().Z()) < 0.999:
                is_free = True
            else:
                wall_area += area
        else:
            is_free = True
        if is_free:
            freeform_area += area

        # Inside corners around the tool axis: concave (REVERSED) cylinders parallel to Z.
        if kind == GeomAbs_Cylinder:
            ax = surf.Cylinder().Axis().Direction()
            if abs(ax.Z()) > 0.999 and reversed_:
                corner_radii.append(surf.Cylinder().Radius())

        # Sample normals (undercuts) and curvature (concave freeform radius).
        down = False
        steep_samples = [0, 0]
        for s, u, v in _samples(face):
            p = BRepLProp_SLProps(s, u, v, 2, 1e-6)
            if not p.IsNormalDefined():
                continue
            n = p.Normal()
            nz = sign * n.Z()
            pt = s.Value(u, v)
            if nz < -0.05 and pt.Z() > zmin + 0.02:
                down = True
            if is_free and nz > 0:
                steep_samples[0] += 1
                if nz < 0.7071:  # steeper than 45°
                    steep_samples[1] += 1
            if kind not in (GeomAbs_Plane, GeomAbs_Cylinder) and p.IsCurvatureDefined():
                # OCCT signs curvature against the surface normal: with the normal turned to
                # face out of the material, positive means concave (a pocket a ball mill must
                # fit into). Verified on a spherical dimple (concave) and a dome (convex).
                for k in (p.MinCurvature(), p.MaxCurvature()):
                    kk = sign * k
                    if kk > 1e-6:
                        concave_radii.append(1.0 / kk)
        if steep_samples[0]:
            steep_area += area * steep_samples[1] / steep_samples[0]
        if down:
            undercut_area += area
            undercut_tris.append(_face_triangles(face))

    # Thin walls: an opening (shrink then grow by t/2) removes features thinner than t.
    def thin_loss(paths, t):
        opened = g.offset(g.offset(paths, -t / 2), t / 2)
        return sum(pyclipper.Area(p) for p in paths) - sum(pyclipper.Area(p) for p in opened)

    thinnest = None
    for z in np.linspace(geo.zmin + 0.05, geo.zmax - 0.05, 6):
        region = geo.region(float(z))
        if not region:
            continue
        if thin_loss(region, thin_threshold) / g.SCALE**2 > 0.05:
            lo, hi = 0.05, thin_threshold
            for _ in range(10):
                mid = (lo + hi) / 2
                if thin_loss(region, mid) / g.SCALE**2 > 0.05:
                    hi = mid
                else:
                    lo = mid
            thinnest = hi if thinnest is None else min(thinnest, hi)

    # Parting level: where the cross-section is largest. A two-sided job splits here.
    parting, best_area = geo.zmin, -1.0
    for z in np.linspace(geo.zmin + 0.02, geo.zmax - 0.02, 24):
        a = sum(pyclipper.Area(p) for p in geo.region(float(z))) / g.SCALE**2
        if a > best_area + 1e-6:
            parting, best_area = float(z), a

    # Volume, and how round the silhouette is (1 = a disc: spiral finishing suits it).
    vprops = GProp_GProps()
    BRepGProp.VolumeProperties_s(shape_work, vprops)
    volume = abs(vprops.Mass())
    sil = geo.shadow(geo.zmin)
    circularity = 0.0
    if sil:
        pts = np.vstack([g.to_mm(p) for p in sil])
        c = pts.mean(0)
        rmax = float(np.max(np.linalg.norm(pts - c, axis=1)))
        area = sum(pyclipper.Area(p) for p in sil) / g.SCALE**2
        circularity = float(area / (np.pi * rmax * rmax)) if rmax > 0 else 0.0

    tris = np.concatenate(undercut_tris) if undercut_tris else np.zeros((0, 3, 3), np.float32)
    return {
        "min_corner_radius": float(min(corner_radii)) if corner_radii else None,
        "min_concave_radius": float(min(concave_radii)) if concave_radii else None,
        "undercut_area": float(undercut_area),
        "thinnest_wall": float(thinnest) if thinnest is not None else None,
        "depth": float(geo.zmax - geo.zmin),
        "parting_z": float(parting),
        "freeform_area": float(freeform_area),
        "flat_area": float(flat_area),
        "wall_area": float(wall_area),
        "steep_area": float(steep_area),
        "volume": float(volume),
        "circularity": circularity,
        "zmax": float(geo.zmax),
        "undercut_triangles": tris,
    }


def freeform_footprint(shape_work, z_min: float | None = None) -> list:
    """Where 3D finishing has work, seen from above: the XY footprint (pyclipper paths) of the
    faces 2.5D operations can't finish (anything but floors square to the tool and walls along
    it). Flat floors and vertical walls belong to the floor and contour passes. `z_min`: only
    faces reaching above it (the side's depth window)."""
    BRepMesh_IncrementalMesh(shape_work, 0.05, False, 0.5, True)
    polys = []
    exp = TopExp_Explorer(shape_work, TopAbs_FACE)
    while exp.More():
        face = TopoDS.Face(exp.Current())
        exp.Next()
        surf, kind = _analytic(face)
        if kind == GeomAbs_Plane:
            nz = abs(surf.Plane().Axis().Direction().Z())
            if not (0.001 < nz < 0.999):
                continue
        elif kind == GeomAbs_Cylinder and abs(surf.Cylinder().Axis().Direction().Z()) >= 0.999:
            continue
        tris = _face_triangles(face)
        if not len(tris):
            continue
        if z_min is not None:
            tris = tris[tris[:, :, 2].max(axis=1) > z_min]
        for t in tris:
            p = g.to_int(t[:, :2].astype(float))
            if abs(pyclipper.Area(p)) > 0:
                polys.append(p if pyclipper.Orientation(p) else p[::-1])
    if not polys:
        return []
    pc = pyclipper.Pyclipper()
    pc.AddPaths(polys, pyclipper.PT_SUBJECT, True)
    return pc.Execute(pyclipper.CT_UNION, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)
