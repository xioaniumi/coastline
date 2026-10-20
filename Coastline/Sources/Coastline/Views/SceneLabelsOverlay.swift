import CoastlineCore
import SwiftUI
import simd
import Viewport

/// A number or short text pinned to a point in the 3D view (model coordinates; `group` is the
/// motion group it moves with, e.g. "x" for things on the table).
struct SceneLabel: Identifiable, Equatable {
    var id: String
    var text: String
    var point: SIMD3<Float>
    var group: String? = "x"
    /// The one being talked about (the current prep step): full colour; others are dimmed.
    var emphasized = true
}

/// Draws `model.sceneLabels` over the viewport, following the camera.
struct SceneLabelsOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let _ = model.camera  // re-project when the camera moves
            ForEach(model.stockAnimating ? [] : model.sceneLabels) { l in
                let w = model.renderer.scene.groupTransform(l.group) * SIMD4(l.point, 1)
                if let p = model.project(SIMD3(w.x, w.y, w.z), geo.size), inSight(SIMD3(w.x, w.y, w.z), p, geo.size) {
                    Text(l.text)
                        .font(.system(size: l.emphasized ? 15 : 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: l.emphasized ? 26 : 20, minHeight: l.emphasized ? 26 : 20)
                        .background(Circle().fill(Theme.prepCut.opacity(l.emphasized ? 1 : 0.45)))
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: l.emphasized ? 1.5 : 0.5))
                        .shadow(radius: 2)
                        .position(p)
                        .allowsHitTesting(false)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Not behind the machine (its frame, enclosure and table): a ray from the eye to the label
    /// meets nothing of it first.
    private func inSight(_ w: SIMD3<Float>, _ p: CGPoint, _ size: CGSize) -> Bool {
        guard let tree = model.machineTree else { return true }
        let r = model.renderer.ray(at: p, viewSize: size)
        let o = SIMD3<Double>(r.origin), d = simd_normalize(SIMD3<Double>(r.direction))
        let dist = simd_dot(SIMD3<Double>(w) - o, d)
        guard let t = tree.raycast(o, d) else { return true }
        return t > dist - 2
    }
}

/// What the red on the part means, while it's shown.
struct UndercutLegend: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.9, green: 0.12, blue: 0.08)).frame(width: 14, height: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Red: faces turned away from the spindle").font(.caption.weight(.semibold))
                Text(model.twoSided
                     ? "The tool can't reach them from this side; side B (the part turned over) cuts them."
                     : "The tool can't reach them from this side: they stay uncut unless the job is done from both sides.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { model.showUndercutOverlay = false } label: {
                Label("Close", systemImage: "xmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .help("Hide the red (Display options ▸ Back Faces in Red shows it again)")
        }
        .padding(10)
        .frame(maxWidth: 340, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

/// What the magenta on the simulated stock means.
struct LooseLegend: View {
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.95, green: 0.15, blue: 0.75)).frame(width: 14, height: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Magenta: \(count == 1 ? "a piece" : "\(count) pieces") cut loose here").font(.caption.weight(.semibold))
                Text("Nothing joins \(count == 1 ? "it" : "them") to the clamped stock any more. On the machine \(count == 1 ? "it falls" : "they fall") out or the tool throws \(count == 1 ? "it" : "them"): stop and take \(count == 1 ? "it" : "them") out, or keep holding tabs.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: 340, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}
