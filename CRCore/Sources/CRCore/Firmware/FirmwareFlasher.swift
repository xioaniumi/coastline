import Foundation

/// Flashes CR-1 firmware from local `.hex` files. Port of `FirmwareManager::UpdateCustom` +
/// `MillDaemon::UploadCustomFirmware`, using the native `STK500Programmer` instead of avrdude.
///
/// Order (VFD boards with a 32M1 image):
/// 1. flash `ArduinoAsSPI.hex` into the 328P (turns it into an ISP programmer),
/// 2. flash the 32M1 through it at 19200 baud,
/// 3. flash the real 328P firmware,
/// then reconnect and reset EEPROM settings (`$RST=*`, `$90=96`, `$92=97`).
public final class FirmwareFlasher: @unchecked Sendable {
    public typealias PortFactory = (_ path: String, _ baud: Int) -> ProgrammerPort

    private let makePort: PortFactory
    private let log: MachineLog

    public init(log: MachineLog, makePort: @escaping PortFactory = { path, baud in
        POSIXSerialPort(path: path, baudRate: speed_t(baud))
    }) {
        self.log = log
        self.makePort = makePort
    }

    /// `progress` receives the original's status values: 5, 25, 40, 50, 75, 100 (and in between).
    public func flash(connection: MillConnection, firmware328p: IntelHex, firmware32m1: IntelHex?,
                      arduinoAsSPI: IntelHex, progress: @escaping (Int) -> Void) throws {
        // Confirms the mill answers (e-stop not pressed) and tells us whether there's a VFD board.
        let version = try connection.firmwareVersion()
        progress(5)
        if connection.isConnected {
            _ = try? connection.reset()
            connection.disconnect()
        }
        let path = connection.device.path

        do {
            if let firmware32m1, version?.vfd != "00" {
                progress(25)
                try program(arduinoAsSPI, device: .atmega328p, path: path, baud: 115_200) { progress(25 + Int($0 * 25)) }
                progress(50)
                try program(firmware32m1, device: .atmega32m1, path: path, baud: 19_200) { progress(50 + Int($0 * 25)) }
                progress(75)
            } else {
                progress(40)
            }
        } catch {
            // Restore a working 328P before reporting. (The original flashed the 32M1 file here.)
            log.add(.read, "Failed while updating 32m1. Attempting to install 328p firmware.")
            try? program(firmware328p, device: .atmega328p, path: path, baud: 115_200) { _ in }
            throw error
        }

        try program(firmware328p, device: .atmega328p, path: path, baud: 115_200) { progress(75 + Int($0 * 24)) }
        progress(100)
        log.add(.read, "Upload status: 100%")

        // Reconnect and restore EEPROM data used by GRBL.
        Thread.sleep(forTimeInterval: 1)
        try connection.reconnect()
        try connection.executeCommand(GCodeLine("$RST=*"))
        try connection.executeCommand(GCodeLine("$90=96"))
        try connection.executeCommand(GCodeLine("$92=97"))
    }

    /// Two attempts per chip, like the original.
    private func program(_ image: IntelHex, device: AVRDevice, path: String, baud: Int,
                         progress: @escaping (Double) -> Void) throws {
        var lastError: Error?
        for attempt in 1...2 {
            do {
                log.add(.write, "Programming \(device.name) (attempt \(attempt))…")
                try STK500Programmer(port: makePort(path, baud)).program(image, device: device, progress: progress)
                log.add(.read, "\(device.name) programmed and verified.")
                return
            } catch {
                lastError = error
                log.add(.error, "\(device.name): \(error)")
            }
        }
        throw lastError ?? STK500Error("Programming failed.")
    }
}

extension MillConnection {
    /// `Reconnect`: close and re-open the port, waiting for the GRBL banner again.
    public func reconnect() throws {
        if state.isConnected { disconnect() }
        try connect()
    }
}
