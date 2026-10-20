import Foundation
import ZIPFoundation

/// Imports Autodesk Fusion tool libraries (`.tools`, a zip containing `tools.json`; or a bare
/// `.json`). Coast Runner ships its aluminium and steel/titanium libraries in this format.
public enum FusionToolImport {
    public struct Result: Sendable {
        public var tools: [Tool]
        /// Entries that were skipped, with the reason (e.g. holders, probes, unknown types).
        public var skipped: [String]
    }

    public enum ImportError: Error, CustomStringConvertible {
        case unreadable(String)
        public var description: String {
            switch self { case .unreadable(let why): "Couldn't read the tool library: \(why)" }
        }
    }

    public static func load(_ url: URL) throws -> Result {
        let json: Data
        if url.pathExtension.lowercased() == "json" {
            json = try Data(contentsOf: url)
        } else {
            let archive: Archive
            do { archive = try Archive(url: url, accessMode: .read) } catch {
                throw ImportError.unreadable("not a zip archive (\(error))")
            }
            guard let entry = archive.first(where: { $0.path.lowercased().hasSuffix("tools.json") }) else {
                throw ImportError.unreadable("no tools.json inside")
            }
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            json = data
        }
        return try parse(json, sourceName: url.lastPathComponent)
    }

    public static func parse(_ json: Data, sourceName: String) throws -> Result {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else {
            throw ImportError.unreadable("unexpected JSON layout")
        }
        var tools: [Tool] = []
        var skipped: [String] = []
        for e in entries {
            let typeName = e["type"] as? String ?? "?"
            let description = (e["description"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard let kind = kind(for: typeName) else {
                skipped.append("\(typeName) \(description): not a cutting tool Coastline uses")
                continue
            }
            let g = e["geometry"] as? [String: Any] ?? [:]
            // Fusion stores lengths in the library's unit ("inches" or "millimeters").
            let scale = (e["unit"] as? String ?? "").lowercased().hasPrefix("inch") ? 25.4 : 1.0
            func len(_ key: String) -> Double? { (g[key] as? Double).map { $0 * scale } }
            guard let diameter = len("DC"), diameter > 0 else {
                skipped.append("\(typeName) \(description): no diameter")
                continue
            }
            let vendor = (e["vendor"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let product = (e["product-id"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let number = (e["post-process"] as? [String: Any])?["number"] as? Int
            let fluteLength = len("LCF") ?? diameter * 2
            let stickout = len("LB") ?? len("assemblyGaugeLength") ?? fluteLength + 5

            var tool = Tool(
                name: displayName(vendor: vendor, product: product, description: description, kind: kind, diameter: diameter),
                kind: kind,
                vendor: vendor,
                partNumber: product,
                productLink: e["product-link"] as? String ?? "",
                diameter: diameter,
                shankDiameter: len("SFDM") ?? diameter,
                flutes: g["NOF"] as? Int ?? (g["NOF"] as? Double).map(Int.init) ?? 2,
                fluteLength: fluteLength,
                stickout: stickout,
                overallLength: len("OAL") ?? stickout + 20,
                cornerRadius: len("RE") ?? 0,
                angle: (g["TA"] as? Double) ?? (g["SIG"] as? Double),
                tipDiameter: len("tip-diameter") ?? 0,
                toolMaterial: toolMaterial(e["BMC"] as? String),
                // Fusion's body material "ti coated" means TiN-coated carbide.
                coating: (e["BMC"] as? String)?.lowercased() == "ti coated" ? .tiN : coating(in: description),
                intendedFor: description,
                source: "Fusion library \(sourceName)" + (number.map { ", T\($0)" } ?? "")
            )
            tool.presets = presets(e, scale: scale)
            tools.append(tool)
        }
        return Result(tools: tools, skipped: skipped)
    }

    static func kind(for fusionType: String) -> Tool.Kind? {
        switch fusionType.lowercased() {
        case "flat end mill": .flatEndMill
        case "ball end mill": .ballEndMill
        case "bull nose end mill", "radius mill": .bullNoseEndMill
        case "chamfer mill", "dovetail mill": .chamferMill
        case "engrave", "engrave mill", "tapered mill": .engraver
        case "drill": .drill
        case "spot drill", "center drill": .spotDrill
        case "thread mill": .threadMill
        case "face mill": .faceMill
        default: nil
        }
    }

    static func toolMaterial(_ bmc: String?) -> Tool.ToolMaterial {
        switch bmc?.lowercased() {
        case "hss": .hss
        case "cobalt": .cobalt
        default: .carbide
        }
    }

    /// Fusion has no coating field, but vendors often name it in the description.
    static func coating(in description: String) -> Tool.Coating {
        // Whole words only: "cutting" contains "tin".
        let words = Set(description.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let table: [(String, Tool.Coating)] = [("altin", .alTiN), ("tialn", .tiAlN), ("alcrn", .alCrN),
                                               ("zrn", .zrN), ("dlc", .dlc), ("tin", .tiN)]
        return table.first { words.contains($0.0) }?.1 ?? .none
    }

    static func displayName(vendor: String, product: String, description: String, kind: Tool.Kind, diameter: Double) -> String {
        let size = Length.inchFraction(diameter) ?? "\(Length.mm(diameter)) mm"
        let what = "\(size) \(kind.title.lowercased())"
        let maker = [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
        return maker.isEmpty ? what : "\(what) · \(maker)"
    }

    static func presets(_ e: [String: Any], scale: Double) -> [Tool.Preset] {
        let list = (e["start-values"] as? [String: Any])?["presets"] as? [[String: Any]] ?? []
        return list.compactMap { p in
            guard let n = p["n"] as? Double else { return nil }
            func feed(_ key: String) -> Double { ((p[key] as? Double) ?? 0) * scale }  // in/min → mm/min
            return Tool.Preset(
                name: p["name"] as? String ?? "Preset",
                rpm: n,
                feed: feed("v_f"),
                plungeFeed: feed("v_f_plunge"),
                rampFeed: feed("v_f_ramp"),
                stepdown: (p["use-stepdown"] as? Bool ?? false) ? (p["stepdown"] as? Double).map { $0 * scale } : nil,
                stepover: (p["use-stepover"] as? Bool ?? false) ? (p["stepover"] as? Double).map { $0 * scale } : nil
            )
        }
    }
}
