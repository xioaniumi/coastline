import CoastlineCore
import SwiftUI

/// The six stages across the top of the inspector: each with its state, the reason on hover,
/// and a click to go there (back or forth, any time).
struct StageBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            ForEach(JobStage.allCases) { stage in
                let st = model.status(stage)
                let current = model.stage == stage
                Button { model.enter(stage) } label: {
                    VStack(spacing: 3) {
                        ZStack {
                            Circle().fill(fill(st.state, current: model.stage == stage)).frame(width: 24, height: 24)
                            Image(systemName: icon(st.state, stage))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(st.state == .later || st.state == .notNeeded ? Color.secondary : .white)
                        }
                        .overlay(Circle().strokeBorder(model.stage == stage ? Color.primary.opacity(0.7) : .clear, lineWidth: 1.5).frame(width: 28, height: 28))
                        // One short word at caption size (the full name is the tooltip and what
                        // VoiceOver reads): a long name in a narrow cell broke as "Machin-ing".
                        Text(shortTitle(stage)).font(.caption.weight(current ? .semibold : .medium))
                            .lineLimit(1).minimumScaleFactor(0.85)
                            .foregroundStyle(st.state == .later ? .secondary : .primary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .help("\(model.title(stage)): \(st.why)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.title(stage))
                .accessibilityValue(stateName(st.state))
                .accessibilityHint(st.why)
                .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private func shortTitle(_ stage: JobStage) -> String {
        switch stage {
        case .partStock: "Part"
        case .holding: "Holding"
        case .prep: "Prep"
        case .clampKit: model.setup.onBed ? "Bed" : "Clamps"
        case .machining: "Machining"
        case .review: "Review"
        }
    }

    private func stateName(_ s: StageStatus.State) -> String {
        switch s {
        case .done: "Done"
        case .attention: "Needs attention"
        case .todo: "To do"
        case .blocked: "Blocked"
        case .notNeeded: "Not needed"
        case .later: "Later"
        }
    }

    private func icon(_ s: StageStatus.State, _ stage: JobStage) -> String {
        switch s {
        case .done: "checkmark"
        case .attention: "exclamationmark"
        case .todo: "arrow.right"
        case .blocked: "xmark"
        case .notNeeded: "minus"
        case .later: stage.symbol
        }
    }

    private func fill(_ s: StageStatus.State, current: Bool) -> Color {
        // Deep fills so the white glyphs read clearly (WCAG ≥ 4.5:1).
        switch s {
        case .done: Color(red: 0.11, green: 0.50, blue: 0.24)
        case .attention: Color(red: 0.72, green: 0.38, blue: 0.0)
        case .todo: Theme.accent.opacity(current ? 1 : 0.75)
        case .blocked: Color(red: 0.75, green: 0.16, blue: 0.14)
        case .notNeeded: Color.secondary.opacity(0.18)
        case .later: current ? Theme.accent : Color.secondary.opacity(0.18)
        }
    }
}

/// The stage's "why", under the bar.
struct StageHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let st = model.status(model.stage)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(model.stage.rawValue + 1)").font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 18, height: 18).background(Circle().fill(Theme.accent.opacity(0.25)))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title(model.stage)).font(.headline)
                Text(st.why).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(st.why)
            }
            Spacer(minLength: 0)
            if let next = JobStage(rawValue: model.stage.rawValue + 1) {
                Button { model.enter(next) } label: { Label("Next", systemImage: "chevron.right").labelStyle(.titleAndIcon) }
                    .controlSize(.small)
                    .help("Go to \(model.title(next))")
                    .accessibilityLabel("Next: \(model.title(next))")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Stage 2: the four ways to hold the stock, the recommended one marked, each with its reason.
struct HoldingInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(HoldingPath.allCases) { path in
                    let a = model.holdingAssessment(path)
                    let current = model.holdingPath == path
                    Button { model.choose(path) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(path.letter).font(.headline.monospaced())
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(current ? Theme.accent : Color.secondary.opacity(0.15)))
                            .foregroundStyle(current ? .white : .primary)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(path.title).font(.callout.weight(.semibold))
                                if a.recommended { Text("Recommended").font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.ok.opacity(0.25))) }
                                if let r = path.arrives { Text("Coming in \(r)").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(a.why).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        // The chosen path: a checkmark too, not only the filled letter.
                        if current {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(current ? .isSelected : [])
                    .disabled(!(a.possible || current))
                    .opacity(a.possible || current ? 1 : 0.55)
                }
            } header: {
                HStack {
                    Text("How the stock is held")
                    InfoTip(text: "Coastline picks the path from the part's size, the stock and the clamp kit's grip range; click another one to use it instead.")
                }
            }
        }
        .formStyle(.grouped)
        .darkPanel()
    }
}

/// Stage 3: the clampings on the bed, in order; each opens its view.
struct PrepInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if let plan = model.flatPrepPlan {
                Section("Your stock") {
                    LabeledContent("As bought", value: "\(Length.mm(plan.width)) × \(Length.mm(plan.length)) × \(Length.mm(plan.thickness)) mm")
                    if let sh = model.setup.shoulders {
                        LabeledContent("Into the clamp kit", value: "\(Length.mm(plan.width)) mm tall, \(Length.mm(sh.height)) mm at the \(Length.mm(sh.length)) mm shoulders")
                    } else {
                        LabeledContent("Into the clamp kit", value: "\(Length.mm(plan.target)) × \(Length.mm(plan.finalLength)) × \(Length.mm(plan.thickness)) mm")
                    }
                    stageRow(-1, "Your stock, as bought", "Every cut is marked on the bar in orange, numbered by its step.", "")
                }
                Section {
                    ForEach(Array(plan.stages.enumerated()), id: \.offset) { k, st in
                        stageRow(k, st.title, removes(st, plan: plan), st.isEdge
                                 ? "Faced end A on the stop; the edge sticks out \(Length.mm(st.protrusion)) mm past it, cut in shallow layers."
                                 : "Long side on the stop, end toward the spindle, \(Length.mm(st.protrusion)) mm proud.")
                    }
                } header: {
                    HStack {
                        Text("Steps on the bed")
                        InfoTip(text: "Each step is its own clamping. Click one: the bar shows as it is then, what that step mills off in orange, and the later steps faint.")
                    }
                }
                if model.setup.shoulders != nil { ShoulderSummary() }
                PrepStepsSection(plan: plan)
                BedFixturesSection()
                if !plan.issues.isEmpty { IssuesSection(issues: plan.issues) }
            } else if model.setup.shoulders != nil {
                ShoulderSummary()
            } else {
                Section {
                    Label("No prep: the stock fits the clamp kit as it is.", systemImage: "checkmark.circle")
                }
            }
        }
        .formStyle(.grouped)
        .darkPanel()
    }

    /// What a step mills off, in words (the orange on the bar).
    private func removes(_ st: FlatPrep.Stage, plan: FlatPrep.Plan) -> String {
        switch st.kind {
        case .faceEnd:
            return "Takes \(Length.mm(st.cut)) mm off end A, so it sits square against the stop."
        case .edge:
            if let sh = model.setup.shoulders {
                return st.otherEdge
                    ? "Turned over: mills \(Length.mm(st.cut)) mm off the bottom of both ends (\(Length.mm(sh.length)) mm each): four-corner shoulders."
                    : "Mills \(Length.mm(st.cut)) mm off the top of both ends (\(Length.mm(sh.length)) mm each); the middle stays full height."
            }
            return "Mills \(Length.mm(st.cut)) mm off the whole top edge."
        }
    }

    private func stageRow(_ k: Int, _ title: String, _ what: String, _ how: String) -> some View {
        let current = model.viewSide == -1 && model.prepStage == k
        return Button { model.show(side: -1, stage: k); model.focusWork() } label: {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if k < 0 {
                        Image(systemName: "shippingbox").font(.system(size: 12, weight: .semibold))
                    } else {
                        Text("\(k + 1)").font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                }
                .foregroundStyle(current ? .white : Theme.prepCut)
                .frame(width: 24, height: 24)
                .background(Circle().fill(current ? Theme.prepCut : Theme.prepCut.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(current ? .semibold : .regular))
                    Text(what).font(.caption).foregroundStyle(current ? .primary : .secondary)
                    if !how.isEmpty { Text(how).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
        .listRowBackground(current ? Theme.prepCut.opacity(0.12) : nil)
    }
}

/// The prep's features, editable: Coastline proposes them; each can be changed here.
struct PrepStepsSection: View {
    @Environment(AppModel.self) private var model
    let plan: FlatPrep.Plan

    var body: some View {
        Section {
            if model.setup.shoulders != nil {
                Text("Shoulders: see the section below.").font(.caption).foregroundStyle(.secondary)
            } else {
            NumberField(title: "Mill down to", value: Binding(
                get: { model.setup.downsizeHeight ?? plan.target },
                set: { v in
                    let lo = UniversalClamp.onJaw(softJaw: model.setup.clampSoftJaw).lowerBound
                    model.prepAuto = false
                    let hi = min(plan.width - 0.5, UniversalClamp.onJaw(softJaw: model.setup.clampSoftJaw).upperBound)
                    model.setup.downsizeHeight = min(max(v, lo), hi)
                }), tip: "The height the bar goes into the clamp kit at. Lower takes longer and leaves less room for the frame; the kit grips from \(Length.mm(UniversalClamp.onJaw(softJaw: model.setup.clampSoftJaw).lowerBound)) mm.")
            }
            Toggle(isOn: Binding(get: { plan.faceEnds }, set: { model.setup.prepFaceEnd = $0 })) {
                Text("Square end A first")
                Text("Face the sawn end square so it sits flat against the stop for the edge rounds.")
            }
            if plan.rounds > 0 {
                Stepper(value: Binding(get: { plan.rounds }, set: { model.setup.prepRounds = max($0, 1) }), in: 1...8) {
                    LabeledContent("Edge rounds", value: "\(plan.rounds) × \(Length.mm((plan.width - plan.target) / Double(plan.rounds))) mm")
                }
            }
            if model.setup.shoulders == nil, model.setup.prepFaceEnd != nil || model.setup.prepRounds != nil || !model.prepAuto {
                Button("Back to Coastline's Proposal", systemImage: "arrow.uturn.backward") {
                    model.setup.prepFaceEnd = nil
                    model.setup.prepRounds = nil
                    model.prepAuto = true
                    model.setup.downsizeHeight = nil
                    model.autoPlanPrep()
                }
            }
        } header: {
            HStack {
                Text("Prep steps")
                InfoTip(text: "Each step is its own clamping on the bed.")
            }
        }
    }
}

/// Path D's shoulders, adjustable: how the kit grips them (with or without its soft jaws),
/// how tall they are, how much comes off their bottom so the bar sits lower, and whether the
/// part is then within the CR-1's reach.
struct ShoulderSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let sh = model.setup.shoulders, let stock = model.stock {
            let raw = model.setup.rawStockSize(stock)
            let grip = UniversalClamp.onJaw(softJaw: model.setup.clampSoftJaw)
            Section {
                HStack(alignment: .top) {
                    Label(model.setup.clampSoftJaw
                          ? "Gripped with the soft jaws: they take shorter shoulders (\(Length.mm(grip.lowerBound))–\(Length.mm(grip.upperBound)) mm), so more comes off the ends."
                          : "Gripped straight in the kit, no soft jaws: taller shoulders (up to \(Length.mm(grip.upperBound)) mm), less to mill.",
                          systemImage: "rectangle.compress.vertical")
                        .font(.caption)
                }
                LabeledContent("Shoulder height") {
                    HStack {
                        Slider(value: Binding(get: { sh.height }, set: { v in
                            model.shouldersAuto = false
                            model.setup.shoulders?.height = min(max((v * 2).rounded() / 2, grip.lowerBound), min(grip.upperBound, raw.x - sh.bottom))
                        }), in: grip.lowerBound...max(min(grip.upperBound, raw.x - sh.bottom), grip.lowerBound + 0.5))
                            .accessibilityLabel("Shoulder height")
                            .accessibilityValue("\(Length.mm(sh.height)) millimetres")
                        Text("\(Length.mm(sh.height)) mm").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                .help("What the jaws grip at each end. Lower takes more off but leaves more room around the bolts and screws.")
                LabeledContent("Lower the middle by") {
                    HStack {
                        Slider(value: Binding(get: { sh.bottom }, set: { v in
                            model.shouldersAuto = false
                            var n = sh
                            n.bottom = min(max((v * 2).rounded() / 2, 0), model.maxShoulderBottom)
                            n.height = min(n.height, raw.x - n.bottom)
                            model.setup.shoulders = n
                        }), in: 0...model.maxShoulderBottom)
                            .accessibilityLabel("Lower the middle by")
                            .accessibilityValue("\(Length.mm(sh.bottom)) millimetres")
                        Text("\(Length.mm(sh.bottom)) mm").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                .help("Four-corner shoulders: the bottom of the ends comes off too, so the full-height middle hangs lower between the clamps (it stays 1.5 mm above the bed).")
                NumberField(title: "Shoulder length", value: Binding(get: { sh.length }, set: { v in
                    model.shouldersAuto = false
                    model.setup.shoulders?.length = min(max(v, Shoulders.gripZone), raw.y / 3)
                }), tip: "How far each shoulder runs in from its end. The universal clamp is 19 mm wide, 12 mm in from the end; longer leaves less room for the part.")
                let removed = 2 * sh.length * (sh.top(barHeight: raw.x) + sh.bottom) * raw.z / 1000
                LabeledContent("Milled off", value: "\(Length.mm(removed)) cm³ (\(Length.mm(sh.top(barHeight: raw.x))) mm off the top\(sh.bottom > 0 ? ", \(Length.mm(sh.bottom)) mm off the bottom" : "") of each end)")
                if let r = model.reachExcess {
                    if r.above > 0 {
                        HStack {
                            Label("The part's top is \(Length.mm(r.above)) mm beyond the CR-1's travel.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Theme.warning)
                            Spacer()
                            Button("Lower It Enough") { model.shouldersAuto = false; model.lowerForReach() }
                                .disabled(sh.bottom >= model.maxShoulderBottom)
                        }
                    } else if r.below > 0 {
                        Label("The part's bottom is \(Length.mm(r.below)) mm beyond the travel: lower the middle less.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.warning)
                    } else {
                        Label("The whole part is within the CR-1's reach (\(Length.mm(-r.above)) mm to spare at the top).", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                }
                Button("See the Cuts on the Bed (Stock Prep)", systemImage: "eye") { model.enter(.prep) }
            } header: {
                HStack {
                    Text("Shoulders")
                    InfoTip(text: "The clamps grip only the ends: the part may come right to the bar's top and bottom edges. Anything the jaws or the bed would hit shows red.")
                }
            }
        }
    }
}

/// Stock prep: the shoulders in one line; they're set up in the Clamp kit step, where the
/// clamps grip them.
struct ShoulderSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let sh = model.setup.shoulders {
            Section("Shoulders") {
                LabeledContent("Ends", value: "\(Length.mm(sh.height)) mm high, \(Length.mm(sh.length)) mm long\(sh.bottom > 0 ? ", \(Length.mm(sh.bottom)) mm off the bottom" : "")")
                LabeledContent("Gripped", value: model.setup.clampSoftJaw ? "with the soft jaws" : "straight in the kit")
                Button("Change in Clamp Kit", systemImage: "slider.horizontal.3") { model.enter(.clampKit) }
            }
        }
    }
}

/// The stop and the C-clamps of the clamping on screen: pick one (here or in 3D) and move it.
struct BedFixturesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Stop and clamps") {
            if model.bedEditable, let p = model.currentBedPlacement {
                let o = model.currentBedOverride
                if let sel = model.bedSelection {
                    HStack {
                        Label(sel.title, systemImage: "hand.point.up.left").font(.callout.weight(.semibold))
                        Spacer()
                        Button("Deselect") { model.bedSelection = nil }.controlSize(.small)
                    }
                }
                switch model.bedSelection {
                case .stop:
                    NumberField(title: "Along the T-slots", value: Binding(
                        get: { o.stopShiftY },
                        set: { v in let r = model.stopRange; model.editPrep { $0.stopShiftY = min(max(v.rounded(), -r), r) } }),
                                tip: "The stop slides in the T-slots; the bar sits against it and moves with it. Up to ±\(Length.mm(model.stopRange)) mm keeps both ends of the bar in the spindle's reach.")
                case .clamp(let i) where i < p.clampPoints.count:
                    let c = i < o.clamps.count ? o.clamps[i] : ClampOverride()
                    let angle = i < p.clampAngles.count ? p.clampAngles[i] : 0
                    NumberField(title: "Along the bar", value: Binding(get: { c.dy }, set: { v in model.editPrep { $0.clamps[i].dy = v } }),
                                tip: "Moves the pad along the bar (Y), from where Coastline put it.")
                    NumberField(title: "Toward the spindle", value: Binding(get: { c.dz }, set: { v in model.editPrep { $0.clamps[i].dz = v } }),
                                tip: "Moves the pad across the bar (Z). Further forward holds the cut better, but the frame has to reach around the bed's back edge and the pad must stay out of the cutter's way.")
                    LabeledContent("Turned") {
                        HStack {
                            Slider(value: Binding(get: { angle * 180 / .pi }, set: { v in model.setClampAngle(i, (v / 5).rounded() * 5 * .pi / 180) }),
                                   in: -80...80)
                                .accessibilityLabel("Turned")
                                .accessibilityValue("\(Int((angle * 180 / .pi).rounded())) degrees")
                            Text("\(Int((angle * 180 / .pi).rounded()))°").monospacedDigit().frame(width: 36, alignment: .trailing)
                        }
                    }
                    HStack {
                        Button("Square") { model.setClampAngle(i, 0) }
                        Button("45°") { model.setClampAngle(i, (i == 0 ? -1 : 1) * .pi / 4) }
                        Button("Reach onto the Bar") { model.snapClampToBedEdge(i) }
                            .help("Puts the pad as far onto the bar as the frame allows: its back against the bed's back edge.")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                default:
                    Text("Press on the stop, the bar or a C-clamp in 3D and drag it. A picked C-clamp also turns with its red ring; its numbers show here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !o.isEmpty {
                    Button("Back to the Proposal for This Clamping", systemImage: "arrow.uturn.backward") { model.resetClamping() }
                }
                if case .clamp(let i) = model.bedSelection, model.collisions.contains(where: { $0.a == "C-clamp \(i + 1)" || $0.b == "C-clamp \(i + 1)" }) {
                    Button("Find a Place That Doesn't Collide", systemImage: "wand.and.stars") { Task { await model.resolveClampCollision(i) } }
                        .buttonStyle(.borderedProminent)
                }
                let issues = model.bedIssues
                if issues.isEmpty {
                    Label("The clamps hold the bar and stay clear of the cutter.", systemImage: "checkmark.circle").foregroundStyle(.green)
                } else {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, i in
                        Label(i.message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    }
                }
            } else {
                Text(model.setup.onBed ? "Show side A to move the stop and C-clamps." : "Show a clamping above to move its stop and C-clamps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Stage 4 on path B: the stock on the bed for the whole job.
struct BedJobInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if let st = model.bedJobStage {
                Section("On the bed") {
                    LabeledContent("Stock", value: "\(Length.mm(st.stock.x)) × \(Length.mm(st.stock.y)) × \(Length.mm(st.stock.z)) mm")
                    LabeledContent("Deepest cut", value: "\(Length.mm(st.cut)) mm")
                    LabeledContent("Face past the stop", value: "\(Length.mm(st.protrusion)) mm")
                    Text("The stock lies on the riser plate with one end against the acetal stop; two 3\" C-clamps hold it behind the area that gets cut. One side only: the part stays joined to the bar and is sawn off after.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                BedFixturesSection()
            }
        }
        .formStyle(.grouped)
        .darkPanel()
    }
}

/// Stage 6: what's ready, the tour and the export.
struct ReviewInspector: View {
    @Environment(AppModel.self) private var model
    @State private var recording: JournalEntry?

    var body: some View {
        Form {
            Section {
                Button { model.startTour() } label: { Label("Walk Through the Job (Tour)", systemImage: "play.rectangle.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent)
                    .disabled(model.programs.isEmpty)
                Text("Every step in order: the stock moving between clampings, edge finding, each program played through, the measuring checkpoints.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.programs.isEmpty { ResultsSection() }
            Section {
                Button { recording = model.draftJournalEntry() } label: {
                    Label("Record This Job in the Journal…", systemImage: "book.closed").frame(maxWidth: .infinity)
                }
                .disabled(model.programs.isEmpty)
                Text("After it ran on the machine: what you measured, how it went, photos. Tool wear, the stock and the feeds learn from it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .darkPanel()
        .sheet(item: $recording) { e in RecordJobSheet(entry: e) }
    }
}
