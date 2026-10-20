import io
import math
from pathlib import Path

import pytest

from coastline_engine.cad_import import import_part
from coastline_engine.measure import face_info
from coastline_engine.rpc import read_frame, serve, write_frame
from coastline_engine.server import HANDLERS

RES = Path(__file__).resolve().parents[2] / "resources"


def test_3dm_is_now_exact_with_tight_bounds():
    part = import_part(RES / "samples/end_mill_quarter_inch.3dm")
    assert part.exact and part.shape is not None
    lo, hi = part.bounds
    size = sorted(h - l for l, h in zip(lo, hi))
    assert size == pytest.approx([6.35, 6.35, 63.5], abs=0.01)
    assert not part.warnings


def test_face_info_finds_the_end_mill_shank_cylinder():
    part = import_part(RES / "samples/end_mill_quarter_inch.3dm")
    lo, hi = part.bounds
    # A point just outside the shank, halfway along the tool (tool axis is Y in this file).
    cx, cz = (lo[0] + hi[0]) / 2, (lo[2] + hi[2]) / 2
    info = face_info(part.shape, (cx + 5, (lo[1] + hi[1]) / 2, cz))
    assert info["type"] in ("cylinder", "freeform")
    if info["type"] == "cylinder":
        assert info["radius"] == pytest.approx(3.175, abs=0.01)


def test_face_info_on_clamp_planes():
    part = import_part(RES / "fixtures/universal_clamp_v96.step")
    lo, hi = part.bounds
    info = face_info(part.shape, (lo[0] - 1, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2))
    assert info["type"] in ("plane", "cylinder")
    assert info["distance"] < 5


def test_machine_model_groups_and_axes(tmp_path):
    from coastline_engine.machine_model import load_machine

    parts = load_machine(RES / "machine/cr1_mechanicals_v1.3.step", tmp_path)
    groups = {p.group for p in parts}
    assert groups == {"static", "x", "y", "z"}
    assert any(p.role == "enclosure" for p in parts)
    total = sum(len(p.mesh.indices) for p in parts)
    assert 200_000 < total < 1_500_000
    # Cached second load returns the same meshes.
    again = load_machine(RES / "machine/cr1_mechanicals_v1.3.step", tmp_path)
    assert sum(len(p.mesh.indices) for p in again) == total


def test_rpc_import_returns_part_id_and_face_info():
    inp = io.BytesIO()
    write_frame(inp, {"id": 1, "method": "import_part", "params": {"path": str(RES / "fixtures/universal_clamp_v96.step")}})
    inp.seek(0)
    out = io.BytesIO()
    serve(HANDLERS, inp, out)
    out.seek(0)
    h, _ = read_frame(out)
    pid = h["result"]["part_id"]
    lo = h["result"]["bounds_min"]
    inp = io.BytesIO()
    write_frame(inp, {"id": 2, "method": "face_info", "params": {"part_id": pid, "point": [lo[0] - 1, lo[1] + 5, lo[2] + 5]}})
    inp.seek(0)
    out = io.BytesIO()
    serve(HANDLERS, inp, out)
    out.seek(0)
    h2, _ = read_frame(out)
    assert h2["result"]["type"] != "none"
