import Foundation
@testable import CRCore

let manualTests: [TestCase] = [
    TestCase(name: "outOfBounds") {
        let home = Point3(x: -86, y: -0.5, z: -0.5)
        try expect(!ManualMode.isOutOfBounds("G53 G0 X-50 Y-100 Z-10", grblVersion: "1.1g", absoluteMode: true, inches: false, machinePosition: home))
        try expect(ManualMode.isOutOfBounds("G53 G0 X10", grblVersion: "1.1g", absoluteMode: true, inches: false, machinePosition: home))
        try expect(ManualMode.isOutOfBounds("G0 Y-250", grblVersion: "1.1g", absoluteMode: true, inches: false, machinePosition: home))
        // Relative move from home: +1 in Z goes above 0.
        try expect(ManualMode.isOutOfBounds("G91 G0 Z1", grblVersion: "1.1g", absoluteMode: true, inches: false, machinePosition: home))
        try expect(!ManualMode.isOutOfBounds("G0 Z-1", grblVersion: "1.1g", absoluteMode: false, inches: false, machinePosition: home))
        // Older firmware has a smaller envelope.
        try expect(ManualMode.isOutOfBounds("G0 X-80", grblVersion: "1.0", absoluteMode: true, inches: false, machinePosition: home))
        // Commands without axes are fine.
        try expect(!ManualMode.isOutOfBounds("$H", grblVersion: "1.1g", absoluteMode: true, inches: false, machinePosition: home))
    },

    TestCase(name: "limitProximity") {
        let limits = SoftLimits(enabled: true, travelX: 86, travelY: 241.5, travelZ: 78.5)
        // X range is -85.5…-0.5.
        try expectEqual(ManualMode.proximity(axis: .x, towardMax: false, position: Point3(x: -84, y: 0, z: 0),
                                             limits: limits, continuous: true, stepMillimeters: 1), .red)
        try expectEqual(ManualMode.proximity(axis: .x, towardMax: false, position: Point3(x: -80, y: 0, z: 0),
                                             limits: limits, continuous: true, stepMillimeters: 1), .yellow)
        try expectEqual(ManualMode.proximity(axis: .x, towardMax: false, position: Point3(x: -50, y: 0, z: 0),
                                             limits: limits, continuous: true, stepMillimeters: 1), .none)
        try expectEqual(ManualMode.proximity(axis: .z, towardMax: true, position: Point3(x: 0, y: 0, z: -3),
                                             limits: limits, continuous: false, stepMillimeters: 1), .yellow)
    },

    TestCase(name: "presetsAndHistory") {
        try expectEqual(ManualMode.presetCommands(Point3(x: -10, y: -20.5, z: -3), inches: false),
                        ["$HZ", "G53 G0 X-10.000 Y-20.500", "G53 G0 Z-3.000"])
        var history = CommandHistory()
        for c in ["G0 X1", "G0 X2", "G0 X1"] { history.add(c) }
        try expectEqual(history.entries, ["G0 X2", "G0 X1"])
        try expectEqual(history.previous(), "G0 X1")
        try expectEqual(history.previous(), "G0 X2")
        try expectEqual(history.previous(), "G0 X2")
        try expectEqual(history.next(), "G0 X1")
        try expectEqual(history.next(), "")
        try expect(ManualMode.isValidStep(0.01, inches: false) && !ManualMode.isValidStep(2000, inches: false))
    },

    TestCase(name: "spindleLoad") {
        var monitor = SpindleLoadMonitor()
        let t0: TimeInterval = 1000
        monitor.process([.init(kind: .write, text: "M3S12000"), .init(kind: .read, text: "ok")], now: t0)
        try expect(!monitor.active)
        monitor.process([.init(kind: .write, text: "M105"), .init(kind: .read, text: "2k")], now: t0 + 1)
        try expect(monitor.active)
        try expectEqual(monitor.level, .grey, "not meaningful until 5 s after a spindle change")
        monitor.process([.init(kind: .write, text: "M105"), .init(kind: .read, text: "2k")], now: t0 + 6)
        try expectEqual(monitor.level, .orange)
    },
]
