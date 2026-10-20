"""CAD import: STEP / IGES (exact B-rep via OpenCASCADE) and Rhino .3dm.

Everything inside the engine is in millimetres. Imported geometry is scaled
to mm on load, so the rest of the engine never has to think about units.

.3dm: Rhino Breps are rebuilt as exact OCCT solids (rhino_exact.py). If nothing in the
file converts, Rhino's cached render meshes are shown instead (display only).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from OCP.BRep import BRep_Tool
from OCP.BRepBndLib import BRepBndLib
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.Bnd import Bnd_Box
from OCP.IFSelect import IFSelect_RetDone
from OCP.IGESControl import IGESControl_Reader
from OCP.STEPControl import STEPControl_Reader
from OCP.TopAbs import TopAbs_FACE, TopAbs_REVERSED
from OCP.TopExp import TopExp_Explorer
from OCP.TopLoc import TopLoc_Location
from OCP.TopoDS import TopoDS, TopoDS_Shape


class ImportError_(Exception):
    """Raised when a CAD file can't be read."""


@dataclass
class Mesh:
    """An indexed triangle mesh in millimetres.

    vertices: (N, 3) float32, normals: (N, 3) float32, indices: (M, 3) uint32.
    """

    vertices: np.ndarray
    normals: np.ndarray
    indices: np.ndarray

    @property
    def bounds(self) -> tuple[list[float], list[float]]:
        if len(self.vertices) == 0:
            return [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]
        return self.vertices.min(0).tolist(), self.vertices.max(0).tolist()

    @staticmethod
    def concat(meshes: list["Mesh"]) -> "Mesh":
        meshes = [m for m in meshes if len(m.indices)]
        if not meshes:
            empty = np.zeros((0, 3), np.float32)
            return Mesh(empty, empty.copy(), np.zeros((0, 3), np.uint32))
        offset, idx = 0, []
        for m in meshes:
            idx.append(m.indices + offset)
            offset += len(m.vertices)
        return Mesh(
            np.concatenate([m.vertices for m in meshes]).astype(np.float32),
            np.concatenate([m.normals for m in meshes]).astype(np.float32),
            np.concatenate(idx).astype(np.uint32),
        )


@dataclass
class ImportedPart:
    path: str
    kind: str  # "step" | "iges" | "3dm"
    mesh: Mesh
    shape: TopoDS_Shape | None  # exact B-rep when available (STEP/IGES)
    face_count: int
    exact: bool  # True when `shape` is an exact B-rep usable for machining
    warnings: list[str] = field(default_factory=list)

    @property
    def bounds(self):
        if self.shape is not None:
            return shape_bounds(self.shape)
        return self.mesh.bounds


# ---------------------------------------------------------------- STEP / IGES


def load_step(path: str | Path) -> TopoDS_Shape:
    """Reads a STEP file. OCCT converts the file's units to mm by default."""
    reader = STEPControl_Reader()
    if reader.ReadFile(str(path)) != IFSelect_RetDone:
        raise ImportError_(f"Couldn't read STEP file: {path}")
    reader.TransferRoots()
    shape = reader.OneShape()
    if shape.IsNull():
        raise ImportError_(f"STEP file has no geometry: {path}")
    return shape


def load_iges(path: str | Path) -> TopoDS_Shape:
    reader = IGESControl_Reader()
    if reader.ReadFile(str(path)) != IFSelect_RetDone:
        raise ImportError_(f"Couldn't read IGES file: {path}")
    reader.TransferRoots()
    shape = reader.OneShape()
    if shape.IsNull():
        raise ImportError_(f"IGES file has no geometry: {path}")
    return shape


def shape_bounds(shape: TopoDS_Shape) -> tuple[list[float], list[float]]:
    box = Bnd_Box()
    # Optimal = tight bounds from the exact geometry. The quick Add() uses NURBS control
    # polygons, which can be many mm too big on freeform surfaces.
    BRepBndLib.AddOptimal_s(shape, box, False, False)
    # OCCT 7.9 changed Bnd_Box.Get() to return a struct OCP can't convert,
    # so read the corners instead.
    lo, hi = box.CornerMin(), box.CornerMax()
    return [lo.X(), lo.Y(), lo.Z()], [hi.X(), hi.Y(), hi.Z()]


def tessellate(
    shape: TopoDS_Shape, linear_deflection: float = 0.01, angular_deflection: float = 0.2
) -> tuple[Mesh, int]:
    """Triangulates a B-rep. Deflections are in mm / radians.

    0.01 mm linear deflection is fine enough for jewellery display; CAM uses
    the exact B-rep or its own (finer) tessellation.
    Returns the mesh and the face count.
    """
    BRepMesh_IncrementalMesh(shape, linear_deflection, False, angular_deflection, True)
    parts: list[Mesh] = []
    faces = 0
    exp = TopExp_Explorer(shape, TopAbs_FACE)
    while exp.More():
        face = TopoDS.Face(exp.Current())
        faces += 1
        loc = TopLoc_Location()
        tri = BRep_Tool.Triangulation_s(face, loc)
        if tri is not None:
            trsf = loc.Transformation()
            n = tri.NbNodes()
            v = np.empty((n, 3), np.float32)
            for i in range(1, n + 1):
                p = tri.Node(i).Transformed(trsf)
                v[i - 1] = (p.X(), p.Y(), p.Z())
            t = np.empty((tri.NbTriangles(), 3), np.uint32)
            for i in range(1, tri.NbTriangles() + 1):
                a, b, c = tri.Triangle(i).Get()
                t[i - 1] = (a - 1, b - 1, c - 1)
            if face.Orientation() == TopAbs_REVERSED:
                t = t[:, [0, 2, 1]]
            parts.append(Mesh(v, vertex_normals(v, t), t))
        exp.Next()
    return Mesh.concat(parts), faces


def vertex_normals(v: np.ndarray, t: np.ndarray) -> np.ndarray:
    """Area-weighted vertex normals."""
    n = np.zeros_like(v)
    if len(t) == 0:
        return n
    fn = np.cross(v[t[:, 1]] - v[t[:, 0]], v[t[:, 2]] - v[t[:, 0]])
    for k in range(3):
        np.add.at(n, t[:, k], fn)
    length = np.linalg.norm(n, axis=1, keepdims=True)
    length[length == 0] = 1
    return (n / length).astype(np.float32)


# ---------------------------------------------------------------- Rhino .3dm

_RHINO_TO_MM = {
    "Millimeters": 1.0,
    "Centimeters": 10.0,
    "Meters": 1000.0,
    "Inches": 25.4,
    "Feet": 304.8,
    "Microns": 0.001,
}


def load_3dm_mesh(path: str | Path) -> tuple[Mesh, int]:
    """Reads Rhino's cached render meshes from Breps, Extrusions and Meshes."""
    import rhino3dm

    f = rhino3dm.File3dm.Read(str(path))
    if f is None:
        raise ImportError_(f"Couldn't read Rhino file: {path}")
    unit = str(f.Settings.ModelUnitSystem).split(".")[-1]
    scale = _RHINO_TO_MM.get(unit)
    if scale is None:
        raise ImportError_(f"Unsupported Rhino unit system: {unit}")

    meshes: list[rhino3dm.Mesh] = []
    faces = 0
    for obj in f.Objects:
        g = obj.Geometry
        if isinstance(g, rhino3dm.Brep):
            for i in range(len(g.Faces)):
                faces += 1
                m = g.Faces[i].GetMesh(rhino3dm.MeshType.Any)
                if m is not None:
                    meshes.append(m)
        elif isinstance(g, rhino3dm.Extrusion):
            faces += 1
            m = g.GetMesh(rhino3dm.MeshType.Any)
            if m is not None:
                meshes.append(m)
        elif isinstance(g, rhino3dm.Mesh):
            meshes.append(g)

    parts = []
    for m in meshes:
        v = np.array([[p.X, p.Y, p.Z] for p in m.Vertices], np.float32) * scale
        tris = []
        for i in range(len(m.Faces)):
            a, b, c, d = m.Faces[i]
            tris.append((a, b, c))
            if c != d:  # quad
                tris.append((a, c, d))
        t = np.array(tris, np.uint32).reshape(-1, 3)
        parts.append(Mesh(v, vertex_normals(v, t), t))
    if not parts:
        raise ImportError_(
            "The Rhino file has no render meshes. Re-save it in Rhino with "
            "shaded view on (or export STEP), then import again."
        )
    return Mesh.concat(parts), faces


# ---------------------------------------------------------------- entry point


def import_part(path: str | Path, linear_deflection: float = 0.01) -> ImportedPart:
    p = Path(path)
    ext = p.suffix.lower()
    if ext in (".step", ".stp"):
        shape = load_step(p)
        mesh, faces = tessellate(shape, linear_deflection)
        return ImportedPart(str(p), "step", mesh, shape, faces, True)
    if ext in (".iges", ".igs"):
        shape = load_iges(p)
        mesh, faces = tessellate(shape, linear_deflection)
        return ImportedPart(str(p), "iges", mesh, shape, faces, True)
    if ext == ".3dm":
        # Exact NURBS first; fall back to Rhino's render meshes if nothing converts.
        import rhino3dm

        from .rhino_exact import load_3dm_exact

        f = rhino3dm.File3dm.Read(str(p))
        if f is None:
            raise ImportError_(f"Couldn't read Rhino file: {p}")
        unit = str(f.Settings.ModelUnitSystem).split(".")[-1]
        scale = _RHINO_TO_MM.get(unit)
        if scale is None:
            raise ImportError_(f"Unsupported Rhino unit system: {unit}")
        shape, converted, _, invalid = load_3dm_exact(p, scale)
        if converted:
            mesh, faces = tessellate(shape, linear_deflection)
            part = ImportedPart(str(p), "3dm", mesh, shape, faces, True)
            part.warnings = ([f"{invalid} object(s) have small geometry defects. If machining them looks wrong, "
                              "export STEP from Rhino."] if invalid else [])
            return part
        mesh, faces = load_3dm_mesh(p)
        part = ImportedPart(str(p), "3dm", mesh, None, faces, False)
        part.warnings = ["No exact surfaces could be read, so this shows Rhino's render mesh. Export STEP for machining."]
        return part
    raise ImportError_(f"Unsupported file type: {ext} (use STEP, IGES or 3DM)")
