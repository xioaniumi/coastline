import Foundation

/// Jog directions as named by the UI. Port of `EJogDirection` (`JogDirection.h`).
public enum JogDirection: String, CaseIterable, Sendable {
    /// X: raise table (negative).
    case up = "UP"
    /// X: lower table (positive).
    case down = "DOWN"
    /// Y: gantry left (negative).
    case left = "LEFT"
    /// Y: gantry right (positive).
    case right = "RIGHT"
    /// Z: plunge (negative).
    case plunge = "PLUNGE"
    /// Z: retract (positive).
    case retract = "RETRACT"

    public var axis: Axis {
        switch self {
        case .up, .down: .x
        case .left, .right: .y
        case .plunge, .retract: .z
        }
    }

    public var isPositive: Bool {
        switch self {
        case .down, .right, .retract: true
        case .up, .left, .plunge: false
        }
    }
}

extension MillConnection {
    /// `Jog`: `$J=G91 G21 X-1.0000 F1000`, clamped to the soft limits.
    public func jog(_ direction: JogDirection, continuous: Bool, distanceMillimeters: Double) {
        do {
            try settings(refresh: false)
            try executeCommand(.injected("?"))
        } catch {
            log.add(.error, "Failed to query status. Is the machine still connected?")
            return
        }

        var distance = jogDistance(direction, continuous: continuous, distanceMillimeters: distanceMillimeters)
        guard distance != 0 else { return } // already at the limit
        let units = state.units == 20 ? "G20" : "G21"
        if units == "G20" { distance *= 0.0393701 }
        let command = "$J=G91 \(units) \(direction.axis.rawValue)\(String(format: "%.4f", distance)) F1000"

        lock.withLock {
            guard state.bufferFits(GCodeLine(command)) else { return }
            try? executeCommand(GCodeLine(command))
        }
    }

    /// `CalculateDistance`: distance to the soft limit (continuous) or the requested step, signed.
    func jogDistance(_ direction: JogDirection, continuous: Bool, distanceMillimeters: Double) -> Double {
        let positive = direction.isPositive
        guard let limits = state.settings.softLimits else {
            return positive ? distanceMillimeters : -distanceMillimeters
        }
        guard let status = state.status else { return positive ? 1 : -1 }
        let position = status.machinePosition[direction.axis]
        let range = limits.range(direction.axis)
        let toLimit = positive ? range.upperBound - position : position - range.lowerBound
        var distance = abs(toLimit)
        if !continuous { distance = min(distance, distanceMillimeters) }
        distance = (distance * 10_000).rounded(.down) / 10_000
        var result = positive ? distance : -distance
        if continuous {
            // Back off 1 mm from the limit. Deviation: within 1 mm the original flipped the sign
            // and jogged the other way; stay put instead.
            result = positive ? max(0, result - 1) : min(0, result + 1)
        }
        return result
    }

    /// `StopJogging`: jog-cancel (0x85) then a status query.
    public func cancelJog() {
        try? executeRealtime(0x85)
        try? executeCommand(.injected("?"))
    }

    // MARK: WCS helpers (MillDaemon)

    /// `HasNonzeroWCS`: any of G54–G58 non-zero (G59 is a deliberate carry-over register).
    public func hasNonzeroWCS() -> Bool {
        offsets().contains { entry in
            entry.name.hasPrefix("G5") && entry.name != "G59" && entry.point != .zero
        }
    }

    /// `ClearG54ThroughG58`.
    public func clearG54ThroughG58(allowRetry: Bool = true) {
        lock.withLock {
            let offsets = self.offsets()
            guard !offsets.isEmpty else { log.add(.error, "Offset clearing failed."); return }
            do {
                for entry in offsets where entry.name.hasPrefix("G5") && entry.name != "G59" && entry.point != .zero {
                    guard let digit = entry.name.last?.wholeNumberValue else { continue }
                    try executeCommand(GCodeLine("G10 L2 P\(digit - 3) X0 Y0 Z0"))
                }
            } catch {
                if allowRetry {
                    try? executeCommand(GCodeLine("$X"))
                    clearG54ThroughG58(allowRetry: false)
                }
            }
        }
    }

    /// `WcsValueCheck`: "" when every check passes, else the job's failure message.
    public func wcsValueCheck(for job: Job) -> String {
        guard !job.wcsChecks.isEmpty else { return "" }
        let offsets = self.offsets()
        guard !offsets.isEmpty else { return "" }
        for check in job.wcsChecks {
            guard let entry = offsets.first(where: { Int($0.name.dropFirst()) == check.wcs }) else { continue }
            let diff = entry.point - Point3(x: check.x, y: check.y, z: check.z)
            let tolerance = 0.001
            if abs(diff.x) > tolerance || abs(diff.y) > tolerance || abs(diff.z) > tolerance {
                return job.wcsCheckFailedMessage
            }
        }
        return ""
    }
}
