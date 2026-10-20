import Foundation

public enum LengthUnit: Sendable, Equatable {
    case millimeters, inches
}

/// X/Y/Z in millimetres. (The original's `Measurement` stored a unit; everything is normalised to mm here.)
public struct Point3: Equatable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Point3()

    public static func + (a: Point3, b: Point3) -> Point3 { Point3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    public static func - (a: Point3, b: Point3) -> Point3 { Point3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }

    public subscript(axis: Axis) -> Double {
        get {
            switch axis {
            case .x: x
            case .y: y
            case .z: z
            }
        }
        set {
            switch axis {
            case .x: x = newValue
            case .y: y = newValue
            case .z: z = newValue
            }
        }
    }

    public var description: String { "(\(x), \(y), \(z))" }
}

public enum Axis: String, CaseIterable, Sendable {
    case x = "X", y = "Y", z = "Z"

    /// `GetAxisValue(point, char)`: accepts upper or lower case.
    init?(letter: Character) {
        switch letter {
        case "x", "X": self = .x
        case "y", "Y": self = .y
        case "z", "Z": self = .z
        default: return nil
        }
    }
}

/// A parsed `?` status report. Port of `RealTimeStatus` (`src/Mill/GRBL/Status/*`).
///
/// The CR-1 firmware (grblCR 1.1g) uses a compact format, e.g.
/// `<Idle|M:-86.000,-0.500,-0.500|B:15,127|L:0|0000|W:0.000,0.000,0.000>`.
public struct RealTimeStatus: Equatable, Sendable {
    public var raw: String
    /// `Idle`, `Run`, `Hold`, `Jog`, `Home`, `Alarm`, `Check`, `Sleep`.
    public var state: String
    public var subState: Int
    /// Machine position in mm.
    public var machinePosition: Point3
    /// Work coordinate offset (WCO) in mm, if known.
    public var workOffset: Point3?
    /// Which WCS the offset belongs to (54…59).
    public var wcs: Int
    public var freePlannerBlocks: Int
    public var freeRxBytes: Int
    public var lineNumber: UInt32
    public var probeTripped = false
    public var limitX = false
    public var limitY = false
    public var limitZ = false
    public var feedRate: UInt32?
    public var spindleSpeed: UInt32?
    /// Parser state at the time of the report: 20/21 and 90/91.
    public var parserUnits: Int
    public var distanceMode: Int

    /// Work position = machine position − work offset.
    public var workPosition: Point3? { workOffset.map { machinePosition - $0 } }
    public var anyLimitTripped: Bool { probeTripped || limitX || limitY || limitZ }

    struct ParseError: Error {}

    /// `RealTimeStatus::Parse` (GRBL 1.1 format).
    static func parse(_ input: String, wcs: Int, reportUnit: LengthUnit, parserUnits: Int, distanceMode: Int) throws -> RealTimeStatus {
        guard input.count >= 2, input.first == "<", input.last == ">" else { throw ParseError() }
        let fields = input.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4 else { throw ParseError() }

        let (stateName, subStateText) = splitOnce(fields[0], ":")
        let subState = subStateText.isEmpty ? -1 : try parseInt(subStateText)
        let (isMachine, coordinates) = try parsePosition(fields[1], unit: reportUnit)
        let (planner, rx) = try parseBuffer(fields[2])

        var lineNumber: UInt32 = 0
        let limits: String
        if fields[3].hasPrefix("L") {
            let text = splitOnce(fields[3], ":").1
            lineNumber = text.isEmpty ? 0 : UInt32(try parseInt(text))
            guard fields.count > 4 else { throw ParseError() }
            limits = fields[4]
        } else {
            limits = fields[3]
        }
        guard limits.count == 4 else { throw ParseError() }
        let pins = Array(limits)

        var status = RealTimeStatus(
            raw: input, state: stateName, subState: subState,
            machinePosition: coordinates, workOffset: nil, wcs: 54,
            freePlannerBlocks: planner, freeRxBytes: rx, lineNumber: lineNumber,
            probeTripped: pins[0] == "P", limitX: pins[1] == "X", limitY: pins[2] == "Y", limitZ: pins[3] == "Z",
            parserUnits: parserUnits, distanceMode: distanceMode)

        // The original starts at index 5 regardless of whether a line-number field was present.
        for field in fields.dropFirst(5) {
            let (key, value) = splitOnce(field, ":")
            if key == "W" {
                status.wcs = wcs
                status.workOffset = try parseCoordinates(value, unit: reportUnit)
            } else if key == "FS" {
                let (feed, speed) = splitOnce(value, ",")
                status.feedRate = UInt32(try parseInt(feed))
                status.spindleSpeed = UInt32(try parseInt(speed))
            } else if key == "F" {
                status.feedRate = UInt32(try parseInt(value))
                status.spindleSpeed = 0
            }
        }

        if !isMachine {
            // Position was reported as work position; convert when the offset is known.
            if let offset = status.workOffset {
                status.machinePosition = coordinates + offset
            }
        }
        return status
    }

    /// `RealTimeStatus::ParseV0` (GRBL 1.0: `<Idle,MPos:0,0,0,WPos:0,0,0>`).
    static func parseV0(_ input: String, wcs: Int, reportUnit: LengthUnit, parserUnits: Int, distanceMode: Int) throws -> RealTimeStatus {
        guard input.count >= 2, input.first == "<", input.last == ">" else { throw ParseError() }
        let cleaned = String(input.dropFirst().dropLast())
        let (statusPart, coords) = splitOnce(cleaned, ",")
        let (stateName, subStateText) = splitOnce(statusPart, ":")
        let subState = subStateText.isEmpty ? -1 : try parseInt(subStateText)
        let parts = coords.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 6 else { throw ParseError() }
        let (_, machine) = try parsePosition(parts[0...2].joined(separator: ","), unit: reportUnit)
        let workText = splitOnce(parts[3...5].joined(separator: ","), ":").1
        let work = try parseCoordinates(workText, unit: reportUnit)
        return RealTimeStatus(
            raw: input, state: stateName, subState: subState,
            machinePosition: machine, workOffset: machine - work, wcs: wcs,
            freePlannerBlocks: 0, freeRxBytes: 0, lineNumber: 0,
            parserUnits: parserUnits, distanceMode: distanceMode)
    }

    // MARK: Helpers

    static func splitOnce(_ s: String, _ separator: Character) -> (String, String) {
        guard let i = s.firstIndex(of: separator) else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    static func parseInt(_ s: String) throws -> Int {
        guard let v = ManifestParser.leadingInteger(s) else { throw ParseError() }
        return v
    }

    static func parsePosition(_ s: String, unit: LengthUnit) throws -> (isMachine: Bool, Point3) {
        let (kind, value) = splitOnce(s, ":")
        guard let first = kind.first, first == "M" || first == "W" else { throw ParseError() }
        return (first == "M", try parseCoordinates(value, unit: unit))
    }

    static func parseCoordinates(_ s: String, unit: LengthUnit) throws -> Point3 {
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 3, let x = Double(parts[0]), let y = Double(parts[1]), let z = Double(parts[2]) else {
            throw ParseError()
        }
        let scale = unit == .inches ? 25.4 : 1
        return Point3(x: x * scale, y: y * scale, z: z * scale)
    }

    static func parseBuffer(_ s: String) throws -> (Int, Int) {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "B" else { throw ParseError() }
        let values = parts[1].split(separator: ",", omittingEmptySubsequences: false)
        guard values.count == 2 else { throw ParseError() }
        return (try parseInt(String(values[0])), try parseInt(String(values[1])))
    }
}

/// Soft-limit travel ranges in machine coordinates (mm). Port of `SoftLimits`.
public struct SoftLimits: Equatable, Sendable {
    public var enabled: Bool
    public var travelX: Double
    public var travelY: Double
    public var travelZ: Double

    public func range(_ axis: Axis) -> ClosedRange<Double> {
        switch axis {
        case .x: (-(travelX - 0.5))...(-0.5)
        case .y: (-travelY)...(-0.5)
        case .z: (-travelZ)...(-0.5)
        }
    }
}

/// GRBL `$n=value` settings. Port of `MillSettings`.
public struct MillSettings: Equatable, Sendable {
    public private(set) var values: [Int: Double] = [:]

    public var isEmpty: Bool { values.isEmpty }

    mutating func update(_ setting: Int, _ value: Double) {
        values[setting] = value
    }

    /// `$13` report-in-inches.
    public var reportUnit: LengthUnit {
        if let v = values[13], Int(v) == 1 { return .inches }
        return .millimeters
    }

    /// `$20` soft limits enabled, `$130-132` max travel.
    public var softLimits: SoftLimits? {
        guard let x = values[130], let y = values[131], let z = values[132] else { return nil }
        return SoftLimits(enabled: Int(values[20] ?? 0) == 1, travelX: x, travelY: y, travelZ: z)
    }
}
