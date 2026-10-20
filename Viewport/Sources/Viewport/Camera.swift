import simd

/// An orbit camera around a target point. World is Z-up, like the machine.
public struct OrbitCamera: Equatable, Sendable {
    public var target = SIMD3<Float>(0, 0, 0)
    public var distance: Float = 300
    /// Rotation about Z, radians. 0 looks along +Y.
    public var yaw: Float = -.pi / 4
    /// Elevation, radians; clamped to just short of straight up/down.
    public var pitch: Float = .pi / 6
    public var fieldOfView: Float = 35 * .pi / 180
    /// Orthographic by default: no perspective distortion, like engineering views in CAD.
    public var orthographic = true
    /// Point the camera orbits around (display space). nil = the view target.
    public var pivot: SIMD3<Float>?

    public init() {}

    public var eye: SIMD3<Float> {
        let cp = cos(pitch)
        return target + distance * SIMD3(cp * sin(yaw), -cp * cos(yaw), sin(pitch))
    }

    /// Turntable orbit. With a pivot, the view target swings around the pivot too, so the
    /// scene turns about that point (e.g. the mill's centre) rather than the screen centre.
    public mutating func orbit(dx: Float, dy: Float) {
        let oldDir = simd_normalize(eye - target)
        let newYaw = yaw - dx * 0.008
        let newPitch = min(max(pitch + dy * 0.008, -.pi / 2 + 0.01), .pi / 2 - 0.01)
        if let pivot {
            let qYaw = simd_quatf(angle: newYaw - yaw, axis: SIMD3(0, 0, 1))
            let afterYaw = qYaw.act(oldDir)
            var probe = self
            probe.yaw = newYaw
            probe.pitch = newPitch
            let newDir = simd_normalize(probe.eye - probe.target)
            let qPitch = simd_quatf(from: afterYaw, to: newDir)
            target = pivot + (qPitch * qYaw).act(target - pivot)
        }
        yaw = newYaw
        pitch = newPitch
    }

    /// Pans in the view plane; `dx`, `dy` in points, scaled so the target tracks the cursor.
    public mutating func pan(dx: Float, dy: Float, viewHeight: Float) {
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 0, 1)))
        let up = simd_cross(right, forward)
        let worldPerPoint = 2 * distance * tan(fieldOfView / 2) / max(viewHeight, 1)
        target += (-dx * right + dy * up) * worldPerPoint
    }

    public mutating func zoom(by factor: Float) {
        distance = min(max(distance * factor, 2), 5000)
    }

    /// Frames a bounding box so it fills the view.
    public mutating func frame(min lo: SIMD3<Float>, max hi: SIMD3<Float>) {
        target = (lo + hi) / 2
        let radius = max(simd_length(hi - lo) / 2, 1)
        distance = radius / sin(fieldOfView / 2) * 1.05
    }

    /// Standard views in display space (Z up, the operator looks along +Y).
    /// `tool` looks down the spindle at the face being cut (the CAM "top" view on the CR-1).
    public enum StandardView: String, CaseIterable, Sendable {
        case tool, front, top, right, left, iso, toolIso

        public var title: String {
            switch self {
            case .tool: "Tool"
            case .front: "Front"
            case .top: "Top"
            case .right: "Right"
            case .left: "Left"
            case .iso: "Iso"
            case .toolIso: "Tool Iso"
            }
        }
    }

    public mutating func set(_ view: StandardView) {
        switch view {
        case .tool: (yaw, pitch) = (.pi, 0)
        case .front: (yaw, pitch) = (0, 0)
        case .top: (yaw, pitch) = (0, .pi / 2 - 0.01)
        case .right: (yaw, pitch) = (.pi / 2, 0)
        case .left: (yaw, pitch) = (-.pi / 2, 0)
        case .iso: (yaw, pitch) = (.pi / 4, .pi / 6)  // front-right, from above
        case .toolIso: (yaw, pitch) = (.pi * 0.75, .pi / 6)  // spindle side: sees the face being cut
        }
    }

    /// Looks along `direction` (display space, from the target toward the eye).
    public mutating func look(from direction: SIMD3<Float>) {
        let d = simd_normalize(direction)
        pitch = min(max(asin(d.z), -.pi / 2 + 0.01), .pi / 2 - 0.01)
        yaw = atan2(d.x, -d.y)
    }

    /// Unit vector from the target to the eye, in display space.
    public var viewDirection: SIMD3<Float> { simd_normalize(eye - target) }

    public func viewMatrix() -> simd_float4x4 {
        // Orthographic: put the eye far outside the scene, so nothing is ever "behind" it
        // (zoom is the view height, not the eye distance).
        let e = orthographic ? target + viewDirection * (distance + Self.orthoStandOff) : eye
        return lookAt(eye: e, target: target, up: SIMD3(0, 0, 1))
    }

    static let orthoStandOff: Float = 3000

    public func projectionMatrix(aspect: Float) -> simd_float4x4 {
        let near = max(distance * 0.01, 0.1)
        let far = distance * 20 + 2000
        if orthographic {
            let h = distance * tan(fieldOfView / 2)
            return ortho(left: -h * aspect, right: h * aspect, bottom: -h, top: h, near: 1,
                         far: distance * 2 + Self.orthoStandOff * 2)
        }
        return perspective(fovY: fieldOfView, aspect: aspect, near: near, far: far)
    }
}

func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = simd_normalize(target - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)
    return simd_float4x4(columns: (
        SIMD4(s.x, u.x, -f.x, 0),
        SIMD4(s.y, u.y, -f.y, 0),
        SIMD4(s.z, u.z, -f.z, 0),
        SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
    ))
}

/// Right-handed perspective with **reversed** depth (near → 1, far → 0): with a float depth
/// buffer that keeps precision even far from the camera, so touching faces don't flicker.
func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovY / 2)
    let x = y / aspect
    let a = near / (far - near)
    return simd_float4x4(columns: (
        SIMD4(x, 0, 0, 0),
        SIMD4(0, y, 0, 0),
        SIMD4(0, 0, a, -1),
        SIMD4(0, 0, far * a, 0)
    ))
}

/// Orthographic, reversed depth (near → 1, far → 0) like `perspective`.
func ortho(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> simd_float4x4 {
    simd_float4x4(columns: (
        SIMD4(2 / (right - left), 0, 0, 0),
        SIMD4(0, 2 / (top - bottom), 0, 0),
        SIMD4(0, 0, 1 / (far - near), 0),
        SIMD4((left + right) / (left - right), (top + bottom) / (bottom - top), far / (far - near), 1)
    ))
}

/// Depth convention: reversed (see `perspective`).
public enum DepthConvention {
    public static let clear: Double = 0
    public static let near: Float = 1, far: Float = 0
}
