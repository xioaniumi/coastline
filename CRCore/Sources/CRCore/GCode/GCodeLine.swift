import Foundation

/// A G-code line reduced to its minimal form and classified for GRBL streaming.
/// Port of `GCodeLine` (`src/Files/GCodeLine.cpp`).
public struct GCodeLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case unknown
        /// Starts with an axis, feed, spindle or parameter word (`X…`, `F…`, `S…`, …).
        case axisFeedSpindle
        case gcode
        case mcode
        /// A GRBL system command (`$…`) or real-time character (`~`, `?`, `|`), or an empty line.
        case grbl
    }

    public enum Group: Equatable, Sendable {
        case unknown
        // G-code modal groups
        case nonModal, motion, planeSelection, distance, feedRateMode, units, toolLengthOffset, coordinateSystem
        // M-code groups
        case stopping, spindle, coolant, userDefined
        // GRBL command groups
        case empty, command, home, unlock, special, status, checkMode, wcsInfo, jog, level
    }

    /// The text as given (with `%` replaced and an unterminated leading `(` closed).
    public let original: String
    /// Without comments and whitespace — this is what is sent to GRBL.
    public let cleaned: String
    public let kind: Kind
    public let group: Group
    /// The G or M number, 0 otherwise.
    public let value: Int
    /// True for codes that require GRBL's planner buffer to be empty before sending.
    public let isBlocking: Bool
    public let isProbe: Bool
    /// True for lines CRWrite inserted itself (not from the user's file).
    public let isInjected: Bool
    /// For M-codes: the text after the number (`M102 G556X …` → `G556X…`).
    public let mcodeOptions: String?
    /// 54…59 for a coordinate-system select.
    public let wcs: Int?
    /// 20 (inch) or 21 (mm).
    public let units: Int?
    /// 90 (absolute) or 91 (relative).
    public let distanceMode: Int?

    public init(_ line: String, injected: Bool = false) {
        var s = line
        // A line starting with "(" gets a closing ")" appended (the original's check for ")" at
        // index 0 is always true at that point).
        if s.hasPrefix("(") { s.append(")") }
        s = s.replacingOccurrences(of: "%", with: " ")
        original = s
        isInjected = injected

        var clean = ""
        var inComment = false
        for c in s {
            if c == ";" || c == "\r" || c == "\n" || c == "\r\n" { break }
            if c == "(" { inComment = true }
            else if c == ")" { inComment = false }
            else if !inComment, c != " ", c != "\t" { clean.append(c) }
        }
        cleaned = clean

        var kind = Kind.unknown
        var group = Group.unknown
        var value = 0
        var blocking = false
        var probe = false
        var options: String?
        var wcs: Int?
        var units: Int?
        var distance: Int?

        let upper = clean.uppercased()
        if clean.isEmpty {
            kind = .grbl
            group = .empty
        } else if let first = upper.first, "FIJKLNPRSTXYZ".contains(first) {
            kind = .axisFeedSpindle
            group = .motion
        } else if let number = Self.gNumber(upper) {
            kind = .gcode
            value = Int(number) ?? 0
            switch number {
            case "4", "10", "28", "30", "53", "92":
                group = .nonModal
                blocking = true
            case "0", "1", "2", "3", "38", "80":
                if number == "38" { probe = true }
                group = .motion
            case "17", "18", "19": group = .planeSelection
            case "90", "91":
                group = .distance
                distance = number == "90" ? 90 : 91
            case "93", "94": group = .feedRateMode
            case "20", "21":
                group = .units
                units = Int(number)
            case "43", "49": group = .toolLengthOffset
            case "54", "55", "56", "57", "58", "59":
                group = .coordinateSystem
                blocking = true
                wcs = Int(number)
            default: break
            }
        } else if let (number, rest) = Self.mNumber(clean) {
            kind = .mcode
            value = Int(number) ?? 0
            options = rest
            switch number {
            case "0", "1", "2", "30": group = .stopping
            case "3", "4", "5": group = .spindle
            case "7", "8", "9": group = .coolant
            case "100", "101", "102", "106", "111", "112", "113", "114": group = .userDefined
            default: break
            }
        } else if Self.isGRBL(clean) {
            kind = .grbl
            let chars = Array(clean)
            if chars[0] == "$" {
                blocking = true
                if chars.count == 1 {
                    group = .command
                } else {
                    switch chars[1] {
                    case "H": group = .home
                    case "X": group = .unlock
                    case "?": group = .status
                    case "#": group = .wcsInfo
                    case "C": group = .checkMode
                    case "J": group = .jog
                    case "L": group = .level
                    default: group = .command
                    }
                }
            } else {
                group = .special
            }
        }

        self.kind = kind
        self.group = group
        self.value = value
        self.isBlocking = blocking
        self.isProbe = probe
        self.mcodeOptions = options
        self.wcs = wcs
        self.units = units
        self.distanceMode = distance
    }

    public static func injected(_ line: String) -> GCodeLine { GCodeLine(line, injected: true) }

    public var isGCode: Bool { kind == .gcode }
    public var isMCode: Bool { kind == .mcode }
    public var isGRBL: Bool { kind == .grbl }
    public var isHome: Bool { group == .home }
    public var isUnlock: Bool { group == .unlock }
    public var isLevel: Bool { group == .level }

    /// `^G0*(\d+).*` (case-insensitive) → the number with leading zeros removed (but at least one digit).
    static func gNumber(_ upper: String) -> String? {
        guard upper.first == "G" else { return nil }
        let digits = upper.dropFirst().prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let trimmed = digits.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    /// `^M(\d+)(.*)` (case-insensitive) → number as written and the remainder.
    static func mNumber(_ clean: String) -> (String, String)? {
        guard let first = clean.first, first == "M" || first == "m" else { return nil }
        let digits = clean.dropFirst().prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let rest = clean.dropFirst(1 + digits.count)
        // `sm[1]` keeps leading zeros ("M03" → "03"), so it does not match "3" in the switch;
        // mirrored here by returning the digits verbatim.
        return (String(digits), String(rest))
    }

    static func isGRBL(_ line: String) -> Bool {
        if line.first == "$" { return true }
        if line.count == 1 { return line == "~" || line == "?" || line == "|" }
        return false
    }
}

/// Splits a cleaned line into words: a new chunk starts at each letter except `P` and `L`
/// (`ChunkGCodeLine`). `G10L2P1X0` → `["G10L2P1", "X0"]`.
public func chunkGCodeLine(_ line: String) -> [String] {
    var result: [String] = []
    var current = ""
    for c in line {
        if !current.isEmpty, c.isASCII, c.isLetter, c != "P", c != "L" {
            result.append(current)
            current = ""
        }
        current.append(c)
    }
    result.append(current)
    return result
}

/// A G-code program ready to stream. Port of `GCodeFile` (`src/Files/GCodeFile.cpp`).
public struct GCodeProgram: Equatable, Sendable {
    public var lines: [GCodeLine]

    public init(lines: [GCodeLine]) {
        self.lines = lines
    }

    /// Builds a program from file lines, inserting the helper lines the original added:
    /// a status query `?` before probe moves (`G38.`) and a 0.1 s dwell before `M101`.
    public init(source: [String]) {
        var out: [GCodeLine] = []
        out.reserveCapacity(source.count + 4)
        // The original only checks lines 1…29 here (a match on line 0 is ignored).
        if source.prefix(30).dropFirst().contains(where: { $0.contains("G38.") }) {
            out.append(.injected("?"))
        }
        for (i, line) in source.enumerated() {
            // `LookAhead(..) > 0` — a match on the very first line does not count.
            if i > 0, line.contains("G38.") { out.append(GCodeLine("?")) }
            if i > 0, line.contains("M101") { out.append(GCodeLine("G4 P0.1")) }
            out.append(GCodeLine(line))
        }
        lines = out
    }
}
