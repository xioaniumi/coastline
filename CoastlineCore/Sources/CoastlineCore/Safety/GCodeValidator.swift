import Foundation
import simd

/// Independent safety check of a finished G-code file against the CR-1 and the setup.
/// It reads the **text** (not Coastline's internal toolpath), so a bug anywhere upstream
/// is still caught before the file reaches CRWrite. Errors block export; warnings explain.
public struct GCodeValidator {
    public struct Context: Sendable {
        /// Stock box in the work frame (Z top = 0).
        public var stockMin: SIMD3<Double>
        public var stockMax: SIMD3<Double>
        public var tool: Tool
        /// Rapids moving in X/Y must be at or above this Z (mm above the stock face).
        public var safeZ: Double = 1.0
        /// Allow cutting below the stock bottom (into the fixture). Never by default.
        public var allowThroughCut = false
        /// An air-cut copy: moves run with the spindle off, above the work.
        public var airCut = false
        /// Top of the material actually there (work Z): below 0 once the face was faced down.
        /// The collet-nut check measures depth from here.
        public var materialTop = 0.0

        public init(stockMin: SIMD3<Double>, stockMax: SIMD3<Double>, tool: Tool) {
            self.stockMin = stockMin
            self.stockMax = stockMax
            self.tool = tool
        }
    }

    public struct Report: Sendable, Codable, Equatable {
        public var issues: [Issue]
        public var cutLength: Double
        public var rapidLength: Double
        public var minZ: Double
        public var extentMin: SIMD3<Double>
        public var extentMax: SIMD3<Double>
        public var lineCount: Int
        public var passed: Bool { !issues.contains { $0.severity == .error } }
    }

    public let machine: MachineProfile
    public init(machine: MachineProfile = .cr1) { self.machine = machine }

    public func validate(_ gcode: String, context c: Context) -> Report {
        var issues: [Issue] = []
        func add(_ s: Issue.Severity, _ line: Int, _ msg: String) {
            // Report each kind of problem once, with its first line number.
            let key = msg.prefix(40)
            if !issues.contains(where: { $0.message.contains(key) }) {
                issues.append(Issue(s, "Line \(line): \(msg)"))
            }
        }
        var absolute = false, metric = false, spindleOn = false
        var rpm = 0.0, feed = 0.0
        var motion = "G0"
        var pos = SIMD3<Double>(0, 0, 1e6)  // unknown start: CRWrite runs programs from a retracted spindle
        var knownZ = false
        var cutLength = 0.0, rapidLength = 0.0
        var minZ = Double.infinity
        var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
        let r = c.tool.diameter / 2
        let lines = gcode.split(separator: "\n", omittingEmptySubsequences: false)

        for (index, raw) in lines.enumerated() {
            let n = index + 1
            let line = String(raw)
            if line.count > machine.maxLineLength { add(.error, n, "longer than \(machine.maxLineLength) characters; grbl rejects it (error 11).") }
            let code = line.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression).uppercased()
            if code.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            var words: [(Character, Double)] = []
            let scanner = Scanner(string: code)
            scanner.charactersToBeSkipped = .whitespaces
            while !scanner.isAtEnd {
                guard let letter = scanner.scanCharacter() else { break }
                if letter == "$" { break }  // grbl system command
                guard let v = scanner.scanDouble() else { add(.error, n, "can't read '\(code)'."); break }
                words.append((letter, v))
            }
            var target = pos
            var hasAxis = false
            var isG53 = false
            var arc: (i: Double, j: Double)?
            for (l, v) in words {
                switch l {
                case "G":
                    switch v {
                    case 0, 1, 2, 3: motion = "G\(Int(v))"
                    case 90: absolute = true
                    case 91: absolute = false; add(.error, n, "G91 incremental mode: Coastline programs must stay absolute.")
                    case 21: metric = true
                    case 20: add(.error, n, "G20 inches: Coastline programs are in mm.")
                    case 53: isG53 = true
                    case 17, 54, 4: break
                    case 28, 30, 43, 92: add(.error, n, "G\(Int(v)) isn't used on the CR-1 and can move to unexpected places.")
                    case 81, 82, 83, 73: add(.error, n, "canned cycle G\(Int(v)): grbl doesn't support it.")
                    default: add(.warning, n, "unusual code G\(v).")
                    }
                case "M":
                    switch v {
                    case 3: spindleOn = true
                    case 5: spindleOn = false
                    case 4: add(.warning, n, "M4 reverse spindle is only for probing.")
                    case 6: add(.error, n, "M6: the CR-1 has no tool changer; tool changes are guided steps.")
                    case 30, 2: add(.info, n, "M\(Int(v)) program end; Coast Runner's post ends with M5 instead.")
                    default: break
                    }
                case "S":
                    rpm = v
                    if v != 0 && !machine.isUsableRPM(v) {
                        add(.error, n, "S\(Int(v)) is outside the CR-1's \(Int(machine.spindleRPM.lowerBound))–\(Int(machine.spindleRPM.upperBound)) RPM.")
                    }
                case "F": feed = v
                case "X": target.x = v; hasAxis = true
                case "Y": target.y = v; hasAxis = true
                case "Z": target.z = v; hasAxis = true; knownZ = true
                case "I": arc = (v, arc?.j ?? 0)
                case "J": arc = (arc?.i ?? 0, v)
                case "P": break
                default: break
                }
            }
            if isG53 {
                // A G53 Z move is a machine-coordinate retract (Coast Runner's `G53 G0 G90 Z-1.`):
                // afterwards the tool is fully up, far above any work Z.
                if words.contains(where: { $0.0 == "Z" }) { pos.z = 1e6; knownZ = true }
                continue
            }
            guard hasAxis else { continue }
            if !absolute { add(.error, n, "motion before G90: grbl starts in G91, so this would move relative.") }
            if !metric { add(.error, n, "motion before G21 (mm).") }
            let d = target - pos
            let dist = (d * d).sum().squareRoot()
            if motion == "G0" {
                rapidLength += dist
                let movesXY = abs(d.x) > 1e-6 || abs(d.y) > 1e-6
                let inFootprint = target.x > c.stockMin.x - r && target.x < c.stockMax.x + r
                    && target.y > c.stockMin.y - r && target.y < c.stockMax.y + r
                if knownZ && min(pos.z, target.z) < c.safeZ && inFootprint && (movesXY || target.z < c.safeZ) {
                    add(.error, n, "rapid move below the safe height (Z\(CR1Post.fmt(c.safeZ))) over the stock. Rapids into material break tools.")
                }
            } else {
                if (!spindleOn || rpm == 0) && !c.airCut { add(.error, n, "cutting move with the spindle stopped.") }
                if feed <= 0 { add(.error, n, "cutting move without a feed rate.") }
                if feed > machine.maxRate.y + 1e-6 {
                    add(.error, n, "F\(Int(feed)) is faster than the CR-1 can move (\(Int(machine.maxRate.y)) mm/min).")
                } else if dist > 0, feed * abs(d.x) / dist > machine.maxRate.x + 1e-6 {
                    add(.warning, n, "X component of F\(Int(feed)) exceeds X's \(Int(machine.maxRate.x)) mm/min; grbl will slow it.")
                }
                if motion == "G2" || motion == "G3" {
                    guard let a = arc else { add(.error, n, "arc without I/J."); pos = target; continue }
                    let rs = (a.i * a.i + a.j * a.j).squareRoot()
                    let ce = SIMD2(pos.x + a.i, pos.y + a.j)
                    let re = ((target.x - ce.x) * (target.x - ce.x) + (target.y - ce.y) * (target.y - ce.y)).squareRoot()
                    if abs(rs - re) > 0.005 + rs * 1e-4 { add(.error, n, "arc end isn't on the arc (radius \(CR1Post.fmt(rs)) vs \(CR1Post.fmt(re))); grbl raises error 33.") }
                    let m = Move(.cut, motion == "G2" ? .arcCW : .arcCCW, x: target.x, y: target.y, z: target.z, i: a.i, j: a.j)
                    cutLength += ToolpathGeometry.length(of: m, from: pos)
                } else {
                    cutLength += dist
                }
                minZ = min(minZ, target.z)
                lo = simd_min(lo, target)
                hi = simd_max(hi, target)
            }
            pos = target
        }

        // Depth and reach.
        if minZ < .infinity {
            if !c.allowThroughCut && minZ < c.stockMin.z - 1e-6 {
                issues.append(Issue(.error, "Cuts to Z\(CR1Post.fmt(minZ)), below the stock bottom (Z\(CR1Post.fmt(c.stockMin.z))): it would cut into the fixture."))
            }
            let depth = c.materialTop - minZ
            if depth > c.tool.stickout - 1 {
                issues.append(Issue(.error, "Cuts \(CR1Post.fmt(depth)) mm deep, but the tool only sticks out \(CR1Post.fmt(c.tool.stickout)) mm: the collet nut would hit the work."))
            } else if c.tool.kind == .threadMill && depth > c.tool.fluteLength + 1e-6 {
                // A thread mill's neck is thinner than its cutter; its reach counts from the hole's
                // top (the engine stops each thread there), which may be below a faced stock face.
                issues.append(Issue(.info, "Threads reach \(CR1Post.fmt(depth)) mm below the stock face; the thread mill's \(CR1Post.fmt(c.tool.fluteLength)) mm reach counts from each hole's top."))
            } else if c.tool.kind.cutsSideways && depth > c.tool.fluteLength + 1e-6 {
                if c.tool.shankDiameter > c.tool.diameter + 0.02 {
                    // The engine keeps a wider shank out of the part (3D: shank-aware drop cutter;
                    // 2.5D: stops at the flute length), so deeper points are where it clears.
                    issues.append(Issue(.info, "Reaches \(CR1Post.fmt(depth)) mm deep, below its \(CR1Post.fmt(c.tool.fluteLength)) mm flutes, only where its shank clears the part."))
                } else {
                    issues.append(Issue(.warning, "Cuts \(CR1Post.fmt(depth)) mm deep with \(CR1Post.fmt(c.tool.fluteLength)) mm flutes: the shank rubs deep walls (friction and heat)."))
                }
            }
            // The cutting area must fit the machine's travel.
            let span = hi - lo
            if span.x > machine.travel.x || span.y > machine.travel.y || span.z > machine.travel.z {
                issues.append(Issue(.error, "The toolpath spans \(CR1Post.fmt(span.x)) × \(CR1Post.fmt(span.y)) × \(CR1Post.fmt(span.z)) mm, more than the CR-1's travel."))
            }
            let margin = r + 6
            if lo.x < c.stockMin.x - margin || hi.x > c.stockMax.x + margin || lo.y < c.stockMin.y - margin || hi.y > c.stockMax.y + margin {
                issues.append(Issue(.warning, "Cutting moves reach more than \(CR1Post.fmt(margin)) mm outside the stock. Check that the clamps are clear."))
            }
        }
        if !gcode.contains("G53 G0 G90 Z-1.") {
            issues.append(Issue(.warning, "No full Z retract (G53 G0 G90 Z-1.) at the start/end."))
        }
        return Report(issues: issues, cutLength: cutLength, rapidLength: rapidLength, minZ: minZ,
                      extentMin: lo, extentMax: hi, lineCount: lines.count)
    }
}

/// A first time estimate: path length over feed, rapids at the axis limit, plus an
/// acceleration allowance at each sharp corner. (A later version may replace it with a grbl planner
/// simulation.)
public enum TimeEstimate {
    public static func seconds(_ paths: [OperationToolpath], machine: MachineProfile = .cr1) -> Double {
        ToolpathTimeline(paths: paths, programOf: [], lines: [], machine: machine).duration
    }
}
