import Foundation

/// A material Coastline knows how to cut. Values are **starting points for a carbide tool on the
/// CR-1**, a light machine with a spindle limited to 8000 RPM. The feeds engine scales
/// them by tool diameter, flutes and engagement, and the job journal tunes them from
/// real results.
public struct Material: Identifiable, Hashable, Sendable, Codable {
    public enum Family: String, CaseIterable, Sendable, Codable {
        case aluminium, copperAlloy, steel, stainless, titanium, plastic, printedResin, wax

        public var title: String {
            switch self {
            case .aluminium: "Aluminium"
            case .copperAlloy: "Brass, Copper & Bronze"
            case .steel: "Steel"
            case .stainless: "Stainless Steel"
            case .titanium: "Titanium"
            case .plastic: "Engineering Plastics"
            case .printedResin: "Formlabs Printed"
            case .wax: "Wax"
            }
        }

        public var symbol: String {
            switch self {
            case .aluminium: "square.stack.3d.up"
            case .copperAlloy: "circle.hexagongrid"
            case .steel, .stainless: "shield.lefthalf.filled"
            case .titanium: "atom"
            case .plastic: "drop.halffull"
            case .printedResin: "printer.dotmatrix"
            case .wax: "flame"
            }
        }
    }

    /// How hard this material is on the CR-1. It decides how conservative the planner is.
    public enum Difficulty: Int, Comparable, CaseIterable, Sendable, Codable {
        case easy, moderate, careful, experimental

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .easy: "Easy"
            case .moderate: "Moderate"
            case .careful: "Careful mode"
            case .experimental: "Experimental"
            }
        }

        public var explanation: String {
            switch self {
            case .easy: "Cuts cleanly on the CR-1 with standard settings."
            case .moderate: "Needs sharp tools and the right lubricant, but is routine."
            case .careful: "Light radial engagement, low speed and strict load limits. Expect faster tool wear."
            case .experimental: "Possible on the CR-1, but at its limits. Make test cuts in scrap first."
            }
        }
    }

    public var id: String
    public var name: String
    public var family: Family
    /// Common designation, for example "6061-T6", "C360" or "Rigid 10K".
    public var grade: String
    public var difficulty: Difficulty
    /// g/cm³, used for stock weight and cost.
    public var density: Double
    /// Hardness as a readable string ("95 HB", "Shore D 85").
    public var hardness: String

    // MARK: Cutting data (carbide, starting points)

    /// Surface speed range, m/min. On the CR-1 small tools often hit the 8000 RPM cap first.
    public var surfaceSpeed: ClosedRange<Double>
    /// Feed per tooth relative to 6061 aluminium (1.0) at the same diameter. The aluminium
    /// anchor comes from Coast Runner's feeds & speeds master document.
    public var chipLoadFactor: Double
    /// Max radial engagement for adaptive roughing, as a fraction of tool diameter.
    public var adaptiveStepoverMax: Double
    /// Max axial depth for adaptive roughing, as a multiple of tool diameter (limited by flute length).
    public var adaptiveDepthMax: Double
    /// Max depth for a full-width slot, as a multiple of tool diameter.
    public var slotDepthMax: Double
    /// Specific cutting force kc1.1, N/mm². Used for spindle-power and deflection checks.
    public var specificCuttingForce: Double
    /// Relative tool-wear rate (6061 = 1). Feeds the tool-life model.
    public var toolWearFactor: Double

    // MARK: Guidance shown in the app and in guided steps

    public var lubricant: String
    public var chips: String
    public var tooling: String
    public var notes: String
    /// Is this material allowed in a first-time job without a confirmation?
    public var needsConfirmation: Bool { difficulty >= .careful }

    public init(id: String, name: String, family: Family, grade: String, difficulty: Difficulty, density: Double,
                hardness: String, surfaceSpeed: ClosedRange<Double>, chipLoadFactor: Double,
                adaptiveStepoverMax: Double, adaptiveDepthMax: Double, slotDepthMax: Double,
                specificCuttingForce: Double, toolWearFactor: Double,
                lubricant: String, chips: String, tooling: String, notes: String = "") {
        self.id = id
        self.name = name
        self.family = family
        self.grade = grade
        self.difficulty = difficulty
        self.density = density
        self.hardness = hardness
        self.surfaceSpeed = surfaceSpeed
        self.chipLoadFactor = chipLoadFactor
        self.adaptiveStepoverMax = adaptiveStepoverMax
        self.adaptiveDepthMax = adaptiveDepthMax
        self.slotDepthMax = slotDepthMax
        self.specificCuttingForce = specificCuttingForce
        self.toolWearFactor = toolWearFactor
        self.lubricant = lubricant
        self.chips = chips
        self.tooling = tooling
        self.notes = notes
    }

    /// RPM for a tool diameter (mm) at the middle of the surface-speed range, before the
    /// machine's spindle limits are applied.
    public func idealRPM(toolDiameter: Double) -> Double {
        let vc = (surfaceSpeed.lowerBound + surfaceSpeed.upperBound) / 2
        return vc * 1000 / (Double.pi * toolDiameter)
    }
}
