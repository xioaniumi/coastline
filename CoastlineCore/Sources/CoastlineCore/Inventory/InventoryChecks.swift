import Foundation

/// A problem or hint about an inventory item, shown in its inspector and used by the planner.
public struct Issue: Hashable, Sendable, Identifiable, Codable {
    public enum Severity: Int, Comparable, Sendable, Codable {
        case info, warning, error
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
    public var severity: Severity
    public var message: String
    public var id: String { "\(severity.rawValue)|\(message)" }
    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }
}

/// Checks inventory items against the machine and the rest of the inventory.
public enum InventoryChecks {
    /// How close a collet must match a shank, mm. ER collets close a little, but metric and
    /// inch sizes must not be mixed.
    static let colletTolerance = 0.05

    public static func check(_ tool: Tool, machine: MachineProfile = .cr1, inventory: Inventory) -> [Issue] {
        var issues: [Issue] = []
        if tool.shankDiameter > machine.maxShankDiameter + 1e-6 {
            issues.append(Issue(.error, "The \(Length.describe(tool.shankDiameter)) shank is too big for the \(machine.colletName) collet (max \(Length.mm(machine.maxShankDiameter)) mm)."))
        } else if !inventory.colletSizes.contains(where: { abs($0 - tool.shankDiameter) <= colletTolerance }) {
            issues.append(Issue(.warning, "You have no \(machine.colletName) collet for a \(Length.describe(tool.shankDiameter)) shank. Add one under Accessories, or buy one."))
        }
        if tool.overallLength > machine.maxToolLength + 1e-6 {
            issues.append(Issue(.error, "\(Length.mm(tool.overallLength)) mm long: tools over \(Length.mm(machine.maxToolLength)) mm (3\") can crash during homing. [MAN §4.2]"))
        }
        if tool.kind.cutsSideways && tool.stickout + 1e-6 < tool.fluteLength {
            issues.append(Issue(.warning, "Stick-out (\(Length.mm(tool.stickout)) mm) is shorter than the flutes (\(Length.mm(tool.fluteLength)) mm). The flutes would sit inside the collet."))
        }
        // Slenderness: the fluted length counts at the cutting diameter, the plain shank below
        // the nut at the shank diameter (a 1/8" tool at 1.125" stick-out is normal on the CR-1).
        let fluted = min(tool.fluteLength, tool.stickout)
        let ratio = fluted / max(tool.diameter, 0.01) + (tool.stickout - fluted) / max(tool.shankDiameter, 0.01)
        if tool.kind.cutsSideways && ratio > 10 {
            issues.append(Issue(.warning, "The tool is very slender (about \(String(format: "%.0f", ratio))× its diameter). Expect deflection and chatter; the planner will use very light cuts."))
        } else if tool.kind.cutsSideways && ratio > 7 {
            issues.append(Issue(.info, "The tool is fairly slender (about \(String(format: "%.1f", ratio))× its diameter). Shorten the stick-out if the job allows; it improves finish and tool life."))
        }
        if tool.overallLength - tool.stickout < 10 {
            issues.append(Issue(.warning, "Only \(Length.mm(tool.overallLength - tool.stickout)) mm of shank in the collet. Grip at least 10 mm."))
        }
        switch tool.condition {
        case .worn: issues.append(Issue(.warning, "Marked worn. Fine for roughing; don't use it for finishing passes."))
        case .broken: issues.append(Issue(.error, "Marked broken. The planner won't use it."))
        default: break
        }
        if tool.quantity <= 0 {
            issues.append(Issue(.info, "Quantity is 0, so the planner treats it as not owned. It will suggest buying it when it helps."))
        }
        return issues
    }

    public static func check(_ stock: StockItem, machine: MachineProfile = .cr1) -> [Issue] {
        var issues: [Issue] = []
        guard stock.sizeX > 0, stock.sizeY > 0, stock.shape == .roundBar || stock.sizeZ > 0 else {
            return [Issue(.error, "Enter all the dimensions.")]
        }
        if stock.material == nil {
            issues.append(Issue(.error, "Unknown material. Pick one from the library."))
        }
        let env = machine.physicalEnvelope
        let dims = [stock.envelope.x, stock.envelope.y, stock.envelope.z].sorted()
        let box = [env.x, env.y, env.z].sorted()
        if zip(dims, box).contains(where: { $0 > $1 }) {
            issues.append(Issue(.error, "Doesn't fit the CR-1 work envelope (\(Length.mm(env.x)) × \(Length.mm(env.y)) × \(Length.mm(env.z)) mm) in any orientation. Cut it down first."))
        } else {
            // Lying on its largest face, how much Z is left for the tool?
            let room = env.z - dims[0]
            if room < 30 {
                issues.append(Issue(.warning, "Lying flat it leaves only \(Length.mm(room)) mm of Z for the tool and collet nut. Use short tools, or a thinner piece."))
            }
        }
        if stock.finish == .sawn {
            issues.append(Issue(.info, "Sawn faces aren't flat or square. The plan will face a datum surface first."))
        }
        if let m = stock.material, m.difficulty >= .careful {
            issues.append(Issue(.info, "\(m.name): \(m.difficulty.title). \(m.difficulty.explanation)"))
        }
        return issues
    }
}
