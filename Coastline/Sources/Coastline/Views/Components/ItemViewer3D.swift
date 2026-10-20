import CoastlineCore
import Metal
import SwiftUI
import Viewport

/// A small realistic 3D view of one inventory item (tool, stock, fixture) that can be orbited
/// and zoomed like the workspace. Display space: Z up.
struct ItemViewer3D: View {
    /// Builds the item's meshes on the given device.
    let build: (MTLDevice) -> [SceneMesh]
    /// Changes when the item changes, to rebuild.
    let key: String
    @State private var renderer: ViewportRenderer?

    var body: some View {
        Group {
            if let renderer {
                ViewportContainer(renderer: renderer)
            } else {
                Color.clear
            }
        }
        .frame(height: 220)
        .onAppear { setUp() }
        .onChange(of: key) { _, _ in setUp() }
    }

    private func setUp() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let r = renderer ?? (try? ViewportRenderer(device: device))
        guard let r else { return }
        r.background = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)  // drawn on the card
        for m in r.scene.meshes { r.scene.remove(id: m.id) }
        for m in build(device) { r.scene.setMesh(m) }
        r.realistic = true
        r.animationsEnabled = false
        r.camera.set(.iso)
        r.camera.pitch = .pi / 7
        r.frameAll()
        r.camera.zoom(by: 0.8)
        renderer = r
    }
}

/// A preview card with a drawing and a 3D view, toggled in its corner.
struct PreviewCard<Drawing: View>: View {
    let drawing: Drawing
    let build: (MTLDevice) -> [SceneMesh]
    let key: String
    @AppStorage("inventoryPreview3D") private var show3D = false

    init(key: String, build: @escaping (MTLDevice) -> [SceneMesh], @ViewBuilder drawing: () -> Drawing) {
        self.key = key
        self.build = build
        self.drawing = drawing()
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if show3D { ItemViewer3D(build: build, key: key) } else { drawing.frame(height: 220) }
            Picker("Preview", selection: $show3D) {
                Text("Drawing").tag(false)
                Text("3D").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .padding(6)
            .help("Switch between the dimensioned drawing and a 3D view you can orbit (drag) and zoom (pinch)")
        }
        // One container: a single rounded panel for both the drawing and the 3D view.
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

extension StockItem {
    /// The stock as a solid block in its material, extrusion lines along its length.
    func sceneMeshes(device: MTLDevice) -> [SceneMesh] {
        let e = SIMD3<Float>(Float(envelope.x), Float(envelope.y), Float(envelope.z))
        let c = material?.linearSwatch ?? SIMD3(0.5, 0.5, 0.5)
        guard let m = SceneMesh.box(device: device, id: "item", min: -e / 2, max: e / 2, color: SIMD4(c, 1)) else { return [] }
        let metal = [.aluminium, .copperAlloy, .steel, .stainless, .titanium].contains(material?.family)
        var axis = SIMD3<Float>(0, 0, 0)
        axis[[e.x, e.y, e.z].enumerated().max { $0.element < $1.element }!.offset] = 1
        m.material = metal ? SurfaceMaterial(metallic: 1, roughness: 0.3, pattern: 1, axis: axis) : .plastic
        return [m]
    }
}

extension AppModel {
    /// Clamp-kit meshes for a fixture kind (kit-local frame, z up), if the kit has it.
    func fixtureMeshes(_ kind: Fixture.Kind, device: MTLDevice) -> [SceneMesh] {
        let kit: [String] = switch kind {
        case .universalClamp: ["clamp"]
        case .squaringBoss, .squaringStop: ["brick"]
        case .cClamp: ["cclamp"]
        case .vise: ["eccentric"]
        case .tSlotNuts: []
        default: []
        }
        return kitParts.enumerated().compactMap { j, p in
            guard kit.contains(p.kit) else { return nil }
            let look = Self.kitAppearance(p)
            let m = SceneMesh(device: device, id: "item.\(j)", positions: p.mesh.vertices, normals: p.mesh.normals,
                              indices: p.mesh.indices, color: look.color)
            m?.material = look.material
            return m
        }
    }
}
