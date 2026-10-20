import SwiftUI

extension View {
    /// Delete with a confirmation that names what goes: the toolbar's Delete, the context menu's
    /// and the Delete key (⌫) all set `pending`; nothing is removed until it's confirmed.
    func confirmingDelete<ID: Hashable>(_ pending: Binding<Set<ID>?>, name: @escaping (Set<ID>) -> String,
                                        delete: @escaping (Set<ID>) -> Void) -> some View {
        confirmationDialog(pending.wrappedValue.map { "Delete \(name($0))?" } ?? "Delete?",
                           isPresented: Binding(get: { pending.wrappedValue?.isEmpty == false }, set: { if !$0 { pending.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: pending.wrappedValue) { ids in
            Button("Delete", role: .destructive) { delete(ids) }
            Button("Cancel", role: .cancel) {}
        } message: { ids in
            Text(ids.count == 1 ? "It's removed from your inventory." : "They're removed from your inventory.")
        }
    }
}

enum DeleteName {
    /// “Name” for one item, "3 tools" for several.
    static func of(_ names: [String], noun: String, plural: String? = nil) -> String {
        names.count == 1 ? "“\(names[0])”" : "\(names.count) \(plural ?? noun + "s")"
    }
}
