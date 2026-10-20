import SwiftUI

/// What to do on opening Coastline: carry on with the last part, open a project, import a part,
/// or try one of the example parts (each held a different way on the CR-1).
struct StartView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    private let last = AppModel.lastSessionPart

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "water.waves").font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coastline").font(.title.weight(.semibold))
                    Text("From a CAD part to a guided job on your CR-1.").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                if let last {
                    Button("Continue with \(last.lastPathComponent)", systemImage: "arrow.forward.circle") {
                        dismiss()
                        Task { await model.restoreSession() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                Button("Open Project…", systemImage: "folder") {
                    dismiss()
                    model.openProjectInteractively()
                }
                Button("Import Part…", systemImage: "square.and.arrow.down") { importing = true }
            }
            .controlSize(.large)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Try an example").font(.title3.weight(.semibold))
                Text("Real parts with engineering details, each showing another way to hold the stock. A bar you don't have is added to the inventory as Not owned.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ExampleGrid(large: true) { dismiss() }
            HStack {
                Spacer()
                Button(last == nil ? "Start Empty" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: 760)
        .fileImporter(isPresented: $importing, allowedContentTypes: CADFile.types) { result in
            if case let .success(url) = result {
                dismiss()
                Task {
                    let access = url.startAccessingSecurityScopedResource()
                    await model.importPart(url)
                    if access { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
    }
}
