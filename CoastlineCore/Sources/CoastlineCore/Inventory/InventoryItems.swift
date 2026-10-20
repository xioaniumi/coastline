import Foundation

/// A piece of raw stock. Dimensions are mm.
public struct StockItem: Identifiable, Hashable, Sendable, Codable {
    public enum Shape: String, CaseIterable, Sendable, Codable {
        case block, roundBar, plate, printedBlank
        public var title: String {
            switch self {
            case .block: "Block"
            case .roundBar: "Round bar"
            case .plate: "Plate / sheet"
            case .printedBlank: "Printed blank"
            }
        }
        public var symbol: String {
            switch self {
            case .block: "cube"
            case .roundBar: "cylinder"
            case .plate: "rectangle"
            case .printedBlank: "printer.dotmatrix"
            }
        }
    }

    /// How true the faces are. Sawn stock needs a facing pass before it can be a datum.
    public enum Finish: String, CaseIterable, Sendable, Codable {
        case sawn, milled, precisionGround, asPrinted
        public var title: String {
            switch self {
            case .sawn: "Sawn / rough"
            case .milled: "Milled square"
            case .precisionGround: "Precision ground"
            case .asPrinted: "As printed"
            }
        }
    }

    public var id: UUID
    public var materialID: String
    public var shape: Shape
    /// Block/plate: x × y × z. Round bar: x = diameter, y = length (z unused).
    public var sizeX: Double
    public var sizeY: Double
    public var sizeZ: Double
    public var quantity: Int
    public var finish: Finish
    public var unitCost: Double?
    public var supplier: String
    /// Where it is in the workshop ("Drawer 2").
    public var location: String
    public var notes: String
    /// Offcut from an earlier job (the job journal creates these automatically).
    public var isRemnant: Bool
    /// For printed blanks: the STEP the blank was printed from.
    public var modelPath: String?
    /// Extruded or drawn bar: which size runs along the extrusion (0 = X, 1 = Y, 2 = Z). Faces
    /// parallel to it come out straight and square from the mill; only the sawn ends across it
    /// need facing. nil: not known (Coastline assumes the longest side).
    public var extrusionAxis: Int?

    /// The size along the extrusion (the longest side when not known).
    public var extrusionLength: Double {
        let e = [envelope.x, envelope.y, envelope.z]
        return extrusionAxis.map { e[min(max($0, 0), 2)] } ?? e.max()!
    }

    public init(id: UUID = UUID(), materialID: String, shape: Shape = .block, sizeX: Double, sizeY: Double,
                sizeZ: Double, quantity: Int = 1, finish: Finish = .sawn, unitCost: Double? = nil,
                supplier: String = "", location: String = "", notes: String = "", isRemnant: Bool = false,
                modelPath: String? = nil) {
        self.id = id
        self.materialID = materialID
        self.shape = shape
        self.sizeX = sizeX
        self.sizeY = sizeY
        self.sizeZ = sizeZ
        self.quantity = quantity
        self.finish = finish
        self.unitCost = unitCost
        self.supplier = supplier
        self.location = location
        self.notes = notes
        self.isRemnant = isRemnant
        self.modelPath = modelPath
    }

    public var material: Material? { MaterialLibrary.material(id: materialID) }

    /// Bounding box of the stock, mm.
    public var envelope: Vec3 {
        shape == .roundBar ? Vec3(sizeX, sizeY, sizeX) : Vec3(sizeX, sizeY, sizeZ)
    }

    public var volume: Double {  // mm³
        shape == .roundBar ? Double.pi * sizeX * sizeX / 4 * sizeY : sizeX * sizeY * sizeZ
    }

    /// Weight of one piece, grams.
    public var weight: Double? { material.map { volume / 1000 * $0.density } }

    public var sizeDescription: String {
        shape == .roundBar
            ? "⌀\(Length.mm(sizeX)) × \(Length.mm(sizeY)) mm"
            : "\(Length.mm(sizeX)) × \(Length.mm(sizeY)) × \(Length.mm(sizeZ)) mm"
    }
}

/// Workholding: clamps, vises, plates and printed nests.
public struct Fixture: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, CaseIterable, Sendable, Codable {
        case universalClamp, vise, jigPlate, tombstone, squaringBoss, softJaws, printedNest, fixturePlate, tSlotNuts, cClamp,
             squaringStop, riser, other
        public var title: String {
            switch self {
            case .universalClamp: "Universal clamp"
            case .vise: "Vise"
            case .jigPlate: "Jig plate"
            case .tombstone: "Tombstone"
            case .squaringBoss: "Squaring boss"
            case .softJaws: "Soft jaws"
            case .printedNest: "Printed nest"
            case .fixturePlate: "Fixture plate"
            case .tSlotNuts: "T-slot nuts"
            case .cClamp: "C-clamp"
            case .squaringStop: "Squaring stop"
            case .riser: "Riser plate"
            case .other: "Other"
            }
        }
        public var symbol: String {
            switch self {
            case .universalClamp: "rectangle.compress.vertical"
            case .vise: "arrow.right.and.line.vertical.and.arrow.left"
            case .jigPlate, .fixturePlate: "square.grid.3x3"
            case .tombstone: "rectangle.portrait"
            case .squaringBoss: "l.square"
            case .softJaws: "square.split.2x1"
            case .printedNest: "printer.dotmatrix"
            case .tSlotNuts: "t.square"
            case .cClamp: "c.square"
            case .squaringStop: "rectangle.portrait.and.arrow.right"
            case .riser: "square.stack.3d.down.forward"
            case .other: "wrench.adjustable"
            }
        }
    }

    public enum ClampAxis: String, CaseIterable, Sendable, Codable {
        case x, y, none
        public var title: String { self == .none ? "—" : rawValue.uppercased() }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var quantity: Int
    /// The machine axis it clamps along (universal clamp: X, vise: Y). [MAN §4.4]
    public var clampAxis: ClampAxis
    /// Smallest and largest stock it grips along the clamp axis, mm.
    public var gripRange: ClosedRange<Double>?
    /// How far it raises the stock above the table, mm.
    public var height: Double
    /// Electrically isolated from the bed, so conductive probing works. [MAN §4.4]
    public var isolated: Bool
    /// STEP/3MF/STL for the 3D view and collision checks (relative to `resources/` or absolute).
    public var modelPath: String?
    public var notes: String

    public init(id: UUID = UUID(), name: String, kind: Kind, quantity: Int = 1, clampAxis: ClampAxis = .none,
                gripRange: ClosedRange<Double>? = nil, height: Double = 0, isolated: Bool = false,
                modelPath: String? = nil, notes: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.quantity = quantity
        self.clampAxis = clampAxis
        self.gripRange = gripRange
        self.height = height
        self.isolated = isolated
        self.modelPath = modelPath
        self.notes = notes
    }
}

/// Measuring equipment. Guided measuring steps only ask for what you own.
public struct MeasuringTool: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, CaseIterable, Sendable, Codable {
        case caliper, micrometer, depthMicrometer, heightGauge, dialIndicator, testIndicator,
             edgeFinder, touchProbe, gaugePins, gaugeBlocks, radiusGauge, threadGauge, feelerGauge, loupe, surfacePlate
        public var title: String {
            switch self {
            case .caliper: "Caliper"
            case .micrometer: "Outside micrometer"
            case .depthMicrometer: "Depth micrometer"
            case .heightGauge: "Height gauge"
            case .dialIndicator: "Dial indicator"
            case .testIndicator: "Test indicator"
            case .edgeFinder: "Edge finder"
            case .touchProbe: "Touch probe / touch plate"
            case .gaugePins: "Gauge pins"
            case .gaugeBlocks: "Gauge blocks"
            case .radiusGauge: "Radius gauge"
            case .threadGauge: "Thread gauge"
            case .feelerGauge: "Feeler gauge"
            case .loupe: "Loupe"
            case .surfacePlate: "Surface plate"
            }
        }
        public var symbol: String {
            switch self {
            case .caliper, .micrometer, .depthMicrometer, .heightGauge: "ruler"
            case .dialIndicator, .testIndicator: "gauge.with.dots.needle.33percent"
            case .edgeFinder, .touchProbe: "scope"
            case .gaugePins, .gaugeBlocks, .feelerGauge: "square.stack"
            case .radiusGauge, .threadGauge: "circle.dashed"
            case .loupe: "magnifyingglass"
            case .surfacePlate: "square"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Measuring range, mm (0…150 for a 6" caliper).
    public var range: ClosedRange<Double>?
    /// Smallest step it reads, mm.
    public var resolution: Double?
    /// How far it can be off, ± mm.
    public var accuracy: Double?
    public var quantity: Int
    public var notes: String

    public init(id: UUID = UUID(), name: String, kind: Kind, range: ClosedRange<Double>? = nil,
                resolution: Double? = nil, accuracy: Double? = nil, quantity: Int = 1, notes: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.range = range
        self.resolution = resolution
        self.accuracy = accuracy
        self.quantity = quantity
        self.notes = notes
    }
}

/// Collets, lubricants, adhesives, dowel pins and other supplies.
public struct Accessory: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, CaseIterable, Sendable, Codable {
        case collet, lubricant, adhesive, dowelPin, tape, deburring, polishing, other
        public var title: String {
            switch self {
            case .collet: "Collet"
            case .lubricant: "Lubricant"
            case .adhesive: "Adhesive"
            case .dowelPin: "Dowel pins"
            case .tape: "Tape"
            case .deburring: "Deburring"
            case .polishing: "Polishing"
            case .other: "Other"
            }
        }
        public var symbol: String {
            switch self {
            case .collet: "circle.circle"
            case .lubricant: "drop"
            case .adhesive: "bandage"
            case .dowelPin: "pin"
            case .tape: "rectangle.dashed"
            case .deburring: "scissors"
            case .polishing: "sparkles"
            case .other: "shippingbox"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Collets: bore in mm (6.35 for 1/4"). Dowel pins: diameter.
    public var size: Double?
    public var quantity: Int
    public var notes: String

    public init(id: UUID = UUID(), name: String, kind: Kind, size: Double? = nil, quantity: Int = 1, notes: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.size = size
        self.quantity = quantity
        self.notes = notes
    }
}

/// Length formatting. Coastline works in mm but tools are often sold in inches, so common
/// fractions are shown too.
public enum Length {
    /// The locale numbers are shown in. Defaults to the user's (e.g. a decimal comma in much of Europe), so
    /// labels match the editable fields. Tests pin it to `en_US_POSIX`.
    nonisolated(unsafe) public static var locale = Locale.autoupdatingCurrent

    /// "6.35", "3", "0.8": up to 3 decimals, trailing zeros removed, in `locale`.
    public static func mm(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0 ... 3)).grouping(.never).locale(locale))
    }

    /// The nearest common inch fraction (up to 1/64") within 0.01 mm, e.g. "1/4\"".
    public static func inchFraction(_ v: Double) -> String? {
        let inches = v / 25.4
        for denominator in [1, 2, 4, 8, 16, 32, 64] {
            let numerator = (inches * Double(denominator)).rounded()
            guard numerator > 0, abs(numerator / Double(denominator) * 25.4 - v) < 0.01 else { continue }
            let whole = Int(numerator) / denominator, rest = Int(numerator) % denominator
            if rest == 0 { return "\(whole)\"" }
            return whole > 0 ? "\(whole) \(rest)/\(denominator)\"" : "\(rest)/\(denominator)\""
        }
        return nil
    }

    /// "6.35 mm (1/4\")" or "6 mm".
    public static func describe(_ v: Double) -> String {
        if let f = inchFraction(v) { return "\(mm(v)) mm (\(f))" }
        return "\(mm(v)) mm"
    }
}
