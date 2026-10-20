import Foundation

/// The job journal: every job you run on the machine, what it took and how it went.
/// Recording one updates the inventory (tool wear, the stock used, the offcut put back) and
/// what Coastline learns about feeds.
public struct JournalEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, CaseIterable, Sendable {
        case good, minorIssues, scrapped
        public var title: String {
            switch self {
            case .good: "Good part"
            case .minorIssues: "Good, with issues"
            case .scrapped: "Scrapped"
            }
        }
    }

    /// One program as it ran: the tool and how long it cut.
    public struct ProgramRun: Codable, Equatable, Sendable {
        public var title: String
        public var toolID: UUID
        public var toolName: String
        public var minutes: Double
        /// Cutting distance, mm.
        public var distance: Double
        public init(title: String, toolID: UUID, toolName: String, minutes: Double, distance: Double) {
            self.title = title
            self.toolID = toolID
            self.toolName = toolName
            self.minutes = minutes
            self.distance = distance
        }
    }

    /// A checkpoint: what to measure, what it should be, and what you measured.
    public struct Measurement: Codable, Equatable, Sendable {
        public var what: String
        public var expected: Double
        public var tolerance: Double
        public var measured: Double?
        public init(what: String, expected: Double, tolerance: Double, measured: Double? = nil) {
            self.what = what
            self.expected = expected
            self.tolerance = tolerance
            self.measured = measured
        }
        public var inTolerance: Bool? { measured.map { abs($0 - expected) <= tolerance + 1e-9 } }
    }

    public var id = UUID()
    public var date = Date()
    public var partName: String
    public var projectPath: String?
    public var materialID: String
    public var stockID: UUID?
    public var stockDescription: String
    public var copies = 1
    public var programs: [ProgramRun]
    public var measurements: [Measurement]
    public var outcome: Outcome = .good
    /// Chatter or squeal heard while cutting (Coastline slows that tool's feeds next time).
    public var chatter = false
    public var chatterToolIDs: [UUID] = []
    /// Surface finish, 1 (rough) … 5 (mirror).
    public var finish = 3
    public var notes = ""
    /// Photo file names in the journal's folder.
    public var photos: [String] = []
    /// Stock left over (put back as an offcut) and whether the bar was used up.
    public var remnantLength: Double?

    public init(partName: String, materialID: String, stockDescription: String, programs: [ProgramRun], measurements: [Measurement]) {
        self.partName = partName
        self.materialID = materialID
        self.stockDescription = stockDescription
        self.programs = programs
        self.measurements = measurements
    }

    public var cuttingMinutes: Double { programs.reduce(0) { $0 + $1.minutes } }
}

public enum JobJournal {
    /// Applies a recorded job to the inventory: each tool's cutting minutes and distance, one
    /// piece of the stock used, and the offcut back as a remnant (same section, shorter).
    public static func record(_ e: JournalEntry, into inv: inout Inventory) -> [String] {
        var notes: [String] = []
        var perTool: [UUID: (Double, Double)] = [:]
        for p in e.programs { perTool[p.toolID, default: (0, 0)].0 += p.minutes; perTool[p.toolID, default: (0, 0)].1 += p.distance }
        for (id, (m, d)) in perTool {
            guard let k = inv.tools.firstIndex(where: { $0.id == id }) else { continue }
            inv.tools[k].cuttingMinutes += m
            inv.tools[k].cuttingDistance += d
        }
        if let sid = e.stockID, let k = inv.stock.firstIndex(where: { $0.id == sid }) {
            let used = inv.stock[k]
            if inv.stock[k].quantity > 1 {
                inv.stock[k].quantity -= 1
            } else {
                inv.stock.remove(at: k)
                notes.append("\(used.sizeDescription) used up: removed from the stock.")
            }
            if let left = e.remnantLength, left >= 10 {
                // The offcut keeps the bar's section; its longest side becomes what's left.
                var r = used
                r.id = UUID()
                r.quantity = 1
                r.isRemnant = true
                r.notes = "Offcut from \(e.partName), \(DateFormatter.localizedString(from: e.date, dateStyle: .short, timeStyle: .none))."
                let sizes = [r.sizeX, r.sizeY, r.sizeZ]
                let longest = r.extrusionAxis ?? sizes.indices.max { sizes[$0] < sizes[$1] }!
                switch longest {
                case 0: r.sizeX = left
                case 1: r.sizeY = left
                default: r.sizeZ = left
                }
                inv.stock.append(r)
                notes.append("Offcut \(r.sizeDescription) put back as a remnant.")
            }
        }
        return notes
    }
}

/// How worn each tool is, from its recorded cutting minutes (Taylor life per material, ToolWear).
public enum ToolLife {
    public struct Status: Equatable, Sendable {
        public var used: Double      // fraction of the expected life
        public var minutes: Double
        public var lifeMinutes: Double
        public var replaceSoon: Bool { used >= 0.8 }
        public var wornOut: Bool { used >= 1 }
    }

    /// Wear in the material it's mostly used for (aluminium if unknown).
    public static func status(_ tool: Tool, material: Material) -> Status {
        let life = ToolWear.life(tool: tool, material: material, pace: 1)
        return Status(used: tool.cuttingMinutes / max(life, 1), minutes: tool.cuttingMinutes, lifeMinutes: life)
    }

    /// What to buy: tools near the end of their life with no spare, and worn or broken ones.
    public static func shoppingList(_ inv: Inventory, material: Material) -> [(tool: Tool, why: String)] {
        inv.tools.compactMap { t in
            let s = status(t, material: material)
            if t.condition == .broken { return (t, "Broken") }
            if t.condition == .worn && t.quantity <= 1 { return (t, "Marked worn, no spare") }
            if s.replaceSoon && t.quantity <= 1 {
                return (t, s.wornOut ? "Past its expected life (\(Int(s.minutes)) of ~\(Int(s.lifeMinutes)) min)"
                    : "\(Int((s.used * 100).rounded())) % of its expected life used, no spare")
            }
            return nil
        }
    }
}

/// What the journal teaches the feeds: a factor per material and tool kind. Chatter slows that
/// kind down by 10 %; three clean jobs in a row give back 3 %. Bounded to 0.6…1.05.
public struct FeedLearning: Codable, Equatable, Sendable {
    public var factors: [String: Double] = [:]
    public var cleanStreak: [String: Int] = [:]
    public init() {}

    public static func key(materialID: String, kind: Tool.Kind) -> String { "\(materialID)|\(kind.rawValue)" }

    public func factor(materialID: String, kind: Tool.Kind) -> Double { factors[Self.key(materialID: materialID, kind: kind)] ?? 1 }

    public mutating func learn(from e: JournalEntry, tools: [Tool]) {
        let kinds = Set(e.programs.compactMap { p in tools.first { $0.id == p.toolID }?.kind })
        let noisy = Set(e.chatterToolIDs.compactMap { id in tools.first { $0.id == id }?.kind })
        for kind in kinds {
            let k = Self.key(materialID: e.materialID, kind: kind)
            var f = factors[k] ?? 1
            if e.chatter && (noisy.isEmpty || noisy.contains(kind)) {
                f *= 0.9
                cleanStreak[k] = 0
            } else if e.outcome != .scrapped {
                let n = (cleanStreak[k] ?? 0) + 1
                cleanStreak[k] = n
                if n % 3 == 0 { f *= 1.03 }
            }
            factors[k] = min(max(f, 0.6), 1.05)
        }
    }
}
