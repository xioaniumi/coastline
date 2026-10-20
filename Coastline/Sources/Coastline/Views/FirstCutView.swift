import AppKit
import CoastlineCore
import SwiftUI

/// The first cut on the real CR-1 (docs/FIRST_CUT.md) as a checklist: every stage in order,
/// ticked off as you go (remembered), with the buttons that do each stage's part in Coastline:
/// the test coupon, the guided job, the coupon in POM and aluminium, recording what you measured.
/// Never skip a stage for a new kind of operation.
struct FirstCutStage: Identifiable {
    enum Action { case openCoupon, exportJob, material(String), record }
    var id: String
    var title: String
    var detail: [String]
    var action: Action?
}

enum FirstCut {
    static let stages: [FirstCutStage] = [
        .init(id: "crwrite", title: "CRWrite basics", detail: [
            "Connect, check the DRO, home with $H, jog in both modes and check the soft limits (CRWrite's own checklist).",
        ]),
        .init(id: "coupon", title: "Open the test coupon", detail: [
            "34 × 24 × 6 in machinable wax, with only tools you have: facing, the outline, a pocket, two holes and a step.",
            "About 8 minutes of cutting. Every feature has a size to measure afterwards.",
        ], action: .openCoupon),
        .init(id: "export", title: "Export the guided job", detail: [
            "Machining ▸ Export Guided Job for CRWrite, then open it in CRWrite and pick the job.",
        ], action: .exportJob),
        .init(id: "dry", title: "Dry run: no stock, no tool", detail: [
            "Run the helper steps (home, tool-change position) and watch where the spindle goes.",
        ]),
        .init(id: "edge", title: "Edge finding on scrap", detail: [
            "Clamp a scrap block and edge-find X and Y.",
            "In CRWrite, G54 X/Y should now be the middle of the block: jog to X0 Y0 to see it.",
        ]),
        .init(id: "air", title: "Touch off and air cut", detail: [
            "Fit the tool at the stick-out shown and touch off with paper.",
            "Answer Yes to the air cut: the whole program runs 10 mm above the work with the spindle off. Stop if anything goes somewhere unexpected.",
        ]),
        .init(id: "wax", title: "Cut it in wax", detail: [
            "Run the cut. Measure at each checkpoint and write the numbers down.",
            "Then record the job: the measurements, the finish, any chatter. The feeds learn from it.",
        ], action: .record),
        .init(id: "pom", title: "Then in POM", detail: [
            "The same coupon from a 40 × 20 POM bar: Coastline switches the stock and generates again (feeds for POM).",
            "Air-cut it first again (new feeds), then cut, measure and record.",
        ], action: .material("pom")),
        .init(id: "alu", title: "Then in aluminium", detail: [
            "From a 40 × 20 bar of 6061: WD-40 mist, and vacuum between tools (never compressed air).",
            "Air cut, cut, measure, record.",
        ], action: .material("al-6061")),
    ]

    /// The bar each stage's coupon is cut from (StockCatalog's standard sizes, 40 tall on the jaw).
    static func bar(material: String) -> SIMD3<Double> {
        switch material {
        case "pom": SIMD3(100, 40, 20)
        case "al-6061": SIMD3(150, 40, 20)
        default: SIMD3(100, 38, 25)
        }
    }
}

struct FirstCutView: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory
    @AppStorage("firstCutDone") private var doneRaw = ""
    @AppStorage("firstCutNotes") private var notes = ""
    @AppStorage("firstCutSettings") private var settingsRaw = ""
    @State private var recording: JournalEntry?
    @State private var message: String?

    private var done: Set<String> { Set(doneRaw.split(separator: ",").map(String.init)) }

    private func setDone(_ id: String, _ on: Bool) {
        var d = done
        if on { d.insert(id) } else { d.remove(id) }
        doneRaw = FirstCut.stages.map(\.id).filter(d.contains).joined(separator: ",")
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("First Cut on the CR-1").font(.title2.weight(.semibold))
                    Text("Coastline has only run against CRWrite's simulated mill so far. Bring it up on the machine in this order, and never skip a stage for a new kind of operation.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: Double(done.count), total: Double(FirstCut.stages.count)) {
                        Text("\(done.count) of \(FirstCut.stages.count) done").font(.caption).foregroundStyle(.secondary)
                    }
                    .tint(Theme.accent)
                }
                .padding(.vertical, 4)
            }
            Section("Stages") {
                ForEach(Array(FirstCut.stages.enumerated()), id: \.element.id) { n, stage in
                    stageRow(n + 1, stage)
                }
            }
            if let message {
                Section { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
            settingsSection
            Section {
                TextEditor(text: $notes)
                    .font(.callout)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Calibration notes")
            } header: {
                Text("Calibration notes")
            } footer: {
                Text("Where the table top and spindle nose really are (home, jog the tool tip onto the table, read the DRO), and spindle power in practice: stalls or chatter with their depth of cut, stepover and material.")
            }
        }
        .formStyle(.grouped)
        .darkPanel()
        .sheet(item: $recording) { e in RecordJobSheet(entry: e) }
    }

    private func stageRow(_ n: Int, _ stage: FirstCutStage) -> some View {
        let isDone = done.contains(stage.id)
        return HStack(alignment: .top, spacing: 12) {
            Button { setDone(stage.id, !isDone) } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isDone ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone ? "Done: \(stage.title)" : "Not done: \(stage.title)")
            .accessibilityHint("Toggles the stage")
            VStack(alignment: .leading, spacing: 4) {
                Text("\(n). \(stage.title)").font(.headline).strikethrough(isDone, color: .secondary)
                ForEach(Array(stage.detail.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let action = stage.action { button(action).padding(.top, 2) }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func button(_ action: FirstCutStage.Action) -> some View {
        switch action {
        case .openCoupon:
            Button("Open the Coupon", systemImage: "arrow.forward.circle") { Task { await openCoupon(material: nil) } }
                .disabled(model.isBusy)
        case .exportJob:
            Button("Export Guided Job…", systemImage: "list.bullet.rectangle.portrait") { exportJob() }
                .disabled(!isCouponOpen || model.programs.isEmpty)
                .help(isCouponOpen ? "Save the coupon's guided job and open it in CRWrite" : "Open the coupon first")
        case .material(let m):
            Button("Open the Coupon in \(MaterialLibrary.material(id: m)?.name ?? m)", systemImage: "arrow.triangle.2.circlepath") {
                Task { await openCoupon(material: m) }
            }
            .disabled(model.isBusy || model.isGenerating)
        case .record:
            Button("Record the Result…", systemImage: "book.closed") { recording = model.draftJournalEntry() }
                .disabled(!isCouponOpen || model.programs.isEmpty)
                .help(isCouponOpen ? "What you measured, how it went: the journal and the feeds learn from it" : "Open the coupon first")
        }
    }

    private var isCouponOpen: Bool { ExamplePart.of(model.part?.url)?.id == "first_cut" }

    private func openCoupon(material: String?) async {
        message = await model.openFirstCutCoupon(material: material, inventory: inventory)
    }

    private func exportJob() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "crproj") ?? .data]
        let material = model.stock.flatMap { MaterialLibrary.material(id: $0.materialID)?.name } ?? "Coupon"
        panel.nameFieldStringValue = "First-Cut Coupon (\(material)).crproj"
        panel.message = "Save the guided job. Open it in CRWrite's Guided Mode."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportGuidedJob(to: url, measuring: inventory.inventory.measuring)
            message = "Saved \(url.lastPathComponent)."
            setDone("export", true)
            if let app = AppModel.crwriteURL {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Firmware settings

    /// $110–$112 (max rates, mm/min) and $120–$122 (acceleration, mm/s²) as read with $$, against
    /// the firmware defaults Coastline's time estimates use.
    private var settingsSection: some View {
        let machine = model.machine
        let defaults: [(String, String, Double, String)] = [
            ("$110", "X max rate", machine.maxRate.x, "mm/min"), ("$111", "Y max rate", machine.maxRate.y, "mm/min"),
            ("$112", "Z max rate", machine.maxRate.z, "mm/min"), ("$120", "X acceleration", machine.acceleration.x, "mm/s²"),
            ("$121", "Y acceleration", machine.acceleration.y, "mm/s²"), ("$122", "Z acceleration", machine.acceleration.z, "mm/s²"),
        ]
        let values = settings
        let differing = defaults.filter { d in values[d.0].map { abs($0 - d.2) > 0.5 } ?? false }
        return Section {
            ForEach(defaults, id: \.0) { key, name, value, unit in
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField(value.formatted(), value: Binding(get: { values[key] }, set: { setSetting(key, $0) }), format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .accessibilityLabel("\(key) \(name)")
                        Text(unit).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        if let v = values[key] {
                            Image(systemName: abs(v - value) <= 0.5 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(abs(v - value) <= 0.5 ? .green : .orange)
                                .accessibilityLabel(abs(v - value) <= 0.5 ? "Same as the default" : "Differs from the default")
                        }
                    }
                } label: {
                    Text("\(key) · \(name)")
                }
            }
        } header: {
            Text("Firmware settings ($$ in CRWrite's console)")
        } footer: {
            Text(differing.isEmpty
                 ? "Coastline's time estimates use the firmware defaults shown in grey. Type what $$ prints to compare."
                 : "Differs from the defaults (\(differing.map(\.0).joined(separator: ", "))): the time estimates are off by that much until the CR-1 profile carries your values (the limits themselves stay the firmware's).")
        }
    }

    private var settings: [String: Double] {
        var out: [String: Double] = [:]
        for pair in settingsRaw.split(separator: ",") {
            let kv = pair.split(separator: "=")
            if kv.count == 2, let v = Double(kv[1]) { out[String(kv[0])] = v }
        }
        return out
    }

    private func setSetting(_ key: String, _ value: Double?) {
        var s = settings
        s[key] = value
        settingsRaw = s.keys.sorted().compactMap { k in s[k].map { "\(k)=\($0)" } }.joined(separator: ",")
    }
}

extension AppModel {
    /// Opens the first-cut coupon (saved with its wax toolpaths); in another material, on that
    /// bar with the toolpaths generated again for it. Returns what went wrong, if anything.
    func openFirstCutCoupon(material: String?, inventory: InventoryModel) async -> String? {
        guard let coupon = ExamplePart.all.first(where: { $0.id == "first_cut" }) else { return nil }
        await openExample(coupon, inventory: inventory)
        page = .workspace
        guard let material, material != coupon.material else { return nil }
        let bar = FirstCut.bar(material: material)
        func same(_ s: StockItem) -> Bool {
            s.materialID == material && s.shape == .block
                && abs(s.sizeX - bar.x) < 0.01 && abs(s.sizeY - bar.y) < 0.01 && abs(s.sizeZ - bar.z) < 0.01
        }
        let stock = inventory.inventory.stock
        guard let item = stock.first(where: { same($0) && !$0.isSuggestion }) ?? stock.first(where: same) else {
            return "There's no \(Length.mm(bar.y)) × \(Length.mm(bar.z)) \(MaterialLibrary.material(id: material)?.name ?? material) bar in the inventory: add one (Stock), then try again."
        }
        useStock(item)
        await generateToolpaths(inventory: inventory.inventory)
        return nil
    }
}
