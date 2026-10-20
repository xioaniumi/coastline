import CoastlineCore
import SwiftUI

/// Where the job stands: the steps from part to guided job, each done, needing attention or
/// next, with what to do and what it affects. Clicking a step opens the right tab.
struct FlowSteps: View {
    @Environment(AppModel.self) private var model

    struct Step: Identifiable {
        enum State { case done, attention, next, later }
        var id: String { title }
        var title: String
        var symbol: String
        var state: State
        var detail: String
        var tab: AppModel.InspectorTab
    }

    private var steps: [Step] {
        let hasPart = model.part != nil, hasStock = model.stock != nil
        let issues = model.setupIssues
        let setupError = issues.contains { $0.severity == .error }
        let hasOps = !model.operations.isEmpty
        let generated = !model.programs.isEmpty
        let passed = generated && model.programs.allSatisfy(\.report.passed) && model.travelIssue == nil
        func state(_ done: Bool, _ ready: Bool, attention: Bool = false) -> Step.State {
            attention ? .attention : done ? .done : ready ? .next : .later
        }
        return [
            Step(title: "Part", symbol: "cube", state: state(hasPart, true),
                 detail: hasPart ? "\(model.part!.fileName). Changing its orientation changes every toolpath." : "Import a STEP, IGES or Rhino file.",
                 tab: .setup),
            Step(title: "Stock", symbol: "shippingbox", state: state(hasStock, hasPart),
                 detail: hasStock ? "Its size sets the clamping, the facing and how much there is to rough." : "Choose stock from your inventory.",
                 tab: .setup),
            Step(title: "Clamp", symbol: "square.and.arrow.down.on.square", state: state(hasStock && !setupError, hasStock, attention: hasStock && setupError),
                 detail: setupError ? "Something doesn't fit: see the suggestions in Setup." : "Clamp kit across both T-slots. Changing the stock or sides re-plans it.",
                 tab: .setup),
            Step(title: "Ops", symbol: "list.bullet", state: state(hasOps, hasStock && !setupError),
                 detail: hasOps ? "\(model.operations.filter(\.enabled).count) operations. Tools and cusp height trade finish for time." : "Let Coastline suggest them from your tools.",
                 tab: .machining),
            Step(title: "Paths", symbol: "point.topleft.down.to.point.bottomright.curvepath", state: state(passed, hasOps, attention: generated && !passed),
                 detail: generated ? (passed ? "Safety-checked. Play them back and compare with the CAD." : "A program needs attention: see Machining.") : "Generate them (a minute or two for 3D finishing).",
                 tab: .machining),
            Step(title: "Export", symbol: "square.and.arrow.up", state: passed ? .next : .later,
                 detail: "A guided job for CRWrite: clamping, edge finding, tools, air cuts, cuts and measuring.",
                 tab: .machining),
        ]
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { k, step in
                Button { model.inspectorTab = step.tab } label: {
                    VStack(spacing: 3) {
                        ZStack {
                            Circle().fill(fill(step.state)).frame(width: 22, height: 22)
                            Image(systemName: step.state == .done ? "checkmark" : step.state == .attention ? "exclamationmark" : step.symbol)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(step.state == .later ? Color.secondary : .white)
                        }
                        Text(step.title).font(.system(size: 9, weight: .medium)).lineLimit(1)
                            .foregroundStyle(step.state == .later ? .secondary : .primary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .help("\(step.title): \(step.detail)")
                if k < steps.count - 1 {
                    Rectangle().fill(step.state == .done ? Theme.ok.opacity(0.6) : Color.secondary.opacity(0.25))
                        .frame(height: 1.5).frame(maxWidth: 14).offset(y: -7)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func fill(_ s: Step.State) -> Color {
        switch s {
        case .done: Theme.ok
        case .attention: Theme.warning
        case .next: Theme.accent
        case .later: Color.secondary.opacity(0.18)
        }
    }
}
