import CoastlineCore
import SwiftUI

struct MaterialsPage: View {
    @Environment(AppModel.self) private var app
    @State private var selection: Material.ID? = "al-6061"
    @State private var search = ""
    @State private var family: Material.Family? = nil

    private var rows: [Material] {
        MaterialLibrary.all
            .filter { family == nil || $0.family == family }
            .filter { search.isEmpty || "\($0.name) \($0.grade) \($0.notes)".localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Material") { m in
                HStack(spacing: 8) {
                    Circle().fill(m.swatch).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.primary.opacity(0.2)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.name)
                        Text(m.grade).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 220, ideal: 280)
            TableColumn("Family") { Label($0.family.title, systemImage: $0.family.symbol).foregroundStyle(.secondary) }
                .width(min: 120, ideal: 170)
            TableColumn("On the CR-1") { Badge(text: $0.difficulty.title, color: Theme.color($0.difficulty)) }
                .width(min: 100, ideal: 120)
            TableColumn("Surface speed") { m in
                Text("\(Int(m.surfaceSpeed.lowerBound))–\(Int(m.surfaceSpeed.upperBound)) m/min").monospacedDigit()
            }
            .width(min: 100, ideal: 120)
            TableColumn("Chip load") { m in
                Text("\(m.chipLoadFactor.formatted(.number.precision(.fractionLength(2))))×").monospacedDigit()
            }
            .width(70)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                FilterChips(options: [(Material.Family?.none, "All")] + Material.Family.allCases.map { (Optional($0), $0.title) },
                            selection: $family)
                    .padding(.horizontal, 16)
            }
            .padding(.vertical, 10)
        }
        .searchable(text: $search, prompt: "Search materials")
        .navigationTitle("Materials")
        .inspector(isPresented: Bindable(app).showInspector) {
            Group {
                if let id = selection, let m = MaterialLibrary.material(id: id) {
                    MaterialDetail(material: m)
                } else {
                    NothingSelected(what: "Material")
                }
            }
            .panelEdge(.leading).inspectorColumnWidth(min: 320, ideal: 360, max: 480)
        }
    }
}

struct MaterialDetail: View {
    let material: Material
    private let machine = MachineProfile.cr1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GlassCard(tint: material.swatch) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Label(material.family.title, systemImage: material.family.symbol)
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Badge(text: material.difficulty.title, color: Theme.color(material.difficulty))
                        }
                        Text(material.name).font(.title2.weight(.semibold))
                        Text(material.grade).foregroundStyle(.secondary)
                        Text(material.difficulty.explanation).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !material.notes.isEmpty {
                    Text(material.notes).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Spindle speed on the CR-1").font(.headline)
                        ForEach([1.5875, 3.175, 6.35], id: \.self) { d in
                            let ideal = material.idealRPM(toolDiameter: d)
                            let actual = min(max(ideal, machine.spindleRPM.lowerBound), machine.spindleRPM.upperBound)
                            HStack {
                                Text(Length.inchFraction(d) ?? Length.mm(d)).frame(width: 44, alignment: .leading).monospacedDigit()
                                Gauge(value: actual, in: 0 ... machine.spindleRPM.upperBound) {}
                                    .gaugeStyle(.accessoryLinearCapacity)
                                    .tint(ideal > machine.spindleRPM.upperBound ? Theme.warning : Theme.accent)
                                Text("\(Int(actual)) RPM").font(.callout.monospacedDigit()).frame(width: 82, alignment: .trailing)
                            }
                        }
                        Text(capNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

                GlassCard {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        row("Surface speed", "\(Int(material.surfaceSpeed.lowerBound))–\(Int(material.surfaceSpeed.upperBound)) m/min")
                        row("Chip load", "\(material.chipLoadFactor.formatted(.number.precision(.fractionLength(2)))) × aluminium")
                        row("Adaptive stepover", "up to \(Int(material.adaptiveStepoverMax * 100))% of ⌀")
                        row("Adaptive depth", "up to \(Length.mm(material.adaptiveDepthMax)) × ⌀")
                        row("Slot depth", "up to \(Length.mm(material.slotDepthMax)) × ⌀")
                        row("Cutting force kc", "\(Int(material.specificCuttingForce)) N/mm²")
                        row("Tool wear", "\(material.toolWearFactor.formatted(.number.precision(.fractionLength(1)))) × aluminium")
                        row("Density", "\(material.density.formatted(.number.precision(.fractionLength(2)))) g/cm³")
                        row("Hardness", material.hardness)
                    }
                    .font(.callout)
                }

                guidance("Lubricant", "drop.fill", material.lubricant)
                guidance("Chips", "aqi.medium", material.chips)
                guidance("Tooling", "wrench.and.screwdriver.fill", material.tooling)

                Text("Starting values for carbide tools. Coastline adjusts them for each tool and operation, and later from your job journal.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            .padding(16)
        }
    }

    private var capNote: String {
        material.idealRPM(toolDiameter: 3.175) > machine.spindleRPM.upperBound
            ? "Small tools want more speed than the CR-1's 8000 RPM, so Coastline keeps the chip load right by lowering the feed instead."
            : "Within the CR-1's 1500–8000 RPM range."
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private func guidance(_ title: String, _ symbol: String, _ text: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol).font(.headline).foregroundStyle(Theme.accent)
                Text(.init(text)).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
