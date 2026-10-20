import Charts
import CoastlineCore
import SwiftUI

/// Quality ↔ time: presets and two sliders, with the consequences before you regenerate.
struct TunerSection: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory

    @State private var details = false

    var body: some View {
        @Bindable var model = model
        Section {
            Picker("Preset", selection: Binding(get: { model.tuning.preset }, set: { if let p = $0 { model.tuning = model.tuning.with(p) } })) {
                ForEach(Tuning.Preset.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                if model.tuning.preset == nil { Text("Custom").tag(Tuning.Preset?.none) }
            }
            .pickerStyle(.segmented)
            .help(model.tuning.preset?.explanation ?? "Your own mix of the settings below.")
            roughingPicker
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Finish")
                    InfoTip(text: "Cusp height left between finishing passes. Halving it adds ~40 % more finishing passes. Ra ≈ cusp / 4.")
                    Spacer()
                    Text("\(Int((model.tuning.cusp * 1000).rounded())) µm · Ra ≈ \(String(format: "%.1f", model.tuning.ra)) µm")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { log(model.tuning.cusp * 1000) }, set: { model.tuning.cusp = (exp($0)).rounded() / 1000 }),
                       in: log(2) ... log(30)) { Text("Finish") }
                    .labelsHidden()
                    .accessibilityValue("\(Int((model.tuning.cusp * 1000).rounded())) micrometre cusps, Ra about \(String(format: "%.1f", model.tuning.ra)) micrometres")
            }
            if model.twoSided {
                HStack {
                    Text("Seen from")
                    InfoTip(text: "Finish matters only where the part shows. A side nobody sees (the inside of a wallet, the back of a pendant) gets 3× coarser 3D finishing: about 40 % less finishing time there. Walls, floors and holes are finished as usual.")
                    Spacer()
                    Picker("Seen from", selection: Binding(get: { model.tuning.hiddenSide ?? -1 },
                                                         set: { model.tuning.hiddenSide = $0 < 0 ? nil : $0 })) {
                        Text("Both sides").tag(-1)
                        Text("A only").tag(1)
                        Text("B only").tag(0)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            DisclosureGroup("Details", isExpanded: $details) { detailsContent }
        } header: {
            Text("Quality ↔ time")
        }
    }

    /// Pace, cost, tool wear, batch, the time curve and the rates: there when wanted.
    @ViewBuilder private var detailsContent: some View {
        @Bindable var model = model
        if let p = model.tuning.preset { Text(p.explanation).font(.caption).foregroundStyle(.secondary) }
        Text(model.tuning.roughingStyle.explanation).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Pace")
                InfoTip(text: "Feeds (and roughing engagement) relative to the recommended values. Faster saves time but wears tools much faster (Taylor: life falls with the 4th power of speed) and can chatter on the CR-1.")
                Spacer()
                Text("\(Int((model.tuning.pace * 100).rounded())) %").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $model.tuning.pace, in: 0.7 ... 1.2, step: 0.05) { Text("Pace") }
                .labelsHidden()
                .accessibilityValue("\(Int((model.tuning.pace * 100).rounded())) percent of the recommended feeds")
        }
        if let e = model.tunerEstimate(model.tuning) {
            let c = model.costModel
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let k = e.cost {
                    GridRow {
                        Text("Cost / part").foregroundStyle(.secondary)
                        Text(money(k.total, c)).help("Machine \(money(k.machine, c)) · tools \(money(k.tools, c)) · stock \(money(k.stock, c)) · setup \(money(k.labour, c))")
                    }
                }
                ForEach(Array(e.toolMinutes.prefix(4).enumerated()), id: \.offset) { _, tm in
                    if let m = model.stock?.material {
                        GridRow {
                            Text(tm.0.name.components(separatedBy: " · ").first ?? tm.0.name).foregroundStyle(.secondary).lineLimit(1)
                                .help(tm.0.name)
                            Text("\(String(format: "%.1f", ToolWear.fraction(tool: tm.0, material: m, minutes: tm.1, pace: model.tuning.pace) * 100)) % of its life")
                        }
                    }
                }
            }
            .font(.callout.monospacedDigit())
            Stepper("Batch of \(model.batchQuantity)", value: $model.batchQuantity, in: 1 ... 100)
            Text("\(model.batchQuantity == 1 ? "1 part" : "\(model.batchQuantity) parts") ≈ \(AppModel.duration(e.minutes * 60 * Double(model.batchQuantity))) of machining + \(Int(c.setupMinutes * Double(model.batchQuantity))) min of setting up · \(money((e.cost?.total ?? 0) * Double(model.batchQuantity), c))")
                .font(.caption).foregroundStyle(.secondary)
            curve
            DisclosureGroup("Rates") {
                NumberField(title: "Machine per hour", value: $model.costModel.machinePerHour, unit: c.currency,
                            tip: "Power, wear and maintenance of the CR-1 per running hour.")
                NumberField(title: "Your time per hour", value: $model.costModel.labourPerHour, unit: c.currency,
                            tip: "0 for a hobby. Used for the setup time.")
                NumberField(title: "Setup per clamping", value: $model.costModel.setupMinutes, unit: "min")
                NumberField(title: "Tool price (if unknown)", value: $model.costModel.defaultToolPrice, unit: c.currency)
            }
        } else {
            Text("Generate once: then time, tool wear and cost follow every setting here, before you regenerate.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Roughing never shows on the part: how hard it runs (each style's time on hover).
    private var roughingPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Roughing")
                InfoTip(text: "Roughing only removes material: it leaves an even allowance for the finishing passes, so how fast it runs never shows on the part. What limits it is the tool and the machine. " + model.tuning.roughingStyle.explanation)
                Spacer()
            }
            Picker("Roughing", selection: Binding(get: { model.tuning.roughingStyle },
                                                  set: { model.tuning.roughing = $0 == .thinned ? nil : $0 })) {
                ForEach(FeedsEngine.RoughingStyle.allCases, id: \.self) { st in
                    Text(st == .table ? "Gentle" : st == .thinned ? "Chip-thinned" : "Deep").tag(st)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .help(FeedsEngine.RoughingStyle.allCases.map { st -> String in
                var t = model.tuning
                t.roughing = st == .thinned ? nil : st
                return "\(st.title): " + (model.tunerEstimate(t).map { "≈ " + AppModel.duration($0.minutes * 60) } ?? "generate to see the time")
            }.joined(separator: "\n"))
        }
    }

    /// Time across finishes at the current pace, presets marked.
    private var curve: some View {
        let cusps: [Double] = [2, 3, 4, 6, 8, 11, 15, 20, 25, 30]
        let points = cusps.compactMap { c -> (Double, Double)? in
            model.tunerEstimate({ var t = model.tuning; t.cusp = c / 1000; return t }()).map { (c, $0.minutes) }
        }
        return Chart {
            ForEach(points, id: \.0) { p in
                LineMark(x: .value("Cusp (µm)", p.0), y: .value("Minutes", p.1)).interpolationMethod(.monotone)
            }
            if let now = model.tunerEstimate(model.tuning) {
                PointMark(x: .value("Cusp (µm)", model.tuning.cusp * 1000), y: .value("Minutes", now.minutes))
                    .foregroundStyle(Theme.accent).symbolSize(90)
            }
        }
        .chartXScale(type: .log)
        .chartXAxisLabel("finish: cusp height (µm)")
        .chartYAxisLabel("minutes")
        .frame(height: 120)
        .help("How the machining time moves with the finish at this pace. The dot is your setting.")
    }

    private func delta(_ a: Double, _ b: Double) -> String {
        let d = a - b
        guard abs(d) >= 0.5 else { return "" }
        return "  (\(d > 0 ? "+" : "−")\(AppModel.duration(abs(d) * 60)))"
    }

    private func money(_ v: Double, _ c: CostModel) -> String { "\(c.currency)\(String(format: "%.2f", v))" }
}
