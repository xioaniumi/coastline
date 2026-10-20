import CoastlineCore
import SwiftUI

/// Jog the modelled CR-1 with sliders across its travel, with or without a bit: check where
/// things reach before cutting.
struct JogPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory

    var body: some View {
        @Bindable var model = model
        let e = model.machine.machineEnvelope
        let q = model.machinePosition
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Jog", systemImage: "dpad").font(.headline)
                Spacer()
                Button { model.jogOpen = false } label: {
                    Label("Close", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Close the jog panel")
            }
            Picker("In the collet", selection: Binding(get: { model.jogTool?.id }, set: { id in
                model.jogTool = OperationPlanner.usableTools(inventory.inventory).first { $0.id == id }
                model.jog(to: model.machinePosition)
            })) {
                Text("No bit (spindle nose)").tag(UUID?.none)
                ForEach(OperationPlanner.usableTools(inventory.inventory)) { t in
                    Text("\(t.name.components(separatedBy: " · ").first ?? t.name) · \(Length.mm(t.stickout)) mm out").tag(Optional(t.id))
                }
            }
            axis("X", "table up/down", q.x, e.x) { model.jog(to: SIMD3($0, q.y, q.z)) }
            axis("Y", "spindle left/right", q.y, e.y) { model.jog(to: SIMD3(q.x, $0, q.z)) }
            axis("Z", "spindle in/out", q.z, e.z) { model.jog(to: SIMD3(q.x, q.y, $0)) }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("Machine").foregroundStyle(.secondary)
                    Text(String(format: "X%8.2f  Y%8.2f  Z%8.2f", q.x, q.y, q.z)).monospacedDigit()
                }
                if let w = model.jogWorkPosition {
                    GridRow {
                        Text(model.jogTool == nil ? "Nose, work" : "Tip, work").foregroundStyle(.secondary)
                        Text(String(format: "X%8.2f  Y%8.2f  Z%8.2f", w.x, w.y, w.z)).monospacedDigit()
                    }
                }
            }
            .font(.caption)
            if model.jogTouchesClamp {
                Label("The tool touches the clamp kit here", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.danger)
            }
            Menu("Go To") {
                ForEach(model.jogPlaces, id: \.0) { name, p in
                    Button(name) { model.jog(to: p) }
                }
            }
            .fixedSize()
            Text("Machine coordinates are what CRWrite's DRO shows (negative from home). The table moves X; the spindle moves Y and Z.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 330)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func axis(_ name: String, _ what: String, _ value: Double, _ range: ClosedRange<Double>,
                      set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(name).font(.callout.weight(.semibold))
                Text(what).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", value)).font(.caption.monospacedDigit())
            }
            Slider(value: Binding(get: { value }, set: set), in: range) { Text("\(name), \(what)") }
                .labelsHidden()
                .accessibilityValue(String(format: "%.2f millimetres", value))
        }
    }
}
