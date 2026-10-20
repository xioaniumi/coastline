import Foundation

/// The "Machine Output" log: lines read from / written to the mill plus errors.
/// Port of `MillDisplayManager`. The UI drains it periodically.
public final class MachineLog: @unchecked Sendable {
    public enum Kind: String, Sendable { case read = "READ", write = "WRITE", error = "ERROR" }
    public struct Entry: Equatable, Sendable {
        public var kind: Kind
        public var text: String
    }

    private let entries = Locked<[Entry]>([])

    public init() {}

    public func add(_ kind: Kind, _ text: String) {
        entries.withLock { $0.append(Entry(kind: kind, text: text)) }
    }

    /// Returns and clears pending entries (`GetLines`).
    public func drain() -> [Entry] {
        entries.withLock { e in
            defer { e.removeAll() }
            return e
        }
    }

    public func clear() { entries.withLock { $0.removeAll() } }
}

/// Line-oriented access to the mill over a `SerialTransport`.
/// Port of `SerialConnection` (`src/Mill/GRBL/SerialConnection.cpp`).
final class SerialConnection: @unchecked Sendable {
    let transport: SerialTransport
    private let state: ConnectionState
    private let log: MachineLog
    /// Recursive, like the original's connection mutex, so compound operations can nest.
    let lock = NSRecursiveLock()
    private var pending: [UInt8] = []
    private var readBuffer: [UInt8] = []
    private var showStatus = false

    init(transport: SerialTransport, state: ConnectionState, log: MachineLog) {
        self.transport = transport
        self.state = state
        self.log = log
    }

    func connect() throws {
        lock.withLock {
            pending.removeAll()
            readBuffer.removeAll()
        }
        try transport.open()
    }

    func disconnect() {
        transport.close()
    }

    /// Sends one byte (real-time commands like `?`, `!`, `~`, 0x18, 0x85), then optionally waits.
    /// Real-time bytes bypass the line lock (GRBL accepts them mid-line), so an e-stop or feed
    /// hold is never delayed behind a long `$#`/`$I` exchange.
    func writeChar(_ byte: UInt8, waitMilliseconds: Int = 0) throws {
        try transport.write([byte])
        sleep(milliseconds: waitMilliseconds)
    }

    /// Sends `line` + `\n`, logging it unless the most recent buffered line was injected.
    func writeLine(_ line: String, waitMilliseconds: Int = 0) throws {
        let back = state.bufferBack
        if back == nil || back?.isInjected == false {
            log.add(.write, line)
            if line.contains("?") { lock.withLock { showStatus = true } }
        }
        try lock.withLock { try transport.write(Array((line + "\n").utf8)) }
        sleep(milliseconds: waitMilliseconds)
    }

    /// Returns the next complete line (without `\r\n`), or nil if none is available yet.
    func readLine() -> String? {
        lock.withLock {
            pending.append(contentsOf: transport.readAvailable())
            var index = 0
            defer { pending.removeFirst(index) }
            while index < pending.count {
                let byte = pending[index]
                index += 1
                state.resetIdleTime()
                if byte == UInt8(ascii: "\n") {
                    let line = String(decoding: readBuffer, as: UTF8.self)
                    readBuffer.removeAll()
                    let front = state.bufferFront
                    if front == nil || front?.isInjected == false {
                        if !line.hasPrefix("<") {
                            log.add(.read, line)
                        } else if showStatus {
                            log.add(.read, line)
                            showStatus = false
                        }
                    }
                    return line
                } else if byte != UInt8(ascii: "\r") {
                    readBuffer.append(byte)
                }
            }
            return nil
        }
    }

    /// Discards everything received so far.
    func flushReads() {
        lock.withLock {
            pending.removeAll()
            _ = transport.readAvailable()
        }
    }
}
