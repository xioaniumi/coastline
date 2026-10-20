import Foundation

/// Stock sizes you can simply buy: the common extruded flat and square bar sections (EN 755 /
/// ASTM B221 aluminium, CW614N / C360 brass, POM plate), cut to a length that suits the CR-1.
/// Like ToolCatalog they sit in the inventory with quantity 0, marked "Not owned"; a part that
/// fits one says so, and "I Have It Now" turns it into owned stock.
public enum StockCatalog {
    public static let source = "Coastline suggestion · standard size"
    /// Bumped when sizes are added: inventories that saw an older catalog get the new ones.
    public static let version = 1
    /// Bars are suggested cut to this length (most suppliers saw to length; the CR-1's Y
    /// travel is 241 mm, and the clamp kit wants a bar no longer than the job needs).
    public static let cutLength = 150.0

    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "C0A57200-0000-4000-8000-%012d", n))! }

    /// A bar `w` × `t` mm in section (width stands up in the clamp kit), `cutLength` long.
    private static func bar(_ n: Int, _ material: String, w: Double, t: Double, length: Double = cutLength, note: String) -> StockItem {
        var s = StockItem(id: id(n), materialID: material, shape: .block, sizeX: length, sizeY: w, sizeZ: t, quantity: 0, finish: .sawn,
                          supplier: source, notes: "Not in your inventory: a standard size. \(note)")
        s.extrusionAxis = 0  // extruded along its length: only the sawn ends need facing
        return s
    }

    private static func round(_ n: Int, _ material: String, d: Double, length: Double = 100, note: String) -> StockItem {
        StockItem(id: id(n), materialID: material, shape: .roundBar, sizeX: d, sizeY: length, sizeZ: 0, quantity: 0, finish: .sawn,
                  supplier: source, notes: "Not in your inventory: a standard size. \(note)")
    }

    public static let suggestions: [StockItem] = [
        // Aluminium flat bar (6061 / 6082, metric sections).
        bar(1, "al-6061", w: 25, t: 6, note: "Thin flat bar for pendants, tags and watch bridges (on the jaw)."),
        bar(2, "al-6061", w: 25, t: 10, note: "Small parts up to ~12 mm across, on the jaw."),
        bar(3, "al-6061", w: 30, t: 10, note: "Rings, small pendants and watch plates up to ~20 mm across."),
        bar(4, "al-6061", w: 30, t: 15, note: "Thicker small parts; two-sided jobs up to ~12 mm thick."),
        bar(5, "al-6061", w: 40, t: 10, note: "Watch plates and pendants up to ~30 mm across: the tallest flat bar the soft jaws hold."),
        bar(6, "al-6061", w: 40, t: 20, note: "Chunky parts up to ~30 × 17 mm."),
        bar(7, "al-6061", w: 30, t: 30, note: "Square bar: rings and three-dimensional parts."),
        bar(8, "al-6061", w: 40, t: 40, note: "Square bar: the largest section the clamp kit holds (40 mm tall on the jaw)."),
        // Imperial sections (ASTM B221, 6061-T6511).
        bar(9, "al-6061", w: 25.4, t: 6.35, note: "1\" × 1/4\" flat bar, the common US section."),
        bar(10, "al-6061", w: 38.1, t: 12.7, note: "1-1/2\" × 1/2\" flat bar."),
        // Brass (CW614N / C360 free-cutting).
        bar(11, "brass-c360", w: 30, t: 10, length: 100, note: "Free-cutting brass flat bar: watch plates and bridges are traditionally brass."),
        bar(12, "brass-c360", w: 40, t: 5, length: 100, note: "Brass flat bar for movement plates up to ~30 mm."),
        round(13, "brass-c360", d: 30, note: "Brass round bar: sawn into discs for round watch plates and pendants."),
        // Plastics and wax for test cuts.
        bar(14, "pom", w: 40, t: 20, length: 100, note: "POM (Delrin) bar: cheap, kind to small tools, ideal for a first cut of a new part."),
        bar(15, "wax-machinable", w: 38, t: 25, length: 100, note: "Machinable wax block: try a toolpath at full speed without risking a tool."),
    ]
}

extension StockItem {
    /// A standard size Coastline suggests, not owned.
    public var isSuggestion: Bool { supplier == StockCatalog.source && quantity == 0 }
}
