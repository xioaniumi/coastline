import simd
import AppKit
import CoastlineCore
import SwiftUI
import Viewport

@main
struct CoastlineApp: App {
    @State private var model = AppModel()
    @State private var inventory = InventoryModel()

    init() {
        // `swift run` starts a bare executable; make it a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        AppSettings.shared.apply()
    }

    var body: some Scene {
        WindowGroup("Coastline") {
            ContentView()
                .containerBackground(Theme.windowBackground, for: .window)
                .environment(model)
                .environment(inventory)
                .tint(Theme.accent)
                .frame(minWidth: 1040, minHeight: 640)
                .task { await Automation.runIfRequested(model, inventory) }
                // A .coastline file double-clicked in Finder (the packaged app declares the type).
                .sheet(isPresented: Binding(get: { model.showWelcome }, set: { model.showWelcome = $0 })) {
                    WelcomeView().onDisappear {
                        UserDefaults.standard.set(true, forKey: "seenWelcome")
                        if model.part == nil { model.showStart = true }
                    }
                }
                .sheet(isPresented: Binding(get: { model.showStart }, set: { model.showStart = $0 })) {
                    StartView().environment(model).environment(inventory).tint(Theme.accent)
                }
                .sheet(isPresented: Binding(get: { model.showNestSheet }, set: { model.showNestSheet = $0 })) {
                    NestSheet().environment(model).environment(inventory).tint(Theme.accent)
                }
                .onOpenURL { url in
                    guard url.pathExtension == "coastline" else { return }
                    Task { await model.openProject(url); model.page = .workspace }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    inventory.saveNow()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Start…") { model.page = .workspace; model.showStart = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open…") { model.openProjectInteractively() }.keyboardShortcut("o")
                Menu("Open Example") {
                    ForEach(ExamplePart.all) { ex in
                        Button(ex.title) { model.page = .workspace; Task { await model.openExample(ex, inventory: inventory) } }
                    }
                }
                Menu("Open Recent") {
                    ForEach(AppModel.recentProjects, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { Task { await model.openProject(url) } }
                    }
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveProjectInteractively() }.keyboardShortcut("s")
                Button("Save As…") { model.saveProjectInteractively(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Print a Nest…") { model.page = .workspace; model.showNestSheet = true }
                    .disabled(model.part == nil || model.stock == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoName.map { "Undo \($0)" } ?? "Undo") { model.undoAnywhere() }.keyboardShortcut("z")
                Button(model.redoName.map { "Redo \($0)" } ?? "Redo") { model.redoAnywhere() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("How Coastline Works") { model.showWelcome = true }
            }
            CommandGroup(after: .sidebar) {
                // ⌘1…⌘9 for the first nine pages (a key is one character).
                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                    if index < 9 {
                        Button(item.title) { model.page = item }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    } else {
                        Button(item.title) { model.page = item }
                    }
                }
            }
            // Toolpaths (⌘G, ⌘.), Playback (Space, arrows, ⌘[ ⌘]) and View ▸ Measure (M).
            CoastlineCommands(model: model, inventory: inventory)
        }

        Settings {
            SettingsView()
                .environment(inventory)
                .tint(Theme.accent)
        }
    }
}

/// Scripted runs for checks without screen access (like CRWrite's DebugAutomation), e.g.
/// `COASTLINE_SCRIPT="page tools; wait 1; wsnap /tmp/tools.png; quit"`.
/// - `snap` renders the 3D viewport off screen (Metal).
/// - `wsnap` captures the whole window through the window server, Liquid Glass included.
/// Set `COASTLINE_INVENTORY=/tmp/x.json` so automation doesn't touch the real inventory.
@MainActor
enum Automation {
    static func runIfRequested(_ model: AppModel, _ inventory: InventoryModel) async {
        guard let script = ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] else { return }
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffered, so logs survive a killed run
        for command in script.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts.first {
            case "import": await model.importPart(URL(fileURLWithPath: arg))
            case "stress": model.loadStressToolpath(count: Int(arg) ?? 1_000_000)
            case "view": if let v = OrbitCamera.StandardView(rawValue: arg) { model.setView(v) }
            case "section": model.sectionOn = arg != "off"
            case "zoom": model.renderer.camera.zoom(by: Float(arg) ?? 1)
            case "page": if let p = SidebarItem(rawValue: arg) { model.page = p }
            case "coupon": await couponCommand(model, inventory, arg)  // "coupon pom": the first-cut coupon in POM
            case "addthread":  // "addthread M3 [depth]": a thread milling operation, as the menu adds it
                var op = Operation(kind: .thread)
                model.prepareThread(&op, inventory: inventory.inventory)
                let words = arg.split(separator: " ").map(String.init)
                if let name = words.first, let spec = ThreadSpec.named(name) {
                    op.thread = ThreadMilling(spec: name, depth: words.count > 1 ? Double(words[1]) : nil)
                    op.toolID = inventory.inventory.tools.filter { $0.kind == .threadMill && spec.canBeCut(by: $0) }
                        .min { ($0.quantity > 0 ? 0 : 1, -$0.fluteLength) < ($1.quantity > 0 ? 0 : 1, -$1.fluteLength) }?.id
                }
                model.operations.append(op)
                print("addthread \(op.thread?.spec ?? "-") tool \(op.toolID.flatMap { id in inventory.inventory.tools.first { $0.id == id }?.name } ?? "none") holes \(model.features?.holes.map(\.diameter) ?? [])")
            case "texture":  // "texture barleycorn 10": a texture of that pattern and size at the face's centre
                let words = arg.split(separator: " ").map(String.init)
                var op = Operation(kind: .engrave)
                var e = Engraving(text: "", depth: 0.08)
                var t = Texture.preset(words.first.flatMap { Texture.Pattern(rawValue: $0) } ?? .barleycorn)
                if words.count > 1, let w = Double(words[1]) { t.width = w; t.height = w * 0.6 }
                e.texture = t
                op.engraving = e
                op.toolID = OperationPlanner.usableTools(inventory.inventory)
                    .filter { [.engraver, .chamferMill, .ballEndMill, .flatEndMill].contains($0.kind) && $0.diameter <= 3.2 }
                    .min { ($0.kind == .engraver ? 0 : 1, $0.diameter) < ($1.kind == .engraver ? 0 : 1, $1.diameter) }?.id
                model.justAddedOperation = op.id
                model.operations.append(op)
                print("texture \(t.pattern) lines \(t.lines().count) tool \(inventory.inventory.tools.first { $0.id == op.toolID }?.name ?? "none") title \(op.title)")
            case "nest":  // "nest": the Print a Nest sheet
                model.showNestSheet = true
            case "toolspin":  // the tool mesh's turn now, and what's playing
                let t = model.renderer.scene.mesh("tool")?.transform
                let angle = t.map { atan2(Double($0.columns.0.y), Double($0.columns.0.x)) * 180 / .pi } ?? .nan
                let e = model.timeline.entries.isEmpty ? nil : model.timeline.entries[min(max(model.timeline.index(at: model.playhead), 0), model.timeline.entries.count - 1)]
                print("toolspin playing \(model.isPlaying) angle \(Int(angle)) spin \(model.toolSpin) playhead \(String(format: "%.1f", model.playhead)) program \(e.map { "\($0.program)" } ?? "-") tool \(model.currentTool?.name ?? "-")")
            case "projectspick": model.projectsPick = arg  // before "page projects": what it selects
            case "stock":  // "stock 0" = first stock item in the inventory
                let items = inventory.inventory.stock
                if let i = Int(arg), items.indices.contains(i) { model.useStock(items[i]) }
            case "machine": if let m = MachineDisplay(rawValue: arg) { model.machineDisplay = m }
            case "sweep": model.sweepTravel(duration: Double(arg) ?? 4)
            case "downsize": model.setup.downsizeHeight = Double(arg)
            case "realistic": model.realistic = arg != "off"
            case "stockview": if let d = StockDisplay(rawValue: arg) { model.stockDisplay = d }
            case "isolate": model.isolateWork = arg != "off"
            case "plans":
                await model.findPlans(inventory: inventory.inventory)
                print("sides twoSided=\(model.twoSided) chosen=\(model.twoSidedChosen) splitZ=\(model.splitZ.map { String($0) } ?? "-") topAllowance=\(model.setup.topAllowance)")
                for c in model.planOptions {
                    print("plan \(c.name) minutes=\(Int(c.minutes)) finish=\(Int(c.finish)) risk=\(c.risk) ops=\(c.operations.map { $0.kind.rawValue + ($0.pocketsOnly == true ? "(pockets)" : "") }) needs=\(c.needsTools.map(\.name)) remedies=\(c.remedies.map(\.title))")
                    for r in c.reasons where r.hasPrefix("Risk") || r.contains("pockets") { print("   \(r)") }
                }
            case "useplan":
                // "mid": Find the Best Plan's middle tier. Plans with a tool to buy first when
                // there are any (they're better, or they wouldn't be offered); among those the
                // Balanced one, else the middle one by time (of two, the finer).
                var name = arg == "recommended" ? (model.recommendedPlan ?? "") : arg
                if arg == "mid" || arg == "owned" {
                    // "owned": only plans with the tools you have (the first-cut coupon).
                    let buy = model.planOptions.filter { !$0.needsTools.isEmpty }
                    let have = model.planOptions.filter(\.needsTools.isEmpty)
                    let pool = (arg == "owned" ? have : buy.isEmpty ? model.planOptions : buy).sorted { $0.minutes < $1.minutes }
                    name = (pool.first { $0.name.hasPrefix("Balanced") } ?? (pool.isEmpty ? nil : pool[pool.count / 2]))?.name ?? ""
                }
                if let c = model.planOptions.first(where: { $0.name == name }) { model.usePlan(c); print("using plan \(c.name) to buy \(model.jobToolsToBuy.map(\.name))") }
            case "paths": model.pathsVisible = arg != "off"
            case "workarea": model.showWorkArea = arg != "off"
            case "cutface": model.showCutFace = arg != "off"
            case "simdebug":
                for id in ["simstock", "simstock.back"] {
                    guard let m = model.renderer.scene.mesh(id) else { print("simdebug \(id) none"); continue }
                    var out: [String] = []
                    m.updateVertices { v in
                        for i in [0, 5000, 40000, 120000] where i * 6 + 5 < v.count {
                            out.append(String(format: "[z %.2f n %.2f %.2f %.2f]", v[i * 6 + 2], v[i * 6 + 3], v[i * 6 + 4], v[i * 6 + 5]))
                        }
                    }
                    print("simdebug \(id) visible \(m.isVisible) \(out.joined(separator: " ")) transform \(m.transform.columns.0) \(m.transform.columns.2)")
                }
            case "tabmoves":
                // Per operation on side B: the lowest cutting move whose tool covers a tab centre.
                if let r = model.result(forSide: 1) {
                    for (k, path) in r.paths.enumerated() where k < r.planned.count {
                        let rad = r.planned[k].tool.diameter / 2
                        var lowest = Double.infinity, count = 0
                        var roles: [String: Int] = [:]
                        for m in path.moves where m.role != .rapid {
                            for t in model.placedTabs where simd_distance(SIMD2(m.x, m.y), t.centre) < rad + 0.5 {
                                lowest = min(lowest, m.z); count += 1
                                if m.z < -15.3 { roles["\(m.role)", default: 0] += 1 }
                            }
                        }
                        print("  low roles \(roles)")
                        print("tabmoves \(r.planned[k].operation.kind.title) \(r.planned[k].tool.name.prefix(14)): \(count) moves over tabs, lowest z \(lowest.isFinite ? String(format: "%.2f", lowest) : "-")")
                    }
                }
            case "travelscan":
                // Every move of the clamping on screen in machine coordinates: anything outside the travel.
                if let r = model.result(forSide: model.viewSide) {
                    let e = model.machine.machineEnvelope
                    var worst: (String, SIMD3<Double>)? = nil, count = 0, total = 0
                    for (k, path) in r.paths.enumerated() where k < r.planned.count {
                        guard let toM = model.machineMapper(stickout: r.planned[k].tool.stickout) else { continue }
                        for m in path.moves {
                            total += 1
                            let q = toM(m.position)
                            if !(e.x.contains(q.x) && e.y.contains(q.y) && e.z.contains(q.z)) {
                                count += 1
                                if worst == nil { worst = ("\(r.planned[k].operation.kind.title) \(m.role) work \(String(format: "%.2f %.2f %.2f", m.x, m.y, m.z))", q) }
                            }
                        }
                    }
                    print("travelscan side \(model.viewSide) stage \(model.prepStage): \(count) of \(total) moves outside" + (worst.map { " · first: \($0.0) → machine \(String(format: "%.2f %.2f %.2f", $0.1.x, $0.1.y, $0.1.z))" } ?? ""))
                } else { print("travelscan side \(model.viewSide) stage \(model.prepStage): no result") }
            case "stripcheck":
                // Side B cutting moves whose tool reaches into the clamped strips.
                if let r = model.result(forSide: 1), let st = model.stock {
                    let strips = model.shoulderStrips(stockSize: model.setup.stockSize(st))
                    for (k, path) in r.paths.enumerated() where k < r.planned.count {
                        let rad = r.planned[k].tool.diameter / 2
                        var n = 0, worst = 0.0
                        for m in path.moves where m.role == .cut || m.role == .ramp || m.role == .plunge {
                            for s in strips {
                                let dx = max(s.min.x - m.x, 0, m.x - s.max.x), dy = max(s.min.y - m.y, 0, m.y - s.max.y)
                                let d = (dx * dx + dy * dy).squareRoot()
                                if d < rad - 0.05 {
                                    n += 1; worst = max(worst, rad - d)
                                    if n <= 3 { print("   \(m.role) \(m.motion) x \(String(format: "%.2f", m.x)) y \(String(format: "%.2f", m.y)) z \(String(format: "%.2f", m.z)) strip x \(s.min.x)…\(s.max.x) below \(r.planned[k].zTop)") }
                                }
                            }
                        }
                        print("stripcheck \(r.planned[k].operation.kind.title) \(r.planned[k].tool.name.prefix(12)): \(n) moves into the strips, deepest \(String(format: "%.2f", worst)) mm")
                    }
                }
            case "tabcheck":
                // The final side's heights along each tab, from the part outward (top, back).
                if let hm = model.heightmap {
                    for t in model.placedTabs {
                        var row: [String] = []
                        for k in stride(from: 0.0, through: 22.0, by: 2.0) {
                            let p = t.centre + t.normal * k
                            let c = Int(((p.x - hm.origin.x) / hm.cell).rounded()), r = Int(((p.y - hm.origin.y) / hm.cell).rounded())
                            guard c >= 0, r >= 0, c < hm.cols, r < hm.rows else { continue }
                            let i = r * hm.cols + c
                            row.append(String(format: "%+.0f:%.2f/%.2f", k, hm.heights[i], model.simBack?[i] ?? -99))
                        }
                        print("tab at \(t.centre) " + row.joined(separator: " "))
                    }
                }
            case "thumb":  // "thumb /tmp/t.png": the project icon as it would be saved
                if let img = model.projectThumbnail(), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: arg)); print("thumb written \(arg)")
                } else { print("thumb none") }
            case "optimes":  // simulated minutes per operation, both sides, longest first
                var rows: [(String, Double)] = []
                for r in model.sideResults {
                    for (k, path) in r.paths.enumerated() where k < r.planned.count {
                        let p = r.planned[k]
                        rows.append(("side \(r.side) \(p.operation.title)\(p.operation.pocketsOnly == true ? " (pockets)" : "") · \(p.tool.name.prefix(24)) · \(path.moves.count) moves", TimeEstimate.seconds([path]) / 60))
                    }
                }
                for (name, m) in rows.sorted(by: { $0.1 > $1.1 }) { print(String(format: "optimes %6.1f min  ", m) + name) }
            case "tuneest":  // the tuner's estimate for each roughing style and hidden side
                for st in FeedsEngine.RoughingStyle.allCases {
                    for hid in [nil, 1] as [Int?] {
                        var t = model.tuning
                        t.roughing = st == .thinned ? nil : st
                        t.hiddenSide = hid
                        print("tuneest \(st.title) hidden \(hid.map(String.init) ?? "-"): \(model.tunerEstimate(t).map { AppModel.duration($0.minutes * 60) } ?? "-")")
                    }
                }
            case "kitreach":
                if let st = model.stock, let p = model.clampPlacement(stockSize: model.setup.stockSize(st)) {
                    print("kitreach clamp centres (work Y) \(p.clamps.map { String(format: "%.2f", $0.columns.3.y - model.travelCentreY) }) shift \(model.setup.kitClampShift) strips \(model.shoulderStrips(stockSize: model.setup.stockSize(st)).map { String(format: "x %.1f…%.1f y %.2f…%.2f", $0.min.x, $0.max.x, $0.min.y, $0.max.y) })")
                }
                print("kitreach xrange \(model.kitWorkXRange.map { "\($0)" } ?? "-") reach \(model.reachExcess.map { "above \($0.above) below \($0.below)" } ?? "-") shoulders \(model.setup.shoulders.map { "h \($0.height) bottom \($0.bottom)" } ?? "none") max bottom \(model.maxShoulderBottom)")
            case "edgemoves":  // cutting moves near the stock's X edges, per operation (side on screen)
                if let r = model.result(forSide: model.viewSide), let st = model.stock {
                    let hx = model.setup.stockSize(st).x / 2
                    print("edgemoves kitXRange \(model.kitWorkXRange.map { "\($0)" } ?? "-") stock half \(hx)")
                    for (k, path) in r.paths.enumerated() where k < r.planned.count {
                        let rad = r.planned[k].tool.diameter / 2
                        let reach = path.moves.filter { $0.role != .rapid && abs($0.x) + rad >= hx - 0.05 }
                        guard !reach.isEmpty else { continue }
                        print("  \(r.planned[k].operation.title) \(r.planned[k].tool.name.prefix(12)): \(reach.count) moves reach the edge, max |x| \(String(format: "%.2f", reach.map { abs($0.x) }.max() ?? 0)), z \(String(format: "%.2f…%.2f", reach.map(\.z).min() ?? 0, reach.map(\.z).max() ?? 0))")
                    }
                }
            case "loose": print("loose pieces \(model.loosePieces) walls \(model.renderer.scene.mesh("simstock.walls") != nil ? "yes" : "no")")
            case "deviation":
                model.showDeviation = arg != "off"
                try? await Task.sleep(for: .seconds(3))
                if let d = model.deviationStats { print("deviation within=\(d.within) maxLeft=\(d.maxLeft) maxGouge=\(d.maxGouge)") } else { print("deviation none") }
            case "mesh":  // "mesh stock": colour, material and visibility of a scene mesh
                if let m = model.renderer.scene.mesh(arg) {
                    print("mesh \(arg) color=\(m.color) visible=\(m.isVisible) material=\(m.material) realistic=\(model.renderer.realistic) display=\(model.stockDisplay)")
                } else { print("mesh \(arg) missing") }
            case "milldown": model.previewMillDown = arg != "off"
            case "measure": model.measuring = arg != "off"
            case "fit": model.focusWork()
            case "tab": model.enter(arg == "machining" ? .machining : .partStock)
            case "stagebar": if let st = JobStage.allCases.first(where: { "\($0)" == arg }) { model.enter(st) }
            case "crproj":
                do {
                    try model.exportGuidedJob(to: URL(fileURLWithPath: arg), measuring: inventory.inventory.measuring)
                    print("crproj written \(arg)")
                } catch { print("crproj failed: \(error)") }
            case "suggest": await suggestCommand(model, inventory)
            case "generate": await generateCommand(model, inventory)
            case "generatebg":  // start generating and go on (background generation)
                Task { @MainActor in await generateCommand(model, inventory) }
                try? await Task.sleep(for: .milliseconds(300))
            case "waitgen":  // until the background generation ends
                while model.isGenerating { try? await Task.sleep(for: .milliseconds(500)) }
                try? await Task.sleep(for: .seconds(1))
            case "genstate":
                print("genstate \(model.status) | sides shown \(model.sideResults.map { $0.planned.count }) timeline \(Int(model.timeline.duration)) s playhead \(Int(model.playhead)) playing \(model.isPlaying) | failed \(model.failedOperationCount)")
            case "scrollto": model.inspectorScrollTarget = arg
            case "tuner": if let p = Tuning.Preset(rawValue: arg) { model.tuning = .preset(p) }
            case "export":
                let dir = URL(fileURLWithPath: arg)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                do { print("exported", try model.exportPrograms(to: dir).map(\.lastPathComponent)) } catch { print("export failed: \(error)") }
            case "orbit":
                let d = arg.split(separator: " ").compactMap { Float($0) }
                if d.count == 2 { model.renderer.camera.orbit(dx: d[0], dy: d[1]) }
            case "perspective": model.perspective = arg != "off"
            case "twosided": model.twoSided = arg != "off"; model.twoSidedChosen = true
            case "holdtabs": model.holdWithTabs = arg != "off"; print("hold with tabs \(model.holdWithTabs)")
            case "softjaw":
                model.setup.clampSoftJaw = arg == "on"
                try? await Task.sleep(for: .milliseconds(300))
                print("softjaw \(model.setup.clampSoftJaw) shoulders \(model.setup.shoulders.map { "h \($0.height) bottom \($0.bottom)" } ?? "-") prep \(model.flatPrepPlan?.stages.map(\.title) ?? [])")
            case "side": model.viewSide = Int(arg) ?? 0
            case "stage": model.show(side: -1, stage: Int(arg) ?? 0)  // a prep clamping
            case "analysis":
                if let a = model.analysis {
                    print("analysis corner=\(a.minCornerRadius ?? -1) concave=\(a.minConcaveRadius ?? -1) undercut=\(a.undercutArea) tris=\(a.undercutTriangles.count / 9) thin=\(a.thinnestWall ?? -1) undercutMesh=\(model.renderer.scene.mesh("undercuts") != nil)")
                } else { print("analysis none") }
            case "seek": model.seek((Double(arg) ?? 0.5) * model.timeline.duration)  // fraction of the job
            case "bridges": print("bridges \(model.bridgeNote ?? "none") standout \(model.autoProtrusion.map { "\($0)" } ?? "-")")
            case "cancelafter":  // "cancelafter 8": cancel the next generation after 8 s
                let delay = Double(arg) ?? 5
                Task { @MainActor in try? await Task.sleep(for: .seconds(delay)); model.cancelGenerationNow() }
            case "scale": model.setup.partScale = Double(arg) ?? 1
            case "jog":  // "jog -40 -120 -30": machine coordinates
                let v = arg.split(separator: " ").compactMap { Double($0) }
                model.jogOpen = true
                if v.count == 3 { model.jog(to: SIMD3(v[0], v[1], v[2])) }
            case "saveproject": try? model.saveProject(to: URL(fileURLWithPath: arg)); print("saved \(arg)")
            case "openproject":
                let t0 = Date()
                await model.openProject(URL(fileURLWithPath: arg))
                print("opened \(arg) in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s scale \(model.setup.partScale) programs \(model.programs.count) passed \(model.programs.allSatisfy(\.report.passed)) prep \(model.prepPrograms.count) timeline \(Int(model.timeline.duration)) s status \(model.status)")
            case "undo": await model.undo(); print("undo scale \(model.setup.partScale) canUndo \(model.canUndo)")
            case "undoname": print("undoname \(model.undoName ?? "-") | redoname \(model.redoName ?? "-")")
            case "redo": await model.redo(); print("redo scale \(model.setup.partScale)")
            case "copies":  // batching
                var s = model.setup
                s.copies = Int(arg) ?? 1
                model.setup = model.placementLimited(s)
                print("copies \(model.setup.copies) max \(model.maxCopies) offsets \(model.copyOffsets(for: model.setup))")
            case "recordjob":  // "recordjob chatter": record the generated job in the (test) journal
                if var e = model.draftJournalEntry() {
                    e.chatter = arg == "chatter"
                    var notes: [String] = []
                    inventory.update { inv in notes = JobJournal.record(e, into: &inv) }
                    model.journal.add(e, tools: inventory.inventory.tools)
                    print("recorded \(e.partName) \(String(format: "%.1f", e.cuttingMinutes)) min, remnant \(e.remnantLength.map { "\($0)" } ?? "-"); \(notes) journal \(model.journal.entries.count) learned \(model.journal.learning.factors)")
                    let worn = inventory.inventory.tools.filter { $0.cuttingMinutes > 0 }.map { "\($0.name.prefix(14)) \(Int($0.cuttingMinutes)) min" }
                    print("tool wear \(worn) stock \(inventory.inventory.stock.map { "\($0.sizeDescription) remnant \($0.isRemnant)" })")
                } else { print("recordjob: nothing generated") }
            case "engrave", "engraveprobe":  // "engrave LOVE": text at the face's centre, finest tool; engraveprobe: following the probed face
                var op = Operation(kind: .engrave)
                op.engraving = Engraving(text: arg, height: 3, depth: 0.15)
                if parts.first == "engraveprobe" { op.engraving?.probeSurface = true }
                op.toolID = OperationPlanner.usableTools(inventory.inventory)
                    .filter { [.engraver, .chamferMill, .flatEndMill, .ballEndMill].contains($0.kind) && $0.diameter <= 3.2 }
                    .min { $0.diameter < $1.diameter }?.id
                model.operations.append(op)
                print("engrave \(arg) tool \(inventory.inventory.tools.first { $0.id == op.toolID }?.name ?? "none") size \(op.engraving!.size)")
            case "resolve":  // "resolve 1": find a collision-free place for C-clamp 1
                let t0 = Date()
                let ok = await model.resolveClampCollision((Int(arg) ?? 1) - 1)
                print("resolve \(ok) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: \(model.status) overrides \(model.setup.prepOverrides)")
            case "options":  // the stock's orientations as stage 1 lists them
                for o in model.stockOptions() { print("option \(o.axes) workable \(o.workable) shoulders \(o.viaShoulders) prep \(o.prepHeight.map { "\($0)" } ?? "-") current \(o.axes == model.setup.stockAxes): \(o.summary)") }
                print("reach \(model.reachExcess.map { "above \($0.above) below \($0.below)" } ?? "-") prep stages \(model.flatPrepPlan?.stages.map(\.title) ?? [])")
                print("status1 \(model.status(.partStock).why) | shoulders \(model.setup.shoulders.map { "\($0)" } ?? "none") hasPrep \(model.hasPrep) topAllowance \(model.setup.topAllowance)")
            case "welcome": model.showWelcome = arg != "off"
            case "start": model.showStart = arg != "off"
            case "example":  // "example watch_bridge" (or its number, 1–4)
                if let ex = ExamplePart.all.first(where: { $0.id == arg }) ?? Int(arg).flatMap({ ExamplePart.all.indices.contains($0 - 1) ? ExamplePart.all[$0 - 1] : nil }) {
                    await model.openExample(ex, inventory: inventory)
                    print("example \(ex.id) part \(model.part?.fileName ?? "-") stock \(model.stock.map { "\($0.sizeDescription) suggestion \($0.isSuggestion)" } ?? "-") holding \(model.holdingPath) twoSided \(model.twoSided) clamps \(model.stock.flatMap { model.clampPlacement(stockSize: model.setup.stockSize($0))?.clamps.count } ?? 0)")
                }
            case "autoprot": model.autoProtrusion = Double(arg)  // tests: as if generation had asked for this stand-out
            case "axes":  // "axes 2 1 0": which stock dimension each work axis is
                model.useStockAxes(arg.split(separator: " ").compactMap { Int($0) })
                print("axes \(model.setup.stockAxes) size \(model.stock.map { model.setup.stockSize($0) } ?? .zero)")
            case "holding":  // "holding bedOnly"
                if let h = HoldingPath(rawValue: arg) { model.choose(h) }
                for h in HoldingPath.allCases { let a = model.holdingAssessment(h); print("holding \(h.letter) possible \(a.possible) rec \(a.recommended) current \(model.holdingPath == h): \(a.why)") }
                print("onBed \(model.setup.onBed) twoSided \(model.twoSided) kit status \(model.status(.clampKit).why)")
            case "bedpick":  // "bedpick stop" / "bedpick clamp1"
                model.bedSelection = arg == "stop" ? .stop : arg.hasPrefix("clamp") ? .clamp((Int(arg.dropFirst(5)) ?? 1) - 1) : nil
                print("bedpick \(model.bedSelection.map(\.title) ?? "none") editable \(model.bedEditable)")
            case "collisions":  // waits for the background check, then prints it
                try? await Task.sleep(for: .seconds(Double(arg) ?? 3))
                print("collisions \(model.collisions.map { "\($0.a) × \($0.b) \(String(format: "%.2f", $0.depth)) mm at \($0.point)" }) machine tris \(model.machineTree?.triangleCount ?? -1)")
            case "probe":  // "probe y": the machine's surface seen from above, across Z at that Y, and the back edge
                if let y = Double(arg), let tree = await model.machineCollisionTree() {
                    var row: [String] = []
                    for z in stride(from: -80.0, through: 0, by: 2) {
                        let t = tree.raycast(SIMD3(20, y, z), SIMD3(-1, 0, 0))
                        row.append("z\(Int(z)):\(t.map { String(format: "%.2f", 20 - $0) } ?? "-")")
                    }
                    print("probe top y \(y) " + row.joined(separator: " "))
                    var back: [String] = []
                    for x in stride(from: -31.5, through: -46, by: -2.0) {
                        let t = tree.raycast(SIMD3(x, y, -150), SIMD3(0, 0, 1))
                        back.append("x\(x):\(t.map { String(format: "%.2f", -150 + $0) } ?? "-")")
                    }
                    print("probe back y \(y) " + back.joined(separator: " "))
                }
            case "kitbounds":  // local bounds of each kit part of a kit
                for (j, p) in model.kitParts.enumerated() where p.kit == arg {
                    let v = p.mesh.vertices
                    var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
                    for i in stride(from: 0, to: v.count, by: 3) { let q = SIMD3(Float(v[i]), Float(v[i + 1]), Float(v[i + 2])); lo = simd_min(lo, q); hi = simd_max(hi, q) }
                    print("kitpart \(j) \(p.name) [\(p.role)] lo \(lo) hi \(hi)")
                }
            case "collisiondetail":  // which kit part hits which machine part (role), per colliding fixture
                guard let mm = model.machineModel else { break }
                let machines = mm.parts.filter { $0.group == "static" || $0.group == "x" }.map { p -> Collision.Body in
                    var t: [SIMD3<Double>] = []
                    for idx in p.mesh.indices { let i = Int(idx) * 3; t.append(SIMD3(Double(p.mesh.vertices[i]), Double(p.mesh.vertices[i + 1]), Double(p.mesh.vertices[i + 2]))) }
                    return Collision.Body(name: "machine \(p.group)/\(p.role)", triangles: t)
                }
                for m in model.renderer.scene.meshes where m.id.hasPrefix("fixture.") && m.isVisible {
                    let parts = m.id.split(separator: ".")
                    guard parts.count == 4, let j = Int(parts[3]) else { continue }
                    let kp = model.kitParts[j]
                    var t: [SIMD3<Double>] = []
                    let tf = m.transform
                    for idx in kp.mesh.indices {
                        let i = Int(idx) * 3
                        let w = tf * SIMD4<Float>(Float(kp.mesh.vertices[i]), Float(kp.mesh.vertices[i + 1]), Float(kp.mesh.vertices[i + 2]), 1)
                        t.append(SIMD3(Double(w.x), Double(w.y), Double(w.z)))
                    }
                    let body = Collision.Body(name: "\(m.id) \(kp.name) [\(kp.role)]", triangles: t)
                    for c in Collision.check([body] + machines, tolerance: 0.1) where c.a == body.name || c.b == body.name {
                        print("detail \(c.a) × \(c.b) \(String(format: "%.2f", c.depth)) at \(c.point)")
                    }
                }
            case "bedissues":
                print("bed overrides \(model.setup.prepOverrides) issues \(model.bedIssues.map(\.message)) kit \(model.status(.clampKit).why) setupIssues \(model.setupIssues.map(\.message))")
                for p in model.prepPrograms { print("prep program \(p.title ?? "") passed \(p.report.passed) hits \(p.clearanceHits.count)") }
            case "gring":  // "gring z 40": grab a ring (x/y/z; default x) at its u point, drag 40 px along it
                let w = arg.split(separator: " ")
                let k = ["x": 0, "y": 1, "z": 2][String(w.first ?? "x")] ?? 0
                let px = Double(w.last ?? "30") ?? 30
                if let v = NSApp.windows.lazy.compactMap({ $0.contentView?.firstSubview(of: ViewportNSView.self) }).first,
                   let t = model.gumballTarget, let o = model.gumballOrigin(t) {
                    let size = v.bounds.size, r = model.gumballLength * AppModel.ringShare, (u, vv, _) = AppModel.ringBasis(k)
                    // Grab at 45° (where no other ring crosses), then follow the ring round.
                    let a0: Float = .pi / 4
                    if let s0 = model.project(o + (u * cos(a0) + vv * sin(a0)) * r, size),
                       let s1 = model.project(o + (u * cos(a0 + 0.3) + vv * sin(a0 + 0.3)) * r, size) {
                        let d = hypot(s1.x - s0.x, s1.y - s0.y)
                        let began = model.gumballBegin(s0, size)
                        var a: Float = a0
                        let step: Float = 0.05
                        var travelled = 0.0
                        while travelled < px, a < a0 + 3 {
                            a += step
                            if let q = model.project(o + (u * cos(a) + vv * sin(a)) * r, size) { model.gumballMove(q, size) }
                            travelled += d / 0.3 * Double(step)
                        }
                        model.gumballEnd()
                        print("gring \(k) began \(began) facing \(model.setup.facing) spin \(model.setup.spin) overrides \(model.setup.prepOverrides) \(model.setup.bedJobOverride)")
                    }
                }
            case "gpress":  // "gpress clamp1 40 0" / "gpress stop 40 0": press on that fixture, drag by (dx, dy) px
                let w = arg.split(separator: " ")
                let f = w.dropFirst().compactMap { Double($0) }
                if w.count == 3, let v = NSApp.windows.lazy.compactMap({ $0.contentView?.firstSubview(of: ViewportNSView.self) }).first {
                    let size = v.bounds.size
                    model.bedSelection = nil
                    let obj: BedObject = w[0] == "stop" ? .stop : w[0] == "kstock" ? .kitStock
                        : w[0].hasPrefix("kclamp") ? .kitClamp((Int(w[0].dropFirst(6)) ?? 1) - 1) : .clamp((Int(w[0].dropFirst(5)) ?? 1) - 1)
                    // Aim at the object: the pad (clamp) or the stop's top, a hair inside it.
                    var down: Float = 3
                    if case .kitClamp = obj { down = 40 }  // into the clamp's body, not the air between its screws
                    guard let aim = model.gumballOrigin(.bed(obj)), let p0 = model.project(aim - SIMD3(down, 0, 0), size) else { print("gpress: nothing to aim at"); break }
                    let f = [0, 0] + f
                    let began = model.gumballBegin(p0, size)
                    for k in 1...10 { model.gumballMove(CGPoint(x: p0.x + f[2] * Double(k) / 10, y: p0.y + f[3] * Double(k) / 10), size) }
                    _ = began
                    model.gumballEnd()
                    print("gpress began \(began) picked \(model.bedSelection.map(\.title) ?? "none") overrides \(model.setup.prepOverrides) kit \(model.setup.kitClampShift) protrusion \(model.setup.clampProtrusion) auto \(model.autoProtrusion.map { "\($0)" } ?? "-")")
                }
            case "gdrag":  // "gdrag x 60": grab the X arrow, drag 60 px along it on screen
                let a = arg.split(separator: " ")
                if a.count == 2, let px = Double(a[1]), let v = NSApp.windows.lazy.compactMap({ $0.contentView?.firstSubview(of: ViewportNSView.self) }).first,
                   let t = model.gumballTarget, let o = model.gumballOrigin(t), let axis = AppModel.gumballAxes.first(where: { $0.id == "gumball.\(a[0])" }) {
                    let size = v.bounds.size
                    if let s0 = model.project(o + axis.dir * model.gumballLength * 0.6, size), let s1 = model.project(o + axis.dir * model.gumballLength, size) {
                        let d = hypot(s1.x - s0.x, s1.y - s0.y)
                        let end = CGPoint(x: s0.x + (s1.x - s0.x) / d * px, y: s0.y + (s1.y - s0.y) / d * px)
                        let began = model.gumballBegin(s0, size)
                        model.gumballMove(end, size)
                        model.gumballEnd()
                        print("gdrag \(a[0]) began \(began) offsets X\(model.setup.partOffsetX) Y\(model.setup.partOffsetY) depth \(model.setup.topAllowance) bed \(model.setup.prepOverrides)")
                    }
                }
            case "psnap": if let s = ["centre": AppModel.PlacementSnap.centre, "face": .face, "back": .back, "top": .top, "bottom": .bottom, "left": .left, "right": .right][arg] { model.snapPart(s) }
            case "simready":  // waits for the background checkpoints (Playback.precomputeCheckpoints)
                let t0 = Date()
                await model.simPrecompute?.value
                print("simready \(model.simCheckpoints.count) checkpoints after \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
            case "jobstep":  // "jobstep 5": go to that step as clicking it does
                let steps = model.jobSteps
                if let n = Int(arg), steps.indices.contains(n - 1) { model.go(to: steps[n - 1]) }
                print("jobstep \(arg) → side \(model.viewSide) stage \(model.prepStage) playhead \(Int(model.playhead)) current \(model.currentStep.map { "\($0.number) \($0.title)" } ?? "-")")
            case "play":  // Play (one step), as the button does
                model.togglePlay()
                print("play playing \(model.isPlaying) toolchange \(model.toolChangeStop.map { "\($0.phase) to \($0.to.name)" } ?? "-") playhead \(Int(model.playhead))")
            case "tcpath":  // the tool-change path from where the machine is, and whether each pose is clear
                let plan = model.toolChangePath(from: model.machinePosition, tool: model.currentTool)
                print("tcpath " + plan.path.map { "(\(Int($0.x)),\(Int($0.y)),\(Int($0.z)))\(model.headClear(at: $0, tool: model.currentTool) ? "" : "!")" }.joined(separator: " → ") + " note \(plan.note ?? "-")")
                let tc = model.machine.toolChangePose
                print("tcpath coast runner pose clear \(model.headClear(at: tc, tool: model.currentTool)) kit shift \(model.kitShiftY)")
            case "toolchange":  // "toolchange" prints it, "toolchange ok" confirms it
                if arg == "ok" { model.confirmToolChange() }
                print("toolchange \(model.toolChangeStop.map { "\($0.phase) from \($0.from?.name ?? "-") to \($0.to.name)" } ?? "none") playing \(model.isPlaying) machine \(model.machinePosition) tool \(model.currentTool?.name ?? "-") playhead \(Int(model.playhead))")
            case "tabhold": await tabHoldCommand(model)  // whether each holding tab ends in frame that stays
            case "visible":  // the work's meshes on screen (not the machine)
                print("visible " + model.renderer.scene.meshes.filter { $0.isVisible && !$0.id.hasPrefix("machine.") && !$0.id.hasPrefix("fixture.") }.map { "\($0.id)(a\(String(format: "%.2f", $0.color.w)))" }.joined(separator: " "))
            case "jobsteps":
                for st in model.jobSteps { print("step \(st.number) [\(st.kind)] side \(st.side) stage \(st.stage) \(st.title) — \(st.detail)") }
            case "scrub":  // "scrub 40": that many back-and-forth seeks, timed
                let t0 = Date()
                for k in 0..<(Int(arg) ?? 40) { model.seek(Double((k * 37) % 100) / 100 * model.timeline.duration) }
                print("scrub \(arg) seeks in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
            case "colour": if let c = PathColorMode(rawValue: arg) { model.colorMode = c }
            case "inspect":  // "inspect 0.5 0.5": click at viewport fractions in inspect mode
                let f = arg.split(separator: " ").compactMap { Double($0) }
                if f.count == 2, let v = NSApp.windows.lazy.compactMap({ $0.contentView?.firstSubview(of: ViewportNSView.self) }).first {
                    model.inspecting = true
                    model.inspect(at: CGPoint(x: f[0] * v.bounds.width, y: f[1] * v.bounds.height), viewSize: v.bounds.size)
                    print("inspected \(model.inspected.map { "\($0.operation) line \($0.line ?? -1)" } ?? "nothing")")
                }
            case "camera":
                let c = model.renderer.camera
                print("camera target=\(c.target) distance=\(c.distance) yaw=\(c.yaw) pitch=\(c.pitch)")
                for m in model.renderer.scene.meshes where ["part", "stock"].contains(m.id) {
                    print("  \(m.id) local=\(m.boundsMin)…\(m.boundsMax) t=\(m.transform.columns.3)")
                }
            case "loadmachine": await model.loadMachine()
            case "click":  // "click 0.5 0.4": fractions of the viewport's width and height
                let f = arg.split(separator: " ").compactMap { Double($0) }
                if f.count == 2, let v = NSApp.windows.lazy.compactMap({ $0.contentView?.firstSubview(of: ViewportNSView.self) }).first {
                    let size = v.bounds.size
                    model.handleClick(at: CGPoint(x: f[0] * size.width, y: f[1] * size.height), viewSize: size)
                }
            case "inspector": model.showInspector = arg != "off"
            case "appearance": NSApp.appearance = NSAppearance(named: arg == "dark" ? .darkAqua : .aqua)
            case "size":
                let wh = arg.split(separator: "x").compactMap { Double($0) }
                if wh.count == 2, let w = NSApp.windows.first(where: { $0.isVisible }) {
                    w.setContentSize(NSSize(width: wh[0], height: wh[1]))
                }
            case "snap":
                do {
                    try model.renderer.snapshot(width: 1600, height: 1000, to: URL(fileURLWithPath: arg))
                    print("snap \(arg) gpu=\(String(format: "%.2f", model.renderer.lastFrameMilliseconds))ms")
                } catch { print("snap failed: \(error)") }
            case "wsnap": WindowSnapshot.capture(to: URL(fileURLWithPath: arg))
            case "print":
                print("measure=\(model.measurePoints.map { $0.info?.summary ?? "pending" }) distance=\(model.measuredDistance.map { Length.mm($0) } ?? "-") issues=\(model.setupIssues.map(\.message))")
                print("page=\(model.page) status=\(model.status) tools=\(inventory.inventory.tools.count) stock=\(inventory.inventory.stock.count) error=\(inventory.lastError ?? "-")")
            case "accent": if let a = AppSettings.Accent(rawValue: arg) { AppSettings.shared.accent = a }
            case "wait": try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
            case "quit":  // a sheet on top would hold the app open
                model.showStart = false
                model.showWelcome = false
                model.showNestSheet = false
                try? await Task.sleep(for: .milliseconds(300))
                NSApplication.shared.terminate(nil)
            default: print("unknown automation command: \(command)")
            }
        }
    }
}

extension Automation {
    // Async commands live in their own functions: one huge async switch with many awaits
    // tripped a Swift concurrency allocator crash ("freed pointer was not the last allocation").
    static func suggestCommand(_ model: AppModel, _ inventory: InventoryModel) async {
        await model.suggestOperations(inventory: inventory.inventory)
        print("suggest ops=\(model.operations.map(\.kind.rawValue)) notes=\(model.planNotes) error=\(model.errorMessage ?? "-")")
    }

    static func couponCommand(_ model: AppModel, _ inventory: InventoryModel, _ material: String) async {
        let problem = await model.openFirstCutCoupon(material: material.isEmpty ? nil : material, inventory: inventory)
        print("coupon \(model.stock.map { "\($0.materialID) \($0.sizeDescription)" } ?? "-") programs \(model.programs.count) passed \(model.programs.allSatisfy(\.report.passed)) \(problem ?? "") status \(model.status)")
    }

    static func tabHoldCommand(_ model: AppModel) async {
        let held = await model.tabsHold()
        print("tabhold \(held.map { $0.map { $0 ? "holds" : "FLOATS" }.joined(separator: " ") } ?? "no tabs") placed \(model.placedTabs.map { t in "(\(Int(t.centre.x)),\(Int(t.centre.y)) long \(t.extent.map { String(format: "%.1f", $0.length) } ?? "?"))" })")
    }

    static func generateCommand(_ model: AppModel, _ inventory: InventoryModel) async {
        await model.generateToolpaths(inventory: inventory.inventory)
        print("generate status=\(model.status) error=\(model.errorMessage ?? "-")")
        for p in model.programs {
            print("program \(p.index + 1) side \(p.side) \(p.tool.name) passed=\(p.report.passed) lines=\(p.report.lineCount) secs=\(Int(p.seconds)) issues=\(p.report.issues.map(\.message))")
            if let h = p.clearanceHits.first, let r = model.result(forSide: p.side) {
                let moves = zip(r.paths, r.operationProgram).filter { $0.1 == p.index }.flatMap(\.0.moves)
                let k = h.moveIndex
                let around = moves[max(k - 2, 0)...min(k + 1, moves.count - 1)].map { "\($0.role) \($0.motion) (\(String(format: "%.2f %.2f %.2f", $0.x, $0.y, $0.z)))" }
                print("  hit \(h.part) at \(h.position) move \(k): \(around)")
            }
        }
    }
}

/// Window capture through the window server, so Liquid Glass renders (off-screen
/// `cacheDisplay` snapshots don't draw glass). `CGWindowListCreateImage` is looked up at
/// runtime because the SDK marks it unavailable; capturing our own windows needs no permission.
@MainActor
enum WindowSnapshot {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImage? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    static func capture(to url: URL) {
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.title != "" }) ?? NSApp.windows.first(where: \.isVisible) else {
            print("wsnap: no window")
            return
        }
        let window = main.attachedSheet ?? main  // a sheet on top (start, welcome) is what's on screen
        let rep: NSBitmapImageRep
        // kCGWindowListOptionIncludingWindow = 1 << 3, kCGWindowImageBoundsIgnoreFraming = 1 << 0
        if let createImage, let image = createImage(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue(),
           image.width > 1 {
            rep = NSBitmapImageRep(cgImage: image)
        } else {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: cached)
            rep = cached
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wsnap \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
}

extension NSView {
    /// Depth-first search for a subview of a type (automation only).
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for v in subviews {
            if let t = v as? T { return t }
            if let t = v.firstSubview(of: type) { return t }
        }
        return nil
    }
}
