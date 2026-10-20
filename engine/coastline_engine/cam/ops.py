"""2.5D operations. Each returns a Toolpath in the work frame.

Conventions: climb milling with the CR-1's clockwise (M3) spindle: outside walls are cut
clockwise, pockets and holes counter-clockwise, so the material is always on the tool's right.
"""

from __future__ import annotations

import math

import os
import time

import numpy as np
import pyclipper

from . import geometry as g
from .toolpath import CUT, LEAD, LINK, PLUNGE, RAMP, Toolpath


class Op:
    """Operation parameters from the app (mm, mm/min)."""

    def __init__(self, d: dict):
        self.id = d["id"]
        self.kind = d["kind"]
        t = d["tool"]
        self.tool_d = float(t["diameter"])
        self.r = self.tool_d / 2
        self.flute = float(t.get("flute_length", self.tool_d * 2))
        self.tool_kind = t.get("kind", "flatEndMill")
        self.corner_r = float(t.get("corner_radius", 0) or 0)
        self.stickout = float(t.get("stickout", 0) or 0)
        # Above the flutes the shank (often wider than a small cutter: a 1/16" on a 1/8" shank)
        # mustn't go into the part.
        self.shank_d = float(t.get("shank_diameter") or self.tool_d)
        # 3D finishing parameters (cam/surface3d.py): scallop, angle, steep_angle, ref_tool…
        self.params = d.get("params", {}) or {}
        c = d["data"]
        self.feed = float(c["feed"])
        self.plunge = float(c["plunge_feed"])
        self.ramp = float(c["ramp_feed"])
        self.stepdown = max(float(c["stepdown"]), 0.01)
        self.stepover = max(float(c["stepover"]), 0.005)
        self.ramp_angle = float(c.get("ramp_angle", 2.0))
        self.leave_xy = float(d.get("leave_radial", 0))
        self.leave_z = float(d.get("leave_axial", 0))
        self.face_depth = float(d.get("face_depth", 0.3))
        self.spring = bool(d.get("spring_pass", False))
        # Depth window for two-sided parts: never cut below z_min (work frame).
        zm = d.get("z_min")
        self.z_min = float(zm) if zm is not None else -1e9
        # Cut through: down to z_min (within the stock box) even below the part's own bottom,
        # around its outline (a part at the back of the bar, freed on holding tabs).
        self.through = bool(d.get("through", False))
        # Where the material starts (work Z): below 0 once the face has been faced down.
        self.z_top = float(d.get("z_top", 0.0))
        # Roughing band around the part (mm; default one tool + 1 mm) and the uncut frame's top
        # (for the holder check) when it isn't z_top.
        self.band = float(d["band"]) if d.get("band") is not None else None
        # Roughing: pockets narrower than this many tool diameters are left to a smaller tool
        # (0: rough every pocket the tool fits); pockets_only: only the pockets, nothing outside.
        self.min_pocket = float(d.get("min_pocket", 1.6))  # tool diameters (Operation.defaultMinPocket)
        self.pockets_only = bool(d.get("pockets_only", False))
        # The widest the tool centre may travel (x, y), mm: the machine's reach.
        self.max_span = tuple(float(v) for v in d["max_span"]) if d.get("max_span") else None
        # 3D finishing in strips: only this stretch of work Y [y0, y1] (each strip its own job).
        self.tile = tuple(float(v) for v in d["tile"]) if d.get("tile") else None
        # Floor finishing: only floors narrower than this (the wider ones had a bigger tool).
        self.floor_max_width = float(d["floor_max_width"]) if d.get("floor_max_width") else None
        # Larger roughing tools before this one: [{diameter, min_pocket, leave}].
        self.rest_from = list(d.get("rest_from") or [])
        self.frame_top = float(d["frame_top"]) if d.get("frame_top") is not None else self.z_top
        # Links run through air the tool already cleared: brisk, it never touches the part.
        self.link_feed = min(max(self.feed * 1.5, 1500), 2000)
        # Where the clamps are (work XY rectangles): roughing keeps out of them below `below`.
        ko = d.get("keep_out") or {}
        self.keep_out = [g.rect(*r) for r in ko.get("rects", [])]
        self.keep_out_below = float(ko.get("below", -1e9))


def shank_bottom(op) -> float:
    """The deepest a 2.5D tool may cut (work Z): a shank wider than the cutter would cut the
    walls below the flutes, so it stops a flute length below the material top."""
    if op.shank_d > op.tool_d + 0.02:
        return op.z_top - op.flute
    return -float("inf")


def shank_warning(op, z: float) -> str:
    return (f"Stops at Z{z:.2f}, {op.flute:g} mm down: below its flutes the ⌀{op.shank_d:g} mm shank is wider "
            f"than the ⌀{op.tool_d:g} mm cutter and would cut the walls. A long-reach tool goes deeper.")


def levels(top: float, bottom: float, step: float, extra: list[float] = ()) -> list[float]:
    """Z levels from just below `top` down to `bottom` (inclusive), evenly spaced at most
    `step` apart, plus `extra` levels (floors) in range."""
    if bottom >= top:
        return []
    n = max(1, math.ceil((top - bottom) / step - 1e-9))
    even = {round(top - (top - bottom) * k / n, 6) for k in range(1, n + 1)}
    floors = {round(z, 6) for z in extra if bottom - 1e-9 <= z < top - 1e-6}
    # Floors win; an even level within 0.05 mm of one is the same cut (a second pass microns
    # deep makes the solver crawl).
    out: list[float] = []
    for z in sorted(floors, reverse=True):  # floors closer than 0.05 mm are one floor (the higher)
        if all(abs(z - f) >= 0.05 for f in out):
            out.append(z)
    for z in sorted(even):
        if all(abs(z - f) >= 0.05 for f in out):
            out.append(z)
    return sorted(out, reverse=True)


# ---------------------------------------------------------------- facing


def facing(op: Op, stock_min, stock_max, tp: Toolpath) -> Toolpath:
    """Zig-zag passes along Y (the long axis) across the whole stock face, starting and
    ending outside the stock so every pass enters from the side."""
    xmin, ymin, xmax, ymax = stock_min[0], stock_min[1], stock_max[0], stock_max[1]
    r = op.r
    xs = []
    x = xmin - r + op.stepover * 0.5
    while x - r < xmax:
        xs.append(x)
        x += op.stepover
    y0, y1 = ymin - r - 1.0, ymax + r + 1.0
    depth = min(op.face_depth, 30.0)
    # Facing to thickness: roughing passes (~1 mm with a 1/4" tool) down to the last 0.25 mm,
    # then one finishing pass at the facing stepdown.
    finish = min(op.stepdown, depth)
    rough_step = min(1.0, op.tool_d * 0.16)
    zs = []
    if depth - finish > 1e-6:
        n = max(1, math.ceil((depth - finish) / rough_step - 1e-9))
        zs = [-(depth - finish) * k / n for k in range(1, n + 1)]
    zs.append(-depth)
    for z in zs:
        tp.go_to(xs[0], y0, z, op.plunge, op.link_feed)
        forward = True
        for idx, x in enumerate(xs):
            if idx > 0:
                tp.line(x, y1 if not forward else y0, z, op.feed, LINK)
            tp.line(x, y1 if forward else y0, z, op.feed)
            forward = not forward
        tp.retract()
    return tp


# ---------------------------------------------------------------- adaptive


def _difference(subject, clip):
    pc = pyclipper.Pyclipper()
    pc.AddPaths(subject, pyclipper.PT_SUBJECT, True)
    pc.AddPaths(clip, pyclipper.PT_CLIP, True)
    return pc.Execute(pyclipper.CT_DIFFERENCE, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)


def _swept_by_earlier(hole, rest_from):
    """What larger roughing tools before this one cleared in a pocket (pyclipper paths), or
    None if none of them took it: the area their body swept, `leave` short of the walls."""
    swept = []
    for t in rest_from:
        d, mp, leave = float(t["diameter"]), float(t.get("min_pocket", 1.6)), float(t.get("leave", 0.0))
        if mp and not g.offset([hole], -mp * d / 2):
            continue  # too narrow: that tool skipped this pocket
        centres = g.offset([hole], -(d / 2 + leave))
        if centres:
            swept += g.offset(centres, d / 2 - 0.02)
    if not swept:
        return None
    pc = pyclipper.Pyclipper()
    pc.AddPaths(swept, pyclipper.PT_SUBJECT, True)
    return pc.Execute(pyclipper.CT_UNION, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)


def _reach_rect(paths, span, r, fallback):
    """`span` centred on the part (paths: pyclipper units), grown by `r` each side."""
    if paths:
        pts = np.vstack([g.to_mm(p) for p in paths])
        c = (pts.min(axis=0) + pts.max(axis=0)) / 2
    else:
        c = np.asarray(fallback, dtype=float)
    return (c[0] - span[0] / 2 - r, c[1] - span[1] / 2 - r, c[0] + span[0] / 2 + r, c[1] + span[1] / 2 + r)


def _clip_rect(rect_path, box):
    a = np.asarray(rect_path, dtype=float)
    lo = np.maximum(a.min(axis=0), box[:2])
    hi = np.minimum(a.max(axis=0), box[2:])
    return g.rect(lo[0], lo[1], hi[0], hi[1])


def adaptive(op: Op, part: g.PartGeometry, stock_min, stock_max, floor_levels, tp: Toolpath,
             z_top: float = 0.0) -> Toolpath:
    """Constant-engagement roughing (FreeCAD's Adaptive2d) level by level: outside the part's
    shadow within the stock, and inside pockets (holes in the shadow)."""
    from .. import _native as N

    bottom = max(stock_min[2], op.z_min) if op.through else max(part.zmin, stock_min[2], op.z_min) + op.leave_z
    if bottom < shank_bottom(op) - 0.01:
        bottom = shank_bottom(op)
        tp.warnings.append(shank_warning(op, bottom))
    # Containment: clear only a band around the part (its full outline grown by one tool
    # diameter + 1 mm), not the whole stock. Much faster, and the uncut stock around the band
    # stays as a rigid frame that holds the part (the jewellery "frame + tabs" approach).
    # Adaptive2d is told the stock is material but everything outside the band is already
    # cleared, so it can enter from there.
    # The band grows from the part alone: grown around the holding tabs too, it would reach
    # past their ends and leave them standing in the channel instead of joined to the frame.
    tabs_kept, part.tabs = part.tabs, None
    try:
        silhouette = part.shadow(max(part.zmin, stock_min[2]))
    finally:
        part.tabs = tabs_kept
    # The band is wide enough for real adaptive motion (1.6 diameters + 1 mm): a channel barely
    # wider than the tool can only be slotted.
    frame_wall = os.environ.get("COASTLINE_FRAME_WALL", "1") != "0"
    default_band = (1.6 * op.tool_d + 1.0) if frame_wall else (op.tool_d + 1.0)
    band = g.offset(silhouette, (op.band if op.band is not None else default_band) + op.leave_xy)
    band_outers, _ = g.outer_and_holes(band)
    # The solver's region reaches a tool diameter past the stock's edges: that's air (already
    # cleared), so a narrow strip of material along an open edge is cut from outside in normal
    # adaptive passes instead of being worked as a channel (thousands of trochoidal loops).
    # Where the outside isn't air (the clamp jaws), the keep-out below takes it away again.
    # Material is only the band *inside the real stock*: the band can poke past the stock's
    # edge, and counting that air as material makes the solver fight phantom islands.
    grow = float(os.environ.get("COASTLINE_GROW", op.tool_d + 1.0))
    stock_rect = g.rect(stock_min[0] - grow, stock_min[1] - grow, stock_max[0] + grow, stock_max[1] + grow)
    real = g.rect(stock_min[0], stock_min[1], stock_max[0], stock_max[1])
    full_real = real
    if op.max_span:
        # Out of reach: the tool centre stays within max_span, centred on the part. An open
        # edge is cut from outside, the centre a radius (+ ~0.3 mm the solver overshoots) past
        # the material, so the material is clipped that much inside the span. Only the material:
        # the air around it stays, or the solver crawls along the clipped edge as if it were a
        # wall (7× slower).
        reach = _reach_rect(silhouette, op.max_span, -(op.tool_d / 2 + 0.3),
                            ((stock_min[0] + stock_max[0]) / 2, (stock_min[1] + stock_max[1]) / 2))
        real = _clip_rect(real, reach)
    pc = pyclipper.Pyclipper()
    pc.AddPath(g.to_int(real), pyclipper.PT_SUBJECT, True)
    pc.AddPaths(band_outers, pyclipper.PT_CLIP, True)
    material = pc.Execute(pyclipper.CT_INTERSECTION, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)
    pc = pyclipper.Pyclipper()
    pc.AddPath(g.to_int(stock_rect), pyclipper.PT_SUBJECT, True)
    if frame_wall:
        # Only the air past the stock is already clear. The frame outside the band is solid at
        # every level below its top: it's a wall the solver keeps out of, like the part. (Told
        # it was clear, the solver entered and linked through it at depth: the channel came out
        # far wider than planned, slotting, and it cut holding tabs off from the frame.)
        pc.AddPath(g.to_int(full_real), pyclipper.PT_CLIP, True)
    else:
        pc.AddPaths(material, pyclipper.PT_CLIP, True)
    cleared = [g.to_mm(p).tolist() for p in pc.Execute(pyclipper.CT_DIFFERENCE, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)]
    # Pocket mode: where the tool may go is the band, within the machine's reach (the tool's
    # edge reaches a radius past its centre's window, so the wall is there).
    pocket_band = band_outers
    if frame_wall and op.max_span:
        box = _reach_rect(silhouette, op.max_span, op.tool_d / 2,
                          ((stock_min[0] + stock_max[0]) / 2, (stock_min[1] + stock_max[1]) / 2))
        pc = pyclipper.Pyclipper()
        pc.AddPaths(band_outers, pyclipper.PT_SUBJECT, True)
        pc.AddPath(g.to_int(g.rect(*box)), pyclipper.PT_CLIP, True)
        pocket_band = pc.Execute(pyclipper.CT_INTERSECTION, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)
    frame_keep: list = []
    if frame_wall:
        pc = pyclipper.Pyclipper()
        pc.AddPath(g.to_int(full_real), pyclipper.PT_SUBJECT, True)
        pc.AddPaths(material, pyclipper.PT_CLIP, True)
        frame_keep = [g.to_mm(p).tolist() for p in pc.Execute(pyclipper.CT_DIFFERENCE, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)]
    stock = [stock_rect]
    zs = levels(z_top, bottom, op.stepdown, [f + op.leave_z for f in floor_levels])
    # The clamps' keep-out, only where it overlaps the stock (outside it, nothing is cut anyway).
    keep_out = []
    if op.keep_out:
        pc = pyclipper.Pyclipper()
        # Grown by the clearance the tool keeps (the jaws often sit right on the stock's edge).
        pc.AddPaths(g.offset([g.to_int(r) for r in op.keep_out], 0.75), pyclipper.PT_SUBJECT, True)
        # Clipped to the stock grown by 1 mm: an island that ends exactly on the stock's edge
        # isn't kept out reliably by the solver.
        pc.AddPath(g.to_int(g.rect(stock_min[0] - grow - 1, stock_min[1] - grow - 1, stock_max[0] + grow + 1, stock_max[1] + grow + 1)),
                   pyclipper.PT_CLIP, True)
        keep_out = pc.Execute(pyclipper.CT_INTERSECTION, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)
    # Below the jaws, links may not cross the keep-out either: it isn't "already cleared".
    stock_ko = stock
    if keep_out:
        pc = pyclipper.Pyclipper()
        pc.AddPath(g.to_int(stock_rect), pyclipper.PT_SUBJECT, True)
        pc.AddPaths(keep_out, pyclipper.PT_CLIP, True)
        stock_ko = [g.to_mm(p).tolist() for p in pc.Execute(pyclipper.CT_DIFFERENCE, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)]
    cleared_ko = cleared
    if keep_out and cleared:
        pc = pyclipper.Pyclipper()
        pc.AddPaths([g.to_int(np.asarray(p)) for p in cleared], pyclipper.PT_SUBJECT, True)
        pc.AddPaths(keep_out, pyclipper.PT_CLIP, True)
        cleared_ko = [g.to_mm(p).tolist() for p in pc.Execute(pyclipper.CT_DIFFERENCE, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)]

    def make():
        a = N.Adaptive2d()
        a.tool_diameter = op.tool_d
        a.step_over_factor = min(max(op.stepover / op.tool_d, 0.02), 0.5)
        a.helix_ramp_target_diameter = op.tool_d * 0.9
        a.helix_ramp_min_diameter = op.tool_d * 0.3
        a.tolerance = 0.05
        a.stock_to_leave = op.leave_xy
        a.finishing_profile = False
        return a

    skipped_pockets: list[int] = []

    def level(z):
        """One level, outside the part and inside its pockets. The native solver releases the
        GIL, so levels run in parallel threads; they're independent (each clears its own band)."""
        t0 = time.time()
        out = _level(z)
        if os.environ.get("COASTLINE_ADAPTIVE_DEBUG"):
            n = sum(len(p) for r in out[0] for _, p in r.paths)
            print(f"adaptive level z={z:.2f} {time.time() - t0:.1f}s points={n} keep={len(part.shadow(z - op.leave_z))}", flush=True)
        return out

    def _level(z):
        shadow = part.shadow(z - op.leave_z)
        outers, holes = g.outer_and_holes(shadow)
        level_stock, level_cleared = stock, cleared
        if keep_out and z < op.keep_out_below:
            # Below the clamp jaws' face the clamps aren't stock: take them out of the material
            # (the solver ignores islands that cross the stock's edge) and out of the "already
            # cleared" area its links may cross.
            level_stock, level_cleared = stock_ko, cleared_ko
        # Outside the part's outline only: its pockets are cleared from inside below (or left
        # to a smaller tool), not worked around as islands by the outside pass.
        keep = [g.to_mm(p).tolist() for p in outers]
        a = make()
        a.op_type = N.OperationType.ClearingOutside
        if op.pockets_only:
            outside = []
        elif frame_wall:
            # The band as a pocket: its outer edge is a wall (the frame stays solid), the part
            # and its tabs are islands, the clamps' keep-out comes off it; only the real stock
            # is material (the band past the stock's edge is air to enter from).
            pc = pyclipper.Pyclipper()
            pc.AddPaths(pocket_band, pyclipper.PT_SUBJECT, True)
            clip = list(outers) + (list(keep_out) if (keep_out and z < op.keep_out_below) else [])
            if clip:
                pc.AddPaths(clip, pyclipper.PT_CLIP, True)
            region = pc.Execute(pyclipper.CT_DIFFERENCE, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)
            outside = []
            if region:
                a.op_type = N.OperationType.ClearingInside
                outside = a.execute(stock_paths=[g.to_mm(g.to_int(full_real)).tolist()],
                                    paths=[g.to_mm(p).tolist() for p in region], cleared_paths=[])
        elif keep:
            outside = a.execute(stock_paths=level_stock, paths=keep, cleared_paths=level_cleared)
        else:
            # Above the part: the whole face is material. Clear outside a speck far from the stock.
            far = 1e4
            outside = a.execute(stock_paths=level_stock, paths=[[(far, far), (far + 1e-3, far), (far + 1e-3, far + 1e-3)]],
                                cleared_paths=level_cleared)
        # Pockets inside the part (holes in the shadow) need inside clearing with helical entry;
        # pockets narrower than the tool return nothing (holes are drilled or bored separately).
        t_out = time.time()
        inside = []
        for hole in holes:
            # Pockets barely wider than the tool would be cleared in endless small loops: they're
            # left to a smaller tool (pockets-only roughing, or the finishing contour).
            if op.min_pocket and not g.offset([hole], -op.min_pocket * op.tool_d / 2):
                skipped_pockets.append(1)
                continue
            loop = g.to_mm(hole).tolist()
            done = _swept_by_earlier(hole, op.rest_from)
            if done is not None and not g.offset(_difference([hole], done), -op.tool_d * 0.1):
                continue  # the larger tools left nothing worth a pass here
            b = make()
            b.op_type = N.OperationType.ClearingInside
            t_h = time.time()
            inside.append((b.execute(stock_paths=[loop], paths=[loop],
                                     cleared_paths=[g.to_mm(p).tolist() for p in done] if done else []), loop))
            if os.environ.get("COASTLINE_ADAPTIVE_DEBUG") and time.time() - t_h > 2:
                hb = g.to_mm(hole)
                print(f"  slow pocket at z={z:.2f}: {time.time() - t_h:.1f}s, size {np.ptp(hb[:, 0]):.1f} x {np.ptp(hb[:, 1]):.1f}", flush=True)
        _ = t_out
        return outside, inside

    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=max(min(os.cpu_count() or 4, 8) - 1, 1)) as pool:
        per_level = list(pool.map(level, zs))
    prev = z_top
    ko_mm = [g.to_mm(p) for p in keep_out]
    for z, (outside, inside) in zip(zs, per_level):
        _emit_adaptive(op, outside, z, prev, stock_min, stock_max, tp,
                       avoid=ko_mm if (ko_mm and z < op.keep_out_below) else None)
        for res, loop in inside:
            _emit_adaptive(op, res, z, prev, stock_min, stock_max, tp, inside=True, walls=[np.asarray(loop, float)])
        prev = z
    if op.max_span and frame_wall and not op.pockets_only:
        span_c = _reach_rect(silhouette, op.max_span, 0.0,
                             ((stock_min[0] + stock_max[0]) / 2, (stock_min[1] + stock_max[1]) / 2))
        _edge_slivers(op, part, band_outers, full_real, real, span_c, zs, z_top, tabs_kept, keep_out, stock_min, stock_max, tp)
    tp.retract()
    if skipped_pockets:
        n = len(skipped_pockets) // max(len(zs), 1) or 1
        tp.warnings.append(f"{n} pocket{'s' if n != 1 else ''} too narrow to rough with this {op.tool_d:g} mm tool "
                           "were left for a smaller one (pockets-only roughing or the finishing contour).")
    return tp


def _edge_slivers(op: Op, part, band_outers, full_real, real, span_c, zs, z_top, tabs, keep_out, stock_min, stock_max,
                  tp: Toolpath) -> None:
    """Where the band runs off the stock's edge but the machine's reach clipped the roughing
    (it enters an open edge from outside, a radius past it), a sliver of stock stays standing
    along the edge: under a millimetre wide and the full depth, it breaks loose and chatters
    against the tool. It's taken off from inside the reach instead: one light side pass along
    it per level, the tool's centre within the travel and its edge past the stock. Never over
    the tabs, the clamps' keep-out or the part."""
    pc = pyclipper.Pyclipper()
    pc.AddPaths(band_outers, pyclipper.PT_SUBJECT, True)
    pc.AddPath(g.to_int(full_real), pyclipper.PT_CLIP, True)
    band_in = pc.Execute(pyclipper.CT_INTERSECTION, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)
    if not band_in:
        return
    pc = pyclipper.Pyclipper()
    pc.AddPaths(band_in, pyclipper.PT_SUBJECT, True)
    pc.AddPath(g.to_int(real), pyclipper.PT_CLIP, True)
    left = pc.Execute(pyclipper.CT_DIFFERENCE, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)
    if not left:
        return
    r = op.r
    forbidden = []
    bottom_shadow = part.shadow(min(zs) - op.leave_z) if zs else []
    if bottom_shadow:
        forbidden += g.offset(bottom_shadow, r + op.leave_xy + 0.1)
    if tabs and tabs[0]:
        forbidden += g.offset(tabs[0], r + 0.5)
    if keep_out:
        forbidden += g.offset(keep_out, r + 0.25)
    cx0, cy0, cx1, cy1 = span_c

    def runs(fixed_x, x_or_y, a, b):
        """Stretches of the pass (along Y if fixed_x else X) clear of everything forbidden."""
        out, start, t = [], None, a
        step = 0.25
        while t <= b + 1e-9:
            pt = (x_or_y, t) if fixed_x else (t, x_or_y)
            ip = g.to_int(np.array([pt]))[0]
            bad = any(pyclipper.PointInPolygon(tuple(ip), f) != 0 for f in forbidden)
            if not bad and start is None:
                start = t
            if (bad or t + step > b + 1e-9) and start is not None:
                end = t - step if bad else t
                if end - start >= 1.0:
                    out.append((start, end))
                start = None
            t += step
        return out

    passes = []  # (fixed_x, coordinate, a, b)
    for poly in left:
        pts = g.to_mm(poly)
        bx0, by0 = pts.min(axis=0)
        bx1, by1 = pts.max(axis=0)
        if bx1 - bx0 > 2 * r and by1 - by0 > 2 * r:
            continue  # not a sliver: a strip the reach leaves on purpose
        if by1 - by0 >= bx1 - bx0:  # along Y, at the ±X edge
            if bx1 >= stock_max[0] - 0.01:
                xc = min(cx1, bx0 + r - 0.05)
                if xc + r < bx1 + 0.05:
                    continue
            elif bx0 <= stock_min[0] + 0.01:
                xc = max(cx0, bx1 - r + 0.05)
                if xc - r > bx0 - 0.05:
                    continue
            else:
                continue
            passes += [(True, xc, a, b) for a, b in runs(True, xc, by0, by1)]
        else:  # along X, at the ±Y edge
            if by1 >= stock_max[1] - 0.01:
                yc = min(cy1, by0 + r - 0.05)
                if yc + r < by1 + 0.05:
                    continue
            elif by0 <= stock_min[1] + 0.01:
                yc = max(cy0, by1 - r + 0.05)
                if yc - r > by0 - 0.05:
                    continue
            else:
                continue
            passes += [(False, yc, a, b) for a, b in runs(False, yc, bx0, bx1)]
    if not passes:
        return
    for fixed_x, c, a, b in passes:
        prev = z_top
        forward = True
        for z in zs:
            s_, e_ = (a, b) if forward else (b, a)
            p0 = (c, s_) if fixed_x else (s_, c)
            p1 = (c, e_) if fixed_x else (e_, c)
            tp.go_to(p0[0], p0[1], z, op.plunge, op.link_feed, cleared_down_to=prev)
            tp.line(p1[0], p1[1], z, op.feed)
            forward = not forward
            prev = z
        tp.retract()


def _clearance(x: float, y: float, polys: list) -> float:
    """Distance from a point to the nearest of `polys` (mm arrays), negative inside one."""
    best = float("inf")
    for p in polys:
        a, b = p, np.roll(p, -1, axis=0)
        d = b - a
        t = np.clip(((x - a[:, 0]) * d[:, 0] + (y - a[:, 1]) * d[:, 1]) / np.maximum((d * d).sum(1), 1e-12), 0, 1)
        dist = np.hypot(a[:, 0] + t * d[:, 0] - x, a[:, 1] + t * d[:, 1] - y).min()
        # Even-odd point-in-polygon.
        inside = (((a[:, 1] > y) != (b[:, 1] > y)) & (x < a[:, 0] + (y - a[:, 1]) * d[:, 0] / np.where(d[:, 1] == 0, 1e-12, d[:, 1]))).sum() % 2
        best = min(best, -dist if inside else dist)
    return best


def _helix_spot(op: Op, hx, hy, hr, res, avoid):
    """A helix centre and radius that keep the tool out of `avoid` (the clamps' keep-out):
    the solver's spot if it's clear, else the first clear spot along the first cut (which is
    clear by construction), else a tight helix at the cut's start."""
    from .. import _native as N
    if not avoid or _clearance(hx, hy, avoid) >= hr + op.r:
        return hx, hy, hr
    for motion, pts in res.paths:
        if motion != int(N.MotionType.Cutting):
            continue
        for x, y in pts[:: max(len(pts) // 40, 1)]:
            if _clearance(x, y, avoid) >= hr + op.r:
                return x, y, hr
        sx, sy = pts[0]
        return sx, sy, max(min(_clearance(sx, sy, avoid) - op.r, hr), 0.1)
    return hx, hy, hr


def _emit_adaptive(op: Op, results, z, prev, stock_min, stock_max, tp: Toolpath, inside=False, avoid=None, walls=None):
    from .. import _native as N

    for res in results:
        # A region the tool can't enter comes back with "start point not found" and a default
        # helix centre of (0, 0), which may be inside the part. Never emit those.
        if res.start_point_not_found or not any(len(p) for _, p in res.paths):
            continue
        hx, hy = res.helix_center
        sx, sy = res.start_point
        in_stock = (stock_min[0] - op.r < hx < stock_max[0] + op.r) and (stock_min[1] - op.r < hy < stock_max[1] + op.r)
        if inside or in_stock:
            # Helical ramp from the level above (already cleared) down into this level.
            hr = op.tool_d * 0.45 * 0.5
            hx, hy, hr = _helix_spot(op, hx, hy, hr, res, avoid)
            if walls:
                # In a pocket barely wider than the tool the solver may have placed its entry for
                # a smaller helix: never wider than the room to the pocket's walls (a nick in
                # the part otherwise).
                room = abs(_clearance(hx, hy, walls)) - op.r - op.leave_xy - 0.05
                hr = min(hr, max(room, 0.05))
            tp.go_to(hx + hr, hy, prev + 0.2, op.plunge, op.link_feed, cleared_down_to=prev + 0.2)
            tp.helix_down(hx, hy, hr, prev + 0.2, z, op.ramp_angle, op.ramp)
            tp.line(sx, sy, z, op.ramp, RAMP)
        else:
            tp.go_to(sx, sy, z, op.plunge, op.link_feed, cleared_down_to=z)
        for motion, pts in res.paths:
            pts = np.asarray(pts, float)
            if len(pts) == 0:
                continue
            if motion == int(N.MotionType.Cutting):
                tp.polyline(pts, z, op.feed, CUT)
            elif motion == int(N.MotionType.LinkClear):
                tp.polyline(pts, z, op.feed, LINK, arc_tol=None)
            else:  # LinkNotClear: lift over the material
                end = pts[-1]
                tp.go_to(end[0], end[1], z, op.plunge, op.link_feed, cleared_down_to=z)
        tp.retract()


# ---------------------------------------------------------------- contour


def _tab_zones(tabs, r: float):
    """Where the tool's centre lifts over the tabs (a one-sided part cut through: tabs are gaps
    in the contour, not islands it goes round): within a tab's width plus the tool's radius
    along the outline, from just inside the outline out past the slot."""
    zones = []
    for t in tabs:
        c, n = np.asarray(t["centre"], float), np.asarray(t["normal"], float)
        n = n / max(np.linalg.norm(n), 1e-9)
        poly = np.asarray(t["poly"], float)
        along = np.array([-n[1], n[0]])
        half = float(np.max(np.abs((poly - c) @ along)))
        zones.append((c, n, along, half + r))
    def inside(p):
        for c, n, along, half in zones:
            d = p - c
            if abs(d @ along) < half and -r - 1.0 < d @ n < 3 * r + 3.0:
                return True
        return False
    return inside


def _lifted_loop(tp: Toolpath, pts, z, z_lift, inside, op: Op):
    """The loop at z, lifted to z_lift wherever the tool's centre is over a tab."""
    from .surface3d import densify

    dense = densify(np.asarray(pts, float), 0.2)
    for p in dense:
        zz = z_lift if inside(p) else z
        down = tp.pos is not None and zz < tp.pos[2] - 1e-6
        tp.line(p[0], p[1], zz, op.plunge if down else op.feed, PLUNGE if down else CUT)


def contour(op: Op, part: g.PartGeometry, stock_min, tp: Toolpath, z_top: float = 0.0, lift=None,
            skin_top: float | None = None) -> Toolpath:
    """Finishes the walls level by level following the part's outline at each height, with
    tangent arc lead-in/out and an optional spring pass. `lift` = (tabs, z_lo, z_hi): a part
    cut through on one side keeps its tabs by the tool lifting over them below z_hi; below
    `skin_top` (the roughing's floor) the slot is cut from material, not air."""
    bottom = max(stock_min[2], op.z_min) if op.through else max(part.zmin, stock_min[2], op.z_min)
    if bottom < shank_bottom(op) - 0.01:
        bottom = shank_bottom(op)
        tp.warnings.append(shank_warning(op, bottom))
    zs = levels(z_top, bottom, op.stepdown)
    if lift is not None:
        # The tabs' top is a level of its own (the lift height), so the slot under it is clean.
        zs = sorted(set(list(zs) + [lift[2]] + ([skin_top] if skin_top is not None else [])), reverse=True)
        zs = [z for z in zs if bottom - 1e-9 <= z <= z_top]
    lifting = (_tab_zones(lift[0], op.r), lift[2]) if lift is not None and lift[0] else None
    lead = min(max(op.r, 0.5), 2.0)
    for z in zs:
        shadow = part.shadow(z)
        tool_region = g.offset(shadow, op.r + op.leave_xy, arc_tol=0.001)
        # Where the tool's centre may not go (a hair inside the path itself): lead arcs are
        # checked against it, so in a narrow lattice hole they don't swing into the next wall.
        keep_clear = g.offset(shadow, op.r + op.leave_xy - 0.02) if shadow else []
        outers, holes = g.outer_and_holes(tool_region)
        loops = [(p, True) for p in outers] + [(p, False) for p in holes]
        for path, outer in loops:
            pts = g.to_mm(path)
            # pyclipper outers are CCW; climb outside = CW → reverse outers. Holes are CW → reverse to CCW.
            pts = pts[::-1]
            pts = np.vstack([pts, pts[:1]])
            if len(pts) < 4:
                continue
            passes = 2 if op.spring else 1
            air = skin_top if skin_top is not None and z < skin_top else None
            _lead_in(tp, pts, z, lead, op, keep_clear, air)
            for _ in range(passes):
                if lifting is not None and z < lifting[1] - 1e-9:
                    _lifted_loop(tp, pts, z, lifting[1], lifting[0], op)
                else:
                    tp.polyline(pts, z, op.feed, CUT)
            _lead_out(tp, pts, z, lead, op, keep_clear)
            tp.retract()
    return tp


def _arc_clear(c, a0, a1, R, keep_clear) -> bool:
    """True if the arc about c from angle a0 to a1 (radius R) keeps the tool's centre out of
    `keep_clear` (pyclipper paths, even-odd)."""
    if not keep_clear:
        return True
    for k in range(1, 9):
        a = a0 + (a1 - a0) * k / 8
        q = g.to_int(np.array([[c[0] + R * math.cos(a), c[1] + R * math.sin(a)]]))[0]
        inside = sum(1 for poly in keep_clear if pyclipper.PointInPolygon(tuple(q), poly) != 0) % 2 == 1
        if inside:
            return False
    return True


def _lead_in(tp: Toolpath, pts, z, R, op: Op, keep_clear=None, air=None):
    """A tangent quarter-arc onto the path from its free side, as large as fits (R, R/2, R/4);
    with no room at all, straight down onto the path's start (the roughing cleared it). `air`:
    cleared only down to there (below, plunge feed)."""
    p0, p1 = pts[0], pts[1]
    t = (p1 - p0) / max(np.linalg.norm(p1 - p0), 1e-9)
    n = np.array([-t[1], t[0]])  # material is on the right, so left = away from the wall
    for r_ in (R, R / 2, R / 4):
        c = p0 + n * r_
        s = c - t * r_
        a_s = math.atan2(s[1] - c[1], s[0] - c[0])
        a_e = math.atan2(p0[1] - c[1], p0[0] - c[0])
        if a_e < a_s:
            a_e += 2 * math.pi  # counter-clockwise
        if _arc_clear(c, a_s, a_e, r_, keep_clear):
            tp.go_to(s[0], s[1], z, op.plunge, op.link_feed, cleared_down_to=z if air is None else air)
            tp.arc(p0[0], p0[1], z, c[0], c[1], False, op.feed, LEAD)
            return
    tp.go_to(p0[0], p0[1], z, op.plunge, op.link_feed, cleared_down_to=z if air is None else air)


def _lead_out(tp: Toolpath, pts, z, R, op: Op, keep_clear=None):
    pe, pp = pts[-1], pts[-2]
    t = (pe - pp) / max(np.linalg.norm(pe - pp), 1e-9)
    n = np.array([-t[1], t[0]])
    for r_ in (R, R / 2, R / 4):
        c = pe + n * r_
        e = c + t * r_
        a_s = math.atan2(pe[1] - c[1], pe[0] - c[0])
        a_e = math.atan2(e[1] - c[1], e[0] - c[0])
        if a_e < a_s:
            a_e += 2 * math.pi
        if _arc_clear(c, a_s, a_e, r_, keep_clear):
            tp.arc(e[0], e[1], z, c[0], c[1], False, op.feed, LEAD)
            return
    # No room to leave on an arc: lift straight off the path's end.


# ---------------------------------------------------------------- floors


def floors(op: Op, floor_list, tp: Toolpath) -> Toolpath:
    """Finishes flat up-facing faces with inward offset rings (climb, CCW)."""
    narrow: dict = {}
    too_deep = 0
    for fl in floor_list:
        z = fl["z"]
        if z < op.z_min - 1e-6:
            continue  # the other side's floor
        if op.floor_max_width and g.offset(fl["paths"], -op.floor_max_width / 2):
            continue  # wide enough for the bigger tool's pass: done there
        if z < shank_bottom(op) - 1e-6:
            too_deep += 1
            continue
        rings = []
        cur = g.offset(fl["paths"], -op.r, arc_tol=0.002)
        while cur:
            rings.append(cur)
            cur = g.offset(cur, -op.stepover, arc_tol=0.002)
        if not rings:
            narrow[round(z, 2)] = narrow.get(round(z, 2), 0) + 1
            continue
        for ring in rings:
            for path in ring:
                pts = g.to_mm(path)
                if pyclipper.Orientation(path):
                    pts = pts  # CCW already
                else:
                    pts = pts[::-1]
                pts = np.vstack([pts, pts[:1]])
                tp.go_to(pts[0][0], pts[0][1], z, op.plunge, op.link_feed, cleared_down_to=z + 0.05)
                tp.polyline(pts, z, op.feed, CUT)
        tp.retract()
    # One line per height, not one per floor (a lattice has dozens).
    for z, n in sorted(narrow.items(), reverse=True):
        tp.warnings.append(f"{n} floor{'s' if n != 1 else ''} at Z{z:.2f} {'are' if n != 1 else 'is'} too narrow for the ⌀{op.tool_d:g} mm tool.")
    if too_deep:
        tp.warnings.append(f"{too_deep} floor{'s' if too_deep != 1 else ''} below Z{shank_bottom(op):.2f} left: " + shank_warning(op, shank_bottom(op)))
    return tp


# ---------------------------------------------------------------- holes


def drill(op: Op, holes, tp: Toolpath, tip_angle: float = 118.0) -> Toolpath:
    """Peck drilling, expanded into moves (grbl has no canned cycles): feed a peck, retract
    to clear chips, feed back down to just above the last depth."""
    tip = op.r / math.tan(math.radians(tip_angle / 2))
    for h in holes:
        x, y = h["x"], h["y"]
        top = h["z_top"]
        end = max(h["z_bottom"] - (tip + 0.3 if h.get("through") else 0), op.z_min - (tip + 0.3))
        tp.go_to(x, y, top + 0.5, op.plunge, op.link_feed, cleared_down_to=top + 0.5)
        depth = top
        while depth > end + 1e-9:
            nxt = max(depth - op.stepdown, end)
            tp.line(x, y, nxt, op.feed, PLUNGE)
            depth = nxt
            if depth > end + 1e-9:
                tp.retract()
                tp.rapid(x, y, tp.approach_z)
                tp.line(x, y, depth + 0.2, op.link_feed, LINK)
        tp.retract()
    return tp


def bore(op: Op, holes, tp: Toolpath, skin_top: float | None = None) -> Toolpath:
    """Helical boring for holes larger than the tool: helix down, a full circle at the bottom,
    then a finishing circle. `skin_top`: a part cut through on one side, its roughing stopped
    at a skin there; in a through hole wider than the ring the bore leaves, that skin's disc
    is cleared too (a small helix at the centre, then circles out), never left loose."""
    shallow: list = []
    for h in holes:
        rc = h["diameter"] / 2 - op.r
        if rc < 0.05:
            tp.warnings.append(f"⌀{h['diameter']:.2f} hole: the ⌀{op.tool_d:g} mm tool is too big to bore it.")
            continue
        x, y = h["x"], h["y"]
        top, bottom = h["z_top"], h["z_bottom"]
        if h.get("through"):
            bottom -= 0.2
        bottom = max(bottom, op.z_min - 0.2)
        if bottom < shank_bottom(op) - 0.01:
            bottom = shank_bottom(op)
            shallow.append(1)
            if bottom >= top - 0.05:
                continue
        core = skin_top is not None and h.get("through") and rc - op.r > 0.05
        if core:
            # The skin's disc first, from the centre out, while the ring still holds it.
            r0 = min(max(0.3 * op.tool_d, 0.2), rc)
            tp.go_to(x + r0, y, skin_top + 0.3, op.plunge, op.link_feed, cleared_down_to=skin_top + 0.3)
            tp.helix_down(x, y, r0, skin_top + 0.3, bottom, op.ramp_angle, op.ramp)
            rr = r0
            while rr < rc - 1e-6:
                rr = min(rr + 0.8 * op.r, rc)
                tp.line(x + rr, y, bottom, op.feed, CUT)
                tp.arc(x - rr, y, bottom, x, y, False, op.feed, CUT)
                tp.arc(x + rr, y, bottom, x, y, False, op.feed, CUT)
            tp.retract()
        tp.go_to(x + rc, y, top + 0.3, op.plunge, op.link_feed, cleared_down_to=top + 0.3)
        tp.helix_down(x, y, rc, top + 0.3, bottom, op.ramp_angle, op.ramp)
        # Finishing circle (climb, CCW), then off the wall to the centre before lifting.
        tp.arc(x - rc, y, bottom, x, y, False, op.feed, CUT)
        tp.arc(x + rc, y, bottom, x, y, False, op.feed, CUT)
        tp.line(x, y, bottom, op.feed, LEAD)
        tp.retract()
    if shallow:
        tp.warnings.append(f"{len(shallow)} hole{'s' if len(shallow) != 1 else ''} only bored part way. " + shank_warning(op, shank_bottom(op)))
    return tp


def thread(op: Op, holes, tp: Toolpath, major: float, pitch: float, depth: float | None = None) -> Toolpath:
    """Internal right-hand threads with a single-form thread mill, in holes already made at
    about the tap-drill size. For each hole: feed down the hole's centre (cleared air) to the
    thread's bottom, an arc in onto the helix (tangent), one helical turn per pitch climbing to
    the top (G3: climb milling for a right-hand internal thread), an arc back to the centre.
    Two radial passes (two thirds of the profile, then full), so the thin cutter is never fully
    loaded. The feed is at the cutting edge; the centre runs slower on the inside arc."""
    r_full = major / 2 - op.r
    if r_full <= 0.05:
        tp.warnings.append(f"The \u2300{op.tool_d:g} mm thread mill is too big for an M{major:g} thread.")
        return tp
    centre_feed = max(op.feed * r_full / (major / 2), 1.0)
    too_deep = 0
    for h in holes:
        x, y = h["x"], h["y"]
        top, bottom = h["z_top"], h["z_bottom"]
        hole_r = h["diameter"] / 2
        if hole_r <= op.r + 0.02:
            tp.warnings.append(f"\u2300{h['diameter']:.2f} hole: too small for the \u2300{op.tool_d:g} mm thread mill.")
            continue
        # The thread's bottom: its depth below the top (or the hole's bottom; a blind hole keeps
        # half a pitch clear of its floor), never below the depth window or the cutter's reach.
        end = top - depth if depth else bottom
        if not h.get("through"):
            end = max(end, bottom + pitch / 2)
        end = max(end, op.z_min)
        if end < top - op.flute - 1e-6:
            end = top - op.flute
            too_deep += 1
        if end >= top - pitch:
            continue
        turns = math.ceil((top - end) / pitch - 1e-9)
        wall = r_full - (hole_r - op.r)  # how far the full profile goes into the wall
        passes = [r_full - wall / 3, r_full] if wall > 0.15 else [r_full]
        for r in passes:
            tp.go_to(x, y, end, op.plunge, op.link_feed, cleared_down_to=end)
            # In: a half circle from the centre to the helix, tangent to it (CCW).
            tp.arc(x + r, y, end, x + r / 2, y, False, centre_feed, LEAD)
            z = end
            side = 1
            for _ in range(2 * turns):
                z += pitch / 2
                side = -side
                tp.arc(x + side * r, y, z, x, y, False, centre_feed, CUT)
            # Out: a half circle back to the centre, then up the cleared hole.
            tp.arc(x, y, z, x + r / 2, y, False, centre_feed, LEAD)
            tp.retract()
    if too_deep:
        tp.warnings.append(f"{too_deep} thread{'s' if too_deep != 1 else ''} only {op.flute:.1f} mm deep: the thread mill reaches no further.")
    return tp

