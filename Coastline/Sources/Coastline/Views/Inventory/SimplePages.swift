import Metal
import CoastlineCore
import SwiftUI

// Fixtures, measuring tools and accessories: simpler lists with the same table + inspector layout.

struct FixturesPage: View {
    @Environment(InventoryModel.self) private var model
    @Environment(AppModel.self) private var app
    @State private var selection: Set<Fixture.ID> = []
    @State private var pendingDelete: Set<Fixture.ID>?

    var body: some View {
        Table(model.inventory.fixtures, selection: $selection) {
            TableColumn("Fixture") { f in
                Label(f.name, systemImage: f.kind.symbol)
            }
            .width(min: 200, ideal: 260)
            TableColumn("Type") { Text($0.kind.title).foregroundStyle(.secondary) }.width(min: 100, ideal: 130)
            TableColumn("Clamps") { Text($0.clampAxis.title) }.width(55)
            TableColumn("Probing") { f in
                if f.isolated { Label("Isolated", systemImage: "bolt.slash").foregroundStyle(Theme.ok) } else { Text("—").foregroundStyle(.secondary) }
            }
            .width(80)
            TableColumn("3D Model") { f in
                Image(systemName: f.modelPath == nil ? "minus" : "cube.fill").foregroundStyle(.secondary)
                    .accessibilityLabel(f.modelPath == nil ? "No 3D model" : "Has a 3D model")
            }
            .width(70)
            TableColumn("Qty") { Text("\($0.quantity)").monospacedDigit() }.width(40)
        }
        .contextMenu(forSelectionType: Fixture.ID.self) { ids in
            Button("Delete…", role: .destructive) { pendingDelete = ids }
        }
        .onDeleteCommand { if !selection.isEmpty { pendingDelete = selection } }
        .confirmingDelete($pendingDelete, name: { ids in
            DeleteName.of(model.inventory.fixtures.filter { ids.contains($0.id) }.map(\.name), noun: "fixture")
        }) { ids in
            model.remove(ids, from: \.fixtures)
            selection.subtract(ids)
        }
        .overlay { if model.inventory.fixtures.isEmpty { ContentUnavailableView("No Fixtures", systemImage: "square.grid.3x3.square") } }
        .navigationTitle("Fixtures")
        .toolbar {
            ToolbarItemGroup {
                Menu("Add Fixture", systemImage: "plus") {
                    ForEach(Fixture.Kind.allCases, id: \.self) { kind in
                        Button(kind.title, systemImage: kind.symbol) {
                            let f = Fixture(name: kind.title, kind: kind, clampAxis: kind == .vise ? .y : kind == .universalClamp ? .x : .none)
                            model.add(f, to: \.fixtures)
                            selection = [f.id]
                        }
                    }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = selection }
                    .disabled(selection.isEmpty)
                    .help("Delete the selected fixtures (⌫)")
            }
        }
        .inspector(isPresented: Bindable(app).showInspector) {
            Group {
                if selection.count == 1, let id = selection.first, let f = model.binding(\.fixtures, id: id) {
                    FixtureInspector(fixture: f)
                } else {
                    NothingSelected(what: "Fixture")
                }
            }
            .panelEdge(.leading).inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .onAppear { if selection.isEmpty, let first = model.inventory.fixtures.first { selection = [first.id] } }
    }
}

struct FixtureInspector: View {
    @Binding var fixture: Fixture
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            if let device = MTLCreateSystemDefaultDevice(), !app.fixtureMeshes(fixture.kind, device: device).isEmpty {
                Section {
                    ItemViewer3D(build: { [kind = fixture.kind] d in app.fixtureMeshes(kind, device: d) }, key: fixture.kind.rawValue)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("From your clamp kit model. Drag to orbit, pinch to zoom.")
                }
            }
            Section("Fixture") {
                TextField("Name", text: $fixture.name)
                Picker("Type", selection: $fixture.kind) {
                    ForEach(Fixture.Kind.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                QuantityField(quantity: $fixture.quantity)
            }
            Section {
                Picker("Clamps along", selection: $fixture.clampAxis) {
                    ForEach(Fixture.ClampAxis.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                RangeField(title: "Grips stock", range: $fixture.gripRange)
                NumberField(title: "Raises stock by", value: $fixture.height)
                Toggle("Electrically isolated", isOn: $fixture.isolated)
            } header: {
                Text("Workholding")
            } footer: {
                Text("Isolated fixtures let the CR-1's probe wire touch off on the part (conductive probing). The universal clamp clamps along X, a vise along Y.")
            }
            Section("Model") {
                TextField("3D model file", text: Binding(get: { fixture.modelPath ?? "" }, set: { fixture.modelPath = $0.isEmpty ? nil : $0 }),
                          prompt: Text("STEP, 3MF or STL"))
                TextField("Notes", text: $fixture.notes, axis: .vertical).lineLimit(2 ... 6)
            }
        }
        .formStyle(.grouped)
        .darkPanel()
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

struct MeasuringPage: View {
    @Environment(InventoryModel.self) private var model
    @Environment(AppModel.self) private var app
    @State private var selection: Set<MeasuringTool.ID> = []
    @State private var pendingDelete: Set<MeasuringTool.ID>?

    var body: some View {
        Table(model.inventory.measuring, selection: $selection) {
            TableColumn("Instrument") { Label($0.name, systemImage: $0.kind.symbol) }.width(min: 200, ideal: 260)
            TableColumn("Type") { Text($0.kind.title).foregroundStyle(.secondary) }.width(min: 100, ideal: 140)
            TableColumn("Range") { m in
                Text(m.range.map { "\(Length.mm($0.lowerBound))–\(Length.mm($0.upperBound)) mm" } ?? "—").monospacedDigit()
            }
            .width(min: 80, ideal: 100)
            TableColumn("Resolution") { m in Text(m.resolution.map { "\(Length.mm($0)) mm" } ?? "—").monospacedDigit() }.width(80)
            TableColumn("Qty") { Text("\($0.quantity)").monospacedDigit() }.width(40)
        }
        .contextMenu(forSelectionType: MeasuringTool.ID.self) { ids in
            Button("Delete…", role: .destructive) { pendingDelete = ids }
        }
        .onDeleteCommand { if !selection.isEmpty { pendingDelete = selection } }
        .confirmingDelete($pendingDelete, name: { ids in
            DeleteName.of(model.inventory.measuring.filter { ids.contains($0.id) }.map(\.name), noun: "instrument")
        }) { ids in
            model.remove(ids, from: \.measuring)
            selection.subtract(ids)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            GlassCard {
                Label("Guided measuring steps only ask for instruments listed here. A digital caliper (0.01 mm) covers most checks; a micrometer (0.001 mm) is worth having for jewellery fits.",
                      systemImage: "ruler")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .navigationTitle("Measuring Tools")
        .toolbar {
            ToolbarItemGroup {
                Menu("Add Instrument", systemImage: "plus") {
                    ForEach(MeasuringTool.Kind.allCases, id: \.self) { kind in
                        Button(kind.title, systemImage: kind.symbol) {
                            let m = MeasuringTool(name: kind.title, kind: kind)
                            model.add(m, to: \.measuring)
                            selection = [m.id]
                        }
                    }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = selection }
                    .disabled(selection.isEmpty)
                    .help("Delete the selected instruments (⌫)")
            }
        }
        .inspector(isPresented: Bindable(app).showInspector) {
            Group {
                if selection.count == 1, let id = selection.first, let m = model.binding(\.measuring, id: id) {
                    Form {
                        Section("Instrument") {
                            TextField("Name", text: m.name)
                            Picker("Type", selection: m.kind) {
                                ForEach(MeasuringTool.Kind.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                            }
                            QuantityField(quantity: m.quantity)
                        }
                        Section("Specification") {
                            RangeField(title: "Range", range: m.range)
                            OptionalNumberField(title: "Resolution", value: m.resolution, unit: "mm")
                            OptionalNumberField(title: "Accuracy ±", value: m.accuracy, unit: "mm")
                        }
                        Section("Notes") { TextField("Notes", text: m.notes, axis: .vertical).lineLimit(2 ... 6) }
                    }
                    .formStyle(.grouped)
        .darkPanel()
                    .scrollEdgeEffectStyle(.soft, for: .all)
                } else {
                    NothingSelected(what: "Instrument")
                }
            }
            .panelEdge(.leading).inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
    }
}

struct AccessoriesPage: View {
    @Environment(InventoryModel.self) private var model
    @Environment(AppModel.self) private var app
    @State private var selection: Set<Accessory.ID> = []
    @State private var pendingDelete: Set<Accessory.ID>?

    var body: some View {
        Table(model.inventory.accessories, selection: $selection) {
            TableColumn("Item") { Label($0.name, systemImage: $0.kind.symbol) }.width(min: 200, ideal: 260)
            TableColumn("Type") { Text($0.kind.title).foregroundStyle(.secondary) }.width(min: 90, ideal: 120)
            TableColumn("Size") { a in Text(a.size.map { Length.describe($0) } ?? "—").monospacedDigit() }.width(min: 90, ideal: 130)
            TableColumn("Qty") { Text("\($0.quantity)").monospacedDigit() }.width(40)
        }
        .contextMenu(forSelectionType: Accessory.ID.self) { ids in
            Button("Delete…", role: .destructive) { pendingDelete = ids }
        }
        .onDeleteCommand { if !selection.isEmpty { pendingDelete = selection } }
        .confirmingDelete($pendingDelete, name: { ids in
            DeleteName.of(model.inventory.accessories.filter { ids.contains($0.id) }.map(\.name), noun: "item")
        }) { ids in
            model.remove(ids, from: \.accessories)
            selection.subtract(ids)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            GlassCard {
                Label("Collets matter: a tool can only be used if you own an ER-11 collet for its shank size. Coastline checks this for every tool.",
                      systemImage: "circle.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .navigationTitle("Accessories")
        .toolbar {
            ToolbarItemGroup {
                Menu("Add Accessory", systemImage: "plus") {
                    ForEach(Accessory.Kind.allCases, id: \.self) { kind in
                        Button(kind.title, systemImage: kind.symbol) {
                            let a = Accessory(name: kind == .collet ? "ER-11 collet" : kind.title, kind: kind, size: kind == .collet ? 3.175 : nil)
                            model.add(a, to: \.accessories)
                            selection = [a.id]
                        }
                    }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = selection }
                    .disabled(selection.isEmpty)
                    .help("Delete the selected items (⌫)")
            }
        }
        .inspector(isPresented: Bindable(app).showInspector) {
            Group {
                if selection.count == 1, let id = selection.first, let a = model.binding(\.accessories, id: id) {
                    Form {
                        Section("Item") {
                            TextField("Name", text: a.name)
                            Picker("Type", selection: a.kind) {
                                ForEach(Accessory.Kind.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                            }
                            OptionalNumberField(title: a.wrappedValue.kind == .collet ? "Bore" : "Size", value: a.size, unit: "mm")
                            QuantityField(quantity: a.quantity)
                        }
                        Section("Notes") { TextField("Notes", text: a.notes, axis: .vertical).lineLimit(2 ... 6) }
                    }
                    .formStyle(.grouped)
        .darkPanel()
                    .scrollEdgeEffectStyle(.soft, for: .all)
                } else {
                    NothingSelected(what: "Item")
                }
            }
            .panelEdge(.leading).inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
    }
}
