import Foundation

/// Logic behind the Manual Mode window. Ports of helpers in the original
/// `components/Modals/Shuttle/Operations.js` and `PositionPreset.js`.
public enum ManualMode {
    public enum Proximity: Sendable, Equatable { case none, yellow, red }

    /// `isOutOfBounds`: would this manual command move outside the travel envelope?
    /// Positions are machine coordinates in mm. Deviation: the original compared values in the
    /// display unit against mm limits; here inch commands (G20 mode) are converted first.
    public static func isOutOfBounds(_ command: String, grblVersion: String?, absoluteMode: Bool,
                                     inches: Bool, machinePosition: Point3) -> Bool {
        let limits: Point3
        if let grblVersion, !grblVersion.hasPrefix("1.1") {
            limits = Point3(x: -75, y: -180, z: -60.5)
        } else {
            limits = Point3(x: -86.5, y: -241.5, z: -78.5)
        }
        var absolute = absoluteMode
        let upper = command.uppercased()
        if upper.contains("G90") || upper.contains("G91"), Axis.allCases.contains(where: { axisValue($0, in: upper) != nil }) {
            absolute = upper.contains("G90")
        }
        let scale = inches || upper.contains("G20") ? 25.4 : 1
        for axis in Axis.allCases {
            var value = (axisValue(axis, in: upper) ?? 0) * scale
            if !absolute { value += machinePosition[axis] }
            if value > 0 || value < limits[axis] { return true }
        }
        return false
    }

    /// `X-12.5` → -12.5 (first occurrence of the axis letter followed by a number).
    static func axisValue(_ axis: Axis, in upper: String) -> Double? {
        let chars = Array(upper)
        for (i, c) in chars.enumerated() where c == Character(axis.rawValue) {
            let number = chars[(i + 1)...].prefix { $0.isNumber || $0 == "." || $0 == "-" }
            if let value = Double(String(number)), !number.isEmpty { return value }
        }
        return nil
    }

    /// `getPathColorClass`: red within the red threshold of a soft limit, yellow within the yellow one.
    /// Continuous jogging uses 2 mm / 10 mm; fixed jogging uses the step and 3× the step.
    public static func proximity(axis: Axis, towardMax: Bool, position: Point3, limits: SoftLimits,
                                 continuous: Bool, stepMillimeters: Double) -> Proximity {
        let range = limits.range(axis)
        let red = continuous ? 2 : stepMillimeters
        let yellow = continuous ? 10 : stepMillimeters * 3
        let value = position[axis]
        if towardMax {
            let limit = range.upperBound
            if value > limit || value >= limit - red { return .red }
            if value >= limit - yellow { return .yellow }
        } else {
            let limit = range.lowerBound
            if value < limit || value <= limit + red { return .red }
            if value <= limit + yellow { return .yellow }
        }
        return .none
    }

    /// `PositionPreset.handleClick`: home Z first, then move X/Y, then lower Z.
    public static func presetCommands(_ point: Point3, inches: Bool) -> [String] {
        let f = { (v: Double) -> String in
            inches ? String(format: "%.4f", v / 25.4) : String(format: "%.3f", v)
        }
        return ["$HZ", "G53 G0 X\(f(point.x)) Y\(f(point.y))", "G53 G0 Z\(f(point.z))"]
    }

    /// Valid fixed jog distance range (`isMaxDistanceValid`).
    public static func isValidStep(_ value: Double, inches: Bool) -> Bool {
        inches ? (0.0001...40).contains(value) : (0.0025...1000).contains(value)
    }
}

/// Manual-entry command history (15 entries, most recent last, no duplicates).
public struct CommandHistory: Sendable {
    public private(set) var entries: [String] = []
    private var cursor: Int?
    public static let capacity = 14

    public init() {}

    public mutating func add(_ command: String) {
        entries.removeAll { $0 == command }
        entries.append(command)
        if entries.count > Self.capacity { entries.removeFirst() }
        cursor = nil
    }

    /// Up arrow: older entry.
    public mutating func previous() -> String? {
        guard !entries.isEmpty else { return nil }
        let index = max(0, (cursor ?? entries.count) - 1)
        cursor = index
        return entries[index]
    }

    /// Down arrow: newer entry, or empty past the end.
    public mutating func next() -> String? {
        guard let current = cursor else { return nil }
        let index = current + 1
        if index >= entries.count {
            cursor = entries.count
            return ""
        }
        cursor = index
        return entries[index]
    }
}
