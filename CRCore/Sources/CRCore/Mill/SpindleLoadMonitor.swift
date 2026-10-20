import Foundation

/// The spindle-load ("RPM divergence") indicator. The firmware answers M105 with `0k`…`3k`
/// instead of `ok` to report load. Port of `Modals/RPMDivergence/RPMDivergence.js`.
public struct SpindleLoadMonitor: Sendable {
    public enum Level: String, Sendable {
        case green, yellow, orange, red, grey
    }

    /// Indicator is visible while load reports are arriving.
    public private(set) var active = false
    private var lastK = ""
    private var lastWrite = ""
    private var lastRPM = 0
    private var lastDirection = ""
    private var lastSpindleChange: TimeInterval = 0
    private var meaningful = false

    public init() {}

    public var level: Level {
        guard meaningful else { return .grey }
        switch lastK {
        case "0k": return .green
        case "1k": return .yellow
        case "2k": return .orange
        case "3k": return .red
        default: return .grey
        }
    }

    public mutating func process(_ entries: [MachineLog.Entry], now: TimeInterval = Date().timeIntervalSince1970) {
        for entry in entries {
            if entry.kind == .write { lastWrite = entry.text }
            if ["0k", "1k", "2k", "3k"].contains(entry.text) {
                active = true
                lastK = entry.text
            } else if entry.text == "ok" {
                active = false
            }
            if let direction = Self.spindleDirection(entry.text) {
                lastDirection = direction
                lastSpindleChange = now
            }
            if let rpm = Self.spindleSpeed(entry.text) {
                lastRPM = rpm
                lastSpindleChange = now
            }
            checkMeaningfulness(now: now)
        }
    }

    private mutating func checkMeaningfulness(now: TimeInterval) {
        let spindleJustChanged = Self.spindleSpeed(lastWrite) != nil || Self.spindleDirection(lastWrite) != nil
        if !active || lastDirection == "M5" || lastRPM < 1500 || spindleJustChanged {
            meaningful = false
            return
        }
        if lastSpindleChange + 5 <= now { meaningful = true }
    }

    /// `/s[0-9]+/i`
    static func spindleSpeed(_ text: String) -> Int? {
        let chars = Array(text)
        for (i, c) in chars.enumerated() where c == "S" || c == "s" {
            let digits = chars[(i + 1)...].prefix(while: { $0.isASCII && $0.isNumber })
            if !digits.isEmpty { return Int(String(digits)) }
        }
        return nil
    }

    /// `/m[345]/i`
    static func spindleDirection(_ text: String) -> String? {
        let chars = Array(text)
        for i in chars.indices.dropLast() where (chars[i] == "M" || chars[i] == "m") && "345".contains(chars[i + 1]) {
            return "M\(chars[i + 1])"
        }
        return nil
    }
}
