import AppKit
import CoastlineCore
import SwiftUI

/// The Machining tab: operations, tools, cutting data, generation, safety and export.
struct MachiningInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
        Form {
            if model.part == nil || model.stock == nil {
                ContentUnavailableView("Set Up First", systemImage: "cube.transparent",
                                       description: Text("Import a part and choose stock on the Setup tab."))
            } else {
                let toBuy = model.jobToolsToBuy
                if !toBuy.isEmpty {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("This job needs \(toBuy.count == 1 ? "a tool" : "\(toBuy.count) tools") you don't have yet").font(.callout.weight(.semibold))
                                Text(toBuy.map(\.name).joined(separator: ", ") + ". They're on your Shopping List; the toolpaths and the simulation already use them.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Open the Shopping List") { model.page = .shopping }.buttonStyle(.link).font(.caption)
                            }
                        } icon: {
                            Image(systemName: "cart.badge.plus").foregroundStyle(Theme.accent)
                        }
                    }
                }
                Section {
                    if let m = model.stock?.material {
                        LabeledContent("Material") { Badge(text: m.name, color: Theme.color(m.difficulty)) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            Task { await model.findPlans(inventory: inventory.inventory) }
                        } label: {
                            Group {
                                if model.isFindingPlans {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small).tint(.white)
                                        Text("Comparing plans…")
                                    }
                                } else {
                                    Label("Find the Best Plan", systemImage: "sparkles")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(model.isFindingPlans)
                        .help("Costs every sensible plan your tools allow (roughing tool and step, finishing strategy, ball, cusp height, rest pass) and shows the best trade-offs between time, finish and risk.")
                        HStack {
                            Button("Or a Quick Suggestion", systemImage: "wand.and.stars") {
                                Task { await model.suggestOperations(inventory: inventory.inventory) }
                            }
                            .plainGlassButton()
                            .help("One reasonable plan from rules of thumb, without comparing alternatives.")
                            Spacer()
                            InfoTip(text: "Find the Best Plan costs every plan your tools allow (and ones with a tool to buy): roughing tool and step, finishing strategy, ball, cusp, rest pass. Then it shows the best trade-offs between time, finish and risk, each with its reasons. It takes a few seconds. A quick suggestion is one sensible plan from rules of thumb, at once, without comparing.")
                        }
                    }
                    if !model.planCandidates.isEmpty || !model.planOptions.isEmpty { PlanOptionsView() }
                    ForEach(model.planNotes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text("Plan")
                }

                if !model.operations.isEmpty {
                    TunerSection().id("tuner")
                    Section("Operations") {
                        ForEach($model.operations) { $op in
                            OperationRow(operation: $op)
                                .contextMenu {
                                    Button("Delete Operation", systemImage: "trash", role: .destructive) {
                                        model.operations.removeAll { $0.id == op.id }
                                    }
                                }
                        }
                        .onDelete { model.operations.remove(atOffsets: $0) }
                        Menu("Add Operation", systemImage: "plus") {
                            ForEach(OperationKind.allCases.filter { $0 != .chamfer }, id: \.self) { kind in
                                Button(kind.title, systemImage: kind.symbol) {
                                    var op = Operation(kind: kind)
                                    if kind == .thread { model.prepareThread(&op, inventory: inventory.inventory) }
                                    if kind == .engrave {
                                        op.engraving = Engraving(text: "Coastline")
                                        // The finest engraving-capable tool you have.
                                        op.toolID = OperationPlanner.usableTools(inventory.inventory)
                                            .filter { [.engraver, .chamferMill, .flatEndMill, .ballEndMill].contains($0.kind) && $0.diameter <= 3.2 }
                                            .min { ($0.kind == .engraver ? 0 : 1, $0.diameter) < ($1.kind == .engraver ? 0 : 1, $1.diameter) }?.id
                                    }
                                    model.justAddedOperation = op.id
                                    model.operations.append(op)
                                }
                            }
                            Divider()
                            Button("Texture (guilloché, clous de Paris…)", systemImage: "circle.hexagongrid") {
                                var op = Operation(kind: .engrave)
                                var e = Engraving(text: "", depth: 0.08)
                                e.texture = .preset(.barleycorn)
                                op.engraving = e
                                // A V engraver if you have one (crisp lines), else the finest tool that engraves.
                                op.toolID = OperationPlanner.usableTools(inventory.inventory)
                                    .filter { [.engraver, .chamferMill, .ballEndMill, .flatEndMill].contains($0.kind) && $0.diameter <= 3.2 }
                                    .min { ($0.kind == .engraver ? 0 : 1, $0.diameter) < ($1.kind == .engraver ? 0 : 1, $1.diameter) }?.id
                                model.justAddedOperation = op.id
                                model.operations.append(op)
                            }
                        }
                        .menuStyle(.borderlessButton)
                    }
                }

                if !model.programs.isEmpty { ResultsSection() }
            }
        }
        .formStyle(.grouped)
        .darkPanel()
        .scrollEdgeEffectStyle(.soft, for: .all)
        // Generate and its progress stay put at the bottom (like the stage header at the top):
        // never scrolled away.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.part != nil && model.stock != nil { GenerateBar() }
        }
        .onChange(of: model.inspectorScrollTarget) { _, id in
            guard let id else { return }
            withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id, anchor: .top) }
            model.inspectorScrollTarget = nil
        }
        }
    }
}

/// One operation: enable, tool, and the computed cutting data with its reasoning.
struct OperationRow: View {
    @Binding var operation: Operation
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory
    @State private var expanded = false

    private var compatibleTools: [Tool] {
        OperationPlanner.usableTools(inventory.inventory).filter { t in
            switch operation.kind {
            case .drill: [.drill, .spotDrill].contains(t.kind)
            case .chamfer: [.chamferMill, .engraver].contains(t.kind)
            case .engrave: [.engraver, .chamferMill, .flatEndMill, .ballEndMill].contains(t.kind) && t.diameter <= 3.2
            case .thread: false  // threadMills below (they need their own collet: often not in the inventory yet)
            case let k where k.is3D: [.ballEndMill, .bullNoseEndMill, .flatEndMill].contains(t.kind)
            default: [.flatEndMill, .bullNoseEndMill].contains(t.kind)
            }
        }
    }

    private var tool: Tool? { operation.toolID.flatMap { id in inventory.inventory.tools.first { $0.id == id } } }

    /// The tools the picker offers: thread milling lists every thread mill you have or
    /// Coastline suggests (to buy), whatever its collet.
    private var choices: [Tool] {
        guard operation.kind == .thread else { return compatibleTools }
        return inventory.inventory.tools.filter { $0.kind == .threadMill && $0.condition != .broken && ($0.quantity > 0 || $0.isSuggestion) }
            .sorted { ($0.quantity > 0 ? 0 : 1, $0.diameter) < ($1.quantity > 0 ? 0 : 1, $1.diameter) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded || model.justAddedOperation == operation.id },
                                            set: { expanded = $0; if !$0, model.justAddedOperation == operation.id { model.justAddedOperation = nil } })) {
            Picker("Tool", selection: $operation.toolID) {
                Text("Choose…").tag(UUID?.none)
                ForEach(choices) { t in Text(t.isSuggestion ? "\(t.name) (to buy)" : t.name).tag(Optional(t.id)) }
            }
            Text(operation.explanation).font(.caption).foregroundStyle(.secondary)
            if operation.kind == .thread {
                ThreadFields(operation: $operation, tool: tool)
            }
            if [.adaptive].contains(operation.kind) {
                NumberField(title: "Leave on walls", value: $operation.leaveRadial,
                            tip: "Material left on the walls for the finishing pass. More is safer for the finish but makes the finisher work harder; 0.1–0.3 mm is typical.")
                NumberField(title: "Leave on floors", value: $operation.leaveAxial,
                            tip: "Material left on floors and curved tops for the finishing tools.")
                OptionalNumberField(title: "Depth per pass", value: $operation.stepdownOverride, unit: "mm")
                    .help("Blank = Coastline decides. Deeper passes use more of the flute (faster, even wear); on curved parts smaller steps leave smaller terraces for the ball finisher.")
            }
            if operation.kind == .facing {
                NumberField(title: "Face depth", value: $operation.faceDepth,
                            tip: "How much comes off the stock face. It sets where Z0 ends up, so measure the stock thickness after facing.")
            }
            if operation.kind == .engrave {
                EngravingFields(engraving: Binding(get: { operation.engraving ?? Engraving(text: "") }, set: { operation.engraving = $0 }))
            }
            if operation.kind == .contour {
                Toggle("Spring pass", isOn: $operation.springPass)
                    .help("Repeats the last pass at the same depth to take out tool deflection: better size and finish for a little more time.")
            }
            if operation.kind.is3D {
                NumberField(title: "Cusp height", value: Binding(get: { operation.scallop * 1000 }, set: { operation.scallop = max($0, 0.5) / 1000 }), unit: "µm",
                            tip: "The ridges left between passes. Halving it adds about 40 % more passes (time). 8 µm is a fine finish for polishing; 20 µm is a quicker semi-finish.")
                if [.parallel, .steepShallow, .rest].contains(operation.kind) {
                    NumberField(title: "Pass angle", value: $operation.angle, unit: "°",
                                tip: "Direction of the straight passes. Run them along long features so the cusps follow the shape.")
                }
                if operation.kind == .steepShallow {
                    NumberField(title: "Steep from", value: $operation.steepAngle, unit: "°",
                                tip: "Surfaces steeper than this get waterline passes, shallower ones parallel passes. 40–50° gives the most even finish.")
                }
            }
            if let tool, let m = model.stock?.material {
                let d = operation.cuttingData(tool: tool, material: m)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Speed").foregroundStyle(.secondary); Text("\(Int(d.rpm)) RPM") }
                    GridRow { Text("Feed").foregroundStyle(.secondary); Text("\(Int(d.feed)) mm/min · plunge \(Int(d.plungeFeed))") }
                    GridRow { Text("Chip load").foregroundStyle(.secondary); Text("\(d.chipLoad.formatted(.number.precision(.fractionLength(3)))) mm/tooth") }
                    if d.stepdown > 0 { GridRow { Text(operation.kind == .drill ? "Peck" : "Depth/pass").foregroundStyle(.secondary); Text("\(Length.mm(d.stepdown)) mm") } }
                    if d.stepover > 0 { GridRow { Text("Stepover").foregroundStyle(.secondary); Text("\(Length.mm(d.stepover)) mm") } }
                    GridRow { Text("Power").foregroundStyle(.secondary); Text("≈ \(Int(d.power.rounded())) W") }
                }
                .font(.callout.monospacedDigit())
                ForEach(d.notes, id: \.self) { Label($0, systemImage: "lightbulb").font(.caption).foregroundStyle(.secondary) }
            }
            if let path = model.toolpaths[operation.id] {
                ForEach(path.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning) }
                ForEach(path.notes, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            }
        } label: {
            HStack(spacing: 8) {
                Toggle(operation.title, isOn: $operation.enabled).labelsHidden().toggleStyle(.checkbox)
                Image(systemName: operation.symbol).foregroundStyle(Theme.accent).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(operation.title)
                    Text(tool?.name ?? "No tool chosen").font(.caption).foregroundStyle(tool == nil ? Theme.warning : .secondary)
                        .lineLimit(1)
                        .help(tool?.name ?? "No tool chosen")
                }
                Spacer()
                switch model.genState(for: operation.id) {
                case .queued? where model.isGenerating:
                    Image(systemName: "circle.dotted").foregroundStyle(.secondary).help("Waiting to be generated")
                        .accessibilityLabel("Waiting to be generated")
                case .running? where model.isGenerating:
                    ProgressView { Text("Generating now") }.labelsHidden().controlSize(.mini).help("Generating now")
                case .failed(let why)?:
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger).help("Failed: \(why) Retry redoes only this one.")
                        .accessibilityLabel("Failed")
                        .accessibilityValue(why)
                default:
                    EmptyView()
                }
                if let path = model.toolpaths[operation.id], !path.warnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).help(path.warnings.joined(separator: "\n"))
                        .accessibilityLabel("\(path.warnings.count) warning\(path.warnings.count == 1 ? "" : "s")")
                        .accessibilityValue(path.warnings.joined(separator: ". "))
                }
            }
            .opacity(operation.enabled ? 1 : 0.5)
            .help(operation.explanation)
        }
    }
}

/// Programs, safety checks, time and export.
struct ResultsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory
    @State private var exportMessage: String?

    var body: some View {
        Section {
            LabeledContent("Machining time", value: "≈ " + AppModel.duration((model.programs + model.prepPrograms).reduce(0) { $0 + $1.seconds }))
            if let note = model.bridgeNote {
                Label(note, systemImage: "rectangle.connected.to.line.below").font(.caption).foregroundStyle(Theme.warning)
            }
            ForEach(model.prepPrograms) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: p.report.passed ? "checkmark.shield.fill" : "xmark.shield.fill")
                            .foregroundStyle(p.report.passed ? Theme.ok : Theme.danger)
                            .accessibilityLabel(p.report.passed ? "Passed safety check" : "Failed safety check")
                        Text("Prep · \(p.opsTitle)").font(.callout.weight(.medium)).lineLimit(1)
                            .help("Prep · \(p.opsTitle)")
                    }
                    Text("\(p.tool.name) · on the side clamps · \(p.report.lineCount) lines · ≈ \(AppModel.duration(p.seconds))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .help("Squaring and milling the stock down to fit the clamp kit, on the acetal brick and eccentric clamps. Buying stock the right size saves this time.")
            }
            if model.twoSided, let part = model.part, let stock = model.stock {
                let b = model.setupFor(side: 1)
                let (lo, hi) = model.setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
                let ideal = (hi.z - lo.z) + 2 * model.setup.topAllowance + 1
                if b.topAllowance > 3 {
                    let backing = model.programs.filter { $0.side == 1 && $0.operations.contains { $0.kind == .facing } }.reduce(0) { $0 + $1.seconds }
                    Label("Side B first faces off \(Length.mm(b.topAllowance - 0.5)) mm of backing (about \(AppModel.duration(backing))). Stock about \(Length.mm(ideal.rounded(.up))) mm thick instead of \(Length.mm(model.setup.stockSize(stock).z)) mm would save most of that.",
                          systemImage: "lightbulb")
                        .font(.callout).foregroundStyle(Theme.warning)
                }
            }
            if let t = model.travelIssue {
                Label(t + ". Move the stock on the table, use a shorter stick-out, or turn the part.", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Theme.danger).font(.callout)
            }
            LabeledContent("Tool changes", value: "\(max(model.programs.count - 1, 0))")
            ForEach(model.programs) { p in ProgramRow(program: p) }
            Button("Export Guided Job for CRWrite…", systemImage: "list.bullet.rectangle.portrait") { exportGuided() }
            Button("Print a Nest for a Second Side…", systemImage: "cube.transparent") { model.showNestSheet = true }
                .help("A printed block shaped like one face of the part, to hold it once it's cut free and machine the other face.")
                .buttonStyle(.glassProminent)
                .disabled(!model.programs.allSatisfy(\.report.passed))
                .help("A .crproj with every step: mounting, edge finding, tool changes, air cuts, cuts and measuring checkpoints")
            Button("Export G-code Only…", systemImage: "square.and.arrow.up") { export() }
                .plainGlassButton()
                .disabled(!model.programs.allSatisfy(\.report.passed))
            // Say why the buttons are disabled, and what to do about it.
            let failed = model.programs.filter { !$0.report.passed }.count
            if failed > 0 {
                Label(failed == 1 ? "Fix the program that failed the safety check to export."
                                  : "Fix the \(failed) programs that failed the safety check to export.",
                      systemImage: "xmark.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let exportMessage { Text(exportMessage).font(.caption).foregroundStyle(.secondary) }
        } header: {
            HStack {
                Text("Result")
                InfoTip(text: "Every program is checked independently against the CR-1's limits before it can be exported. Always air-cut a new program first (spindle off, Z raised).")
            }
        }
    }

    private func exportGuided() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "crproj") ?? .data]
        panel.nameFieldStringValue = ((model.part?.fileName as NSString?)?.deletingPathExtension ?? "Coastline") + ".crproj"
        panel.message = "Save the guided job. Open it in CRWrite's Guided Mode."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportGuidedJob(to: url, measuring: inventory.inventory.measuring)
            exportMessage = "Saved \(url.lastPathComponent)."
            if let app = AppModel.crwriteURL {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            exportMessage = error.localizedDescription
        }
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the G-code programs (one per tool)."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let urls = try model.exportPrograms(to: folder)
            exportMessage = "Saved \(urls.count) file\(urls.count == 1 ? "" : "s") to \(folder.lastPathComponent)."
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } catch {
            exportMessage = "\(error.localizedDescription)"
        }
    }
}


/// One tool program: a line with its check, tool and time; open it for the operations, the
/// checks' findings and the notes. A program that failed its check opens by itself.
struct ProgramRow: View {
    let program: ToolProgram
    @Environment(AppModel.self) private var model
    @State private var open: Bool?

    var body: some View {
        let p = program
        let notes = p.report.issues.count + p.warnings.count
        DisclosureGroup(isExpanded: Binding(get: { open ?? !p.report.passed }, set: { open = $0 })) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(p.operations.map(\.title).joined(separator: ", ")) · \(Int(p.rpm)) RPM · \(p.report.lineCount) lines")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(p.report.issues) { issue in
                    Label(issue.message, systemImage: Theme.symbol(issue.severity))
                        .font(.caption).foregroundStyle(Theme.color(issue.severity))
                }
                ForEach(p.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
                }
                if let need = p.minStickout {
                    let spare = p.tool.stickout - need
                    if spare >= 0 {
                        Label(spare > 4
                              ? "Stick-out \(Length.mm(p.tool.stickout)) mm; \(Length.mm(max(need, p.tool.fluteLength).rounded(.up))) mm is enough here. Shorter is stiffer: better finish, less chatter."
                              : "Collet nut clears the work by \(Length.mm(spare + 1)) mm at the deepest point.",
                              systemImage: "ruler").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: p.report.passed ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .foregroundStyle(p.report.passed ? Theme.ok : Theme.danger)
                    .accessibilityLabel(p.report.passed ? "Passed safety check" : "Failed safety check")
                Text("\(model.twoSided ? (p.side == 0 ? "A · " : "B · ") : "")\(p.index + 1) · \(p.tool.name.components(separatedBy: " · ").first ?? p.tool.name)")
                    .lineLimit(1)
                    .help(p.tool.name)
                Spacer(minLength: 4)
                if notes > 0 {
                    Text("\(notes)").font(.caption2.weight(.semibold)).padding(.horizontal, 5)
                        .background(Capsule().fill((p.report.passed ? Theme.warning : Theme.danger).opacity(0.25)))
                        .help("\(notes) finding\(notes == 1 ? "" : "s"): open to read")
                }
                Text(AppModel.duration(p.seconds)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

/// Text to engrave: what, which font, how big and deep, where on the face.
struct EngravingFields: View {
    @Binding var engraving: Engraving
    @Environment(AppModel.self) private var model
    static let fonts = ["Helvetica-Bold", "Avenir-Heavy", "Futura-Bold", "Gill Sans Bold", "Georgia-Bold", "Didot-Bold",
                        "Copperplate-Bold", "SnellRoundhand-Bold", "Zapfino"]

    var body: some View {
        if engraving.texture != nil {
            TextureFields(texture: Binding(get: { engraving.texture ?? .preset(.barleycorn) }, set: { engraving.texture = $0 }))
        } else {
        TextField("Text", text: $engraving.text)
        Picker("Font", selection: $engraving.font) {
            ForEach(Self.fonts, id: \.self) { Text($0.replacingOccurrences(of: "-", with: " ")).font(.custom($0, size: 13)).tag($0) }
        }
        NumberField(title: "Letter height", value: $engraving.height, tip: "Capital-letter height. Lines under about 3× the tool's width fill in; a 0.5 mm tool wants letters of 2.5 mm or more.")
        }
        NumberField(title: "Depth", value: $engraving.depth, tip: "Below the surface, everywhere (it follows a dome). 0.1–0.2 mm reads well and polishes cleanly.")
        NumberField(title: "Up / down (X)", value: $engraving.x)
        NumberField(title: "Left / right (Y)", value: $engraving.y)
        NumberField(title: "Turn", value: $engraving.angle, unit: "°")
        Picker("On", selection: $engraving.side) {
            Text("Side A (the face)").tag(0)
            Text("Side B (the back)").tag(1)
        }
        Toggle(isOn: Binding(get: { engraving.probeSurface == true }, set: { engraving.probeSurface = $0 ? true : nil })) {
            Text("Follow the real face")
            Text("Probes the face at up to \(SurfaceProbe.maxPoints) points first, so the depth stays even on stock that isn't flat or square (CRWrite's contour map). Flat faces only.")
        }
        if engraving.probeSurface == true, let why = probeUnavailable {
            Label(why, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
        }
        let size = engraving.size
        if size.x > 0 {
            Text("\(Length.mm(size.x)) × \(Length.mm(size.y)) mm on the face (purple outline in 3D).").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Why probing can't be used in this job, if it can't.
    private var probeUnavailable: String? {
        if model.setup.onBed || AppSettings.shared.clampKitProbing != .electrical {
            return "Needs the insulated clamp kit with electrical probing (Settings ▸ Machining): until then it follows the CAD."
        }
        if let m = model.stock?.material, [.wax, .plastic, .printedResin].contains(m.family) {
            return "\(m.name) doesn't conduct, so the tool can't feel it: it follows the CAD."
        }
        return nil
    }
}

/// The bottom of the Machining panel: Generate (only when the setup is done and the
/// operations have their tools), then the progress and Cancel while it runs.
struct GenerateBar: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isGenerating {
                HStack(spacing: 10) {
                    ProgressView(value: model.generationProgress ?? 0) { Text("Generating toolpaths") }
                        .labelsHidden()
                    Button("Cancel") { model.cancelGenerationNow() }
                        .controlSize(.small)
                        .help("Stops now; the operations already done stay and are reused next time (⌘.)")
                }
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.status)
            } else {
                let blocker = model.generationBlocker
                expectedTime
                Button {
                    Task { await model.generateOrApply(inventory: inventory.inventory) }
                } label: {
                    Text(model.generateTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(blocker != nil)
                .help("Operations generate in the background, several at once; each chapter's toolpaths show (and simulate) as soon as they're ready. Unchanged operations are reused. (⌘G)")
                if let blocker {
                    Label(blocker, systemImage: "arrow.turn.left.up").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// The machining time to expect with the settings as they are now (the tuner's estimate
    /// once generated, the plan's before), and how it moved: always in view, one fixed line.
    private var expectedTime: some View {
        let generated = (model.programs + model.prepPrograms).reduce(0) { $0 + $1.seconds } / 60
        let now: Double? = model.programs.isEmpty
            ? model.plannedMinutes
            : model.tunerEstimate(model.tuning).map { $0.minutes + model.prepPrograms.reduce(0) { $0 + $1.seconds } / 60 }
        return HStack(spacing: 6) {
            Image(systemName: "clock").foregroundStyle(.secondary)
            Text("Expected").foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let now {
                Text("≈ \(AppModel.duration(now * 60))").monospacedDigit().fontWeight(.semibold)
                if !model.programs.isEmpty, abs(now - generated) >= 1 {
                    Text("(\(now < generated ? "−" : "+")\(AppModel.duration(abs(now - generated) * 60)))")
                        .monospacedDigit().foregroundStyle(now < generated ? Theme.ok : Theme.warning)
                        .help("Against the toolpaths as generated (≈ \(AppModel.duration(generated * 60))). Apply & Regenerate to make it so.")
                }
            } else {
                Text("after a plan").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .frame(height: 18)
        .help(model.programs.isEmpty ? "The plan's estimate (simulated time follows once generated)." : "From the generated toolpaths, scaled to the settings above.")
    }
}

extension AppModel {
    /// The tuner changed since the toolpaths were made: Generate becomes Apply & Regenerate.
    var tuningChangedSinceGenerating: Bool { !programs.isEmpty && tuning != generatedTuning }

    /// What Generate does now (the button, and the Toolpaths menu).
    var generateTitle: String {
        let failed = failedOperationCount
        return failed > 0 ? "Retry \(failed == 1 ? "the Failed Operation" : "the \(failed) Failed Operations")"
            : tuningChangedSinceGenerating ? "Apply & Regenerate" : "Generate Toolpaths"
    }

    /// Generate, or Apply & Regenerate after the tuner changed (the button and ⌘G).
    func generateOrApply(inventory: Inventory) async {
        guard part != nil, stock != nil, !isGenerating else { return }
        if let blocker = generationBlocker {
            status = blocker
            NSSound.beep()
            return
        }
        if tuningChangedSinceGenerating { await applyTuning(inventory: inventory) }
        else { await generateToolpaths(inventory: inventory) }
    }
}

/// Thread milling: which thread, how deep, which holes it goes into, and whether the cutter suits.
struct ThreadFields: View {
    @Binding var operation: Operation
    let tool: Tool?
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory

    var body: some View {
        let setting = operation.thread ?? ThreadMilling(spec: "M3")
        let spec = setting.thread
        Picker("Thread", selection: Binding(get: { setting.spec }, set: { operation.thread = ThreadMilling(spec: $0, depth: setting.depth) })) {
            ForEach(ThreadSpec.metricCoarse) { Text($0.title).tag($0.name) }
        }
        OptionalNumberField(title: "Thread depth", value: Binding(get: { setting.depth }, set: { operation.thread = ThreadMilling(spec: setting.spec, depth: $0) }), unit: "mm")
            .help("Blank = the hole's whole depth, as far as the cutter reaches. 1.5 × the diameter holds as well as a nut.")
        if let spec {
            let holes = (model.features?.holes ?? []).filter { spec.fits(hole: $0.diameter) }
            Label(holes.isEmpty
                  ? "No hole is made for it: model the hole at the tap-drill size, Ø\(Length.mm(spec.tapDrill)) mm (\(Length.mm(spec.holeRange.lowerBound))–\(Length.mm(spec.holeRange.upperBound)) works)."
                  : "Threads \(holes.count) hole\(holes.count == 1 ? "" : "s") of Ø\(Length.mm(holes[0].diameter)) mm, after the operations that make them.",
                  systemImage: holes.isEmpty ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.caption).foregroundStyle(holes.isEmpty ? Theme.warning : .secondary)
            if let tool {
                if !spec.canBeCut(by: tool) {
                    Label("The \(tool.name) can't cut \(spec.title): \(tool.kind != .threadMill ? "it isn't a thread mill" : tool.diameter >= spec.tapDrill - 0.05 ? "it's too big for the hole" : "its profile is for another pitch").",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
                }
                if !inventory.inventory.colletSizes.contains(where: { abs($0 - tool.shankDiameter) <= 0.05 }) {
                    Label("Needs a \(Length.mm(tool.shankDiameter)) mm ER-11 collet: there's none in your inventory (Accessories).",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
                }
            }
        }
    }
}

/// A texture's pattern and size, with a drawing of its lines.
struct TextureFields: View {
    @Binding var texture: Texture

    var body: some View {
        Picker("Pattern", selection: Binding(get: { texture.pattern }, set: { p in
            // A new pattern starts from its own good values, keeping the area.
            var t = Texture.preset(p)
            t.region = texture.region
            t.width = texture.width
            t.height = texture.height
            texture = t
        })) {
            ForEach(Texture.Pattern.allCases) { Text($0.title).tag($0) }
        }
        Picker("Area", selection: $texture.region) {
            Text("Circle").tag(Texture.Region.circle)
            Text("Rectangle").tag(Texture.Region.rectangle)
        }
        .pickerStyle(.segmented)
        NumberField(title: texture.region == .circle ? "Diameter" : "Width (along)", value: $texture.width)
        if texture.region == .rectangle { NumberField(title: "Height (up)", value: $texture.height) }
        NumberField(title: "Line spacing", value: $texture.pitch,
                    tip: "Between neighbouring lines. With a V engraver the line's width grows with depth: lines meet when the depth is about half the spacing (90° V) — clous de Paris wants exactly that, the others less.")
        if texture.pattern.waves {
            NumberField(title: texture.pattern == .sunburst ? "Wave" : texture.pattern == .rosette ? "Offset" : "Wave height", value: $texture.amplitude,
                        unit: texture.pattern == .sunburst ? "°" : "mm",
                        tip: texture.pattern == .rosette ? "How far each circle's centre sits from the middle: bigger makes longer petals." : "How far the lines swing. 0 gives straight lines or plain rings.")
            if texture.pattern != .rosette {
                Stepper("\(texture.pattern == .flinque ? "Waves across" : "Lobes"): \(texture.lobes)", value: $texture.lobes, in: 0...60)
            }
        }
        Canvas { ctx, size in
            let lines = texture.lines()
            let s = texture.size
            let k = min(size.width / max(s.x, 0.1), size.height / max(s.y, 0.1)) * 0.92
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            var path = Path()
            for line in lines where line.count > 1 {
                path.move(to: CGPoint(x: c.x + line[0].x * k, y: c.y - line[0].y * k))
                for p in line.dropFirst() { path.addLine(to: CGPoint(x: c.x + p.x * k, y: c.y - p.y * k)) }
            }
            ctx.stroke(path, with: .color(.secondary), lineWidth: 0.6)
        }
        .frame(height: 140)
        .accessibilityLabel("Drawing of the \(texture.pattern.title) texture")
        let n = texture.lines().count
        Text("\(n) line\(n == 1 ? "" : "s"), \(Length.mm(texture.size.x)) × \(Length.mm(texture.size.y)) mm. Depth, position and turn are the engraving's below.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

