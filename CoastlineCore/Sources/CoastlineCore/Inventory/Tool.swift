import Foundation

/// A cutting tool in the inventory. All lengths are mm.
public struct Tool: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, CaseIterable, Sendable, Codable {
        case flatEndMill, ballEndMill, bullNoseEndMill, chamferMill, engraver, drill, spotDrill, threadMill, faceMill

        public var title: String {
            switch self {
            case .flatEndMill: "Flat end mill"
            case .ballEndMill: "Ball end mill"
            case .bullNoseEndMill: "Bull nose end mill"
            case .chamferMill: "Chamfer mill"
            case .engraver: "Engraver (V-bit)"
            case .drill: "Drill"
            case .spotDrill: "Spot drill"
            case .threadMill: "Thread mill"
            case .faceMill: "Face mill"
            }
        }

        public var symbol: String {
            switch self {
            case .flatEndMill, .bullNoseEndMill, .faceMill: "rectangle.portrait.bottomhalf.filled"
            case .ballEndMill: "capsule.portrait.bottomhalf.filled"
            case .chamferMill, .engraver, .spotDrill: "triangle"
            case .drill: "arrowtriangle.down.fill"
            case .threadMill: "screwdriver"
            }
        }

        /// Does the tool cut sideways (so it can profile and pocket)?
        public var cutsSideways: Bool { ![.drill, .spotDrill].contains(self) }
    }

    public enum ToolMaterial: String, CaseIterable, Sendable, Codable {
        case carbide, hss, cobalt
        public var title: String { self == .hss ? "HSS" : rawValue.capitalized }
    }

    public enum Coating: String, CaseIterable, Sendable, Codable {
        case none, tiN, tiAlN, alTiN, alCrN, zrN, dlc, diamond
        public var title: String {
            switch self {
            case .none: "Uncoated"
            case .tiN: "TiN"
            case .tiAlN: "TiAlN"
            case .alTiN: "AlTiN"
            case .alCrN: "AlCrN"
            case .zrN: "ZrN"
            case .dlc: "DLC"
            case .diamond: "Diamond"
            }
        }
    }

    public enum Condition: String, CaseIterable, Sendable, Codable {
        case new, good, worn, broken
        public var title: String { rawValue.capitalized }
    }

    /// A cutting-data preset that came with the tool (for example from a Fusion library).
    /// Kept for reference; the feeds engine computes its own values.
    public struct Preset: Hashable, Sendable, Codable {
        public var name: String
        public var rpm: Double
        public var feed: Double        // mm/min
        public var plungeFeed: Double  // mm/min
        public var rampFeed: Double    // mm/min
        public var stepdown: Double?   // mm
        public var stepover: Double?   // mm
        public init(name: String, rpm: Double, feed: Double, plungeFeed: Double, rampFeed: Double,
                    stepdown: Double? = nil, stepover: Double? = nil) {
            self.name = name
            self.rpm = rpm
            self.feed = feed
            self.plungeFeed = plungeFeed
            self.rampFeed = rampFeed
            self.stepdown = stepdown
            self.stepover = stepover
        }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var vendor: String
    public var partNumber: String
    public var productLink: String

    // MARK: Geometry (mm)

    public var diameter: Double
    public var shankDiameter: Double
    public var flutes: Int
    public var fluteLength: Double
    /// Length below the collet nut (Fusion "LB"). The guided steps tell you to set this.
    public var stickout: Double
    public var overallLength: Double
    /// Bull nose corner radius. Ball = diameter / 2, flat = 0.
    public var cornerRadius: Double
    /// Half-angle of chamfer mills and engravers (45° for a 90° chamfer mill), or the point
    /// angle of drills (118°, 90° spot drill).
    public var angle: Double?
    public var tipDiameter: Double
    /// Thread mills: the pitch their single-form profile is ground for, mm (nil: any, or not a
    /// thread mill).
    public var threadPitch: Double? = nil

    public var toolMaterial: ToolMaterial
    public var coating: Coating
    /// The materials the vendor recommends it for (free text, e.g. "Aluminium, brass, copper").
    public var intendedFor: String

    // MARK: Ownership

    public var quantity: Int
    public var condition: Condition
    /// Price per tool, in the user's currency.
    public var unitCost: Double?
    public var notes: String
    public var presets: [Preset]
    /// Where it came from, e.g. "Fusion library CR-tools-for-Aluminum.tools, T2".
    public var source: String

    // MARK: Usage (filled from the job journal)

    public var cuttingMinutes: Double
    public var cuttingDistance: Double  // mm

    public init(id: UUID = UUID(), name: String, kind: Kind, vendor: String = "", partNumber: String = "",
                productLink: String = "", diameter: Double, shankDiameter: Double, flutes: Int,
                fluteLength: Double, stickout: Double, overallLength: Double, cornerRadius: Double = 0,
                angle: Double? = nil, tipDiameter: Double = 0, toolMaterial: ToolMaterial = .carbide,
                coating: Coating = .none, intendedFor: String = "", quantity: Int = 1,
                condition: Condition = .new, unitCost: Double? = nil, notes: String = "",
                presets: [Preset] = [], source: String = "", cuttingMinutes: Double = 0, cuttingDistance: Double = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.vendor = vendor
        self.partNumber = partNumber
        self.productLink = productLink
        self.diameter = diameter
        self.shankDiameter = shankDiameter
        self.flutes = flutes
        self.fluteLength = fluteLength
        self.stickout = stickout
        self.overallLength = overallLength
        self.cornerRadius = kind == .ballEndMill ? diameter / 2 : cornerRadius
        self.angle = angle
        self.tipDiameter = tipDiameter
        self.toolMaterial = toolMaterial
        self.coating = coating
        self.intendedFor = intendedFor
        self.quantity = quantity
        self.condition = condition
        self.unitCost = unitCost
        self.notes = notes
        self.presets = presets
        self.source = source
        self.cuttingMinutes = cuttingMinutes
        self.cuttingDistance = cuttingDistance
    }

    /// "1/8\" ball · 3 fl" style summary for lists.
    public var summary: String {
        "\(Length.describe(diameter)) \(kind.title.lowercased()) · \(flutes) fl"
    }
}
