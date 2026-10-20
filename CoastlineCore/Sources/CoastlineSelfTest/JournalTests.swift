import CoastlineCore
import Foundation
import simd

let journalTests: [TestCase] = [
    TestCase(name: "recordingAJobWearsToolsUsesStockAndPutsTheOffcutBack") {
        let tool = Tool(name: "1/4\" flat end mill", kind: .flatEndMill, diameter: 6.35, shankDiameter: 6.35, flutes: 3,
                        fluteLength: 19, stickout: 28, overallLength: 63.5)
        var bar = StockItem(materialID: "al-6061", sizeX: 150, sizeY: 80, sizeZ: 20)
        bar.extrusionAxis = 0
        var inv = Inventory()
        inv.tools = [tool]
        inv.stock = [bar]
        var e = JournalEntry(partName: "Pendant", materialID: "al-6061", stockDescription: bar.sizeDescription,
                             programs: [.init(title: "Roughing", toolID: tool.id, toolName: tool.name, minutes: 30, distance: 12_000),
                                        .init(title: "Facing", toolID: tool.id, toolName: tool.name, minutes: 5, distance: 2_000)],
                             measurements: [.init(what: "Thickness", expected: 5, tolerance: 0.05, measured: 5.03)])
        e.stockID = bar.id
        e.remnantLength = 62
        let notes = JobJournal.record(e, into: &inv)
        try expect(abs(inv.tools[0].cuttingMinutes - 35) < 1e-9 && abs(inv.tools[0].cuttingDistance - 14_000) < 1e-9)
        // The bar is used up; a 62 mm offcut of the same section comes back as a remnant.
        try expectEqual(inv.stock.count, 1)
        let r = inv.stock[0]
        try expect(r.isRemnant && r.id != bar.id && r.sizeX == 62 && r.sizeY == 80 && r.sizeZ == 20, "\(r.sizeDescription)")
        try expect(notes.count == 2, "\(notes)")
        try expectEqual(e.measurements[0].inTolerance, true)
        // Tool life: 35 of ~900 minutes in aluminium; far from the shopping list.
        let al = MaterialLibrary.material(id: "al-6061")!
        try expect(ToolLife.status(inv.tools[0], material: al).used < 0.1)
        try expect(ToolLife.shoppingList(inv, material: al).isEmpty)
        inv.tools[0].cuttingMinutes = 850
        try expectEqual(ToolLife.shoppingList(inv, material: al).count, 1, "nearly worn out, no spare")
        inv.tools[0].quantity = 3
        try expect(ToolLife.shoppingList(inv, material: al).isEmpty, "spares on hand")
    },
    TestCase(name: "chatterTeachesSlowerFeedsCleanJobsGiveSomeBack") {
        let ball = Tool(name: "1/8\" ball", kind: .ballEndMill, diameter: 3.175, shankDiameter: 3.175, flutes: 2,
                        fluteLength: 9.5, stickout: 15, overallLength: 38)
        var learn = FeedLearning()
        var e = JournalEntry(partName: "P", materialID: "al-6061", stockDescription: "", programs:
                                [.init(title: "Finish", toolID: ball.id, toolName: ball.name, minutes: 10, distance: 1)], measurements: [])
        e.chatter = true
        learn.learn(from: e, tools: [ball])
        try expect(abs(learn.factor(materialID: "al-6061", kind: .ballEndMill) - 0.9) < 1e-9)
        try expectEqual(learn.factor(materialID: "brass-360", kind: .ballEndMill), 1, "other materials untouched")
        e.chatter = false
        for _ in 0..<3 { learn.learn(from: e, tools: [ball]) }
        try expect(abs(learn.factor(materialID: "al-6061", kind: .ballEndMill) - 0.9 * 1.03) < 1e-9)
        e.chatter = true
        for _ in 0..<20 { learn.learn(from: e, tools: [ball]) }
        try expectEqual(learn.factor(materialID: "al-6061", kind: .ballEndMill), 0.6, "never below 60 %")
    },
    TestCase(name: "batchCopiesAreSpacedWithTheirOwnBandsAndAWeb") {
        let o = Setup.copyOffsets(count: 3, partY: 24)
        let pitch = Setup.copyPitch(partY: 24)
        try expect(abs(pitch - (24 + 2 * 7.35 + 3)) < 1e-9)
        try expect(o.count == 3 && abs(o[0] + pitch) < 1e-9 && abs(o[1]) < 1e-9 && abs(o[2] - pitch) < 1e-9)
        // 150 mm bar, 24 mm part: the first copy takes 24 + 14.7, each more one pitch.
        try expectEqual(Setup.maxCopies(stockY: 150, partY: 24), 1 + Int(((150 - 14.7 - 24) / pitch).rounded(.down)))
        try expectEqual(Setup.maxCopies(stockY: 30, partY: 24), 1)
        var s = Setup()
        s.copies = 3
        let back = try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(s))
        try expectEqual(back.copies, 3)
    },
    TestCase(name: "engravingTextBecomesClosedOutlinesOfTheRightSize") {
        let e = Engraving(text: "HI", height: 4, x: 1, y: -2, depth: 0.15, font: "Helvetica-Bold")
        let loops = e.polylines()
        try expect(loops.count >= 2, "H and I: \(loops.count) outlines")
        try expect(loops.allSatisfy { simd_distance($0.first!, $0.last!) < 1e-6 }, "closed")
        // Capital height along work X (up), the word along Y, centred on (1, -2).
        let pts = loops.flatMap { $0 }
        let lo = pts.reduce(SIMD2(Double.infinity, .infinity)) { simd_min($0, $1) }, hi = pts.reduce(-SIMD2(Double.infinity, .infinity)) { simd_max($0, $1) }
        try expect(abs((hi.x - lo.x) - 4) < 0.2, "height \(hi.x - lo.x)")
        try expect(abs((lo.x + hi.x) / 2 - 1) < 0.2 && abs((lo.y + hi.y) / 2 + 2) < 0.6, "centre \((lo + hi) / 2)")
        try expect(hi.y - lo.y > 3, "the word runs along Y")
        // Turned 90°: it runs along X instead.
        var turned = e
        turned.angle = 90
        let s = turned.size, flat = e.size
        try expect(abs(s.y - flat.x) < 0.1 && abs(s.x - flat.y) < 0.1, "turned \(s) vs \(flat)")
        // Operations saved before engraving existed still open.
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"contour","enabled":true,"leaveRadial":0,"leaveAxial":0,"faceDepth":0.25,"springPass":false,"scallop":0.008,"angle":0,"steepAngle":45,"feedScale":1}"#
        let op = try JSONDecoder().decode(Operation.self, from: Data(old.utf8))
        try expect(op.engraving == nil && op.kind == .contour)
    },
]
