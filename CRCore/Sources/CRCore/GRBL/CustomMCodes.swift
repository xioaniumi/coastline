import Foundation

/// CRWrite-only M-codes, executed in software. Ports of `src/Mill/GRBL/Commands/*`.
extension MillConnection {

    /// Runs an internal command the way `MillDaemon::ExecuteCommand` did: errors are logged, not thrown.
    /// Deviation: a GRBL error stays recorded, so the running program stops at its next read. In the
    /// original a failed `G10` inside M100/M102 was ignored and cutting continued with wrong offsets.
    func executeInternal(_ command: String) {
        do {
            try executeCommand(GCodeLine(command), isManualEntry: true)
        } catch {
            log.add(.error, "ExecuteCommand error: \(error)")
        }
    }

    func offset(named name: String, in offsets: [(name: String, point: Point3)]) -> Point3? {
        offsets.first(where: { $0.name == name })?.point
    }

    /// `M100 Gaa U Gbb V Gcc W` — store the midpoint of WCS Gaa.U and Gbb.V into Gcc.W.
    /// Example: `M100 G55XG56XG54X` (arguments arrive without spaces).
    func m100(_ args: String) throws {
        log.add(.write, "M100 In Progress...")
        let a = Array(args)
        guard a.count >= 12, let axisIn = Axis(letter: a[3]), let axisOut = Axis(letter: a[11]) else {
            log.add(.error, "M100 Failed")
            throw MillError(.m100OutOfRange)
        }
        let gIn1 = String(a[0..<3]), gIn2 = String(a[4..<7]), gOut = String(a[8..<11])
        let pCode = Int(a[10].asciiValue ?? 0) - Int(Character("3").asciiValue!) // '4'…'9' → 1…6

        let offsets = self.offsets()
        var points: [Point3] = []
        if let p = offset(named: gIn1, in: offsets) { points.append(p) }
        if let p = offset(named: gIn2, in: offsets) { points.append(p) }
        guard points.count == 2 else {
            // The original only checked for an empty list; with one point it would crash.
            log.add(.error, "M100 Failed")
            throw MillError(.m100OutOfRange)
        }
        let v1 = points[0][axisIn], v2 = points[1][axisIn]
        let center = min(v1, v2) + (max(v1, v2) - min(v1, v2)) / 2
        executeInternal("G10 L2 P\(pCode) \(axisOut.rawValue)\(String(format: "%.3f", center))")

        // Verify the stored value lies between the two inputs.
        if let stored = offset(named: gOut, in: self.offsets()) {
            let value = stored[axisOut]
            let distanceFromSecond = abs(v2 - value)
            let span = abs(v2 - v1)
            if distanceFromSecond > span {
                log.add(.error, "M100 Failed")
                throw MillError(.m100OutOfRange)
            }
        }
        log.add(.read, "M100 Complete")
    }

    /// `M101 GaaGbbGccA tol` — fail if the A-axis values of three WCS differ by `tol` or more.
    func m101(_ args: String) throws {
        log.add(.write, "M101 Initiated")
        let a = Array(args)
        guard a.count > 10, let axis = Axis(letter: a[9]), let tolerance = Double(String(a[10...])) else {
            throw MillError(.m101Fail, a.count > 9 ? String(a[9]) : "")
        }
        let names = [String(a[0..<3]), String(a[3..<6]), String(a[6..<9])]
        let offsets = self.offsets()
        let values = names.compactMap { offset(named: $0, in: offsets)?[axis] }
        guard let maxValue = values.max(), let minValue = values.min(), abs(maxValue - minValue) < tolerance else {
            log.add(.error, "M101 Check Failed")
            throw MillError(.m101Fail, axis.rawValue)
        }
        log.add(.read, "M101 Check Succeeded")
    }

    /// `M102 GaaU <expression>` — evaluate arithmetic over WCS registers (e.g. `((G54Y + G55Y)/2)`)
    /// and store the result in GaaU. The original used exprtk; `WCSExpression` covers arithmetic.
    func m102(_ original: String) throws {
        var line = original.replacingOccurrences(of: "M102", with: "").replacingOccurrences(of: "m102", with: "")
        line = line.filter { !$0.isWhitespace }
        let chars = Array(line)
        guard chars.count >= 4, WCSExpression.isRegister(chars[0..<4]) else {
            log.add(.error, "M102 Syntax Error - Invalid destination register. Must be G54-59(X,Y,Z)")
            throw MillError(.m102InvalidDestRegister)
        }
        let destination = String(chars[0..<4]).uppercased()
        let expression = String(chars[4...])

        let offsets = self.offsets()
        guard !offsets.isEmpty else {
            log.add(.error, "M102 Failed - Could not get offsets")
            throw MillError(.m102OffsetsFail)
        }
        let result: Double
        do {
            result = try WCSExpression.evaluate(expression) { register in
                guard let axis = Axis(letter: register.last!) else { return nil }
                return self.offset(named: String(register.prefix(3)), in: offsets)?[axis]
            }
        } catch {
            log.add(.error, "M102 Syntax Error - Invalid exprtk expression")
            throw MillError(.m102InvalidExpression)
        }
        let p = Int(destination[destination.index(destination.startIndex, offsetBy: 2)].wholeNumberValue ?? 0) - 3
        executeInternal("G10 L2 P\(p) \(destination.last!)\(Self.cppFloat(result))")
        log.add(.read, "M102 Complete")
    }

    /// `M106 <left> <op> <right> error: <message>` — boolean check on WCS values; fails the step if false.
    func m106(_ original: String) throws {
        var text = original
        for prefix in ["M106 ", "m106 ", "M106\t", "m106\t"] { text = text.replacingOccurrences(of: prefix, with: "") }
        let check = try M106Check.parse(text)
        let offsets = self.offsets()
        if try !check.evaluate(offsets: offsets) {
            throw MillError(.m106BoolTestFail, check.errorMessage)
        }
    }

    /// `M111 <axes>` — probe with `G38.2<axes>` and add the hit to the contour map.
    func m111(_ params: String) throws {
        log.add(.write, "Initiating M111")
        // Deviation: wait for a new probe report rather than a different value (probing the
        // same point twice made the original spin forever).
        let reports = probeReports
        try serial.writeLine("G38.2" + params)
        while probeReports == reports {
            sleep(milliseconds: 10)
            try readResponse(blocking: true)
        }
        let point = lastProbedPoint
        if contour.add(point) {
            serial.flushReads()
            log.add(.read, "M111 Complete")
        } else {
            serial.flushReads()
            log.add(.read, "M111 Failed. Duplicate X & Y values.")
        }
    }
}

// MARK: - Contour map (M111–M114)

/// Probed surface points and the Z compensation built from them. Port of `ContourMapping.cpp`.
final class ContourMap: @unchecked Sendable {
    private struct Values {
        var points: [Point3] = []
        var enabled = false
        var previousZ = ""
    }
    private let values = Locked(Values())

    var isEnabled: Bool { values.withLock { $0.enabled } }
    var points: [Point3] { values.withLock { $0.points } }
    var previousZ: String {
        get { values.withLock { $0.previousZ } }
        set { values.withLock { $0.previousZ = newValue } }
    }

    /// Adds a point unless one with the same X/Y exists.
    func add(_ point: Point3) -> Bool {
        values.withLock { v in
            if v.points.contains(where: { $0.x == point.x && $0.y == point.y }) { return false }
            v.points.append(point)
            return true
        }
    }

    /// M112
    func enable(log: MachineLog) throws {
        guard points.count >= 3 else {
            throw MillError(.m112Fail, "M112 Failed. Contour map needs at least 3 points.")
        }
        log.add(.write, "M112: Contour Adjustment Enabled")
        values.withLock { $0.enabled = true }
    }

    /// M113
    func disable(log: MachineLog) {
        log.add(.write, "M113: Contour Adjustment Disabled")
        values.withLock { $0.enabled = false }
    }

    /// M114
    func clear(log: MachineLog) {
        values.withLock { $0.points.removeAll() }
        log.add(.write, "M114: Contour Map Cleared")
        disable(log: log)
    }

    struct Plane {
        var normal: Point3
        var intercept: Double
        func z(at p: Point3) -> Double { (intercept - normal.x * p.x - normal.y * p.y) / normal.z }
    }

    static func cross(_ a: Point3, _ b: Point3) -> Point3 {
        Point3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }

    static func plane(_ a: Point3, _ b: Point3, _ c: Point3) -> Plane? {
        let n = cross(b - a, c - a)
        guard n.x * n.x + n.y * n.y + n.z * n.z != 0 else { return nil }
        return Plane(normal: n, intercept: n.x * a.x + n.y * a.y + n.z * a.z)
    }

    static func isSurrounded(_ q: Point3, _ a: Point3, _ b: Point3, _ c: Point3) -> Bool {
        let ab = cross(b - a, q - a).z, bc = cross(c - b, q - b).z, ca = cross(a - c, q - c).z
        return (ab > 0 && bc > 0 && ca > 0) || (ab < 0 && bc < 0 && ca < 0)
    }

    static func distance(_ a: Point3, _ b: Point3) -> Double {
        let d = b - a
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
    }

    /// `GetOffsetPlane`: plane through the two nearest points and a third, preferring triangles
    /// that surround the target.
    func offsetPlane(for point: Point3) throws -> Plane {
        let map = points
        let sorted = map.indices.sorted { Self.distance(point, map[$0]) < Self.distance(point, map[$1]) }
        guard sorted.count >= 3 else { throw MillError(.m112Fail, "Contour map needs at least 3 points.") }
        let p1 = map[sorted[0]], p2 = map[sorted[1]]
        for preferSurrounding in [true, false] {
            for k in 2..<sorted.count {
                let p3 = map[sorted[k]]
                if preferSurrounding, !Self.isSurrounded(point, p1, p2, p3) { continue }
                if let plane = Self.plane(p1, p2, p3), plane.normal.z != 0 { return plane }
            }
        }
        throw MillError(.m112Fail, "No unique plane found. You must have at least three **non-colinear** points stored with M111 for CRWrite to perform slope adjustment.")
    }

    func transformAbsoluteZ(_ line: GCodeLine, at point: Point3, wcs: Point3) throws -> String {
        let plane = try offsetPlane(for: point)
        let z = (plane.z(at: point) - wcs.z) + (point.z - wcs.z)
        return Self.replaceZ(in: line.original, with: z)
    }

    func transformRelativeZ(_ line: GCodeLine, from previous: Point3, to next: Point3) throws -> String {
        let plane = try offsetPlane(for: previous)
        let depth = next.z - previous.z
        let planeChange = plane.z(at: next) - plane.z(at: previous)
        return Self.replaceZ(in: line.original, with: depth + planeChange)
    }

    /// `ReplaceZValue`: replace or append ` Z<value>` (truncated to 3 decimals), dropping duplicate X/Y words.
    static func replaceZ(in line: String, with z: Double) -> String {
        var text = String(format: "%f", z)
        if let dot = text.firstIndex(of: ".") {
            let end = text.index(dot, offsetBy: 4, limitedBy: text.endIndex) ?? text.endIndex
            text = String(text[..<end])
        }
        var result = ""
        var needZ = true, hasX = false, hasY = false
        for chunk in chunkGCodeLine(line) {
            switch chunk.first {
            case "Z":
                result += " Z" + text
                needZ = false
            case "X":
                if !hasX { hasX = true; result += chunk }
            case "Y":
                if !hasY { hasY = true; result += chunk }
            default:
                result += chunk
            }
        }
        if needZ { result += " Z" + text }
        return result
    }
}

// MARK: - M102 expressions

/// A small arithmetic evaluator for M102 (replaces exprtk): numbers, `+ - * / % ^`, unary minus,
/// parentheses, functions `abs min max sqrt floor ceil round`, and WCS registers like `G54X`.
enum WCSExpression {
    struct SyntaxError: Error {}

    /// `[Gg]5[4-9][X-Zx-z]`
    static func isRegister<C: Collection>(_ c: C) -> Bool where C.Element == Character {
        let a = Array(c)
        return a.count == 4 && (a[0] == "G" || a[0] == "g") && a[1] == "5"
            && ("4"..."9").contains(a[2]) && "XYZxyz".contains(a[3])
    }

    static func evaluate(_ text: String, register: @escaping (String) -> Double?) throws -> Double {
        var parser = Parser(chars: Array(text), register: register)
        let value = try parser.expression()
        guard parser.atEnd else { throw SyntaxError() }
        return value
    }

    private struct Parser {
        let chars: [Character]
        let register: (String) -> Double?
        var i = 0

        var atEnd: Bool { i >= chars.count }

        mutating func peek() -> Character? { i < chars.count ? chars[i] : nil }

        mutating func expression() throws -> Double {
            var value = try term()
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                let rhs = try term()
                value = c == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func term() throws -> Double {
            var value = try power()
            while let c = peek(), c == "*" || c == "/" || c == "%" {
                i += 1
                let rhs = try power()
                switch c {
                case "*": value *= rhs
                case "/": value /= rhs
                default: value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        mutating func power() throws -> Double {
            let base = try unary()
            if peek() == "^" {
                i += 1
                return pow(base, try power())
            }
            return base
        }

        mutating func unary() throws -> Double {
            if peek() == "-" { i += 1; return -(try unary()) }
            if peek() == "+" { i += 1; return try unary() }
            return try primary()
        }

        mutating func primary() throws -> Double {
            guard let c = peek() else { throw SyntaxError() }
            if c == "(" {
                i += 1
                let value = try expression()
                guard peek() == ")" else { throw SyntaxError() }
                i += 1
                return value
            }
            if c.isNumber || c == "." {
                let start = i
                while let d = peek(), d.isNumber || d == "." { i += 1 }
                guard let value = Double(String(chars[start..<i])) else { throw SyntaxError() }
                return value
            }
            if i + 4 <= chars.count, WCSExpression.isRegister(chars[i..<(i + 4)]) {
                let name = String(chars[i..<(i + 4)]).uppercased()
                i += 4
                guard let value = register(name) else { throw SyntaxError() }
                return value
            }
            if c.isLetter {
                let start = i
                while let d = peek(), d.isLetter { i += 1 }
                let name = String(chars[start..<i]).lowercased()
                guard peek() == "(" else { throw SyntaxError() }
                i += 1
                var args = [try expression()]
                while peek() == "," { i += 1; args.append(try expression()) }
                guard peek() == ")" else { throw SyntaxError() }
                i += 1
                switch (name, args.count) {
                case ("abs", 1): return abs(args[0])
                case ("sqrt", 1): return args[0].squareRoot()
                case ("floor", 1): return args[0].rounded(.down)
                case ("ceil", 1): return args[0].rounded(.up)
                case ("round", 1): return args[0].rounded()
                case ("min", _) where args.count >= 2: return args.min()!
                case ("max", _) where args.count >= 2: return args.max()!
                default: throw SyntaxError()
                }
            }
            throw SyntaxError()
        }
    }
}

// MARK: - M106 checks

/// `M106 G54X > G55X error: Stock too short` and friends. Port of `M106.cpp`.
struct M106Check {
    struct Comparand {
        var number: Double = 0
        var register = ""
        var axes: [Axis] = []
    }

    var left: Comparand
    var op: String
    var right: Comparand
    var errorMessage: String

    static func parse(_ text: String) throws -> M106Check {
        // Statement is everything before "error" (case-insensitive); message is after the last "error:".
        guard let errorRange = text.range(of: "error", options: [.caseInsensitive, .backwards]) else {
            throw MillError(.m106MalformedTest)
        }
        let statement = String(text[..<errorRange.lowerBound])
        var message = ""
        if let colon = text.range(of: "error:", options: [.caseInsensitive, .backwards]) {
            message = String(text[colon.upperBound...])
        }

        guard let opRange = statement.range(of: "[!<>=]=?", options: .regularExpression) else {
            throw MillError(.m106MalformedTest)
        }
        let op = String(statement[opRange])
        let leftText = statement[..<opRange.lowerBound].trimmingCharacters(in: .whitespaces)
        let rightText = statement[opRange.upperBound...].trimmingCharacters(in: .whitespaces)

        // Left must be a register (the original cannot use a number on the left).
        guard leftText.range(of: "^G5[4-9][xyz]{1,3}$", options: [.regularExpression, .caseInsensitive]) != nil else {
            throw MillError(.m106MalformedTest)
        }
        let isRegister = rightText.range(of: "^G5[4-9][xyz]{1,3}$", options: [.regularExpression, .caseInsensitive]) != nil
        let isNumber = Double(rightText) != nil
        guard isRegister || isNumber else { throw MillError(.m106MalformedTest) }

        return M106Check(left: comparand(leftText), op: op, right: comparand(rightText), errorMessage: message)
    }

    static func comparand(_ text: String) -> Comparand {
        if let number = Double(text) { return Comparand(number: number) }
        let upper = text.uppercased()
        let register = String(upper.prefix(3))
        let axes = Axis.allCases.filter { upper.dropFirst(3).contains($0.rawValue) }
        return Comparand(register: register, axes: axes)
    }

    func evaluate(offsets: [(name: String, point: Point3)]) throws -> Bool {
        func values(_ c: Comparand) -> [Axis: Double] {
            guard let p = offsets.first(where: { $0.name == c.register })?.point else {
                return Dictionary(uniqueKeysWithValues: c.axes.map { ($0, 0) })
            }
            return Dictionary(uniqueKeysWithValues: c.axes.map { ($0, p[$0]) })
        }
        func compare(_ a: Double, _ b: Double) throws -> Bool {
            // The original adds 1 to both sides "to fix -0 vs +0".
            let l = a + 1, r = b + 1
            switch op {
            case "<": return l < r
            case "<=": return l <= r
            case ">": return l > r
            case ">=": return l >= r
            case "==": return l == r
            case "!=": return l != r
            default: throw MillError(.m106MalformedTest)
            }
        }
        let lv = values(left), rv = values(right)
        let lc = left.axes.count, rc = right.axes.count
        let single: (Comparand, [Axis: Double]) -> Double = { c, v in c.axes.isEmpty ? c.number : v[c.axes[0]]! }

        if lc <= 1, rc <= 1 {
            return try compare(single(left, lv), single(right, rv))
        } else if lc == rc {
            guard Set(left.axes).isSubset(of: Set(right.axes)) else { throw MillError(.m106MalformedTest) }
            for axis in left.axes where try !compare(lv[axis]!, rv[axis]!) { return false }
            return true
        } else if lc <= 1 {
            let l = single(left, lv)
            for axis in right.axes where try !compare(l, rv[axis]!) { return false }
            return true
        } else if rc <= 1 {
            let r = single(right, rv)
            for axis in left.axes where try !compare(lv[axis]!, r) { return false }
            return true
        }
        throw MillError(.m106MalformedTest)
    }
}
