import CoastlineCore
import Foundation
import Observation
import SwiftUI

/// The inventory as the UI sees it: loads `Inventory.json`, autosaves edits (debounced) and
/// hands out bindings to individual items for the inspectors.
@MainActor
@Observable
final class InventoryModel {
    private(set) var inventory = Inventory()
    var lastError: String?
    /// True after the starter inventory was created, until the user dismisses the banner.
    var showStarterBanner = false

    let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(fileURL: URL = InventoryModel.resolvedURL) {
        self.fileURL = fileURL
        do {
            if var loaded = try InventoryStore.load(from: fileURL) {
                // Once: the flat clamping kit (squaring stops, riser, C-clamps) joins inventories
                // made before it was listed.
                // Once: the tools Coastline may suggest buying (quantity 0, marked).
                if loaded.toolSuggestionsAdded != true || (loaded.toolSuggestionsVersion ?? 1) < ToolCatalog.version {
                    loaded.toolSuggestionsVersion = ToolCatalog.version
                    let have = Set(loaded.tools.map(\.id))
                    loaded.tools += ToolCatalog.suggestions.filter { !have.contains($0.id) }
                    // Suggestions Coastline no longer makes go, unless you bought them.
                    loaded.tools.removeAll { ToolCatalog.retired.contains($0.id) && $0.isSuggestion }
                    loaded.toolSuggestionsAdded = true
                    try? InventoryStore.save(loaded, to: fileURL)
                }
                // Suggestions not bought yet follow the catalog (its specs get better).
                var refreshed = false
                for i in loaded.tools.indices where loaded.tools[i].isSuggestion {
                    if let c = ToolCatalog.suggestions.first(where: { $0.id == loaded.tools[i].id }), c != loaded.tools[i] {
                        loaded.tools[i] = c
                        refreshed = true
                    }
                }
                // Standard stock sizes to buy (quantity 0, marked), once per catalog version.
                if (loaded.stockSuggestionsVersion ?? 0) < StockCatalog.version {
                    loaded.stockSuggestionsVersion = StockCatalog.version
                    let have = Set(loaded.stock.map(\.id))
                    loaded.stock += StockCatalog.suggestions.filter { !have.contains($0.id) }
                    refreshed = true
                }
                if refreshed { try? InventoryStore.save(loaded, to: fileURL) }
                if loaded.flatKitAdded != true {
                    let have = Set(loaded.fixtures.map(\.kind))
                    loaded.fixtures += Inventory.flatClampingKit.filter { !have.contains($0.kind) }
                    loaded.flatKitAdded = true
                    try? InventoryStore.save(loaded, to: fileURL)
                }
                inventory = loaded
            } else {
                inventory = Inventory.starter(toolLibraries: Self.bundledToolLibraries)
                inventory.tools += ToolCatalog.suggestions
                inventory.toolSuggestionsAdded = true
                inventory.toolSuggestionsVersion = ToolCatalog.version
                inventory.stock += StockCatalog.suggestions
                inventory.stockSuggestionsVersion = StockCatalog.version
                showStarterBanner = true
                try InventoryStore.save(inventory, to: fileURL)
            }
        } catch {
            lastError = "\(error)"
        }
    }

    /// `COASTLINE_INVENTORY` overrides the location (used by automation so tests don't touch
    /// the real file).
    static var resolvedURL: URL {
        if let path = ProcessInfo.processInfo.environment["COASTLINE_INVENTORY"] {
            return URL(fileURLWithPath: path)
        }
        return InventoryStore.defaultURL
    }

    /// Coast Runner's Fusion libraries shipped with Coastline (`resources/libraries`).
    static var bundledToolLibraries: [URL] {
        let dir = AppModel.repoRoot.appendingPathComponent("resources/libraries")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "tools" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Editing

    func update(_ change: (inout Inventory) -> Void) {
        change(&inventory)
        scheduleSave()
    }

    /// A binding to one item of a list in the inventory, by id. Returns nil if it was deleted.
    func binding<T: Identifiable>(_ list: WritableKeyPath<Inventory, [T]>, id: T.ID) -> Binding<T>? {
        guard let current = inventory[keyPath: list].first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.inventory[keyPath: list].first { $0.id == id } ?? current },
            set: { [weak self] newValue in
                self?.update { inv in
                    if let i = inv[keyPath: list].firstIndex(where: { $0.id == id }) { inv[keyPath: list][i] = newValue }
                }
            }
        )
    }

    func add<T>(_ item: T, to list: WritableKeyPath<Inventory, [T]>) {
        update { $0[keyPath: list].append(item) }
    }

    func remove<T: Identifiable>(_ ids: Set<T.ID>, from list: WritableKeyPath<Inventory, [T]>) {
        update { $0[keyPath: list].removeAll { ids.contains($0.id) } }
    }

    func duplicate<T: Identifiable & Codable>(_ id: T.ID, in list: WritableKeyPath<Inventory, [T]>, newID: (inout T) -> Void) {
        guard var copy = inventory[keyPath: list].first(where: { $0.id == id }) else { return }
        newID(&copy)
        add(copy, to: list)
    }

    /// Imports a Fusion `.tools` / `.json` library. Returns a summary for the alert.
    func importToolLibrary(_ url: URL) -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try FusionToolImport.load(url)
            let known = Set(inventory.tools.map { "\($0.vendor)|\($0.partNumber)|\($0.diameter)" })
            let fresh = result.tools.filter { $0.partNumber.isEmpty || !known.contains("\($0.vendor)|\($0.partNumber)|\($0.diameter)") }
            update { $0.tools += fresh }
            var message = "Imported \(fresh.count) tool\(fresh.count == 1 ? "" : "s") from \(url.lastPathComponent)."
            if fresh.count < result.tools.count { message += " \(result.tools.count - fresh.count) were already in your inventory." }
            if !result.skipped.isEmpty { message += "\n\nSkipped:\n" + result.skipped.joined(separator: "\n") }
            return message
        } catch {
            return "\(error)"
        }
    }

    func resetToStarter() {
        inventory = Inventory.starter(toolLibraries: Self.bundledToolLibraries)
        saveNow()  // immediately, so Inventory.json.bak holds the replaced inventory
        showStarterBanner = true
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try InventoryStore.save(inventory, to: fileURL)
            lastError = nil
        } catch {
            lastError = "Couldn't save the inventory: \(error)"
        }
    }

    // MARK: Checks

    func issues(for tool: Tool) -> [Issue] { InventoryChecks.check(tool, inventory: inventory) }
    func issues(for stock: StockItem) -> [Issue] { InventoryChecks.check(stock) }

    func worstIssue(for tool: Tool) -> Issue.Severity? { issues(for: tool).map(\.severity).max() }
    func worstIssue(for stock: StockItem) -> Issue.Severity? { issues(for: stock).map(\.severity).max() }

    /// Suggested stock was bought: it joins the inventory as owned.
    func markStockOwned(_ ids: Set<StockItem.ID>) {
        update { inv in
            for k in inv.stock.indices where ids.contains(inv.stock[k].id) && inv.stock[k].isSuggestion {
                inv.stock[k].quantity = 1
                inv.stock[k].supplier = ""
                inv.stock[k].notes = inv.stock[k].notes.replacingOccurrences(of: "Not in your inventory: a standard size. ", with: "")
            }
        }
    }

    /// A suggested tool was bought: it joins the inventory as owned.
    func markOwned(_ id: Tool.ID) {
        update { inv in
            for k in inv.tools.indices where inv.tools[k].id == id && inv.tools[k].isSuggestion {
                inv.tools[k].quantity = 1
                inv.tools[k].source = "Bought on Coastline's suggestion"
            }
        }
    }
}
