import AppKit
import Foundation
import SwiftUI

/// Coastline ▸ Settings: the app's own preferences (not the project's), kept in UserDefaults.
/// Observable, so `Theme.accent` and everything else that reads these redraw when they change.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    enum Accent: String, CaseIterable, Identifiable {
        case sea, amber, orange, red, magenta, purple, indigo, blue, green, graphite
        var id: String { rawValue }
        var title: String {
            switch self {
            case .sea: "Sea Teal"
            case .amber: "Amber"
            case .orange: "Orange"
            case .red: "Red"
            case .magenta: "Magenta"
            case .purple: "Purple"
            case .indigo: "Indigo"
            case .blue: "Blue"
            case .green: "Green"
            case .graphite: "Graphite"
            }
        }
        var color: Color {
            switch self {
            case .sea: Color(red: 0x2B / 255, green: 0xB3 / 255, blue: 0xB8 / 255)
            case .amber: Color(red: 0.98, green: 0.72, blue: 0.10)
            case .orange: Color(red: 1.00, green: 0.50, blue: 0.12)
            case .red: Color(red: 0.93, green: 0.22, blue: 0.24)
            case .magenta: Color(red: 0.90, green: 0.25, blue: 0.62)
            case .purple: Color(red: 0.62, green: 0.36, blue: 0.95)
            case .indigo: Color(red: 0.36, green: 0.40, blue: 0.95)
            case .blue: Color(red: 0.12, green: 0.52, blue: 1.00)
            case .green: Color(red: 0.20, green: 0.74, blue: 0.40)
            case .graphite: Color(red: 0.55, green: 0.57, blue: 0.60)
            }
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    /// How the guided job finds edges and the top on clamp-kit setups. The clamp kit is
    /// electrically isolated from the machine, so a wire on the stock and the tool closing the
    /// circuit (G38.2) can do it; acetal stops on the bed can't, there it's the edge finder and paper.
    enum ClampKitProbing: String, CaseIterable, Identifiable {
        case electrical, edgeFinder
        var id: String { rawValue }
        var title: String { self == .electrical ? "Electrical probing (G38.2)" : "Edge finder and paper" }
    }

    private let defaults = UserDefaults.standard

    var accent: Accent { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance"); apply() } }
    /// 0 = automatic (by the number of cores).
    var engines: Int { didSet { defaults.set(engines, forKey: "engines") } }
    var clampKitProbing: ClampKitProbing { didSet { defaults.set(clampKitProbing.rawValue, forKey: "clampKitProbing") } }
    /// Two-sided jobs mill reference bores on side A and find side B's zero from them.
    var referenceBores: Bool { didSet { defaults.set(referenceBores, forKey: "referenceBores") } }

    private init() {
        accent = Accent(rawValue: defaults.string(forKey: "accent") ?? "") ?? .sea
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        engines = defaults.integer(forKey: "engines")
        clampKitProbing = ClampKitProbing(rawValue: defaults.string(forKey: "clampKitProbing") ?? "") ?? .electrical
        referenceBores = defaults.object(forKey: "referenceBores") as? Bool ?? true
    }

    func apply() { NSApp?.appearance = appearance.nsAppearance }
}
