import Foundation
@testable import CRCore

private let device = MillDevice(path: "/dev/mock", serialNumber: "MOCK")

private func connect(_ mock: MockGRBL, manual: Bool = false) throws -> MillConnection {
    try MillConnection.connect(device: device, transport: mock, log: MachineLog(), isManualOperation: { manual })
}

private func program(_ text: String) -> [GCodeLine] {
    GCodeProgram(source: text.components(separatedBy: "\n")).lines
}

let grblTests: [TestCase] = [
    TestCase(name: "statusParsingCRFormat") {
        let s = try RealTimeStatus.parse("<Idle|M:-86.000,-0.500,-1.250|B:15,127|L:0|P0Y0|W:-10.000,-20.000,-30.000>",
                                         wcs: 55, reportUnit: .millimeters, parserUnits: 21, distanceMode: 90)
        try expectEqual(s.state, "Idle")
        try expectEqual(s.machinePosition, Point3(x: -86, y: -0.5, z: -1.25))
        try expectEqual(s.workOffset, Point3(x: -10, y: -20, z: -30))
        try expectEqual(s.workPosition, Point3(x: -76, y: 19.5, z: 28.75))
        try expect(s.probeTripped && s.limitY && !s.limitX)
        try expectEqual(s.wcs, 55)
        let hold = try RealTimeStatus.parse("<Hold:0|M:0.000,0.000,0.000|B:15,128|L:|0000>",
                                            wcs: 54, reportUnit: .millimeters, parserUnits: 21, distanceMode: 90)
        try expectEqual(hold.state, "Hold")
        try expectEqual(hold.subState, 0)
        try expect(hold.workOffset == nil)
        try expectThrows { _ = try RealTimeStatus.parse("<Idle|MPos:0,0,0|Bf:15,128|FS:0,0>", wcs: 54, reportUnit: .millimeters, parserUnits: 21, distanceMode: 90) }
    },

    TestCase(name: "protocolHelpers") {
        try expect(GRBLProtocol.isHexOK("KA") && !GRBLProtocol.isHexOK("KAB") && !GRBLProtocol.isHexOK("Ka"))
        try expect(GRBLProtocol.parseSetting("$130=86.000")! == (130, 86))
        try expect(GRBLProtocol.parseSetting("$N0=") == nil)
        try expectEqual(MillConnection.grblVersion(in: "Grbl 1.1g ['$' for help]"), "1.1")
        try expectEqual(MillConnection.lastFeedRate(in: "G1X10F200Y2F300"), 300)
        try expectEqual(MillConnection.replaceFeedRates(in: "G1X10F200Y2f300", with: 150), "G1X10F150Y2F150")
    },

    TestCase(name: "connectLoadsSettings") {
        let mock = MockGRBL()
        let connection = try connect(mock)
        defer { connection.disconnect() }
        try expect(connection.isConnected)
        try expect(mock.receivedLines.contains("$$"))
        let limits = connection.settingsSnapshot.softLimits
        try expectEqual(limits, SoftLimits(enabled: true, travelX: 86, travelY: 241.5, travelZ: 78.5))
    },

    TestCase(name: "streamingRespectsReceiveBuffer") {
        var options = MockGRBL.Options()
        options.linesPerPoll = 1 // slow controller: forces the host to wait for buffer space
        let mock = MockGRBL(options: options)
        let connection = try connect(mock)
        defer { connection.disconnect() }

        var source = ["G21", "G90", "G0 X-10 Y-10"]
        for i in 0..<60 { source.append("G1 X-\(10 + i % 7).123 Y-\(20 + i % 5).456 Z-1.789 F300") }
        source.append("M5")
        try connection.executeProgram(GCodeProgram(source: source).lines)

        try expect(!mock.overflowed, "receive buffer overflowed (max \(mock.maxRxUsed))")
        try expect(mock.maxRxUsed > 60, "streaming should keep the buffer busy, max was \(mock.maxRxUsed)")
        let sent = mock.receivedLines.filter { $0.hasPrefix("G1") }
        try expectEqual(sent.count, 60)
        try expectEqual(mock.receivedLines.last, "G4P0")
        // M-codes require an empty buffer before they are sent.
        try expectEqual(mock.pendingLines(whenReceived: "M5"), 0)
        try expectEqual(connection.progress, MillProgress(completed: source.count, total: source.count))
    },

    TestCase(name: "feedRateOverride") {
        let mock = MockGRBL()
        let connection = try connect(mock)
        defer { connection.disconnect() }
        connection.feedRateSlider = 50
        try connection.executeProgram(program("G1 X-5 F200"))
        try expect(mock.receivedLines.contains("G1X-5F100"), "\(mock.receivedLines)")
        connection.feedRateSlider = 10 // clamped to 30
        try expectEqual(connection.feedRateSlider, 30)
    },

    TestCase(name: "grblErrorStopsProgram") {
        var options = MockGRBL.Options()
        options.replyOverride = { $0.contains("G99") ? "error:20" : nil }
        let mock = MockGRBL(options: options)
        let connection = try connect(mock)
        defer { connection.disconnect() }
        do {
            try connection.executeProgram(program("G0 X-1\nG99 X1\nG0 X-2"))
            throw TestFailure(description: "expected an error")
        } catch let error as MillError {
            try expectEqual(error.kind, .grblError)
        }
        try expectEqual(connection.currentError?.title, "Unsupported command")
        try expect(connection.currentError?.description.contains("Command \"G99X1\"") == true)
    },

    TestCase(name: "silenceIsTreatedAsHardwareEStop") {
        var options = MockGRBL.Options()
        options.linesPerPoll = 1
        let mock = MockGRBL(options: options)
        let connection = try connect(mock)
        defer { connection.disconnect() }
        mock.silent = true
        let start = Date()
        do {
            try connection.executeProgram(program("G4 P0.5\nG0 X-1"))
            throw TestFailure(description: "expected e-stop")
        } catch let error as MillError {
            try expectEqual(error.kind, .eStopPushed)
        }
        let elapsed = Date().timeIntervalSince(start)
        try expect(elapsed > 1.9 && elapsed < 4, "took \(elapsed)s")
        try expect(connection.isEStopEngaged)
    },

    TestCase(name: "softwareEStopInterruptsProgram") {
        var options = MockGRBL.Options()
        options.linesPerPoll = 1
        let mock = MockGRBL(options: options)
        let connection = try connect(mock)
        defer { connection.disconnect() }
        let manager = MillingManager()
        let lines = (0..<400).map { "G1 X-\($0 % 50) F100" }
        try expect(manager.runStep(GCodeProgram(source: lines), resetAfter: false, on: connection))
        Thread.sleep(forTimeInterval: 0.3)
        try expect(manager.inProgress)
        connection.emergencyStop()
        let deadline = Date().addingTimeInterval(5)
        while manager.inProgress, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        try expect(!manager.inProgress, "program kept running after e-stop")
        try expect(mock.realtimeBytes.filter { $0 == 0x18 }.count >= 2, "expected two soft resets")
        try expect(mock.receivedLines.filter { $0.hasPrefix("G1") }.count < 400)
    },

    TestCase(name: "jogClampsToSoftLimits") {
        let mock = MockGRBL()
        mock.setPosition(Point3(x: -80, y: -100, z: -10))
        let connection = try connect(mock)
        defer { connection.disconnect() }
        _ = try connection.queryStatus()
        // X range is -85.5…-0.5; at -80 the limit is 5.5 mm away; continuous backs off 1 mm.
        try expectEqual(connection.jogDistance(.up, continuous: true, distanceMillimeters: 10), -4.5)
        try expectEqual(connection.jogDistance(.up, continuous: false, distanceMillimeters: 2), -2)
        try expectEqual(connection.jogDistance(.up, continuous: false, distanceMillimeters: 50), -5.5)
        try expectEqual(connection.jogDistance(.retract, continuous: false, distanceMillimeters: 100), 9.5)
        connection.jog(.down, continuous: false, distanceMillimeters: 1)
        try expect(mock.receivedLines.contains("$J=G91G21X1.0000F1000"), "\(mock.receivedLines.suffix(3))")
        try expectEqual(mock.position.x, -79)
        connection.cancelJog()
        try expect(mock.realtimeBytes.contains(0x85))
    },

    TestCase(name: "jogNearLimitDoesNotReverse") {
        let mock = MockGRBL()
        mock.setPosition(Point3(x: -85.2, y: -100, z: -10)) // 0.3 mm from the X minimum
        let connection = try connect(mock)
        defer { connection.disconnect() }
        _ = try connection.queryStatus()
        try expectEqual(connection.jogDistance(.up, continuous: true, distanceMillimeters: 10), 0)
    },

    TestCase(name: "nonBlockingReadKeepsHomingTimeout") {
        let mock = MockGRBL()
        let connection = try connect(mock)
        defer { connection.disconnect() }
        connection.state.setHoming(true)
        try connection.readResponse(blocking: false)
        try expect(connection.state.isHoming, "a status poll must not end the 25 s homing window")
    },

    TestCase(name: "feedOverrideAccountsForLongerLines") {
        var options = MockGRBL.Options()
        options.linesPerPoll = 1
        let mock = MockGRBL(options: options)
        let connection = try connect(mock)
        defer { connection.disconnect() }
        connection.feedRateSlider = 150
        // F999 → F1498: one byte longer than counted; many such lines would overflow before.
        try connection.executeProgram((0..<80).map { GCodeLine("G1X-\($0 % 9).5Y-1.25F999") })
        try expect(!mock.overflowed, "receive buffer overflowed (max \(mock.maxRxUsed))")
    },

    TestCase(name: "eStopLatchedWhileProgramWaitsForLock") {
        var options = MockGRBL.Options()
        options.linesPerPoll = 1
        let mock = MockGRBL(options: options)
        let connection = try connect(mock)
        defer { connection.disconnect() }
        let manager = MillingManager()
        // Hold the connection lock so the program thread is stuck waiting when stop is pressed.
        connection.lock.lock()
        try expect(manager.runStep(GCodeProgram(source: (0..<200).map { "G1 X-\($0 % 9) F100" }), resetAfter: false, on: connection))
        Thread.sleep(forTimeInterval: 0.2)
        DispatchQueue.global().async { connection.emergencyStop() }
        Thread.sleep(forTimeInterval: 0.3)
        connection.lock.unlock()
        let deadline = Date().addingTimeInterval(8)
        while manager.inProgress, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        try expect(!manager.inProgress, "program kept running after an e-stop it missed")
        try expect(mock.receivedLines.filter { $0.hasPrefix("G1") }.count < 200)
    },

    TestCase(name: "probeSuccessRecordsPoint") {
        let mock = MockGRBL()
        let connection = try connect(mock)
        defer { connection.disconnect() }
        try connection.executeProgram(program("G21\nG38.2 Z-20 F50\nG0 Z-1"))
        try expectEqual(connection.lastProbedPoint.z, -10)
        // `$G` is queried before probing so the state can be restored on failure.
        try expect(mock.receivedLines.contains("$G"))
    },

    TestCase(name: "probeFailureRecovers") {
        var options = MockGRBL.Options()
        options.probeContactZ = nil
        let mock = MockGRBL(options: options)
        let connection = try connect(mock)
        defer { connection.disconnect() }
        let manager = MillingManager()
        try expect(manager.runStep(GCodeProgram(source: ["G21", "G38.2 Z-20 F50"]), resetAfter: false, on: connection))
        let deadline = Date().addingTimeInterval(8)
        while manager.inProgress, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        guard case .failed(let error) = manager.status(connection: connection, clearError: true) else {
            throw TestFailure(description: "expected a failure")
        }
        try expect(error.isProbeFailure, "\(error)")
        try expect(error.allowsRetry)
        // Recovery unlocked the machine and moved back to the pre-probe position.
        try expect(mock.receivedLines.contains("$X"))
        try expect(mock.receivedLines.contains { $0.hasPrefix("G53 G0 X") })
    },

    TestCase(name: "m100Midpoint") {
        let mock = MockGRBL()
        mock.setOffset(55, Point3(x: -10, y: -40, z: 0))
        mock.setOffset(56, Point3(x: -20, y: -50, z: 0))
        let connection = try connect(mock)
        defer { connection.disconnect() }
        try connection.executeProgram(program("M100 G55XG56XG54X"))
        try expect(mock.receivedLines.contains("G10L2P1X-15.000"), "\(mock.receivedLines.suffix(5))")
        try expectEqual(mock.offset(54).x, -15)
    },

    TestCase(name: "m102Expression") {
        let mock = MockGRBL()
        mock.setOffset(54, Point3(x: 0, y: -2, z: 0))
        mock.setOffset(55, Point3(x: 0, y: -4, z: 0))
        let connection = try connect(mock)
        defer { connection.disconnect() }
        // The real Universal Clamp project uses exactly this form.
        try connection.executeProgram(program("M102 G54Y ((G54Y + G55Y)/2)"))
        try expect(mock.receivedLines.contains("G10L2P1Y-3.000000"), "\(mock.receivedLines.suffix(5))")
        try expectEqual(try WCSExpression.evaluate("max(1,2)*-3+abs(-1)^2") { _ in nil }, -5)
        try expectThrows { _ = try WCSExpression.evaluate("G54X +") { _ in 1 } }
    },

    TestCase(name: "m106Check") {
        let offsets: [(name: String, point: Point3)] = [("G54", Point3(x: 1, y: 2, z: 3)), ("G55", Point3(x: 1, y: 5, z: 0))]
        try expect(try M106Check.parse("G54X == G55X error: X differs").evaluate(offsets: offsets))
        try expect(try !M106Check.parse("G54Y > G55Y error: too short").evaluate(offsets: offsets))
        try expectEqual(try M106Check.parse("G54Y > G55Y error: too short").errorMessage, " too short")
        try expect(try M106Check.parse("G54XYZ > -1 error: neg").evaluate(offsets: offsets))
        try expectThrows { _ = try M106Check.parse("1 > G54X error: x") }
    },

    TestCase(name: "wcsHelpers") {
        let mock = MockGRBL()
        let connection = try connect(mock)
        defer { connection.disconnect() }
        try expect(!connection.hasNonzeroWCS())
        mock.setOffset(59, Point3(x: 5, y: 5, z: 5))
        try expect(!connection.hasNonzeroWCS(), "G59 is a carry-over register")
        mock.setOffset(56, Point3(x: 1, y: 0, z: 0))
        try expect(connection.hasNonzeroWCS())
        connection.clearG54ThroughG58()
        try expectEqual(mock.offset(56), .zero)
        try expectEqual(mock.offset(59), Point3(x: 5, y: 5, z: 5))

        var job = Job()
        job.wcsChecks = [WCSCheck(wcs: 59, x: 5, y: 5, z: 5)]
        job.wcsCheckFailedMessage = "bad"
        try expectEqual(connection.wcsValueCheck(for: job), "")
        job.wcsChecks = [WCSCheck(wcs: 59, x: 5, y: 5, z: 4)]
        try expectEqual(connection.wcsValueCheck(for: job), "bad")
    },

    TestCase(name: "universalClampStepStreamsCompletely") {
        let url = repoRoot.appending(path: "reference/fixtures/universal_clamp.crproj")
        guard FileManager.default.fileExists(atPath: url.path) else { throw Skip(reason: "fixture not present") }
        let project = try CRProject.open(url: url)
        // Pick a milling step without probing so the mock can run it end to end.
        guard let step = try project.jobs[0].steps.first(where: { step in
            guard step.hasGCode else { return false }
            let lines = try project.gcodeLines(for: step)
            return lines.count > 200 && !lines.contains { $0.contains("G38") || $0.contains("M1") }
        }) else { throw Skip(reason: "no suitable step") }
        let programLines = GCodeProgram(source: try project.gcodeLines(for: step)).lines
        let mock = MockGRBL()
        let connection = try connect(mock)
        defer { connection.disconnect() }
        let before = mock.receivedLines.count
        try connection.executeProgram(programLines)
        try expect(!mock.overflowed)
        let expected = programLines.map(\.cleaned).filter { !$0.isEmpty }
        let sent = Array(mock.receivedLines[before...]).filter { $0 != "?" && $0 != "" && $0 != "$G" }
        let sentProgram = Array(sent.dropLast()) // final G4P0
        try expectEqual(sentProgram.count, expected.count, "step \(step.title)")
        try expect(sentProgram == expected, "streamed lines differ from the file")
        print("    streamed \(expected.count) lines of '\(step.title)' (\(step.gcodePath))")
    },
]
