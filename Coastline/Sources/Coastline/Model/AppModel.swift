import AppKit
import CoastlineCore
import Foundation
import Metal
import Observation
import simd
import Viewport

/// What the inspector shows about the imported part.
struct PartInfo: Equatable {
    var url: URL
    var fileName: String
    var kind: String
    var exact: Bool
    var faceCount: Int
    var triangleCount: Int
    var size: Vec3
    var boundsMin: SIMD3<Double>
    var boundsMax: SIMD3<Double>
    var partID: String
    var warnings: [String]
}

/// How much of the CR-1 to draw.
enum MachineDisplay: String, CaseIterable, Identifiable {
    case full, open, ghost, moving, hidden
    var id: Self { self }
    var title: String {
        switch self {
        case .ghost: "Ghosted (see-through)"
        case .full: "Whole machine"
        case .open: "Without enclosure"
        case .moving: "Moving parts only"
        case .hidden: "Hidden"
        }
    }
}

/// One measuring click.
struct MeasurePoint: Equatable {
    var world: SIMD3<Float>
    var info: FaceInfo?
}

/// App state: navigation plus the workspace (machine, part, stock, setup, measuring).
///
/// Scene frame: the CR-1 assembly's own coordinates, which are the machine axes (X up,
/// Y right, Z toward the spindle). The work frame of `Setup` is placed into it with
/// `workToModel` (a pure translation: the axes are the same).
@MainActor
@Observable
final class AppModel {
    let machine = MachineProfile.cr1
    let renderer: ViewportRenderer

    // Navigation
    var page: SidebarItem = .workspace
    var showInspector = true
    /// Section the inspector should scroll to ("tuner").
    var inspectorScrollTarget: String?
    enum InspectorTab { case setup, machining }
    var inspectorTab = InspectorTab.setup {
        didSet {
            // Old callers still switch tabs: keep the stage in step.
            if inspectorTab == .machining, ![.machining, .review].contains(stage) { stage = .machining }
            if inspectorTab == .setup, [.machining, .review].contains(stage) { stage = .partStock }
        }
    }
    /// The workflow stage on screen (StageBar).
    var stage = JobStage.partStock

    // Workspace
    var part: PartInfo?
    var setup = Setup() {
        didSet {
            guard setup != oldValue else { return }
            if setup.bedJobOverride != oldValue.bedJobOverride, ProcessInfo.processInfo.environment["COASTLINE_DEBUG_BED"] != nil {
                print("DEBUG bed override \(oldValue.bedJobOverride) -> \(setup.bedJobOverride)\n" + Thread.callStackSymbols.prefix(14).joined(separator: "\n"))
            }
            var a = setup, b = oldValue
            a.prepOverrides = []
            b.prepOverrides = []
            // The kit's clamps along the slots and the stock's stand-out: the toolpaths are
            // relative to the stock face, so they stay (and are checked again; KitEditor).
            a.kitClampShift = []; b.kitClampShift = []
            a.clampProtrusion = 0; b.clampProtrusion = 0
            if a == b {
                // Only fixtures moved (BedEditor, KitEditor): the part's toolpaths stay valid.
                layoutScene(); saveSession(); noteProjectChange()
                if setup.kitClampShift != oldValue.kitClampShift || setup.clampProtrusion != oldValue.clampProtrusion,
                   gumballDrag == nil { recheckClearance() }
                return
            }
            clearToolpathResults(); layoutScene(); saveSession(); scheduleAnalysis(); keepStockWorkable(); autoPlanPrep(); noteProjectChange()
        }
    }
    /// Collision engine results for what's on the bed now (CollisionCheck.swift).
    var collisions: [Collision.Contact] = []
    @ObservationIgnored var collisionPrefixes: [String: String] = [:]
    @ObservationIgnored var collisionGeneration = 0
    @ObservationIgnored var machineTree: TriangleTree?
    /// The spindle head (z group) and the translator (y group) at the modelled pose, for the
    /// tool-change path check (ToolChange.swift).
    @ObservationIgnored var headTrees: (z: TriangleTree, y: TriangleTree)?
    /// What's on the table (fixtures, parallels, stock) as last laid out, and its tree.
    @ObservationIgnored var bedBodies: [BedBody] = []
    @ObservationIgnored var bedTree: (generation: Int, tree: TriangleTree)?
    @ObservationIgnored var machineTreeTask: Task<TriangleTree?, Never>?
    /// Generated operations by everything that shapes them (Machining.swift).
    @ObservationIgnored var opCache: [String: ([OperationToolpath], [PlacedTab])] = [:]
    @ObservationIgnored var opCacheOrder: [String] = []
    @ObservationIgnored var cachedOps = 0
    /// Shoulders Coastline planned itself (undone when the stock fits another way).
    var shouldersAuto = false
    @ObservationIgnored var prepProgramCache: (key: String, items: [GuidedJobBuilder.MillDown.Item])?
    @ObservationIgnored var clampFieldCache: (key: String, field: FixtureField?)?
    @ObservationIgnored var cClampFrameCache: (Double, Double)?
    @ObservationIgnored var clearanceRecheck: Task<Void, Never>?
    @ObservationIgnored var partMeshData: (positions: [Float], normals: [Float], indices: [UInt32])?
    /// The welcome guide: once on first launch (never in automation runs), then from Help.
    var showWelcome = ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil && !UserDefaults.standard.bool(forKey: "seenWelcome")
    /// The start sheet (StartView): continue, open, import or pick an example. At launch (after
    /// the welcome the first time), and from File ▸ Start….
    var showStart = false
    /// The job journal.
    let journal = JournalModel()
    /// A typed move waiting for its value (GumballTyping.swift).
    var gumballPrompt: GumballPrompt?
    /// The fixture picked on the bed (stage 3).
    var bedSelection: BedObject? { didSet { if bedSelection != oldValue { layoutGumball() } } }
    var stockID: StockItem.ID? { didSet { if stockID != oldValue { layoutScene(); saveSession(); keepStockWorkable(); autoPlanPrep(); noteProjectChange() } } }
    // The job as a document: its file, unsaved changes, and undo history (ProjectDocument.swift).
    var projectURL: URL?
    var projectDirty = false
    var undoHistory: [ProjectFile] = []
    var redoHistory: [ProjectFile] = []
    @ObservationIgnored var restoringProject = false
    /// Jog panel: open, and what's in the collet (nil: no bit).
    var jogOpen = false
    var jogTool: Tool?
    @ObservationIgnored var lastSnapshot: ProjectFile?
    @ObservationIgnored var lastChangeAt = Date.distantPast
    /// The whole machine at start; it turns see-through once there's work inside to look at.
    var machineDisplay = MachineDisplay.full { didSet { applyMachineDisplay() } }
    var machineLoaded = false
    /// Perspective is optional; orthographic (no distortion) is the default.
    var perspective = false {
        didSet { if renderer.destinationCamera.orthographic == perspective { renderer.moveCamera(animated: false) { $0.orthographic = !perspective } } }
    }
    /// Mirror of the renderer's camera for SwiftUI (the view cube).
    var camera = OrbitCamera()
    var showWorkArea = true { didSet { layoutScene() } }
    /// Live machine coordinates (X, Y, Z) of the modelled CR-1.
    var machinePosition = SIMD3<Double>(0, 0, 0)
    /// The tool in the collet (the playing program's, or the first planned one).
    var currentTool: Tool?
    var status = "Ready"
    var isBusy = false
    var errorMessage: String?
    var toolpathSegments = 0

    // Machining
    var operations: [Operation] = [] { didSet { if operations != oldValue { clearToolpathResults(); noteProjectChange(); layoutEngravingPreview() } } }
    var planNotes: [String] = []
    /// Smart planner: every candidate, the three recommended, and the chosen one's
    /// per-operation estimate (compared with the simulation after generating).
    var planCandidates: [StrategyEngine.Candidate] = []
    var planOptions: [StrategyEngine.Candidate] = []
    var chosenPlan: String?
    /// The plan Coastline recommends (with tools to buy when your own can't do it safely).
    var recommendedPlan: String?
    @ObservationIgnored var planEstimate: [UUID: Double] = [:]
    @ObservationIgnored var calibration = AppModel.loadCalibration()
    /// Quality ↔ time tuner: the setting being explored, the one the current
    /// toolpaths were generated with, rates for the cost, and the batch size.
    var tuning = Tuning()
    var generatedTuning = Tuning()
    var costModel = AppModel.loadCostModel() {
        didSet { if let d = try? JSONEncoder().encode(costModel) { UserDefaults.standard.set(d, forKey: "costModel") } }
    }
    var batchQuantity = 1
    var features: PartFeatures?
    var toolpaths: [UUID: OperationToolpath] = [:]
    var programs: [ToolProgram] = []
    var isGenerating = false {
        // Done: the timeline is final, so its simulation checkpoints can be made now.
        didSet { if oldValue && !isGenerating, let start = simStart { precomputeCheckpoints(from: start) } }
    }
    /// 0…1 while generating; Cancel stops between operations.
    var generationProgress: Double?
    @ObservationIgnored var cancelGeneration = false
    /// Background generation: each operation's state per side (queued, running, ready, failed).
    var opGenState: [UUID: [Int: GenState]] = [:]
    /// Extra engine processes that generate in parallel with the main one, each with the part.
    @ObservationIgnored var workerEngines: [(engine: EngineClient, partURL: URL, partID: String)] = []
    /// Set when the job needs more travel than the CR-1 has with this stock placement.
    var travelIssue: String?
    /// Two-sided job: side B is machined after turning the stock front-to-back.
    var twoSided = false { didSet { if twoSided != oldValue { clearToolpathResults(); keepStockWorkable(); layoutScene(); noteProjectChange() } } }
    /// Set once the user picks one or two sides themselves; until then the analysis decides (two
    /// sides when the back has shape, one when it is flat).
    var twoSidedChosen = false
    /// How far generation stood the stock face out past the clamp jaws so every tool clears them
    /// (more than the setup's own value); nil until it had to.
    var autoProtrusion: Double?
    /// Set when finishing had to leave bridges to keep clamping stock (GripZones).
    var bridgeNote: String?
    /// The job step last chosen (strip, step card or tour) and the playhead it set.
    var selectedStep: (id: String, time: Double)?
    /// The guided tour is running.
    var touring = false
    /// The instruction card over the 3D view (toggle in the view options).
    var showStepCard = true
    /// What the Projects page selects when it opens ("firstCut"; automation and links).
    var projectsPick: String?
    /// The Print a Nest sheet.
    var showNestSheet = false
    /// The operation just added from the menu: its row opens, ready to set up.
    @ObservationIgnored var justAddedOperation: UUID?
    /// The tint on the stock face the next cut works on (view options; off unless you want it).
    var showCutFace = UserDefaults.standard.bool(forKey: "showCutFace") {
        didSet {
            guard showCutFace != oldValue else { return }
            if ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil { UserDefaults.standard.set(showCutFace, forKey: "showCutFace") }
            cutFaceKey = ""
            layoutCutFace()
        }
    }
    /// The red overlay on faces turned away from the spindle (what side A can't reach). Off
    /// until asked for (view options, or the Analysis section's undercut warning).
    var showUndercutOverlay = false { didSet { if showUndercutOverlay != oldValue { showUndercuts() } } }
    /// Whether that overlay is on screen now (for its legend).
    var undercutOverlayShown = false
    /// The part's work transform the analysis was made with: the overlay follows the part when
    /// it only moved, and waits for the next analysis when it turned or scaled.
    @ObservationIgnored var analysisTransform: simd_double4x4?
    /// While generating: the programs as planned (side, tool, operations), numbered as the
    /// finished ones will be, and how many operations each side has. The chapters and their
    /// steps show from these before the toolpaths exist.
    var plannedPrograms: [(index: Int, side: Int, tool: Tool, operations: [Operation])] = []
    var plannedOperationCount: [Int: Int] = [:]
    /// The planner is comparing plans (the button shows it).
    var isFindingPlans = false
    /// Pieces the simulation shows cut loose (nothing joins them to where the clamps hold).
    var loosePieces = 0
    /// Two-sided registration: where side A bores its reference holes (nil: none this job).
    var referencePlan: ReferenceBores.Plan?
    @ObservationIgnored var simSurfacesAt = Date.distantPast
    @ObservationIgnored var simSurfacesPending = false
    /// Which side A result `sideAFinal` was made from (its move count).
    @ObservationIgnored var sideAFinalKey = -1
    /// The stock is moving between clampings (overlays wait for it to land).
    var stockAnimating = false
    /// "Your stock" arriving: only the first n prep cuts are drawn (nil: all).
    var prepReveal: Int?
    var prepRevealTask: Task<Void, Never>?
    /// Numbers drawn over the 3D view (prep steps on the bar), model coordinates.
    var sceneLabels: [SceneLabel] = []
    @ObservationIgnored var measuringToolNames: [String] = []
    @ObservationIgnored var tourTask: Task<Void, Never>?
    /// The cutter's turn while playing (radians).
    @ObservationIgnored var toolSpin: Float = 0
    @ObservationIgnored var pendingPlay = false
    /// A tool change playback stopped at (ToolChange.swift): its panel shows while set.
    var toolChangeStop: ToolChangeStop?
    @ObservationIgnored var toolChangeTask: Task<Void, Never>?
    /// Tool changes confirmed where the playhead is (cleared when you move it yourself).
    @ObservationIgnored var toolChangesDone: Set<Int> = []
    /// Set while playback or a tool change moves the playhead (not you).
    @ObservationIgnored var internalSeek = false
    @ObservationIgnored var gumballDrag: GumballDrag?
    /// The stick-out the clamps are set for.
    var effectiveProtrusion: Double { max(setup.clampProtrusion, autoProtrusion ?? 0) }
    /// Which side the viewport shows.
    var viewSide = 0 {
        didSet {
            guard viewSide != oldValue, !switchingView else { return }
            transition(from: ViewKey(side: oldValue, stage: prepStage))
        }
    }
    /// Which prep stage (clamping on the squaring stop) is shown while `viewSide` is −1.
    var prepStage = 0 {
        didSet {
            guard prepStage != oldValue, !switchingView, viewSide == -1 else { return }
            transition(from: ViewKey(side: viewSide, stage: oldValue))
        }
    }
    @ObservationIgnored var switchingView = false
    /// Material left between the sides, holding the part in the frame, mm (when not using tabs).
    var webThickness = 0.3 { didSet { if webThickness != oldValue { clearToolpathResults() } } }
    /// Hold the part with tabs (it cuts free except for a few bridges) instead of a full web.
    var holdWithTabs = true { didSet { if holdWithTabs != oldValue { clearToolpathResults(); noteProjectChange() } } }
    var tabs = HoldingTabs() {
        didSet {
            // Tabs go in mirrored pairs (older projects may hold an odd count).
            if tabs.count % 2 == 1 { tabs.count += 1 }
            if tabs != oldValue { clearToolpathResults(); noteProjectChange() }
        }
    }
    /// Where the engine put the tabs (side B work frame).
    var placedTabs: [PlacedTab] = []
    /// Their Z range as generated (side B work frame): what the engine kept, even if the
    /// analysis' split has moved since.
    var placedTabZ: ClosedRange<Double>?
    /// The job's tool-change spot (ToolChange.swift), for the setup, stock and tools it was found for.
    @ObservationIgnored var toolChangeSpotCache: (key: String, spot: ToolChangeSpot)?
    /// How far the clamp kit sits left of the travel's middle (≤ 0, mm), for the setup it was
    /// found for (ToolChange.swift, `updateKitShift`).
    @ObservationIgnored var kitShiftCache: (key: String, shift: Double)?
    var kitShiftY: Double { kitShiftCache?.shift ?? 0 }
    @ObservationIgnored var sideResults: [SideResult] = [] { didSet { tunerBaselineCache = nil } }
    /// Prep on the side clamps (square, mill down) when the stock is too big for the clamp kit.
    var prepPrograms: [ToolProgram] = []
    @ObservationIgnored var prepResults: [SideResult] = [] { didSet { tunerBaselineCache = nil } }
    @ObservationIgnored var tunerBaselineCache: [(op: Operation, tool: Tool, minutes: Double, side: Int)]?
    /// The prep was planned automatically (the stock didn't fit the clamp kit).
    var prepAuto = false

    // Toolpath viewer
    var timeline = ToolpathTimeline()
    var playhead: Double = 0
    var isPlaying = false
    var playSpeed: Double = 1
    var colorMode = PathColorMode.moveType { didSet { if colorMode != oldValue { showToolpaths() } } }
    var simulate = true { didSet { if simulate != oldValue { resetSimulation(); updatePlayback() } } }
    var inspecting = false { didSet { if !inspecting { inspected = nil } } }
    var inspected: InspectedMove?
    @ObservationIgnored var entrySegmentEnd: [Int] = []
    @ObservationIgnored var heightmap: Heightmap?
    @ObservationIgnored var simIndex = 0
    /// Saved simulation states along the timeline: scrubbing back restores the nearest one
    /// instead of replaying every move from the start.
    @ObservationIgnored var simCheckpoints: [(index: Int, map: Heightmap)] = []
    @ObservationIgnored var simCatchUp: Task<Void, Never>?
    /// Simulates the whole side in the background once, saving checkpoints at every
    /// operation's start, so a click anywhere on the timeline starts close by (Playback.swift).
    @ObservationIgnored var simPrecompute: Task<Void, Never>?
    /// The fresh stock the simulation of the side on screen starts from.
    @ObservationIgnored var simStart: Heightmap?
    /// Side A as it leaves the machine (every move applied): side B's simulation starts from it,
    /// turned front-to-back, so the back shows what side A already cut.
    @ObservationIgnored var sideAFinal: Heightmap?
    /// What each timeline operation is (the edge finding first).
    @ObservationIgnored var timelineTitles: [String] = []
    @ObservationIgnored var sideAFinalTask: Task<Void, Never>?
    /// Side B's back surface (side A's result mirrored), per simulation cell, work Z.
    @ObservationIgnored var simBack: [Float]?
    @ObservationIgnored var playTimer: Timer?
    @ObservationIgnored var operationProgram: [Int] = []
    @ObservationIgnored var operationLines: [[Int?]] = []
    @ObservationIgnored var plannedTools: [Tool] = []
    @ObservationIgnored var toolMeshID: UUID?

    // Analysis
    var analysis: PartAnalysis?
    var partChangedOnDisk = false
    @ObservationIgnored var analysisTask: Task<Void, Never>?
    @ObservationIgnored var partWatcher: DispatchSourceFileSystemObject?

    // Measuring
    var measuring = false { didSet { if !measuring { clearMeasurements() } } }
    var measurePoints: [MeasurePoint] = []

    // Section
    enum SectionAxis: String, CaseIterable, Identifiable { case x, y, z; var id: Self { self } }
    var sectionOn = false { didSet { applySection() } }
    var sectionAxis = SectionAxis.y { didSet { applySection() } }
    /// Offset from the stock centre along the section axis, mm.
    var sectionOffset: Double = 0 { didSet { applySection() } }

    /// The stock currently used (resolved against the inventory by the view).
    @ObservationIgnored var stockLookup: (StockItem.ID) -> StockItem? = { _ in nil }
    @ObservationIgnored var toolLookup: (Tool.ID) -> Tool? = { _ in nil }
    /// Adds tools and stock to the inventory (a project's own copies of what it uses).
    @ObservationIgnored var addToInventory: ([Tool], [StockItem]) -> Void = { _, _ in }
    @ObservationIgnored private(set) var engine: EngineClient?
    @ObservationIgnored private(set) var machineModel: MachineModel?
    /// The clamp kit's parts (kit-local frames, see `UniversalClamp` and `fixture_kit.py`).
    @ObservationIgnored var kitParts: [FixturePart] = []
    /// Turning the stock over on screen when switching to side B.
    @ObservationIgnored var flipTask: Task<Void, Never>?
    /// Realistic (physically based) shading or the flat CAD look; remembered.
    var realistic = UserDefaults.standard.object(forKey: "realistic") as? Bool ?? true {
        didSet {
            renderer.realistic = realistic
            if ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil { UserDefaults.standard.set(realistic, forKey: "realistic") }
            applyStockDisplay()
        }
    }
    /// How the stock is drawn, and "show only the work" (hides the machine and fixtures).
    var stockDisplay = StockDisplay.realistic { didSet { applyStockDisplay() } }
    var isolateWork = false { didSet { applyMachineDisplay() } }
    /// Show the toolpaths (off: just the solid stock being cut and the tool).
    var pathsVisible = true { didSet { renderer.scene.lineSet("toolpath")?.isVisible = pathsVisible } }
    /// Colour the simulated stock by its distance from the CAD (Deviation.swift).
    var showDeviation = false { didSet { Task { await updateDeviation() } } }
    var deviationStats: DeviationStats?
    @ObservationIgnored var partHeights: (key: String, heights: [Float])?
    /// Show the mill-down setup (side clamps, raw stock) in the viewport.
    var previewMillDown = false { didSet { if previewMillDown != oldValue { layoutScene() } } }
    @ObservationIgnored var cutFaceKey = ""
    /// Where to seek once a side switch has finished (job strip clicks).
    @ObservationIgnored var pendingSeek: (() -> Void)?
    /// Nominal tool for placing the stock under the spindle in the 3D view.
    @ObservationIgnored private let nominalStickout = 25.0

    init() {
        // A write to the engine after it died must be an error, not SIGPIPE ending the app.
        signal(SIGPIPE, SIG_IGN)
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal isn't available on this Mac.") }
        do {
            renderer = try ViewportRenderer(device: device)
        } catch {
            fatalError("The 3D viewport couldn't start: \(error)")
        }
        renderer.worldToDisplay = ViewportRenderer.machineToDisplay
        renderer.camera.set(.iso)
        renderer.animationsEnabled = ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil
            || ProcessInfo.processInfo.environment["COASTLINE_ANIMATE"] != nil
        renderer.realistic = realistic
        camera = renderer.camera
        renderer.onCameraChange = { [weak self] c in
            self?.camera = c
            if self?.showingStockOnly == true { self?.layoutGumball() }  // arrows keep their size on screen
        }
        // Motion groups: the table (X) carries the work; the translator (Y) and spindle (Z, which
        // rides on Y) carry the tool.
        let onTable: Set<String> = ["part", "stock", "stock.edges", "simstock", "simstock.back", "stock.anim", "clearance", "toolpath", "workarea", "workarea.edges", "travel.trace",
                                    "undercuts", "measure", "section.plane", "section.edges", "deviation", "cutface", "cutface.edges",
                                    "prep.cut", "prep.cut.edges", "prep.next", "simstock.walls", "simstock.loose"]
        renderer.scene.groupForID = { id in
            if id.hasPrefix("machine.x.") { return "x" }
            if id.hasPrefix("machine.y.") { return "y" }
            if id.hasPrefix("machine.z.") || id == "tool" || id.hasPrefix("tool.") { return "z" }
            if id.hasPrefix("fixture.") || id.hasPrefix("tabs") { return "x" }
            return onTable.contains(id) ? "x" : nil
        }
        if let axes = SceneLines(device: device, id: "axes", segments: LineSegment.axes(length: 20)) {
            renderer.scene.setLines(axes)
        }
    }

    /// The repository root during development (Sources/Coastline/Model/AppModel.swift → 5 levels
    /// up), or the standalone app's copy of it.
    static let repoRoot: URL = {
        // A standalone app (scripts/make-app.sh --standalone) carries the repo's engine/,
        // resources/ and its own python/ in Contents/Resources/Coastline.
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Coastline"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("engine/coastline_engine").path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }()

    /// The engine, restarted if it died (a crash in a native library ends its process), with the
    /// part imported into the new one so its ID is valid again. The setup is untouched.
    func liveEngine() async throws -> EngineClient {
        if let e = engine, await e.isRunning() { return e }
        let restarted = engine != nil
        engine = nil
        let e = try connectedEngine()
        if restarted, let p = part {
            let mesh = try await e.importPart(p.url)
            part?.partID = mesh.partID
            status = "The geometry engine restarted; \(p.fileName) was loaded into it again."
        }
        return e
    }

    func connectedEngine() throws -> EngineClient {
        if let engine { return engine }
        let e = try EngineClient.development(repoRoot: Self.repoRoot)
        engine = e
        return e
    }

    /// The stock in the inventory, or the copy the project keeps once it's used up (recorded in
    /// the journal), so the job still opens and exports.
    var stock: StockItem? {
        guard let id = stockID else { return nil }
        return stockLookup(id) ?? (stockSnapshot?.id == id ? stockSnapshot : nil)
    }
    @ObservationIgnored var stockSnapshot: StockItem?

    // MARK: Machine

    /// Loads the CR-1 assembly (cached by the engine after the first run, ~6 s → 0.1 s).
    func loadMachine() async {
        guard machineModel == nil else { return }
        status = "Loading the CR-1 model…"
        do {
            let engine = try connectedEngine()
            let model = try await engine.machineModel(Self.repoRoot.appendingPathComponent("resources/machine/cr1_mechanicals_v1.3.step"))
            machineModel = model
            kitParts = (try? await engine.fixtureKit()) ?? []
            // The collision engine's machine tree (628 k triangles) is built now, in the
            // background, so the first check after a move doesn't wait for it.
            Task { _ = await machineCollisionTree() }
            for (i, p) in model.parts.enumerated() {
                guard let mesh = SceneMesh(device: renderer.device, id: "machine.\(p.group).\(p.role).\(i)",
                                           positions: p.mesh.vertices, normals: p.mesh.normals, indices: p.mesh.indices,
                                           color: SIMD4(Self.displayColor(role: p.role, p.color), 1)) else { continue }
                renderer.scene.setMesh(mesh)
            }
            machineLoaded = true
            applyMachineDisplay()
            layoutScene()
            if part == nil { renderer.frameAll() }  // the whole machine, iso
            status = part == nil ? "Ready" : status
        } catch {
            errorMessage = "Couldn't load the machine model: \(error)"
        }
    }

    private func applyMachineDisplay() {
        for m in renderer.scene.meshes where m.id.hasPrefix("machine.") {
            let parts = m.id.split(separator: ".")
            let group = parts.count > 1 ? String(parts[1]) : "static"
            let role = parts.count > 2 ? String(parts[2]) : ""
            // The shell and everything mounted only on it (its screws, the E-stop) go together.
            let shell = role.hasPrefix("enclosure")
            // Ghosted: the whole machine see-through, the enclosure shell fainter still.
            m.color.w = machineDisplay == .ghost ? (shell ? 0.12 : 0.24) : 1
            switch machineDisplay {
            case .ghost: m.isVisible = true
            case .full: m.isVisible = true
            case .open: m.isVisible = !shell
            case .moving: m.isVisible = group != "static" && !shell
            case .hidden: m.isVisible = false
            }
            if isolateWork || showingStockOnly { m.isVisible = false }  // stage 1: just the stock and the part
        }
        applyFixtureDisplay()
        applySurfaces()
        updatePivot()
    }

    /// Orbit around the centre of the mill while it's shown, otherwise around the work.
    private func updatePivot() {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        let machineShown = machineDisplay != .hidden && machineLoaded
        for m in renderer.scene.meshes where m.isVisible && (machineShown ? m.id.hasPrefix("machine.") : ["part", "stock"].contains(m.id)) {
            for i in 0..<8 {
                let c = SIMD3(i & 1 == 0 ? m.boundsMin.x : m.boundsMax.x, i & 2 == 0 ? m.boundsMin.y : m.boundsMax.y,
                              i & 4 == 0 ? m.boundsMin.z : m.boundsMax.z)
                let w = m.transform * SIMD4(c, 1)
                lo = simd_min(lo, SIMD3(w.x, w.y, w.z))
                hi = simd_max(hi, SIMD3(w.x, w.y, w.z))
            }
        }
        renderer.setPivot(world: lo.x <= hi.x ? (lo + hi) / 2 : nil)
    }

    // MARK: Layout

    /// Where the work origin (stock top-face centre) sits in model coordinates: stock standing
    /// on the table (lifted by the fixture), centred on the spindle axis in Y, with its face a
    /// nominal tool length in front of the collet nut.
    func workOrigin(stockSize: SIMD3<Double>) -> SIMD3<Double> { workToModel(stockSize: stockSize) }

    /// Where the work origin (centre of the stock face toward the spindle) sits in the model,
    /// with the table at the model's pose: in the universal clamp's throat (on its lower jaw,
    /// face proud of the jaws), centred on the Y travel.
    func workToModel(stockSize: SIMD3<Double>) -> SIMD3<Double> {
        if showingMillDown, let stage = currentPrepStage {
            let p = prepPlacement(stage)
            // As bought it just lies on the bed (nothing clamps it yet).
            let bottom = prepStage < 0 ? prepTable.topX : p.stockBottomX
            return SIMD3(bottom + stockSize.x / 2, prepCentreY(stage), p.stockFaceZ)
        }
        if setup.onBed, !showingStockOnly, let p = bedJobPlacement {
            return SIMD3(p.stockBottomX + stockSize.x / 2, bedJobCentreY, p.stockFaceZ)
        }
        guard let p = clampPlacement(stockSize: stockSize) else { return .zero }
        return SIMD3(p.stockBottomX + stockSize.x / 2, kitCentreY, p.stockFaceZ)
    }

    /// In the clamp kit (or on the bed for path B): where work X0 Y0 Z0 is in machine
    /// coordinates for a tool sticking out `stickout`, whatever is on screen.
    func kitMachineOrigin(stickout: Double) -> SIMD3<Double>? {
        guard let mm = machineModel, let stock else { return nil }
        let size = setup.stockSize(stock)
        let o: SIMD3<Double>
        if setup.onBed, let p = bedJobPlacement {
            o = SIMD3(p.stockBottomX + size.x / 2, bedJobCentreY, p.stockFaceZ)
        } else if let p = clampPlacement(stockSize: size) {
            o = SIMD3(p.stockBottomX + size.x / 2, kitCentreY, p.stockFaceZ)
        } else { return nil }
        let t = tipAtModelPose(stickout: stickout), m = mm.modelPose
        return SIMD3(m.x - t.x + o.x, m.y + o.y - t.y, m.z + o.z - t.z)
    }

    /// In the clamp kit: the work X (up) the CR-1 can reach, with 0.05 mm to spare. Moves are
    /// kept inside it (at the bar's outer edge only the frame is cut, never the part).
    var kitWorkXRange: ClosedRange<Double>? {
        guard !setup.onBed, let mm = machineModel, let stock, let p = clampPlacement(stockSize: setup.stockSize(stock)) else { return nil }
        let ox = p.stockBottomX + setup.stockSize(stock).x / 2
        let x0 = mm.modelPose.x - (mm.spindleNose.x - ox)  // machine X of work X0
        let e = machine.machineEnvelope.x
        let lo = e.lowerBound - x0 + 0.05, hi = e.upperBound - x0 - 0.05
        return lo < hi ? lo...hi : nil
    }

    /// Machining and Review show toolpaths and the simulated stock; the setup steps before
    /// them show the stock as it is going in.
    var showsMachiningResults: Bool { stage == .machining || stage == .review }

    /// Showing the mill-down setup (raw stock on the side clamps) instead of the part setup.
    var showingMillDown: Bool { (previewMillDown || viewSide == -1) && hasPrep && !showingStockOnly }
    /// The stock drawn with its shoulders (path D, once it's in the clamp kit).
    var showingShoulders: Bool { setup.shoulders != nil && !showingMillDown && !showingStockOnly }

    /// The stock as the viewport shows it: as bought on the side clamps (prep), else as clamped.
    var displayStockSize: SIMD3<Double>? {
        if showingMillDown, let stage = currentPrepStage { return stage.stock }
        if showingStockOnly, let stock { return setup.rawStockSize(stock) }  // stage 1: as bought
        return stock.map { setup.stockSize($0) }
    }

    /// The machine position the CR-1 assembly is modelled at (calibrated, machine_travel.py).
    var modelPose: SIMD3<Double>? { machineModel.map { SIMD3($0.modelPose.x, $0.modelPose.y, $0.modelPose.z) } }

    /// Model y of the spindle axis when the gantry is in the middle of its Y travel.
    var travelCentreY: Double {
        guard let mm = machineModel else { return 0 }
        let e = machine.machineEnvelope.y
        return mm.spindleNose.y + ((e.lowerBound + e.upperBound) / 2 - mm.modelPose.y)
    }

    /// Where the clamp kit's stock is centred along the table (model y): the travel's middle, or
    /// to the left of it so the tools can be changed on the right (`kitShiftY`, ToolChange.swift).
    var kitCentreY: Double { travelCentreY + kitShiftY }

    /// The universal clamps bolted across both T-slots, and the stock in them.
    func clampPlacement(stockSize: SIMD3<Double>) -> UniversalClamp.Placement? {
        guard let mm = machineModel else { return nil }
        // Path D: the clamps grip the shoulders, so it's their height that sits in the jaws;
        // the bar's bottom hangs lower by what was milled off the shoulders' bottom.
        var grip = stockSize
        if let sh = setup.shoulders { grip.x = min(sh.height, stockSize.x - sh.bottom) }
        var p = UniversalClamp.place(stock: grip, tableTopX: mm.tableTopX, frontSlotZ: mm.tSlotZ.max() ?? -13.4,
                                    centreY: kitCentreY, protrusion: effectiveProtrusion, softJaw: setup.clampSoftJaw,
                                    shifts: setup.kitClampShift,
                                    count: setup.shoulders != nil ? 2 : setup.kitClampCount)  // shoulders: one clamp per end
        if let sh = setup.shoulders { p.stockBottomX -= sh.bottom }
        return p
    }

    /// Re-places the part, stock and markers after any setup change.
    func layoutScene() {
        let scene = renderer.scene
        let millDown = showingMillDown
        let stockSize = displayStockSize ?? SIMD3(0, 0, 0)
        var origin = workToModel(stockSize: stockSize)
        // Mill-down preview: the raw stock; the part where it will be once the top is milled off.
        let partOrigin = millDown || showingStockOnly ? origin - SIMD3(stockSize.x - (stock.map { setup.stockSize($0).x } ?? stockSize.x), 0, 0) / 2 : origin
        let originT = simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(partOrigin, 1)))

        scene.mesh("part")?.isVisible = !millDown  // the prep shows the bar on its own
        if let part, let mesh = scene.mesh("part") {
            let t = originT * setupFor(side: twoSided ? viewSide : 0).partToWork(partMin: part.boundsMin, partMax: part.boundsMax)
            mesh.transform = t.float
            layoutCopies(partTransform: t, visible: !millDown)
        }
        // Prep is shown on its own (the part's paths hide); otherwise the Paths toggle decides.
        if viewSide != -1 {
            for id in ["toolpath", "simstock", "simstock.back", "simstock.walls", "simstock.loose", "tabs"] { scene.lineSet(id)?.isVisible = !millDown; scene.mesh(id)?.isVisible = !millDown }
        }
        scene.lineSet("toolpath")?.isVisible = pathsVisible && (viewSide == -1 || !millDown)
        // The bar as bought: nothing cut yet. Whatever another view left (side A's simulation
        // standing in the clamp kit, its paths, the tool, the next-cut tint) goes.
        // They're removed, not hidden (the stock display would show them again); going to a
        // step that cuts builds its own (showSide).
        if viewSide == -1 && prepStage < 0 {
            for id in ["toolpath", "simstock", "simstock.back", "simstock.walls", "simstock.loose", "tabs", "tool", "tool.shank",
                       "cutface", "cutface.edges", "clearance"] {
                scene.remove(id: id)
            }
            cutFaceKey = ""
            // No program moves the machine here: it stands as for loading the stock, the table
            // down and the spindle back (not wherever another view's toolpath left it, which
            // mapped into this clamping can be past the travel).
            let tc = machine.toolChangePose, env = machine.machineEnvelope
            setMachinePosition(SIMD3(tc.x, tc.y, env.z.upperBound))
        }
        scene.remove(id: "stock")
        scene.remove(id: "stock.edges")
        clearPrepBar()
        if let stock {
            let box = (min: SIMD3(-stockSize.x / 2, -stockSize.y / 2, -stockSize.z), max: SIMD3(stockSize.x / 2, stockSize.y / 2, 0))
            _ = stock
            let lo = SIMD3<Float>(box.min + origin), hi = SIMD3<Float>(box.max + origin)
            let c = stock.material?.linearSwatch ?? SIMD3(0.5, 0.5, 0.5)
            if millDown, let plan = flatPrepPlan, !plan.stages.isEmpty {
                // The prep on the bed: the bar as it is at this step, what it mills off, numbered.
                layoutPrepBar(plan: plan, stage: min(prepStage, plan.stages.count - 1), origin: origin, color: c)
            } else if showingShoulders {
                // Path D: the bar with its two shoulders (stepped solid).
                let tris = setup.stockTriangles(stockSize: stockSize).map { SIMD3<Float>($0 + origin) }
                var p: [Float] = [], n: [Float] = [], ix: [UInt32] = []
                for k in stride(from: 0, to: tris.count, by: 3) {
                    let nn = simd_normalize(simd_cross(tris[k + 1] - tris[k], tris[k + 2] - tris[k]))
                    for j in 0..<3 { p += [tris[k + j].x, tris[k + j].y, tris[k + j].z]; n += [nn.x, nn.y, nn.z]; ix.append(UInt32(k + j)) }
                }
                if let m = SceneMesh(device: renderer.device, id: "stock", positions: p, normals: n, indices: ix, color: SIMD4(c, 0.22)) {
                    scene.setMesh(m)
                }
                if let edges = SceneLines(device: renderer.device, id: "stock.edges",
                                          segments: shoulderEdges(stockSize: stockSize, origin: origin, color: SIMD4(200, 205, 215, 255))) {
                    scene.setLines(edges)
                }
            } else {
                if let m = SceneMesh.box(device: renderer.device, id: "stock", min: lo, max: hi, color: SIMD4(c, 0.22)) {
                    scene.setMesh(m)
                }
                if let edges = SceneLines(device: renderer.device, id: "stock.edges",
                                          segments: LineSegment.box(min: lo, max: hi, color: SIMD4(200, 205, 215, 255))) {
                    scene.setLines(edges)
                }
            }
        }
        // Stage 1: what's left after the prep, drawn inside the stock as bought (the part
        // must sit inside it).
        scene.remove(id: "stock.final")
        if showingStockOnly, let stock, setup.stockSize(stock) != stockSize {
            let f = setup.stockSize(stock)
            let lo = SIMD3<Float>(SIMD3(-stockSize.x / 2, -f.y / 2, -f.z) + origin), hi = SIMD3<Float>(SIMD3(-stockSize.x / 2 + f.x, f.y / 2, 0) + origin)
            if let l = SceneLines(device: renderer.device, id: "stock.final", segments: LineSegment.box(min: lo, max: hi, color: SIMD4(255, 196, 0, 255))) {
                l.group = "x"
                scene.setLines(l)
            }
        }
        layoutClamps(stockSize: stockSize)
        origin = partOrigin
        layoutTabs(origin: origin)
        layoutWorkArea(stockSize: stockSize, origin: origin)
        if showingStockOnly { for id in ["workarea", "workarea.edges"] { scene.mesh(id)?.isVisible = false; scene.lineSet(id)?.isVisible = false } }
        cutFaceKey = ""
        layoutCutFace()
        if (viewSide == -1 && prepStage < 0) || showingStockOnly || !showsMachiningResults {
            // The stock as bought, or a setup step (part & stock, holding, prep, clamp kit): the
            // plain stock, never a simulated (cut) one, no paths or tool. Machining and Review
            // bring the simulation back (enter → showSide).
            for id in ["toolpath", "clearance"] { scene.lineSet(id)?.isVisible = false }
            for id in ["simstock", "simstock.back", "simstock.walls", "simstock.loose", "tool", "tool.shank"] { scene.mesh(id)?.isVisible = false }
            scene.mesh("stock")?.isVisible = true
        }
        applyMachineDisplay()  // visibility rules (display mode, show-only-the-work) win over layout
        applyStockDisplay()
        applySection()
        refreshMeasureMarkers()
        showUndercuts()
        if timeline.entries.isEmpty { parkMachine() }
        updatePivot()
        layoutGumball()
        layoutGripStrips()
        layoutEngravingPreview()
    }

    /// The fixtures on the table (they move with X): the universal clamps with their spacers and
    /// parallels, or, for the mill-down setup, the acetal brick and eccentric clamps. Meshes are
    /// made once per part and instance and then only moved.
    private func layoutClamps(stockSize: SIMD3<Double>) {
        let scene = renderer.scene
        var used = Set<String>()
        // Everything placed here, for the collision check (CollisionCheck.swift).
        var bodies: [BedBody] = []
        defer { scheduleCollisionCheck(bodies, stockSize: stockSize) }
        func place(kit: String, instance: Int, transform: simd_double4x4, screwSlide: Double = 0) {
            let parts = kitPartTransforms(kit: kit, transform: transform, screwSlide: screwSlide)
            bodies.append(BedBody(name: Self.fixtureName(kit: kit, instance: instance), meshPrefix: "fixture.\(kit).\(instance).",
                                  shape: .mesh(parts)))
            for (j, t) in parts {
                let p = kitParts[j]
                let id = "fixture.\(kit).\(instance).\(j)"
                // The insulating feet and washers are clear plastic (they isolate the clamp from
                // the bed so conductive probing works).
                let clear = p.role == "insulator"
                let look = Self.kitAppearance(p)
                // Pickable: on the bed they're clicked and dragged (BedEditor).
                if scene.mesh(id) == nil, let m = SceneMesh(device: renderer.device, id: id, positions: p.mesh.vertices,
                                                            normals: p.mesh.normals, indices: p.mesh.indices, color: look.color,
                                                            pickable: kit == "brick" || kit == "cclamp" || kit == "clamp") {
                    if clear { m.material = look.material }
                    scene.setMesh(m)
                }
                guard let m = scene.mesh(id) else { continue }
                m.transform = t.float
                m.isVisible = true
                used.insert(id)
            }
        }
        func box(_ id: String, _ lo: SIMD3<Double>, _ hi: SIMD3<Double>) {
            bodies.append(BedBody(name: Self.fixtureName(box: id), meshPrefix: id, shape: .box(lo, hi)))
            scene.remove(id: id)
            if let m = SceneMesh.box(device: renderer.device, id: id, min: SIMD3<Float>(lo), max: SIMD3<Float>(hi),
                                     color: SIMD4(0.30, 0.31, 0.33, 1)) {
                scene.setMesh(m)
                used.insert(id)
            }
        }
        if stock != nil {
            // On the bed: a prep clamping, or the whole job (path B).
            let bed: (p: SideClamps.Placement, asBought: Bool)? = showingMillDown
                ? currentPrepStage.map { (prepPlacement($0), prepStage < 0) }
                : (setup.onBed && !showingStockOnly ? bedJobPlacement.map { ($0, false) } : nil)
            if let bed {
                let p = bed.p
                place(kit: "brick", instance: 0, transform: p.brick)
                if bed.asBought {  // as bought: only the squaring stop is on the table yet
                    for m in scene.meshes where m.id.hasPrefix("fixture.") && !used.contains(m.id) { m.isVisible = false }
                    applyFixtureDisplay()
                    return
                }
                box("fixture.riser", p.riserMin, p.riserMax)
                if let b = p.bridge { box("fixture.bridge", b.min, b.max) }  // the parallel across an overhanging bar
                let under = prepTable.topX - FlatPrep.tableThickness
                for (i, c) in p.clampPoints.enumerated() {
                    if kitParts.contains(where: { $0.kit == "cclamp" }) {
                        // The 3" C-clamp: fixed jaw under the table, screw down onto the bar,
                        // spine behind the table's back edge (kit x → up, y → away from the
                        // spindle, z → across).
                        // Turned about its screw (vertical) when the bar reaches past the bed.
                        let a = i < p.clampAngles.count ? p.clampAngles[i] : 0
                        place(kit: "cclamp", instance: i, transform: cClampTransform(pad: c, angle: a), screwSlide: (c.x - under) - Self.cClampPadAt)
                    } else {
                        for m in CClampMesh.meshes(device: renderer.device, id: "fixture.cclamp.\(i)", clampPoint: c,
                                                   tableUnderX: under, spineZ: prepTable.clampSpineZ) {
                            scene.setMesh(m)
                            used.insert(m.id)
                        }
                    }
                }
            } else if let k = clampKitLayout(stockSize: stockSize) {
                for (kit, i, t) in k.instances { place(kit: kit, instance: i, transform: t) }
                for b in k.boxes { box(b.id, b.lo, b.hi) }
            }
        }
        for m in scene.meshes where m.id.hasPrefix("fixture.") && !used.contains(m.id) { m.isVisible = false }
        applyFixtureDisplay()
    }

    /// The universal clamps (kit instances, kit-local → model) and the parallels (boxes) for
    /// stock of this size, as the viewport shows them and the clearance check sees them.
    func clampKitLayout(stockSize: SIMD3<Double>) -> (instances: [(String, Int, simd_double4x4)], boxes: [(id: String, lo: SIMD3<Double>, hi: SIMD3<Double>)], jawDrop: Double)? {
        guard let p = clampPlacement(stockSize: stockSize) else { return nil }
        // As modelled the jaw's underside is 56.67 mm up; bring it to the stock's top edge
        // (the shoulders', on path D).
        let top = p.seat.z + (setup.shoulders?.height ?? stockSize.x)
        let press = UniversalClamp.pressRange(softJaw: setup.clampSoftJaw)
        let drop = min(max(top, press.lowerBound), press.upperBound) - (setup.clampSoftJaw ? 56.67 : UniversalClamp.screwTipZ)
        var instances: [(String, Int, simd_double4x4)] = []
        for (i, t) in p.clamps.enumerated() { instances.append(("clamp", i, t)) }
        for (i, t) in p.spacers.enumerated() { instances.append(("spacer_u", i, t)) }
        // Parallels: behind the stock (to push its face out) and under it (between the spacer's
        // range and the jaw's).
        var boxes: [(id: String, lo: SIMD3<Double>, hi: SIMD3<Double>)] = []
        let y0 = kitCentreY - stockSize.y / 2, y1 = kitCentreY + stockSize.y / 2
        let back = p.stockFaceZ - stockSize.z
        if p.parallels > 0.05 {
            // On the lower jaw, where the bar's grip (its shoulders, on path D) sits: one block in
            // each clamp, as wide as its jaw (as in the kit's Rhino model), not a bar along the
            // stock.
            let seatX = p.stockBottomX + (setup.shoulders?.bottom ?? 0)
            let h = UniversalClamp.clampHalfWidth
            for (i, t) in p.clamps.enumerated() {
                let yc = t.columns.3.y
                let lo = max(yc - h, y0), hi = min(yc + h, y1)
                guard hi > lo + 1 else { continue }
                boxes.append(("fixture.parallel.behind.\(i)", SIMD3(seatX, lo, back - p.parallels),
                              SIMD3(seatX + min((setup.shoulders?.height ?? stockSize.x) * 0.6, 12), hi, back)))
            }
        }
        if p.seat.kind == .parallel, let mm = machineModel {
            boxes.append(("fixture.parallel.under", SIMD3(mm.tableTopX + UniversalClamp.jawTopZ, y0, back),
                          SIMD3(p.stockBottomX, y1, p.stockFaceZ - 1)))
        }
        return (instances, boxes, drop)
    }

    /// Each kit part of one instance with its transform: the soft jaw and its two M4x35 screws
    /// come down onto the stock (without the soft jaw, the screw tips do).
    func kitPartTransforms(kit: String, transform: simd_double4x4, screwSlide: Double = 0) -> [(Int, simd_double4x4)] {
        let drop = stock.flatMap { clampKitLayout(stockSize: setup.stockSize($0))?.jawDrop } ?? 0
        var out: [(Int, simd_double4x4)] = []
        for (j, p) in kitParts.enumerated() where p.kit == kit {
            if kit == "cclamp" {  // the screw, pad and handle run down to the work
                let slide = p.role == "screw" ? screwSlide : 0
                var t = transform * simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(slide, 0, 0, 1)))
                if p.name.hasSuffix("T-handle") {
                    // Turned 45° about the screw (both the same way): clamps side by side keep
                    // their handles parallel instead of crossing.
                    let a = Double.pi / 4, c = cos(a), s = sin(a)
                    t = t * simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
                }
                out.append((j, t))
                continue
            }
            if p.role == "soft_jaw" && !setup.clampSoftJaw { continue }
            let moves = kit == "clamp" && (p.role == "soft_jaw" || p.name.hasPrefix("M4x35"))
            out.append((j, moves ? transform * simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, drop, 1))) : transform))
        }
        return out
    }

    /// Where the C-clamp model's swivel pad face sits from its fixed jaw (fixture_kit.py).
    static let cClampPadAt = 62.4

    /// Fixtures follow the machine display: see-through when the machine is ghosted.
    private func applyFixtureDisplay() {
        for m in renderer.scene.meshes where m.id.hasPrefix("fixture.") {
            let clear = m.material.metallic == 0 && m.material.roughness <= 0.05  // insulators
            m.color.w = clear ? 0.35 : machineDisplay == .ghost ? 0.5 : 1
            if isolateWork || showingStockOnly { m.isVisible = false }
        }
    }

    /// The holding tabs, as orange outlines over their Z range, on the side that cuts through.
    private func layoutTabs(origin: SIMD3<Double>) {
        renderer.scene.remove(id: "tabs")
        guard (twoSided && holdWithTabs) || cutsThroughWithTabs, viewSide == tabSide, !placedTabs.isEmpty, let r = tabZ else { return }
        let bottom = r.lowerBound, top = r.upperBound
        let o = SIMD3<Float>(origin)
        var segs: [LineSegment] = []
        let c = SIMD4<UInt8>(255, 150, 40, 255)
        for t in placedTabs where t.corners.count >= 3 {
            for k in t.corners.indices {
                let a = t.corners[k], n = t.corners[(k + 1) % t.corners.count]
                for z in [bottom, top] {
                    segs.append(LineSegment(SIMD3<Float>(Float(a.x), Float(a.y), Float(z)) + o, SIMD3<Float>(Float(n.x), Float(n.y), Float(z)) + o, color: c))
                }
                segs.append(LineSegment(SIMD3<Float>(Float(a.x), Float(a.y), Float(bottom)) + o, SIMD3<Float>(Float(a.x), Float(a.y), Float(top)) + o, color: c))
            }
        }
        if let set = SceneLines(device: renderer.device, id: "tabs", segments: segs) { renderer.scene.setLines(set) }
    }

    /// Another tool came into the spindle (playback): only what its stick-out moves, the work
    /// area (the tip's reach), not the whole scene. The previews that shift the part re-lay all.
    func toolChanged() {
        guard !showingMillDown && !showingStockOnly else { layoutScene(); return }
        let size = displayStockSize ?? SIMD3(0, 0, 0)
        layoutWorkArea(stockSize: size, origin: workToModel(stockSize: size))
    }

    /// The CR-1's work area: every point the tool tip can reach, in the table's frame (drawn on
    /// the table, so it moves with it). The table moves X, the spindle Y and Z, so relative to the
    /// table the tip covers the full X, Y and Z travel from the modelled pose.
    private func layoutWorkArea(stockSize: SIMD3<Double>, origin: SIMD3<Double>) {
        let scene = renderer.scene
        scene.remove(id: "workarea")
        scene.remove(id: "workarea.edges")
        guard machineModel != nil, showWorkArea else { return }
        let (lo, hi) = reachBox()
        if let m = SceneMesh.box(device: renderer.device, id: "workarea", min: SIMD3<Float>(lo), max: SIMD3<Float>(hi),
                                 color: SIMD4(0.10, 0.55, 0.60, 0.07)) {
            scene.setMesh(m)
        }
        if let e = SceneLines(device: renderer.device, id: "workarea.edges",
                              segments: LineSegment.box(min: SIMD3<Float>(lo), max: SIMD3<Float>(hi), color: SIMD4(60, 200, 210, 254))) {
            scene.setLines(e)
        }
    }

    // MARK: Machine kinematics

    /// Tool tip at the modelled pose (model frame), for the current tool's stick-out.
    var tipAtModelPose: SIMD3<Double> { tipAtModelPose(stickout: currentStickout) }

    func tipAtModelPose(stickout: Double) -> SIMD3<Double> {
        guard let mm = machineModel else { return .zero }
        return SIMD3(mm.spindleNose.x, mm.spindleNose.y, mm.spindleNose.z - stickout)
    }

    var currentStickout: Double { currentTool?.stickout ?? nominalStickout }

    /// The reachable box of the tool tip in the table frame (model coordinates, table at the
    /// modelled pose).
    func reachBox() -> (SIMD3<Double>, SIMD3<Double>) {
        guard let mm = machineModel else { return (.zero, .zero) }
        let t = tipAtModelPose, p = mm.modelPose, e = machine.machineEnvelope
        // Table shift dx = Xm − X; the tip relative to the table moves by −dx.
        let xs = [t.x - (p.x - e.x.lowerBound), t.x - (p.x - e.x.upperBound)]
        let ys = [t.y + (e.y.lowerBound - p.y), t.y + (e.y.upperBound - p.y)]
        let zs = [t.z + (e.z.lowerBound - p.z), t.z + (e.z.upperBound - p.z)]
        return (SIMD3(xs.min()!, ys.min()!, zs.min()!), SIMD3(xs.max()!, ys.max()!, zs.max()!))
    }

    /// Machine coordinates that put the tool tip at work-frame point `p`.
    func machinePosition(forWork p: SIMD3<Double>, stickout: Double? = nil) -> SIMD3<Double>? {
        machineMapper(stickout: stickout).map { $0(p) }
    }

    /// Work → machine coordinates for one tool, worked out once (the work origin needs the
    /// whole clamp placement): use it for many points.
    func machineMapper(stickout: Double? = nil) -> ((SIMD3<Double>) -> SIMD3<Double>)? {
        guard let mm = machineModel, let stock else { return nil }
        let o = workToModel(stockSize: displayStockSize ?? setup.stockSize(stock)), t = tipAtModelPose(stickout: stickout ?? currentStickout), m = mm.modelPose
        return { p in
            let dx = t.x - (o.x + p.x), dy = o.y + p.y - t.y, dz = o.z + p.z - t.z
            return SIMD3(m.x - dx, m.y + dy, m.z + dz)
        }
    }

    /// Moves the machine's table, translator and spindle to machine coordinates.
    func setMachinePosition(_ q: SIMD3<Double>) {
        guard let mm = machineModel else { return }
        let m = mm.modelPose
        let scene = renderer.scene
        scene.groupTransforms["x"] = simd_float4x4(translation: SIMD3(Float(m.x - q.x), 0, 0))
        scene.groupTransforms["y"] = simd_float4x4(translation: SIMD3(0, Float(q.y - m.y), 0))
        scene.groupTransforms["z"] = simd_float4x4(translation: SIMD3(0, Float(q.y - m.y), Float(q.z - m.z)))
        machinePosition = q
    }

    /// Parks the tool 10 mm above the work origin (or at home if that's out of reach), with the
    /// current tool in the collet.
    func parkMachine() {
        guard machineModel != nil else { return }
        if let tool = currentTool { ensureToolMesh(tool) }
        let env = machine.machineEnvelope
        if let q = machinePosition(forWork: SIMD3(0, 0, 10)) {
            setMachinePosition(SIMD3(min(max(q.x, env.x.lowerBound), env.x.upperBound),
                                     min(max(q.y, env.y.lowerBound), env.y.upperBound),
                                     min(max(q.z, env.z.lowerBound), env.z.upperBound)))
        } else {
            setMachinePosition(SIMD3(env.x.lowerBound, env.y.upperBound, env.z.upperBound))
        }
    }

    /// Whether a machine position is inside the CR-1's travel, and by how much it isn't.
    func travelProblem(_ q: SIMD3<Double>) -> String? {
        let e = machine.machineEnvelope
        var out: [String] = []
        for (name, v, r) in [("X", q.x, e.x), ("Y", q.y, e.y), ("Z", q.z, e.z)] where !r.contains(v) {
            let over = v < r.lowerBound ? r.lowerBound - v : v - r.upperBound
            out.append("\(name) by \(Length.mm(over)) mm")
        }
        return out.isEmpty ? nil : "Beyond the CR-1's travel: " + out.joined(separator: ", ")
    }

    // MARK: Import

    func importPart(_ url: URL) async {
        isBusy = true
        status = "Importing \(url.lastPathComponent)…"
        errorMessage = nil
        defer { isBusy = false }
        do {
            let engine = try await liveEngine()
            let mesh = try await engine.importPart(url)
            // Another part: threads and engraving were for the last one's holes and faces.
            if let old = part?.url, old.standardizedFileURL != url.standardizedFileURL {
                operations.removeAll { [.thread, .engrave].contains($0.kind) }
            }
            guard let sceneMesh = SceneMesh(device: renderer.device, id: "part", positions: mesh.vertices,
                                            normals: mesh.normals, indices: mesh.indices,
                                            color: SIMD4(0.55, 0.57, 0.6, 1), pickable: true) else {
                throw EngineClient.EngineError(type: "Empty", message: "The file has no surfaces to show.")
            }
            renderer.scene.setMesh(sceneMesh)
            partMeshData = (mesh.vertices, mesh.normals, mesh.indices)
            for m in renderer.scene.meshes where m.id.hasPrefix("part.copy.") { renderer.scene.remove(id: m.id) }
            let lo = SIMD3(mesh.boundsMin.x, mesh.boundsMin.y, mesh.boundsMin.z)
            let hi = SIMD3(mesh.boundsMax.x, mesh.boundsMax.y, mesh.boundsMax.z)
            part = PartInfo(url: url, fileName: url.lastPathComponent,
                            kind: mesh.exact ? "\(url.pathExtension.uppercased()) · exact NURBS" : "\(url.pathExtension.uppercased()) · render mesh",
                            exact: mesh.exact, faceCount: mesh.faceCount, triangleCount: mesh.triangleCount,
                            size: mesh.size, boundsMin: lo, boundsMax: hi, partID: mesh.partID, warnings: mesh.warnings)
            // Suggest an orientation: thinnest dimension toward the spindle.
            var s = setup
            (s.facing, s.spin) = Setup.defaultOrientation(partMin: lo, partMax: hi)
            setup = s
            twoSidedChosen = false
            clearMeasurements()
            keepStockWorkable()
            layoutScene()
            revealWork()
            setView(.iso)
            focusWork()
            watchPartFile(url)
            scheduleAnalysis()
            status = "Imported \(url.lastPathComponent)"
            saveSession()
        } catch {
            errorMessage = "\(error)"
            status = "Import failed"
        }
    }

    /// Standard views are engineering views: always orthographic. Eased from the current view.
    func setView(_ view: OrbitCamera.StandardView) {
        perspective = false
        renderer.moveCamera { $0.orthographic = true; $0.set(view) }
    }

    /// Views along a direction (display space), e.g. a view-cube edge or corner.
    func look(from direction: SIMD3<Float>) {
        perspective = false
        renderer.moveCamera { $0.orthographic = true; $0.look(from: direction) }
    }

    /// The enclosure hides the work: once there's a part or toolpaths, show the machine
    /// see-through instead of whole.
    func revealWork() {
        // The whole machine is the default (realistic) by default; the camera looks in through
        // the front opening. Ghosting is one click away in the view bar.
    }

    /// The parts the CAD colours green (the electronics' boards and the cable cover) are black
    /// plastic on the real machine.
    static func displayColor(role: String, _ c: SIMD3<Float>) -> SIMD3<Float> {
        switch role {
        case "pcb": SIMD3(0.022, 0.022, 0.025)
        case "guard": SIMD3(0.62, 0.63, 0.65)  // polished: a bright base so the mirror reads as one
        default: c
        }
    }

    /// Frames the stock, part and clamps where the table currently is.
    func focusWork(fixtures: Bool = true) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for m in renderer.scene.meshes where (["part", "stock"].contains(m.id) || (fixtures && m.id.hasPrefix("fixture."))) && m.isVisible {
            let t = renderer.scene.groupTransform(m.group) * m.transform
            for i in 0..<8 {
                let c = SIMD3(i & 1 == 0 ? m.boundsMin.x : m.boundsMax.x, i & 2 == 0 ? m.boundsMin.y : m.boundsMax.y,
                              i & 4 == 0 ? m.boundsMin.z : m.boundsMax.z)
                let w = t * SIMD4(c, 1)
                lo = simd_min(lo, SIMD3(w.x, w.y, w.z))
                hi = simd_max(hi, SIMD3(w.x, w.y, w.z))
            }
        }
        guard lo.x < hi.x else { return }
        // Comfortable framing: the work with room around it (×1.3) and never tighter than
        // ~70 mm across, so it's never a super close-up and the clamps stay in context.
        let c = (lo + hi) / 2
        let half = simd_max((hi - lo) / 2 * 1.3, SIMD3(repeating: 35))
        renderer.frame(worldMin: c - half, worldMax: c + half, animated: true)
    }

    /// Picks a sensible default orientation for the stock (thinnest toward the spindle).
    func useStock(_ item: StockItem) {
        stockSnapshot = item
        var s = setup
        s.stockAxes = bestStockAxes(item) ?? Setup.defaultStockAxes(item)
        s.downsizeHeight = nil
        setup = s
        stockID = item.id
        focusWork()
    }

    /// The stock in use was edited in its sheet: keep how it sits if that still works, and plan
    /// again (its size, material or faces change the toolpaths and feeds).
    func stockEdited(_ item: StockItem) {
        stockSnapshot = item
        guard item.id == stockID else { return useStock(item) }
        let keep = stockOptions(item).contains { $0.axes == setup.stockAxes && $0.workable }
        clearToolpathResults()
        var s = setup
        if !keep { s.stockAxes = bestStockAxes(item) ?? Setup.defaultStockAxes(item) }
        s.downsizeHeight = nil
        if s != setup { setup = s } else { layoutScene(); saveSession(); keepStockWorkable(); autoPlanPrep(); noteProjectChange() }
        focusWork()
    }

    /// Standard sizes to buy (StockCatalog, in the inventory as not owned) that hold the part in
    /// the clamp kit as they are (no milling down), the least material first; the current
    /// stock's material family first.
    func standardStockThatFits(in inventory: Inventory, limit: Int = 3) -> [StockItem] {
        let family = stock?.material?.family
        return inventory.stock.filter { s in
            s.isSuggestion && s.id != stockID && stockOptions(s).contains { $0.workable && $0.prepHeight == nil && !$0.viaShoulders }
        }
            .sorted { a, b in
                let fa = a.material?.family == family ? 0 : 1, fb = b.material?.family == family ? 0 : 1
                return fa != fb ? fa < fb : a.volume < b.volume
            }
            .prefix(limit).map { $0 }
    }

    /// The ways the stock can sit for this part, best first (StockOrientation).
    func stockOptions(_ item: StockItem? = nil) -> [StockOrientation.Option] {
        guard let part, let stock = item ?? stock else { return [] }
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        let rough = 6.35  // the 1/4" end mill that roughs
        return StockOrientation.options(stock: stock, part: hi - lo, twoSided: twoSided, topAllowance: setup.topAllowance,
                                        softJaw: setup.clampSoftJaw, toolDiameter: rough)
    }

    func bestStockAxes(_ item: StockItem) -> [Int]? {
        stockOptions(item).first(where: \.workable)?.axes
    }

    /// Sits the stock another way (only workable ways are offered).
    func useStockAxes(_ axes: [Int]) {
        var s = setup
        s.stockAxes = axes
        s.downsizeHeight = nil
        prepAuto = false
        setup = s
    }

    /// When the part or sides change and the stock no longer fits as it sits, turn it the best
    /// workable way (the stock never ends up smaller than the part).
    func keepStockWorkable() {
        guard !setup.onBed, setup.shoulders == nil, let stock, let current = stockOptions().first(where: { $0.axes == setup.stockAxes }), !current.workable,
              let best = bestStockAxes(stock) else { return }
        useStockAxes(best)
        status = "The stock was turned so the part fits: \(stockOptions().first { $0.axes == best }?.summary ?? "")."
    }

    var setupIssues: [Issue] {
        guard let part, let stock else { return [] }
        let fixture = setup.onBed ? (bedJobPlacement?.issues ?? []) : (clampPlacement(stockSize: setup.stockSize(stock))?.issues ?? [])
        return SetupChecks.check(setup, partMin: part.boundsMin, partMax: part.boundsMax, stock: stock) + fixture + (showingMillDown ? [] : collisionIssues)
            + (batchIssue.map { [$0] } ?? [])
    }

    // MARK: Section

    private func applySection() {
        renderer.scene.remove(id: "section.plane")
        renderer.scene.remove(id: "section.edges")
        guard sectionOn else { renderer.scene.clipPlane = .zero; return }
        let stockSize = stock.map { setup.stockSize($0) } ?? SIMD3(0, 0, 0)
        let origin = workToModel(stockSize: stockSize)
        // The section plane passes through the part's centre (or the stock's, without a part),
        // plus the offset; everything on the plane's positive side is cut away.
        var centre = origin + SIMD3(0, 0, -stockSize.z / 2)
        if let part, let mesh = renderer.scene.mesh("part") {
            let c = (part.boundsMin + part.boundsMax) / 2
            let w = mesh.transform * SIMD4(Float(c.x), Float(c.y), Float(c.z), 1)
            centre = SIMD3(Double(w.x), Double(w.y), Double(w.z))
        }
        let n: SIMD3<Double> = switch sectionAxis {
        case .x: SIMD3(1, 0, 0)
        case .y: SIMD3(0, 1, 0)
        case .z: SIMD3(0, 0, 1)
        }
        let d = simd_dot(n, centre) + sectionOffset
        renderer.scene.clipPlane = SIMD4(Float(n.x), Float(n.y), Float(n.z), Float(d))
        // Draw the cut plane itself (a translucent sheet with an outline) so the section
        // doesn't float in space. It sits a hair on the kept side so it isn't clipped.
        let half = max(stockSize.x, stockSize.y, stockSize.z, 40) * 0.75
        let at = centre + n * (sectionOffset - 0.02)
        let (u, v): (SIMD3<Double>, SIMD3<Double>) = switch sectionAxis {
        case .x: (SIMD3(0, 1, 0), SIMD3(0, 0, 1))
        case .y: (SIMD3(1, 0, 0), SIMD3(0, 0, 1))
        case .z: (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        }
        let corners = [at - u * half - v * half, at + u * half - v * half, at + u * half + v * half, at - u * half + v * half].map { SIMD3<Float>($0) }
        var p: [Float] = [], nn: [Float] = []
        for c in corners { p += [c.x, c.y, c.z]; nn += [Float(-n.x), Float(-n.y), Float(-n.z)] }
        if let quad = SceneMesh(device: renderer.device, id: "section.plane", positions: p, normals: nn, indices: [0, 1, 2, 0, 2, 3],
                                color: SIMD4(0.95, 0.55, 0.20, 0.10)) {
            renderer.scene.setMesh(quad)
        }
        let edge = SIMD4<UInt8>(245, 150, 60, 255)
        let segs = (0..<4).map { LineSegment(corners[$0], corners[($0 + 1) % 4], color: edge) }
        if let lines = SceneLines(device: renderer.device, id: "section.edges", segments: segs) { renderer.scene.setLines(lines) }
    }

    // MARK: Measuring

    /// Handles a click in the viewport while measuring.
    func handleClick(at point: CGPoint, viewSize: CGSize) {
        guard measuring else { selectBedObject(at: point, viewSize: viewSize); return }
        let ray = renderer.ray(at: point, viewSize: viewSize)
        guard let hit = renderer.scene.pick(origin: ray.origin, direction: ray.direction), hit.id == "part" else {
            status = "Click on the part to measure"
            return
        }
        if measurePoints.count >= 2 { measurePoints.removeAll() }
        measurePoints.append(MeasurePoint(world: hit.world, info: nil))
        let index = measurePoints.count - 1
        refreshMeasureMarkers()
        guard let part, part.exact else { return }
        let local = hit.local
        Task {
            do {
                let engine = try await liveEngine()
                let info = try await engine.faceInfo(partID: part.partID, point: Vec3(Double(local.x), Double(local.y), Double(local.z)))
                if index < measurePoints.count { measurePoints[index].info = info }
            } catch {
                status = "Measuring failed: \(error)"
            }
        }
    }

    var measuredDistance: Double? {
        guard measurePoints.count == 2 else { return nil }
        return Double(simd_distance(measurePoints[0].world, measurePoints[1].world))
    }

    /// Distance per machine axis between the two points (work-frame axes).
    var measuredDelta: SIMD3<Double>? {
        guard measurePoints.count == 2 else { return nil }
        return SIMD3<Double>(measurePoints[1].world - measurePoints[0].world)
    }

    func clearMeasurements() {
        measurePoints.removeAll()
        refreshMeasureMarkers()
    }

    private func refreshMeasureMarkers() {
        renderer.scene.remove(id: "measure")
        guard !measurePoints.isEmpty else { return }
        var segs: [LineSegment] = []
        let s: Float = 1.5
        let colour = SIMD4<UInt8>(255, 214, 10, 255)
        for p in measurePoints {
            let w = p.world
            segs += [LineSegment(w - SIMD3(s, 0, 0), w + SIMD3(s, 0, 0), color: colour),
                     LineSegment(w - SIMD3(0, s, 0), w + SIMD3(0, s, 0), color: colour),
                     LineSegment(w - SIMD3(0, 0, s), w + SIMD3(0, 0, s), color: colour)]
        }
        if measurePoints.count == 2 {
            segs.append(LineSegment(measurePoints[0].world, measurePoints[1].world, color: colour))
        }
        if let set = SceneLines(device: renderer.device, id: "measure", segments: segs) { renderer.scene.setLines(set) }
    }

    // MARK: Session (restored on next launch)

    private struct Session: Codable {
        var partPath: String?
        var setup: Setup
        var stockID: UUID?
    }

    private static let sessionKey = "CoastlineSession"

    private func saveSession() {
        // Automation runs never touch the user's saved session.
        guard ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil else { return }
        let s = Session(partPath: part?.url.path, setup: setup, stockID: stockID)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.sessionKey) }
    }

    /// Restores the last part, stock and setup. Skipped during automation runs.
    /// The part the last session had open (for Continue on the start sheet).
    static var lastSessionPart: URL? {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let s = try? JSONDecoder().decode(Session.self, from: data), let path = s.partPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func restoreSession() async {
        guard ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil,
              let data = UserDefaults.standard.data(forKey: Self.sessionKey),
              let s = try? JSONDecoder().decode(Session.self, from: data) else { return }
        stockID = s.stockID
        if let path = s.partPath, FileManager.default.fileExists(atPath: path) {
            await importPart(URL(fileURLWithPath: path))
        }
        setup = s.setup
        // A stock that needs prep starts where the job starts: as bought, on the bed.
        if hasPrep { show(side: -1, stage: -1) }
    }

    // MARK: Viewport stress test

    func loadStressToolpath(count: Int) {
        var segments: [LineSegment] = []
        segments.reserveCapacity(count)
        let levels = 200
        let perLevel = max(count / levels, 8)
        let base = workToModel(stockSize: stock.map { setup.stockSize($0) } ?? SIMD3(40, 60, 10))
        let o = SIMD3<Float>(base)
        var previous: SIMD3<Float>?
        for level in 0..<levels {
            let z = -Float(level) * 0.05
            let r = 18 + 6 * sin(Float(level) * 0.07)
            var levelStart: SIMD3<Float>?
            for i in 0..<perLevel where segments.count < count {
                let t0 = Float(i) / Float(perLevel) * 2 * .pi
                let t1 = Float(i + 1) / Float(perLevel) * 2 * .pi
                func p(_ t: Float) -> SIMD3<Float> {
                    let c = cos(t), s = sin(t)
                    return o + SIMD3(r * copysign(pow(abs(s), 0.5), s), 1.6 * r * copysign(pow(abs(c), 0.5), c), z)
                }
                if i == 0 { levelStart = p(t0) }
                let k = UInt8(min(255, 80 + level / 2))
                segments.append(LineSegment(p(t0), p(t1), color: SIMD4(46, k, 255, 255)))
            }
            if let prev = previous, let start = levelStart, segments.count < count {
                segments.append(LineSegment(prev, start, color: PathColor.lead))
            }
            previous = segments.last.map { SIMD3($0.b.0, $0.b.1, $0.b.2) }
        }
        if let set = SceneLines(device: renderer.device, id: "toolpath", segments: segments) {
            renderer.scene.setLines(set)
            toolpathSegments = set.count
        }
    }

    /// Generated results no longer match the inputs: drop them (paths, programs, simulation).
    func clearToolpathResults() {
        pause()
        if !isGenerating { opGenState = [:] }
        programs = []
        sideResults = []
        prepPrograms = []
        prepResults = []
        autoProtrusion = nil
        bridgeNote = nil
        // The prep's views stay valid without toolpaths (the stock on the bed); only leave them
        // when there's no prep any more.
        if viewSide == -1 && !hasPrep { viewSide = 0 }
        placedTabs = []
        placedTabZ = nil
        renderer.scene.remove(id: "tabs")
        timeline = ToolpathTimeline()
        inspected = nil
        for id in ["toolpath", "tool", "tool.shank", "simstock", "simstock.back", "simstock.walls", "simstock.loose", "clearance"] { renderer.scene.remove(id: id) }
        loosePieces = 0
        sideAFinalTask?.cancel()
        sideAFinal = nil
        sideAFinalKey = -1
        renderer.scene.mesh("stock")?.isVisible = true
        heightmap = nil
        toolpathSegments = 0
    }

    func clearToolpath() {
        renderer.scene.remove(id: "toolpath")
        toolpathSegments = 0
    }
}

extension Material {
    /// The swatch in linear RGB for the Metal viewport.
    var linearSwatch: SIMD3<Float> {
        let c = NSColor(swatch).usingColorSpace(.sRGB) ?? .gray
        func lin(_ v: CGFloat) -> Float { Float(pow(Double(v), 2.2)) }
        return SIMD3(lin(c.redComponent), lin(c.greenComponent), lin(c.blueComponent))
    }
}


extension simd_double4x4 {
    /// Single precision, for the GPU.
    var float: simd_float4x4 {
        simd_float4x4(columns: (SIMD4<Float>(columns.0), SIMD4<Float>(columns.1), SIMD4<Float>(columns.2), SIMD4<Float>(columns.3)))
    }
}
