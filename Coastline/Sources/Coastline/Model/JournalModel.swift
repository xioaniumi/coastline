import CoastlineCore
import Foundation
import Observation
import simd

/// The job journal on disk: `journal.json` and a photos folder next to the
/// inventory. Automation runs (COASTLINE_INVENTORY set) get their own beside that file.
@MainActor
@Observable
final class JournalModel {
    private(set) var entries: [JournalEntry] = []
    private(set) var learning = FeedLearning()
    /// When each maintenance task was last done (Maintenance.tasks).
    private(set) var maintenance: [String: Maintenance.Record] = [:]
    let fileURL: URL
    var photosDir: URL { fileURL.deletingLastPathComponent().appendingPathComponent("journal-photos", isDirectory: true) }

    private struct Stored: Codable {
        var entries: [JournalEntry]
        var learning: FeedLearning
        var maintenance: [String: Maintenance.Record]?
    }

    init(fileURL: URL = JournalModel.resolvedURL) {
        self.fileURL = fileURL
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let s = try? dec.decode(Stored.self, from: data) {
            entries = s.entries
            learning = s.learning
            maintenance = s.maintenance ?? [:]
        }
    }

    static var resolvedURL: URL {
        if let path = ProcessInfo.processInfo.environment["COASTLINE_INVENTORY"] {
            return URL(fileURLWithPath: path + ".journal.json")
        }
        return InventoryStore.defaultURL.deletingLastPathComponent().appendingPathComponent("journal.json")
    }

    func add(_ e: JournalEntry, tools: [Tool]) {
        entries.insert(e, at: 0)
        learning.learn(from: e, tools: tools)
        save()
    }

    func remove(_ id: JournalEntry.ID) {
        entries.removeAll { $0.id == id }
        save()
    }

    var totalCuttingMinutes: Double { entries.reduce(0) { $0 + $1.cuttingMinutes } }

    var maintenanceStatus: [Maintenance.Due] {
        Maintenance.status(records: maintenance, jobs: entries.count, cuttingMinutes: totalCuttingMinutes, since: entries.last?.date)
    }

    func markDone(_ taskID: String) {
        maintenance[taskID] = Maintenance.Record(date: Date(), jobs: entries.count, cuttingMinutes: totalCuttingMinutes)
        save()
    }

    /// Copies a photo into the journal's folder; returns its file name there.
    func importPhoto(_ url: URL) -> String? {
        try? FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        let name = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased())
        do {
            try FileManager.default.copyItem(at: url, to: photosDir.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? enc.encode(Stored(entries: entries, learning: learning, maintenance: maintenance)) { try? data.write(to: fileURL, options: .atomic) }
    }
}

extension AppModel {
    /// A journal entry for the job as generated now (programs, checkpoints, stock).
    func draftJournalEntry() -> JournalEntry? {
        guard let part, let stock, !programs.isEmpty else { return nil }
        // Recording may use the bar up: the project keeps its own copy to open again.
        stockSnapshot = stock
        let runs = (prepPrograms + programs).map { p in
            JournalEntry.ProgramRun(title: p.title ?? p.operations.map(\.title).joined(separator: ", "), toolID: p.tool.id, toolName: p.tool.name,
                                    minutes: p.seconds / 60, distance: cuttingDistance(of: p))
        }
        let checks = checkpoints().map { JournalEntry.Measurement(what: $0.what, expected: $0.expected, tolerance: $0.tolerance) }
        var e = JournalEntry(partName: part.fileName, materialID: stock.materialID, stockDescription: stock.sizeDescription,
                             programs: runs, measurements: checks)
        e.projectPath = projectURL?.path
        e.stockID = stock.id
        e.copies = max(setup.copies, 1)
        // What's left of the bar: its length minus what the setup uses (the prep length, or the
        // part's room), if a useful piece remains.
        let raw = setup.rawStockSize(stock)
        let used = setup.prepLength ?? setup.stockSize(stock).y
        let left = max(raw.y, raw.z) - used - 3  // the saw kerf and a clean-up
        e.remnantLength = left >= 10 ? (left * 2).rounded(.down) / 2 : nil
        return e
    }

    private func cuttingDistance(of p: ToolProgram) -> Double {
        let side = p.side == -1 ? prepResults : sideResults
        var d = 0.0
        for r in side {
            for (k, path) in r.paths.enumerated() where k < r.operationProgram.count && r.operationProgram[k] == p.index {
                var last: SIMD3<Double>?
                for m in path.moves {
                    if let l = last, m.role != .rapid { d += simd_distance(l, m.position) }
                    last = m.position
                }
            }
        }
        return d
    }

    /// The learned feed factor for this tool in this material (1 = as computed).
    func learnedFeedFactor(tool: Tool, material: Material) -> Double {
        journal.learning.factor(materialID: material.id, kind: tool.kind)
    }
}
