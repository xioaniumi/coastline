import Foundation

/// The quality ↔ time tuner: one finish setting and one pace setting drive every
/// operation, with the consequences (time, surface, tool wear, cost) shown before generating.
public struct Tuning: Codable, Equatable, Sendable {
    public enum Preset: String, CaseIterable, Codable, Sendable {
        case draft, standard, fine, mirror
        public var title: String {
            switch self {
            case .draft: "Draft"
            case .standard: "Standard"
            case .fine: "Fine"
            case .mirror: "Mirror"
            }
        }
        public var explanation: String {
            switch self {
            case .draft: "Prototype or wax: coarse cusps, brisk feeds. Fastest; expect to sand."
            case .standard: "Good machined finish, Coast Runner's recommended feeds."
            case .fine: "Jewellery finish ready for light polishing; slower, gentler on tools."
            case .mirror: "Tiny cusps and light feeds for a near-polished surface. Slowest."
            }
        }
    }

    /// Cusp height left by finishing passes, mm.
    public var cusp: Double
    /// Feed and engagement relative to the recommended values (0.7 gentle … 1.2 brisk).
    public var pace: Double
    /// How hard roughing runs (nil: chip-thinned). It never shows on the part.
    public var roughing: FeedsEngine.RoughingStyle?
    /// Two-sided parts: the side nobody sees (the inside, the back) gets 3× coarser 3D
    /// finishing. nil: both sides show.
    public var hiddenSide: Int?

    public var roughingStyle: FeedsEngine.RoughingStyle { roughing ?? .thinned }

    public init(cusp: Double = 0.008, pace: Double = 1.0, roughing: FeedsEngine.RoughingStyle? = nil, hiddenSide: Int? = nil) {
        self.cusp = cusp
        self.pace = pace
        self.roughing = roughing == .thinned ? nil : roughing
        self.hiddenSide = hiddenSide
    }

    /// How much coarser the hidden side's 3D finishing is.
    public static let hiddenCuspFactor = 3.0

    public static func preset(_ p: Preset) -> Tuning {
        switch p {
        case .draft: Tuning(cusp: 0.020, pace: 1.15, roughing: .deep)
        case .standard: Tuning(cusp: 0.008, pace: 1.0)
        case .fine: Tuning(cusp: 0.004, pace: 0.9)
        case .mirror: Tuning(cusp: 0.002, pace: 0.8, roughing: .table)
        }
    }

    /// The preset this matches, if any (the hidden side is a separate choice).
    public var preset: Preset? {
        Preset.allCases.first { var p = Tuning.preset($0); p.hiddenSide = hiddenSide; return p == self }
    }

    /// The same, with a preset's finish, pace and roughing (keeping the hidden side).
    public func with(_ p: Preset) -> Tuning { var t = Tuning.preset(p); t.hiddenSide = hiddenSide; return t }

    /// Roughness from the cusp: Ra ≈ h / 4 for ball-end cusps (µm).
    public var ra: Double { cusp * 1000 / 4 }

    /// Applies the finish to every 3D finishing operation and the pace to every operation.
    public func apply(to ops: [Operation]) -> [Operation] {
        ops.map { op in
            var o = op
            if o.kind.is3D { o.scallop = cusp }
            o.feedScale = pace
            o.roughing = roughing
            return o
        }
    }
}

/// Tool wear from cutting time (Taylor's tool-life equation): life falls steeply with speed,
/// so a brisk pace costs tools much faster than it saves time.
public enum ToolWear {
    /// Rated life of a carbide tool at the recommended speed, cutting minutes.
    public static func baseLife(_ material: Material) -> Double {
        switch material.family {
        case .aluminium: 900
        case .copperAlloy: 600
        case .plastic, .printedResin, .wax: 1500
        case .steel: 150
        case .stainless: 90
        case .titanium: 60
        }
    }

    public static func life(tool: Tool, material: Material, pace: Double) -> Double {
        var l = baseLife(material)
        if tool.toolMaterial == .hss { l *= 0.25 }
        if tool.diameter < 1.5 { l *= 0.5 }  // tiny tools wear (and break) sooner
        return l * pow(max(pace, 0.3), -4)  // Taylor, n ≈ 0.25
    }

    /// Fraction of the tool's life used by `minutes` of cutting.
    public static func fraction(tool: Tool, material: Material, minutes: Double, pace: Double) -> Double {
        minutes / life(tool: tool, material: material, pace: pace)
    }
}

/// What a part costs to make: machine time, tool wear, stock, and the hands-on setup time.
public struct CostModel: Codable, Equatable, Sendable {
    public var currency = Locale.current.currencySymbol ?? "$"
    /// Machine running cost per hour (power, wear, maintenance).
    public var machinePerHour = 4.0
    /// Your time per hour for setting up (0 for a hobby).
    public var labourPerHour = 0.0
    /// Hands-on minutes per setup (clamping, edge finding, tool changes).
    public var setupMinutes = 12.0
    /// Tool price when the inventory has none.
    public var defaultToolPrice = 25.0

    public init() {}

    /// Stock price per kilogram by material family (rough market prices).
    public static func pricePerKg(_ m: Material) -> Double {
        switch m.family {
        case .aluminium: 9
        case .copperAlloy: 14
        case .steel: 4
        case .stainless: 9
        case .titanium: 45
        case .plastic: 15
        case .printedResin: 150
        case .wax: 30
        }
    }

    public struct Breakdown: Sendable, Equatable {
        public var machine: Double
        public var tools: Double
        public var stock: Double
        public var labour: Double
        public var total: Double { machine + tools + stock + labour }
    }

    /// - Parameters: minutes: machining minutes; toolMinutes: cutting minutes per tool;
    ///   stockVolume: mm³; setups: how many times it's clamped.
    public func cost(minutes: Double, toolMinutes: [(Tool, Double)], material: Material, pace: Double,
                     stockVolume: Double, setups: Int) -> Breakdown {
        let tools = toolMinutes.reduce(0) { sum, tm in
            sum + ToolWear.fraction(tool: tm.0, material: material, minutes: tm.1, pace: pace) * (tm.0.unitCost ?? defaultToolPrice)
        }
        let kg = stockVolume / 1e6 * material.density
        return Breakdown(machine: minutes / 60 * machinePerHour, tools: tools, stock: kg * Self.pricePerKg(material),
                         labour: Double(setups) * setupMinutes / 60 * labourPerHour)
    }
}
