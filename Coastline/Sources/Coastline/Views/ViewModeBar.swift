import SwiftUI

/// How much of the machine to show, as one attached icon selector (like Finder's view
/// switcher), with the display options in a menu beside it.
struct ViewModeBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 8) {
            machineGroup
            StockDisplayBar()
        }
    }

    private var machineGroup: some View {
        @Bindable var model = model
        return HStack(spacing: 2) {
            ForEach(MachineDisplay.allCases) { mode in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { model.machineDisplay = mode }
                } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 34, height: 26)
                        .contentShape(Rectangle())
                        .background {
                            if model.machineDisplay == mode {
                                Capsule().fill(Theme.accent).matchedGeometryEffect(id: "sel", in: selection)
                            }
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.machineDisplay == mode ? Color.white : Color.secondary)
                .help(mode.title)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(model.machineDisplay == mode ? .isSelected : [])
            }
            Divider().frame(height: 20).padding(.horizontal, 4)
            Button {
                model.jogOpen.toggle()
                if model.jogOpen { model.jog(to: model.machinePosition) }
            } label: {
                Image(systemName: "dpad").font(.system(size: 14))
                    .frame(width: 30, height: 26)
                    .background { if model.jogOpen { Capsule().fill(.primary.opacity(0.13)) } }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Jog the machine: move X, Y and Z by hand, with or without a bit")
            .accessibilityLabel("Jog")
            .accessibilityAddTraits(model.jogOpen ? .isSelected : [])
            Menu {
                Toggle("Realistic Rendering", isOn: $model.realistic)
                Toggle("Show Only the Work", isOn: $model.isolateWork)
                Toggle("Work Area", isOn: $model.showWorkArea)
                Toggle("Perspective", isOn: $model.perspective)
                Toggle("Step Card", isOn: $model.showStepCard)
                Toggle("Next Cut Face Highlight", isOn: $model.showCutFace)
                Toggle("Back Faces in Red", isOn: $model.showUndercutOverlay)
                Divider()
                Button("Sweep the Travel", systemImage: "move.3d") { model.sweepTravel() }
                    .disabled(!model.machineLoaded)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 14))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .frame(height: 26)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Display options")
            .accessibilityLabel("Display Options")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// How the stock is drawn, one click each (no menu): solid, see-through, edges, hidden.
struct StockDisplayBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "shippingbox").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4).padding(.trailing, 2)
                .help("The stock")
                .accessibilityHidden(true)  // the buttons say "Stock …" themselves
            ForEach(StockDisplay.allCases) { mode in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { model.stockDisplay = mode }
                } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 14, weight: .regular))
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                        .background {
                            if model.stockDisplay == mode {
                                Capsule().fill(Theme.accent).matchedGeometryEffect(id: "stocksel", in: selection)
                            }
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.stockDisplay == mode ? Color.white : Color.secondary)
                .help("Stock: \(mode.title)")
                .accessibilityLabel("Stock \(mode.title)")
                .accessibilityAddTraits(model.stockDisplay == mode ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

extension StockDisplay {
    var symbol: String {
        switch self {
        case .realistic: "square.fill"
        case .seeThrough: "square.lefthalf.filled"
        case .wireframe: "square.dashed"
        case .hidden: "eye.slash"
        }
    }
}

extension MachineDisplay {
    var symbol: String {
        switch self {
        case .full: "cube.fill"
        case .open: "cube"
        case .ghost: "cube.transparent"
        case .moving: "arrow.up.and.down.and.arrow.left.and.right"
        case .hidden: "eye.slash"
        }
    }
}
