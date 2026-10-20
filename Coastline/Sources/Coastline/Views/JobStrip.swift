import CoastlineCore
import SwiftUI

/// One step of the whole job, in the order it happens at the machine.
struct JobStep: Identifiable {
    enum Kind { case prepSetup, setup, program, flip, measure, finish }
    /// The job's four phases, in the order they happen at the machine.
    enum Phase: Int, CaseIterable {
        case stock, prep, sideA, sideB, finish
        var title: String {
            switch self {
            case .stock: "Your stock"
            case .prep: "Flat on the bed"
            case .sideA: "Clamp kit · side A"
            case .sideB: "Clamp kit · side B"
            case .finish: "Finish"
            }
        }
        /// Path B: the job runs on the bed, not in the clamp kit.
        func title(onBed: Bool) -> String { onBed && self == .sideA ? "On the bed" : title }
    }
    var id: String
    var kind: Kind
    var number: Int
    var title: String
    var detail: String
    var symbol: String
    var side: Int
    /// The prep clamping it belongs to (side −1).
    var stage: Int = 0
    var program: Int?
    var minutes: Double?
    /// Measuring checkpoint: what, expected, tolerance.
    var checkpoint: GuidedJobBuilder.Checkpoint?
    /// Your time for a step done by hand (an estimate), minutes; machining steps use `minutes`.
    var handMinutes: Double {
        switch kind {
        case .prepSetup: return stage < 0 ? 2 : 3
        case .setup: return minutes ?? 5
        case .flip: return 4
        case .measure: return 1.5
        case .finish: return 10
        case .program: return 0
        }
    }
    /// How long the step takes, minutes: machining, or the estimate for what you do by hand.
    var duration: Double { kind == .program ? max(minutes ?? 1, 0.2) : handMinutes }
    /// The chapter it belongs to (set when the steps are built).
    var chapter = JobChapter(id: "", title: "", side: 0)
    var phase: Phase {
        switch kind {
        case .finish: .finish
        default:
            side == -1 ? (stage < 0 ? .stock : .prep) : side == 0 ? .sideA : .sideB
        }
    }
}

/// A short part of the job: one clamping's setup, or one stage of the work on it (roughing,
/// pockets, walls and floors, finishing, holes). The timeline shows one chapter at a time.
struct JobChapter: Hashable, Identifiable {
    var id: String
    var title: String
    var side: Int
}

extension AppModel {
    /// The job as the user runs it: each clamping (with edge finding and a touch-off after it),
    /// each tool program (a tool change and touch-off before each), turning the stock over, side
    /// B, then freeing the part. The same order as the guided .crproj.
    var jobSteps: [JobStep] {
        // The finished programs, or while generating the planned ones (the same grouping and
        // numbering): every chapter and step is known before its toolpaths are.
        struct Prog { var index: Int; var side: Int; var tool: Tool; var operations: [Operation]; var seconds: Double? }
        let progs: [Prog] = programs.isEmpty
            ? plannedPrograms.map { Prog(index: $0.index, side: $0.side, tool: $0.tool, operations: $0.operations, seconds: nil) }
            : programs.map { Prog(index: $0.index, side: $0.side, tool: $0.tool, operations: $0.operations, seconds: $0.seconds) }
        guard !progs.isEmpty else { return [] }
        var out: [JobStep] = []
        func add(_ kind: JobStep.Kind, _ id: String, _ title: String, _ detail: String, _ symbol: String, side: Int,
                 stage: Int = 0, program: Int? = nil, minutes: Double? = nil) {
            out.append(JobStep(id: id, kind: kind, number: out.count + 1, title: title, detail: detail, symbol: symbol,
                               side: side, stage: stage, program: program, minutes: minutes))
        }
        // After every clamping: the edge finder finds X/Y, then each tool is touched off on the face.
        let electrical = !setup.onBed && AppSettings.shared.clampKitProbing == .electrical
        let reach = stock.map { probing(stockSize: setup.stockSize($0)) }
        func edgeFind(side: Int, stage: Int) {
            let probe = electrical && side >= 0
            let both = side < 0 || ((reach?.lowerXReachable[min(side, 1)] ?? true) && (reach?.upperXReachable[min(side, 1)] ?? true))
            let edges = both ? "lower, upper, left and right edge" : "one X edge (the other is out of reach: X0 from it and the stock's height), left and right edge"
            let detail = probe
                ? "Electrical probing with the first tool (wire on the clamp, G38.2): \(edges) → X0 Y0 at the face's centre; each tool touches down on the face (Z0)"
                : "Fisher edge finder: \(edges) → X0 Y0 at the face's centre; then touch off each tool on the face (Z0)"
            add(.program, "e\(side).\(stage)", probe ? "Probe the stock" : "Edge-find", detail,
                probe ? "bolt.horizontal" : "scope", side: side, stage: stage, program: Self.edgeFindProgram(side: side, stage: stage))
        }
        if let plan = flatPrepPlan, !prepPrograms.isEmpty || (isGenerating && hasPrep) {
            let saw = plan.sawLength.map { "Saw a \(Length.mm($0)) mm piece off first · " } ?? ""
            add(.prepSetup, "prep", "Your stock",
                "As bought, \(Length.mm(plan.width)) × \(Length.mm(plan.length)) × \(Length.mm(plan.thickness)) mm · " + saw + "one acetal stop across both T-slots, squared; the riser just behind its face; two 3\" C-clamps over the table's back edge",
                "shippingbox", side: -1, stage: -1)
            for k in plan.stages.indices {
                let p = prepPrograms.indices.contains(k) ? prepPrograms[k] : nil
                let st = plan.stages[k]
                let (title, detail, symbol): (String, String, String) = switch st.kind {
                case .faceEnd(0): ("Mount · end A", "Length toward the spindle, a long side on the stop, \(Length.mm(st.protrusion)) mm proud", "arrow.down.to.line")
                case .faceEnd: ("Turn end for end", "End B toward the spindle, the same side on the stop", "arrow.triangle.2.circlepath")
                case .edge(0, _): ("Quarter turn · edge", "Faced end A on the stop, the long edge \(Length.mm(st.protrusion)) mm past it", "rotate.3d")
                case .edge(let r, _): ("Slide out · round \(r + 1)", "Slide the bar \(Length.mm(st.cut)) mm toward the spindle, end A on the stop", "arrow.up.to.line")
                }
                add(.prepSetup, "m\(k)", title, detail + " · clamp it", symbol, side: -1, stage: k)
                edgeFind(side: -1, stage: k)
                add(.program, "p\(p?.index ?? 1000 + k)", p?.title ?? st.title, p?.tool.name ?? "Mills the bar on the bed", st.isEdge ? "square.3.layers.3d.top.filled" : "square.split.bottomrightquarter",
                    side: -1, stage: k, program: p?.index, minutes: p.map { $0.seconds / 60 })
                if k == plan.stages.count - 1, let p {
                    let c = GuidedJobBuilder.Checkpoint(afterProgram: p.index, what: "Bar width", expected: plan.target, tolerance: 0.1)
                    out.append(JobStep(id: "c\(p.index)", kind: .measure, number: out.count + 1, title: "Measure the bar",
                                       detail: "\(setup.shoulders == nil ? "Width" : "Shoulder height") \(Length.mm(plan.target)) ± 0.1 mm before it goes into the clamp kit", symbol: "ruler",
                                       side: -1, stage: k, program: p.index, checkpoint: c))
                }
            }
        }
        let clamps = stock.flatMap { clampPlacement(stockSize: setup.stockSize($0))?.clamps.count } ?? 1
        if setup.onBed {
            add(.setup, "setup", "Clamp on the bed & edge-find",
                "Flat on the riser against the stop, two C-clamps · find the X/Y centre · touch off", "square.and.arrow.down.on.square", side: 0)
        } else {
            add(.setup, "setup", prepPrograms.isEmpty ? "Clamp & edge-find" : "Into the clamp kit",
                "\(clamps == 1 ? "Universal clamp" : "\(clamps) universal clamps") in the T-slots · find the X/Y centre · touch off",
                "square.and.arrow.down.on.square", side: 0)
        }
        edgeFind(side: 0, stage: 0)
        let checks = checkpoints()
        func measures(after p: Prog) {
            for (n, c) in checks.enumerated() where c.afterProgram == p.index {
                out.append(JobStep(id: "c\(p.index).\(n)", kind: .measure, number: out.count + 1, title: "Measure",
                                   detail: "\(c.what): \(Length.mm(c.expected)) ± \(Length.mm(c.tolerance)) mm", symbol: "ruler",
                                   side: p.side, stage: 0, program: p.index, checkpoint: c))
            }
        }
        for p in progs where p.side == 0 {
            add(.program, "p\(p.index)", p.tool.name.components(separatedBy: " · ").first ?? p.tool.name,
                "Change tool, touch off · " + p.operations.map(\.title).joined(separator: ", "),
                "wrench.and.screwdriver", side: 0, program: p.index, minutes: p.seconds.map { $0 / 60 })
            measures(after: p)
        }
        if twoSided {
            add(.flip, "flip", "Turn over & re-clamp",
                "Front-to-back about the vertical axis · same bottom edge and parallels · edge-find and touch off again",
                "arrow.triangle.2.circlepath", side: 1)
            edgeFind(side: 1, stage: 0)
            for p in progs where p.side == 1 {
                add(.program, "p\(p.index)", p.tool.name.components(separatedBy: " · ").first ?? p.tool.name,
                    "Change tool, touch off · " + p.operations.map(\.title).joined(separator: ", "),
                    "wrench.and.screwdriver", side: 1, program: p.index, minutes: p.seconds.map { $0 / 60 })
                measures(after: p)
                if p.operations.contains(where: { $0.reference == .windows }) {
                    add(.setup, "bores", "Find the reference bores",
                        (electrical ? "The tool touches each bore's wall four times (G38.2)" : "The edge finder finds each bore's four walls")
                            + " · X0 Y0 from the two centres · checks their size, spacing and squareness",
                        "circle.circle", side: 1, program: p.index, minutes: electrical ? 3 : 15)
                }
            }
        }
        let onTabs = ((twoSided && holdWithTabs) || cutsThroughWithTabs) && !placedTabs.isEmpty
        let finish = onTabs ? "Cut the \(placedTabs.count) tabs, file the stubs"
            : twoSided ? "Saw the web, file flush" : partOnBarBack > 0.05 ? "Saw it off the bar, face the back" : "Unclamp and deburr"
        add(.finish, "finish", onTabs || twoSided ? "Free the part" : "Finish", finish, "scissors", side: twoSided ? 1 : 0)
        // Chapters: contiguous runs of steps with the same key.
        let opsOf = Dictionary(progs.map { ($0.index, $0.operations) }, uniquingKeysWith: { a, _ in a })
        func stageOfWork(_ ops: [Operation]) -> (Int, String) {
            guard let o = ops.first else { return (0, "Roughing") }
            switch o.kind {
            case .facing: return (0, "Roughing")
            case .adaptive: return o.pocketsOnly == true ? (1, "Pockets") : (0, "Roughing")
            case .contour, .floor, .chamfer: return (2, "Walls & floors")
            case .bore, .drill, .engrave: return (4, "Holes & details")
            default: return (3, "Finishing")
            }
        }
        let sideName: (Int) -> String = { side in self.twoSided ? (side == 0 ? "A · " : "B · ") : "" }
        var last: (key: String, chapter: JobChapter)?
        var runs = 0
        for k in out.indices {
            let st = out[k]
            let key: String, title: String
            switch st.kind {
            case .finish: (key, title) = ("finish", st.title)
            case .measure: (key, title) = last.map { ($0.key, $0.chapter.title) } ?? ("measure", "Measure")
            case .prepSetup where st.stage < 0: (key, title) = ("bed0", "Bed 1 · " + (flatPrepPlan?.stages.first?.title ?? "Prep"))
            case .setup, .flip: (key, title) = ("s\(st.side).setup", sideName(st.side) + (st.kind == .flip || st.side == 1 ? "Turn over & edge-find" : "Clamp & edge-find"))
            default:
                if st.side == -1 {
                    let n = max(st.stage, 0)
                    (key, title) = ("bed\(n)", "Bed \(n + 1) · " + (flatPrepPlan.map { $0.stages.indices.contains(n) ? $0.stages[n].title : "Prep" } ?? "Prep"))
                } else if st.program == Self.edgeFindProgram(side: st.side, stage: 0)
                            || (st.program.flatMap { opsOf[$0] }?.contains { $0.reference == .windows } ?? false) {
                    (key, title) = ("s\(st.side).setup", sideName(st.side) + (st.side == 1 ? "Turn over & edge-find" : "Clamp & edge-find"))
                } else {
                    let (cat, name) = stageOfWork(st.program.flatMap { opsOf[$0] } ?? [])
                    (key, title) = ("s\(st.side).\(cat)", sideName(st.side) + name)
                }
            }
            if last?.key != key {
                runs += 1
                last = (key, JobChapter(id: "\(key)#\(runs)", title: title, side: st.side == -1 || key.hasPrefix("bed") ? -1 : st.side))
            }
            out[k].chapter = last!.chapter
        }
        return out
    }

    /// The phase whose side the scrubber shows (the timeline is one side at a time).
    var phaseOnScrubber: JobStep.Phase? {
        guard !timeline.entries.isEmpty else { return nil }
        switch viewSide {
        case -1: return .prep
        case 1: return .sideB
        default: return .sideA
        }
    }

    /// The chapter that's open: the one with the step on screen.
    var openChapter: JobChapter? { currentStep?.chapter ?? jobSteps.first { $0.side == viewSide }?.chapter }

    /// A program's toolpaths are all made (while generating they arrive one by one).
    func programReady(_ p: Int) -> Bool {
        guard isGenerating else { return true }
        if let planned = plannedPrograms.first(where: { $0.index == p }) {
            let done = sideResults.first { $0.side == planned.side }?.operationProgram.filter { $0 == p }.count ?? 0
            return done >= planned.operations.count
        }
        return !prepResults.isEmpty  // the prep's (made first)
    }

    /// A chapter can be opened once its programs are all there; a clamping's setup once its
    /// first toolpaths are.
    func chapterReady(_ group: [JobStep]) -> Bool {
        guard isGenerating else { return !programs.isEmpty || !sideResults.isEmpty }
        let progs = group.compactMap(\.program).filter { $0 < 2000 }
        if progs.isEmpty {
            let side = group.first?.side ?? 0
            return side == -1 ? !prepResults.isEmpty : sideResults.contains { $0.side == side && !$0.planned.isEmpty }
        }
        return progs.allSatisfy(programReady)
    }

    /// How much of a chapter's toolpaths are made while generating (nil: nothing to make).
    func chapterProgress(_ group: [JobStep]) -> Double? {
        let progs = group.compactMap(\.program).filter { $0 < 2000 }
        guard !progs.isEmpty else { return nil }
        return Double(progs.filter(programReady).count) / Double(progs.count)
    }

    /// The open chapter's stretch of the timeline (the scrubber shows only that).
    var chapterSpan: ClosedRange<Double>? {
        guard let ch = openChapter, !timeline.entries.isEmpty else { return nil }
        let progs = Set(jobSteps.filter { $0.chapter == ch }.compactMap(\.program))
        let entries = timeline.entries.filter { progs.contains($0.program) }
        guard let a = entries.first?.tStart, let b = entries.last?.tEnd, b > a else { return nil }
        return a...b
    }

    /// A chapter's number in the job (1, 2, 3…).
    func chapterNumber(_ ch: JobChapter) -> Int {
        var seen: [JobChapter] = []
        for st in jobSteps where seen.last != st.chapter { seen.append(st.chapter) }
        return (seen.firstIndex(of: ch) ?? 0) + 1
    }

    /// A machining step's stretch of the timeline on screen (nil: by hand, or another clamping).
    func stepSpan(_ step: JobStep) -> ClosedRange<Double>? {
        guard step.kind == .program, let p = step.program, step.side == viewSide, step.side != -1 || step.stage == prepStage,
              let a = timeline.entries.first(where: { $0.program == p }), let b = timeline.entries.last(where: { $0.program == p }) else { return nil }
        return a.tStart...b.tEnd
    }

    /// The scrubber's span of the step on screen (its program's time), for the bracket.
    var currentStepSpan: ClosedRange<Double>? {
        guard let step = currentStep, let p = step.program, step.kind == .program,
              let a = timeline.entries.first(where: { $0.program == p }),
              let b = timeline.entries.last(where: { $0.program == p }) else { return nil }
        return a.tStart...b.tEnd
    }

    /// The program under the playhead.
    var currentProgram: Int? {
        guard !timeline.entries.isEmpty else { return nil }
        return timeline.entries[timeline.index(at: playhead)].program
    }

    /// Whether a step is the one on screen.
    func isActive(_ step: JobStep) -> Bool {
        // The step chosen last wins while the playhead stays where it put it: one step selected,
        // never two (a measuring step sits at the end of the program before it).
        if let sel = selectedStep, abs(playhead - sel.time) < 1e-6 { return step.id == sel.id }
        let atStart = playhead <= 1e-6
        switch step.kind {
        case .program: return step.program == currentProgram && (step.side != -1 || prepStage == step.stage)
        case .prepSetup: return viewSide == -1 && prepStage == step.stage && atStart
        case .setup: return viewSide == 0 && atStart
        case .flip: return viewSide == 1 && atStart
        case .measure:
            return selectedStep?.id == step.id && abs(playhead - (selectedStep?.time ?? -1)) < 1e-6
        case .finish: return viewSide == step.side && playhead >= timeline.duration - 1e-6 && timeline.duration > 0
        }
    }

    /// Shows a step: switches side or clamping (with the stock moving the way it does at the
    /// machine) and jumps to its program.
    func go(to step: JobStep) {
        pause()
        let seekTo: () -> Void = { [weak self] in
            guard let self else { return }
            switch step.kind {
            case .prepSetup, .setup, .flip: self.seek(0)
            case .finish: self.seek(self.timeline.duration)
            case .measure:
                if let p = step.program, let e = self.timeline.entries.last(where: { $0.program == p }) { self.seek(e.tEnd) }
            case .program:
                if let p = step.program, let e = self.timeline.entries.first(where: { $0.program == p }) { self.seek(e.tStart) }
            }
            self.selectedStep = (step.id, self.playhead)
        }
        let stage = step.side == -1 ? step.stage : prepStage
        if step.side != viewSide || stage != prepStage {
            pendingSeek = seekTo
            show(side: step.side, stage: stage)
        } else if stockAnimating {
            // The stock is still moving to this clamping: its timeline isn't on screen yet.
            // The step is taken when it lands (the last one clicked wins).
            pendingSeek = seekTo
        } else {
            seekTo()
        }
    }
}

/// The job's steps above the playback scrubber. Machining steps carry their time; the manual
/// ones (clamping, turning over, freeing the part) show what to do.
struct JobStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Outer corner radius of a chapter card; the open one's steps sit inset by `inset`, with
    /// radius outer − inset, so the corners run concentric. Every card is `cardHeight` tall,
    /// open or not, its number in the same place: nothing jumps as chapters open and close.
    private let outer: CGFloat = 16, inset: CGFloat = 7, badge: CGFloat = 18, cardHeight: CGFloat = 72
    /// Where the row fades out at its ends while it scrolls.
    private let fade: CGFloat = 18
    /// The strip's width: a row that fits sits in the middle of it.
    @State private var width: CGFloat = 0

    var body: some View {
        let steps = model.jobSteps
        var chapters: [JobChapter] = []
        for st in steps where chapters.last != st.chapter { chapters.append(st.chapter) }
        let open = model.openChapter
        // The chapters in one row, in the order of the job: one open (its steps inside it), the
        // others closed to their number. Too many for the width: the row scrolls sideways
        // (never wraps), fading out at its ends, and keeps the open chapter in view.
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Array(chapters.enumerated()), id: \.element) { n, ch in
                        let group = steps.filter { $0.chapter == ch }
                        Group {
                            if ch == open {
                                openChapter(ch, group, n + 1)
                                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity), removal: .opacity))
                            } else {
                                closedChapter(ch, group, n + 1)
                            }
                        }
                        .id(ch.id)
                    }
                    if model.isGenerating {
                        generationTally(chapters.map { ch in steps.filter { $0.chapter == ch } })
                            .frame(height: cardHeight)
                    }
                }
                .padding(.horizontal, fade)
                .frame(minWidth: width)  // centred while it fits; scrolls from the left when not
            }
            .scrollIndicators(.hidden)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: fade)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: fade)
                }
            }
            .padding(.horizontal, -fade)  // the fade sits in the bar's margin, the cards line up with it
            .frame(height: cardHeight)
            .onChange(of: open) { _, ch in
                guard let ch else { return }
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { proxy.scrollTo(ch.id, anchor: .center) }
            }
            .onAppear { if let ch = open { proxy.scrollTo(ch.id, anchor: .center) } }
        }
        // Reduce Motion: chapters change in place instead of springing open.
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82), value: open)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: model.currentStep?.id)
    }

    /// A closed chapter: a card as tall as the open one, its number where the open one has it,
    /// the chapter's first step symbol below. Ready (filled number, a tick while the rest
    /// generates), generating (a progress ring) or waiting (dashed).
    private func closedChapter(_ ch: JobChapter, _ group: [JobStep], _ n: Int) -> some View {
        let ready = model.chapterReady(group)
        let progress = model.chapterProgress(group)
        let steps = "\(group.count) step\(group.count == 1 ? "" : "s")"
        let percent: Int? = progress.map { Int(($0 * 100).rounded()) }
        let help = "Chapter \(n) · \(ch.title) · \(steps)"
            + (ready ? "" : percent.map { " · generating, \($0) % ready" } ?? " · comes when the toolpaths are ready")
        let value = steps + (ready ? "" : percent.map { ", generating, \($0) percent ready" } ?? ", comes when the toolpaths are ready")
        let generating = !ready && (progress ?? 0) > 0
        return Button { if let first = group.first { model.go(to: first) } } label: {
            VStack(spacing: 0) {
                ZStack {
                    if ready {
                        Circle().fill(Theme.accent.opacity(0.22))
                        Circle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1)
                    } else if generating, let progress {
                        Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                        Circle().trim(from: 0, to: progress).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    } else {
                        Circle().strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                    // Not ready yet: secondary text at full opacity, so the number stays readable.
                    Text("\(n)").font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(ready ? Color.primary : Color.secondary)
                }
                .frame(width: badge, height: badge)
                .overlay(alignment: .bottomTrailing) {
                    if ready && model.isGenerating {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 9, weight: .bold))
                            .symbolRenderingMode(.palette).foregroundStyle(.white, Theme.ok)
                            .offset(x: 3, y: 3)
                            .accessibilityHidden(true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: group.first?.symbol ?? "circle").font(.caption)
                    .foregroundStyle(ready ? Color.secondary : Color.secondary.opacity(0.5))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .padding(inset)
            .frame(height: cardHeight)
            .background(RoundedRectangle(cornerRadius: outer).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: outer).strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: outer))
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .help(help)
        .accessibilityLabel("Chapter \(n), \(ch.title)")
        .accessibilityValue(value)
    }

    /// While generating: how many chapters can be opened, with a legend in its help.
    private func generationTally(_ groups: [[JobStep]]) -> some View {
        let ready = groups.filter { model.chapterReady($0) }.count
        return HStack(spacing: 5) {
            ProgressView().controlSize(.mini)
            Text("\(ready) of \(groups.count) ready").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .fixedSize()
        .help("Chapters arrive as their toolpaths are made. Filled with a tick: ready to open. A ring: being generated (how far). Dashed: waiting its turn. The view stays where you are while new ones arrive.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Generating, \(ready) of \(groups.count) chapters ready")
    }

    private func openChapter(_ ch: JobChapter, _ group: [JobStep], _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("\(n)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: badge, height: badge).background(Circle().fill(Theme.accent))
                Text(ch.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Text("\(group.count) step\(group.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Chapter \(n), \(ch.title), \(group.count) step\(group.count == 1 ? "" : "s")")
            .accessibilityAddTraits(.isHeader)
            // One row of steps (the strip scrolls when it's long).
            HStack(spacing: 3) {
                ForEach(group) { step in
                    let active = model.isActive(step)
                    Button { model.go(to: step) } label: { chip(step, active: active, compact: !active) }
                        .buttonStyle(.plain)
                        .help("\(step.number) · \(step.title): \(step.detail)")
                        .accessibilityLabel("Step \(step.number), \(step.title)")
                        .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
        }
        .padding(inset)
        .frame(height: cardHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: outer).fill(Theme.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: outer).strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1))
    }

    private func chip(_ step: JobStep, active: Bool, compact: Bool) -> some View {
        let manual = step.kind != .program
        return HStack(spacing: compact ? 3 : 6) {
            Text("\(step.number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(minWidth: 16, minHeight: 16)
                .background(Circle().fill(active ? Color.white.opacity(0.9) : Color.secondary.opacity(0.25)))
                .foregroundStyle(active ? Theme.accent : .primary)
            Image(systemName: step.symbol).font(.caption)
            if !compact {
            VStack(alignment: .leading, spacing: 0) {
                Text(step.title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(step.minutes.map { "\(step.side == -1 ? "Prep · " : model.twoSided ? (step.side == 0 ? "A · " : "B · ") : "")≈ \(AppModel.duration($0 * 60))" }
                     ?? (step.kind == .program ? "being generated…" : step.kind == .flip ? "Side B" : step.kind == .prepSetup ? "Prep" : step.kind == .setup ? (model.twoSided ? "Side A" : "Setup") : "By hand"))
                    .font(.caption).foregroundStyle(active ? Color.white : .secondary).lineLimit(1)
            }
            }
        }
        .padding(.horizontal, compact ? 5 : 8).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: outer - inset)
                .fill(active ? Theme.accent.opacity(0.85) : (manual ? Color.orange.opacity(0.16) : Color.secondary.opacity(0.12)))
        )
        .overlay(RoundedRectangle(cornerRadius: outer - inset).strokeBorder(manual ? Color.orange.opacity(0.35) : .clear, lineWidth: 0.8))
        .foregroundStyle(active ? .white : .primary)
    }
}
