import Charts
import CoastlineCore
import SwiftUI

/// The smart planner's result: every plan it costed (time vs finish), and the three worth
/// choosing between, each with its reasons.
struct PlanOptionsView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: UUID?
    @State private var showChart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.planCandidates.isEmpty {
                DisclosureGroup("All \(model.planCandidates.count) plans compared", isExpanded: $showChart) { chart }
                    .font(.callout)
            }
            ForEach(model.planOptions) { c in
                VStack(alignment: .leading, spacing: 6) {
                    let parts = c.name.components(separatedBy: ", ")
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(parts[0]).font(.headline).lineLimit(1)
                            if parts.count > 1 {
                                Text(parts.dropFirst().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .help(c.name)
                        if model.recommendedPlan == c.name {
                            Text("Recommended").font(.caption2.weight(.semibold)).lineLimit(1).fixedSize().padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.2), in: Capsule()).foregroundStyle(Theme.accent)
                        }
                        if model.chosenPlan == c.name {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                                .help("The plan in use").accessibilityLabel("In use")
                        }
                        Spacer()
                        Button("Use This Plan") { model.usePlan(c) }
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                    }
                    HStack(spacing: 12) {
                        Label("≈ \(AppModel.duration(c.minutes * 60))", systemImage: "clock").fixedSize()
                        Label("\(c.finish < 3 ? "to size" : "~\(Int(c.finish.rounded())) µm cusps")", systemImage: "sparkles")
                        // A different symbol per level, so it doesn't rest on the colour alone.
                        Label(c.risk < 0.2 ? "comfortable" : c.risk < 0.45 ? "some risk" : "risky",
                              systemImage: c.risk < 0.2 ? "gauge.with.dots.needle.0percent" : c.risk < 0.45 ? "gauge.with.dots.needle.50percent" : "exclamationmark.triangle.fill")
                            .foregroundStyle(c.risk < 0.2 ? Theme.ok : c.risk < 0.45 ? Theme.warning : Theme.danger)
                    }
                    .font(.caption)
                    Text(c.operations.map(\.kind.title).joined(separator: " → ")).font(.caption).foregroundStyle(.secondary)
                    ForEach(c.needsTools) { t in
                        Label("Needs the \(t.name): not in your inventory\(t.unitCost.map { String(format: ", about %.0f", $0) } ?? ""). \(t.notes.replacingOccurrences(of: "Not in your inventory: Coastline suggests it. ", with: ""))",
                              systemImage: "cart")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                    if !c.remedies.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Make it less risky:").font(.caption.weight(.semibold))
                            ForEach(c.remedies, id: \.self) { r in
                                Button { model.applyRemedy(r, to: c) } label: {
                                    Label(r.title, systemImage: "wand.and.stars").font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    DisclosureGroup(isExpanded: Binding(get: { expanded == c.id }, set: { expanded = $0 ? c.id : nil })) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(c.reasons, id: \.self) { r in
                                Label(r, systemImage: r.hasPrefix("Risk") ? "exclamationmark.triangle" : "lightbulb")
                                    .font(.caption)
                                    .foregroundStyle(r.hasPrefix("Risk") ? Theme.warning : .secondary)
                            }
                        }
                    } label: {
                        Text("Why").font(.caption)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(model.chosenPlan == c.name ? Theme.accent.opacity(0.12) : Color.secondary.opacity(0.07)))
            }
            if !model.planOptions.isEmpty {
                Text("Times are estimates. Generating checks them against the simulation, and Coastline learns your real times from it.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Every plan costed: time against finish, the ones worth choosing marked.
    private var chart: some View {
        let picks = Set(model.planOptions.map(\.id))
        return Chart {
                    ForEach(model.planCandidates) { c in
                        PointMark(x: .value("Minutes", c.minutes), y: .value("Cusp (µm)", c.finish))
                            .foregroundStyle(picks.contains(c.id) ? Theme.accent : Color.secondary.opacity(0.35))
                            .symbolSize(picks.contains(c.id) ? 90 : 18)
                    }
                    ForEach(Array(model.planOptions.enumerated()), id: \.element.id) { k, c in
                        PointMark(x: .value("Minutes", c.minutes), y: .value("Cusp (µm)", c.finish))
                            .opacity(0)
                            .annotation(position: k % 2 == 0 ? .topLeading : .bottomTrailing, spacing: 2) {
                                Text(c.name.components(separatedBy: ",").first ?? c.name).font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                            }
                    }
                }
                .chartXScale(domain: 0 ... max((model.planCandidates.map(\.minutes).max() ?? 60) * 1.08, 1))
                .chartYScale(domain: 0 ... max((model.planCandidates.map(\.finish).max() ?? 20) * 1.15, 1))
                .chartXAxisLabel("machining time (min)")
                .chartYAxisLabel("finish: cusp height (µm)")
                .frame(height: 150)
                .help("Every plan Coastline costed. Lower is a finer finish, left is quicker. The highlighted ones are the best trade-offs.")
    }

}
