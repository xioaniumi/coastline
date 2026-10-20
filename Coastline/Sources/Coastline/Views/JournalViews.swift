import AppKit
import CoastlineCore
import SwiftUI
import UniformTypeIdentifiers

/// After a job ran on the machine: how it went, what you measured, what's left of the bar.
struct RecordJobSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory
    @Environment(\.dismiss) private var dismiss
    @State var entry: JournalEntry
    @State private var putBack = true

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("How it went") {
                    Picker("Result", selection: $entry.outcome) {
                        ForEach(JournalEntry.Outcome.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Surface finish") {
                        Picker("Surface finish", selection: $entry.finish) {
                            ForEach(1...5, id: \.self) { Text(["Rough", "Fair", "Good", "Fine", "Mirror"][$0 - 1]).tag($0) }
                        }
                        .labelsHidden()
                    }
                    Toggle("Chatter or squeal while cutting", isOn: $entry.chatter)
                    if entry.chatter {
                        ForEach(uniqueTools, id: \.0) { id, name in
                            Toggle(name, isOn: Binding(get: { entry.chatterToolIDs.contains(id) },
                                                       set: { on in entry.chatterToolIDs.removeAll { $0 == id }; if on { entry.chatterToolIDs.append(id) } }))
                                .padding(.leading, 16)
                        }
                        Text("Coastline slows those tools' feeds by 10 % in this material next time (Settings → journal learning).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !entry.measurements.isEmpty {
                    Section("What you measured") {
                        ForEach(entry.measurements.indices, id: \.self) { k in
                            let m = entry.measurements[k]
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(m.what)
                                    Text("\(Length.mm(m.expected)) ± \(Length.mm(m.tolerance)) mm").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                TextField("mm", value: $entry.measurements[k].measured, format: .number.precision(.fractionLength(0...3)))
                                    .multilineTextAlignment(.trailing).frame(width: 80)
                                if let ok = m.inTolerance {
                                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red)
                                        .accessibilityLabel(ok ? "In tolerance" : "Out of tolerance")
                                        .help(ok ? "In tolerance" : "Out of tolerance")
                                }
                            }
                        }
                    }
                }
                Section("Stock") {
                    LabeledContent("Used", value: entry.stockDescription)
                    if let left = entry.remnantLength {
                        Toggle(isOn: $putBack) {
                            Text("Put the rest back as an offcut")
                            Text("About \(Length.mm(left)) mm of the bar is left (after the saw cut).")
                        }
                        if putBack {
                            NumberField(title: "Length left", value: Binding(get: { entry.remnantLength ?? 0 }, set: { entry.remnantLength = $0 }))
                        }
                    }
                }
                Section("Notes and photos") {
                    TextField("Notes", text: $entry.notes, axis: .vertical).lineLimit(3...8)
                    HStack {
                        Button("Add Photos…", systemImage: "photo.on.rectangle") { addPhotos() }
                        Text(entry.photos.isEmpty ? "None" : "\(entry.photos.count) added").foregroundStyle(.secondary)
                    }
                }
                Section {
                    LabeledContent("Cutting time", value: AppModel.duration(entry.cuttingMinutes * 60))
                    Text("Recording adds each tool's cutting time to its wear, takes one piece of the stock out of the inventory\(putBack && entry.remnantLength != nil ? " and puts the offcut back" : "").")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        .darkPanel()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Record") { record() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(width: 480, height: 620)
    }

    private var uniqueTools: [(UUID, String)] {
        var seen = Set<UUID>()
        return entry.programs.compactMap { p in seen.insert(p.toolID).inserted ? (p.toolID, p.toolName) : nil }
    }

    private func addPhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let name = model.journal.importPhoto(url) { entry.photos.append(name) } }
    }

    private func record() {
        var e = entry
        if !putBack { e.remnantLength = nil }
        var notes: [String] = []
        inventory.update { inv in notes = JobJournal.record(e, into: &inv) }
        model.journal.add(e, tools: inventory.inventory.tools)
        model.status = (["Recorded in the journal."] + notes).joined(separator: " ")
        dismiss()
    }
}

/// A recorded job (Projects ▸ Job Journal).
struct JournalDetail: View {
    @Environment(AppModel.self) private var model
    let entry: JournalEntry

    var body: some View {
        Form {
            Section(entry.partName) {
                LabeledContent("Date", value: entry.date.formatted(date: .long, time: .shortened))
                LabeledContent("Result", value: entry.outcome.title)
                LabeledContent("Stock", value: entry.stockDescription)
                if entry.copies > 1 { LabeledContent("Copies", value: "\(entry.copies)") }
                LabeledContent("Finish", value: ["Rough", "Fair", "Good", "Fine", "Mirror"][min(max(entry.finish, 1), 5) - 1])
                if entry.chatter { Label("Chatter reported", systemImage: "waveform.path").foregroundStyle(.orange) }
            }
            Section("Programs") {
                ForEach(Array(entry.programs.enumerated()), id: \.offset) { _, p in
                    LabeledContent(p.title, value: "\(p.toolName) · \(AppModel.duration(p.minutes * 60))")
                }
            }
            if !entry.measurements.isEmpty {
                Section("Measured") {
                    ForEach(Array(entry.measurements.enumerated()), id: \.offset) { _, m in
                        LabeledContent(m.what) {
                            HStack {
                                Text(m.measured.map { Length.mm($0) + " mm" } ?? "—")
                                Text("(\(Length.mm(m.expected)) ± \(Length.mm(m.tolerance)))").foregroundStyle(.secondary)
                                if let ok = m.inTolerance {
                                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red)
                                        .accessibilityLabel(ok ? "In tolerance" : "Out of tolerance")
                                        .help(ok ? "In tolerance" : "Out of tolerance")
                                }
                            }
                        }
                    }
                }
            }
            if !entry.notes.isEmpty { Section("Notes") { Text(entry.notes) } }
            if !entry.photos.isEmpty {
                Section("Photos") {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(entry.photos, id: \.self) { name in
                                if let img = NSImage(contentsOf: model.journal.photosDir.appendingPathComponent(name)) {
                                    Image(nsImage: img).resizable().scaledToFit().frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }
                }
            }
            if let path = entry.projectPath {
                Section {
                    Button("Open the Project", systemImage: "folder") { Task { await model.openProject(URL(fileURLWithPath: path)); model.page = .workspace } }
                        .disabled(!FileManager.default.fileExists(atPath: path))
                }
            }
        }
        .formStyle(.grouped)
        .darkPanel()
    }
}

/// Tools to reorder (wear from the journal, worn or broken ones) and what's been learned.
struct ShoppingListPage: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory

    var body: some View {
        let al = MaterialLibrary.material(id: "al-6061") ?? MaterialLibrary.all[0]
        let list = ToolLife.shoppingList(inventory.inventory, material: al)
        Form {
            let forJob = model.jobToolsToBuy
            if !forJob.isEmpty {
                Section {
                    ForEach(forJob) { t in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(t.name).font(.headline)
                                Spacer()
                                if let c = t.unitCost { Text(String(format: "≈ %.0f", c)).monospacedDigit() }
                            }
                            Text(t.notes.replacingOccurrences(of: "Not in your inventory: Coastline suggests it. ", with: ""))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("⌀\(Length.mm(t.diameter)) mm · \(Length.mm(t.fluteLength)) mm flutes/reach · \(Length.mm(t.shankDiameter)) mm shank · \(t.vendor)")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("I Have It Now") { inventory.markOwned(t.id) }.font(.caption)
                        }
                    }
                } header: {
                    Text("For \(model.part?.fileName ?? "this job")")
                } footer: {
                    let total = forJob.compactMap(\.unitCost).reduce(0, +)
                    Text("The plan uses these; the toolpaths and simulation are made with them. About \(Int(total.rounded())) in all (typical prices).")
                }
            }
            Section {
                if list.isEmpty {
                    Label("Nothing to buy: no tool is near the end of its life.", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                ForEach(list, id: \.tool.id) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.tool.name).font(.headline)
                            Spacer()
                            if let c = item.tool.unitCost { Text(String(format: "%.2f", c)).monospacedDigit() }
                        }
                        Text(item.why).font(.caption).foregroundStyle(.orange)
                        if !item.tool.vendor.isEmpty || !item.tool.partNumber.isEmpty {
                            Text([item.tool.vendor, item.tool.partNumber].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        if let url = URL(string: item.tool.productLink), !item.tool.productLink.isEmpty {
                            Link("Product Page", destination: url).font(.caption)
                        }
                    }
                }
            } header: {
                Text("Tools to reorder")
            } footer: {
                Text("Wear comes from the cutting time of recorded jobs (Taylor tool life, in aluminium). Mark a tool worn or broken in Tools to add it here.")
            }
            Section("Learned from your jobs") {
                let learned = model.journal.learning.factors.filter { abs($0.value - 1) > 0.001 }.sorted { $0.key < $1.key }
                if learned.isEmpty {
                    Text("Nothing yet: report chatter when you record a job and Coastline slows that tool kind down in that material.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(learned, id: \.key) { k, v in
                    let parts = k.split(separator: "|")
                    LabeledContent("\(Tool.Kind(rawValue: String(parts.last ?? ""))?.title ?? String(parts.last ?? "")) in \(MaterialLibrary.material(id: String(parts.first ?? ""))?.name ?? String(parts.first ?? ""))",
                                   value: "feeds ×\(String(format: "%.2f", v))")
                }
            }
        }
        .formStyle(.grouped)
        .darkPanel()
        .navigationTitle("Shopping List")
    }
}
