import Foundation

/// Everything the user owns: stock, tools, fixtures, measuring tools and accessories.
/// Stored as one human-readable JSON file so it's easy to back up, diff and fix by hand.
public struct Inventory: Equatable, Sendable, Codable {
    /// Bump when the format changes, and migrate in `InventoryStore.load`.
    public static let currentSchema = 1

    public var schema = Inventory.currentSchema
    public var stock: [StockItem] = []
    public var tools: [Tool] = []
    public var fixtures: [Fixture] = []
    /// The flat clamping kit (stops, riser, C-clamps) was added once; removing it later sticks.
    public var flatKitAdded: Bool?
    /// The suggested tools (ToolCatalog) were added once.
    public var toolSuggestionsAdded: Bool?
    /// The catalog version whose suggestions this inventory has (nil: the first one).
    public var toolSuggestionsVersion: Int?
    /// The StockCatalog version whose standard sizes this inventory has.
    public var stockSuggestionsVersion: Int?
    public var measuring: [MeasuringTool] = []
    public var accessories: [Accessory] = []

    public init() {}

    public var isEmpty: Bool {
        stock.isEmpty && tools.isEmpty && fixtures.isEmpty && measuring.isEmpty && accessories.isEmpty
    }

    /// Collet bores you own, in mm.
    public var colletSizes: [Double] {
        accessories.filter { $0.kind == .collet && $0.quantity > 0 }.compactMap(\.size)
    }
}

/// Loads and saves the inventory JSON.
public enum InventoryStore {
    /// `~/Library/Application Support/Coastline/Inventory.json`
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Coastline/Inventory.json")
    }

    public enum StoreError: Error, CustomStringConvertible {
        case newerSchema(Int)
        public var description: String {
            switch self {
            case .newerSchema(let v): "This inventory was saved by a newer Coastline (format \(v)). Update the app."
            }
        }
    }

    /// Returns nil when there's no file yet.
    public static func load(from url: URL = defaultURL) throws -> Inventory? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let inventory = try JSONDecoder().decode(Inventory.self, from: data)
        if inventory.schema > Inventory.currentSchema { throw StoreError.newerSchema(inventory.schema) }
        return inventory
    }

    /// Writes atomically, keeping the previous version as `Inventory.json.bak`.
    public static func save(_ inventory: Inventory, to url: URL = defaultURL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(inventory)
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        try data.write(to: url, options: .atomic)
    }
}

extension Inventory {
    /// The starting inventory on first launch, built from what ships in the standard CR-1 kit:
    /// - Coast Runner's two Fusion tool libraries (the tools used in the CR-1 lessons);
    /// - the ER-11 collets the Coast Runner cutcodes use (1/8" and 1/4");
    /// - the universal clamp, jig plate and T-slot nuts from the CR-1 clamp kit;
    /// - the Fisher A250 edge finder from the operator manual;
    /// - the 150 × 80 × 20 mm 6061 block modelled in `CoastRunnerCNCDimensions.3dm`.
    /// Everything is editable; the app asks the user to confirm what they actually own.
    /// What holds stock flat on the bed before it fits the clamp kit (FlatPrep): the two
    /// acetal squaring stops, the kit's riser plate and two 3" C-clamps.
    public static let flatClampingKit: [Fixture] = [
        Fixture(name: "Acetal squaring stop", kind: .squaringStop, quantity: 2, height: 25.4,
                notes: "54 × 19 × 25.4 mm acetal brick, bolted across both T-slots (M4x25 + T-slot nuts). Its spindle-side face sits level with the table's edge, so stock always sticks out past it by the cut + 2 mm."),
        Fixture(name: "Riser plate", kind: .riser, quantity: 1, height: FlatPrep.riserHeight,
                notes: "12.7 mm aluminium plate under flat stock, placed just behind the squaring stop's face so the cut overhangs it."),
        Fixture(name: "3\" C-clamp", kind: .cClamp, quantity: 2, gripRange: 0 ... FlatPrep.clampOpening,
                notes: "Screw C-clamp from the Coast Runner kit: 76 mm opening, 50 mm throat. Reaches around the table's back edge to hold flat stock on the riser."),
    ]

    public static func starter(toolLibraries: [URL]) -> Inventory {
        var inv = Inventory()
        for url in toolLibraries {
            guard let result = try? FusionToolImport.load(url) else { continue }
            inv.tools += result.tools.map {
                var t = $0
                t.notes = "Imported from Coast Runner's library. Set the quantity to what you own."
                return t
            }
        }
        inv.accessories = [
            Accessory(name: "ER-11 collet 1/8\"", kind: .collet, size: 3.175, notes: "Used by Coast Runner's cutcodes."),
            Accessory(name: "ER-11 collet 1/4\"", kind: .collet, size: 6.35, notes: "Used by Coast Runner's cutcodes."),
        ]
        inv.fixtures = [
            Fixture(name: "CR-1 Universal Clamp", kind: .universalClamp, quantity: 1, clampAxis: .x,
                    height: 0, isolated: true, modelPath: "fixtures/universal_clamp_v96.step",
                    notes: "Bolts to the T-slots, clamps in X and is electrically isolated, so conductive probing works. [MAN §4.4]"),
            Fixture(name: "Quick Release Jig Plate", kind: .jigPlate, quantity: 1,
                    modelPath: "fixtures/quick_release_jig_plate.step",
                    notes: "Jig Plate Rev D (metric). M5 shoulder bolts, insulating pad and washer."),
            Fixture(name: "M4 T-slot nuts", kind: .tSlotNuts, quantity: 4,
                    notes: "Fairway JPPNM04016 (11 × 3.14 × 15.87 mm). 80/20 25-1941 / 25-1951 are equivalent."),
        ] + Self.flatClampingKit
        inv.flatKitAdded = true
        inv.measuring = [
            MeasuringTool(name: "Fisher A250 edge finder", kind: .edgeFinder, resolution: 0.01,
                          notes: "0.2\" (5.08 mm) tip: offset 2.54 mm. Run at about 1500 RPM. [MAN §4.6]"),
        ]
        inv.stock = [
            StockItem(materialID: "al-6061", sizeX: 150, sizeY: 80, sizeZ: 20, notes: "From your CR-1 dimensions model."),
        ]
        return inv
    }
}
