import Foundation

/// Sorts an operation's engine warnings into real warnings and notes the plan already handles.
/// "This tool is too big for X" is expected when a later operation with a smaller tool is there
/// for exactly that (the planner chose it, even a tool to buy): no warning triangle then.
public enum WarningTriage {
    public static func split(_ warnings: [String], at k: Int, in planned: [EngineClient.PlannedOperation]) -> (warnings: [String], notes: [String]) {
        guard planned.indices.contains(k) else { return (warnings, []) }
        let d = planned[k].tool.diameter
        func smallerLater(_ kinds: Set<OperationKind>, after: Bool = true) -> Bool {
            planned.indices.contains { j in
                (after ? j > k : j != k) && kinds.contains(planned[j].operation.kind) && planned[j].tool.diameter < d - 1e-6
            }
        }
        var keep: [String] = [], notes: [String] = []
        for w in warnings {
            let handled: Bool
            if w.contains("too narrow to rough with this") {
                handled = smallerLater([.adaptive, .contour])
            } else if w.contains("too narrow for the ⌀") {
                // Floors a smaller end mill reaches (its floor pass, or its pocket roughing).
                handled = smallerLater([.floor, .adaptive], after: false)
            } else if w.contains("is too big to bore it") {
                handled = smallerLater([.bore, .drill], after: false)
            } else {
                handled = false
            }
            if handled { notes.append(w) } else { keep.append(w) }
        }
        return (keep, notes)
    }
}
