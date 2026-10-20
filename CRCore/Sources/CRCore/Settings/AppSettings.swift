import Foundation

/// Keyboard bindings for manual mode. Port of `JogKeys` (values are JS `KeyboardEvent.key` names).
public struct JogKeys: Codable, Equatable, Sendable {
    public var gantryLeft = "ArrowLeft"
    public var gantryRight = "ArrowRight"
    public var raiseTable = "ArrowUp"
    public var lowerTable = "ArrowDown"
    public var retract = "a"
    public var plunge = "z"
    public var focusManualEntry = "Control"
    public var focusMaxDistance = "NumLock"
    public var switchUnits = "*"
    public var switchJogMode = "/"
    public var increaseUnits = "PageUp"
    public var decreaseUnits = "PageDown"
    public var escapeTextbox = "Escape"
    public var homePreset = "F1"
    public var preset1 = "F2"
    public var preset2 = "F3"
    public var preset3 = "F4"
    public var preset4 = "F5"

    public init() {}

    /// Mapping to the original `cncmill.conf` keys.
    nonisolated(unsafe) static let confKeys: [(String, WritableKeyPath<JogKeys, String>)] = [
        ("gantry_left", \.gantryLeft), ("gantry_right", \.gantryRight),
        ("raise_table", \.raiseTable), ("lower_table", \.lowerTable),
        ("retract", \.retract), ("plunge", \.plunge),
        ("focus_manual_entry", \.focusManualEntry), ("focus_max_distance", \.focusMaxDistance),
        ("switch_units", \.switchUnits), ("switch_jog_mode", \.switchJogMode),
        ("increase_units", \.increaseUnits), ("decrease_units", \.decreaseUnits),
        ("escape_textbox", \.escapeTextbox), ("home_preset", \.homePreset),
        ("preset_1", \.preset1), ("preset_2", \.preset2), ("preset_3", \.preset3), ("preset_4", \.preset4),
    ]
}

/// User preferences. Port of `SettingManager` (which stored `~/.cncmill/cncmill.conf`); stored in
/// `UserDefaults` with the same keys and defaults, importing an existing conf file once.
public final class AppSettings: @unchecked Sendable {
    public static let shared = AppSettings()

    private let defaults: UserDefaults
    private static let importedKey = "importedCNCMillConf"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private func int(_ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    public var enableSlider: Bool {
        get { bool("enable_slider", false) }
        set { defaults.set(newValue, forKey: "enable_slider") }
    }
    public var pauseAfterGCode: Bool {
        get { bool("pauseAfterGCode", false) }
        set { defaults.set(newValue, forKey: "pauseAfterGCode") }
    }
    public var minFeedRate: Int {
        get { int("minFeedRate", 30) }
        set { defaults.set(newValue, forKey: "minFeedRate") }
    }
    public var maxFeedRate: Int {
        get { int("maxFeedRate", 100) }
        set { defaults.set(newValue, forKey: "maxFeedRate") }
    }
    /// "Disable warning when manual entry will trigger a limit alarm".
    public var disableLimitCatch: Bool {
        get { bool("disableLimitCatch", false) }
        set { defaults.set(newValue, forKey: "disableLimitCatch") }
    }
    public var showEditButtonSetting: Bool {
        get { bool("showEditButtonSetting", false) }
        set { defaults.set(newValue, forKey: "showEditButtonSetting") }
    }
    public var enableEditButton: Bool {
        get { bool("enableEditButton", false) }
        set { defaults.set(newValue, forKey: "enableEditButton") }
    }
    public var enableLS: Bool {
        get { bool("enable_ls", false) }
        set { defaults.set(newValue, forKey: "enable_ls") }
    }

    public func showWalkthrough(_ name: String) -> Bool { bool("walkthrough_\(name)", true) }
    public func setShowWalkthrough(_ name: String, _ show: Bool) { defaults.set(show, forKey: "walkthrough_\(name)") }

    /// Saved machine position for preset buttons 0 (home) and 1–4, in mm.
    public func positionPreset(_ number: Int) -> Point3? {
        guard let values = defaults.array(forKey: "position_button_\(number)") as? [Double], values.count == 3 else { return nil }
        return Point3(x: values[0], y: values[1], z: values[2])
    }

    public func setPositionPreset(_ number: Int, _ point: Point3) {
        defaults.set([point.x, point.y, point.z], forKey: "position_button_\(number)")
    }

    public var jogKeys: JogKeys {
        get {
            guard let data = defaults.data(forKey: "jogKeys"),
                  let keys = try? JSONDecoder().decode(JogKeys.self, from: data) else { return JogKeys() }
            return keys
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "jogKeys") }
    }

    /// Imports `~/.cncmill/cncmill.conf` from the old app once (key=value lines).
    public func importLegacyConfigIfNeeded(from url: URL = FileManager.default.homeDirectoryForCurrentUser
                                            .appending(path: ".cncmill/cncmill.conf")) {
        guard !defaults.bool(forKey: Self.importedKey),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        for key in ["enable_slider", "pauseAfterGCode", "disableLimitCatch", "showEditButtonSetting", "enableEditButton", "enable_ls"] {
            if let v = values[key] { defaults.set(v == "true", forKey: key) }
        }
        for key in ["minFeedRate", "maxFeedRate"] {
            if let v = values[key].flatMap(Int.init) { defaults.set(v, forKey: key) }
        }
        var keys = jogKeys
        for (confKey, path) in JogKeys.confKeys {
            if let v = values[confKey] { keys[keyPath: path] = v }
        }
        jogKeys = keys
        // Position presets were stored as JSON {"x":{"mm":…,"inch":…},…}.
        for n in 0...4 {
            guard let json = values["position_button_\(n)"], let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]],
                  let x = object["x"]?["mm"], let y = object["y"]?["mm"], let z = object["z"]?["mm"] else { continue }
            setPositionPreset(n, Point3(x: x, y: y, z: z))
        }
        defaults.set(true, forKey: Self.importedKey)
    }
}
