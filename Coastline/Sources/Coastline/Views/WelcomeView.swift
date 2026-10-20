import SwiftUI

/// What Coastline does and how to drive it: shown once, and from Help ▸ How Coastline Works.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss

    private let stages: [(String, String, String)] = [
        ("cube.transparent", "1 · Part & stock", "Import the part (STEP, IGES, Rhino) and pick the bar you have. Move it in the stock with the gumball (arrows move, rings turn it in quarter turns); several copies fit side by side."),
        ("hand.raised", "2 · Holding", "How the bar is held: straight in the clamp kit, prepped on the bed first, shoulders at its ends, or the whole job flat on the bed. Coastline recommends one and says why."),
        ("square.3.layers.3d.down.right", "3 · Stock prep", "Each clamping on the bed. Press on the stop or a C-clamp and drag it; a picked C-clamp turns with its red ring. Anything that collides turns red."),
        ("square.and.arrow.down.on.square", "4 · Clamp kit", "Slide the universal clamps along the T-slots, drag the stock to stand it out. The orange strips are what the jaws hold: never cut."),
        ("point.topleft.down.to.point.bottomright.curvepath", "5 · Machining", "Operations, the quality ↔ time tuner, generation, the simulation. Add text to engrave."),
        ("checklist", "6 · Review", "Walk through the job (Tour), export the guided job for CRWrite, and afterwards record it in the journal: tool wear, stock and feeds learn from it."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "water.waves").font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading) {
                    Text("Welcome to Coastline").font(.title.weight(.semibold))
                    Text("From a CAD part to a guided job on your Coast Runner CR-1, one stage at a time.").foregroundStyle(.secondary)
                }
            }
            ForEach(stages, id: \.1) { s in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: s.0).font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.1).font(.headline)
                        Text(s.2).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text("Orbit").bold(); Text("drag in empty space") }
                GridRow { Text("Pan").bold(); Text("two fingers, or ⌥-drag") }
                GridRow { Text("Zoom").bold(); Text("pinch, or the scroll wheel") }
                GridRow { Text("Frame all").bold(); Text("double-click") }
                GridRow { Text("Pages").bold(); Text("⌘1 … ⌘9") }
                GridRow { Text("Playback").bold(); Text("Space plays; ← → a move, ⌥← ⌥→ an operation, ⌘[ ⌘] a step") }
            }
            .font(.callout)
            Label("Every new program runs as an air cut first (spindle off, 10 mm up). Never use compressed air on the CR-1: vacuum and wipe.",
                  systemImage: "shield.lefthalf.filled")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Get Started") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 600)
    }
}
