import Foundation

/// What to do once the part is free: deburring, sanding and polishing, by material.
public enum FinishingGuide {
    /// After the part is free: deburring, sanding and polishing by material.
    public static func steps(for m: Material?) -> [String] {
        switch m?.family {
        case .aluminium:
            return ["File the tab stubs flush, deburr the edges with a deburring blade.",
                    "Sand wet 400 → 800 → 1500, then polish with metal polish on a felt wheel. Bead blast instead for a satin look; anodise if you want colour."]
        case .copperAlloy:
            return ["File the tab stubs, then sand 400 → 1200.",
                    "Tripoli then rouge on a buffing wheel, or tumble in steel shot for a bright finish. Lacquer or wax it against tarnish."]
        case .steel, .stainless:
            return ["Deburr, sand 240 → 600, polish with compound.", "Oil plain steel against rust."]
        case .titanium:
            return ["Deburr gently (titanium burrs are sharp), sand 400 → 1000.", "Anodise for colour if you like."]
        case .plastic:
            return ["Scrape the edges with a sharp blade instead of sanding the burr.", "Sand wet 600 → 1500; only acrylic can be flame-polished."]
        case .wax:
            return ["Smooth with a warmed tool or a nylon stocking; don't sand (wax clogs).", "Sprue it from the thickest section for casting."]
        case .printedResin:
            return ["Sand wet 400 → 1000; prime and paint, or clear-coat."]
        case nil:
            return []
        }
    }
}
