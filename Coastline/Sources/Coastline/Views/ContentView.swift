import CoastlineCore
import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case workspace, projects, stock, tools, fixtures, measuring, accessories, shopping, materials, machine
    var id: Self { self }

    var title: String {
        switch self {
        case .workspace: "Workspace"
        case .projects: "Projects"
        case .shopping: "Shopping List"
        case .stock: "Stock"
        case .tools: "Tools"
        case .fixtures: "Fixtures"
        case .measuring: "Measuring Tools"
        case .accessories: "Accessories"
        case .materials: "Materials"
        case .machine: "Coast Runner CR-1"
        }
    }

    var symbol: String {
        switch self {
        case .workspace: "cube.transparent"
        case .projects: "folder"
        case .shopping: "cart"
        case .stock: "shippingbox"
        case .tools: "wrench.and.screwdriver"
        case .fixtures: "square.grid.3x3.square"
        case .measuring: "ruler"
        case .accessories: "circle.circle"
        case .materials: "square.stack.3d.up"
        case .machine: "gearshape.2"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(InventoryModel.self) private var inventory

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: Binding<SidebarItem?>(get: { app.page }, set: { if let p = $0 { app.page = p } })) {
                Section("Project") {
                    row(.workspace)
                    row(.projects)
                }
                Section("Inventory") {
                    row(.stock, count: inventory.inventory.stock.reduce(0) { $0 + $1.quantity })
                    row(.tools, count: inventory.inventory.tools.reduce(0) { $0 + $1.quantity })
                    row(.fixtures, count: inventory.inventory.fixtures.count)
                    row(.measuring, count: inventory.inventory.measuring.count)
                    row(.accessories, count: inventory.inventory.accessories.count)
                    row(.shopping, count: ToolLife.shoppingList(inventory.inventory, material: MaterialLibrary.material(id: "al-6061") ?? MaterialLibrary.all[0]).count)
                }
                Section("Library") { row(.materials, count: MaterialLibrary.all.count) }
                Section("Machine") { row(.machine, count: app.journal.maintenanceStatus.filter(\.due).count) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.windowBackground.opacity(0.75))
            .panelEdge(.trailing)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            Group {
                switch app.page {
                case .workspace: WorkspaceView()
                case .projects: ProjectsPage()
                case .shopping: ShoppingListPage()
                case .stock: StockPage()
                case .tools: ToolsPage()
                case .fixtures: FixturesPage()
                case .measuring: MeasuringPage()
                case .accessories: AccessoriesPage()
                case .materials: MaterialsPage()
                case .machine: MachineView(machine: app.machine)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Inspector", systemImage: "sidebar.right") { app.showInspector.toggle() }
                        .help("Show or hide the inspector (⌥⌘I)")
                        .keyboardShortcut("i", modifiers: [.command, .option])
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = inventory.lastError {
                ErrorBanner(text: error, shape: .capsule) { inventory.lastError = nil }
                    .padding(20)
            }
        }
    }

    private func row(_ item: SidebarItem, count: Int? = nil) -> some View {
        Label(item.title, systemImage: item.symbol)
            .badge(count ?? 0)
            .tag(item)
    }
}

/// What's due on the machine (Operator Manual 7.1), from the job journal.
struct MaintenanceSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            ForEach(app.journal.maintenanceStatus, id: \.task.id) { d in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: d.due ? "exclamationmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(d.due ? .orange : .green)
                        .accessibilityLabel(d.due ? "Due" : "Not due")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.task.title).font(.callout.weight(.semibold))
                        Text(d.task.detail).font(.caption).foregroundStyle(.secondary)
                        Text(d.why).font(.caption).foregroundStyle(d.due ? .orange : .secondary)
                    }
                    Spacer()
                    Button("Mark as Done") { app.journal.markDone(d.task.id) }.controlSize(.small)
                }
            }
        } header: {
            Text("Maintenance")
        } footer: {
            Text("From the Operator Manual (7.1 Basic Maintenance); counted from the jobs you record in the journal.")
        }
    }
}

struct MachineView: View {
    let machine: MachineProfile

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "gearshape.2.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(machine.name).font(.title2.weight(.semibold))
                        Text("3-axis desktop mill · grbl 1.1g (Coast Runner fork)").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Travel") {
                LabeledContent("X (table up/down)", value: "\(Length.mm(machine.travel.x)) mm")
                LabeledContent("Y (gantry left/right)", value: "\(Length.mm(machine.travel.y)) mm")
                LabeledContent("Z (spindle)", value: "\(Length.mm(machine.travel.z)) mm")
                LabeledContent("Max feed X / Y / Z", value: "\(Int(machine.maxRate.x)) / \(Int(machine.maxRate.y)) / \(Int(machine.maxRate.z)) mm/min")
                LabeledContent("Acceleration", value: "\(Int(machine.acceleration.x)) mm/s²")
            }
            Section("Spindle & tooling") {
                LabeledContent("Usable speed", value: "\(Int(machine.spindleRPM.lowerBound))–\(Int(machine.spindleRPM.upperBound)) RPM")
                LabeledContent("Collet", value: "\(machine.colletName), shanks up to \(Length.mm(machine.maxShankDiameter)) mm")
                LabeledContent("Longest tool", value: "\(Length.mm(machine.maxToolLength)) mm (3\")")
            }
            Section("Controller") {
                LabeledContent("Max line length", value: "\(machine.maxLineLength) characters")
                LabeledContent("Planner", value: "\(machine.plannerBlocks) blocks")
                LabeledContent("Tool changes", value: "Manual: guided steps, no tool table")
            }
            Section("Probing & workholding") {
                LabeledContent("Edge finder", value: "Fisher A250, \(Length.mm(machine.edgeFinderTipDiameter)) mm tip")
                LabeledContent("Conductive probing", value: "\(Int(machine.probeFeed)) mm/min, M4 S\(Int(machine.probeSpindleRPM))")
                LabeledContent("Table", value: "\(machine.tSlotCount) T-slots")
                LabeledContent("T-slot nut", value: machine.tSlotNut)
            }
            MaintenanceSection()
            Section {
                Label("Never use compressed air on the CR-1: vacuum and wipe only. Vacuum at every tool or orientation change.",
                      systemImage: "wind.snow")
                Label("Run $L (auto-level) after the enclosure or spindle has been removed.", systemImage: "level")
            } header: {
                Text("Care")
            } footer: {
                Text("Values come from the CR-1 firmware defaults, the Operator Manual v0.9 and Coast Runner's Fusion post.")
            }
        }
        .formStyle(.grouped)
        .darkPanel()
        .scrollEdgeEffectStyle(.soft, for: .all)
        .navigationTitle(machine.name)
    }
}
