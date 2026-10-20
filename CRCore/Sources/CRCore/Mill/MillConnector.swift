import Foundation

/// Connection status shown in the toolbar (`ECNCMillStatus`: -1/0/1/2 in the original).
public enum ConnectionStatus: Int, Sendable {
    case failed = -1
    case notConnected = 0
    case connecting = 1
    case connected = 2
}

/// Finds a mill, connects automatically, and notices when it is unplugged.
/// Port of `MillConnector` (`src/Mill/MillConnector.cpp`).
public final class MillConnector: @unchecked Sendable {
    public typealias DeviceSource = @Sendable () -> [MillDevice]
    public typealias TransportFactory = @Sendable (MillDevice) -> SerialTransport

    private struct Values {
        var connection: MillConnection?
        var status = ConnectionStatus.notConnected
        var shutdown = false
        /// Monitoring paused (firmware flashing owns the port).
        var suspended = false
    }
    private let values = Locked(Values())
    private let deviceSource: DeviceSource
    private let makeTransport: TransportFactory
    private let log: MachineLog
    private let isManualOperation: @Sendable () -> Bool
    private let enableLS: @Sendable () -> Bool
    private let connectLock = NSLock()

    public init(log: MachineLog,
                deviceSource: @escaping DeviceSource = { PortFinder.availableMills() },
                makeTransport: @escaping TransportFactory = { POSIXSerialPort(path: $0.path) },
                isManualOperation: @escaping @Sendable () -> Bool = { false },
                enableLS: @escaping @Sendable () -> Bool = { false }) {
        self.log = log
        self.deviceSource = deviceSource
        self.makeTransport = makeTransport
        self.isManualOperation = isManualOperation
        self.enableLS = enableLS
    }

    public var status: ConnectionStatus { values.withLock { $0.status } }
    public var connection: MillConnection? { values.withLock { $0.connection } }

    /// Starts the 200 ms connect/unplug polling loop (`Thread_Connect`).
    public func start() {
        let thread = Thread { [weak self] in
            while let self, !self.values.withLock({ $0.shutdown }) {
                if !self.values.withLock({ $0.suspended }) {
                    if self.status != .connected { self.tryConnect() }
                    if self.status == .connected { self.checkUnplugged() }
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        thread.name = "CONNECT_THREAD"
        thread.start()
    }

    public func shutdown() {
        values.withLock { $0.shutdown = true }
        if let connection, connection.isConnected {
            _ = try? connection.reset(sendSoftReset: false)
            connection.disconnect()
        }
    }

    public func availableMills() -> [MillDevice] { deviceSource() }

    /// Pause/resume auto-connect and unplug detection (used while flashing firmware).
    public func setSuspended(_ suspended: Bool) {
        values.withLock { $0.suspended = suspended }
    }

    private func tryConnect() {
        guard let first = deviceSource().first else { return }
        if connection?.device != first { _ = select(first) }
    }

    private func checkUnplugged() {
        guard let connection else { return }
        // A brief USB drop can re-enumerate under the same path within one poll; the port we hold
        // is dead then, so also check the connection itself.
        let stillListed = deviceSource().contains(where: { $0.path == connection.device.path })
        if stillListed, connection.isConnected, connection.isTransportOpen { return }
        log.add(.error, stillListed ? "Lost the connection to \(connection.device.path); reconnecting."
                                    : "Coast Runner \(connection.device.path) unplugged")
        values.withLock {
            $0.status = .notConnected
            $0.connection = nil
        }
        connection.disconnect()
    }

    /// `SetSelectedCNCMill`.
    @discardableResult
    public func select(_ device: MillDevice) -> Bool {
        connectLock.withLock {
            guard connection?.device != device else { return false }
            values.withLock { if $0.status != .failed { $0.status = .connecting } }
            do {
                let connection = try MillConnection.connect(
                    device: device, transport: makeTransport(device), log: log,
                    isManualOperation: isManualOperation, enableLS: enableLS)
                values.withLock {
                    $0.connection = connection
                    $0.status = .connected
                }
                return true
            } catch let error as MillError {
                // A freshly plugged-in device may not open yet; keep trying.
                values.withLock { $0.status = error.kind == .failedOpen ? .connecting : .failed }
            } catch {
                values.withLock { $0.status = .failed }
            }
            return false
        }
    }
}
