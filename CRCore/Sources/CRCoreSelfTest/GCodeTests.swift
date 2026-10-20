import Foundation
@testable import CRCore

let gcodeTests: [TestCase] = [
    TestCase(name: "cleaning") {
        try expectEqual(GCodeLine("G0 X1.5 Y-2 ; rapid").cleaned, "G0X1.5Y-2")
        try expectEqual(GCodeLine("G1 (feed move) X3 F100").cleaned, "G1X3F100")
        try expectEqual(GCodeLine("(only a comment").cleaned, "")
        try expectEqual(GCodeLine("(only a comment").original, "(only a comment)")
        try expectEqual(GCodeLine("%").cleaned, "")
        try expectEqual(GCodeLine("\tM3 S10000").cleaned, "M3S10000")
    },

    TestCase(name: "classification") {
        let empty = GCodeLine("   ")
        try expect(empty.kind == .grbl && empty.group == .empty)

        let axis = GCodeLine("X10 Y5")
        try expect(axis.kind == .axisFeedSpindle && axis.group == .motion)

        let dwell = GCodeLine("G4 P0.1")
        try expect(dwell.kind == .gcode && dwell.group == .nonModal && dwell.isBlocking)
        try expectEqual(dwell.value, 4)

        let rapid = GCodeLine("G00 X0")
        try expect(rapid.group == .motion && !rapid.isBlocking)
        try expectEqual(rapid.value, 0)

        let probe = GCodeLine("G38.2 Z-10 F50")
        try expect(probe.isProbe && probe.group == .motion)

        let wcs = GCodeLine("G55")
        try expect(wcs.group == .coordinateSystem && wcs.isBlocking)
        try expectEqual(wcs.wcs, 55)

        try expectEqual(GCodeLine("G20").units, 20)
        try expectEqual(GCodeLine("g91").distanceMode, 91)

        let spindle = GCodeLine("M3 S12000")
        try expect(spindle.kind == .mcode && spindle.group == .spindle)
        try expectEqual(spindle.mcodeOptions, "S12000")

        // Leading zeros keep the original's quirk: "M03" is an M-code but not grouped as spindle.
        try expectEqual(GCodeLine("M03").group, .unknown)

        let custom = GCodeLine("M102 G556X G54X + (2 * G55X)")
        try expect(custom.group == .userDefined)
        try expectEqual(custom.mcodeOptions, "G556XG54X+")

        try expectEqual(GCodeLine("$H").group, .home)
        try expectEqual(GCodeLine("$X").group, .unlock)
        try expectEqual(GCodeLine("$#").group, .wcsInfo)
        try expectEqual(GCodeLine("$J=G91 X1 F100").group, .jog)
        try expectEqual(GCodeLine("$$").group, .command)
        try expect(GCodeLine("$$").isBlocking)
        try expectEqual(GCodeLine("~").group, .special)
        try expectEqual(GCodeLine("!").kind, .unknown, "'!' is not treated as GRBL by the original")
    },

    TestCase(name: "programInsertsHelperLines") {
        let program = GCodeProgram(source: ["G21", "G38.2 Z-5 F20", "M101 G54X G55X 0.1"])
        try expectEqual(program.lines.map(\.cleaned), ["?", "G21", "?", "G38.2Z-5F20", "G4P0.1", "M101G54XG55X0.1"])
        try expect(program.lines[0].isInjected)
        try expect(!program.lines[2].isInjected)
    },

    TestCase(name: "probeOnFirstLineIsIgnoredByLookahead") {
        let program = GCodeProgram(source: ["G38.2 Z-5", "G0 Z5"])
        try expectEqual(program.lines.map(\.cleaned), ["G38.2Z-5", "G0Z5"])
    },

    TestCase(name: "chunking") {
        try expectEqual(chunkGCodeLine("G10L2P1X0Y0"), ["G10L2P1", "X0", "Y0"])
        try expectEqual(chunkGCodeLine("G0X1"), ["G0", "X1"])
    },
]
