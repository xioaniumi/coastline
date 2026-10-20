import CoastlineCore
import Foundation
import simd

/// Rhino-style typed moves: click an arrow or a ring of the gumball (without dragging) and type
/// how far to move or turn. Arrows take millimetres, rings degrees.
struct GumballPrompt: Equatable {
    var axis: String
    var target: AppModel.GumballTarget
    var point: CGPoint
    var isRing: Bool { axis.hasPrefix("gumball.ring") }
    var title: String {
        let name = ["gumball.x": "Up / down", "gumball.y": "Along Y", "gumball.z": "Toward the spindle",
                    "gumball.ring.x": "Turn about X", "gumball.ring.y": "Turn about Y", "gumball.ring.z": "Turn about Z"][axis] ?? "Move"
        return name
    }
    var unit: String { isRing ? "°" : "mm" }
}

extension AppModel {
    /// Applies a typed move or turn to what the gumball holds.
    func applyTyped(_ v: Double, _ prompt: GumballPrompt) {
        defer { gumballPrompt = nil; layoutGumball() }
        guard v.isFinite, abs(v) > 1e-9 else { return }
        switch prompt.target {
        case .part:
            if let k = Self.ringIDs.firstIndex(of: prompt.axis) {
                let q = Int((v / 90).rounded())
                guard q != 0 else { status = "The part turns in quarter turns (90°)."; return }
                setup = placementLimited(setup.turned(about: k, quarterTurns: q))
                return
            }
            var s = setup
            switch prompt.axis {
            case "gumball.x": s.partOffsetX += v
            case "gumball.y": s.partOffsetY += v
            default: s.topAllowance -= v
            }
            let limited = placementLimited(s)
            if limited != s { status = "Moved as far as the part's frame allows." }
            setup = limited
        case .bed(.stop):
            let r = stopRange
            editPrep { $0.stopShiftY = min(max($0.stopShiftY + v, -r), r) }
        case .bed(.clamp(let i)):
            if prompt.isRing {
                let p = currentBedPlacement
                let a = (p.map { i < $0.clampAngles.count ? $0.clampAngles[i] : 0 } ?? 0) + v * .pi / 180
                setClampAngle(i, a)
            } else {
                editPrep { if prompt.axis == "gumball.y" { $0.clamps[i].dy += v } else { $0.clamps[i].dz += v } }
            }
        case .bed(.kitClamp(let i)):
            setKitClampShift(i, kitClampShift(i) + v)
        case .bed(.kitStock):
            setProtrusion(effectiveProtrusion + v)
        }
    }
}
