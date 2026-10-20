import CoastlineCore
import Foundation

extension AppModel {
    /// A new thread milling operation: the thread the part's holes were most likely made for
    /// (their diameter against the tap drills), and the thread mill that cuts it (yours first,
    /// else a suggestion to buy). Every choice can be changed in the operation.
    func prepareThread(_ op: inout Operation, inventory: Inventory) {
        let holes = features?.holes ?? []
        let spec = holes.lazy.compactMap { ThreadSpec.likely(forHole: $0.diameter) }.first ?? ThreadSpec.named("M3")!
        op.thread = ThreadMilling(spec: spec.name)
        let mills = inventory.tools.filter { $0.kind == .threadMill && $0.condition != .broken && ($0.quantity > 0 || $0.isSuggestion) && spec.canBeCut(by: $0) }
        op.toolID = mills.min { ($0.quantity > 0 ? 0 : 1, -$0.fluteLength) < ($1.quantity > 0 ? 0 : 1, -$1.fluteLength) }?.id
    }

    /// Threads go into holes the other operations make: always after them (stable otherwise).
    static func threadsLast(_ planned: [EngineClient.PlannedOperation]) -> [EngineClient.PlannedOperation] {
        planned.filter { $0.operation.kind != .thread } + planned.filter { $0.operation.kind == .thread }
    }
}
