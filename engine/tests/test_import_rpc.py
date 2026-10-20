import io
from pathlib import Path

import numpy as np
import pytest

from coastline_engine.cad_import import import_part
from coastline_engine.rpc import read_frame, write_frame, serve
from coastline_engine.server import HANDLERS

RES = Path(__file__).resolve().parents[2] / "resources"


def test_step_import_is_exact_and_in_mm():
    part = import_part(RES / "fixtures/universal_clamp_v96.step")
    assert part.exact and part.face_count > 10
    lo, hi = part.bounds
    size = sorted(h - l for l, h in zip(lo, hi))
    # The CR-1 universal clamp is roughly 19 x 59 x 81 mm.
    assert size == pytest.approx([19.1, 59.1, 80.6], abs=0.5)
    assert part.mesh.indices.max() < len(part.mesh.vertices)


def test_3dm_import_converts_inches_to_mm():
    part = import_part(RES / "samples/end_mill_quarter_inch.3dm")
    lo, hi = part.mesh.bounds
    size = sorted(h - l for l, h in zip(lo, hi))
    # A 1/4" x 2.5" cylinder modelled in inches.
    assert size[0] == pytest.approx(6.35, abs=0.05)
    assert size[2] == pytest.approx(63.5, abs=0.1)
    assert part.exact  # Rhino Breps are rebuilt as exact OCCT solids


def test_unsupported_extension():
    with pytest.raises(Exception, match="Unsupported"):
        import_part("x.obj")


def _roundtrip(requests):
    inp = io.BytesIO()
    for r in requests:
        write_frame(inp, r)
    inp.seek(0)
    out = io.BytesIO()
    serve(HANDLERS, inp, out)
    out.seek(0)
    frames = []
    while (f := read_frame(out)) is not None:
        frames.append(f)
    return frames


def test_rpc_import_returns_mesh_blobs_and_errors_dont_kill_server():
    frames = _roundtrip([
        {"id": 1, "method": "import_part", "params": {"path": str(RES / "fixtures/universal_clamp_v96.step")}},
        {"id": 2, "method": "nope"},
        {"id": 3, "method": "ping"},
    ])
    (h1, b1), (h2, _), (h3, _) = frames
    assert h1["id"] == 1 and h1["result"]["exact"]
    verts = np.frombuffer(b1[0], "<f4").reshape(-1, 3)
    tris = np.frombuffer(b1[2], "<u4").reshape(-1, 3)
    assert len(verts) == h1["result"]["vertex_count"] and len(tris) == h1["result"]["triangle_count"]
    assert "error" in h2 and h2["id"] == 2
    assert h3["result"]["engine"] == "0.1.0"
