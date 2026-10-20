import Foundation

/// The CR-1's care, from the Operator Manual (section 7.1, Basic Maintenance), tracked against
/// the job journal: what's due after how many jobs, cutting hours or days.
public enum Maintenance {
    public struct Task: Identifiable, Sendable {
        public var id: String
        public var title: String
        public var detail: String
        /// Due after this many recorded jobs, cutting hours or days since it was last done
        /// (whichever comes first; nil: not that kind).
        public var everyJobs: Int?
        public var everyHours: Double?
        public var everyDays: Double?
    }

    public static let tasks: [Task] = [
        Task(id: "wipe-oil", title: "Wipe and oil the shafts and ballscrews",
             detail: "Wipe the walls, table and mirrored spindle guard with a rag, then the shafts, ballscrews and sealed bearings (a cotton swab around the seals) and give the shafts and ballscrews a light coat of oil. After every major job (Operator Manual 7.1.1).",
             everyJobs: 1),
        Task(id: "belts", title: "Check the three belts",
             detail: "Spindle, Y and Z belts: black rubber dust at the back or the right side of the mill means one is wearing; turn the mill over to look at them. Replace a worn belt (Operator Manual 7.1.1, 7.2).",
             everyHours: 10, everyDays: 30),
        Task(id: "deep-clean", title: "Deep clean: vacuum under the table and around the X motors",
             detail: "Vacuum the chips that collect around the X motors and under the table, where the hose reaches from the front. Never compressed air: it pushes chips past the seals into the electronics.",
             everyHours: 5, everyDays: 14),
    ]

    /// When a task was last done, and the journal's totals then.
    public struct Record: Codable, Equatable, Sendable {
        public var date: Date
        public var jobs: Int
        public var cuttingMinutes: Double
        public init(date: Date, jobs: Int, cuttingMinutes: Double) {
            self.date = date
            self.jobs = jobs
            self.cuttingMinutes = cuttingMinutes
        }
    }

    public struct Due: Sendable {
        public var task: Task
        public var due: Bool
        public var why: String
    }

    /// Each task's state from the journal totals now. A task never done counts from the first
    /// recorded job (`since`), not from the beginning of time.
    public static func status(records: [String: Record], jobs: Int, cuttingMinutes: Double, since firstJob: Date? = nil,
                              now: Date = Date()) -> [Due] {
        tasks.map { t in
            let r = records[t.id] ?? Record(date: firstJob ?? .distantPast, jobs: 0, cuttingMinutes: 0)
            let jobsSince = jobs - r.jobs, hoursSince = (cuttingMinutes - r.cuttingMinutes) / 60
            let daysSince = now.timeIntervalSince(r.date) / 86_400
            var reasons: [String] = []
            if let n = t.everyJobs, jobsSince >= n { reasons.append("\(jobsSince) job\(jobsSince == 1 ? "" : "s") since") }
            if let h = t.everyHours, hoursSince >= h { reasons.append(String(format: "%.1f cutting hours since", hoursSince)) }
            // Days only count once the machine has been used since (an idle mill isn't dirtier).
            if let d = t.everyDays, daysSince >= d, jobsSince > 0 { reasons.append(r.date == .distantPast ? "not done yet" : "\(Int(daysSince)) days since") }
            if records[t.id] == nil, reasons.isEmpty, jobs > 0 {
                return Due(task: t, due: false, why: "Not due yet (counted from your first recorded job).")
            }
            if records[t.id] == nil && jobs == 0 {
                return Due(task: t, due: false, why: "Due after your first recorded job.")
            }
            return Due(task: t, due: !reasons.isEmpty, why: reasons.isEmpty ? "Done \(r.date == .distantPast ? "—" : r.date.formatted(date: .abbreviated, time: .omitted))" : reasons.joined(separator: ", "))
        }
    }
}
