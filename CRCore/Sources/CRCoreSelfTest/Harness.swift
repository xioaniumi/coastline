import Foundation

/// Minimal test harness (see Package.swift for why this isn't XCTest).
struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

struct TestCase: Sendable {
    let name: String
    let body: @Sendable () throws -> Void
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
            file: StaticString = #fileID, line: UInt = #line) throws {
    if try !condition() {
        throw TestFailure(description: "\(file):\(line) expectation failed \(message())")
    }
}

func expectEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                               _ message: @autoclosure () -> String = "",
                               file: StaticString = #fileID, line: UInt = #line) throws {
    let (x, y) = (try a(), try b())
    if x != y {
        throw TestFailure(description: "\(file):\(line) expected \(String(reflecting: y)), got \(String(reflecting: x)) \(message())")
    }
}

func expectThrows(_ body: () throws -> Void, file: StaticString = #fileID, line: UInt = #line) throws {
    do {
        try body()
    } catch {
        return
    }
    throw TestFailure(description: "\(file):\(line) expected an error")
}

/// Repository root, derived from this source file's location.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // CRCoreSelfTest
    .deletingLastPathComponent() // Sources
    .deletingLastPathComponent() // CRCore
    .deletingLastPathComponent() // repo root

struct Skip: Error {
    let reason: String
}
