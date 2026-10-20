import Foundation
import ZIPFoundation

public enum ProjectError: Error, Equatable, CustomStringConvertible, Sendable {
    case fileNotFound(String)
    case notFoundInArchive(String)
    case badManifest(String)
    case yaml(YAMLParseError, file: String)

    public var description: String {
        switch self {
        case .fileNotFound(let path): "File not found: \(path)"
        case .notFoundInArchive(let path): "File not found in archive: \(path)"
        case .badManifest(let reason): "Bad manifest: \(reason)"
        case .yaml(let error, let file): "\(file): \(error)"
        }
    }
}

/// Read access to the files inside a project. Paths are zip entry paths such as `Code/op1.nc`.
public protocol ProjectFileSource: Sendable {
    /// Returns the canonical entry path for `path`, or nil when it does not exist.
    func resolve(_ path: String) -> String?
    func data(at path: String) throws -> Data
    var entryPaths: [String] { get }
}

extension ProjectFileSource {
    public func contains(_ path: String) -> Bool { resolve(path) != nil }

    public func lines(at path: String) throws -> [String] {
        YAMLSubset.lines(from: try data(at: path))
    }
}

/// Entry lookup shared by all sources. The original used minizip's `unzLocateFile(..., 0)`, which
/// is case-insensitive on macOS/Windows, and real projects depend on that (e.g. a manifest
/// referencing `Manifests/Mill Op 1.yml` for an entry stored as `Manifests/mill Op 1.yml`).
/// Backslash separators (Windows-authored manifests) are also accepted.
struct EntryIndex: Sendable {
    private let exact: Set<String>
    private let folded: [String: String]
    let paths: [String]

    init(paths: [String]) {
        self.paths = paths
        exact = Set(paths)
        var folded: [String: String] = [:]
        for path in paths where folded[Self.fold(path)] == nil {
            folded[Self.fold(path)] = path
        }
        self.folded = folded
    }

    func resolve(_ path: String) -> String? {
        if exact.contains(path) { return path }
        return folded[Self.fold(path)]
    }

    private static func fold(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").lowercased()
    }
}

/// A `.crproj` file on disk (a zip archive).
public final class ZipProjectSource: ProjectFileSource, @unchecked Sendable {
    public let url: URL
    private let index: EntryIndex
    private let lock = NSLock()
    private let archive: Archive
    private let entries: [String: Entry]

    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectError.fileNotFound(url.path)
        }
        self.url = url
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ProjectError.fileNotFound(url.path)
        }
        // The original's minizip stored UTF-8 names without the UTF-8 flag; ZIPFoundation would
        // read those as CP437. Prefer UTF-8 when the bytes are valid UTF-8.
        var entries: [String: Entry] = [:]
        var paths: [String] = []
        for entry in archive {
            let utf8 = entry.path(using: .utf8)
            let name = utf8.isEmpty ? entry.path : utf8
            entries[name] = entry
            paths.append(name)
        }
        self.entries = entries
        index = EntryIndex(paths: paths)
    }

    public var entryPaths: [String] { index.paths }

    public func resolve(_ path: String) -> String? { index.resolve(path) }

    public func data(at path: String) throws -> Data {
        guard let resolved = index.resolve(path) else { throw ProjectError.notFoundInArchive(path) }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[resolved] else { throw ProjectError.notFoundInArchive(path) }
        var data = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
        } catch {
            throw ProjectError.notFoundInArchive(path)
        }
        return data
    }
}

/// In-memory project files, used by tests and by the editor before saving.
public struct MemoryProjectSource: ProjectFileSource {
    private let files: [String: Data]
    private let index: EntryIndex

    public init(_ files: [String: Data]) {
        self.files = files
        index = EntryIndex(paths: files.keys.sorted())
    }

    public init(text files: [String: String]) {
        self.init(files.mapValues { Data($0.utf8) })
    }

    public var entryPaths: [String] { index.paths }
    public func resolve(_ path: String) -> String? { index.resolve(path) }

    public func data(at path: String) throws -> Data {
        guard let resolved = index.resolve(path), let data = files[resolved] else {
            throw ProjectError.notFoundInArchive(path)
        }
        return data
    }
}
