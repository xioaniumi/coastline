import Foundation

/// GRBL's receive buffer is 128 bytes; the original reserved one (`BUFFER_SIZE = 127`).
public let grblBufferSize = 127

/// Lines sent to GRBL that have not been acknowledged yet, for character-counting flow control.
/// Port of `Buffer` (`src/Mill/GRBL/Buffer.h`).
struct LineBuffer {
    private(set) var lines: [GCodeLine] = []
    private(set) var used = 0

    static func cost(_ line: GCodeLine) -> Int { line.cleaned.utf8.count + 1 }

    @discardableResult
    mutating func pop() -> GCodeLine? {
        guard !lines.isEmpty else { return nil }
        let line = lines.removeFirst()
        used -= Self.cost(line)
        return line
    }

    mutating func push(_ line: GCodeLine) {
        used += Self.cost(line)
        lines.append(line)
    }

    mutating func clear() {
        lines.removeAll()
        used = 0
    }

    var isEmpty: Bool { lines.isEmpty }
    var count: Int { lines.count }
    var front: GCodeLine? { lines.first }
    var back: GCodeLine? { lines.last }
    var remaining: Int { max(0, grblBufferSize - used) }
    func fits(_ line: GCodeLine) -> Bool { remaining >= Self.cost(line) }
}

/// Model of the GRBL controller and connection: flags, alarm/error, buffer, cached status.
/// Port of `ConnectionState` (`src/Mill/GRBL/ConnectionState.h`). All access is locked.
public final class ConnectionState: @unchecked Sendable {
    /// Startup banner must arrive within this window (`STARTDELAY`).
    static let startupDelay: TimeInterval = 10

    struct Values {
        var connected = false
        var startup = false
        var locked = false
        var homing = false
        var checkMode = false
        var timedOut = false
        var errorFlag = false
        var alarm = 0
        var error = 0
        var errorMessage = ""
        var errorSource: GCodeLine?
        var lastReadTime = monotonicNow()
        var buffer = LineBuffer()
        var lastGCodeGroup = GCodeLine.Group.unknown
        var statusRequested = false
        var retryProbe = false
        var wcs = 54
        var units = 21
        var distanceMode = 90
        var status: RealTimeStatus?
        var statusTime: TimeInterval = 0
        var settings = MillSettings()
    }

    private let state = Locked(Values())

    init() {}

    /// `keepConnected` sets `connected` in the same critical section, so a concurrent observer
    /// (the connector's unplug check) never sees a momentary "disconnected" during a reset.
    func reset(keepConnected: Bool = false) {
        state.withLock { v in
            let settings = v.settings // settings survive a reset in the original (separate member)
            v = Values()
            v.settings = settings
            v.connected = keepConnected
        }
    }

    func withValues<R>(_ body: (inout Values) -> R) -> R { state.withLock(body) }

    // MARK: Flags

    var isConnected: Bool { state.withLock { $0.connected } }
    var isStartup: Bool { state.withLock { $0.startup } }
    var isLocked: Bool { state.withLock { $0.locked } }
    var isHoming: Bool { state.withLock { $0.homing } }
    var isCheckMode: Bool { state.withLock { $0.checkMode } }
    var isTimedOut: Bool { state.withLock { $0.timedOut } }
    var isError: Bool { state.withLock { $0.errorFlag } }
    var alarm: Int { state.withLock { $0.alarm } }
    var error: Int { state.withLock { $0.error } }
    var isAlarm: Bool { alarm != 0 }
    var errorSource: GCodeLine? { state.withLock { $0.errorSource } }
    var errorMessage: String { state.withLock { $0.errorMessage } }

    func setConnected(_ value: Bool) { state.withLock { $0.connected = value } }
    func setStartup(_ value: Bool) { state.withLock { $0.startup = value } }
    func setLocked(_ value: Bool) { state.withLock { $0.locked = value } }
    func setHoming(_ value: Bool) { state.withLock { $0.homing = value } }
    func setCheckMode(_ value: Bool) { state.withLock { $0.checkMode = value } }
    func setTimedOut(_ value: Bool) { state.withLock { $0.timedOut = value } }

    var retryProbe: Bool {
        get { state.withLock { $0.retryProbe } }
        set { state.withLock { $0.retryProbe = newValue } }
    }
    var wcs: Int {
        get { state.withLock { $0.wcs } }
        set { state.withLock { $0.wcs = newValue } }
    }
    var units: Int {
        get { state.withLock { $0.units } }
        set { state.withLock { $0.units = newValue } }
    }
    var distanceMode: Int {
        get { state.withLock { $0.distanceMode } }
        set { state.withLock { $0.distanceMode = newValue } }
    }
    var lastGCodeGroup: GCodeLine.Group {
        get { state.withLock { $0.lastGCodeGroup } }
        set { state.withLock { $0.lastGCodeGroup = newValue } }
    }
    var settings: MillSettings { state.withLock { $0.settings } }
    func updateSetting(_ setting: Int, _ value: Double) { state.withLock { $0.settings.update(setting, value) } }

    // MARK: Buffer

    func bufferPush(_ line: GCodeLine) { state.withLock { $0.buffer.push(line) } }
    @discardableResult func bufferPop() -> GCodeLine? { state.withLock { $0.buffer.pop() } }
    var bufferIsEmpty: Bool { state.withLock { $0.buffer.isEmpty } }
    func bufferFits(_ line: GCodeLine) -> Bool { state.withLock { $0.buffer.fits(line) } }
    var bufferFront: GCodeLine? { state.withLock { $0.buffer.front } }
    var bufferBack: GCodeLine? { state.withLock { $0.buffer.back } }
    var bufferUsed: Int { state.withLock { $0.buffer.used } }

    // MARK: Idle / timeout (the e-stop heuristic)

    /// `UpdateState`: ends the startup window and flags a timeout after 2 s of silence (25 s while
    /// homing or levelling). The original treats such a timeout as the hardware e-stop.
    func updateState(now: TimeInterval = monotonicNow()) {
        state.withLock { v in
            let delta = now - v.lastReadTime
            if v.startup, delta > Self.startupDelay { v.startup = false }
            let timeout: TimeInterval = v.homing ? 25 : 2
            if delta > timeout { v.timedOut = true }
        }
    }

    /// `ShouldRequestStatus`: one `?` probe, sent 1 s before the timeout would trigger.
    func shouldRequestStatus(now: TimeInterval = monotonicNow()) -> Bool {
        state.withLock { v in
            guard !v.statusRequested else { return false }
            let timeout: TimeInterval = v.homing ? 25 : 2
            if v.lastReadTime + timeout < now + 1 {
                v.statusRequested = true
                return true
            }
            return false
        }
    }

    func resetIdleTime(now: TimeInterval = monotonicNow()) {
        state.withLock { v in
            v.lastReadTime = now
            v.timedOut = false
            v.statusRequested = false
        }
    }

    // MARK: Alarm / error

    func clearAlarm() {
        state.withLock { v in
            v.alarm = 0
            v.locked = false
            v.errorFlag = false
        }
    }

    func setAlarm(_ alarm: Int) {
        state.withLock { v in
            v.alarm = alarm
            v.locked = true
            v.errorFlag = true
            v.status?.state = "Alarm"
        }
    }

    func clearError() {
        state.withLock { v in
            v.error = 0
            v.errorFlag = false
            v.errorMessage = ""
            v.errorSource = nil
        }
    }

    func setError(_ error: Int, message: String = "", source: GCodeLine? = nil) {
        state.withLock { v in
            v.error = error
            v.errorFlag = true
            v.errorMessage = message
            v.errorSource = source
        }
    }

    // MARK: Status

    func isStatusRecent(now: TimeInterval = monotonicNow()) -> Bool {
        state.withLock { $0.status != nil && $0.statusTime >= now - 0.2 }
    }

    var status: RealTimeStatus? { state.withLock { $0.status } }

    func setStatus(_ status: RealTimeStatus, now: TimeInterval = monotonicNow()) {
        state.withLock { v in
            v.status = status
            v.statusTime = now
        }
    }
}
