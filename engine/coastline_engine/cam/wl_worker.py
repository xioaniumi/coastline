"""Waterline levels in a separate process.

OpenCAMLib's waterline weave (`SmartWeave::add_vertex`) can segfault on some geometry, which
would take the whole engine (and the generation) down with it. The engine runs the levels
here instead: one pickled job on stdin, one pickled result per level on stdout as soon as it's
done, so if a level crashes the parent knows which one and carries on without it.
"""

from __future__ import annotations

import os
import pickle
import signal
import sys

import numpy as np
import opencamlib as ocl


def cutter_for(kind: str, d: float, corner_r: float, length: float):
    if kind == "ballEndMill":
        return ocl.BallCutter(d, length)
    if kind == "bullNoseEndMill" and corner_r > 1e-3:
        return ocl.BullCutter(d, min(corner_r, d / 2 - 1e-3), length)
    return ocl.CylCutter(d, length)


def main() -> None:
    from ..watchdog import exit_with_parent
    exit_with_parent()
    job = pickle.load(sys.stdin.buffer)
    v, t = job["vertices"], job["faces"]
    stl = ocl.STLSurf()
    for a, b, c in t:
        stl.addTriangle(ocl.Triangle(ocl.Point(*v[a]), ocl.Point(*v[b]), ocl.Point(*v[c])))
    cutter = cutter_for(*job["cutter"])
    out = sys.stdout.buffer
    crash_at = os.environ.get("COASTLINE_WL_CRASH_Z")  # tests: crash like OpenCAMLib does
    for z in job["zs"]:
        if crash_at is not None and abs(z - float(crash_at)) < 1e-6:
            os.kill(os.getpid(), signal.SIGSEGV)
        wl = ocl.AdaptiveWaterline()
        wl.setSTL(stl)
        wl.setCutter(cutter)
        wl.setZ(float(z))
        wl.setSampling(float(job["sampling"]))
        wl.setMinSampling(float(job["sampling"] / 8))
        wl.run2()
        loops = [np.array([[p.x, p.y, p.z] for p in lp]) for lp in wl.getLoops()]
        pickle.dump((z, loops), out)
        out.flush()


if __name__ == "__main__":
    main()
