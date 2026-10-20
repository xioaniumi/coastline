import Foundation
import simd

/// Holding tabs (bridges): small bars of uncut material that keep the part in the stock frame
/// when the last side cuts all the way through. The part ends up "floating" in the frame on the
/// tabs; a jeweller's saw or flush cutter frees it and a file cleans the stubs.
public struct HoldingTabs: Equatable, Sendable, Codable {
    public var count: Int
    /// Along the outline, mm.
    public var width: Double
    /// Along the tool axis, mm.
    public var height: Double
    /// How far each tab runs out from the part, mm: past the roughing channel into the uncut
    /// frame (nil: the engine's default). Set per side from its roughing tools.
    public var reach: Double?
    /// Where the frame stays at the tabs' height once side A is cut (side B's work frame):
    /// each tab then runs out until it's well into it, however wide side A's channel is there.
    public var frame: TabFrame?
    /// Circles no tab may cross (x, y, radius; side B's work frame): the windows side B opens
    /// over the reference bores would cut a tab in two.
    public var avoid: [SIMD3<Double>]?
    /// Where the tools can go all the way round a tab's end (work X, within the CR-1's travel):
    /// past it the moves are pulled back to the limit, straight through the tab.
    public var withinX: ClosedRange<Double>?
    /// One side cut through: the tabs are gaps the finishing contour lifts over (bridging its
    /// slot into the skin the roughing leaves above `skinTop`), not islands it goes round.
    public var lift: Bool?
    public var skinTop: Double?

    public init(count: Int = 4, width: Double = 2, height: Double = 0.8) {
        self.count = count
        self.width = width
        self.height = height
    }

    /// Rules of thumb: four tabs in two mirrored pairs hold a part square without rocking, six
    /// above ~120 mm (long parts sag and chatter between tabs too far apart); soft
    /// materials need wider, taller tabs to stay stiff, hard metals smaller ones that are
    /// quicker to saw.
    public static func suggested(material: Material?, partSize: SIMD3<Double>) -> HoldingTabs {
        let span = max(partSize.x, partSize.y)
        var t = HoldingTabs(count: span > 120 ? 6 : 4)
        switch material?.family {
        case .wax?, .plastic?, .printedResin?: t.width = 3; t.height = 1.2
        case .steel?, .stainless?, .titanium?: t.width = 1.5; t.height = 0.6
        default: break
        }
        return t
    }
}

/// A grid over the stock (side B's work frame): which cells are frame that stays at the tabs'
/// height once the other side is cut (material connected to the stock's edge).
public struct TabFrame: Equatable, Sendable, Codable, CustomStringConvertible {
    public var origin: SIMD2<Double>
    public var cell: Double
    public var cols: Int, rows: Int
    /// Row-major, one bit a cell, most significant first (numpy's packbits), base64.
    public var bits: String

    public init(origin: SIMD2<Double>, cell: Double, cols: Int, rows: Int, frame: [Bool]) {
        self.origin = origin
        self.cell = cell
        self.cols = cols
        self.rows = rows
        var bytes = [UInt8](repeating: 0, count: (frame.count + 7) / 8)
        for (i, f) in frame.enumerated() where f { bytes[i >> 3] |= 0x80 >> UInt8(i & 7) }
        bits = Data(bytes).base64EncodedString()
    }

    public func isFrame(_ p: SIMD2<Double>) -> Bool {
        let c = Int(((p.x - origin.x) / cell).rounded()), r = Int(((p.y - origin.y) / cell).rounded())
        guard (0..<cols).contains(c), (0..<rows).contains(r), let d = Data(base64Encoded: bits) else { return false }
        let i = r * cols + c
        return d[d.startIndex + (i >> 3)] & (0x80 >> UInt8(i & 7)) != 0
    }

    /// Short, for cache keys: the grid and a hash of the bits.
    public var description: String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in bits.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "TabFrame(\(origin.x),\(origin.y),\(cell),\(cols)x\(rows),\(String(h, radix: 16)))"
    }
}

/// A tab the engine placed (work frame of the side that cuts through).
public struct PlacedTab: Sendable, Equatable, Codable {
    public var centre: SIMD2<Double>
    /// Outward from the part.
    public var normal: SIMD2<Double>
    /// The kept rectangle, 4 corners.
    public var corners: [SIMD2<Double>]
}
