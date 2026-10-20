import Foundation
import simd

/// G-code for the Coast Runner CR-1, following Coast Runner's own Fusion post
/// (`Coast_Runner_CR-1_Postprocessor.cps`) [CPS] and the controller's rules [MAN]:
/// - absolute mm (G90 G17 G21) set explicitly, because grbl powers up in G91;
/// - every program starts and ends with `G53 G0 G90 Z-1.` (full retract in machine Z);
/// - spindle start ramp S0 → 5000 → target with dwells; no M6 (tool changes are guided steps);
/// - no canned cycles (grbl has none): drilling is already expanded into moves;
/// - lines ≤ 79 characters, 3 decimals, F only when it changes; no M30 at the end.
public enum CR1Post {
    public struct Header: Sendable {
        public var programName: String
        public var setupName: String
        public var tool: Tool
        public var operationNames: [String]
        public var stockDescription: String
        public init(programName: String, setupName: String, tool: Tool, operationNames: [String], stockDescription: String) {
            self.programName = programName
            self.setupName = setupName
            self.tool = tool
            self.operationNames = operationNames
            self.stockDescription = stockDescription
        }
    }

    /// One program per tool: the operations that tool runs, in order.
    public static func program(header h: Header, rpm: Double, paths: [OperationToolpath], machine: MachineProfile = .cr1) -> String {
        programWithLineMap(header: h, rpm: rpm, paths: paths, machine: machine).text
    }

    /// The program plus, for each path and move, the 1-based G-code line it produced (nil when
    /// the move was a no-op), for the viewer's click-to-line inspection.
    public static func programWithLineMap(header h: Header, rpm: Double, paths: [OperationToolpath],
                                          machine: MachineProfile = .cr1) -> (text: String, lines: [[Int?]]) {
        var lineMap: [[Int?]] = []
        var lines: [String] = []
        func comment(_ s: String) {
            // Parentheses inside comments end them early; grbl drops long lines.
            let clean = s.replacingOccurrences(of: "(", with: "[").replacingOccurrences(of: ")", with: "]")
            lines.append(String("(\(clean))".prefix(machine.maxLineLength)))
        }
        comment("Coastline: \(h.programName)")
        comment("Setup: \(h.setupName)")
        comment("Stock: \(h.stockDescription)")
        comment("Tool: \(h.tool.name)")
        comment("D=\(fmt(h.tool.diameter)) stick-out=\(fmt(h.tool.stickout)) flutes=\(h.tool.flutes)")
        for name in h.operationNames { comment("Op: \(name)") }
        comment("WCS G54: X/Y centre of the stock face, Z0 on the face")
        lines.append("G90 G17 G21")
        lines.append("G54")
        lines.append("G53 G0 G90 Z-1.")
        // Spindle ramp-up. [CPS]
        let s = Int(min(max(rpm, machine.spindleRPM.lowerBound), machine.spindleRPM.upperBound).rounded())
        lines.append("S0 M3")
        lines.append("G4 P1.")
        if Double(s) > machine.spindleRampIntermediateRPM {
            lines.append("S\(Int(machine.spindleRampIntermediateRPM))")
            lines.append("G4 P2.")
        }
        lines.append("S\(s) M3")
        lines.append("G4 P1.")

        var lastMotion = ""
        var lastF: Double = -1
        var pos: SIMD3<Double>?
        for path in paths {
            var map: [Int?] = []
            defer { lineMap.append(map) }
            for m in path.moves {
                map.append(nil)
                var words: [String] = []
                // grbl checks that the arc's end is as far from the centre as its start (within
                // 0.005 mm) using the rounded numbers it receives. The fitted centre is only within
                // the fit tolerance of that, so it's moved onto the perpendicular bisector of the
                // rounded start and end. If that would move it noticeably, the arc becomes a line.
                var motion = m.motion
                var centre: SIMD2<Double>?
                if m.motion != .line, let p = pos {
                    let a = SIMD2(Self.rounded(p.x), Self.rounded(p.y)), b = SIMD2(Self.rounded(m.x), Self.rounded(m.y))
                    let c = SIMD2(p.x + m.i, p.y + m.j)
                    let chord = b - a, len = simd_length(chord)
                    if len < 1e-6 {
                        centre = c  // full circle: start = end
                    } else {
                        let mid = (a + b) / 2, n = SIMD2(-chord.y, chord.x) / len
                        let fixed = mid + n * simd_dot(c - mid, n)
                        if simd_length(fixed - c) <= 0.05 { centre = fixed } else { motion = .line }
                    }
                }
                let code: String
                switch (m.role, motion) {
                case (.rapid, _): code = "G0"
                case (_, .line): code = "G1"
                case (_, .arcCW): code = "G2"
                case (_, .arcCCW): code = "G3"
                }
                if code != lastMotion || code == "G2" || code == "G3" { words.append(code) }
                if pos == nil || abs(pos!.x - m.x) > 5e-4 || motion != .line { words.append("X" + fmt(m.x)) }
                if pos == nil || abs(pos!.y - m.y) > 5e-4 || motion != .line { words.append("Y" + fmt(m.y)) }
                if pos == nil || abs(pos!.z - m.z) > 5e-4 { words.append("Z" + fmt(m.z)) }
                if motion != .line, let p = pos, let c = centre {
                    // I/J from the rounded start grbl will measure from.
                    words.append("I" + fmt(c.x - rounded(p.x)))
                    words.append("J" + fmt(c.y - rounded(p.y)))
                } else if motion != .line {
                    words.append("I" + fmt(m.i))
                    words.append("J" + fmt(m.j))
                }
                if code != "G0" {
                    let f = max(m.feed.rounded(), 1)
                    if f != lastF { words.append("F" + fmtF(f)); lastF = f }
                }
                pos = m.position
                // Skip moves that go nowhere. The modal motion only changes when a line is
                // actually written, so a skipped G1 can't leave the next line without its G-code.
                let hasAxis = words.contains { $0.hasPrefix("X") || $0.hasPrefix("Y") || $0.hasPrefix("Z") }
                if !hasAxis { continue }
                if let g = words.first, g.hasPrefix("G") { lastMotion = g }
                lines.append(words.joined(separator: " "))
                map[map.count - 1] = lines.count
            }
        }
        // End. [CPS]
        lines.append("G53 G0 G90 Z-1.")
        lines.append("S0 M3")
        lines.append("G4 P2.")
        lines.append("M5")
        return (lines.joined(separator: "\n") + "\n", lineMap)
    }

    /// 3 decimals, trailing zeros trimmed ("12.5", "-3", "0.125").
    static func fmt(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    static func fmtF(_ v: Double) -> String { String(Int(v)) }

    static func rounded(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}
