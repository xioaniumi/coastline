import Foundation

/// A simulated Coast Runner controller (grblCR 1.1g) behind the `SerialTransport` interface.
/// Used by the self-tests and by the app's "simulated mill" mode.
///
/// Lines are queued in a 128-byte receive buffer, as on the real controller, and acknowledged
/// when the host polls (`readAvailable`), `linesPerPoll` at a time. `maxRxUsed`/`overflowed`
/// let tests verify the host's character-counting flow control.
public final class MockGRBL: SerialTransport, @unchecked Sendable {
    public struct Options: Sendable {
        public var startLocked = false
        /// Lines acknowledged per host poll (1 = slow controller, large = instant).
        public var linesPerPoll = Int.max
        /// Return `"error:N"` (or any reply) for a line instead of `ok`.
        public var replyOverride: (@Sendable (String) -> String?)?
        /// Probe result: `nil` → ALARM:5 (no contact).
        public var probeContactZ: Double? = -10
        public var softLimitTravel = Point3(x: 86, y: 241.5, z: 78.5)
        public var firmwareInfo = "[grbl:1.1g CR:3A PCB:3B VFD:3A YMD:20240318]"
        public init() {}
    }

    public static let rxBufferSize = 128

    private struct State {
        var open = false
        var output: [UInt8] = []
        var partialLine: [UInt8] = []
        var rxQueue: [String] = []
        var rxUsed = 0
        var maxRxUsed = 0
        var overflowed = false
        var silent = false
        var alarm = false
        var hold = false
        var position = Point3(x: -86, y: -0.5, z: -0.5)
        var offsets: [Int: Point3] = Dictionary(uniqueKeysWithValues: (54...59).map { ($0, Point3.zero) })
        var wcs = 54
        var absolute = true
        var inches = false
        var received: [String] = []
        var realtime: [UInt8] = []
        var pendingAtArrival: [String: Int] = [:]
        var statusCount = 0
        /// Opening the port resets the Arduino; the banner appears after a short boot delay.
        var bootAt: TimeInterval?
    }

    public var options: Options
    private let state = Locked(State())

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: Test hooks

    /// Every complete line received, in order (as sent, without newline).
    public var receivedLines: [String] { state.withLock { $0.received } }
    /// Real-time bytes received.
    public var realtimeBytes: [UInt8] { state.withLock { $0.realtime } }
    public var maxRxUsed: Int { state.withLock { $0.maxRxUsed } }
    public var overflowed: Bool { state.withLock { $0.overflowed } }
    public var position: Point3 { state.withLock { $0.position } }
    /// Simulates the hardware e-stop: the controller stops answering.
    public var silent: Bool {
        get { state.withLock { $0.silent } }
        set { state.withLock { $0.silent = newValue } }
    }
    public func setOffset(_ wcs: Int, _ point: Point3) { state.withLock { $0.offsets[wcs] = point } }
    public func offset(_ wcs: Int) -> Point3 { state.withLock { $0.offsets[wcs] ?? .zero } }
    public func setPosition(_ point: Point3) { state.withLock { $0.position = point } }
    /// How many lines were still queued (unacknowledged) when `line` arrived (first occurrence).
    public func pendingLines(whenReceived line: String) -> Int? { state.withLock { $0.pendingAtArrival[line] } }

    // MARK: SerialTransport

    public var isOpen: Bool { state.withLock { $0.open } }

    public func open() throws {
        state.withLock { s in
            s.open = true
            s.output.removeAll()
            s.rxQueue.removeAll()
            s.rxUsed = 0
            s.bootAt = monotonicNow() + 0.2
        }
    }

    public func close() { state.withLock { $0.open = false } }

    public func write(_ bytes: [UInt8]) throws {
        guard isOpen else { throw MillError(.failedWrite) }
        for byte in bytes { receive(byte) }
    }

    public func readAvailable() -> [UInt8] {
        let shouldBoot: Bool = state.withLock { s in
            guard let at = s.bootAt, monotonicNow() >= at else { return false }
            s.bootAt = nil
            return true
        }
        if shouldBoot { boot() }
        process(limit: options.linesPerPoll)
        return state.withLock { s in
            defer { s.output.removeAll() }
            return s.output
        }
    }

    // MARK: Controller behaviour

    private func emit(_ line: String) {
        state.withLock { s in
            guard !s.silent else { return }
            s.output.append(contentsOf: Array((line + "\r\n").utf8))
        }
    }

    private func boot() {
        state.withLock { s in
            s.rxQueue.removeAll()
            s.rxUsed = 0
            s.hold = false
            s.alarm = options.startLocked
        }
        emit("")
        emit("Grbl 1.1g ['$' for help]")
        if options.startLocked { emit("[MSG:'$H'|'$X' to unlock]") }
    }

    private func receive(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "?"):
            state.withLock { $0.realtime.append(byte) }
            emit(statusReport())
        case UInt8(ascii: "!"):
            state.withLock { $0.realtime.append(byte); $0.hold = true }
        case UInt8(ascii: "~"):
            state.withLock { $0.realtime.append(byte); $0.hold = false }
        case 0x18:
            state.withLock { $0.realtime.append(byte) }
            boot()
        case 0x85, UInt8(ascii: "|"):
            state.withLock { $0.realtime.append(byte) }
        case UInt8(ascii: "\n"):
            state.withLock { s in
                let line = String(decoding: s.partialLine, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
                s.partialLine.removeAll()
                s.received.append(line)
                if s.pendingAtArrival[line] == nil { s.pendingAtArrival[line] = s.rxQueue.count }
                s.rxUsed += line.utf8.count + 1
                s.maxRxUsed = max(s.maxRxUsed, s.rxUsed)
                if s.rxUsed > Self.rxBufferSize { s.overflowed = true }
                s.rxQueue.append(line)
            }
        default:
            state.withLock { $0.partialLine.append(byte) }
        }
    }

    private func process(limit: Int) {
        var handled = 0
        while handled < limit {
            let next: String? = state.withLock { s in
                guard !s.silent, !s.hold, !s.rxQueue.isEmpty else { return nil }
                let line = s.rxQueue.removeFirst()
                s.rxUsed -= line.utf8.count + 1
                return line
            }
            guard let line = next else { return }
            execute(line)
            handled += 1
        }
    }

    func statusReport() -> String {
        state.withLock { s in
            s.statusCount += 1
            let state = s.alarm ? "Alarm" : (s.hold ? "Hold:0" : "Idle")
            let p = s.position
            let w = s.offsets[s.wcs] ?? .zero
            let fmt = { (v: Double) in String(format: "%.3f", v) }
            var report = "<\(state)|M:\(fmt(p.x)),\(fmt(p.y)),\(fmt(p.z))|B:15,\(Self.rxBufferSize - s.rxUsed)|L:0|0000"
            // Like GRBL, only include the work offset every few reports.
            if s.statusCount % 3 == 1 { report += "|W:\(fmt(w.x)),\(fmt(w.y)),\(fmt(w.z))" }
            return report + ">"
        }
    }

    private func execute(_ raw: String) {
        let line = raw.filter { !$0.isWhitespace }.uppercased()
        if let reply = options.replyOverride?(raw) {
            emit(reply)
            return
        }
        if line.isEmpty { emit("ok"); return }

        if line.hasPrefix("$") {
            executeSystem(line)
            return
        }
        if state.withLock({ $0.alarm }) {
            emit("error:9")
            return
        }
        executeGCode(line)
    }

    private func executeSystem(_ line: String) {
        switch line {
        case "$$":
            let t = options.softLimitTravel
            for (k, v) in [(13, 0.0), (20, 1), (22, 1), (130, t.x), (131, t.y), (132, t.z)] {
                emit("$\(k)=\(String(format: "%.3f", v))")
            }
            emit("ok")
        case "$#":
            let offsets = state.withLock { $0.offsets }
            for n in 54...59 {
                let p = offsets[n] ?? .zero
                emit(String(format: "[G%d:%.3f,%.3f,%.3f]", n, p.x, p.y, p.z))
            }
            emit("[G28:0.000,0.000,0.000]")
            emit("[G30:0.000,0.000,0.000]")
            emit("[G92:0.000,0.000,0.000]")
            emit("[TLO:0.000]")
            emit("[PRB:0.000,0.000,0.000:0]")
            emit("ok")
        case "$G":
            let (wcs, absolute, inches) = state.withLock { ($0.wcs, $0.absolute, $0.inches) }
            emit("[GC:G0 G\(wcs) G17 \(inches ? "G20" : "G21") \(absolute ? "G90" : "G91") G94 M5 M9 T0 F0 S0]")
            emit("ok")
        case "$I":
            emit(options.firmwareInfo)
            emit("ok")
        case "$X":
            state.withLock { $0.alarm = false }
            emit("[MSG:Caution: Unlocked]")
            emit("ok")
        case "$H", "$HZ", "$HX", "$HY":
            state.withLock { s in
                s.alarm = false
                if line == "$H" { s.position = Point3(x: -86, y: -0.5, z: -0.5) }
                if line == "$HZ" { s.position.z = -0.5 }
                if line == "$HX" { s.position.x = -86 }
            }
            emit("ok")
        default:
            if line.hasPrefix("$J=") {
                jog(String(line.dropFirst(3)))
            } else if line.hasPrefix("$RST") {
                if line == "$RST=#" { state.withLock { s in for k in s.offsets.keys { s.offsets[k] = .zero } } }
                emit("ok")
            } else {
                emit("ok")
            }
        }
    }

    private func words(_ line: String) -> [(Character, Double)] {
        var result: [(Character, Double)] = []
        var letter: Character?
        var number = ""
        func flush() {
            if let l = letter, let v = Double(number) { result.append((l, v)) }
        }
        for c in line {
            if c.isLetter {
                flush()
                letter = c
                number = ""
            } else {
                number.append(c)
            }
        }
        flush()
        return result
    }

    private func jog(_ body: String) {
        let w = words(body)
        state.withLock { s in
            let scale = w.contains(where: { $0.0 == "G" && $0.1 == 20 }) ? 25.4 : 1
            for (letter, value) in w {
                guard let axis = Axis(letter: letter) else { continue }
                s.position[axis] += value * scale
            }
        }
        emit("ok")
    }

    private func executeGCode(_ line: String) {
        let w = words(line)
        let gCodes = w.filter { $0.0 == "G" }.map(\.1)

        if gCodes.contains(10) {
            // G10 L2 Pn X Y Z — set WCS n
            if let p = w.first(where: { $0.0 == "P" })?.1 {
                state.withLock { s in
                    let wcs = 53 + Int(p)
                    var point = s.offsets[wcs] ?? .zero
                    for (letter, value) in w { if let axis = Axis(letter: letter) { point[axis] = value } }
                    s.offsets[wcs] = point
                }
            }
            emit("ok")
            return
        }
        if gCodes.contains(where: { abs($0 - 38.2) < 0.01 }) {
            guard let z = options.probeContactZ else {
                state.withLock { $0.alarm = true }
                emit("ALARM:5")
                return
            }
            let p: Point3 = state.withLock { s in
                s.position.z = z
                return s.position
            }
            emit(String(format: "[PRB:%.3f,%.3f,%.3f:1]", p.x, p.y, p.z))
            emit("ok")
            return
        }

        state.withLock { s in
            var machineCoordinates = false
            for g in gCodes {
                switch g {
                case 20: s.inches = true
                case 21: s.inches = false
                case 90: s.absolute = true
                case 91: s.absolute = false
                case 53: machineCoordinates = true
                case 54...59: s.wcs = Int(g)
                default: break
                }
            }
            let offset = machineCoordinates ? .zero : (s.offsets[s.wcs] ?? .zero)
            let scale = s.inches ? 25.4 : 1
            for (letter, value) in w {
                guard let axis = Axis(letter: letter) else { continue }
                s.position[axis] = s.absolute ? value * scale + offset[axis] : s.position[axis] + value * scale
            }
        }
        emit("ok")
    }
}
