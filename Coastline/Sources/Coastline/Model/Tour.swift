import CoastlineCore
import Foundation

/// The guided tour: what to do at the machine for each job step, the measuring checkpoints with
/// what to do when out of tolerance, the finishing guide, and an auto-playing walk through it all.
extension AppModel {
    /// The step on screen: the one the playhead is at, else the one last chosen.
    var currentStep: JobStep? {
        let steps = jobSteps
        if let s = steps.first(where: isActive) { return s }
        if let id = selectedStep?.id { return steps.first { $0.id == id } }
        return steps.first
    }

    /// The playhead is in edge finding with the Fisher edge finder: at the machine that's all by
    /// hand (jogging until the finder kicks, storing each edge), the animation only shows it.
    var manualEdgeFindingNow: Bool {
        guard showsMachiningResults, !timeline.entries.isEmpty else { return false }
        let e = timeline.entries[min(max(timeline.index(at: playhead), 0), timeline.entries.count - 1)]
        return e.program >= 2000 && plannedTools.indices.contains(e.operation) && plannedTools[e.operation].id == EdgeFinding.tool.id
    }

    func step(after s: JobStep, by delta: Int) -> JobStep? {
        let steps = jobSteps
        guard let i = steps.firstIndex(where: { $0.id == s.id }) else { return nil }
        let j = i + delta
        return steps.indices.contains(j) ? steps[j] : nil
    }

    /// Shows a step and frames it, always from the front, where you stand at the machine (never
    /// round the back from the spindle's side, however much better the cut face shows there).
    func visit(_ step: JobStep) {
        go(to: step)
        setView(.iso)
        focusWork()
    }

    // MARK: Tour

    func startTour() {
        tourTask?.cancel()
        touring = true
        let steps = jobSteps
        let from = currentStep.flatMap { s in steps.firstIndex { $0.id == s.id } } ?? 0
        tourTask = Task { @MainActor [weak self] in
            for step in steps[from...] {
                guard let self, !Task.isCancelled, self.touring else { return }
                self.visit(step)
                try? await Task.sleep(for: .milliseconds(1300))  // the stock moving, the camera
                if step.kind == .program, let p = step.program,
                   let first = self.timeline.entries.first(where: { $0.program == p }),
                   let last = self.timeline.entries.last(where: { $0.program == p }) {
                    // Play the program through in about four seconds.
                    for k in 1...40 {
                        guard !Task.isCancelled, self.touring else { return }
                        self.advanceSpin(0.1)
                        self.seek(first.tStart + (last.tEnd - first.tStart) * Double(k) / 40)
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    try? await Task.sleep(for: .milliseconds(700))
                } else {
                    try? await Task.sleep(for: .milliseconds(2600))
                }
            }
            self?.touring = false
        }
    }

    func stopTour() {
        touring = false
        tourTask?.cancel()
    }

    // MARK: What to do

    /// The step's instructions, short and in order (the guided .crproj has the long form).
    func instructions(for step: JobStep) -> [String] {
        let material = stock?.material
        switch step.kind {
        case .prepSetup where step.stage < 0:
            guard let plan = flatPrepPlan, let stock else { return [] }
            var out = ["\(material?.name ?? "Stock"), \(Length.mm(plan.width)) × \(Length.mm(plan.length)) × \(Length.mm(plan.thickness)) mm as bought (\(stock.finish.title.lowercased()))."]
            out.append(stock.extrusionAxis == nil
                       ? "Extruded bar is straight and square along its length; its sawn ends aren't. (Set \"Extruded along\" in the stock's details if it's not the longest side.)"
                       : "Straight and square along the extrusion (\(Length.mm(stock.extrusionLength)) mm); the sawn ends across it get faced.")
            out.append("Too tall for the clamp kit as it is, so it's worked flat on the bed first: one acetal stop, the riser plate, two 3\" C-clamps.")
            if let saw = plan.sawLength { out.append("First saw a \(Length.mm(saw)) mm piece off and keep the rest as a remnant.") }
            out.append("Next time, buy about \(Length.mm(plan.target)) × \(Length.mm(plan.finalLength)) × \(Length.mm(plan.thickness)) mm: no prep at all.")
            return out
        case .prepSetup:
            guard let st = prepStage(at: step.stage) else { return [] }
            let p = prepPlacement(st)
            let behind = p.stockFaceZ - (p.clampPoints.first?.z ?? p.stockFaceZ)
            var out: [String]
            switch st.kind {
            case .faceEnd(0): out = ["Bar flat on the riser, its length pointing at the spindle, an extruded long side against the stop."]
            case .faceEnd: out = ["Unclamp and turn the bar end for end: end B toward the spindle, the same side on the stop."]
            case .edge(0, _): out = ["Bar flat along the table, faced end A pushed against the stop, the long edge toward the spindle."]
            case .edge: out = ["Vacuum, loosen the clamps and slide the bar \(Length.mm(st.cut)) mm toward the spindle, end A still on the stop."]
            }
            out.append("Its face sticks out **\(Length.mm(st.protrusion)) mm** past the stop's face; the riser stays just behind the stop's face.")
            out.append(p.clampAngles.contains(where: { $0 != 0 })
                       ? "It reaches past the bed's back edge: turn the C-clamps about 45° each way, pads on the bar near its sides about \(Length.mm(behind.rounded())) mm back from the face, frames beside the bar."
                       : "Two C-clamps over the table's back edge, pads about \(Length.mm(behind.rounded())) mm back from the face, frames touching the bed's edge.")
            out.append("**Edge finding is by hand** here: jog the spinning Fisher edge finder to each edge in CRWrite's Manual Operations until it kicks, and store it. The animation only shows the order.")
            return out
        case .program where (step.program ?? 0) >= 2000 && step.side >= 0 && !setup.onBed && AppSettings.shared.clampKitProbing == .electrical:
            return [
                "**Automatic:** the clamp kit is insulated, so the cutter itself finds the edges: it turns slowly backwards and creeps in until it touches (G38.2), then backs off.",
                "Plug the probe wire into the LED board and fix it to the clamp first.",
                "Lower and upper edge (X), left and right edge (Y): CRWrite stores the centre as X0 Y0, then probes the face for Z0.",
            ]
        case .program where (step.program ?? 0) >= 2000:
            return [
                "**By hand, at the machine:** this animation only shows the order. CRWrite can't feel the stock here, so you jog.",
                "Edge finder in the collet, spinning at \(Int(machine.probeSpindleRPM)) RPM.",
                "In Manual Operations, jog to the lower and upper edge (X), then the left and right edge (Y), until the finder kicks each time, and store it: CRWrite takes the centre as X0 Y0.",
                "Then each tool is touched off on the face with a sheet of paper (Z0) before it cuts.",
            ]
        case .program:
            guard let p = (programs + prepPrograms).first(where: { $0.index == step.program }) else { return [] }
            var out = ["**\(p.tool.name)**, \(Length.mm(p.tool.stickout)) mm sticking out of the collet nut."]
            out.append("\(p.opsTitle), about \(AppModel.duration(p.seconds)).")
            if let m = p.minStickout, m > p.tool.stickout + 0.1 { out.append("Needs at least \(Length.mm(m)) mm stick-out to keep the collet nut clear.") }
            out.append("The first time: run it as an air cut 10 mm above the work, spindle off.")
            if let material { out.append(material.lubricant) }
            return out
        case .setup:
            if setup.onBed, let st = bedJobStage, let p = bedJobPlacement {
                let turned = p.clampAngles.contains { abs($0) > 0.05 }
                return [
                    "No clamp kit: one acetal stop across both T-slots, the riser plate behind it.",
                    "Stock flat on the riser, one end against the stop, its face \(Length.mm(st.protrusion)) mm past the stop's front.",
                    "Two 3\" C-clamps behind the cut\(turned ? ", turned about their screws so the frames pass beside the bar" : ""): fixed jaw under the table, frame behind its back edge.",
                    "**Edge finding is by hand** (the bed isn't insulated): jog the spinning Fisher edge finder to each edge in CRWrite's Manual Operations until it kicks, and store it. The animation only shows the order.",
                ]
            }
            guard let stock, let p = clampPlacement(stockSize: setup.stockSize(stock)) else { return [] }
            return [
                "\(p.clamps.count == 1 ? "The universal clamp" : "\(p.clamps.count) universal clamps") across both T-slots\(setup.clampSoftJaw ? ", soft jaws on" : ", soft jaws off").",
                "Stock \(p.seat.description), \(p.parallels > 0.05 ? "\(Length.mm(p.parallels)) mm of parallels behind it, " : "")face \(Length.mm(effectiveProtrusion)) mm past the jaws.",
                setup.shoulders.map { "Each clamp grips a shoulder (\(Length.mm($0.height)) mm tall); the full-height middle stands up between them." } ?? "",
                "The jaws hold the top and bottom edges: the \(Length.mm(GripZones.grip)) mm strips there are never cut, so the frame stays gripped to the end.",
            ].filter { !$0.isEmpty }
        case .flip:
            return [
                "Vacuum the chips. Loosen the clamp screws and lift the stock out; leave the clamps bolted.",
                "Turn it front-to-back about the vertical axis: the back now faces the spindle, left becomes right.",
                "Same bottom edge on the jaw, same parallels behind it. Tighten, then edge-find and touch off again.",
            ]
        case .measure:
            guard let c = step.checkpoint else { return [] }
            let instrument = inventoryMeasuringName ?? "a caliper"
            return [
                "With \(instrument): \(c.what.lowercased()) should be **\(Length.mm(c.expected)) mm**, between \(Length.mm(c.expected - c.tolerance)) and \(Length.mm(c.expected + c.tolerance)).",
                "Too big: the tool deflected or wore. Run the finishing program again (it only takes what's left) or add a spring pass.",
                "Too small: check the tool's real diameter and stick-out, and the touch-off. Don't unclamp before it's right.",
            ]
        case .finish:
            var out: [String] = []
            if ((twoSided && holdWithTabs) || cutsThroughWithTabs) && !placedTabs.isEmpty {
                out.append("Unclamp. The part hangs in the frame on \(placedTabs.count) tabs: cut each close to the part with a jeweller's saw.")
            } else if twoSided {
                out.append("Unclamp and saw through the thin web to free the part.")
            } else if setup.onBed, let st = bedJobStage {
                out.append("Unclamp. The part is still joined to the bar behind it: saw it off a little past \(Length.mm(st.cut)) mm from the face, then file or sand the back flat.")
            } else if partOnBarBack > 0.05 {
                out.append("Unclamp. The part is still joined to the back of the bar (\(Length.mm(partOnBarBack)) mm of it): saw around it, then face or sand the back flat. (With Hold with tabs on, a bar up to \(Length.mm(Self.throughMaxExcess)) mm thicker than the part is cut through instead.)")
            } else {
                out.append("Unclamp and deburr.")
            }
            if bridgeNote != nil { out.append("Saw the bridges near the clamped edges too (finishing left them to keep stock under the jaws).") }
            out += Self.finishingGuide(material)
            return out
        }
    }

    /// Name of the first caliper or micrometer in the inventory, for measuring steps.
    var inventoryMeasuringName: String? { measuringToolNames.first }
    static func finishingGuide(_ m: Material?) -> [String] { FinishingGuide.steps(for: m) }
}
