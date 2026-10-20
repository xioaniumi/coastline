import CoastlineCore
import SwiftUI

/// The tool change playback stopped at: the CR-1 at the tool-change position, what comes out,
/// what goes in and how (the operator manual's steps), and "Tool Changed" to carry on.
struct ToolChangeCard: View {
    @Environment(AppModel.self) private var model
    let stop: ToolChangeStop

    var body: some View {
        let to = stop.to
        let swapCollet = stop.from.map { abs($0.shankDiameter - to.shankDiameter) > 0.01 } ?? true
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Tool change").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if stop.phase != .waiting {
                    ProgressView().controlSize(.small)
                    Text(stop.phase == .moving ? "Moving to the tool-change position" : "Back to the cut")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Label("Fit the \(to.name)", systemImage: "wrench.and.screwdriver").font(.headline)
            if let note = stop.note {
                Label(note, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                line("The CR-1 has lowered the table (the stock as far from the spindle as it goes) and brought the spindle forward, out of the machine towards you: the collet nut is free and in reach, the stock stays clamped (its zero stays valid).")
                if let from = stop.from {
                    line("**Take out the \(from.name)**: 12 mm wrench on the spindle's flats, 17 mm on the collet nut; hold the 12, loosen with the 17.")
                }
                if swapCollet {
                    line("**Collet:** the \(Length.describe(to.shankDiameter)) one, snapped into the nut until it clicks.")
                }
                line("**\(Length.mm(to.stickout)) mm sticking out** below the nut; finger-tight, then both wrenches until it won't easily go further.")
                line("Then touch off the new tool on the face (Z0).")
            }
            HStack {
                Button("Stop Here", role: .cancel) { model.cancelToolChange() }
                    .keyboardShortcut(.cancelAction)
                    .help("Leave the tool change; playback stays before it.")
                Spacer()
                Button { model.confirmToolChange() } label: {
                    Label("Tool Changed", systemImage: "checkmark")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(stop.phase != .waiting)
                .help("The new tool is in and tight: the machine goes back to the cut (Return).")
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tool change: fit the \(to.name)")
    }

    private func line(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(.secondary).frame(width: 4, height: 4).offset(y: -2).accessibilityHidden(true)
            Text(.init(text)).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
