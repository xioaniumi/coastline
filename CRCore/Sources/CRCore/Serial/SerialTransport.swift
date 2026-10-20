import Foundation

/// Raw byte transport to the mill. Implemented by `POSIXSerialPort` for real hardware and by
/// `MockGRBL` for tests and the app's simulated-mill mode.
public protocol SerialTransport: AnyObject, Sendable {
    func open() throws
    func close()
    /// Writes all bytes or throws `MillError.failedWrite`.
    func write(_ bytes: [UInt8]) throws
    /// Returns and removes all bytes received so far (never blocks).
    func readAvailable() -> [UInt8]
    var isOpen: Bool { get }
}

/// A USB serial device that looks like a Coast Runner (`CNCMill` in the original).
public struct MillDevice: Hashable, Sendable, Identifiable {
    public var path: String
    public var serialNumber: String
    public var id: String { path + "#" + serialNumber }

    public init(path: String, serialNumber: String) {
        self.path = path
        self.serialNumber = serialNumber
    }
}
