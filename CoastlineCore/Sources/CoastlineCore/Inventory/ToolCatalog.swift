import Foundation

/// Tools Coastline can recommend that aren't in the inventory (yet): common small carbide end
/// mills for jewellery work. They sit in the inventory with quantity 0, marked as suggestions;
/// plans that need one say so, and "I have it" turns it into an owned tool.
public enum ToolCatalog {
    public static let source = "Coastline suggestion"
    /// Bumped when tools are added: inventories that saw an older catalog get the new ones.
    public static let version = 5

    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "C0A57100-0000-4000-8000-%012d", n))! }

    private static func tool(_ n: Int, _ name: String, _ kind: Tool.Kind, d: Double, flutes: Int, loc: Double, stickout: Double,
                             shank: Double = 3.175, corner: Double = 0, angle: Double? = nil, tip: Double = 0, length: Double = 38.1,
                             cost: Double, vendor: String = "e.g. Harvey Tool, Kyocera, Datron", part: String = "", link: String = "",
                             why: String) -> Tool {
        Tool(id: id(n), name: name, kind: kind, vendor: vendor, partNumber: part, productLink: link, diameter: d, shankDiameter: shank,
             flutes: flutes, fluteLength: loc, stickout: stickout, overallLength: length, cornerRadius: corner, angle: angle, tipDiameter: tip,
             coating: .none, intendedFor: "Aluminium, brass, wax", quantity: 0, condition: .new, unitCost: cost,
             notes: "Not in your inventory: Coastline suggests it. \(why)", source: source)
    }

    /// The suggestions. Stable IDs, so operations that use one keep pointing at it.
    public static let suggestions: [Tool] = [
        // Small tools as real catalogue items (catalog 4, checked on harveytool.com), 1/8" shank.
        harvey(1, "1/32\" flat end mill", .flatEndMill, inch: 0.031, locInch: 0.093, part: "72031", cost: 32,
               why: "Inside corners down to R 0.4 mm, fine slots, small text."),
        harvey(2, "1/32\" ball end mill", .ballEndMill, inch: 0.031, locInch: 0.046, part: "24531", cost: 40,
               why: "Fine detail and creases on freeform jewellery, tight fillets."),
        harvey(3, "1/16\" ball end mill", .ballEndMill, inch: 0.062, locInch: 0.093, part: "24562", cost: 37,
               why: "Detail finishing between a 1/8\" ball and a 1/32\"."),
        // Long reach (necked): `loc` is the reach, the length that clears the part.
        harvey(4, "1/16\" flat end mill, 9/16\" reach", .flatEndMill, inch: 0.062, locInch: 0.562, part: "758162", cost: 62,
               flutes: 4, lengthInch: 2, stickout: 20,
               why: "Necked: reaches 14 mm down narrow pockets (lattices from both sides) without the shank rubbing. Light cuts only."),
        tool(5, "1/8\" ball end mill, long reach", .ballEndMill, d: 3.175, flutes: 2, loc: 19, stickout: 25, cost: 30,
             why: "Necked: finishes deep walls (19 mm) without the shank rubbing."),
        tool(6, "1/8\" flat end mill, long reach", .flatEndMill, d: 3.175, flutes: 3, loc: 19, stickout: 25, cost: 26,
             why: "Necked: deep contours and pockets up to 19 mm."),
        // (7–9, generic 1 mm and 0.5 mm mills, are gone since catalog 4: the real 1/32" and
        // 0.020" Harvey tools on 1/8" shanks cover them; Harvey's metric ones need a 3 mm collet.)
        tool(10, "60° V engraver, 0.1 mm tip", .engraver, d: 3.175, flutes: 2, loc: 3, stickout: 12, angle: 60, tip: 0.1, cost: 20,
             why: "Crisp engraved text and lines of any width by depth."),
        tool(11, "90° chamfer mill, 1/8\"", .chamferMill, d: 3.175, flutes: 2, loc: 3, stickout: 12, angle: 90, cost: 18,
             why: "Breaks sharp edges: chamfers and deburring."),
        tool(12, "3/16\" flat end mill", .flatEndMill, d: 4.7625, flutes: 3, loc: 14, stickout: 22, shank: 6.35, cost: 22,
             why: "Roughs pockets the 1/4\" can't enter, faster than a 1/8\"."),
        // Extended (long flute) versions: deep walls are cut by the flutes, never rubbed by a
        // shank the cutter's size (friction, heat, a poor wall and a broken tool on a light mill).
        tool(13, "1/4\" flat end mill, 1\" flutes", .flatEndMill, d: 6.35, flutes: 3, loc: 25.4, stickout: 32, shank: 6.35, length: 63.5, cost: 32,
             why: "Roughs and finishes walls up to 25 mm deep with the flutes, not the shank."),
        tool(14, "1/4\" bull nose end mill, 1\" flutes", .bullNoseEndMill, d: 6.35, flutes: 3, loc: 25.4, stickout: 32, shank: 6.35,
             corner: 0.762, length: 63.5, cost: 38,
             why: "3D finishing of deep parts (up to 25 mm) without the shank rubbing the walls."),
        tool(15, "3/16\" flat end mill, 3/4\" flutes", .flatEndMill, d: 4.7625, flutes: 3, loc: 19, stickout: 26, shank: 6.35, length: 50.8, cost: 28,
             why: "Pockets and walls up to 19 mm deep."),
        harvey(16, "1/32\" ball end mill, 1/4\" reach", .ballEndMill, inch: 0.031, locInch: 0.25, part: "734931", cost: 86,
               flutes: 4, lengthInch: 2.5, stickout: 16,
               why: "Necked: fine detail down to 6 mm deep without the shank touching the part."),
        tool(17, "1/8\" bull nose end mill, long reach", .bullNoseEndMill, d: 3.175, flutes: 3, loc: 19, stickout: 25,
             corner: 0.25, cost: 32, why: "Necked: flat-ish areas and walls of deep pockets."),

        // Micro tools for watch plates, bridges and fine jewellery detail (catalog 3). Real
        // catalogue items, checked on harveytool.com: 1/8" shank (the stock ER-11 1/8" collet),
        // 1-1/2" long, uncoated carbide, 2 flutes, "stub & standard" reach (the flutes only).
        harvey(18, "0.010\" (0.25 mm) flat end mill", .flatEndMill, inch: 0.010, locInch: 0.030, part: "72010", cost: 43,
               why: "Inside corners down to R 0.13 mm: jewel and pivot seats, fine slots in watch plates. Very light cuts only (0.1 mm deep)."),
        harvey(19, "1/64\" (0.38 mm) flat end mill", .flatEndMill, inch: 0.015, locInch: 0.045, part: "72015", cost: 36,
               why: "Corners down to R 0.2 mm: wheel recesses and steps in a movement plate."),
        harvey(20, "0.020\" (0.5 mm) flat end mill", .flatEndMill, inch: 0.020, locInch: 0.060, part: "72020", cost: 35,
               why: "The workhorse for watch plates: pockets and contours with R 0.25 mm corners, 1.5 mm deep."),
        harvey(21, "0.030\" (0.76 mm) flat end mill", .flatEndMill, inch: 0.030, locInch: 0.090, part: "72030", cost: 32,
               why: "Rest roughing between a 1/16\" and the 0.5 mm: clears most of a plate's small pockets faster."),
        harvey(22, "1/64\" (0.38 mm) ball end mill", .ballEndMill, inch: 0.015, locInch: 0.022, part: "24515", cost: 35,
               why: "Finest 3D detail: engraving-like relief, tiny fillets."),
        harvey(23, "0.020\" (0.5 mm) ball end mill", .ballEndMill, inch: 0.020, locInch: 0.030, part: "24520", cost: 49,
               why: "Fillets and countersink edges in watch parts; fine 3D detail on jewellery."),
        harvey(24, "0.030\" (0.76 mm) ball end mill", .ballEndMill, inch: 0.030, locInch: 0.045, part: "24530", cost: 40,
               why: "Rest finishing between a 1/32\" ball and a 0.5 mm one."),
        harvey(28, "1/32\" flat end mill, 5/32\" reach", .flatEndMill, inch: 0.031, locInch: 0.156, part: "944531", cost: 61,
               why: "Necked: bores and contours small holes and slots down to 4 mm deep (watch plates up to 3.5 mm) without the shank rubbing."),
        // Micro drills: Kyocera's 105 series (1/8" shank, 1-1/2" long, 118° point, solid carbide).
        drill(25, 0.5, cost: 15, why: "Holes for 0.5 mm pins; a pilot for jewel holes reamed or bored afterwards."),
        drill(26, 0.8, cost: 14, why: "Tap drill for M1.0 screws (0.75–0.8 mm) in watch plates."),
        drill(27, 1.0, cost: 14, why: "Tap drill for M1.2 screws, and 1 mm dowel and pin holes."),
        // Thread mills (catalog 5): Harvey Tool's single-form metric cutters, checked on
        // harveytool.com. 3 mm shanks (4 mm for M5): they need the ER-11 collet of that size.
        // `loc` is the deepest thread they reach (the neck clears it).
        threadMill(29, .init(name: "M2.5", major: 2.5, pitch: 0.45), d: 1.9, flutes: 2, reach: 3.5, part: "890322", cost: 96),
        threadMill(30, .init(name: "M3", major: 3, pitch: 0.5), d: 2.3, flutes: 4, reach: 9.5, part: "737624", cost: 141),
        threadMill(31, .init(name: "M4", major: 4, pitch: 0.7), d: 3.0, flutes: 4, reach: 5.5, part: "890326", cost: 141),
        threadMill(32, .init(name: "M5", major: 5, pitch: 0.8), d: 4.0, flutes: 4, reach: 7.0, shank: 4, length: 50, part: "890328", cost: 143),
    ]

    /// The IDs Coastline once suggested and no longer does (inventories drop them while unowned).
    public static let retired: Set<UUID> = [id(7), id(8), id(9)]

    private static func harvey(_ n: Int, _ name: String, _ kind: Tool.Kind, inch: Double, locInch: Double, part: String, cost: Double,
                               flutes: Int = 2, lengthInch: Double = 1.5, stickout: Double = 12, why: String) -> Tool {
        tool(n, name, kind, d: inch * 25.4, flutes: flutes, loc: locInch * 25.4, stickout: stickout, length: lengthInch * 25.4, cost: cost,
             vendor: "Harvey Tool", part: part,
             link: "https://www.harveytool.com/products/tool-details-\(part)",
             why: why + " Spins at the CR-1's 8000 RPM with a feed of a few tens of mm/min; an ultra-precision collet (runout ≤ 5 µm) makes it last.")
    }

    private static func threadMill(_ n: Int, _ spec: ThreadSpec, d: Double, flutes: Int, reach: Double, shank: Double = 3,
                                   length: Double = 38, part: String, cost: Double) -> Tool {
        var t = tool(n, "\(spec.name) thread mill", .threadMill, d: d, flutes: flutes, loc: reach, stickout: max(reach + 6, 14), shank: shank,
                     length: length, cost: cost, vendor: "Harvey Tool", part: part,
                     link: "https://www.harveytool.com/products/tool-details-\(part)",
                     why: "Mills \(spec.title) internal threads (single form, 60°) up to \(Length.mm(reach)) mm deep, in a Ø\(Length.mm(spec.tapDrill)) hole made first. Needs a \(Length.mm(shank)) mm ER-11 collet.")
        t.angle = 30
        t.threadPitch = spec.pitch
        return t
    }

    private static func drill(_ n: Int, _ d: Double, cost: Double, why: String) -> Tool {
        tool(n, "\(d.formatted(.number.precision(.fractionLength(1)))) mm micro drill", .drill, d: d, flutes: 2, loc: 5, stickout: 12, angle: 118, cost: cost,
             vendor: "Kyocera SGS (105 series)", why: why + " Peck in steps of a quarter diameter; it breaks if the chips pack.")
    }
}

extension Tool {
    /// A suggestion Coastline recommends, not owned.
    public var isSuggestion: Bool { source == ToolCatalog.source && quantity == 0 }
}
