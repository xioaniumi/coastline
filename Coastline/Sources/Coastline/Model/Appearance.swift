import CoastlineCore
import Foundation
import simd
import Viewport

/// How the stock is drawn.
enum StockDisplay: String, CaseIterable, Identifiable {
    case realistic, seeThrough, wireframe, hidden
    var id: Self { self }
    var title: String {
        switch self {
        case .realistic: "Solid"
        case .seeThrough: "See-through"
        case .wireframe: "Edges only"
        case .hidden: "Hidden"
        }
    }
}

extension AppModel {
    /// Surfaces for realistic shading, by what each mesh is. The flat view only uses colours.
    func applySurfaces() {
        let metal = stock.map { [.aluminium, .copperAlloy, .steel, .stainless, .titanium].contains($0.material?.family) } ?? true
        // Bar stock is extruded along its longest side.
        let size = stock.map { setup.stockSize($0) } ?? SIMD3(1, 2, 1)
        let longest = [size.x, size.y, size.z].enumerated().max { $0.element < $1.element }!.offset
        var axis = SIMD3<Float>(0, 0, 0)
        axis[longest] = 1
        for m in renderer.scene.meshes {
            let id = m.id
            if id.hasPrefix("machine.") {
                let role = id.split(separator: ".").dropFirst(2).first.map(String.init) ?? ""
                m.material = Self.machineSurface(role)
            } else if id.hasPrefix("fixture.") {
                if id.contains("parallel") {
                    m.material = SurfaceMaterial(metallic: 1, roughness: 0.18, pattern: 1, axis: SIMD3(0, 1, 0))
                } else {
                    m.material = Self.fixtureSurface(id: id, color: m.color)
                }
            } else if id == "stock" || id == "simstock" || id == "simstock.back" || id == "simstock.walls" {
                m.material = metal ? SurfaceMaterial(metallic: 1, roughness: 0.3, pattern: 1, axis: axis)
                                   : SurfaceMaterial(metallic: 0, roughness: 0.45, pattern: 0, edges: 0.6)
            } else if id == "part" {
                // The finished part: freshly machined, so smoother than the bar.
                m.material = metal ? SurfaceMaterial(metallic: 1, roughness: 0.16) : .plastic
            }
        }
    }

    static func machineSurface(_ role: String) -> SurfaceMaterial {
        let r = role.hasPrefix("enclosure_") ? String(role.dropFirst("enclosure_".count)) : role
        switch r {
        case "enclosure": return .paint
        case "mirror": return .mirror
        case "steel": return .chrome
        case "fastener": return .blackOxide
        case "motor": return SurfaceMaterial(metallic: 0.3, roughness: 0.5)
        case "belt": return .rubber
        case "guard": return .mirror  // the polished plate in front of the spindle: a plain mirror
        case "pcb", "estop": return .plastic
        default: return .aluminium  // frame parts, carriages, table
        }
    }

    /// How a clamp-kit part looks wherever it's drawn (workspace, inventory): the insulating
    /// feet and washers are clear plastic, the rest keeps its kit colour.
    static func kitAppearance(_ p: FixturePart) -> (color: SIMD4<Float>, material: SurfaceMaterial) {
        if p.role == "insulator" { return (SIMD4(0.86, 0.9, 0.93, 0.35), SurfaceMaterial(metallic: 0, roughness: 0.05, edges: 0.8)) }
        let c = SIMD4(p.color, 1)
        return (c, fixtureSurface(id: "fixture", color: c))
    }

    static func fixtureSurface(id: String, color: SIMD4<Float>) -> SurfaceMaterial {
        // Fixture meshes keep their kit colours; the colour tells the material.
        let c = SIMD3(color.x, color.y, color.z)
        if c.x > 0.7 && c.y > 0.7 { return SurfaceMaterial(metallic: 0, roughness: 0.55, edges: 0.5) }  // acetal
        if c.x > 0.3 && c.y < 0.2 { return SurfaceMaterial(metallic: 0, roughness: 0.6, edges: 0.4) }   // insulator
        if simd_length(c) < 0.15 { return .blackOxide }                                                    // screws
        return SurfaceMaterial(metallic: 1, roughness: 0.28)                                                // aluminium
    }

    /// Stock drawing per `stockDisplay`.
    func applyStockDisplay() {
        let scene = renderer.scene
        let simulating = scene.mesh("simstock") != nil
        // Stage 1 is about the part inside the stock: always see-through there.
        let alpha: Float = showingStockOnly || stockDisplay == .seeThrough || (!realistic && stockDisplay == .realistic) ? 0.22 : 1
        if let m = scene.mesh("stock") {
            m.isVisible = !simulating && (stockDisplay == .realistic || stockDisplay == .seeThrough)
            m.color.w = alpha
        }
        for id in ["simstock", "simstock.back", "simstock.walls", "simstock.loose"] {
            guard let m = scene.mesh(id) else { continue }
            m.isVisible = stockDisplay != .hidden && stockDisplay != .wireframe
            if id != "simstock.loose" { m.color.w = stockDisplay == .seeThrough ? 0.45 : 1 }
            // X-ray toolpaths show through the stock only, never through clamps or the machine.
            m.xrayThrough = id != "simstock.loose"
        }
        scene.mesh("stock")?.xrayThrough = true
        scene.lineSet("stock.edges")?.isVisible = stockDisplay != .hidden
        scene.lineSet("toolpath")?.xray = realistic ? 0.35 : 0
    }
}
