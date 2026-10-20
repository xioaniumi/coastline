import CoastlineCore
import Foundation

private let libraries = repoRoot.appendingPathComponent("resources/libraries")

let materialTests: [TestCase] = [
    TestCase(name: "libraryIsConsistent") {
        let all = MaterialLibrary.all
        try expectEqual(Set(all.map(\.id)).count, all.count, "duplicate ids")
        for family in Material.Family.allCases {
            try expect(all.contains { $0.family == family }, "no material in \(family)")
        }
        for m in all {
            try expect(m.surfaceSpeed.lowerBound > 0 && m.surfaceSpeed.upperBound <= 1000, m.id)
            try expect((0.1 ... 3).contains(m.chipLoadFactor), m.id)
            try expect((0.02 ... 0.3).contains(m.adaptiveStepoverMax), m.id)
            try expect(m.density > 0.5 && m.density < 20, m.id)
            try expect(!m.lubricant.isEmpty && !m.chips.isEmpty && !m.tooling.isEmpty, m.id)
        }
    },
    TestCase(name: "aluminiumIsTheReferenceAndSteelIsSlower") {
        let al = MaterialLibrary.material(id: "al-6061")!
        let steel = MaterialLibrary.material(id: "steel-1018")!
        try expectEqual(al.chipLoadFactor, 1.0)
        try expect(steel.chipLoadFactor < 0.5 && steel.difficulty >= .careful)
        // A 1/4" tool in 6061 wants far more than 8000 RPM, which is why the CR-1 runs it at its cap.
        try expect(al.idealRPM(toolDiameter: 6.35) > MachineProfile.cr1.spindleRPM.upperBound)
        try expect(MaterialLibrary.material(id: "ti-gr5")!.difficulty == .experimental)
    },
]

let inventoryTests: [TestCase] = [
    TestCase(name: "fusionAluminiumLibraryImportsInMillimetres") {
        let r = try FusionToolImport.load(libraries.appendingPathComponent("CR-tools-for-Aluminum.tools"))
        try expectEqual(r.tools.count, 9)
        try expect(r.skipped.isEmpty, "\(r.skipped)")
        let t2 = try unwrap(r.tools.first { $0.partNumber == "48031" })
        try expectEqual(t2.kind, .flatEndMill)
        try expect(abs(t2.diameter - 4.7625) < 1e-9, "3/16\" = 4.7625 mm, got \(t2.diameter)")
        try expect(abs(t2.stickout - 28.575) < 1e-9)  // LB 1.125"
        try expectEqual(t2.flutes, 3)
        try expect(t2.source.hasSuffix("T2"))
        let preset = try unwrap(t2.presets.first)
        try expectEqual(preset.rpm, 8000)
        try expect(abs(preset.feed - 508) < 1e-9, "20 ipm = 508 mm/min")
        let ball = try unwrap(r.tools.first { $0.kind == .ballEndMill })
        try expect(abs(ball.cornerRadius - 1.5875) < 1e-9)
        let chamfer = try unwrap(r.tools.first { $0.kind == .chamferMill })
        try expectEqual(chamfer.angle, 45)
        try expectEqual(r.tools.first { $0.partNumber == "03017" }?.coating, .tiN)  // "TiN coated"
    },
    TestCase(name: "fusionSteelLibraryImports") {
        let r = try FusionToolImport.load(libraries.appendingPathComponent("CR-tools-for-Steel.tools"))
        try expectEqual(r.tools.count, 8)
        let bull = try unwrap(r.tools.first { $0.kind == .bullNoseEndMill })
        try expect(abs(bull.cornerRadius - 0.254) < 1e-9)
        try expectEqual(bull.flutes, 4)
    },
    TestCase(name: "coatingIsMatchedOnWholeWordsOnly") {
        let json = #"{"data":[{"type":"flat end mill","unit":"millimeters","description":"Cutting tool","geometry":{"DC":3,"SFDM":3,"NOF":2,"LCF":8,"LB":15,"OAL":38}}]}"#
        let r = try FusionToolImport.parse(Data(json.utf8), sourceName: "t")
        try expectEqual(r.tools.first?.coating, Tool.Coating.none)
    },
    TestCase(name: "starterInventoryAndJSONRoundTrip") {
        let inv = Inventory.starter(toolLibraries: [
            libraries.appendingPathComponent("CR-tools-for-Aluminum.tools"),
            libraries.appendingPathComponent("CR-tools-for-Steel.tools"),
        ])
        try expectEqual(inv.tools.count, 17)
        try expectEqual(inv.colletSizes.sorted(), [3.175, 6.35])
        try expect(inv.fixtures.contains { $0.kind == .universalClamp && $0.isolated })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coastline-test-\(UUID())/Inventory.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try InventoryStore.save(inv, to: url)
        try InventoryStore.save(inv, to: url)  // second save makes a .bak
        try expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
        try expectEqual(try InventoryStore.load(from: url), inv)
        try expect(try InventoryStore.load(from: url.deletingLastPathComponent().appendingPathComponent("none.json")) == nil)
    },
    TestCase(name: "newerSchemaIsRefused") {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coastline-schema-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var inv = Inventory()
        inv.schema = Inventory.currentSchema + 1
        try InventoryStore.save(inv, to: url)
        try expectThrows { _ = try InventoryStore.load(from: url) }
    },
    TestCase(name: "toolChecksCatchMachineLimits") {
        var inv = Inventory()
        inv.accessories = [Accessory(name: "1/4", kind: .collet, size: 6.35)]
        let ok = Tool(name: "1/4 flat", kind: .flatEndMill, diameter: 6.35, shankDiameter: 6.35, flutes: 3,
                      fluteLength: 12.7, stickout: 28.6, overallLength: 50.8)
        try expect(InventoryChecks.check(ok, inventory: inv).allSatisfy { $0.severity < .warning })
        var noCollet = ok
        noCollet.shankDiameter = 4.7625
        try expect(InventoryChecks.check(noCollet, inventory: inv).contains { $0.severity == .warning && $0.message.contains("collet") })
        var tooLong = ok
        tooLong.overallLength = 80
        try expect(InventoryChecks.check(tooLong, inventory: inv).contains { $0.severity == .error && $0.message.contains("homing") })
        var bigShank = ok
        bigShank.shankDiameter = 10
        try expect(InventoryChecks.check(bigShank, inventory: inv).contains { $0.severity == .error })
        var flutesInCollet = ok
        flutesInCollet.stickout = 10
        try expect(InventoryChecks.check(flutesInCollet, inventory: inv).contains { $0.message.contains("inside the collet") })
    },
    TestCase(name: "stockChecksUseTheEnvelope") {
        let fits = StockItem(materialID: "al-6061", sizeX: 150, sizeY: 80, sizeZ: 20)
        try expect(InventoryChecks.check(fits).allSatisfy { $0.severity < .error })
        let huge = StockItem(materialID: "al-6061", sizeX: 300, sizeY: 80, sizeZ: 20)
        try expect(InventoryChecks.check(huge).contains { $0.severity == .error })
        let tall = StockItem(materialID: "al-6061", sizeX: 60, sizeY: 60, sizeZ: 60, finish: .milled)
        try expect(InventoryChecks.check(tall).contains { $0.message.contains("of Z") })
        let bar = StockItem(materialID: "brass-c360", shape: .roundBar, sizeX: 20, sizeY: 100, sizeZ: 0)
        try expect(abs((bar.weight ?? 0) - Double.pi * 100 * 100 / 1000 * 8.5) < 0.01)
        try expect(InventoryChecks.check(bar).allSatisfy { $0.severity < .error })
    },
    TestCase(name: "lengthFormatting") {
        try expectEqual(Length.describe(6.35), "6.35 mm (1/4\")")
        try expectEqual(Length.describe(3), "3 mm")
        try expectEqual(Length.inchFraction(25.4), "1\"")
        try expectEqual(Length.inchFraction(4.7625), "3/16\"")
        try expectEqual(Length.mm(12.700), "12.7")
    },
]

func unwrap<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else { throw TestFailure(description: "\(file):\(line) unexpected nil") }
    return value
}
