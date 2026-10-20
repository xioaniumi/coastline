"""JSON-RPC over stdio with binary attachments.

Frame layout (both directions):
    u32 big-endian  length of the JSON header
    JSON header     {"id", "method"/"result"/"error", "params", "blobs": [len, ...]}
    blobs           raw bytes, concatenated, lengths listed in "blobs"

Binary blobs carry meshes and toolpaths (float32/uint32 arrays, little
endian), so millions of points don't go through JSON.

Requests:  {"id": 1, "method": "import_part", "params": {...}, "blobs": []}
Responses: {"id": 1, "result": {...}, "blobs": [n1, n2]}
       or  {"id": 1, "error": {"message": "...", "type": "..."}, "blobs": []}

The engine logs to stderr only; stdout is reserved for frames.
"""

from __future__ import annotations

import json
import struct
import sys
import traceback
from typing import BinaryIO, Callable

Handler = Callable[[dict, list[bytes]], tuple[dict, list[bytes]]]


def read_frame(stream: BinaryIO) -> tuple[dict, list[bytes]] | None:
    raw = stream.read(4)
    if len(raw) < 4:
        return None
    (n,) = struct.unpack(">I", raw)
    header = json.loads(stream.read(n))
    blobs = [stream.read(k) for k in header.get("blobs", [])]
    return header, blobs


def write_frame(stream: BinaryIO, header: dict, blobs: list[bytes] = ()) -> None:
    header = dict(header, blobs=[len(b) for b in blobs])
    data = json.dumps(header, separators=(",", ":")).encode()
    stream.write(struct.pack(">I", len(data)))
    stream.write(data)
    for b in blobs:
        stream.write(b)
    stream.flush()


def serve(handlers: dict[str, Handler], stdin: BinaryIO = None, stdout: BinaryIO = None) -> None:
    stdin = stdin or sys.stdin.buffer
    stdout = stdout or sys.stdout.buffer
    while True:
        frame = read_frame(stdin)
        if frame is None:
            return
        header, blobs = frame
        rid = header.get("id")
        method = header.get("method")
        try:
            if method not in handlers:
                raise KeyError(f"Unknown method: {method}")
            result, out = handlers[method](header.get("params") or {}, blobs)
            write_frame(stdout, {"id": rid, "result": result}, out)
        except Exception as e:  # report every failure to the app; never die
            traceback.print_exc(file=sys.stderr)
            write_frame(stdout, {"id": rid, "error": {"message": str(e), "type": type(e).__name__}})
