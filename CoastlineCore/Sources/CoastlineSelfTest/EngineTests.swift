import CoastlineCore
import Foundation

private func engine() throws -> EngineClient {
    let python = repoRoot.appendingPathComponent("engine/.venv/bin/python")
    guard FileManager.default.fileExists(atPath: python.path) else {
        throw Skip(reason: "engine venv missing; run `cd engine && uv sync`")
    }
    return try EngineClient.development(repoRoot: repoRoot)
}

/// Runs an async body from the synchronous test harness.
private func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.value!.get()
}

private final class ResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }

let engineTests: [TestCase] = [
    TestCase(name: "pingReportsVersions") {
        let e = try engine()
        let r = try blocking { try await e.call("ping") }
        try expectEqual(r.result["engine"] as? String, "0.1.0")
    },
    TestCase(name: "importStepReturnsMeshInMillimetres") {
        let e = try engine()
        let url = repoRoot.appendingPathComponent("resources/fixtures/universal_clamp_v96.step")
        let mesh = try blocking { try await e.importPart(url) }
        try expect(mesh.exact && mesh.triangleCount > 1000)
        try expectEqual(mesh.normals.count, mesh.vertices.count)
        try expect(mesh.indices.allSatisfy { Int($0) < mesh.vertexCount })
        let size = [mesh.size.x, mesh.size.y, mesh.size.z].sorted()
        try expect(abs(size[0] - 19.1) < 0.5 && abs(size[2] - 80.6) < 0.5, "clamp size \(size)")
    },
    TestCase(name: "engineErrorsAreThrownAndEngineSurvives") {
        let e = try engine()
        try expectThrows { _ = try blocking { try await e.importPart(URL(fileURLWithPath: "/nope.obj")) } }
        let r = try blocking { try await e.call("ping") }
        try expect(r.result["engine"] != nil)
    },
    TestCase(name: "exactMeasuringThroughTheClient") {
        let e = try engine()
        let url = repoRoot.appendingPathComponent("resources/samples/pendant.step")
        let mesh = try blocking { try await e.importPart(url) }
        try expect(!mesh.partID.isEmpty)
        // Just outside the pendant's rim (R 15) and on the bail hole (R 1.2).
        let rim = try blocking { try await e.faceInfo(partID: mesh.partID, point: Vec3(0, -15.2, 2)) }
        try expectEqual(rim.type, "cylinder")
        try expect(abs((rim.radius ?? 0) - 15) < 1e-6, "rim radius \(String(describing: rim.radius))")
        let hole = try blocking { try await e.faceInfo(partID: mesh.partID, point: Vec3(0, 12.69, 2)) }
        try expect(abs((hole.radius ?? 0) - 1.2) < 1e-6)
        try expect(hole.summary.contains("2.4") || hole.summary.contains("2,4"))
    },
    TestCase(name: "rhinoFileImportsExactly") {
        let e = try engine()
        let mesh = try blocking { try await e.importPart(repoRoot.appendingPathComponent("resources/samples/ring_blank.3dm")) }
        try expect(mesh.exact, "3dm should be exact NURBS")
        try expect(abs(mesh.size.x - 21) < 1e-3 && abs(mesh.size.z - 13) < 1e-3, "\(mesh.size)")
    },
]
