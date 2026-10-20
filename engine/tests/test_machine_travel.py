"""The travel calibration's collision sweep, on a synthetic slide: a carriage on a rod between
two stops."""

import numpy as np

from coastline_engine.machine_travel import PITCH, Voxels, free_travel


def _box(lo, hi):
    g = np.mgrid[lo[0]:hi[0]:PITCH, lo[1]:hi[1]:PITCH, lo[2]:hi[2]:PITCH].reshape(3, -1).T
    return np.unique(np.floor(g / PITCH).astype(np.int64), axis=0)


def test_carriage_slides_until_it_meets_a_stop_but_ignores_its_own_rod():
    rod = Voxels("static", "rod", _box((0, -100, 0), (4, 100, 4)))          # along y
    carriage = Voxels("y", "carriage", _box((-3, -10, -3), (7, 10, 7)))     # around the rod
    stop_r = Voxels("static", "right stop", _box((-5, 40, -5), (9, 45, 9)))
    stop_l = Voxels("static", "left stop", _box((-5, -75, -5), (9, -70, 9)))
    parts = [rod, carriage, stop_r, stop_l]
    right, a, b = free_travel(parts, "y", +1)
    left, _, c = free_travel(parts, "y", -1)
    assert abs(right - 30) <= PITCH and (a, b) == ("carriage", "right stop")
    assert abs(left - 60) <= PITCH and c == "left stop"
