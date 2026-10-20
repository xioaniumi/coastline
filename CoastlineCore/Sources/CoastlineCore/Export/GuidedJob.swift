import CRCore
import Foundation

/// Builds a guided `.crproj` for CRWrite: the same step-by-step structure as Coast Runner's own
/// cutcodes (`setup_stock → edgefinder → edgefind → install tool → touch off → cut`), plus
/// Coastline's air cuts, measuring checkpoints and the stock-squaring job.
public enum GuidedJobBuilder {
    public struct Program: Sendable {
        public var tool: Tool
        public var gcode: String
        public var operationNames: [String]
        public var minutes: Double
        /// 0 = side A, 1 = side B (after flipping the stock).
        public var side: Int
        /// Where the face is when this tool is touched off (work Z): 0 on the stock as clamped,
        /// below it once an earlier program on the side faced it.
        public var touchZ: Double = 0
        /// The program cuts reference features (side A's bores, side B's windows).
        public var reference: Operation.ReferenceFeature?
        /// Probes the face first for an engraving that follows it (SurfaceProbe.program): run
        /// after the touch-off, before the air cut (the program's M112 needs the map).
        public var surfaceProbe: String?
        public init(tool: Tool, gcode: String, operationNames: [String], minutes: Double, side: Int = 0) {
            self.tool = tool
            self.gcode = gcode
            self.operationNames = operationNames
            self.minutes = minutes
            self.side = side
        }
    }

    /// How the guided job finds the stock's position after each clamping.
    public struct Probing: Sendable {
        /// The clamp kit is electrically isolated: the tool itself finds edges, bores and the
        /// face (G38.2, the probe wire on the clamp). Otherwise the Fisher edge finder and paper.
        public var electrical = false
        /// Which X edges (lower, upper) the CR-1 reaches in this clamping, per side. An edge out
        /// of reach is replaced by the other edge and the stock's height.
        public var lowerXReachable = [true, true]
        public var upperXReachable = [true, true]
        /// Side B's zero from side A's reference bores.
        public var bores: ReferenceBores.Plan?
        public init() {}
    }

    /// A measurement to take after a program, with the expected value.
    public struct Checkpoint: Sendable {
        public var afterProgram: Int
        public var what: String
        public var expected: Double
        public var tolerance: Double
        public init(afterProgram: Int, what: String, expected: Double, tolerance: Double) {
            self.afterProgram = afterProgram
            self.what = what
            self.expected = expected
            self.tolerance = tolerance
        }
    }

    public struct Input: Sendable {
        public var partName: String
        public var material: Material
        public var stock: StockItem
        /// Stock size in the machine: X (vertical), Y (left–right), Z (toward the spindle).
        public var stockSize: SIMD3<Double>
        public var setupName: String
        public var programs: [Program]
        public var checkpoints: [Checkpoint]
        public var measuring: [MeasuringTool]
        /// PNG of the setup (stock and part in the machine), shown on the mounting steps.
        public var setupImage: Data?
        /// Prepend the stock-squaring job (sawn stock).
        public var squareStockFirst: Bool
        public var faceAllowance: Double
        /// Workholding: universal clamps in the table's rear T-slot, and where each one's centre
        /// is from the stock's left end (mm; empty: Coastline's places, 12 mm in from each end).
        public var clampCount = 1
        public var clampFromLeft: [Double] = []
        /// How far the stock face sticks out past the jaws, and the parallels behind it, mm.
        public var protrusion = 2.0
        public var parallels = 0.0
        /// Holding tabs on the side that cuts through (nil: a web holds the part, or one side).
        public var tabs: HoldingTabs?
        /// PNG of side B's setup, shown on the flip step.
        public var flipImage: Data?
        /// Mill oversized stock down to a height the clamp kit holds, on the side clamps first.
        public var millDown: MillDown?
        /// Holding path B: the whole job flat on the bed instead of the clamp kit.
        public var bed: BedHolding?
        /// Holding path D: the clamps grip shoulders at the ends (height, length).
        public var shoulders: Setup.Shoulders?
        public var probing = Probing()
        /// How far the spindle comes out at the tool-change position (machine Z), when Coast
        /// Runner's own Z would touch the clamps, parallels or stock of this job (worked out
        /// from the clamp kit's and bed's geometry); nil: Coast Runner's.
        public var toolChangeZ: Double?
        /// Where along Y it stops (machine Y), when Coast Runner's Y would put the spindle right
        /// beside the clamps; nil: Coast Runner's.
        public var toolChangeY: Double?
        /// The clamp kit sits left of the middle so the tools are changed on its right: the
        /// stock's right end this far left of the spindle's centre at the tool-change position, mm.
        public var stockRightOfToolChange: Double?

        public init(partName: String, material: Material, stock: StockItem, stockSize: SIMD3<Double>, setupName: String,
                    programs: [Program], checkpoints: [Checkpoint], measuring: [MeasuringTool], setupImage: Data?,
                    squareStockFirst: Bool, faceAllowance: Double = 0.5) {
            self.partName = partName
            self.material = material
            self.stock = stock
            self.stockSize = stockSize
            self.setupName = setupName
            self.programs = programs
            self.checkpoints = checkpoints
            self.measuring = measuring
            self.setupImage = setupImage
            self.squareStockFirst = squareStockFirst
            self.faceAllowance = faceAllowance
        }
    }

    public struct MillDown: Sendable {
        /// The stock as bought (work X height, Y, Z thickness) and the height to mill it to.
        public var raw: SIMD3<Double>
        public var target: Double
        public var tool: Tool
        public var image: Data?
        /// How long a bar the part setup needs (a long sawn bar is cut to this first).
        public var neededLength: Double?
        /// The CR-1's table and the stop's face, from the machine model.
        public var table = SideClamps.table(topX: -31, frontSlotZ: -13.4)
        public var frontSlotZ = -13.4
        /// The work axis the bar was extruded along (FlatPrep.plan).
        public var extrudedAlong: Int?
        /// The user's adjustments per clamping, and the prep steps chosen by hand.
        public var overrides: [PrepOverride] = []
        public var faceEnd: Bool?
        public var rounds: Int?
        /// Holding path D: only the two ends are milled down (shoulders this long), not the edge.
        public var shoulderLength: Double?
        public var shoulderBottom = 0.0
        public init(raw: SIMD3<Double>, target: Double, tool: Tool, image: Data? = nil, neededLength: Double? = nil) {
            self.raw = raw
            self.target = target
            self.tool = tool
            self.image = image
            self.neededLength = neededLength
        }

        public struct Item: Sendable {
            public var stage: FlatPrep.Stage
            public var title: String
            public var gcode: String
            public var moves: [Move]
            public var report: GCodeValidator.Report
            public var placement: SideClamps.Placement
            public var hits: [FixtureClearance.Hit] = []
        }

        public func plan(sawn: Bool) -> FlatPrep.Plan {
            FlatPrep.plan(raw: raw, target: target, sawn: sawn, neededLength: neededLength, table: table, extrudedAlong: extrudedAlong,
                          faceEnd: faceEnd, rounds: rounds, shoulderLength: shoulderLength, shoulderBottom: shoulderBottom)
        }

        /// The prep programs, each checked like any program plus against the stop, riser,
        /// C-clamps and table as they sit for that stage (the edge cut runs out below the bar on
        /// purpose, so through-cuts are allowed).
        public func programs(material: Material, sawn: Bool, machine: MachineProfile = .cr1) -> (plan: FlatPrep.Plan, items: [Item]) {
            var plan = plan(sawn: sawn)
            var items: [Item] = []
            for (k, p) in FlatPrep.programs(plan, tool: tool, material: material, machine: machine).enumerated() {
                let kind: OperationKind = p.stage.isEdge ? .adaptive : .facing
                let data = FeedsEngine.compute(tool: tool, material: material, kind: kind, machine: machine)
                let g = CR1Post.program(header: .init(programName: p.title, setupName: "Flat on the squaring stop", tool: tool,
                                                      operationNames: [p.title], stockDescription: "\(material.name)"),
                                        rpm: data.rpm, paths: [OperationToolpath(operationID: UUID(), moves: p.moves)], machine: machine)
                var ctx = GCodeValidator.Context(stockMin: SIMD3(-p.stock.x / 2, -p.stock.y / 2, -p.stock.z),
                                                 stockMax: SIMD3(p.stock.x / 2, p.stock.y / 2, 0), tool: tool)
                ctx.allowThroughCut = true
                var report = GCodeValidator(machine: machine).validate(g, context: ctx)
                let o = k < overrides.count ? overrides[k] : nil
                let placement = SideClamps.place(stage: p.stage, table: table, frontSlotZ: frontSlotZ, centreY: 0, override: o)
                for issue in placement.issues where !plan.issues.contains(issue) { plan.issues.append(issue) }
                let hits = Self.clearance(p.moves, stage: p.stage, placement: placement, table: table, tool: tool, centreY: o?.stopShiftY ?? 0)
                if let text = FixtureClearance.describe(hits) { report.issues.append(Issue(.error, text)) }
                items.append(Item(stage: p.stage, title: p.title, gcode: g, moves: p.moves, report: report, placement: placement, hits: hits))
            }
            return (plan, items)
        }

        /// The tool against this stage's fixtures, in the stage's work frame.
        public static func clearance(_ moves: [Move], stage: FlatPrep.Stage, placement p: SideClamps.Placement, table: FlatPrep.Table,
                              tool: Tool, centreY: Double = 0) -> [FixtureClearance.Hit] {
            let origin = SIMD3(p.stockBottomX + stage.stock.x / 2, centreY, p.stockFaceZ)
            let tris = SideClamps.solids(p, table: table, centreY: centreY).flatMap { FixtureField.boxTriangles(min: $0.min - origin, max: $0.max - origin) }
            let pad = FixtureClearance.nutRadius + 15
            var field = FixtureField(triangles: tris, regionMin: SIMD2(-stage.stock.x / 2 - pad, -stage.stock.y / 2 - pad),
                                     regionMax: SIMD2(stage.stock.x / 2 + pad, stage.stock.y / 2 + pad))
            return FixtureClearance.check(moves, tool: tool, field: &field)
        }
    }

    // MARK: Fixed helper programs (Coast Runner's conventions [UC])

    /// The tool-change moves, the spindle's last move out stopping at `z` when given.
    /// Where along the table the kit goes: roughly centred, or left of the middle so the tools
    /// are changed on its right (with a measure to set it by).
    static func kitPlace(_ i: Input, machine: MachineProfile) -> String {
        guard let d = i.stockRightOfToolChange else {
            return "Just keep it roughly centred left to right so the whole cut stays within the CR-1's travel."
        }
        let y = i.toolChangeY ?? machine.toolChangePose.y
        return "**Keep it left of the middle**, so the tools are changed on its right: before snugging the T-slot bolts, jog Y to **Y\(ReferenceBores.n(y))** in Manual Operations (where tools are changed) and place the kit so the stock's **right end is about \(Length.mm((d * 2).rounded() / 2)) mm left of the spindle's centre**. Your hands and both wrenches then have room at every tool change."
    }

    static func toolChangeMoves(machine: MachineProfile, z: Double?, y: Double? = nil) -> [String] {
        var moves = machine.toolChangeMoves
        if let z, let k = moves.lastIndex(where: { $0.uppercased().contains("Z") }) {
            moves[k] = "G53 G0 Z\(ReferenceBores.n(z))"
        }
        if let y, let k = moves.lastIndex(where: { $0.uppercased().contains("Y") }) {
            moves[k] = "G53 G0 Y\(ReferenceBores.n(y))"
        }
        return moves
    }

    public static func helperFiles(machine: MachineProfile, toolChangeZ: Double? = nil, toolChangeY: Double? = nil) -> [String: String] {
        [
            "Code/home.nc": "$H\n",
            "Code/tool_change_position.nc": (["G21 G90"] + toolChangeMoves(machine: machine, z: toolChangeZ, y: toolChangeY)).joined(separator: "\n") + "\n",
            "Code/edgefinder_spin.nc": "G21 G90\nM3 S\(Int(machine.probeSpindleRPM))\n",
            "Code/spindle_stop.nc": "M5\n",
            "Code/store_x_low.nc": "G10 L20 P2 X0\nG4 P0.5\n",
            "Code/store_x_high.nc": "G10 L20 P3 X0\nG4 P0.5\n",
            "Code/set_x_centre.nc": "M100 G55X G56X G54X\nG4 P0.5\n",
            "Code/store_y_left.nc": "G10 L20 P2 Y0\nG4 P0.5\n",
            "Code/store_y_right.nc": "G10 L20 P3 Y0\nG4 P0.5\n",
            "Code/set_y_centre.nc": "M100 G55Y G56Y G54Y\nG4 P0.5\n",
            "Code/store_z.nc": "G10 L20 P1 Z0\nG4 P0.5\nG54\n",
        ]
    }

    // MARK: Tool changes, touch-off and finding the stock (Operator manual §4.5–4.6)

    /// Moving to the tool-change position, then changing the tool by hand the way the manual
    /// describes it: both wrenches, the collet snapped into the nut, the stick-out, the chip fan.
    static func toolChangeSteps(_ title: String, tool: Tool, previous: Tool?, note: String = "") -> [Step] {
        let shank = Length.describe(tool.shankDiameter)
        let swapCollet = previous.map { abs($0.shankDiameter - tool.shankDiameter) > 0.01 } ?? true
        let inside = tool.overallLength - tool.stickout
        let collet = swapCollet
            ? (previous == nil
               ? "\n**The collet** must be the **\(shank)** one. If another is in the nut, unscrew the nut completely, pop that collet out and snap the \(shank) one in at a slight angle until it **clicks**. Shake the nut upside down: the collet must not fall out (one that isn't snapped in lets the tool walk out mid-cut). Thread the nut back on a few turns by hand.\n"
               : "\n**Change the collet** to the **\(shank)** one (the last tool had a \(Length.describe(previous!.shankDiameter)) shank): unscrew the nut completely, pop the old collet out and snap the new one in at a slight angle until it **clicks**. Shake the nut upside down: the collet must not fall out. Thread the nut back on a few turns by hand.\n")
            : ""
        return [
            step("Tool Change Position", markdown: """
            Click Next: the CR-1 homes, lowers the table to the bottom of its travel (the stock as far from the spindle as it goes), moves the gantry to where there's room and brings the spindle forward, out of the machine towards you, so the collet nut stands free with room for both wrenches.

            Leave the stock clamped: the zero found for it stays valid.
            """, gcode: "Code/tool_change_position.nc", timeout: 90),
            step(title, markdown: """
            **You need** the 12 mm and 17 mm wrenches\(swapCollet ? " and the \(shank) ER-11 collet" : "").\(note.isEmpty ? "" : " " + note)

            **Take out \(previous.map { "the \($0.name)" } ?? "the tool in the spindle, if there is one")**
            1. Pull the chip fan off the collet nut.
            2. Put the **12 mm wrench on the spindle's flats** and the **17 mm wrench on the collet nut**.
            3. Hold the 12 mm wrench still and turn the 17 mm one to loosen the nut. Unscrew it a little by hand and pull the tool out.
            \(collet)
            **Fit the \(tool.name)**
            4. Slide it into the collet so **\(Length.mm(tool.stickout)) mm sticks out** below the nut (measure it)\(inside < 8 ? "" : "; at least 8 mm of the shank stays in the collet").
            5. Hold it there and tighten the nut by hand as far as it goes.
            6. With both wrenches as before, tighten until it won't easily go further. Don't force it.
            7. Push the chip fan back over the nut, hexagon side first.
            """, popup: ("Tool in?", "Is the \(tool.name) tight in the collet with \(Length.mm(tool.stickout)) mm sticking out?"), noStep: "-0"),
        ]
    }

    /// Paper touch-off by hand (manual §4.6.2): the spindle stopped, 1 → 0.1 → 0.01 mm steps.
    static func paperTouchOff(_ where_: String, extra: String = "") -> String {
        """
        The spindle stays **stopped**. In **Manual Operations**:
        1. Jog the tool over \(where_) and toward the face in 1 mm steps until it's 1–2 mm away.
        2. Slide a strip of paper between the tip and the face and keep wiggling it.
        3. Jog in 0.1 mm steps until the paper drags. If it's pinched tight, back off 0.1 mm.
        4. Switch to 0.01 mm steps and jog until the paper just stops moving. Stop there.\(extra)
        """
    }

    /// Where the stock should be in the CURRENT zero (G54) after it was clamped again, from the
    /// last clamping's geometry: the machine moves near each edge, the last millimetres are
    /// found by hand or by probing. `zShift`: how much longer the tool in the spindle is than
    /// the one that set Z0 (the commanded Z is the old tool's tip).
    public struct Approach: Sendable {
        public var centre: SIMD3<Double>
        public var size: SIMD3<Double>
        public var zShift: Double
        public init(centre: SIMD3<Double>, size: SIMD3<Double>, zShift: Double) {
            self.centre = centre
            self.size = size
            self.zShift = zShift
        }

        /// The position beside an edge (axis 0 = X, 1 = Y; side −1/+1), `gap` mm outside it.
        func beside(axis: Int, side: Double, gap: Double, radius: Double) -> SIMD2<Double> {
            var p = SIMD2(centre.x, centre.y)
            let half = axis == 0 ? size.x / 2 : size.y / 2
            p[axis] += side * (half + gap + radius)
            return p
        }

        /// The edge finder's start: back to safe Z, beside the edge, then in to `front` mm
        /// in front of the expected face (never below it: the last part is by hand).
        func program(axis: Int, side: Double, radius: Double, front: Double = 6) -> String {
            let p = beside(axis: axis, side: side, gap: 4, radius: radius)
            let z = centre.z + front + zShift
            return """
            G21 G90
            G53 G0 Z-1
            G54 G0 X\(ReferenceBores.n(p.x)) Y\(ReferenceBores.n(p.y))
            G0 Z\(ReferenceBores.n(z + 6))
            G1 Z\(ReferenceBores.n(z)) F400

            """
        }

        /// The probing tool's start (electrical, Z0 just set on this face with this tool):
        /// beside the edge, then down with G38.3, which stops without an alarm if it touches.
        func probeProgram(axis: Int, side: Double, radius: Double, depth: Double) -> String {
            let p = beside(axis: axis, side: side, gap: 3, radius: radius)
            return """
            G21 G90
            G54 G0 Z5
            G0 X\(ReferenceBores.n(p.x)) Y\(ReferenceBores.n(p.y))
            G38.3 Z\(ReferenceBores.n(-depth)) F150

            """
        }
    }

    // MARK: Build

    public static func build(_ input: Input, machine: MachineProfile = .cr1) -> (jobs: [Job], files: [String: Data]) {
        var files: [String: Data] = helperFiles(machine: machine, toolChangeZ: input.toolChangeZ, toolChangeY: input.toolChangeY).mapValues { Data($0.utf8) }
        if let img = input.setupImage { files["Image/setup.png"] = img }
        if let img = input.flipImage { files["Image/flip.png"] = img }
        var jobs: [Job] = []
        if let m = input.millDown { jobs.append(millDownJob(input, m, machine: machine, files: &files)) }
        // Squaring happens on the side clamps as part of milling down, when that's needed.
        if input.squareStockFirst && input.millDown == nil { jobs.append(squaringJob(input, machine: machine, files: &files)) }
        jobs.append(partJob(input, machine: machine, files: &files))
        return (jobs, files)
    }

    /// Writes the guided project. CRCore's writer re-reads its own manifest before saving.
    public static func write(_ input: Input, to url: URL, machine: MachineProfile = .cr1) throws {
        let (jobs, files) = build(input, machine: machine)
        try? FileManager.default.removeItem(at: url)
        try ProjectWriter.save(jobs: jobs, extraFiles: files, from: MemoryProjectSource([:]), to: url)
    }

    // MARK: The part job

    /// The bar flat on the riser against the squaring stop, two C-clamps over it (path B).
    public struct BedHolding: Sendable {
        /// How far the face sticks out past the stop, mm.
        public var protrusion: Double
        /// Each C-clamp's turn about its screw, radians.
        public var clampAngles: [Double]
        public init(protrusion: Double, clampAngles: [Double]) {
            self.protrusion = protrusion
            self.clampAngles = clampAngles
        }
    }

    static func mountOnBed(_ i: Input, _ b: BedHolding) -> String {
        let size = i.stockSize
        let turned = b.clampAngles.contains { abs($0) > 0.05 }
            ? " Turn each clamp about its screw as in the picture (about \(b.clampAngles.map { "\(Int((abs($0) * 180 / .pi).rounded()))°" }.joined(separator: " and "))) so its frame passes beside the bar."
            : ""
        return """
        This job runs with the stock **flat on the bed**, not in the clamp kit. Take the clamp kit off the table. Bolt **one acetal squaring stop** across both T-slots (M4x25 bolts into T-slot nuts) and lay the **riser plate** on the table behind it.

        Lay the stock on the riser with its **\(Length.mm(size.y)) × \(Length.mm(size.x)) mm face toward the spindle**, one end against the stop, the face **\(Length.mm(b.protrusion)) mm** past the stop's front.

        Clamp it down with **two 3\" C-clamps**: the fixed jaw under the table, the frame behind the table's back edge, the screw pad on the stock behind the area that gets cut.\(turned) Tighten both evenly, then check the stock hasn't lifted off the riser.

        The face toward the spindle becomes **Z0**; the middle of that face becomes **X0 Y0**. It doesn't have to sit exactly where Coastline drew it: the next steps find the real edges and face.

        \(bedFindingNote)
        """
    }

    /// Why the bed needs the edge finder and paper: nothing there is insulated.
    static let bedFindingNote = "**Finding the stock here is by hand.** Only the clamp kit sits on an insulating sheet; the stop and the steel C-clamps touch the table, so the CR-1's electrical probing can't work (its circuit would always be closed). X and Y come from the clicking Fisher edge finder, Z from paper touch-off, both jogged in Manual Operations. After the first clamping the CR-1 can drive the finder close to each edge (the stop puts the stock back in a known place), but the last millimetres are always yours."

    static func partJob(_ i: Input, machine: MachineProfile, files: inout [String: Data]) -> Job {
        var job = Job(title: "\(i.setupName) · \(i.partName)",
                      prompt: "Machines \(i.partName) from \(i.material.name), in \(i.programs.count) tool program\(i.programs.count == 1 ? "" : "s").")
        var steps: [Step] = []
        let size = i.stockSize
        let toolList = i.programs.enumerated().map { k, p in
            "\(k + 1). **\(p.tool.name)**, stick-out \(Length.mm(p.tool.stickout)) mm (\(p.operationNames.joined(separator: ", ")), about \(Int(p.minutes.rounded())) min)"
        }.joined(separator: "\n")
        steps.append(step("Before You Start", markdown: """
        This job was planned by **Coastline** for your Coast Runner CR-1.

        **Material** \(i.material.name). \(i.material.lubricant)

        **Stock** \(Length.mm(size.x)) mm tall (X) × \(Length.mm(size.y)) mm wide (Y) × \(Length.mm(size.z)) mm thick (toward the spindle).

        **Tools, in order**
        \(toolList)

        Stay with the machine while it cuts, and keep a hand near the E-stop. Never use compressed air on the CR-1; vacuum chips instead.
        """))
        steps.append(step("Home the Machine", text: "Click Next to home all axes.", gcode: "Code/home.nc", timeout: 60))
        let clamps = i.clampCount == 1 ? "the universal clamp" : "\(i.clampCount) universal clamps"
        let parallels = i.parallels > 0.05
            ? "Put **about \(Length.mm(i.parallels)) mm of parallels** behind the stock so its face sticks out **\(Length.mm(i.protrusion)) mm** past the jaws."
            : "Its face sticks out **\(Length.mm(i.protrusion)) mm** past the jaws."
        if let b = i.bed {
            steps.append(step("Mount the Stock", markdown: mountOnBed(i, b), image: i.setupImage == nil ? "" : "Image/setup.png",
                              popup: ("Stock clamped?", "Is the stock flat on the riser, against the stop and clamped tight?")))
        } else {
        steps.append(step("Mount the Stock", markdown: """
        Bolt \(clamps) into the table's **rear T-slot** (M4 bolt into a T-slot nut), throat toward the spindle\(i.clampFromLeft.isEmpty ? (i.clampCount > 1 ? ", one near each end of the stock" : ", centred left to right") : ", their middles **\(i.clampFromLeft.map { Length.mm($0) + " mm" }.joined(separator: " and ")) from the stock's left end** (as placed in Coastline)"). Snug the bolts.

        Stand the stock on the lower jaw with its **\(Length.mm(size.y)) × \(Length.mm(size.x)) mm face toward the spindle** and its \(Length.mm(size.y)) mm side running left to right\(i.shoulders.map { ", the milled shoulders up: each clamp goes over a shoulder (\(Length.mm($0.height)) mm tall there), the full-height middle stands up between them" } ?? ""). \(parallels)

        The stock goes in **from the side**: the spindle is in front of the throat and the clamps' top arms are above it. If the spindle is in the way, loosen the clamps' T-slot bolts, slide the kit along the slots clear of it, slide the stock in through the throat\(i.clampCount > 1 ? "s of both clamps" : ""), then slide everything back to its place and snug the bolts.

        Tighten the clamp screw onto the stock's top edge. The face toward the spindle becomes **Z0**; the middle of that face becomes **X0 Y0**.

        It doesn't have to sit exactly where Coastline drew it: the next steps find the stock's real edges and face, and every program follows them. \(kitPlace(i, machine: machine))
        """, image: i.setupImage == nil ? "" : "Image/setup.png",
        popup: ("Stock clamped?", "Is the stock clamped tight and square to the spindle?")))
        }
        let pr = i.probing
        if pr.electrical {
            steps.append(step("Connect the Probe Wire", markdown: """
            Coastline finds the stock with **electrical probing**: the clamp kit sits on its insulating pad, so when the tool touches the stock it closes a circuit and the CR-1 stops right there (G38.2). No edge finder, no paper.

            1. Plug the red probe wire's barrel jack into the port on the left side of the mill's LED board.
            2. Bolt the other end to the top of the clamp (the tapped M5 hole) or tape it on firmly. The stock touches the clamp, so it's in the circuit too.
            3. Wipe the stock where it will be touched, and the tool's tip: chips, oil or anodising stop the contact.

            Coated tools (dark AlTiN, TiAlN, DLC) don't conduct well; uncoated carbide does.
            """, popup: ("Wire connected?", "Is the probe wire plugged into the LED board and fixed to the clamp?")))
        }
        // The tool in the spindle with its Z set (nil after the edge finder or a flip), and
        // the last one fitted (for the tool change: which collet it had, how long it was).
        var spindle: Tool?
        var fitted: Tool?
        func touchZFile(_ z: Double, electrical: Bool) -> String {
            let name = "Code/\(electrical ? "probe_top" : "store_z")\(abs(z) < 1e-9 ? "" : "_" + ReferenceBores.n(z).replacingOccurrences(of: "-", with: "m").replacingOccurrences(of: ".", with: "_")).nc"
            if electrical {
                files[name] = Data(ReferenceBores.topProgram(z: z).utf8)
            } else if abs(z) > 1e-9 {
                files[name] = Data("G10 L20 P1 Z\(ReferenceBores.n(z))\nG4 P0.5\nG54\n".utf8)
            }
            return name
        }
        func installTool(_ n: Int, _ p: Program) {
            if spindle?.id == p.tool.id { return }
            steps += toolChangeSteps("Change to Tool \(n)", tool: p.tool, previous: fitted)
            fitted = p.tool
            let faced = p.touchZ < -1e-6 ? " The face was milled \(Length.mm(-p.touchZ)) mm down by an earlier program: touch off anywhere on the milled face (Coastline stores it as Z\(ReferenceBores.n(p.touchZ)))." : ""
            if pr.electrical {
                steps.append(step("Touch Off Tool \(n)", markdown: """
                In **Manual Operations**, jog the tool **2–5 mm above a solid spot of the face** (the frame, not over a cut).\(faced) Then close Manual Operations and click Next: the tool turns slowly backwards and creeps down until it touches.
                """, popup: ("Above the face?", "Is the tool 2–5 mm above solid stock?"), noStep: "-0"))
                steps.append(step("Probe Z for Tool \(n)", text: "Click Next to probe the face and store Z.", gcode: touchZFile(p.touchZ, electrical: true), timeout: 120))
            } else {
                steps.append(step("Touch Off Tool \(n) on the Face", markdown: """
                The stock isn't insulated in this setup, so the CR-1 can't feel the face: touch off by hand with paper.

                \(paperTouchOff("a solid spot of the stock face (the frame, not over a cut)", extra: faced.isEmpty ? "" : "\n\n" + faced))
                """, popup: ("Paper pinched?", "Is the paper just pinched between the tool and the stock face?"), noStep: "-0"))
                steps.append(step("Record Z0 for Tool \(n)", text: "Click Next to store this height\(abs(p.touchZ) < 1e-9 ? " as Z0" : "") .", gcode: touchZFile(p.touchZ, electrical: false)))
            }
            spindle = p.tool
        }
        /// X0 Y0 after a clamping: the edges (electrically with the tool in the spindle, or
        /// with the edge finder).
        func findEdges(side: Int, first k: Int) {
            let lower = pr.lowerXReachable[min(side, 1)], upper = pr.upperXReachable[min(side, 1)]
            // Side B: turned about the vertical in the same clamps, so it sits where side A
            // did. The machine can bring the tool or finder close; the edges are still found.
            let lastZ = side == 1 ? i.programs[..<k].last?.tool : nil
            if pr.electrical {
                installTool(k + 1, i.programs[k])
                // Z0 was just probed on this face with this tool.
                let near = side == 1 ? Approach(centre: .zero, size: size, zShift: 0) : nil
                steps += electricalEdgeSteps(i, side: side, lower: lower, upper: upper, tool: i.programs[k].tool, approach: near, files: &files)
            } else {
                let near = lastZ.map { Approach(centre: .zero, size: size, zShift: EdgeFinding.tool.stickout - $0.stickout) }
                steps += edgeFindSteps(machine: machine, lower: lower, upper: upper, height: size.x, previous: fitted, approach: near,
                                       tag: "s\(side)", files: &files)
                spindle = nil
                fitted = EdgeFinding.tool
            }
        }

        findEdges(side: 0, first: 0)
        for (k, p) in i.programs.enumerated() {
            let n = k + 1
            if p.side == 1 && (k == 0 || i.programs[k - 1].side == 0) {
                steps.append(step("Flip the Stock", markdown: """
                Side A is done. Vacuum the chips from the stock, clamps and table\(pr.bores != nil ? ", and out of the two reference bores in the frame" : "").

                1. Loosen the clamp screw and slide the stock out sideways (slide the kit along the T-slots, clear of the spindle, if it's in the way).
                2. **Turn the stock front-to-back** about its vertical axis. The face that was against the parallels now faces the spindle, and the end that was on the left is now on the right.
                3. Slide it back in from the side, on the same bottom edge on the lower jaw, with the same parallels behind it, face \(Length.mm(i.protrusion)) mm past the jaws. Slide the kit back if you moved it, and tighten the clamp screw.

                The part is still joined to the uncut frame between the sides, so the frame stays rigid and clamps exactly like before.\(pr.bores != nil ? " Side B's edges give a first zero; the reference bores then set the exact one." : "")
                """, image: i.flipImage == nil ? "" : "Image/flip.png", gcode: "Code/tool_change_position.nc", timeout: 90,
                popup: ("Flipped and clamped?", "Is the stock turned front-to-back, on the same bottom edge, and clamped tight?")))
                spindle = nil
                findEdges(side: 1, first: k)
            }
            let cutPath = "Code/T\(n)_cut.nc"
            let airPath = "Code/T\(n)_aircut.nc"
            files[cutPath] = Data(p.gcode.utf8)
            files[airPath] = Data(AirCut.make(from: p.gcode).utf8)
            installTool(n, p)
            if let probe = p.surfaceProbe {
                let probePath = "Code/T\(n)_surface.nc"
                files[probePath] = Data(probe.utf8)
                let count = probe.components(separatedBy: "M111").count - 1
                steps.append(step("Probe the Surface", markdown: """
                The engraving follows the real face, not the CAD: the tool feels it at **\(count) points** over the text. It turns slowly backwards and creeps down at each one until it touches (the stock is insulated in the clamp kit; the probe wire stays on the clamp).

                The points go into CRWrite's contour map (M111); the engraving turns the compensation on (M112), so its depth stays the same everywhere, even on a face that isn't quite flat or square.
                """, gcode: probePath, timeout: 240,
                popup: ("Wire on the clamp?", "Is the probe wire plugged in and fixed to the clamp, and the tool clean?")))
            }
            steps.append(step("Air Cut First?", markdown: """
            The first time you run a program, run it **10 mm above the stock with the spindle off**. Watch that every move goes where you expect.
            """, popup: ("Run an air cut?", "Run program \(n) as an air cut first? Choose No to skip straight to cutting."), noStep: "+2"))
            steps.append(step("Air Cut · Program \(n)", text: "The tool moves 10 mm above the work with the spindle off.", gcode: airPath))
            let refNote: String = switch p.reference {
            case .bores?: "\n\nThis program also bores **two reference holes** in the frame (⌀\(ReferenceBores.n(ReferenceBores.diameter)) mm, \(Length.mm(pr.bores?.depthA ?? 0)) mm deep). Side B finds its zero from them: keep them clean."
            case .windows?: "\n\nIt opens the two **reference bores** from this side (⌀\(ReferenceBores.n(ReferenceBores.windowDiameter)) mm windows, \(Length.mm(pr.bores?.windowDepth ?? 0)) mm deep) so they can be found next."
            case nil: ""
            }
            steps.append(step("Cut · Program \(n)", markdown: """
            **\(p.operationNames.joined(separator: " → "))** with \(p.tool.name). About \(Int(p.minutes.rounded())) minutes.\(refNote)

            \(i.material.chips)
            """, gcode: cutPath))
            steps.append(step("Clear the Chips", markdown: """
            Vacuum the chips from the stock, clamps and table\(p.reference == .windows ? ", and out of both reference bores (a chip in a bore throws the probing off)" : ""). Never use compressed air: it drives chips into the CR-1's bearings.
            """))
            if p.reference == .windows, let plan = pr.bores {
                steps += borePickupSteps(plan, tool: p.tool, electrical: pr.electrical, files: &files)
                if !pr.electrical { spindle = nil }
            }
            for c in i.checkpoints where c.afterProgram == k {
                steps += checkpointSteps(c, measuring: i.measuring)
            }
        }
        let twoSided = i.programs.contains { $0.side == 1 }
        let free: String
        if let t = i.tabs {
            free = "cut the part free. It hangs in the frame on **\(t.count) small tabs** (\(Length.mm(t.width)) mm wide, \(Length.mm(t.height)) mm thick): cut each one close to the part with a jeweller's saw\(i.material.family == .wax || i.material.family == .plastic ? " or flush cutters" : ""), then file and sand the stubs flush"
        } else if twoSided {
            free = "saw through the thin web to free the part, then file the web marks flush"
        } else {
            free = "deburr the part"
        }
        steps.append(step("Done", markdown: """
        Home the machine, unclamp the stock and \(free).

        **Finishing**
        \(FinishingGuide.steps(for: i.material).map { "- " + $0 }.joined(separator: "\n"))

        Log the result in Coastline's job journal: measured sizes, finish and any chatter. Coastline uses them to tune the next job.
        """, gcode: "Code/home.nc"))
        job.steps = steps
        return job
    }

    /// Edge finding to the stock centre in X and Y, as Coast Runner's cutcodes do it:
    /// store both edges in G55/G56, then M100 puts their midpoint into G54. The edge finder's
    /// radius cancels out in the midpoint. An X edge out of the CR-1's reach: X0 from the other
    /// edge and the stock's height instead.
    static func edgeFindSteps(machine: MachineProfile, note: String = "", lower: Bool = true, upper: Bool = true,
                              height: Double = 0, previous: Tool? = nil, approach: Approach? = nil, tag: String = "",
                              files: inout [String: Data]) -> [Step] {
        var s: [Step] = []
        let finder = EdgeFinding.tool
        let r = finder.diameter / 2
        if previous.map(EdgeFinding.isEdgeFinder) != true {
            s += toolChangeSteps("Fit the Edge Finder", tool: finder, previous: previous,
                                 note: "The stock was just clamped, so its edges are found again: everything after this works from them. The **Fisher edge finder** spins at \(Int(machine.probeSpindleRPM)) RPM while you search. \(note)")
        } else if !note.isEmpty {
            s.append(step("Edge Finder Still In", markdown: "The edge finder is still in the spindle. \(note)"))
        }
        s.append(step("Start the Edge Finder", text: "Click Next to spin the edge finder.", gcode: "Code/edgefinder_spin.nc"))
        /// The machine's move near an edge (when the stock's place is known), then the pair.
        func edge(_ title: String, _ where_: String, _ store: String, axis: Int, side: Double) {
            if let a = approach {
                let file = "Code/near_\(tag)_\(axis == 0 ? "x" : "y")\(side < 0 ? "lo" : "hi").nc"
                files[file] = Data(a.program(axis: axis, side: side, radius: r).utf8)
                s.append(step("Move Near the \(title)", markdown: "Click Next: the CR-1 drives the spinning finder to about 4 mm outside \(where_), 6 mm in front of the face, from where the stock should be. It can't feel the edge: if the stock sits elsewhere, stop and jog instead.",
                              gcode: file, timeout: 60))
            }
            s += edgePair(title, where_, store, nearby: approach != nil)
        }
        if lower && upper {
            edge("Lower Edge (X)", "the **lower** edge of the stock", "Code/store_x_low.nc", axis: 0, side: -1)
            edge("Upper Edge (X)", "the **upper** edge of the stock", "Code/store_x_high.nc", axis: 0, side: 1)
            s.append(step("Centre in X", text: "Click Next to set X0 halfway between the two edges.", gcode: "Code/set_x_centre.nc"))
        } else {
            let useLower = lower
            let name = useLower ? "x_from_lower.nc" : "x_from_upper.nc"
            files["Code/" + name] = Data(ReferenceBores.singleEdgeProgram(axis: "X", toward: useLower ? 1 : -1, edgeAt: (useLower ? -1 : 1) * height / 2,
                                                                         radius: EdgeFinding.tool.diameter / 2, electrical: false).utf8)
            s.append(step("Find the \(useLower ? "Lower" : "Upper") Edge (X)", markdown: """
            The \(useLower ? "upper" : "lower") edge is **out of the CR-1's reach** in this clamping, so X0 comes from the \(useLower ? "lower" : "upper") edge and the stock's height, **\(Length.mm(height)) mm** (measure it: if it differs, the part shifts by half the difference).

            \(edgeFinding("the **\(useLower ? "lower" : "upper")** edge"))
            """, popup: ("Edge found?", "Has the edge finder just clicked off-centre at the edge, in 0.01 mm steps?"), noStep: "-0"))
            s.append(step("Set X0 from the Edge", text: "Click Next to set X0 half the stock's height from this edge.", gcode: "Code/" + name))
        }
        edge("Left Edge (Y)", "the **left** edge of the stock", "Code/store_y_left.nc", axis: 1, side: -1)
        edge("Right Edge (Y)", "the **right** edge of the stock", "Code/store_y_right.nc", axis: 1, side: 1)
        s.append(step("Centre in Y", text: "Click Next to set Y0 halfway between the two edges.", gcode: "Code/set_y_centre.nc"))
        s.append(step("Stop the Spindle", text: "Click Next to stop the edge finder.", gcode: "Code/spindle_stop.nc"))
        return s
    }

    static func edgeFindSteps(machine: MachineProfile, note: String = "", previous: Tool? = nil) -> [Step] {
        var unused: [String: Data] = [:]
        return edgeFindSteps(machine: machine, note: note, previous: previous, files: &unused)
    }

    /// The same with electrical probing: jog the tool beside each edge, Next probes toward it.
    static func electricalEdgeSteps(_ i: Input, side: Int, lower: Bool, upper: Bool, tool: Tool, approach: Approach? = nil,
                                    files: inout [String: Data]) -> [Step] {
        var s: [Step] = []
        let d = max(min(1.0, i.protrusion - 0.6), 0.3)
        let depth = ReferenceBores.n(d)
        func edge(_ title: String, _ where_: String, axis: String, toward: Double, file: String, program: String) {
            files[file] = Data(program.utf8)
            if let a = approach {
                // The stock is where it was: the CR-1 brings the tool beside the edge itself.
                let near = file.replacingOccurrences(of: ".nc", with: "_near.nc")
                files[near] = Data(a.probeProgram(axis: axis == "X" ? 0 : 1, side: -toward, radius: tool.diameter / 2, depth: d).utf8)
                s.append(step("Move Beside the \(title)", markdown: "Click Next: the CR-1 brings the tool to about 3 mm outside \(where_) and creeps down to \(depth) mm below the face. It stops if it touches the stock on the way.",
                              gcode: near, timeout: 60))
                s.append(step("Check the Position", markdown: "The probe light should be **off** and the tool beside the edge, not on the face.",
                              popup: ("In position?", "Is the tool about 3 mm from the edge, \(depth) mm below the face, not touching? (No: jog it there by hand, then answer again.)"), noStep: "-0"))
            } else {
                s.append(step("Beside the \(title)", markdown: """
                In **Manual Operations**, with the spindle stopped, jog the tool to about **3 mm outside \(where_)**, about **\(depth) mm below the face** (so its side, not its tip, will touch): 1 mm steps, then 0.1 mm as you get close. Close Manual Operations.
                """, popup: ("In position?", "Is the tool about 3 mm from the edge, \(depth) mm below the face, not touching?"), noStep: "-0"))
            }
            s.append(step("Probe the \(title)", text: "Click Next: the tool turns slowly backwards and creeps toward the edge until it touches.", gcode: file, timeout: 120))
        }
        let sideTag = side == 0 ? "A" : "B"
        if lower && upper {
            edge("Lower Edge (X)", "the stock's **lower** edge", axis: "X", toward: 1, file: "Code/probe\(sideTag)_x_low.nc",
                 program: ReferenceBores.edgeProgram(axis: "X", toward: 1, store: 2))
            edge("Upper Edge (X)", "the stock's **upper** edge", axis: "X", toward: -1, file: "Code/probe\(sideTag)_x_high.nc",
                 program: ReferenceBores.edgeProgram(axis: "X", toward: -1, store: 3))
            s.append(step("Centre in X", text: "Click Next to set X0 halfway between the two edges.", gcode: "Code/set_x_centre.nc"))
        } else {
            let useLower = lower
            edge("\(useLower ? "Lower" : "Upper") Edge (X)",
                 "the stock's **\(useLower ? "lower" : "upper")** edge (the other one is out of the CR-1's reach: X0 comes from this edge and the stock's height, \(Length.mm(i.stockSize.x)) mm)",
                 axis: "X", toward: useLower ? 1 : -1, file: "Code/probe\(sideTag)_x_single.nc",
                 program: ReferenceBores.singleEdgeProgram(axis: "X", toward: useLower ? 1 : -1, edgeAt: (useLower ? -1 : 1) * i.stockSize.x / 2,
                                                           radius: tool.diameter / 2, electrical: true))
        }
        edge("Left Edge (Y)", "the stock's **left** end", axis: "Y", toward: 1, file: "Code/probe\(sideTag)_y_left.nc",
             program: ReferenceBores.edgeProgram(axis: "Y", toward: 1, store: 2))
        edge("Right Edge (Y)", "the stock's **right** end", axis: "Y", toward: -1, file: "Code/probe\(sideTag)_y_right.nc",
             program: ReferenceBores.edgeProgram(axis: "Y", toward: -1, store: 3))
        s.append(step("Centre in Y", text: "Click Next to set Y0 halfway between the two ends.", gcode: "Code/set_y_centre.nc"))
        return s
    }

    /// Side B's exact zero from side A's reference bores (after the windows are open).
    static func borePickupSteps(_ plan: ReferenceBores.Plan, tool: Tool, electrical: Bool, files: inout [String: Data]) -> [Step] {
        var s: [Step] = []
        let b = plan.centresB
        s.append(step("Reference Bores", markdown: """
        Side A bored two ⌀\(ReferenceBores.n(ReferenceBores.diameter)) mm holes in the frame from the same zero as the part, and side B just opened them. Their centres are found now and **X0 Y0 is set from them**: side B then lines up with side A to a few hundredths, whatever the stock's edges are like.

        Bore 1 is at X\(ReferenceBores.n(b[0].x)) Y\(ReferenceBores.n(b[0].y)), bore 2 at X\(ReferenceBores.n(b[1].x)) Y\(ReferenceBores.n(b[1].y)) (side B). Each bore's diameter, their spacing and the line between them are checked: if anything is off (a chip, a wrong flip, the stock seated crooked) the step stops with a message instead of cutting.
        """))
        if electrical {
            for k in 0..<2 {
                let file = "Code/B_bore\(k + 1).nc"
                files[file] = Data(ReferenceBores.boreProgram(plan, bore: k, toolDiameter: tool.diameter, electrical: true).utf8)
                s.append(step("Find Bore \(k + 1)", markdown: """
                Click Next: the tool goes down into bore \(k + 1) (\(ReferenceBores.n(-plan.probeZ)) mm deep) and touches its wall four times, turning slowly backwards.
                """, gcode: file, timeout: 300))
            }
        } else {
            s.append(step("Install the Edge Finder", markdown: """
            The spindle moves to the tool-change position. Take the tool out and fit the **Fisher edge finder**: it finds the bores' walls.
            """, gcode: "Code/tool_change_position.nc", timeout: 90))
            for k in 0..<2 {
                let over = "Code/B_over_bore\(k + 1).nc"
                files[over] = Data("G21 G90\nG53 G0 Z-1\nG54 G0 X\(ReferenceBores.n(b[k].x)) Y\(ReferenceBores.n(b[k].y))\nG0 Z3\n".utf8)
                s.append(step("Over Bore \(k + 1)", text: "Click Next to bring the edge finder over bore \(k + 1).", gcode: over, timeout: 120))
                s.append(step("Start the Edge Finder", text: "Click Next to spin the edge finder.", gcode: "Code/edgefinder_spin.nc"))
                s.append(step("Into Bore \(k + 1)", markdown: """
                In **Manual Operations**, lower the edge finder into the bore to about **Z\(ReferenceBores.n(plan.probeZ))**, its tip below the wider window, in the bore's own wall.
                """, popup: ("In the bore?", "Is the edge finder's tip down in the narrow bore, not touching?"), noStep: "-0"))
                for axis in ["X", "Y"] {
                    let plus = "Code/B_wall_\(axis)p.nc", minus = "Code/B_wall_\(axis)m.nc"
                    files[plus] = Data(ReferenceBores.storeWall(axis: axis, positive: true).utf8)
                    files[minus] = Data(ReferenceBores.storeWall(axis: axis, positive: false).utf8)
                    for (sign, file) in [("+", plus), ("−", minus)] {
                        s.append(step("Bore \(k + 1): \(sign)\(axis) Wall", markdown: """
                        Step toward the bore's **\(sign)\(axis)** wall (0.1 mm, then 0.01 mm moves) until the edge finder **kicks off-centre**.
                        """, popup: ("Wall found?", "Has the edge finder just kicked at the \(sign)\(axis) wall?"), noStep: "-0"))
                        s.append(step("Record the \(sign)\(axis) Wall", text: "Click Next to store this position.", gcode: file))
                    }
                    let centre = "Code/B_bore\(k + 1)_\(axis).nc"
                    files[centre] = Data((ReferenceBores.storeCentre(bore: k, axis: axis, toolDiameter: EdgeFinding.tool.diameter)
                                          + "G\(k == 0 ? 55 : 56) G0 \(axis)0\n").utf8)
                    s.append(step("Bore \(k + 1): Centre in \(axis)", text: "Click Next to store the centre in \(axis) and move there.", gcode: centre))
                }
                files["Code/B_up.nc"] = Data("G53 G0 Z-1\n".utf8)
                s.append(step("Up Out of Bore \(k + 1)", text: "Click Next to raise the edge finder.", gcode: "Code/B_up.nc"))
            }
            s.append(step("Stop the Spindle", text: "Click Next to stop the edge finder.", gcode: "Code/spindle_stop.nc"))
        }
        files["Code/B_bores_zero.nc"] = Data(ReferenceBores.zeroProgram(plan).utf8)
        s.append(step("Set X0 Y0 from the Bores", markdown: """
        Click Next to check the two centres against each other and set X0 Y0 from them. The tool then stands over bore 1 at the top of its travel.
        """, gcode: "Code/B_bores_zero.nc", timeout: 120))
        return s
    }

    /// Edge finding by hand (manual §4.6.1): 1 → 0.1 → 0.01 mm steps, backing off between.
    static func edgeFinding(_ where_: String, nearby: Bool = false) -> String {
        """
        In **Manual Operations**:
        1. \(nearby ? "Jog toward the stock (−Z) about 7.5 mm, so the tip is 1.5 mm below the face beside the edge." : "Bring the spinning edge finder beside \(where_), its tip about 1.5 mm below the face (its side touches, not its end).")
        2. Jog toward the edge in 1 mm steps until it **clicks** and kicks off-centre.
        3. Back off 1 mm, then jog in 0.1 mm steps until it clicks again.
        4. Back off 0.1 mm, then jog in 0.01 mm steps until it just clicks. Stop there.
        """
    }

    private static func edgePair(_ title: String, _ where_: String, _ store: String, nearby: Bool = false) -> [Step] {
        [
            step("Find the \(title)", markdown: edgeFinding(where_, nearby: nearby),
                 popup: ("Edge found?", "Has the edge finder just clicked off-centre at the edge, in 0.01 mm steps?"), noStep: "-0"),
            step("Record the \(title)", text: "Click Next to store this position.", gcode: store),
        ]
    }

    /// Measure, then a yes/no. No goes to a step with advice, which loops back to measuring.
    static func checkpointSteps(_ c: Checkpoint, measuring: [MeasuringTool]) -> [Step] {
        let instrument = measuring.first { [.micrometer, .caliper].contains($0.kind) }?.name ?? "a caliper (add one to your inventory)"
        let low = Length.mm(c.expected - c.tolerance), high = Length.mm(c.expected + c.tolerance)
        return [
            step("Measure · \(c.what)", markdown: """
            With **\(instrument)**, measure \(c.what.lowercased()).

            **Expected** \(Length.mm(c.expected)) mm (between \(low) and \(high) mm).
            """, popup: ("In tolerance?", "Is \(c.what.lowercased()) between \(low) and \(high) mm?"), noStep: "+1", yesStep: "+2"),
            step("Out of Tolerance", markdown: """
            Don't unclamp the stock.

            - **Too big**: the tool may be deflecting or worn. Re-run the finishing program (it removes only what's left), or add a spring pass.
            - **Too small**: check the tool's real diameter and stick-out, and the touch-off.

            Note the measurement for the job journal, then measure again.
            """, goTo: "-1"),
        ]
    }

    // MARK: Stock squaring

    /// Squares sawn stock before the part setup: face A, flip and face B to thickness, then the
    /// two long edges. Each face is a facing program generated here (no part geometry needed).
    static func squaringJob(_ i: Input, machine: MachineProfile, files: inout [String: Data]) -> Job {
        var job = Job(title: "Square the Stock", prompt: "Sawn stock isn't flat or square. Face it on all sides first so every setup has true datums.")
        let a = i.faceAllowance
        let s = i.stockSize
        let facer = i.programs.first?.tool
        var steps: [Step] = [step("Why Square the Stock", markdown: """
        Sawn faces are rough and not square. Facing them gives flat, parallel datums, so the part comes out true and measurements mean something.

        Coastline faces \(Length.mm(a)) mm off each side: the stock becomes **\(Length.mm(s.x - 2 * a)) × \(Length.mm(s.y)) × \(Length.mm(s.z - 2 * a)) mm**.
        """)]
        guard let tool = facer else { job.steps = steps; return job }
        let data = FeedsEngine.compute(tool: tool, material: i.material, kind: .facing, machine: machine)
        let faces: [(String, SIMD2<Double>, String)] = [
            ("Face A (front)", SIMD2(s.x, s.y), "Clamp the stock as it will sit for the part, sawn face toward the spindle."),
            ("Face B (back, to thickness)", SIMD2(s.x, s.y), "Flip the stock front-to-back so face A sits against the table side of the clamp."),
            ("Edge C (top edge)", SIMD2(s.z, s.y), "Turn the stock so its top edge faces the spindle, with face A against the clamp's fixed jaw."),
            ("Edge D (bottom edge, to height)", SIMD2(s.z, s.y), "Flip it so edge C sits down in the clamp and edge D faces the spindle."),
        ]
        steps.append(step("Home the Machine", text: "Click Next to home all axes.", gcode: "Code/home.nc", timeout: 60))
        for (k, f) in faces.enumerated() {
            let path = "Code/square_\(k + 1).nc"
            let g = FacingProgram.make(width: f.1.x, length: f.1.y, depth: a, tool: tool, data: data, machine: machine,
                                       title: "Square the stock: \(f.0)")
            files[path] = Data(g.utf8)
            steps.append(step("Mount for \(f.0)", markdown: f.2 + "\n\nClean the clamp and table first: a chip under the stock tilts it.",
                              popup: ("Mounted?", "Is the stock clamped with \(f.0.lowercased()) toward the spindle?")))
            steps += edgeFindSteps(machine: machine, previous: k == 0 ? nil : tool)
            steps += toolChangeSteps("Fit the Facing Tool", tool: tool, previous: EdgeFinding.tool)
            steps.append(step("Touch Off on \(f.0)", markdown: paperTouchOff("the highest point of the face"),
                              popup: ("Paper pinched?", "Is the paper just pinched at the highest point of the face?"), noStep: "-0"))
            steps.append(step("Record Z0", text: "Click Next to store this height as Z0.", gcode: "Code/store_z.nc"))
            steps.append(step("Face \(f.0)", text: "Faces \(Length.mm(a)) mm off.", gcode: path))
            steps.append(step("Clear the Chips", text: "Vacuum the chips (never compressed air)."))
        }
        steps += checkpointSteps(Checkpoint(afterProgram: -1, what: "Stock thickness", expected: s.z - 2 * a, tolerance: 0.05), measuring: i.measuring)
        steps.append(step("Squared", markdown: "Update the stock in Coastline's inventory to **milled square**, \(Length.mm(s.x - 2 * a)) × \(Length.mm(s.y)) × \(Length.mm(s.z - 2 * a)) mm, then continue with the part job."))
        job.steps = steps
        return job
    }

    /// Squares and sizes oversized bar stock flat on the squaring stop (FlatPrep), the way Coast
    /// Runner's Universal Clamp cutcode does: riser plate, one acetal stop, two 3" C-clamps over
    /// the table's back edge. Every time the bar is clamped differently, its edges are found and
    /// the tool touched off again.
    static func millDownJob(_ i: Input, _ m: MillDown, machine: MachineProfile, files: inout [String: Data]) -> Job {
        let (plan, items) = m.programs(material: i.material, sawn: i.squareStockFirst, machine: machine)
        let shoulders = m.shoulderLength
        var job = Job(title: shoulders == nil ? "Square and Size the Stock" : "Mill the Shoulders",
                      prompt: shoulders.map { "The part is taller than the clamp kit grips. Mill a \(Length.mm($0)) mm long shoulder at each end of the bar down to \(Length.mm(m.target)) mm, flat on the squaring stop: the clamps grip those." }
                        ?? "The stock is too big for the clamp kit. Square it and mill it down to \(Length.mm(m.target)) mm, flat on the squaring stop.")
        for (k, it) in items.enumerated() {
            files["Code/prep_\(k + 1).nc"] = Data(it.gcode.utf8)
            files["Code/prep_\(k + 1)_aircut.nc"] = Data(AirCut.make(from: it.gcode).utf8)
        }
        if let img = m.image { files["Image/mill_down.png"] = img }
        let t = plan.thickness, w = plan.width
        let notes = plan.issues.map { "- \($0.message)" }.joined(separator: "\n")
        let why = shoulders.map { ls in "The clamp kit holds stock up to \(Length.mm(UniversalClamp.onJaw(softJaw: false).upperBound)) mm tall, and the part with its frame needs the bar's full \(Length.mm(w)) mm. So only the ends are milled down: a **\(Length.mm(ls)) mm shoulder at each end**, \(Length.mm(plan.cut)) mm off the edge there\(plan.faceEnds ? ", after facing one sawn end square so it can register against the stop" : ""). The universal clamps grip the shoulders; the full-height middle carries the part above the jaws." }
            ?? "The clamp kit holds stock up to \(Length.mm(UniversalClamp.onJaw.upperBound)) mm tall. This bar is \(Length.mm(w)) mm, so \(Length.mm(plan.cut)) mm comes off one long edge\(plan.faceEnds ? ", after facing the sawn ends square so one of them can register against the stop" : "")."
        var steps: [Step] = [step(shoulders == nil ? "Why Square and Size It" : "Why Shoulders", markdown: """
        \(why)

        The stop is bolted into the T-slots, so its spindle-side face can't move back. The bar always **sticks out past the stop's face** by the depth being cut plus \(Length.mm(FlatPrep.stopClearance)) mm: the tool never comes near the stop, the riser or the clamps.

        \(notes)

        **Next time, buy stock about \(Length.mm(m.target)) × \(Length.mm(plan.finalLength)) × \(Length.mm(t)) mm.** It is usually cheaper and much quicker than milling it down.
        """)]
        steps.append(step("Home the Machine", text: "Click Next to home all axes.", gcode: "Code/home.nc", timeout: 60))
        if let saw = plan.sawLength {
            steps.append(step("Saw to Length", markdown: """
            Mark **\(Length.mm(saw)) mm** from one end of the bar and saw it off as squarely as you can (a mitre box helps). Deburr the cut and keep the offcut: add it back to Coastline's inventory.

            Only a piece this short sits fully on the table with its end toward the spindle, where the C-clamps can reach around the table's back edge.
            """, popup: ("Sawn?", "Is the \(Length.mm(saw)) mm piece cut off and deburred?")))
        }
        steps.append(step("Install the Squaring Stop", markdown: """
        Take the clamp kit off the table. Put a T-slot nut in each T-slot near the left end and bolt **one acetal squaring stop** across both slots (M4x25 bolts), its notched hole toward the spindle. Slide it about 25 mm from the left wall.

        Square it to the Y travel before tightening: jog the spindle (no tool) along the stop's right face, or check it with a square against the table's spindle-side edge. Then tighten both bolts.

        Its spindle-side face sits level with the table's edge. The riser plate always goes **just behind that face** (0.5 mm back), so the bar overhangs the riser by the same amount it sticks out past the stop.
        """))
        for (k, it) in items.enumerated() {
            let s = it.stage, p = it.placement
            let behind = p.stockFaceZ - (p.clampPoints.first?.z ?? p.stockFaceZ)
            let clamps = p.clampAngles.contains(where: { $0 != 0 })
                ? "The bar reaches past the bed's back edge, so **turn the two 3\" C-clamps about 45° each way**: pads on the bar near its sides, about \(Length.mm(behind.rounded())) mm back from its spindle-side face, the frames swinging out beside the bar to the bed's back edge, fixed jaws under the bed. Snug, not crushing."
                : "Two 3\" C-clamps over the table's back edge: the swivel pad on the bar **about \(Length.mm(behind.rounded())) mm back from its spindle-side face** (over the riser), the fixed jaw under the table plate. Snug, not crushing. Keep the clamp frames off the bar."
            let mount: String
            switch s.kind {
            case .faceEnd(0):
                mount = """
                Lay the bar **flat on the riser with its length pointing at the spindle**, an extruded long side against the stop's right face (extruded sides are straight; sawn ends are not). End A sticks out **\(Length.mm(s.protrusion)) mm** past the stop's spindle-side face.

                \(clamps)
                """
            case .faceEnd:
                mount = """
                Unclamp and **turn the bar end for end**: faced end A toward you, end B toward the spindle, the same long side against the stop. End B sticks out **\(Length.mm(s.protrusion)) mm** past the stop's face.

                \(clamps)
                """
            case .edge(let round, let of):
                if round == 0 && s.otherEdge {
                    mount = """
                    The top of the shoulders is done. Vacuum, loosen the C-clamps and **turn the bar over** so its **other long edge faces the spindle**, faced end A still against the stop. That edge's ends stick out **\(Length.mm(s.protrusion)) mm** past the stop's face: the bottom of the shoulders comes off now, so the middle hangs lower in the clamp kit.

                    \(clamps)
                    """
                } else if round == 0 {
                    mount = """
                    Lay the bar **flat along the table** on the riser, \(plan.faceEnds ? "**faced end A**" : "its squarest end") pushed against the stop's right face. The long edge to cut faces the spindle and sticks out **\(Length.mm(s.protrusion)) mm** past the stop's face (that's \(Length.mm(s.cut)) mm to cut plus \(Length.mm(FlatPrep.stopClearance)) mm clearance).

                    \(clamps)
                    """
                } else {
                    // After the last round the face sits `stopClearance` past the stop.
                    let slide = s.protrusion - FlatPrep.stopClearance
                    mount = """
                    Round \(round + 1) of \(of). Vacuum the chips, loosen the C-clamps and **slide the bar \(Length.mm(slide)) mm toward the spindle**, end A still against the stop, so the new edge sticks out **\(Length.mm(s.protrusion)) mm** past the stop's face again.

                    \(clamps)
                    """
                }
            }
            steps.append(step("Mount · \(s.title)", markdown: mount + "\n\nThe exact position doesn't matter: the next steps find the bar's real edges and face.",
                              image: m.image == nil ? "" : "Image/mill_down.png",
                              popup: ("Clamped?", "Is the bar flat on the riser, against the stop, sticking out \(Length.mm(s.protrusion)) mm and clamped tight?")))
            // After the first clamping the stop puts the bar back in a known place: relative to
            // the last zero, its new face centre is the change in size (one end and the bottom
            // stay on the stop and the riser) and in stand-out.
            var near: Approach?
            if k > 0 {
                let q = items[k - 1].stage, oq = k - 1 < m.overrides.count ? m.overrides[k - 1].stopShiftY : 0
                let o = k < m.overrides.count ? m.overrides[k].stopShiftY : 0
                near = Approach(centre: SIMD3((s.stock.x - q.stock.x) / 2, (s.stock.y - q.stock.y) / 2 + o - oq, s.protrusion - q.protrusion),
                                size: s.stock, zShift: EdgeFinding.tool.stickout - m.tool.stickout)
            }
            if k == 0 {
                steps.append(step("Finding the Stock on the Bed", markdown: bedFindingNote))
            }
            var edgeFiles: [String: Data] = [:]
            steps += edgeFindSteps(machine: machine, note: s.spans != nil && s.raised > 0.01
                                   ? "Touch the edges and the face on an END (a shoulder): the uncut middle stands \(Length.mm(s.raised)) mm higher."
                                   : "Touch the edges on the part that sticks out past the stop and the riser.",
                                   previous: k == 0 ? nil : m.tool, approach: near, tag: "prep\(k + 1)", files: &edgeFiles)
            files.merge(edgeFiles) { a, _ in a }
            steps += toolChangeSteps("Fit the \(m.tool.name.components(separatedBy: " · ").first ?? "Tool")", tool: m.tool, previous: EdgeFinding.tool)
            steps.append(step("Touch Off · \(s.title)", markdown: paperTouchOff("the highest point of the face toward the spindle"),
                              popup: ("Paper pinched?", "Is the paper just pinched between the tool and the face?"), noStep: "-0"))
            steps.append(step("Record Z0", text: "Click Next to store this height as Z0.", gcode: "Code/store_z.nc"))
            steps.append(step("Air Cut First?", markdown: "Run the program 10 mm off the face with the spindle off first, and watch it clear the stop and clamps.",
                              popup: ("Run an air cut?", "Run \(s.title.lowercased()) as an air cut first?"), noStep: "+2"))
            steps.append(step("Air Cut · \(s.title)", text: "The tool moves 10 mm off the face with the spindle off.", gcode: "Code/prep_\(k + 1)_aircut.nc"))
            let what = s.isEdge ? "Side-mills \(Length.mm(s.cut)) mm off the long edge in deep, light passes." : "Faces \(Length.mm(s.cut)) mm off the end, square to the long side."
            steps.append(step(s.title, markdown: "\(what) \(i.material.chips)", gcode: "Code/prep_\(k + 1).nc"))
            steps.append(step("Clear the Chips", text: "Vacuum the chips (never compressed air)."))
        }
        steps += checkpointSteps(Checkpoint(afterProgram: -1, what: m.shoulderLength == nil ? "Bar width" : "Height at each shoulder",
                                            expected: m.target, tolerance: 0.1), measuring: i.measuring)
        if let ls = shoulders {
            steps.append(step("Ready for the Clamp Kit", markdown: "Unclamp and deburr the shoulders. The bar is now **\(Length.mm(w)) mm** tall in the middle and **\(Length.mm(m.target)) mm** at its two \(Length.mm(ls)) mm shoulders. Take the stop off and refit the clamp kit, then continue with the next job: the clamps go on the shoulders."))
        } else {
            steps.append(step("Ready for the Clamp Kit", markdown: "Unclamp, deburr the new edge and update the stock in Coastline's inventory to **\(Length.mm(m.target)) × \(Length.mm(plan.finalLength)) × \(Length.mm(t)) mm**. Take the stop off and refit the clamp kit, then continue with the next job."))
        }
        job.steps = steps
        return job
    }

    // MARK: Step helper

    static func step(_ title: String, text: String = "", markdown: String = "", image: String = "", gcode: String = "",
                     timeout: UInt = 0, popup: (String, String)? = nil, noStep: String = "", yesStep: String = "",
                     goTo: String = "") -> Step {
        var s = Step(manifest: CRProject.rootManifest)
        s.title = clean(title)
        s.prompt = clean(text)
        s.markdown = safeMarkdown(markdown)
        s.imagePath = image
        s.gcodePath = gcode
        s.timeout = timeout
        if let popup {
            s.popupTitle = clean(popup.0)
            s.popupText = clean(popup.1)
        }
        s.popupNoStep = noStep
        s.popupYesStep = yesStep
        s.goTo = goTo
        return s
    }

    /// Scalars can't contain '#' (comment marker in the cutcode format).
    static func clean(_ s: String) -> String { s.replacingOccurrences(of: "#", with: "No.") }

    /// Markdown blocks end at any line that looks like `key: value`, and 3-character lines are
    /// skipped by CRWrite's parser. Make every line safe without changing what it says.
    public static func safeMarkdown(_ md: String) -> String {
        guard !md.isEmpty else { return "" }
        let keyLike = try! NSRegularExpression(pattern: #"^\s*[A-Za-z0-9_\-]+\s*:"#)
        return md.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            var line = String(raw)
            if keyLike.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { line = "› " + line }
            if line.count == 3 { line += " " }
            return line
        }.joined(separator: "\n")
    }
}

/// The air-cut copy of a program: spindle never starts, and every work-coordinate Z is lifted,
/// so the whole program can be watched safely above the stock.
public enum AirCut {
    public static func make(from gcode: String, lift: Double = 10) -> String {
        var out = ["(AIR CUT: spindle off, all moves \(CR1Post.fmt(lift)) mm above the work)"]
        for raw in gcode.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            let upper = line.uppercased()
            if upper.hasPrefix("(") { out.append(line); continue }
            if upper.contains("M3") || upper.contains("M4") || upper.range(of: #"^S\d"#, options: .regularExpression) != nil {
                out.append("(spindle start removed: " + line.replacingOccurrences(of: "(", with: "[").replacingOccurrences(of: ")", with: "]") + ")")
                continue
            }
            if !upper.contains("G53"), let r = line.range(of: #"Z(-?\d+(\.\d+)?)"#, options: .regularExpression) {
                let v = Double(line[r].dropFirst()) ?? 0
                line.replaceSubrange(r, with: "Z" + CR1Post.fmt(v + lift))
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}

/// A standalone facing program (zig-zag along Y), for stock squaring.
public enum FacingProgram {
    public static func make(width: Double, length: Double, depth: Double, tool: Tool, data: CuttingData,
                            machine: MachineProfile, title: String) -> String {
        CR1Post.program(header: .init(programName: title, setupName: "Squaring", tool: tool, operationNames: ["Facing"],
                                      stockDescription: "\(Length.mm(width)) × \(Length.mm(length)) mm face"),
                        rpm: data.rpm, paths: [OperationToolpath(operationID: UUID(), moves: moves(width: width, length: length, depth: depth, tool: tool, data: data))],
                        machine: machine)
    }

    /// The facing moves (work frame: X across the face's width, Y along its length).
    /// - yRange: where the tool centre travels along Y (default: past both ends). startHigh:
    ///   enter from its high end (the open end of a shoulder at +Y).
    public static func moves(width: Double, length: Double, depth: Double, tool: Tool, data: CuttingData,
                             yRange: ClosedRange<Double>? = nil, startHigh: Bool = false, safeZ: Double = 3) -> [Move] {
        let r = tool.diameter / 2
        var moves: [Move] = []
        let passes = max(1, Int((depth / max(data.stepdown, 0.05)).rounded(.up)))
        var y0 = yRange?.lowerBound ?? (-length / 2 - r - 1), y1 = yRange?.upperBound ?? (length / 2 + r + 1)
        if startHigh { swap(&y0, &y1) }
        var xs: [Double] = []
        var x = -width / 2 - r + data.stepover * 0.5
        while x - r < width / 2 { xs.append(x); x += data.stepover }
        for p in 1...passes {
            let z = -depth * Double(p) / Double(passes)
            moves.append(Move(.rapid, x: xs[0], y: y0, z: safeZ))
            moves.append(Move(.rapid, x: xs[0], y: y0, z: 1))
            moves.append(Move(.plunge, x: xs[0], y: y0, z: z, feed: data.plungeFeed))
            var forward = true
            for (k, xv) in xs.enumerated() {
                if k > 0 { moves.append(Move(.link, x: xv, y: forward ? y0 : y1, z: z, feed: data.feed)) }
                moves.append(Move(.cut, x: xv, y: forward ? y1 : y0, z: z, feed: data.feed))
                forward.toggle()
            }
            moves.append(Move(.rapid, x: xs.last!, y: forward ? y0 : y1, z: safeZ))
        }
        return moves
    }
}
