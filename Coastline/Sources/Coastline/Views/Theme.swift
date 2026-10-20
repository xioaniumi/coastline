import AppKit
import CoastlineCore
import SwiftUI

/// Cutting materials. Declared here so it wins over `SwiftUI.Material` (glass/blur) in this module.
typealias Material = CoastlineCore.Material
/// Machining operations; wins over `Foundation.Operation`.
typealias Operation = CoastlineCore.Operation

/// Coastline's look. The app targets macOS 26+, so it uses Liquid Glass directly: system
/// controls (sidebar, toolbar, inspector, search) get glass automatically; custom floating
/// surfaces use `glassEffect` grouped in `GlassEffectContainer`s.
enum Theme {
    /// The accent chosen in Settings (sea teal #2BB3B8 by default, close to CRWrite's teal so
    /// the two apps feel related). Read inside a view's body, so a change redraws it.
    @MainActor static var accent: Color { AppSettings.shared.accent.color }
    /// Behind everything (the window, under the glass sidebar and the panels): near-black in
    /// dark mode so the part and the toolpaths stand out; the system's own in light mode.
    static let windowBackground = Color(nsColor: NSColor(name: "coastline.window") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.050, green: 0.054, blue: 0.064, alpha: 1) : .windowBackgroundColor
    })
    /// Behind the forms in the panels (their sections sit on it as cards).
    static let panelBackground = Color(nsColor: NSColor(name: "coastline.panel") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.066, green: 0.071, blue: 0.083, alpha: 1) : .windowBackgroundColor
    })
    static let danger = Color.red
    static let warning = Color.orange
    /// Material a prep step mills off (on the bar in 3D, its numbers, the step list).
    static let prepCut = Color(red: 1.0, green: 0.55, blue: 0.1)
    static let ok = Color.green

    static func color(_ severity: Issue.Severity) -> Color {
        switch severity {
        case .info: .secondary
        case .warning: warning
        case .error: danger
        }
    }

    static func symbol(_ severity: Issue.Severity) -> String {
        switch severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    static func color(_ difficulty: Material.Difficulty) -> Color {
        switch difficulty {
        case .easy: .green
        case .moderate: .teal
        case .careful: .orange
        case .experimental: .red
        }
    }
}

extension Material.Family {
    /// A colour that reads as the material in previews and badges.
    var swatch: Color {
        switch self {
        case .aluminium: Color(red: 0.78, green: 0.80, blue: 0.83)
        case .copperAlloy: Color(red: 0.85, green: 0.66, blue: 0.32)
        case .steel: Color(red: 0.52, green: 0.54, blue: 0.57)
        case .stainless: Color(red: 0.70, green: 0.72, blue: 0.75)
        case .titanium: Color(red: 0.55, green: 0.58, blue: 0.68)
        case .plastic: Color(red: 0.93, green: 0.93, blue: 0.90)
        case .printedResin: Color(red: 0.45, green: 0.47, blue: 0.50)
        case .wax: Color(red: 0.30, green: 0.62, blue: 0.48)
        }
    }
}

extension Material {
    /// Copper and some resins differ from their family colour.
    var swatch: Color {
        switch id {
        case "copper-c110": Color(red: 0.80, green: 0.45, blue: 0.30)
        case "bronze-c932", "bronze-c510": Color(red: 0.72, green: 0.52, blue: 0.30)
        case "nickel-silver-c752": Color(red: 0.80, green: 0.80, blue: 0.74)
        case "fl-standard": Color(red: 0.85, green: 0.88, blue: 0.92)
        case "fl-castable-wax-40": Color(red: 0.45, green: 0.62, blue: 0.85)
        case "fl-tough-2000": Color(red: 0.40, green: 0.42, blue: 0.45)
        case "wax-machinable": Color(red: 0.25, green: 0.45, blue: 0.80)
        default: family.swatch
        }
    }
}

// MARK: - Glass building blocks

/// A rounded glass card for inspector previews and guidance.
struct GlassCard<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(tint?.opacity(0.18)), in: .rect(cornerRadius: 18))
    }
}

/// A capsule badge, e.g. a material's difficulty.
struct Badge: View {
    let text: String
    var color: Color = .secondary
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Glass filter chips over a list: one glass container so the chips blend and morph.
struct FilterChips<Value: Hashable & Sendable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(options, id: \.0) { value, title in
                    Button(title) {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { selection = value }
                    }
                    .buttonStyle(.plain)
                    .font(.callout.weight(selection == value ? .semibold : .regular))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(selection == value ? .regular.tint(Theme.accent.opacity(0.35)).interactive() : .regular.interactive(),
                                 in: .capsule)
                    .glassEffectID(value, in: glass)
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
                }
            }
        }
    }
}

// MARK: - Panel hairlines

/// A one-pixel vertical separator in the system separator colour (adapts to light/dark and
/// Increase Contrast).
struct Hairline: View {
    @Environment(\.displayScale) private var scale
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1 / scale)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

extension View {
    /// Draws a hairline along one vertical edge of a panel (sidebar trailing, inspector leading).
    func panelEdge(_ edge: HorizontalEdge) -> some View {
        overlay(alignment: edge == .leading ? .leading : .trailing) { Hairline() }
    }
}

// MARK: - Glass buttons

/// A glass toggle button: plain glass when off, accent-tinted glass when on, so the state
/// reads at a glance. (The app-wide accent tint would otherwise tint every glass button.)
struct GlassToggle: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: { Label(title, systemImage: systemImage) }
            .buttonStyle(.glass)
            .tint(isOn ? Theme.accent : .clear)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

extension View {
    /// Untinted glass for secondary buttons.
    func plainGlassButton() -> some View {
        buttonStyle(.glass).tint(.clear)
    }
}


extension View {
    /// A form or list on the panel background instead of the system's grey.
    func darkPanel() -> some View {
        scrollContentBackground(.hidden).background(Theme.panelBackground)
    }
}
