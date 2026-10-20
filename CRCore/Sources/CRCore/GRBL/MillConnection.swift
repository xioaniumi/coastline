import Foundation

/// Progress of the running program (`Progress`).
public struct MillProgress: Equatable, Sendable {
    public var completed = 0
    public var total = 0
    public var percentage: Double { total > 0 ? Double(completed) / Double(total) * 100 : 0 }

    public init(completed: Int = 0, total: Int = 0) {
        self.completed = completed
        self.total = total
    }
}

/// A live connection to one mill. Port of `MillConnection` + `MillWriter`
/// (`src/Mill/GRBL/MillConnection.cpp`, `MillWriter.cpp`).
///
/// All methods block and must be called off the main thread. Like the original, a recursive lock
/// serialises compound operations, while `emergencyStop()` and `executeRealtime(_:)` can be called
/// concurrently from another thread to interrupt a running program.
public final class MillConnection: @unchecked Sendable {
    public let device: MillDevice
    let state: ConnectionState
    let serial: SerialConnection
    let proto: GRBLProtocol
    let log: MachineLog
    let feedRate = FeedRate()
    let lock = NSRecursiveLock()

    /// True while the UI is in manual mode: timeouts are not treated as e-stops then
    /// (`MillDaemon::GetManualOperationFlag`).
    let isManualOperation: @Sendable () -> Bool
    /// `SettingManager::GetEnableLS`.
    let enableLS: @Sendable () -> Bool

    private let progressStore = Locked(MillProgress())
    private let emergencyStopFlag = Locked(false)
    /// Deviation: the original's e-stop flag was only set for the ~500 ms of `reset()`, so a
    /// program thread busy elsewhere (M-codes, waits, waiting for the lock) could miss it and then
    /// wait forever for acknowledgements GRBL discarded. Programs now latch a stop generation.
    private let stopGeneration = Locked(0)
    private let programGeneration = Locked<Int?>(nil)
    /// Incremented for every `[PRB:` report (M111 waits for a new one).
    private let probeCount = Locked(0)
    private let probeStore = Locked(Point3.zero)
    private var accumulator = PositionAccumulator()
    private var savedPreprobeState: PreprobeState?
    let contour = ContourMap()

    struct PreprobeState {
        var position = Point3.zero
        var gStates: [String] = []
        var coolantState = ""
        var spindleState = ""
        var toolNumber = ""
        var feedRate = ""
        var spindleRPM = ""
    }

    init(device: MillDevice, transport: SerialTransport, log: MachineLog,
         isManualOperation: @escaping @Sendable () -> Bool = { false },
         enableLS: @escaping @Sendable () -> Bool = { false }) {
        self.device = device
        self.log = log
        self.isManualOperation = isManualOperation
        self.enableLS = enableLS
        state = ConnectionState()
        serial = SerialConnection(transport: transport, state: state, log: log)
        proto = GRBLProtocol(serial: serial, state: state)
        proto.onProbeResult = { [weak self] line in self?.saveProbeResult(line) }
    }

    /// Opens the port, waits for the GRBL banner and loads `$$` settings (`MillConnection::Connect`).
    public static func connect(device: MillDevice, transport: SerialTransport, log: MachineLog,
                               isManualOperation: @escaping @Sendable () -> Bool = { false },
                               enableLS: @escaping @Sendable () -> Bool = { false }) throws -> MillConnection {
        guard !device.path.isEmpty else { throw MillError(.failedOpen, "Path Empty") }
        let connection = MillConnection(device: device, transport: transport, log: log,
                                        isManualOperation: isManualOperation, enableLS: enableLS)
        try connection.connect()
        return connection
    }

    func connect() throws {
        try lock.withLock {
            try serial.connect()
            state.setConnected(true)
            state.setStartup(true)
            serial.flushReads()

            var started = false
            // Deviation: the original could retry forever if the banner was swallowed by reset().
            let deadline = monotonicNow() + 20
            while true {
                if monotonicNow() > deadline {
                    serial.disconnect()
                    state.setConnected(false)
                    throw MillError(.failedOpen, "no GRBL banner from \(device.path)")
                }
                if let line = serial.readLine() {
                    if let version = Self.grblVersion(in: line) {
                        proto.setVersion(version)
                        started = true
                    }
                    continue
                }
                state.updateState()
                if started, !state.isStartup { break }
                if state.isTimedOut {
                    if try !reset(sendSoftReset: false) { throw MillError(.eStopPushed) }
                }
                sleep(milliseconds: 50)
            }
            serial.flushReads()
            try executeCommand(.injected("$$"))
        }
    }

    /// `^Grbl (\d+\.\d+).*` (case-insensitive) → version.
    static func grblVersion(in line: String) -> String? {
        guard line.lowercased().hasPrefix("grbl ") else { return nil }
        let rest = line.dropFirst(5)
        let major = rest.prefix(while: \.isNumber)
        guard !major.isEmpty else { return nil }
        let afterMajor = rest.dropFirst(major.count)
        guard afterMajor.first == "." else { return nil }
        let minor = afterMajor.dropFirst().prefix(while: \.isNumber)
        guard !minor.isEmpty else { return nil }
        return "\(major).\(minor)"
    }

    public func disconnect() {
        guard state.isConnected else { return }
        progressStore.current = MillProgress()
        state.reset()
        serial.disconnect()
    }

    func verifyConnected() throws {
        guard state.isConnected else { throw MillError(.notOpen) }
    }

    // MARK: - Public state

    public var progress: MillProgress { progressStore.current }
    /// False once the port was closed (e.g. a USB drop), even if the device path reappeared.
    public var isTransportOpen: Bool { serial.transport.isOpen }
    public var isConnected: Bool { state.isConnected }
    public var isLocked: Bool { state.isLocked }
    public var isTimedOut: Bool { updatedState().isTimedOut }
    public var isHoming: Bool { state.isHoming }
    public var settingsSnapshot: MillSettings { state.settings }
    public var cachedStatus: RealTimeStatus? { state.status }
    public var parserUnits: Int { state.units }
    public var currentWCS: Int { state.wcs }
    public var alarmCode: Int { state.alarm }
    public var lastProbedPoint: Point3 { probeStore.current }

    public var feedRateSlider: Int {
        get { feedRate.slider }
        set { feedRate.slider = newValue }
    }

    func updatedState() -> ConnectionState {
        state.updateState()
        return state
    }

    /// `GetError`: the current GRBL error or alarm, if any.
    public var currentError: MillingError? {
        if state.error > 0 { return .error(state.error, lastCommand: state.errorSource) }
        if state.alarm > 0 { return .alarm(state.alarm) }
        return nil
    }

    public var isEStopEngaged: Bool { state.alarm == MillingError.alarmEStop }

    // MARK: - Reset

    /// `Reset`: clears local state; with `sendSoftReset` also resets GRBL with ^X.
    /// Returns false when the mill does not answer (e.g. e-stop pressed).
    @discardableResult
    public func reset(sendSoftReset: Bool = true) throws -> Bool {
        try verifyConnected()
        sleep(milliseconds: 500)
        if let line = serial.readLine() {
            try proto.processResponse(line) // surfaces errors/alarms to the caller
        }
        serial.flushReads()
        try serial.writeChar(sendSoftReset ? 0x18 : UInt8(ascii: "?"), waitMilliseconds: 1000)
        return lock.withLock {
            sleep(milliseconds: 5)
            var line = serial.readLine()
            if line == nil { return false }
            while let current = line {
                try? proto.processResponse(current)
                line = serial.readLine()
            }
            progressStore.current = MillProgress()
            state.reset(keepConnected: true)
            return true
        }
    }

    /// `ProbeReset`: recover after a failed probe (unlock, restore pre-probe state).
    public func probeReset() throws {
        try verifyConnected()
        sleep(milliseconds: 500)
        try lock.withLock {
            serial.flushReads()
            try serial.writeChar(0x18, waitMilliseconds: 500)
            try serial.writeLine("$X", waitMilliseconds: 500)
            serial.flushReads()
            progressStore.current = MillProgress()
            state.reset(keepConnected: true)
            state.retryProbe = true
            if savedPreprobeState != nil { restorePreprobeState() }
        }
    }

    /// `EmergencyStop`: soft-reset immediately, then again after GRBL has settled.
    public func emergencyStop() {
        stopGeneration.withLock { $0 += 1 }
        emergencyStopFlag.current = true
        try? executeRealtime(0x18)
        progressStore.withLock { $0.completed = 0 }
        _ = try? reset(sendSoftReset: false) // an alarm is expected here
        emergencyStopFlag.current = false
        sleep(milliseconds: 200)
        try? executeRealtime(0x18)
    }

    // MARK: - Execute

    /// `ExecuteCommand`: run one line (manual entry, jogging, internal commands).
    public func executeCommand(_ line: GCodeLine, isManualEntry: Bool = false) throws {
        try verifyConnected()
        try lock.withLock {
            state.resetIdleTime()
            state.clearError()
            if !state.isLocked, !state.isTimedOut, !state.isAlarm {
                try executeLine(line, useBuffer: false, manualEntry: true)
            } else if line.isUnlock || line.isHome {
                // Manually entered commands should not automatically soft-reset GRBL.
                try reset(sendSoftReset: !isManualEntry)
                try executeLine(line, useBuffer: false, manualEntry: true)
            } else if line.cleaned == "|" {
                try reset(sendSoftReset: true)
            } else if !line.isInjected {
                log.add(.error, "Failed to write \"\(line.original)\"! The machine may be locked or the emergency stop may be engaged.")
            }
        }
    }

    /// `ExecuteProgram`: stream a whole program with flow control and progress.
    /// Stop counter snapshot; take it when a run is requested so an e-stop pressed before the
    /// program thread starts still cancels it.
    public var stopGenerationSnapshot: Int { stopGeneration.current }

    public func executeProgram(_ lines: [GCodeLine], isManualEntry: Bool = false, stopGeneration requested: Int? = nil) throws {
        // Captured before taking the lock: an e-stop pressed while we wait still cancels us.
        let generation = requested ?? stopGeneration.current
        try lock.withLock {
            programGeneration.current = generation
            defer { programGeneration.current = nil }
            try checkStopRequested()
            try verifyConnected()
            contour.disable(log: log) // M113: must be re-enabled explicitly on each run

            if currentError != nil {
                guard try reset(sendSoftReset: !isManualEntry) else { return }
            }

            state.resetIdleTime()
            if state.retryProbe {
                try serial.writeLine("$X", waitMilliseconds: 1000)
                state.retryProbe = false
            }

            try refreshStatus()
            serial.flushReads()

            progressStore.current = MillProgress(completed: 0, total: lines.count)
            accumulator.clear()
            accumulator.wcs = currentWCSOffset()
            accumulator.position = currentPosition()

            for (i, line) in lines.enumerated() {
                try checkStopRequested()
                try executeLine(line, useBuffer: true, manualEntry: isManualEntry)
                if feedRate.isUpdateRequired {
                    try executeLine(GCodeLine("F\(feedRate.currentFeedRate())", injected: true),
                                    useBuffer: true, manualEntry: isManualEntry)
                }
                progressStore.withLock { $0.completed = i + 1 }
            }
            try executeLine(GCodeLine("G4 P0"), useBuffer: false, manualEntry: false)
        }
    }

    private func checkStopRequested() throws {
        if let generation = programGeneration.current, stopGeneration.current > generation {
            throw MillError(.softwareEStop)
        }
    }

    /// `ExecuteRealtime`: send a single real-time byte (`?`, `!`, `~`, `|`, 0x18, 0x85).
    public func executeRealtime(_ byte: UInt8) throws {
        try verifyConnected()
        try serial.writeChar(byte)
        if byte == UInt8(ascii: "|") {
            state.wcs = 54
            state.units = 21
        }
    }

    /// `GetSettings`: refresh with `$$` when asked or when nothing is known yet.
    @discardableResult
    public func settings(refresh: Bool = true) throws -> MillSettings {
        if refresh || state.settings.isEmpty {
            try executeCommand(.injected("$$"))
        }
        return state.settings
    }

    /// `QueryStatus`.
    public func queryStatus() throws -> RealTimeStatus? {
        try verifyConnected()
        return proto.queryStatus()
    }

    /// `RefreshStatus`: `?` + newline; GRBL answers with a report and an `ok` for the empty line.
    func refreshStatus() throws {
        state.bufferPush(.injected("?"))
        try serial.writeLine("?")
        try readResponse(blocking: true)
    }

    func executeLine(_ line: GCodeLine, useBuffer: Bool, manualEntry: Bool) throws {
        if line.cleaned.isEmpty { return }

        if !state.bufferIsEmpty {
            if !useBuffer || proto.requiresEmptyBuffer(line) {
                try readResponse(blocking: true)
            }
            while !state.bufferFits(line) {
                try readResponse(blocking: false)
            }
        }

        if !manualEntry, line.cleaned == "$LS", !enableLS() {
            throw MillError(.unknownCommand, line.original)
        }

        // GRBL system commands are only accepted when the machine is not running.
        if line.kind == .grbl {
            var status = "Run"
            var missingStatus = 0
            while status == "Run" {
                try refreshStatus()
                if let current = state.status?.state {
                    status = current
                } else {
                    // Deviation: the original would loop forever without a parsable status.
                    missingStatus += 1
                    if missingStatus > 100 { break }
                }
            }
        }

        if !manualEntry, line.cleaned.contains("G38") {
            try tryProbeOperation(line)
            return
        }

        let cleaned = line.cleaned
        let adjustable = !cleaned.contains("G53") && cleaned.contains(where: { "XYZIJK".contains($0) })
        if contour.isEnabled, adjustable {
            try transformZAndWriteLine(line)
        } else {
            accumulator.apply(line)
            try write(line)
        }

        if !useBuffer || line.isBlocking {
            try readResponse(blocking: true)
        }
    }

    /// `ReadResponse`: process incoming lines; when `blocking`, until every sent line is acknowledged.
    /// This is also where the e-stop heuristic lives: silence → timeout → hardware e-stop alarm.
    public func readResponse(blocking: Bool) throws {
        while true {
            try verifyConnected()
            try checkStopRequested()
            // Deviation: the status poller may have processed an `error:`/`ALARM:` line meant for
            // this operation; stop here instead of streaming on after a rejected line.
            if state.error > 0 { throw MillError(.grblError, state.errorMessage) }
            if state.alarm > 0 { throw MillError(state.alarm == 4 || state.alarm == 5 ? .alarmProbe : .alarm) }
            sleep(milliseconds: 5)

            if let line = serial.readLine() {
                try proto.processResponse(line)
                continue
            } else if emergencyStopFlag.current {
                throw MillError(.softwareEStop)
            }

            state.updateState()
            if state.isTimedOut {
                if isManualOperation() { return } // timeouts are ignored in manual mode
                state.setAlarm(MillingError.alarmEStop)
                throw MillError(.eStopPushed)
            } else if state.shouldRequestStatus() {
                try serial.writeChar(UInt8(ascii: "?"))
            }

            if !blocking || state.bufferIsEmpty { break }
        }
        // Deviation: only a completed blocking read ends homing. In the original a non-blocking
        // poll cleared it too, so the 2 s timeout fired mid-homing (false e-stop + soft reset).
        if blocking { state.setHoming(false) }
    }

    /// Reads one line without processing it, waiting up to ~1 s.
    func readResponseWithoutProcessing() throws -> String {
        sleep(milliseconds: 5)
        var line = serial.readLine()
        var tries = 0
        while line == nil, tries < 200 {
            tries += 1
            sleep(milliseconds: 5)
            line = serial.readLine()
            state.resetIdleTime()
        }
        guard let line else { throw MillError(.alarm) }
        return line
    }

    // MARK: - Offsets / positions

    /// `GetOffsets`: `$#` → [("G54", point), …, ("TLO", …), ("PRB", …)]. Empty on failure.
    public func offsets() -> [(name: String, point: Point3)] {
        var result: [(String, Point3)] = []
        lock.withLock {
            serial.lock.withLock {
                do {
                    try verifyConnected()
                    try serial.writeLine("$#")
                    var response = ""
                    while response != "ok" {
                        response = try readResponseWithoutProcessing()
                        guard response.first == "[", response.count >= 2 else { continue }
                        let body = String(response.dropFirst().dropLast())
                        let (name, values) = RealTimeStatus.splitOnce(body, ":")
                        let numbers = values.split(whereSeparator: { $0 == "," || $0 == ":" }).map(String.init)
                        guard let x = numbers.first.flatMap(Double.init) else { continue }
                        if name == "TLO" {
                            result.append((name, Point3(x: x, y: x, z: x)))
                        } else if numbers.count >= 3, let y = Double(numbers[1]), let z = Double(numbers[2]) {
                            result.append((name, Point3(x: x, y: y, z: z)))
                        }
                    }
                } catch {
                    // Return what was collected, like the original.
                }
            }
        }
        return result
    }

    func currentPosition() -> Point3 {
        guard let status = state.status else { return .zero }
        return status.machinePosition
    }

    func currentWCSOffset() -> Point3 {
        state.status?.workOffset ?? .zero
    }

    /// `SaveProbeResult`: `[PRB:-86.000,-0.500,-1.350:1]`.
    /// Deviation: the original dropped the last digit of X and Y (`substr(0, n - 1)`).
    func saveProbeResult(_ line: String) {
        guard line.hasPrefix("[PRB:"), let colon = line.lastIndex(of: ":") else { return }
        let body = line[line.index(line.startIndex, offsetBy: 5)..<colon]
        let parts = body.split(separator: ",")
        guard parts.count == 3, let x = Double(parts[0]), let y = Double(parts[1]), let z = Double(parts[2]) else { return }
        probeStore.current = Point3(x: x, y: y, z: z)
        probeCount.withLock { $0 += 1 }
    }

    // MARK: - Probing

    /// `TryProbeOperation`: remember modal state/position so a failed probe can be recovered.
    func tryProbeOperation(_ line: GCodeLine) throws {
        savedPreprobeState = nil
        try refreshStatus()

        var point = Point3(x: -86, y: -0.5, z: -0.5) // default: home position
        if let status = state.status { point = status.machinePosition }

        try serial.writeLine("$G")
        var restoreCommand = try readResponseWithoutProcessing() // "[GC:G0 G54 G17 G21 G90 G94 M5 M9 T0 F0 S0]"
        restoreCommand = restoreCommand.count > 5 ? String(restoreCommand.dropFirst(4).dropLast()) : ""

        do {
            // NOTE: the line is pushed here AND again inside write(). The extra entry is balanced
            // by the `ok` that follows the `$G` response above. Kept exactly as in the original.
            state.bufferPush(line)
            try write(line)
            try readResponse(blocking: true)
        } catch {
            var saved = PreprobeState()
            saved.position = point
            for token in restoreCommand.split(separator: " ").map(String.init) {
                if token == "M9" { saved.coolantState = token }
                else if token.hasPrefix("M") { saved.spindleState = token }
                else if token.hasPrefix("T") { saved.toolNumber = token }
                else if token.hasPrefix("F") { saved.feedRate = token }
                else if token.hasPrefix("S") { saved.spindleRPM = token }
                else { saved.gStates.append(token) }
            }
            savedPreprobeState = saved
            throw error
        }
    }

    /// `RestorePreprobeState`.
    func restorePreprobeState() {
        guard let saved = savedPreprobeState else { return }
        do {
            try serial.writeLine(saved.coolantState)
            try serial.writeLine(saved.spindleState)
            try serial.writeLine(saved.toolNumber)
            try serial.writeLine(saved.feedRate)
            try serial.writeLine(saved.spindleRPM)

            let move = "G53 G0 X\(Self.cppFloat(saved.position.x)) Y\(Self.cppFloat(saved.position.y)) Z\(Self.cppFloat(saved.position.z))"
            state.bufferPush(GCodeLine(move))
            try serial.writeLine(move)
            try readResponse(blocking: true)

            for var g in saved.gStates {
                if g.contains("G38.") { g = "G0" }
                try serial.writeLine(g)
            }
            serial.flushReads()
            try serial.writeLine("$G")
            var response = "ok"
            let deadline = monotonicNow() + 5
            while response.first != "[", monotonicNow() < deadline {
                sleep(milliseconds: 10)
                if let line = serial.readLine() { response = line }
            }
            savedPreprobeState = nil
        } catch {
            log.add(.error, "Error occurred while restoring probe state.")
        }
    }

    /// `std::to_string(float)` → 6 decimals.
    static func cppFloat(_ value: Double) -> String { String(format: "%f", value) }

    // MARK: - Writer (MillWriter)

    func write(_ line: GCodeLine) throws {
        updateConnectionState(line)
        switch line.kind {
        case .grbl:
            if line.isUnlock || line.isHome { state.setLocked(false) }
            // GRBL is silent while homing/levelling, so allow a longer timeout.
            if line.isHome || line.isLevel { state.setHoming(true) }
            if line.group == .checkMode { state.setCheckMode(!state.isCheckMode) }
            try writeLine(line)
        case .mcode:
            if line.group == .userDefined {
                guard let options = line.mcodeOptions else { throw MillError(.unknownCommand, line.original) }
                switch line.value {
                case 100: try m100(options)
                case 101: try m101(options)
                case 102: try m102(line.original) // needs the original: parentheses are part of the expression
                case 106: try m106(line.original)
                case 111: try m111(options)
                case 112: try contour.enable(log: log)
                case 113: contour.disable(log: log)
                case 114: contour.clear(log: log)
                default: break
                }
                return
            }
            try writeLine(line)
        case .gcode:
            if let wcs = line.wcs { state.wcs = wcs }
            if let mode = line.distanceMode { state.distanceMode = mode }
            if line.group == .units, let units = line.units { state.units = units }
            state.lastGCodeGroup = line.group
            try writeLine(line)
        case .axisFeedSpindle:
            state.lastGCodeGroup = .motion
            try writeLine(line)
        case .unknown:
            throw MillError(.unknownCommand, line.original)
        }
    }

    /// Tracks units / WCS from any `Gnn` in the line (regex search `G(\d{2})`).
    private func updateConnectionState(_ line: GCodeLine) {
        let chars = Array(line.cleaned)
        var i = 0
        while i + 2 < chars.count + 0 {
            if chars[i] == "G", chars[i + 1].isASCII, chars[i + 1].isNumber, i + 2 < chars.count,
               chars[i + 2].isASCII, chars[i + 2].isNumber, let code = Int(String(chars[(i + 1)...(i + 2)])) {
                if code == 20 || code == 21 { state.units = code }
                if (54...58).contains(code) { state.wcs = code }
                i += 3
            } else {
                i += 1
            }
        }
    }

    var probeReports: Int { probeCount.current }

    func resetProgress() { progressStore.current = MillProgress() }

    private func writeLine(_ line: GCodeLine) throws {
        if state.isCheckMode { sleep(milliseconds: 500) }
        var cleaned = line.cleaned
        if !line.isInjected, let programmed = Self.lastFeedRate(in: cleaned) {
            let scaled = feedRate.update(feedRate: programmed)
            if scaled > 0 { cleaned = Self.replaceFeedRates(in: cleaned, with: scaled) }
        }
        if let (setting, value) = GRBLProtocol.parseSetting(cleaned) {
            state.updateSetting(setting, value)
        }
        // Deviation: account for the text actually sent. Feed override (above 100%) or the contour
        // transform can make it longer than the line checked in executeLine, which could overflow
        // GRBL's 128-byte receive buffer.
        let outgoing = cleaned == line.cleaned ? line : GCodeLine(cleaned, injected: line.isInjected)
        while !state.bufferIsEmpty, !state.bufferFits(outgoing) {
            try readResponse(blocking: false)
        }
        state.bufferPush(outgoing)
        try serial.writeLine(cleaned)
    }

    /// `^.*F(\d+).*` (case-insensitive): the digits after the LAST `F`/`f` followed by a digit.
    static func lastFeedRate(in s: String) -> Int? {
        let chars = Array(s)
        var result: Int?
        for i in chars.indices where (chars[i] == "F" || chars[i] == "f") {
            let digits = chars[(i + 1)...].prefix(while: { $0.isASCII && $0.isNumber })
            if !digits.isEmpty { result = Int(String(digits)) }
        }
        return result
    }

    /// `regex_replace(cleaned, F\d+ (icase), "F<value>")`.
    static func replaceFeedRates(in s: String, with value: Int) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "F" || chars[i] == "f" {
                let digits = chars[(i + 1)...].prefix(while: { $0.isASCII && $0.isNumber })
                if !digits.isEmpty {
                    out += "F\(value)"
                    i += 1 + digits.count
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    // MARK: - Contour-map Z transform

    func transformZAndWriteLine(_ line: GCodeLine) throws {
        let previous = accumulator.position
        var temp = accumulator
        temp.apply(line)
        let target = temp.position
        let wcs = currentWCSOffset()

        let transformed: String
        if temp.distanceMode == 90 {
            var chunks = chunkGCodeLine(line.original)
            var foundZ = false
            for chunk in chunks where chunk.first == "Z" {
                contour.previousZ = chunk
                foundZ = true
            }
            if foundZ {
                transformed = try contour.transformAbsoluteZ(line, at: target, wcs: wcs)
            } else {
                chunks.append(contour.previousZ)
                let withZ = GCodeLine(chunks.joined())
                var acc = accumulator
                acc.apply(withZ)
                transformed = try contour.transformAbsoluteZ(withZ, at: acc.position, wcs: wcs)
            }
        } else {
            transformed = try contour.transformRelativeZ(line, from: previous, to: target)
        }
        let transformedLine = GCodeLine(transformed)
        try write(transformedLine)
        accumulator.apply(transformedLine)
    }
}
