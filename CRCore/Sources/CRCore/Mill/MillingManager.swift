import Foundation

/// Result of `GetMillingStatus`.
public enum MillingStatus: Equatable, Sendable {
    case completed
    case inProgress(MillProgress)
    case failed(MillingError)
}

/// Runs G-code programs on a background thread and tracks progress/errors.
/// Port of `MillingManager` + `MillErrorHandler` (`src/Mill/MillingManager.cpp`).
public final class MillingManager: @unchecked Sendable {
    private struct Values {
        var error: MillingError?
        var inProgress = false
        var manualOperation = false
    }
    private let values = Locked(Values())
    private let errorLock = NSLock()

    public init() {}

    public var inProgress: Bool { values.withLock { $0.inProgress } }

    /// Manual mode ignores timeouts and does not soft-reset automatically.
    public var manualOperation: Bool {
        get { values.withLock { $0.manualOperation } }
        set { values.withLock { $0.manualOperation = newValue } }
    }

    public func clearError() { values.withLock { $0.error = nil } }

    /// `MillOperationAsync`: run one guided step.
    /// Claims the manager atomically (check, clear the old error, mark in progress) so a status
    /// poll can't see a stale error and report the new run as failed.
    private func claim(manual: Bool) -> Bool {
        values.withLock { v in
            guard !v.inProgress else { return false }
            v.inProgress = true
            v.error = nil
            v.manualOperation = manual
            return true
        }
    }

    public func runStep(_ program: GCodeProgram, resetAfter: Bool, on connection: MillConnection?) -> Bool {
        guard let connection, claim(manual: false) else { return false }
        let generation = connection.stopGenerationSnapshot
        start { self.run(connection, program.lines, resetOnCompletion: resetAfter, manualProgram: false, generation: generation) }
        return true
    }

    /// `RunAsyncGCodeBatch`: run a manual-mode G-code file.
    public func runManualProgram(_ program: GCodeProgram, on connection: MillConnection?) -> Bool {
        guard let connection, claim(manual: true) else { return false }
        let generation = connection.stopGenerationSnapshot
        start { self.run(connection, program.lines, resetOnCompletion: false, manualProgram: true, generation: generation) }
        return true
    }

    private func start(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = "MILLING_THREAD"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func run(_ connection: MillConnection, _ lines: [GCodeLine], resetOnCompletion: Bool, manualProgram: Bool,
                     generation: Int) {
        do {
            try connection.executeProgram(lines, isManualEntry: manualProgram, stopGeneration: generation)
            if connection.isTimedOut {
                throw MillError(.timeout)
            } else if resetOnCompletion {
                try connection.reset()
            }
        } catch let error as MillError {
            if connection.currentError == nil {
                let milling = Self.millingError(for: error, connection: connection)
                // Deviation: the original didn't report software e-stops (its UI had started them).
                // Stops can now also come from the menu or Manual Mode, so report them; otherwise a
                // stopped guided step would look "completed" and the job would advance.
                values.withLock { $0.error = milling }
                connection.contour.disable(log: connection.log)
                connection.log.add(.write, error.description)
            }
        } catch {
            values.withLock { $0.error = MillingError(kind: .error, id: -1, title: "Machine is locked due to an error", description: "\(error)") }
        }
        values.withLock { $0.inProgress = false }
    }

    /// `MillErrorHandler::GetError`.
    static func millingError(for error: MillError, connection: MillConnection) -> MillingError {
        switch error.kind {
        case .softwareEStop:
            _ = try? connection.reset()
            return .alarm(MillingError.alarmSoftEStop)
        case .m101Fail:
            let axis = error.detail
            let message = "The frame/lower is out of tolerance for the \(axis) axis\n\nPlease adjust the frame/lower and try again.\n\nIf this error persists you may need to contact Coast Runner technical support or run the M100.crproj file.\n\nThe workpiece is not positioned within tolerance for the \(axis) axis\n\n Please adjust the workpiece and try again.  "
            return MillingError(kind: .alarm, id: 101, title: "Alarm", description: message)
        default:
            break
        }
        if error.kind == .timeout || connection.isTimedOut {
            _ = try? connection.reset()
            return .alarm(MillingError.alarmTimeout)
        }
        switch error.kind {
        case .m106BoolTestFail:
            return MillingError(kind: .error, id: -1, title: "M106 Check Failed", description: error.description)
        case .m106MalformedTest:
            return MillingError(kind: .error, id: -1, title: "M106 Error", description: error.description)
        default:
            return MillingError(kind: .error, id: -1, title: "Machine is locked due to an error", description: error.description)
        }
    }

    /// `CheckForError`: called while idle to pick up alarms/errors (probe failures recover here).
    private func checkForError(_ connection: MillConnection?) {
        guard let connection else { return }
        // Don't read while another thread owns the connection (e.g. a `$H` waiting out homing).
        guard connection.lock.try() else { return }
        defer { connection.lock.unlock() }
        try? connection.readResponse(blocking: false)
        guard let error = connection.currentError else { return }
        values.withLock { $0.error = error }
        connection.resetProgress()
        if error.isProbeFailure {
            try? connection.probeReset()
            return
        }
        if manualOperation { return } // ignore e-stop in manual entry mode
        do {
            try connection.reset(sendSoftReset: !manualOperation)
        } catch {
            values.withLock { $0.error = .alarm(MillingError.alarmMachineLocked) }
        }
        if connection.alarmCode == MillingError.alarmEStop {
            values.withLock { $0.error = .alarm(MillingError.alarmEStop) }
        }
    }

    /// `GetMillingStatus`. With `clearError`, a reported error is cleared.
    public func status(connection: MillConnection?, clearError: Bool) -> MillingStatus {
        errorLock.withLock {
            if !inProgress { checkForError(connection) }
            if let error = values.withLock({ $0.error }) {
                values.withLock { v in
                    if clearError { v.error = nil }
                    v.inProgress = false
                }
                return .failed(error)
            }
            if inProgress {
                if let connection { return .inProgress(connection.progress) }
                return .failed(MillingError(kind: .error, id: -1, title: "Connection Error", description: "Lost Connection to Coast Runner"))
            }
            return .completed
        }
    }
}
