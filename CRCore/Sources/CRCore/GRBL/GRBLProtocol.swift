import Foundation

/// Parses responses from GRBL and updates `ConnectionState`.
/// Port of `Protocol` (`src/Mill/GRBL/Protocol/Protocol.cpp`).
final class GRBLProtocol: @unchecked Sendable {
    enum Version: Sendable { case v1_0, v1_1 }

    private let serial: SerialConnection
    private let state: ConnectionState
    /// Called with `[PRB:…]` lines (`MillConnection::SaveProbeResult`).
    var onProbeResult: (@Sendable (String) -> Void)?
    private let versionStore = Locked(Version.v1_1)

    init(serial: SerialConnection, state: ConnectionState) {
        self.serial = serial
        self.state = state
    }

    var version: Version { versionStore.current }

    func setVersion(_ version: String) {
        versionStore.current = version.hasPrefix("1.1") ? .v1_1 : .v1_0
    }

    /// `ProcessResponse`: throws when the machine is no longer usable (error, alarm, lock).
    func processResponse(_ line: String) throws {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return }

        if line == "ok" || line == "0k" || line == "1k" || line == "2k" || line == "3k" || Self.isHexOK(line) {
            // GRBL acknowledges $H/$L only when the cycle has finished: homing timeout ends here.
            if let line = state.bufferPop(), line.isHome || line.isLevel { state.setHoming(false) }
            return
        }

        if line.hasPrefix("[PRB:") { onProbeResult?(line) }

        if line.hasPrefix("error:") {
            let source = state.bufferPop()
            let rest = String(line.dropFirst(6))
            var code = -1
            var message = ""
            if version == .v1_1 {
                guard let parsed = ManifestParser.leadingInteger(rest) else { throw MillError(.grblError, rest) }
                code = parsed
            } else {
                message = rest
            }
            state.setError(code, message: message, source: source)
            throw MillError(.grblError, message)
        }

        if line == "[Enabled]" || line == "[Disabled]" {
            state.setCheckMode(false)
            return
        }

        if (line.hasPrefix("[") && line.hasSuffix("to unlock]")) || line.contains("[MSG:Reset") {
            state.setLocked(true)
            throw MillError(.machineLocked, "Machine locked. Reset to continue.")
        }

        if let (setting, value) = Self.parseSetting(line) {
            state.updateSetting(setting, value)
            return
        }

        if line.hasPrefix("<") {
            let settings = state.settings
            let wcs = state.wcs
            let units = state.units
            let distance = state.distanceMode
            do {
                var status = version == .v1_0
                    ? try RealTimeStatus.parseV0(line, wcs: wcs, reportUnit: settings.reportUnit, parserUnits: units, distanceMode: distance)
                    : try RealTimeStatus.parse(line, wcs: wcs, reportUnit: settings.reportUnit, parserUnits: units, distanceMode: distance)
                // GRBL only reports the work offset every few reports; keep the last known one.
                if status.workOffset == nil, let previous = state.status {
                    status.workOffset = previous.workOffset
                    status.wcs = wcs
                }
                state.setStatus(status)
            } catch {
                // Original logs and ignores unparsable status reports.
            }
            return
        }

        if line.hasPrefix("ALARM:") {
            let rest = String(line.dropFirst(6))
            var code = -1
            var description = ""
            if version == .v1_1 {
                code = ManifestParser.leadingInteger(rest) ?? -1
            } else {
                description = rest
            }
            state.setAlarm(code)
            if code == 4 || code == 5 || description == "Probe fail" {
                throw MillError(.alarmProbe)
            } else if code == 2 || description == "Hard/soft limit" {
                throw MillError(.alarmLimit)
            } else {
                throw MillError(.alarm, description)
            }
        }
    }

    /// `RequiresEmptyBuffer`: whether all outstanding lines must be acknowledged before sending.
    func requiresEmptyBuffer(_ line: GCodeLine) -> Bool {
        if line.cleaned.isEmpty { return false }
        switch line.kind {
        case .grbl, .mcode:
            return true
        case .gcode:
            return state.lastGCodeGroup != .motion || line.group != .motion
        case .axisFeedSpindle:
            return state.lastGCodeGroup != .motion
        case .unknown:
            return true
        }
    }

    /// `QueryStatus`: returns the cached status if under 200 ms old, otherwise sends `?` and
    /// reads up to 5 lines looking for a fresh report.
    func queryStatus() -> RealTimeStatus? {
        if state.isStatusRecent() { return state.status }
        if !state.isLocked, !state.isTimedOut {
            do {
                try serial.writeChar(UInt8(ascii: "?"))
                for _ in 0..<5 {
                    if let line = serial.readLine() {
                        try processResponse(line)
                        if state.isStatusRecent() { return state.status }
                    } else {
                        sleep(milliseconds: 5)
                    }
                }
            } catch {
                // Swallowed, as in the original.
            }
        }
        return state.status
    }

    /// `^K([0-9A-F])` — corrupted "ok" variants seen from the firmware.
    static func isHexOK(_ line: String) -> Bool {
        let chars = Array(line)
        // std::regex_match: the whole line must be "K" plus one hex digit.
        guard chars.count == 2, chars[0] == "K" else { return false }
        return chars[1].isHexDigit && (chars[1].isNumber || chars[1].isUppercase)
    }

    /// `^\$(.?\d+)=(-?\d*\.?\d+).*`
    static func parseSetting(_ line: String) -> (Int, Double)? {
        guard line.hasPrefix("$"), let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[line.index(after: line.startIndex)..<eq]
        // The original's stoi would throw on non-numeric keys like `$N0`; treat those as non-settings.
        guard let setting = Int(key) else { return nil }
        let valueText = line[line.index(after: eq)...].prefix(while: { $0.isNumber || $0 == "." || $0 == "-" })
        guard let value = Double(valueText) else { return nil }
        return (setting, value)
    }
}

/// Feed-rate override slider. Port of `FeedRate` (`src/Mill/GRBL/Settings/FeedRate.h`).
final class FeedRate: @unchecked Sendable {
    private struct Values {
        var updateRequired = false
        var slider = 100
        var feedRate = 100
    }
    private let values = Locked(Values())

    /// Percentage, minimum 30.
    var slider: Int {
        get { values.withLock { $0.slider } }
        set {
            values.withLock { v in
                let value = max(30, newValue)
                if v.slider != value {
                    v.updateRequired = true
                    v.slider = value
                }
            }
        }
    }

    /// Scales a programmed feed rate by the slider and remembers it.
    func update(feedRate: Int) -> Int {
        values.withLock { v in
            v.feedRate = feedRate
            v.updateRequired = false
            return feedRate * v.slider / 100
        }
    }

    var isUpdateRequired: Bool { values.withLock { $0.updateRequired } }

    /// The current scaled feed rate; clears the update flag.
    func currentFeedRate() -> Int {
        values.withLock { v in
            v.updateRequired = false
            return v.feedRate * v.slider / 100
        }
    }
}

/// Tracks the expected machine position as G-code is sent (for contour mapping).
/// Port of `POSITION_ACCUMULATOR` (`src/Mill/GRBL/PositionAccumulator.cpp`).
struct PositionAccumulator {
    var position = Point3.zero
    var wcs = Point3.zero
    var distanceMode = 90

    mutating func clear() {
        self = PositionAccumulator()
    }

    var workPosition: Point3 { position - wcs }

    mutating func apply(_ line: GCodeLine) {
        if line.group == .userDefined || line.cleaned.contains("$") { return }
        var target: [Axis: Double] = [:]
        var useWCS = true
        for chunk in chunkGCodeLine(line.cleaned) {
            guard let letter = chunk.first else { continue }
            let param = String(chunk.dropFirst())
            if let axis = Axis(letter: letter), letter.isUppercase {
                guard let value = Double(param) else { continue }
                target[axis] = distanceMode == 90 ? value : position[axis] + value
            } else if letter == "G" {
                // Remove the first '.', then stoi ("38.2" → 382, "10L2P1" → 10).
                var digits = param
                if let dot = digits.firstIndex(of: ".") { digits.remove(at: dot) }
                guard let number = ManifestParser.leadingInteger(digits) else { continue }
                if number == 53 { useWCS = false }
                else if number == 90 || number == 91 { distanceMode = number }
            }
        }
        for (axis, value) in target {
            position[axis] = (useWCS && distanceMode != 91) ? value + wcs[axis] : value
        }
    }
}
