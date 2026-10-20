import CoastlineCore
import SwiftUI

struct StockPage: View {
    @Environment(InventoryModel.self) private var model
    @Environment(AppModel.self) private var app
    @State private var selection: Set<StockItem.ID> = []
    @State private var search = ""
    @State private var family: Material.Family? = nil
    @State private var ownership = Ownership.owned
    @State private var pendingDelete: Set<StockItem.ID>?

    private var rows: [StockItem] {
        model.inventory.stock
            .filter { ownership.admits(suggestion: $0.isSuggestion) }
            .filter { family == nil || $0.material?.family == family }
            .filter { search.isEmpty || "\($0.material?.name ?? "") \($0.location) \($0.notes) \($0.supplier)".localizedCaseInsensitiveContains(search) }
    }

    private var familiesInUse: [Material.Family] {
        Material.Family.allCases.filter { f in model.inventory.stock.contains { $0.material?.family == f } }
    }

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("") { IssueDot(severity: model.worstIssue(for: $0)) }.width(22)
            TableColumn("Material") { item in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(item.material?.swatch ?? .gray).frame(width: 14, height: 14)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.primary.opacity(0.2)))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(item.material?.name ?? "Unknown material")
                            if item.isSuggestion {
                                Text("Not owned").font(.caption.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.warning.opacity(0.25)))
                            }
                        }
                        if item.isRemnant { Text("Offcut").font(.caption).foregroundStyle(.secondary) }
                        if item.isSuggestion {
                            Text(item.notes.replacingOccurrences(of: "Not in your inventory: a standard size. ", with: ""))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .width(min: 200, ideal: 260)
            TableColumn("Shape") { Label($0.shape.title, systemImage: $0.shape.symbol) }.width(min: 90, ideal: 110)
            TableColumn("Size") { Text($0.sizeDescription).monospacedDigit() }.width(min: 120, ideal: 150)
            TableColumn("Weight") { item in
                Text(item.weight.map { "\($0.formatted(.number.precision(.fractionLength(0)))) g" } ?? "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(60)
            TableColumn("Finish") { Text($0.finish.title).foregroundStyle(.secondary) }.width(min: 80, ideal: 110)
            TableColumn("Location") { Text($0.location).foregroundStyle(.secondary) }.width(min: 60, ideal: 90)
            TableColumn("Qty") { Text("\($0.quantity)").monospacedDigit() }.width(40)
        }
        .contextMenu(forSelectionType: StockItem.ID.self) { ids in
            if ids.contains(where: { id in model.inventory.stock.first { $0.id == id }?.isSuggestion == true }) {
                Button("I Have It Now") { model.markStockOwned(ids) }
                Divider()
            }
            Button("Duplicate") { ids.forEach { id in model.duplicate(id, in: \.stock) { $0.id = UUID() } } }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = ids }
        }
        .onDeleteCommand { if !selection.isEmpty { pendingDelete = selection } }
        .confirmingDelete($pendingDelete, name: { ids in
            DeleteName.of(model.inventory.stock.filter { ids.contains($0.id) }.map { "\($0.material?.name ?? "Stock") \($0.sizeDescription)" }, noun: "stock item")
        }) { ids in
            model.remove(ids, from: \.stock)
            selection.subtract(ids)
        }
        .overlay {
            if ownership == .owned, !model.inventory.stock.contains(where: { !$0.isSuggestion }) {
                ContentUnavailableView("No Stock", systemImage: "shippingbox",
                                       description: Text("Add the blocks, bars and printed blanks you have."))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                if !familiesInUse.isEmpty {
                    FilterChips(options: [(Material.Family?.none, "All")] + familiesInUse.map { (Optional($0), $0.title) },
                                selection: $family)
                }
                Spacer()
                OwnershipPicker(selection: $ownership)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .searchable(text: $search, prompt: "Search stock")
        .navigationTitle("Stock")
        .toolbar {
            ToolbarItemGroup {
                Menu("Add Stock", systemImage: "plus") {
                    ForEach(StockItem.Shape.allCases, id: \.self) { shape in
                        Button(shape.title, systemImage: shape.symbol) { add(shape) }
                    }
                } primaryAction: { add(.block) }
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = selection }
                    .disabled(selection.isEmpty)
                    .help("Delete the selected stock (⌫)")
            }
        }
        .inspector(isPresented: Bindable(app).showInspector) {
            Group {
                if selection.count == 1, let id = selection.first, let binding = model.binding(\.stock, id: id) {
                    StockInspector(stock: binding)
                } else {
                    NothingSelected(what: "Stock")
                }
            }
            .panelEdge(.leading).inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .onAppear { if selection.isEmpty, let first = rows.first { selection = [first.id] } }
    }

    private func add(_ shape: StockItem.Shape) {
        let item: StockItem
        switch shape {
        case .roundBar: item = StockItem(materialID: "brass-c360", shape: .roundBar, sizeX: 20, sizeY: 100, sizeZ: 0)
        case .plate: item = StockItem(materialID: "al-6061", shape: .plate, sizeX: 100, sizeY: 50, sizeZ: 3)
        case .printedBlank: item = StockItem(materialID: "fl-rigid-10k", shape: .printedBlank, sizeX: 40, sizeY: 30, sizeZ: 15, finish: .asPrinted)
        case .block: item = StockItem(materialID: "al-6061", sizeX: 50, sizeY: 50, sizeZ: 20)
        }
        model.add(item, to: \.stock)
        family = nil
        ownership = .owned
        selection = [item.id]
    }
}

struct StockInspector: View {
    @Binding var stock: StockItem
    @Environment(InventoryModel.self) private var model

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                        PreviewCard(key: "\(stock.id)-\(stock.envelope)-\(stock.materialID)", build: { [stock] d in stock.sceneMeshes(device: d) }) {
                            StockPreview(stock: stock)
                        }
                        if let m = stock.material {
                            HStack {
                                Text(m.name).font(.headline)
                                Spacer()
                                Badge(text: m.difficulty.title, color: Theme.color(m.difficulty))
                            }
                        }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section("Material & shape") {
                MaterialPicker(materialID: $stock.materialID)
                Picker("Shape", selection: $stock.shape) {
                    ForEach(StockItem.Shape.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Picker("Faces", selection: $stock.finish) {
                    ForEach(StockItem.Finish.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if stock.shape != .printedBlank {
                    Picker("Extruded along", selection: $stock.extrusionAxis) {
                        Text("Not known (longest side)").tag(Int?.none)
                        Text("X · \(Length.mm(stock.sizeX)) mm").tag(Int?.some(0))
                        Text("Y · \(Length.mm(stock.sizeY)) mm").tag(Int?.some(1))
                        if stock.shape != .roundBar { Text("Z · \(Length.mm(stock.sizeZ)) mm").tag(Int?.some(2)) }
                    }
                    .help("Extruded and drawn bar is straight and square along its length; only the sawn ends across it need facing. Coastline squares those ends first and registers them against the squaring stop.")
                }
            }
            Section("Size") {
                if stock.shape == .roundBar {
                    NumberField(title: "Diameter", value: $stock.sizeX)
                    NumberField(title: "Length", value: $stock.sizeY)
                } else {
                    NumberField(title: "X (length)", value: $stock.sizeX)
                    NumberField(title: "Y (width)", value: $stock.sizeY)
                    NumberField(title: "Z (height)", value: $stock.sizeZ)
                }
                if let w = stock.weight {
                    LabeledContent("Weight", value: "\(w.formatted(.number.precision(.fractionLength(1)))) g each")
                }
            }
            Section("Ownership") {
                QuantityField(quantity: $stock.quantity)
                OptionalNumberField(title: "Price each", value: $stock.unitCost)
                TextField("Supplier", text: $stock.supplier)
                TextField("Location", text: $stock.location, prompt: Text("e.g. Drawer 2"))
                Toggle("Offcut from an earlier job", isOn: $stock.isRemnant)
                TextField("Notes", text: $stock.notes, axis: .vertical).lineLimit(2 ... 5)
            }
            IssuesSection(issues: model.issues(for: stock))
        }
        .formStyle(.grouped)
        .darkPanel()
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}
