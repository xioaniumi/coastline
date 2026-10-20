import AppKit
import CoastlineCore
import SwiftUI
import UniformTypeIdentifiers

/// Print a Nest: a block with a cavity shaped like one face of the part, for machining the other
/// face of a part that's already cut free (a second side without tabs, a batch of finished parts,
/// an engraving on the back). Printed in Rigid 10K or Tough 2000; it clamps in the universal clamp
/// like stock.
struct NestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var face: AppModel.NestFace = .front
    @State private var clearance = 0.1
    @State private var wall = 4.0
    @State private var nest: EngineClient.Nest?
    @State private var working = false
    @State private var message: String?

    private static let preform = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.formlabs.PreForm")
        ?? ["/Applications/PreForm.app"].map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Print a Nest").font(.title2.weight(.semibold))
                Text("For a part that's already cut free: it sits face-down in a cavity shaped like that face, and the other face is machined. Print it, then clamp it in the universal clamp like stock.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Form {
                Picker("In the nest", selection: $face) {
                    ForEach(AppModel.NestFace.allCases) { Text($0.title).tag($0) }
                }
                NumberField(title: "Clearance", value: $clearance,
                            tip: "Gap between the part and the cavity, all round. 0.1 mm suits Rigid 10K at 50 µm; tighter grips better but may need sanding; looser needs double-sided tape.")
                NumberField(title: "Wall", value: $wall, tip: "Material around the cavity. 4 mm stays stiff when the clamp's soft jaw presses on the nest.")
            }
            .formStyle(.grouped)
            .frame(height: 170)
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05))
                if let nest {
                    ItemViewer3D(build: { d in AppModel.nestMesh(nest.stl, device: d).map { [$0] } ?? [] }, key: "\(nest.stl.count)-\(nest.triangles)")
                } else if working {
                    ProgressView("Shaping the cavity…")
                } else {
                    Text("Make it to see it.").foregroundStyle(.secondary)
                }
            }
            .frame(height: 220)
            if let nest {
                VStack(alignment: .leading, spacing: 4) {
                    let r = { (v: Double) in Length.mm((v * 10).rounded() / 10) }
                    Text("\(r(nest.size.x)) × \(r(nest.size.y)) × \(r(nest.size.z)) mm block · \(r(nest.proud)) mm of the part stands above the rim")
                    Text(fitNote(nest)).foregroundStyle(.secondary)
                    Text("Print in Rigid 10K or Tough 2000 resin at 50 µm, cavity up (no supports in it). Try the part in it before clamping; on a slippery fit put a strip of double-sided tape in the cavity.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(nest == nil ? "Make Nest" : "Make Again") { Task { await make() } }
                    .disabled(working || model.part == nil)
                Button("Save STL…") { save(open: false) }.disabled(nest == nil)
                if Self.preform != nil {
                    Button("Open in PreForm") { save(open: true) }.disabled(nest == nil).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .task { await make() }
        .onChange(of: face) { nest = nil }
    }

    private func fitNote(_ n: EngineClient.Nest) -> String {
        let jaw = UniversalClamp.onJaw
        if n.size.x > jaw.upperBound {
            return "Too tall (\(Length.mm(n.size.x)) mm) for the universal clamp's jaw (up to \(Length.mm(jaw.upperBound)) mm): hold it flat on the bed with the C-clamps instead."
        }
        return "It sits on the universal clamp's lower jaw like a \(Length.mm((n.size.x * 10).rounded() / 10)) mm bar (the jaw holds \(Length.mm((jaw.lowerBound * 10).rounded() / 10))–\(Length.mm((jaw.upperBound * 10).rounded() / 10)) mm)."
    }

    private func make() async {
        working = true
        message = nil
        defer { working = false }
        do {
            nest = try await model.makeNest(face: face, clearance: max(clearance, 0), wall: max(wall, 1.5))
            if nest == nil { message = "Choose the part and its stock first." }
        } catch {
            message = "Couldn't make the nest: \(error)"
        }
    }

    private func save(open: Bool) {
        guard let nest else { return }
        let name = ((model.part?.fileName as NSString?)?.deletingPathExtension ?? "Part") + " nest (\(face == .front ? "front down" : "back down")).stl"
        let url: URL
        if open {
            url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "stl") ?? .data]
            panel.nameFieldStringValue = name
            guard panel.runModal() == .OK, let u = panel.url else { return }
            url = u
        }
        do {
            try nest.stl.write(to: url, options: .atomic)
            if open, let app = Self.preform {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                message = "Opened in PreForm."
            } else {
                message = "Saved \(url.lastPathComponent)."
            }
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
