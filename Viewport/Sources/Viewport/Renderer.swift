import QuartzCore
import CoreGraphics
import ImageIO
import Metal
import MetalKit
import simd
import UniformTypeIdentifiers

/// Must match `Uniforms` in Shaders.swift.
struct Uniforms {
    var viewProjection: simd_float4x4
    var cameraPosition: SIMD4<Float>
    var lightDirection: SIMD4<Float>
    var viewportSize: SIMD2<Float>
    var lineWidth: Float
    var time: Float
    var clipPlane: SIMD4<Float>
    var up: SIMD4<Float>
    var options: SIMD4<Float>
    var lightViewProjection = matrix_identity_float4x4
    var shadow = SIMD4<Float>(0, 0, 1, 0)
}

/// Surface parameters for realistic shading (layout matches `Surface` in the shader).
public struct SurfaceMaterial: Equatable, Sendable {
    public var metallic: Float
    public var roughness: Float
    /// 0 plain, 1 extrusion / brushing streaks along `axis` (world, mesh-local before transform).
    public var pattern: Float
    /// Rounded-edge highlight strength (0…1).
    public var edges: Float
    public var axis: SIMD3<Float>

    public init(metallic: Float = 0, roughness: Float = 0.5, pattern: Float = 0, edges: Float = 1, axis: SIMD3<Float> = SIMD3(0, 1, 0)) {
        self.metallic = metallic
        self.roughness = roughness
        self.pattern = pattern
        self.edges = edges
        self.axis = axis
    }

    public static let paint = SurfaceMaterial(metallic: 0, roughness: 0.42)
    public static let plastic = SurfaceMaterial(metallic: 0, roughness: 0.35)
    public static let rubber = SurfaceMaterial(metallic: 0, roughness: 0.9, edges: 0.3)
    public static let aluminium = SurfaceMaterial(metallic: 1, roughness: 0.32)
    public static let chrome = SurfaceMaterial(metallic: 1, roughness: 0.08)
    public static let mirror = SurfaceMaterial(metallic: 1, roughness: 0.03)
    public static let blackOxide = SurfaceMaterial(metallic: 0.7, roughness: 0.45)
    public static let carbide = SurfaceMaterial(metallic: 1, roughness: 0.22)
}

/// Draws a `ViewportScene` with an `OrbitCamera`, on screen (MTKView) or off screen (snapshots).
@MainActor
public final class ViewportRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    public let scene: ViewportScene
    public var camera = OrbitCamera()
    /// Called after a frame whose camera differs from the previous one (drives the view cube).
    public var onCameraChange: ((OrbitCamera) -> Void)?
    private var lastCamera: OrbitCamera?
    /// An eased camera move in progress (view cube clicks, standard views, framing).
    private var cameraAnimation: (from: OrbitCamera, to: OrbitCamera, start: CFTimeInterval, duration: Double)?
    /// Off for automation runs, so snapshots see the final view straight away.
    public var animationsEnabled = true
    public var lineWidth: Float = 2.0
    /// Scene (world) → display space. The camera is Z-up in display space; the scene can be in
    /// any frame. Coastline's scene is in CR-1 machine axes (X up), so it passes `machineToDisplay`.
    public var worldToDisplay = matrix_identity_float4x4

    /// CR-1 machine axes → Z-up display: machine Y (operator's right) → display X, machine Z
    /// (toward the spindle, away from the operator) → display Y, machine X (up) → display Z.
    public static let machineToDisplay = simd_float4x4(rows: [
        SIMD4(0, 1, 0, 0),
        SIMD4(0, 0, 1, 0),
        SIMD4(1, 0, 0, 0),
        SIMD4(0, 0, 0, 1),
    ])
    /// Linear-space clear colour (≈ sRGB #2A2D33, a neutral dark studio grey).
    public var background = MTLClearColor(red: 0.0062, green: 0.0072, blue: 0.0094, alpha: 1)  // ≈ #131518 (linear)
    public static let sampleCount = 4
    static let colorFormat = MTLPixelFormat.bgra8Unorm_srgb
    /// Depth plus a stencil: the stock marks its pixels, so x-ray toolpaths show through the
    /// stock only (never through clamps or the machine).
    static let depthFormat = MTLPixelFormat.depth32Float_stencil8

    private let queue: MTLCommandQueue
    private let meshPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let meshDepth: MTLDepthStencilState
    private let shadowPipeline: MTLRenderPipelineState
    private let shadowDepth: MTLDepthStencilState
    private var shadowMap: MTLTexture?
    static let shadowSize = 2048
    static let shadowDebug = ProcessInfo.processInfo.environment["COASTLINE_SHADOW_DEBUG"] != nil
    private let lineDepth: MTLDepthStencilState  // also used for translucent meshes
    private let noDepth: MTLDepthStencilState
    private let xrayDepth: MTLDepthStencilState
    /// Realistic (physically based) shading instead of the flat CAD look.
    public var realistic = false
    private let start = Date()
    /// Last frame's GPU time, for the stats overlay.
    public private(set) var lastFrameMilliseconds: Double = 0

    public init(device: MTLDevice) throws {
        self.device = device
        scene = ViewportScene(device: device)
        queue = device.makeCommandQueue()!
        let library = try device.makeLibrary(source: viewportShaderSource, options: nil)

        func pipeline(_ vertex: String, _ fragment: String, blended: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = Self.colorFormat
            d.depthAttachmentPixelFormat = Self.depthFormat
            d.stencilAttachmentPixelFormat = Self.depthFormat
            d.rasterSampleCount = Self.sampleCount
            if blended {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        meshPipeline = try pipeline("mesh_vertex", "mesh_fragment", blended: true)
        linePipeline = try pipeline("line_vertex", "line_fragment", blended: true)

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: Self.shadowSize, height: Self.shadowSize, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        shadowMap = device.makeTexture(descriptor: td)
        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = library.makeFunction(name: "shadow_vertex")
        sd.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline = try device.makeRenderPipelineState(descriptor: sd)
        let sdd = MTLDepthStencilDescriptor()
        sdd.depthCompareFunction = .less
        sdd.isDepthWriteEnabled = true
        shadowDepth = device.makeDepthStencilState(descriptor: sdd)!

        let md = MTLDepthStencilDescriptor()
        md.depthCompareFunction = .greater  // reversed depth
        md.isDepthWriteEnabled = true
        // Each opaque mesh writes its stencil value where it's the nearest: 1 for the stock
        // (x-ray shows through it), 0 for everything else.
        let mark = MTLStencilDescriptor()
        mark.stencilCompareFunction = .always
        mark.depthStencilPassOperation = .replace
        md.frontFaceStencil = mark
        md.backFaceStencil = mark
        meshDepth = device.makeDepthStencilState(descriptor: md)!
        let xd = MTLDepthStencilDescriptor()
        xd.depthCompareFunction = .always
        xd.isDepthWriteEnabled = false
        let onStock = MTLStencilDescriptor()
        onStock.stencilCompareFunction = .equal
        onStock.writeMask = 0
        xd.frontFaceStencil = onStock
        xd.backFaceStencil = onStock
        xrayDepth = device.makeDepthStencilState(descriptor: xd)!
        let ld = MTLDepthStencilDescriptor()
        ld.depthCompareFunction = .greaterEqual
        ld.isDepthWriteEnabled = false
        lineDepth = device.makeDepthStencilState(descriptor: ld)!
        let nd = MTLDepthStencilDescriptor()
        nd.depthCompareFunction = .always
        nd.isDepthWriteEnabled = false
        noDepth = device.makeDepthStencilState(descriptor: nd)!
        super.init()
    }

    // MARK: Drawing on change

    private var lastSignature: Int?
    private var lastDrawAt: CFTimeInterval = 0
    /// Forces the next frame to draw (e.g. after rewriting a buffer the signature can't see).
    public func setNeedsRedraw() { lastSignature = nil }

    /// A hash of everything a frame shows: camera, view settings and the scene's contents.
    private func frameSignature(size: CGSize) -> Int {
        var h = Hasher()
        let c = camera
        h.combine(c.target); h.combine(c.distance); h.combine(c.yaw); h.combine(c.pitch)
        h.combine(c.fieldOfView); h.combine(c.orthographic); h.combine(c.pivot)
        h.combine(size.width); h.combine(size.height)
        h.combine(lineWidth); h.combine(realistic)
        h.combine(background.red); h.combine(background.green); h.combine(background.blue); h.combine(background.alpha)
        Self.combine(&h, worldToDisplay)
        h.combine(scene.clipPlane)
        for k in scene.groupTransforms.keys.sorted() {
            h.combine(k)
            Self.combine(&h, scene.groupTransforms[k]!)
        }
        for m in scene.meshes {
            h.combine(ObjectIdentifier(m)); h.combine(m.isVisible); h.combine(m.color)
            Self.combine(&h, m.transform)
            h.combine(m.depthBias); h.combine(m.onTop); h.combine(m.unlit); h.combine(m.group)
            h.combine(m.material.metallic); h.combine(m.material.roughness); h.combine(m.material.pattern)
            h.combine(m.material.edges); h.combine(m.material.axis)
            h.combine(m.contentVersion); h.combine(m.xrayThrough)
        }
        for l in scene.lines {
            h.combine(ObjectIdentifier(l)); h.combine(l.isVisible); h.combine(l.xray)
            h.combine(l.visibleCount); h.combine(l.group)
        }
        return h.finalize()
    }

    private static func combine(_ h: inout Hasher, _ m: simd_float4x4) {
        h.combine(m.columns.0); h.combine(m.columns.1); h.combine(m.columns.2); h.combine(m.columns.3)
    }

    // MARK: MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        let animating = cameraAnimation != nil
        stepCameraAnimation()
        // Only draw when something changed: an unchanged frame looks the same (the shaders
        // don't animate), and redrawing the machine 120 times a second kept the GPU and the
        // fans busy for nothing. A frame a second anyway, in case a change slipped past.
        let signature = frameSignature(size: view.drawableSize)
        let now = CACurrentMediaTime()
        if !animating, signature == lastSignature, now - lastDrawAt < 1.0 { return }
        lastSignature = signature
        lastDrawAt = now
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].clearColor = background
        encode(commands, pass: pass, size: view.drawableSize, scale: Float(view.window?.backingScaleFactor ?? 2))
        commands.present(drawable)
        if camera != lastCamera {
            lastCamera = camera
            onCameraChange?(camera)
        }
        commands.addCompletedHandler { [weak self] cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            Task { @MainActor in self?.lastFrameMilliseconds = ms }
        }
        commands.commit()
    }

    // MARK: Encoding

    /// The overhead studio light's shadow map (realistic mode): opaque meshes rendered depth-only
    /// from above, fitted to what's visible. Returns the world → map matrix and the light
    /// direction (towards the light, world).
    private func encodeShadows(_ commands: MTLCommandBuffer, displayToWorld: simd_float4x4) -> (simd_float4x4, SIMD3<Float>)? {
        let opaque = scene.meshes.filter { $0.isVisible && !$0.isTranslucent }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for m in opaque {
            let t = scene.groupTransform(m.group) * m.transform
            for i in 0..<8 {
                let c = SIMD3(i & 1 == 0 ? m.boundsMin.x : m.boundsMax.x, i & 2 == 0 ? m.boundsMin.y : m.boundsMax.y,
                              i & 4 == 0 ? m.boundsMin.z : m.boundsMax.z)
                let w = t * SIMD4(c, 1)
                lo = simd_min(lo, SIMD3(w.x, w.y, w.z))
                hi = simd_max(hi, SIMD3(w.x, w.y, w.z))
            }
        }
        guard lo.x <= hi.x else { return nil }
        guard let map = shadowMap else { return nil }
        // A softbox above the CR-1's open front (model: X up, Z toward the spindle, so the
        // operator's side is −Z), a little to the right: it lights the work through the opening.
        let light = simd_normalize(SIMD3<Float>(0.9, 0.3, -1.0))
        let centre = (lo + hi) / 2, r = max(simd_length(hi - lo) / 2, 1)
        let upHint: SIMD3<Float> = abs(light.z) > 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1)
        let view = lookAt(eye: centre + light * r * 2, target: centre, up: upHint)
        let proj = simd_float4x4(columns: (SIMD4(1 / r, 0, 0, 0), SIMD4(0, 1 / r, 0, 0), SIMD4(0, 0, -1 / (4 * r), 0),
                                           SIMD4(0, 0, 0.0, 1)))  // standard depth: eye 0 … 4r → 0 … 1
        var lightVP = proj * view
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = map
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1
        guard let enc = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setRenderPipelineState(shadowPipeline)
        enc.setDepthStencilState(shadowDepth)
        enc.setCullMode(.none)
        enc.setDepthBias(0.0005, slopeScale: 2, clamp: 0.01)
        enc.setVertexBytes(&lightVP, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        // The enclosure doesn't cast (the light comes in through its opening).
        for m in opaque where !(m.id.hasPrefix("machine.") && m.id.contains("enclosure")) {
            var model = scene.groupTransform(m.group) * m.transform
            enc.setVertexBuffer(m.vertexBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&model, length: MemoryLayout<simd_float4x4>.stride, index: 2)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: m.indexCount, indexType: .uint32,
                                      indexBuffer: m.indexBuffer, indexBufferOffset: 0)
        }
        enc.endEncoding()
        return (lightVP, light)
    }

    private func encode(_ commands: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize, scale: Float) {
        let shadow = realistic ? encodeShadows(commands, displayToWorld: worldToDisplay.inverse) : nil
        guard let enc = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let aspect = Float(size.width / max(size.height, 1))
        let vp = camera.projectionMatrix(aspect: aspect) * camera.viewMatrix() * worldToDisplay
        let displayToWorld = worldToDisplay.inverse
        let eye = camera.eye
        // Key light from over the viewer's right shoulder (computed in display space, where the
        // camera lives), then expressed in world space for the shader.
        let toEye = simd_normalize(eye - camera.target)
        let right = simd_normalize(simd_cross(toEye, SIMD3(0, 0, 1)))
        let lightDisplay = simd_normalize(toEye + 0.6 * right + SIMD3(0, 0, 1.2))
        let eyeWorld = displayToWorld * SIMD4(eye, 1)
        let lightWorld = displayToWorld * SIMD4(lightDisplay, 0)
        let upWorld = displayToWorld * SIMD4<Float>(0, 0, 1, 0)
        var u = Uniforms(viewProjection: vp, cameraPosition: eyeWorld, lightDirection: lightWorld,
                         viewportSize: SIMD2(Float(size.width), Float(size.height)),
                         lineWidth: lineWidth * scale, time: Float(Date().timeIntervalSince(start)),
                         clipPlane: scene.clipPlane, up: upWorld, options: SIMD4(realistic ? 1 : 0, 0, Self.shadowDebug ? 1 : 0, 0))
        if let (lvp, l) = shadow {
            u.lightViewProjection = lvp
            u.shadow = SIMD4(l, 1)
            enc.setFragmentTexture(shadowMap, index: 0)
        } else {
            enc.setFragmentTexture(shadowMap, index: 0)  // bound but unused (shadows off)
        }

        enc.setRenderPipelineState(meshPipeline)
        enc.setDepthStencilState(meshDepth)
        enc.setCullMode(.none)
        enc.setFrontFacing(.counterClockwise)  // OCCT and Rhino wind front faces CCW
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        // Opaque meshes first (writing depth), then translucent ones (stock) without depth
        // writes, so the part shows through the stock.
        let visible = scene.meshes.filter(\.isVisible)
        let ordered = visible.filter { !$0.isTranslucent && !$0.onTop } + visible.filter { $0.isTranslucent && !$0.onTop } + visible.filter(\.onTop)
        for m in ordered {
            enc.setDepthStencilState(m.onTop ? noDepth : m.isTranslucent ? lineDepth : meshDepth)
            enc.setStencilReferenceValue(m.xrayThrough ? 1 : 0)
            // Faces that touch (a jaw on the stock, the part on the simulated surface) get a fixed
            // winner instead of flickering: positive bias pulls toward the camera (reversed depth).
            enc.setDepthBias(m.depthBias * 4e-7, slopeScale: m.depthBias * 1.0, clamp: 0)
            var model = scene.groupTransform(m.group) * m.transform
            var color = m.color
            let mat = m.material
            let axisWorld = model * SIMD4(mat.axis, 0)
            var surface = (SIMD4(mat.metallic, mat.roughness, mat.pattern, mat.edges), SIMD4(axisWorld.x, axisWorld.y, axisWorld.z, m.unlit ? 1 : 0))
            enc.setVertexBuffer(m.vertexBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&model, length: MemoryLayout<simd_float4x4>.stride, index: 2)
            enc.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
            enc.setFragmentBytes(&surface, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 4)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: m.indexCount, indexType: .uint32,
                                      indexBuffer: m.indexBuffer, indexBufferOffset: 0)
        }

        enc.setRenderPipelineState(linePipeline)
        // X-ray: lines marked so (toolpaths) are drawn faintly through solid stock first, then
        // normally on top, so they stay readable inside an opaque, realistic stock.
        enc.setDepthStencilState(xrayDepth)
        enc.setStencilReferenceValue(1)
        for l in scene.lines where l.isVisible && l.visibleCount > 0 && l.xray > 0 {
            var visible = Float(l.visibleCount)
            var model = scene.groupTransform(l.group)
            var u2 = u
            u2.options.y = l.xray
            enc.setVertexBytes(&u2, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u2, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setVertexBuffer(l.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&visible, length: 4, index: 2)
            enc.setVertexBytes(&model, length: MemoryLayout<simd_float4x4>.stride, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: l.count)
        }
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setDepthStencilState(lineDepth)
        for l in scene.lines where l.isVisible && l.visibleCount > 0 {
            var visible = Float(l.visibleCount)
            var model = scene.groupTransform(l.group)
            enc.setVertexBuffer(l.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&visible, length: 4, index: 2)
            enc.setVertexBytes(&model, length: MemoryLayout<simd_float4x4>.stride, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: l.count)
        }
        enc.endEncoding()
    }

    // MARK: Picking

    /// The world-space ray under a point in the view (points, origin top-left).
    public func ray(at point: CGPoint, viewSize: CGSize) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let aspect = Float(viewSize.width / max(viewSize.height, 1))
        let inv = (camera.projectionMatrix(aspect: aspect) * camera.viewMatrix() * worldToDisplay).inverse
        let x = Float(point.x / viewSize.width) * 2 - 1
        let y = 1 - Float(point.y / viewSize.height) * 2
        let near = inv * SIMD4(x, y, DepthConvention.near, 1), far = inv * SIMD4(x, y, DepthConvention.far, 1)
        let a = SIMD3(near.x, near.y, near.z) / near.w, b = SIMD3(far.x, far.y, far.z) / far.w
        return (a, simd_normalize(b - a))
    }

    /// Frames the visible meshes (world bounds are converted to display space first).
    // MARK: Camera moves

    /// Where the camera is heading (the end of a running animation, else the camera itself).
    /// Changes compose: "Iso view, then frame the work" animates once, to both.
    public var destinationCamera: OrbitCamera { cameraAnimation?.to ?? camera }

    /// Changes the camera, easing from the current view (in-out cubic) when animated.
    public func moveCamera(animated: Bool = true, duration: Double? = nil, _ change: (inout OrbitCamera) -> Void) {
        var to = destinationCamera
        change(&to)
        guard animated, animationsEnabled, to != camera else {
            cameraAnimation = nil
            camera = to
            return
        }
        // Turn the short way round.
        while to.yaw - camera.yaw > .pi { to.yaw -= 2 * .pi }
        while to.yaw - camera.yaw < -.pi { to.yaw += 2 * .pi }
        // Longer for bigger turns, so a half-turn to the opposite face reads as a turn.
        let angle = Double(abs(to.yaw - camera.yaw) + abs(to.pitch - camera.pitch))
        let d = duration ?? (0.5 + 0.45 * min(angle / .pi, 1))
        cameraAnimation = (camera, to, CACurrentMediaTime(), d)
    }

    /// Stops an animation where it is (the user grabbed the view).
    public func cancelCameraAnimation() { cameraAnimation = nil }

    private func stepCameraAnimation() {
        guard let a = cameraAnimation else { return }
        let t = min((CACurrentMediaTime() - a.start) / a.duration, 1)
        // Ease in-out (sine): gentle start and landing without a sudden middle.
        let e = Float(0.5 - 0.5 * cos(Double.pi * t))
        var c = a.to
        c.yaw = a.from.yaw + (a.to.yaw - a.from.yaw) * e
        c.pitch = a.from.pitch + (a.to.pitch - a.from.pitch) * e
        c.target = a.from.target + (a.to.target - a.from.target) * e
        c.distance = a.from.distance * pow(a.to.distance / max(a.from.distance, 1e-3), e)  // even zoom speed
        camera = c
        if t >= 1 { cameraAnimation = nil }
    }

    public func frameAll(animated: Bool = false) {
        guard let (lo, hi) = scene.visibleBounds() else { return }
        var dlo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), dhi = -dlo
        for i in 0..<8 {
            let c = SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
            let d = worldToDisplay * SIMD4(c, 1)
            dlo = simd_min(dlo, SIMD3(d.x, d.y, d.z))
            dhi = simd_max(dhi, SIMD3(d.x, d.y, d.z))
        }
        moveCamera(animated: animated) { $0.frame(min: dlo, max: dhi) }
    }

    /// Sets the orbit pivot from a world-space point (nil = orbit around the view target).
    public func setPivot(world p: SIMD3<Float>?) {
        camera.pivot = p.map { let d = worldToDisplay * SIMD4($0, 1); return SIMD3(d.x, d.y, d.z) }
    }

    /// Frames a world-space box.
    public func frame(worldMin lo: SIMD3<Float>, worldMax hi: SIMD3<Float>, animated: Bool = false) {
        let a = worldToDisplay * SIMD4(lo, 1), b = worldToDisplay * SIMD4(hi, 1)
        moveCamera(animated: animated) {
            $0.frame(min: simd_min(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)), max: simd_max(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)))
        }
    }

    // MARK: Snapshots

    /// Renders the scene off screen and writes a PNG. Used for guided-step images and UI tests.
    public func snapshot(width: Int, height: Int, to url: URL) throws {
        func texture(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage, storage: MTLStorageMode) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.usage = usage
            d.storageMode = storage
            return device.makeTexture(descriptor: d)!
        }
        let msaa = texture(Self.colorFormat, samples: Self.sampleCount, usage: .renderTarget, storage: .private)
        let resolve = texture(Self.colorFormat, samples: 1, usage: [.renderTarget, .shaderRead], storage: .shared)
        let depth = texture(Self.depthFormat, samples: Self.sampleCount, usage: .renderTarget, storage: .private)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = resolve
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = background
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = DepthConvention.clear
        pass.stencilAttachment.texture = depth
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.storeAction = .dontCare
        pass.stencilAttachment.clearStencil = 0

        let commands = queue.makeCommandBuffer()!
        encode(commands, pass: pass, size: CGSize(width: width, height: height), scale: 2)
        commands.commit()
        commands.waitUntilCompleted()
        lastFrameMilliseconds = (commands.gpuEndTime - commands.gpuStartTime) * 1000

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        resolve.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
