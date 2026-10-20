import CoastlineCore
import SwiftUI
import Viewport

/// The toolpath timeline: transport controls, a scrubber with operation markers, speed,
/// colour mode, material removal and inspection.
struct PlaybackBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                JobStrip()
                if model.timeline.entries.isEmpty {
                    // Generating, nothing ready yet: the chapters above fill in as they're made.
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Generating the toolpaths: each chapter opens when it's ready.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    Scrubber()  // the open chapter's steps, before its toolpaths are on screen
                } else {
                // Narrower windows drop the least needed controls first: the coordinates, then the
                // colour and compare, so the bar never runs past the view.
                ViewThatFits(in: .horizontal) {
                    transportRow(0)
                    transportRow(1)
                    transportRow(2)
                    transportRow(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)  // transport on the left, what's shown on the right
                Scrubber()
                }
                if model.showDeviation, let d = model.deviationStats {
                    HStack(spacing: 14) {
                        Label("\(Int((d.within * 100).rounded())) % within ±\(Int(d.tolerance * 1000)) µm", systemImage: "circle.fill").foregroundStyle(.green)
                        Label("most left \(Length.mm(d.maxLeft)) mm", systemImage: "circle.fill").foregroundStyle(.blue)
                        Label(d.maxGouge > d.tolerance ? "gouge \(Length.mm(d.maxGouge)) mm" : "no gouges", systemImage: "circle.fill")
                            .foregroundStyle(d.maxGouge > d.tolerance ? .red : .secondary)
                        Spacer()
                        Text("at the playhead · simulation cell ≈ \(Length.mm(model.heightmap?.cell ?? 0)) mm").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private func transportRow(_ level: Int) -> some View {
        @Bindable var model = model
                HStack(spacing: 14) {
            // The same glass buttons as the toggles on the right; Play tinted with the accent.
            HStack(spacing: 6) {
                transport("backward.end.fill", "Previous Operation", "⌥←") { model.jumpOperation(-1) }
                transport("backward.frame.fill", "Previous Move", "←") { model.step(-1) }
                // Space is the Playback menu's (it leaves a text field being typed in alone).
                Button { model.togglePlay() } label: {
                    BarIconLabel(symbol: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.glass)
                .tint(Theme.accent)
                .foregroundStyle(.white)
                .disabled(model.toolChangeStop != nil)
                .help(model.isPlaying ? "Pause (Space)" : "Play this step (Space)")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play this step")
                transport("forward.frame.fill", "Next Move", "→") { model.step(1) }
                transport("forward.end.fill", "Next Operation", "⌥→") { model.jumpOperation(1) }
            }
            Text("\(AppModel.clock(model.playhead)) / \(AppModel.clock(model.timeline.duration))")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            // How it plays, next to the transport: real buttons, not faint menus.
            Menu {
                ForEach([1.0, 5, 20, 100, 500], id: \.self) { s in
                    Button { model.playSpeed = s } label: {
                        if s == model.playSpeed { Label("\(Int(s))×", systemImage: "checkmark") } else { Text("\(Int(s))×") }
                    }
                }
            } label: {
                Label("\(Int(model.playSpeed))×", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            .help("Playback speed: 1× is real time, as long as the cut takes at the machine")
            .accessibilityLabel("Playback speed \(Int(model.playSpeed)) times")
            if level < 3 {
                Menu {
                    Section("Colour the toolpath lines by") {
                        ForEach(PathColorMode.allCases) { m in
                            Button { model.colorMode = m } label: {
                                // Title and, under it, what the colours mean.
                                if m == model.colorMode { Label { Text(m.title); Text(m.explanation) } icon: { Image(systemName: "checkmark") } }
                                else { Text(m.title); Text(m.explanation) }
                            }
                        }
                    }
                } label: {
                    Label("Colour: \(model.colorMode.title)", systemImage: "paintpalette")
                        .font(.callout.weight(.semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
                .help("How the toolpath lines are coloured: by move type (cutting, in and out, plunging, rapids), feed rate, depth, operation or tool")
                .accessibilityLabel("Colour the toolpaths by \(model.colorMode.title)")
                if level < 2 { ColourKey(mode: model.colorMode) }
                TimelineLegend()
            }
            if level == 0 {
                let q = model.machinePosition
                let problem = model.travelProblem(q)
                HStack(spacing: 4) {
                    // Past the travel: a warning sign as well as the red, not colour alone. Its
                    // slot is always there, so the bar never changes size.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.danger)
                        .frame(width: 14)
                        .opacity(problem == nil ? 0 : 1)
                        .accessibilityHidden(true)
                    // Fixed width: the bar never changes size as the numbers change.
                    Text(String(format: "X%8.3f  Y%8.3f  Z%8.3f", q.x, q.y, q.z))
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .frame(width: 210, alignment: .leading)
                        .foregroundStyle(problem == nil ? Color.secondary : Theme.danger)
                }
                .help(problem.map { "Machine coordinates (what CRWrite's DRO would show). \($0)." } ?? "Machine coordinates (what CRWrite's DRO would show)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Machine coordinates")
                .accessibilityValue(String(format: "X %.3f, Y %.3f, Z %.3f millimetres", q.x, q.y, q.z) + (problem.map { ". \($0)" } ?? ""))
            }
            Spacer(minLength: 8)
            // What's shown, on the right.
            HStack(spacing: 6) {
                BarToggle(title: "Toolpaths", symbol: "point.topleft.down.to.point.bottomright.curvepath", isOn: $model.pathsVisible,
                          help: "Show the toolpath lines. Off: just the stock being cut and the tool.")
                BarToggle(title: "Work Area", symbol: "rectangle.dashed", isOn: $model.showWorkArea,
                          help: "The blue box: where the tool can reach on the stock face.")
                BarToggle(title: "Simulate Cutting", symbol: "cube.fill", isOn: $model.simulate,
                          help: "Show the stock being cut away as it plays.")
                BarToggle(title: "Pick a Toolpath", symbol: "scope", isOn: $model.inspecting,
                          help: "Click a toolpath line to see its G-code line, feed and position.")
                if level < 3 {
                    BarToggle(title: "Compare with the CAD", symbol: "chart.bar.xaxis", isOn: $model.showDeviation,
                              help: "Colour the simulated stock against the part: green within ±20 µm, blue where material is left, red where it would gouge.")
                        .disabled(!model.simulate)
                }
            }
        }
        .frame(height: 32)
    }

    /// A transport button: the toggles' glass button, icon only, named for VoiceOver.
    private func transport(_ symbol: String, _ title: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { BarIconLabel(symbol: symbol) }
            .plainGlassButton()
            .help("\(title) (\(key))")
            .accessibilityLabel(title)
    }
}

/// Timeline scrubber with a coloured band per operation.
struct Scrubber: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Text(model.openChapter?.title ?? "Timeline").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                .lineLimit(1).fixedSize()
                .help("Everything in the open chapter (above), in order. Steps you do by hand have an estimated time.")
            ChapterTimeline()
        }
        .frame(height: 26)
    }
}

/// The open chapter as a timeline: every step a segment as long as it takes (machining time,
/// or an estimate for what you do by hand; never narrower than 16 points), the step on screen
/// highlighted. In a machining step the playhead runs through its segment; click a segment to
/// go to that step, drag in a machining step to move through it.
struct ChapterTimeline: View {
    @Environment(AppModel.self) private var model
    private let minWidth: CGFloat = 16, gap: CGFloat = 2

    var body: some View {
        let steps = model.openChapter.map { ch in model.jobSteps.filter { $0.chapter == ch } } ?? []
        GeometryReader { geo in
            let widths = Self.widths(steps.map(\.duration), total: geo.size.width, min: minWidth, gap: gap)
            HStack(spacing: gap) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { k, step in
                    segment(step, width: widths[k])
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
        }
        .frame(height: 22)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Steps in this chapter")
    }

    private func segment(_ step: JobStep, width: CGFloat) -> some View {
        let active = model.isActive(step)
        let byHand = step.kind != .program
        let span = model.stepSpan(step)
        let progress: Double? = span.map { s in min(max((model.playhead - s.lowerBound) / max(s.upperBound - s.lowerBound, 1e-6), 0), 1) }
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(active ? Theme.accent : Color.secondary.opacity(byHand ? 0.22 : 0.4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(byHand ? Color.orange.opacity(0.6) : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            if active, let progress, !byHand {
                Circle().fill(.white).shadow(radius: 2).frame(width: 14, height: 14)
                    .offset(x: CGFloat(progress) * max(width - 14, 0))
            }
        }
        .frame(width: width, height: active ? 14 : 10)
        .frame(height: 22)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            if let span, model.isActive(step) {
                model.pause()
                model.seek(span.lowerBound + min(max(Double(v.location.x / max(width, 1)), 0), 1) * (span.upperBound - span.lowerBound))
            } else if !model.isActive(step) {
                model.go(to: step)
            }
        })
        .help("\(step.number) · \(step.title) · \(byHand ? "by hand, about \(AppModel.duration(step.duration * 60))" : "≈ \(AppModel.duration(step.duration * 60))")")
        // VoiceOver: one button per step; swipe up/down (adjust) for the next or previous step.
        .accessibilityElement()
        .accessibilityLabel("Step \(step.number), \(step.title)")
        .accessibilityValue(active && !byHand && progress != nil
            ? "\(Int(((progress ?? 0) * 100).rounded())) percent done"
            : byHand ? "By hand, about \(AppModel.duration(step.duration * 60))" : "About \(AppModel.duration(step.duration * 60))")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.go(to: step) }
        .accessibilityAdjustableAction { direction in
            let base = model.currentStep ?? step
            switch direction {
            case .increment: if let s = model.step(after: base, by: 1) { model.go(to: s) }
            case .decrement: if let s = model.step(after: base, by: -1) { model.go(to: s) }
            @unknown default: break
            }
        }
    }

    /// Widths proportional to the durations, none under the minimum, filling `total`.
    static func widths(_ d: [Double], total: CGFloat, min m: CGFloat, gap: CGFloat) -> [CGFloat] {
        guard !d.isEmpty else { return [] }
        let free = max(total - gap * CGFloat(d.count - 1), m * CGFloat(d.count))
        var fixed = Set<Int>()
        var w = [CGFloat](repeating: m, count: d.count)
        for _ in 0..<d.count {
            let rest = d.indices.filter { !fixed.contains($0) }
            let sum = rest.reduce(0) { $0 + d[$1] }
            let room = free - m * CGFloat(fixed.count)
            var changed = false
            for i in rest {
                let v = sum > 0 ? CGFloat(d[i] / sum) * room : room / CGFloat(rest.count)
                if v < m { fixed.insert(i); w[i] = m; changed = true } else { w[i] = v }
            }
            if !changed { break }
        }
        return w
    }
}

struct InspectCard: View {
    let info: InspectedMove

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Label(info.operation, systemImage: "scope").font(.headline)
                Text("\(info.role.capitalized) move · \(info.feed > 0 ? "\(Int(info.feed)) mm/min" : "rapid") · at \(AppModel.clock(info.time))")
                    .font(.callout)
                Text("X\(Length.mm(info.position.x))  Y\(Length.mm(info.position.y))  Z\(Length.mm(info.position.z))")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if !info.context.isEmpty {
                    Divider()
                    Text("Program \(info.program + 1)").font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(info.context, id: \.0) { n, text in
                            HStack(spacing: 8) {
                                Text("\(n)").foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                                Text(text)
                            }
                            .font(.system(.caption, design: .monospaced))
                            .padding(.vertical, 1)
                            .background(n == info.line ? Theme.accent.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
        }
    }
}

extension AppModel {
    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

extension AppModel {
    /// "Adaptive roughing · 1/4\" flat end mill · 3:20–14:05" for a scrubber segment.
    func segmentDescription(operation k: Int, from a: Double, to b: Double) -> String {
        let title = timelineTitles.indices.contains(k) ? timelineTitles[k] : "Operation"
        let tool = plannedTools.indices.contains(k) ? plannedTools[k].name.components(separatedBy: " · ").first ?? "" : ""
        return "\(title) · \(tool) · \(AppModel.clock(a))–\(AppModel.clock(b))"
    }
}

/// What the colours in the job strip and the timeline mean.
struct TimelineLegend: View {
    @Environment(AppModel.self) private var model
    @State private var shown = false
    private var mode: PathColorMode { model.colorMode }

    var body: some View {
        Button("What the Colours Mean", systemImage: "questionmark.circle") { shown.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("What the colours mean")
            .popover(isPresented: $shown, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("The toolpath lines").font(.headline)
                    Text("Colour: \(mode.title). \(mode.explanation).")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ColourKey(mode: mode)
                    Divider()
                    Text("The steps above").font(.headline)
                    legend(Theme.accent.opacity(0.85), nil, "Where you are now (the playhead's step)")
                    legend(Color.orange.opacity(0.16), Color.orange.opacity(0.5), "By hand: clamping, turning the stock, sawing")
                    legend(Color.secondary.opacity(0.12), nil, "On the machine: a program (its time below the name) or edge finding")
                    Divider()
                    Text("The bar").font(.headline)
                    Text("One colour per operation, in order. Hover a segment to see which operation and tool it is; click or drag anywhere on the bar to move the playhead. The paths in 3D use the same colours when Colour is set to Operation.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(width: 330)
            }
    }

    private func legend(_ fill: Color, _ stroke: Color?, _ text: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5).fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(stroke ?? .clear, lineWidth: 0.8))
                .frame(width: 26, height: 16)
            Text(text).font(.callout)
        }
    }
}

/// The playback bar's icons: all the same size, whatever the symbol.
struct BarIconLabel: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 22, height: 18)
    }
}

/// A show/hide switch of the playback bar: accent when on, its name shown above it on hover
/// (and as the tooltip, with what it does).
struct BarToggle: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    let help: String
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button { isOn.toggle() } label: { BarIconLabel(symbol: symbol) }
            .buttonStyle(.glass)
            .tint(isOn ? Theme.accent : .clear)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .help("\(title): \(help)")
            .accessibilityLabel(title)
            .accessibilityHint(help)
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
            .overlay(alignment: .top) {
                if hovering {
                    Text("\(title)\(isOn ? " · on" : " · off")\(enabled ? "" : " (needs Simulate Cutting)")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.78)))
                        .fixedSize()
                        .offset(y: -30)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// What the toolpath colours mean, right next to the colour menu.
struct ColourKey: View {
    let mode: PathColorMode

    var body: some View {
        HStack(spacing: 8) {
            switch mode {
            case .moveType:
                swatch(PathColor.cut, "cutting")
                swatch(PathColor.lead, "in / out")
                swatch(PathColor.plunge, "down")
                swatch(PathColor.rapid, "rapid", dashed: true)
            case .feed:
                gradient([SIMD4(40, 170, 255, 255), SIMD4(255, 50, 40, 255)], "slow → fast")
            case .depth:
                gradient([SIMD4(170, 230, 255, 255), SIMD4(30, 110, 255, 255)], "high → deep")
            case .operation, .tool:
                Text(mode == .tool ? "one colour per tool" : "one colour per operation").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func colour(_ c: SIMD4<UInt8>) -> Color {
        Color(red: Double(c.x) / 255, green: Double(c.y) / 255, blue: Double(c.z) / 255)
    }

    private func swatch(_ c: SIMD4<UInt8>, _ text: String, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .stroke(colour(c), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: dashed ? [3, 3] : []))
                .frame(width: 14, height: 3)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func gradient(_ cs: [SIMD4<UInt8>], _ text: String) -> some View {
        HStack(spacing: 4) {
            LinearGradient(colors: cs.map(colour), startPoint: .leading, endPoint: .trailing)
                .frame(width: 30, height: 4).clipShape(Capsule())
            Text(text).foregroundStyle(.secondary)
        }
    }
}

