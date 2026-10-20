import Foundation
import simd

/// What limits machining a part from one side, as measured by the engine.
public struct PartAnalysis: Sendable, Equatable {
    public var minCornerRadius: Double?
    public var minConcaveRadius: Double?
    public var undercutArea: Double
    public var thinnestWall: Double?
    public var depth: Double
    /// Where the part's cross-section is largest (work Z): the split for two-sided jobs.
    public var partingZ: Double?
    /// Area of faces 2.5D operations can't finish (domes, fillets, freeform), mm².
    public var freeformArea: Double = 0
    /// Flat floors (square to the tool), walls (along it) and steep (> 45°) freeform area, mm².
    public var flatArea: Double = 0
    public var wallArea: Double = 0
    public var steepArea: Double = 0
    /// Part volume (mm³) and how round its silhouette is (1 = a disc).
    public var volume: Double = 0
    public var circularity: Double = 0
    /// Undercut faces (work frame), xyz per vertex, 3 vertices per triangle.
    public var undercutTriangles: [Float]

    public init(minCornerRadius: Double? = nil, minConcaveRadius: Double? = nil, undercutArea: Double = 0,
                thinnestWall: Double? = nil, depth: Double = 0, partingZ: Double? = nil, undercutTriangles: [Float] = [],
                freeformArea: Double = 0, flatArea: Double = 0, wallArea: Double = 0, steepArea: Double = 0,
                volume: Double = 0, circularity: Double = 0) {
        self.partingZ = partingZ
        self.freeformArea = freeformArea
        self.flatArea = flatArea
        self.wallArea = wallArea
        self.steepArea = steepArea
        self.volume = volume
        self.circularity = circularity
        self.minCornerRadius = minCornerRadius
        self.minConcaveRadius = minConcaveRadius
        self.undercutArea = undercutArea
        self.thinnestWall = thinnestWall
        self.depth = depth
        self.undercutTriangles = undercutTriangles
    }
}

/// Turns the analysis into plain-language findings with a way forward for each.
public enum Feasibility {
    /// Common end mill sizes (mm), for "buy one of these" suggestions.
    static let standardSizes: [Double] = [0.5, 0.8, 1.0, 1.5875, 2.0, 2.38, 3.0, 3.175, 4.0, 4.7625, 6.0, 6.35, 8.0]

    public static func assess(_ a: PartAnalysis, inventory: Inventory, partSize: SIMD3<Double>? = nil,
                              stockSize: SIMD3<Double>? = nil, machine: MachineProfile = .cr1) -> [Issue] {
        var out: [Issue] = []
        let tools = OperationPlanner.usableTools(inventory)
        let flats = tools.filter { [.flatEndMill, .bullNoseEndMill].contains($0.kind) }
        let balls = tools.filter { $0.kind == .ballEndMill }

        if let r = a.minCornerRadius {
            let maxD = 2 * r
            if let t = flats.filter({ $0.diameter <= maxD * 0.98 }).max(by: { $0.diameter < $1.diameter }) {
                out.append(Issue(.info, "Tightest inside corner R \(Length.mm(r)) mm: the \(t.name) (⌀\(Length.mm(t.diameter))) can finish every corner."))
            } else if let buy = standardSizes.filter({ $0 <= maxD * 0.98 }).max() {
                out.append(Issue(.warning, "Tightest inside corner R \(Length.mm(r)) mm needs an end mill of ⌀\(Length.describe(buy)) or smaller. None in your inventory: buy one, or accept rounder corners."))
            } else {
                out.append(Issue(.error, "Inside corner R \(Length.mm(r)) mm is too tight for any end mill. Increase the radius in Rhino."))
            }
        }
        if let r = a.minConcaveRadius {
            if let t = balls.filter({ $0.diameter / 2 <= r * 0.98 }).max(by: { $0.diameter < $1.diameter }) {
                out.append(Issue(.info, "Tightest concave curve R \(Length.mm(r)) mm: the \(t.name) fits it for 3D finishing."))
            } else {
                let buy = standardSizes.filter { $0 / 2 <= r * 0.98 }.max()
                out.append(Issue(.warning, "Concave curves down to R \(Length.mm(r)) mm need a ball mill of ⌀\(buy.map { Length.describe($0) } ?? "under 1 mm") or smaller for a clean 3D finish."))
            }
        }
        if a.undercutArea > 0.01 {
            out.append(Issue(.warning, "\(Length.mm(a.undercutArea)) mm² of the part faces away from the spindle (shown in red). It needs a second setup from the back. The setup planner flips the part for it."))
        }
        if let w = a.thinnestWall {
            out.append(Issue(w < 0.5 ? .warning : .info, "Thinnest wall about \(Length.mm(w)) mm. Thin walls flex while cut: they're finished last with light passes."))
        }
        if a.depth > 0 {
            let reach = flats.map(\.fluteLength).max() ?? 0
            if a.depth > reach {
                out.append(Issue(.warning, "The part is \(Length.mm(a.depth)) mm deep but your longest flutes are \(Length.mm(reach)) mm: deep walls will be cut from both sides or need a longer tool."))
            }
        }
        if let p = partSize, let s = stockSize {
            let fit = min((s.x - 2) / p.x, (s.y - 2) / p.y, (s.z - 0.5) / p.z)
            if fit < 1 {
                out.append(Issue(.error, "The part doesn't fit this stock. Scaled to \(Int((fit * 100).rounded(.down)))% it would, or choose bigger stock."))
            }
            let env = machine.physicalEnvelope
            let mfit = min(env.x / p.x, env.y / p.y, env.z / p.z)
            if mfit < 1 {
                out.append(Issue(.error, "The part is larger than the CR-1 can reach as oriented. Scaled to \(Int((mfit * 100).rounded(.down)))% it would fit, or turn it."))
            }
        }
        return out
    }

    /// Stock in the inventory that the part fits (any orientation, 2 mm margin around, 0.5 mm on top).
    public static func fittingStock(partSize p: SIMD3<Double>, inventory: Inventory, materialFamily: Material.Family? = nil) -> [StockItem] {
        let need = [p.x + 2, p.y + 2, p.z + 0.5].sorted()
        return inventory.stock.filter { s in
            guard s.quantity > 0 else { return false }
            if let f = materialFamily, s.material?.family != f { return false }
            let have = [s.envelope.x, s.envelope.y, s.envelope.z].sorted()
            return zip(need, have).allSatisfy { $0 <= $1 }
        }
    }
}

extension EngineClient {
    public func analyse(partID: String, transform: simd_double4x4) throws -> PartAnalysis {
        let r = try call("analyse", ["part_id": partID, "transform": Self.rowMajor(transform)])
        guard r.result["exact"] as? Bool == true else { return PartAnalysis() }
        return PartAnalysis(minCornerRadius: r.result["min_corner_radius"] as? Double,
                            minConcaveRadius: r.result["min_concave_radius"] as? Double,
                            undercutArea: r.result["undercut_area"] as? Double ?? 0,
                            thinnestWall: r.result["thinnest_wall"] as? Double,
                            depth: r.result["depth"] as? Double ?? 0,
                            partingZ: r.result["parting_z"] as? Double,
                            undercutTriangles: r.blobs.first?.littleEndianArray(of: Float.self) ?? [],
                            freeformArea: r.result["freeform_area"] as? Double ?? 0,
                            flatArea: r.result["flat_area"] as? Double ?? 0, wallArea: r.result["wall_area"] as? Double ?? 0,
                            steepArea: r.result["steep_area"] as? Double ?? 0, volume: r.result["volume"] as? Double ?? 0,
                            circularity: r.result["circularity"] as? Double ?? 0)
    }
}
