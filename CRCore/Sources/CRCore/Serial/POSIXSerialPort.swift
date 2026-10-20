import Foundation
import Darwin

/// A serial port opened with termios. Replaces the Boost.Asio port in `SerialConnection.cpp`:
/// a background read source fills a byte queue; writes are synchronous.
public final class POSIXSerialPort: SerialTransport, @unchecked Sendable {
    public let path: String
    public let baudRate: speed_t

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var received: [UInt8] = []
    private let queue = DispatchQueue(label: "crwrite.serial.read")

    public init(path: String, baudRate: speed_t = 115_200) {
        self.path = path
        self.baudRate = baudRate
    }

    deinit { close() }

    public var isOpen: Bool { lock.withLock { fd >= 0 } }

    public func open() throws {
        close()
        // The previous owner's fd may still be closing (cancel handlers run asynchronously); retry
        // briefly on EBUSY rather than failing an immediate reopen (e.g. between firmware steps).
        var handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        var attempts = 0
        while handle < 0, errno == EBUSY, attempts < 20 {
            usleep(50_000)
            attempts += 1
            handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        }
        guard handle >= 0 else { throw MillError(.failedOpen, "failed to open - \(path)") }
        // Exclusive access: a second opener (another app or a stale port object) would steal bytes.
        if ioctl(handle, TIOCEXCL) != 0 {
            Darwin.close(handle)
            throw MillError(.failedOpen, "\(path) is in use by another program")
        }

        var options = termios()
        guard tcgetattr(handle, &options) == 0 else {
            Darwin.close(handle)
            throw MillError(.failedSet)
        }
        cfmakeraw(&options)
        cfsetispeed(&options, baudRate)
        cfsetospeed(&options, baudRate)
        options.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        // Reads return immediately with whatever is available.
        withUnsafeMutableBytes(of: &options.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 0
        }
        guard tcsetattr(handle, TCSANOW, &options) == 0 else {
            Darwin.close(handle)
            throw MillError(.failedSet)
        }
        // Back to blocking mode for writes; VMIN/VTIME keep reads non-blocking.
        _ = fcntl(handle, F_SETFL, fcntl(handle, F_GETFL) & ~O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: handle, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(handle) }
        source.setCancelHandler { Darwin.close(handle) }

        lock.withLock {
            fd = handle
            received.removeAll()
            readSource = source
        }
        source.resume()
    }

    public func close() {
        let source: DispatchSourceRead? = lock.withLock {
            let s = readSource
            // Release exclusivity now; the fd itself is closed by the source's cancel handler.
            if fd >= 0 { _ = ioctl(fd, TIOCNXCL) }
            readSource = nil
            fd = -1
            received.removeAll()
            return s
        }
        source?.cancel()
    }

    /// Writes while holding the lock so the fd can't be closed (and its number reused) mid-write.
    public func write(_ bytes: [UInt8]) throws {
        try lock.withLock {
            guard fd >= 0 else { throw MillError(.failedWrite) }
            var offset = 0
            while offset < bytes.count {
                let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw MillError(.failedWrite)
                }
                offset += n
            }
        }
    }

    public func readAvailable() -> [UInt8] {
        lock.withLock {
            let bytes = received
            received.removeAll(keepingCapacity: true)
            return bytes
        }
    }

    /// Sets or clears DTR/RTS (used to reset the board before flashing firmware).
    public func setModemLines(dtr: Bool, rts: Bool) {
        let handle = lock.withLock { fd }
        guard handle >= 0 else { return }
        var bits: Int32 = 0
        _ = ioctl(handle, TIOCMGET, &bits)
        if dtr { bits |= TIOCM_DTR } else { bits &= ~TIOCM_DTR }
        if rts { bits |= TIOCM_RTS } else { bits &= ~TIOCM_RTS }
        _ = ioctl(handle, TIOCMSET, &bits)
    }

    /// Discards unread input in the OS buffer and in our queue.
    public func discardInput() {
        let handle = lock.withLock { fd }
        if handle >= 0 { tcflush(handle, TCIFLUSH) }
        _ = readAvailable()
    }

    private func drain(_ handle: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(handle, $0.baseAddress, $0.count) }
        if n > 0 {
            lock.withLock { received.append(contentsOf: buffer[0..<n]) }
        } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
            // Device unplugged: stop reading (cancelling closes the fd). PortFinder polling
            // reports the disconnect to the rest of the app; writes now fail with failedWrite.
            let source: DispatchSourceRead? = lock.withLock {
                let s = readSource
                readSource = nil
                fd = -1
                return s
            }
            source?.cancel()
        }
    }
}
