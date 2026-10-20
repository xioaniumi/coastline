"""Spike: OpenCAMLib drop-cutter on an imported STEP part (3D finishing base)."""

from pathlib import Path

import numpy as np
import opencamlib as ocl

from coastline_engine.cad_import import import_part

RES = Path(__file__).resolve().parents[2] / "resources"


def _stl_surf(mesh):
    s = ocl.STLSurf()
    v, t = mesh.vertices.astype(float), mesh.indices
    for a, b, c in t:
        s.addTriangle(ocl.Triangle(ocl.Point(*v[a]), ocl.Point(*v[b]), ocl.Point(*v[c])))
    return s


def test_ball_dropcutter_never_goes_below_the_part():
    part = import_part(RES / "fixtures/universal_clamp_v96.step", 0.05)
    surf = _stl_surf(part.mesh)
    (x0, y0, z0), (x1, y1, z1) = part.bounds
    cutter = ocl.BallCutter(3.175, 20)  # 1/8" ball
    bdc = ocl.BatchDropCutter()
    bdc.setSTL(surf)
    bdc.setCutter(cutter)
    for x in np.linspace(x0, x1, 25):
        for y in np.linspace(y0, y1, 25):
            bdc.appendPoint(ocl.CLPoint(float(x), float(y), float(z0 - 10)))
    bdc.run()
    pts = bdc.getCLPoints()
    zs = np.array([p.z for p in pts])
    assert len(zs) == 625
    # Cutter-location Z is the tool tip; it is never below the part's lowest point.
    assert zs.min() >= z0 - 10 - 1e-6
    assert zs.max() <= z1 + 1e-6
    assert (zs > z0 - 10 + 1e-3).sum() > 50  # it actually landed on the part
