import CoastlineCore
import Foundation

/// Parts to try Coastline with (resources/examples, modelled by scripts/support/make_examples.py),
/// each held a different way on the CR-1. Opening one imports it, puts it in a standard bar
/// (added to the inventory as Not owned when you don't have it) and picks its holding.
@MainActor
struct ExamplePart: Identifiable, Hashable {
    var id: String
    var title: String
    var summary: String
    /// What it shows, as short chips.
    var shows: [String]
    var holding: HoldingPath
    /// The bar it's cut from: material, length × height × thickness (StockItem X, Y, Z: extruded
    /// along X), and which bar size stands up / runs along / faces the spindle (Setup.stockAxes;
    /// nil: Coastline's choice).
    var material: String
    var bar: SIMD3<Double>
    var stockAxes: [Int]?
    /// What to measure on the finished part, beyond the checkpoints Coastline finds itself
    /// (the first-cut coupon's every feature): (what, expected mm, tolerance mm).
    var checks: [(what: String, expected: Double, tolerance: Double)] = []

    nonisolated static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    nonisolated func hash(into h: inout Hasher) { h.combine(id) }

    var stepURL: URL { AppModel.repoRoot.appendingPathComponent("resources/examples/\(id).step") }
    var thumbnailURL: URL { AppModel.repoRoot.appendingPathComponent("resources/examples/\(id).png") }
    /// The example as a saved project with its toolpaths (made by scripts/make-example-projects.sh).
    var projectURL: URL { AppModel.repoRoot.appendingPathComponent("resources/examples/\(id).coastline") }

    static let all: [ExamplePart] = [
        ExamplePart(id: "watch_bridge", title: "Watch Bridge",
                    summary: "A two-jewel bridge in brass, 32 × 13 × 2.5 mm: jewel holes with oil sinks, counterbored screw seats, steady-pin holes.",
                    shows: ["One universal clamp", "Micro end mills", "2.5D detail"], holding: .clampKit,
                    material: "brass-c360", bar: SIMD3(50, 40, 5)),
        ExamplePart(id: "signet_pendant", title: "Signet Pendant",
                    summary: "An oval pendant with a domed front, a flat table to engrave and a hollowed back.",
                    shows: ["Two sides", "Holding tabs", "3D finishing"], holding: .clampKit,
                    material: "al-6061", bar: SIMD3(150, 40, 10)),
        ExamplePart(id: "pocket_rule", title: "Pocket Rule",
                    summary: "A 110 mm rule with a 0–95 mm scale, a countersunk hanging hole and a name field to engrave.",
                    shows: ["Flat on the bed", "Edge finder & paper", "Long and shallow"], holding: .bedOnly,
                    material: "al-6061", bar: SIMD3(150, 60, 20), stockAxes: [2, 0, 1]),
        ExamplePart(id: "motor_mount", title: "Motor Mount",
                    summary: "A NEMA 17 stepper plate: Ø22.5 pilot bore, counterbored M3 holes on the 31 mm square, tension slots.",
                    shows: ["Shoulders at the ends", "Prep on the bed", "Counterbores"], holding: .shoulders,
                    material: "al-6061", bar: SIMD3(150, 50, 10)),
        ExamplePart(id: "first_cut", title: "First-Cut Coupon",
                    summary: "A 34 × 24 × 6 test piece for your first cut: facing, the outline, a pocket, two holes and a step, each with a size to measure. Wax first, then POM, then aluminium.",
                    shows: ["First cut", "Something to measure", "Wax · POM · aluminium"], holding: .clampKit,
                    material: "wax-machinable", bar: SIMD3(100, 38, 25),
                    checks: [("Coupon length", 34, 0.05), ("Coupon width", 24, 0.05),
                             ("Pocket length", 14, 0.05), ("Pocket width", 8, 0.05), ("Pocket depth", 2.5, 0.05),
                             ("Small hole Ø", 4, 0.05), ("Large hole Ø", 6, 0.05), ("Step depth", 1.5, 0.05)]),
    ]

    /// The example this part is (by its file), if it is one.
    static func of(_ partURL: URL?) -> ExamplePart? {
        guard let name = partURL?.lastPathComponent else { return nil }
        return all.first { $0.stepURL.lastPathComponent == name }
    }
}

extension AppModel {
    /// Opens an example: the part, its bar (yours if you have one that size, else a standard
    /// size marked Not owned), and the holding it was made to show.
    func openExample(_ example: ExamplePart, inventory: InventoryModel) async {
        // Saved with its toolpaths: opens ready, nothing to generate.
        if FileManager.default.fileExists(atPath: example.projectURL.path) {
            await openProject(example.projectURL)  // adds its bar and tools when you haven't got them
            // A copy of the example is yours to change: saving asks where (the bundled one stays).
            projectURL = nil
            return
        }
        await importPart(example.stepURL)
        guard part != nil else { return }
        let bar = example.bar
        func same(_ s: StockItem) -> Bool {
            s.materialID == example.material && s.shape == .block
                && abs(s.sizeX - bar.x) < 0.01 && abs(s.sizeY - bar.y) < 0.01 && abs(s.sizeZ - bar.z) < 0.01
        }
        let item: StockItem
        if let owned = inventory.inventory.stock.first(where: { same($0) && !$0.isSuggestion }) ?? inventory.inventory.stock.first(where: same) {
            item = owned
        } else {
            var s = StockItem(materialID: example.material, sizeX: bar.x, sizeY: bar.y, sizeZ: bar.z, quantity: 0, finish: .sawn,
                              supplier: StockCatalog.source,
                              notes: "Not in your inventory: a standard size. The bar the \(example.title) example is cut from.")
            s.extrusionAxis = 0
            inventory.update { $0.stock.append(s) }
            item = s
        }
        useStock(item)
        // The holding first: on the bed, the bar then lies the example's way without being
        // stood back up for the clamp kit (keepStockWorkable).
        if holdingPath != example.holding { choose(example.holding) }
        if let axes = example.stockAxes { useStockAxes(axes) }
        stage = .partStock
        status = "Example: \(example.title) · \(example.holding.title.lowercased())"
    }
}
