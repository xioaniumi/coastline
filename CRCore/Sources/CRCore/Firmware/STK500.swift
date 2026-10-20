import Foundation

/// An Intel HEX firmware image.
public struct IntelHex: Equatable, Sendable {
    /// Byte address → value.
    public private(set) var bytes: [Int: UInt8] = [:]

    public struct ParseError: Error, CustomStringConvertible {
        public let line: Int
        public let reason: String
        public var description: String { "Intel HEX line \(line): \(reason)" }
    }

    public init(bytes: [Int: UInt8]) {
        self.bytes = bytes
    }

    /// Parses record types 00 (data), 01 (EOF), 02 (extended segment), 04 (extended linear),
    /// verifying every checksum.
    public init(text: String) throws {
        var base = 0
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.first == ":" else { throw ParseError(line: index + 1, reason: "missing ':'") }
            let hex = Array(line.dropFirst())
            guard hex.count >= 10, hex.count % 2 == 0 else { throw ParseError(line: index + 1, reason: "bad length") }
            var record: [UInt8] = []
            for i in stride(from: 0, to: hex.count, by: 2) {
                guard let b = UInt8(String(hex[i...i + 1]), radix: 16) else { throw ParseError(line: index + 1, reason: "bad hex digit") }
                record.append(b)
            }
            let count = Int(record[0])
            guard record.count == count + 5 else { throw ParseError(line: index + 1, reason: "byte count mismatch") }
            guard record.reduce(0, { $0 &+ $1 }) == 0 else { throw ParseError(line: index + 1, reason: "checksum") }
            let address = Int(record[1]) << 8 | Int(record[2])
            let data = record[4..<(4 + count)]
            if record[3] == 0x02 || record[3] == 0x04, count != 2 {
                throw ParseError(line: index + 1, reason: "extended address record must have 2 data bytes")
            }
            switch record[3] {
            case 0x00:
                for (offset, byte) in data.enumerated() { bytes[base + address + offset] = byte }
            case 0x01:
                return
            case 0x02:
                base = (Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])) << 4
            case 0x04:
                base = (Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])) << 16
            case 0x03, 0x05:
                break // start address records: irrelevant for AVR flashing
            default:
                throw ParseError(line: index + 1, reason: "unknown record type \(record[3])")
            }
        }
    }

    public var isEmpty: Bool { bytes.isEmpty }
    public var highestAddress: Int { bytes.keys.max() ?? -1 }

    /// Pages (by start address) that contain data, filled with 0xFF where the image is empty.
    public func pages(size: Int) -> [(address: Int, data: [UInt8])] {
        let starts = Set(bytes.keys.map { $0 / size * size }).sorted()
        return starts.map { start in
            (start, (start..<(start + size)).map { bytes[$0] ?? 0xFF })
        }
    }
}

/// AVR target description (from the original's avrdude.conf).
public struct AVRDevice: Equatable, Sendable {
    public var name: String
    public var signature: [UInt8]
    public var flashSize: Int
    public var pageSize: Int
    public var eepromSize: Int
    public var deviceCode: UInt8
    /// First byte of the bootloader section, which must never be written over (nil = programmed
    /// over ISP, no bootloader to protect).
    public var bootloaderStart: Int?

    public static let atmega328p = AVRDevice(name: "ATmega328P", signature: [0x1E, 0x95, 0x0F],
                                             flashSize: 32768, pageSize: 128, eepromSize: 1024, deviceCode: 0x86,
                                             bootloaderStart: 0x7E00)
    public static let atmega32m1 = AVRDevice(name: "ATmega32M1", signature: [0x1E, 0x95, 0x84],
                                             flashSize: 32768, pageSize: 128, eepromSize: 1024, deviceCode: 0xA0,
                                             bootloaderStart: nil)
}

/// Serial access needed by the programmer.
public protocol ProgrammerPort: AnyObject {
    func open() throws
    func close()
    func write(_ bytes: [UInt8]) throws
    func readAvailable() -> [UInt8]
    func setModemLines(dtr: Bool, rts: Bool)
}

extension POSIXSerialPort: ProgrammerPort {}

public struct STK500Error: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// STK500v1 programmer, as used by `avrdude -c stk500v1` for the Arduino bootloader (328P at
/// 115200) and the ArduinoISP sketch (32M1 at 19200). Replaces the bundled x86_64 avrdude.
public final class STK500Programmer {
    enum Command {
        static let getSync: UInt8 = 0x30
        static let setDevice: UInt8 = 0x42
        static let setDeviceExt: UInt8 = 0x45
        static let enterProgmode: UInt8 = 0x50
        static let leaveProgmode: UInt8 = 0x51
        static let loadAddress: UInt8 = 0x55
        static let universal: UInt8 = 0x56
        static let progPage: UInt8 = 0x64
        static let readPage: UInt8 = 0x74
        static let readSign: UInt8 = 0x75
        static let eop: UInt8 = 0x20
        static let inSync: UInt8 = 0x14
        static let ok: UInt8 = 0x10
    }

    private let port: ProgrammerPort
    private var pending: [UInt8] = []
    var timeout: TimeInterval = 1.0
    /// Pause after the reset pulse (bootloader start-up).
    var resetDelay: TimeInterval = 0.05

    public init(port: ProgrammerPort) {
        self.port = port
    }

    /// Writes and verifies `image` on `device`. `progress` receives 0…1.
    public func program(_ image: IntelHex, device: AVRDevice, progress: (Double) -> Void = { _ in }) throws {
        guard !image.isEmpty else { throw STK500Error("The firmware file is empty.") }
        guard image.highestAddress < device.flashSize else { throw STK500Error("The firmware is larger than the \(device.name)'s flash.") }
        if let boot = device.bootloaderStart, image.highestAddress >= boot {
            // e.g. an Arduino "with_bootloader" export: writing it would erase the bootloader.
            throw STK500Error("This file would overwrite the \(device.name)'s bootloader. Use the firmware file without the bootloader.")
        }

        try port.open()
        defer { port.close() }
        resetBoard()
        try sync()

        // avrdude's order: initialize (incl. enter programming mode) → signature → erase.
        // ArduinoISP only talks to the target chip once programming mode has started.
        try initialize(device)
        let signature = try readSignature()
        guard signature == device.signature else {
            _ = try? command([Command.leaveProgmode])
            throw STK500Error(String(format: "Wrong chip: expected %@ signature %@, read %@.", device.name,
                                     hex(device.signature), hex(signature)))
        }

        try chipErase()
        try initialize(device)

        let pages = image.pages(size: device.pageSize)
        let total = Double(pages.count * 2)
        for (i, page) in pages.enumerated() {
            try loadAddress(page.address)
            try command([Command.progPage, UInt8(page.data.count >> 8), UInt8(page.data.count & 0xFF), 0x46] + page.data)
            progress(Double(i + 1) / total)
        }
        for (i, page) in pages.enumerated() {
            try loadAddress(page.address)
            let read = try command([Command.readPage, UInt8(page.data.count >> 8), UInt8(page.data.count & 0xFF), 0x46],
                                   responseBytes: page.data.count)
            guard read == page.data else {
                throw STK500Error(String(format: "Verification failed at address 0x%04X.", page.address))
            }
            progress(Double(pages.count + i + 1) / total)
        }
        _ = try command([Command.leaveProgmode])
    }

    // MARK: Protocol steps

    /// Pulse DTR/RTS low to reset the board into its bootloader (avrdude's arduino reset).
    func resetBoard() {
        port.setModemLines(dtr: false, rts: false)
        Thread.sleep(forTimeInterval: 0.25)
        port.setModemLines(dtr: true, rts: true)
        Thread.sleep(forTimeInterval: resetDelay)
        drain()
    }

    func sync() throws {
        for _ in 0..<10 {
            try port.write([Command.getSync, Command.eop])
            if let reply = try? read(2, timeout: 0.3), reply == [Command.inSync, Command.ok] {
                // Earlier attempts may still be answered late (e.g. ArduinoISP finishing setup):
                // wait for silence, then confirm with one more sync so no stale reply remains.
                drainUntilQuiet()
                try port.write([Command.getSync, Command.eop])
                if let confirm = try? read(2, timeout: 0.5), confirm == [Command.inSync, Command.ok] {
                    drainUntilQuiet(quiet: 0.05)
                    return
                }
            }
            drainUntilQuiet()
        }
        throw STK500Error("No response from the bootloader (could not sync). Check the USB connection and power.")
    }

    func readSignature() throws -> [UInt8] {
        try command([Command.readSign], responseBytes: 3)
    }

    func initialize(_ device: AVRDevice) throws {
        var params: [UInt8] = [
            device.deviceCode, 0, 0, 1, 1, 1, 1, 3,
            0xFF, 0xFF, 0xFF, 0xFF,
            UInt8(device.pageSize >> 8), UInt8(device.pageSize & 0xFF),
            UInt8(device.eepromSize >> 8), UInt8(device.eepromSize & 0xFF),
        ]
        params += [UInt8(device.flashSize >> 24 & 0xFF), UInt8(device.flashSize >> 16 & 0xFF),
                   UInt8(device.flashSize >> 8 & 0xFF), UInt8(device.flashSize & 0xFF)]
        _ = try command([Command.setDevice] + params)
        _ = try command([Command.setDeviceExt, 4, 4, 0xD7, 0xC2, 0])
        _ = try command([Command.enterProgmode])
    }

    func chipErase() throws {
        _ = try command([Command.universal, 0xAC, 0x80, 0x00, 0x00], responseBytes: 1)
        Thread.sleep(forTimeInterval: 0.02)
    }

    func loadAddress(_ byteAddress: Int) throws {
        let word = byteAddress / 2
        _ = try command([Command.loadAddress, UInt8(word & 0xFF), UInt8(word >> 8 & 0xFF)])
    }

    /// Sends `body` + EOP and expects INSYNC, `responseBytes` of data, OK.
    @discardableResult
    func command(_ body: [UInt8], responseBytes: Int = 0) throws -> [UInt8] {
        try port.write(body + [Command.eop])
        let first = try read(1, timeout: timeout)
        guard first == [Command.inSync] else {
            throw STK500Error(String(format: "Programmer out of sync (command 0x%02X, got 0x%02X).", body[0], first[0]))
        }
        let data = try read(responseBytes, timeout: timeout)
        let last = try read(1, timeout: timeout)
        guard last == [Command.ok] else {
            throw STK500Error(String(format: "Programmer rejected command 0x%02X.", body[0]))
        }
        return data
    }

    // MARK: I/O helpers

    private func read(_ count: Int, timeout: TimeInterval) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        while pending.count < count {
            pending += port.readAvailable()
            if pending.count >= count { break }
            if Date() > deadline { throw STK500Error("Timed out waiting for the programmer.") }
            usleep(1000)
        }
        let result = Array(pending.prefix(count))
        pending.removeFirst(count)
        return result
    }

    private func drain() {
        pending.removeAll()
        _ = port.readAvailable()
    }

    /// Discards input until the line has been silent for `quiet` seconds (avrdude's stk500_drain).
    private func drainUntilQuiet(quiet: TimeInterval = 0.25, maximum: TimeInterval = 2) {
        pending.removeAll()
        let end = Date().addingTimeInterval(maximum)
        var lastByte = Date()
        while Date() < end, Date().timeIntervalSince(lastByte) < quiet {
            if !port.readAvailable().isEmpty { lastByte = Date() }
            usleep(5000)
        }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/// Simulated Arduino bootloader / ArduinoISP speaking STK500v1, for tests.
public final class MockSTK500: ProgrammerPort, @unchecked Sendable {
    public private(set) var flash: [Int: UInt8] = [:]
    public var signature: [UInt8]
    public private(set) var erased = false
    private var input: [UInt8] = []
    private var output: [UInt8] = []
    private var address = 0
    private var inBootloader = false
    private var inProgmode = false
    /// ArduinoISP can only read the target's signature after ENTER_PROGMODE.
    public var requireProgmodeForSignature = true

    public init(signature: [UInt8] = AVRDevice.atmega328p.signature) {
        self.signature = signature
    }

    public func open() throws {}
    public func close() {}

    public func setModemLines(dtr: Bool, rts: Bool) {
        if dtr { inBootloader = true }
    }

    public func readAvailable() -> [UInt8] {
        defer { output.removeAll() }
        return output
    }

    public func write(_ bytes: [UInt8]) throws {
        input += bytes
        process()
    }

    private func process() {
        guard inBootloader else { input.removeAll(); return }
        while let eop = commandEnd() {
            let cmd = Array(input[..<eop])
            input.removeFirst(eop + 1)
            respond(cmd)
        }
    }

    /// Commands have known lengths; find where the current one ends (its EOP byte).
    private func commandEnd() -> Int? {
        guard let first = input.first else { return nil }
        let length: Int
        switch first {
        case 0x42: length = 21
        case 0x45: length = 6
        case 0x55: length = 3
        case 0x56: length = 5
        case 0x64, 0x74:
            guard input.count >= 3 else { return nil }
            let size = Int(input[1]) << 8 | Int(input[2])
            length = first == 0x64 ? 4 + size : 4
        default: length = 1
        }
        return input.count > length ? length : nil
    }

    private func respond(_ cmd: [UInt8]) {
        var reply: [UInt8] = [0x14]
        switch cmd[0] {
        case 0x50: inProgmode = true
        case 0x51: inProgmode = false
        case 0x75:
            guard inProgmode || !requireProgmodeForSignature else { return } // no reply: timeout
            reply += signature
        case 0x55: address = (Int(cmd[1]) | Int(cmd[2]) << 8) * 2
        case 0x56:
            erased = true
            flash.removeAll()
            reply.append(0)
        case 0x64:
            for (i, b) in cmd[4...].enumerated() { flash[address + i] = b }
        case 0x74:
            let size = Int(cmd[1]) << 8 | Int(cmd[2])
            reply += (0..<size).map { flash[address + $0] ?? 0xFF }
        default: break
        }
        output += reply + [0x10]
    }
}
