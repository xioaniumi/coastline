import Foundation

/// Errors thrown while talking to the mill. Port of `MillException` (`src/Mill/MillException.cpp`).
public struct MillError: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Kind: Sendable, Equatable {
        case noAccess, noDevice, failedOpen, failedGet, failedSet, failedWrite, notTTY, notOpen
        case grblError, alarm, alarmLimit, alarmProbe, unknownCommand
        case m100OutOfRange, m101Fail, m102InvalidExpression, m102OffsetsFail, m102InvalidDestRegister
        case m106BoolTestFail, m106MalformedTest, m112Fail
        case timeout, noProbeCoord, invalidMode, softwareEStop, eStopPushed, machineLocked
    }

    public var kind: Kind
    /// Extra detail (the original's `m_errorDetail`).
    public var detail: String

    public init(_ kind: Kind, _ detail: String = "") {
        self.kind = kind
        self.detail = detail
    }

    var typeMessage: String {
        switch kind {
        case .noAccess: "no access to /dev"
        case .noDevice: "no Coast Runner found"
        case .failedOpen: "failed to open connection to Coast Runner"
        case .failedGet: "failed to get properties of Coast Runner"
        case .failedSet: "failed to set properties of Coast Runner"
        case .failedWrite: "failed to write to Coast Runner"
        case .notTTY: "not a tty connection"
        case .notOpen: "connection to Coast Runner not open"
        case .grblError: "Not a valid GRBL command."
        case .alarm: "Alarm: unknown"
        case .alarmLimit: "Alarm: hard/soft limit hit"
        case .alarmProbe: "Alarm: probe fail"
        case .unknownCommand: "Not a recognized G/M/$ or other command"
        case .m100OutOfRange: "M100 value out of range"
        case .m101Fail: "M101 tolerance check failed"
        case .m102InvalidExpression: "M102 invalid expression"
        case .m102OffsetsFail: "M102 could not read offsets"
        case .m102InvalidDestRegister: "M102 invalid destination register"
        case .m106BoolTestFail: "M106 check failed"
        case .m106MalformedTest: "M106 malformed test"
        case .m112Fail: "M112 failed"
        case .timeout: "timeout"
        case .noProbeCoord: "no probe coordinate"
        case .invalidMode: "invalid mode"
        case .softwareEStop: "Software emergency stop"
        case .eStopPushed: "Emergency stop pushed"
        case .machineLocked: "Machine locked"
        }
    }

    public var description: String {
        if kind == .m106BoolTestFail { return detail }
        return detail.isEmpty ? typeMessage : "\(typeMessage): \(detail)"
    }
}

/// An error or alarm shown to the user. Port of `MillingError` (`src/Mill/Status/MillingError.*`).
public struct MillingError: Equatable, Sendable {
    public enum Kind: Sendable { case alarm, error }

    public static let alarmEStop = 50
    public static let alarmTimeout = 51
    public static let alarmSoftEStop = 52
    public static let alarmMachineLocked = 53

    public var kind: Kind
    public var id: Int
    public var title: String
    public var description: String

    public var allowsRetry: Bool { isProbeFailure }
    public var isProbeFailure: Bool { kind == .alarm && (id == 4 || id == 5) }
    public var isNotIdle: Bool { kind == .error && id == 8 }
    public var isHomingFailure: Bool { kind == .alarm && (6...9).contains(id) }
    public var isSoftLimitAlarm: Bool { kind == .alarm && id == 2 }
    public var isEStop: Bool { kind == .alarm && id == Self.alarmEStop }

    static let errorCodes: [Int: (String, String)] = [
        1: ("Expected command letter", "G-code words consist of a letter and a value. Letter was not found."),
        2: ("Bad number format", "Missing the expected G-code word value or numeric value format is not valid."),
        3: ("Invalid statement", "Grbl '$' system command was not recognized or supported."),
        4: ("Value < 0", "Negative value received for an expected positive value."),
        5: ("Setting disabled", "Homing cycle failure. Homing is not enabled via settings."),
        6: ("Value < 3 usec", "Minimum step pulse time must be greater than 3usec."),
        7: ("EEPROM read fail. Using defaults", "An EEPROM read failed. Auto-restoring affected EEPROM to default values."),
        8: ("Not idle", "Grbl '$' command cannot be used unless Grbl is IDLE. Ensures smooth operation during a job."),
        9: ("G-code lock", "G-code commands are locked out during alarm or jog state."),
        10: ("Homing not enabled", "Soft limits cannot be enabled without homing also enabled."),
        11: ("Line overflow", "Max characters per line exceeded. Received command line was not executed."),
        12: ("Step rate > 30kHz", "Grbl '$' setting value cause the step rate to exceed the maximum supported."),
        13: ("Check Door", "Safety door detected as opened and door state initiated."),
        14: ("Line length exceeded", "Build info or startup line exceeded EEPROM line length limit. Line not stored."),
        15: ("Travel exceeded", "Jog target exceeds machine travel. Jog command has been ignored."),
        16: ("Invalid jog command", "Jog command has no '=' or contains prohibited g-code."),
        17: ("Setting disabled", "Laser mode requires PWM output."),
        20: ("Unsupported command", "Unsupported or invalid g-code command found in block."),
        21: ("Modal group violation", "More than one g-code command from same modal group found in block."),
        22: ("Undefined feed rate", "Feed rate has not yet been set or is undefined."),
        23: ("Invalid gcode ID:23", "G-code command in block requires an integer value."),
        24: ("Invalid gcode ID:24", "More than one g-code command that requires axis words found in block."),
        25: ("Invalid gcode ID:25", "Repeated g-code word found in block."),
        26: ("Invalid gcode ID:26", "No axis words found in block for g-code command or current modal state which requires them."),
        27: ("Invalid gcode ID:27", "Line number value is invalid."),
        28: ("Invalid gcode ID:28", "G-code command is missing a required value word."),
        29: ("Invalid gcode ID:29", "G59.x work coordinate systems are not supported."),
        30: ("Invalid gcode ID:30", "G53 only allowed with G0 and G1 motion modes."),
        31: ("Invalid gcode ID:31", "Axis words found in block when no command or current modal state uses them."),
        32: ("Invalid gcode ID:32", "G2 and G3 arcs require at least one in-plane axis word."),
        33: ("Invalid gcode ID:33", "Motion command target is invalid."),
        34: ("Invalid gcode ID:34", "Arc radius value is invalid."),
        35: ("Invalid gcode ID:35", "G2 and G3 arcs require at least one in-plane offset word."),
        36: ("Invalid gcode ID:36", "Unused value words found in block."),
        37: ("Invalid gcode ID:37", "G43.1 dynamic tool length offset is not assigned to configured tool length axis."),
        38: ("Invalid gcode ID:38", "Tool number greater than max supported value."),
    ]

    static let alarmCodes: [Int: String] = [
        1: "Hard limit triggered. Machine position is likely lost due to sudden and immediate halt. Re-homing is highly recommended.",
        2: "G-code motion target exceeds machine travel. Machine position safely retained. Alarm may be unlocked.",
        3: "Reset while in motion. Grbl cannot guarantee position. Lost steps are likely. Re-homing is highly recommended.",
        4: "Probe fail. The probe is not in the expected initial state before starting probe cycle, where G38.2 and G38.3 is not triggered and G38.4 and G38.5 is triggered.",
        5: "Probe fail. Probe did not contact the workpiece within the programmed travel for G38.2 and G38.4.",
        6: "Homing fail. Reset during active homing cycle.",
        7: "Homing fail. Safety door was opened during active homing cycle.",
        8: "Homing fail. Cycle failed to clear limit switch when pulling off. Try increasing pull-off setting or check wiring.",
        9: "Homing fail. Could not find limit switch within search distance. Defined as 1.5 * max_travel on search and 5 * pulloff on locate phases.",
        alarmEStop: "Job was aborted due to pressing the emergency stop button. To reconnect, please twist the red emergency stop switch clockwise until it pops out. After resetting the button, press 'OK' to start program from the very beginning.",
        alarmTimeout: "Operation timed out.\n\nUnfortunately CRWrite cannot continue. Please try again.",
        alarmSoftEStop: "Job was aborted due to pressing the software emergency stop button.",
        alarmMachineLocked: "Machine is locked. Reset to continue.",
    ]

    /// `ErrorCodes::GetError`.
    public static func error(_ code: Int, lastCommand: GCodeLine?) -> MillingError {
        let (message, detail) = errorCodes[code] ?? ("Error", "Unknown error occurred.")
        let command = lastCommand.map { "Command \"\($0.cleaned)\"" } ?? "Command"
        let description = "\(command) returned error \(code): \(message): \(detail)"
            + "\n\nIf this is a known good .crproj file, then a data transmission error occurred. If this is development code, try enabling check code mode to verify all g-code syntax is valid."
            + "\n\nUnfortunately g-code behavior after experiencing an error is undefined, so CRWrite cannot continue. Please try again."
        return MillingError(kind: .error, id: code, title: message, description: description)
    }

    /// `ErrorCodes::GetAlarm`.
    public static func alarm(_ code: Int) -> MillingError {
        var description = alarmCodes[code] ?? "Unknown alarm occurred"
        if code < 50 {
            if code == 4 || code == 5 {
                description = "Coast Runner encountered ALARM:\(code) \(description)\n\nPre-probing position and state has been preserved. You may try again. Ensure probe wire is plugged in and that workpiece is free of chips and debris."
            } else {
                description = "Coast Runner encountered ALARM:\(code) \(description)\n\nUnfortunately CRWrite cannot continue. Please try again."
            }
        }
        return MillingError(kind: .alarm, id: code, title: "Alarm", description: description)
    }
}
