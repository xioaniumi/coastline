import Foundation

/// One step ("operation") of a guided job. Port of `Operation` (`src/Files/operation.cpp`).
public struct Step: Equatable, Sendable, Identifiable {
    public var id = UUID()
    /// The manifest file this step came from (`manifest.yml` or a sub-manifest path).
    public var manifest: String
    /// Which `manifest_file:` reference spliced this step in (nil for steps written inline).
    /// Lets the writer reproduce the references exactly, even for back-to-back reuse.
    public var spliceIndex: Int?
    public var title = ""
    /// `step_text`: plain text shown when there is no markdown.
    public var prompt = ""
    /// `step_markdown`.
    public var markdown = ""
    /// `step_image`: entry path of the image, empty when none.
    public var imagePath = ""
    /// `step_gcode`: entry path of the G-code file, empty when none.
    public var gcodePath = ""
    public var pause = false
    public var reset = false
    public var timeout: UInt = 0
    /// `unskippable` (raw string; the original compares it to `"true"`). Set to "true" by `popup_text`.
    public var unskippable = ""
    public var popupText = ""
    public var popupTitle = ""
    public var popupWaitTime = 0
    /// `popup_yes_step` / `popup_no_step` / `step_goto`: absolute index or relative `+n`/`-n`.
    public var popupYesStep = ""
    public var popupNoStep = ""
    public var goTo = ""
    /// `if: name==N` — parsed but unused by the original app; kept for round-tripping.
    public var conditionName: String?
    public var conditionValue = 0

    public init(manifest: String) {
        self.manifest = manifest
    }

    /// A blank step as created by the editor (`Operation(const std::string manifest)`).
    public static func placeholder(manifest: String) -> Step {
        var step = Step(manifest: manifest)
        step.title = "Step Name"
        step.markdown = "\nStep Text"
        step.prompt = "Please download the latest version of CRWrite at coastrunner.net/downloads"
        return step
    }

    public var hasGCode: Bool { !gcodePath.isEmpty }
    public var isUnskippable: Bool { unskippable == "true" }
    public var hasPopup: Bool { !popupText.isEmpty }

    public static func == (lhs: Step, rhs: Step) -> Bool {
        lhs.manifest == rhs.manifest && lhs.title == rhs.title && lhs.prompt == rhs.prompt
            && lhs.markdown == rhs.markdown && lhs.imagePath == rhs.imagePath && lhs.gcodePath == rhs.gcodePath
            && lhs.pause == rhs.pause && lhs.reset == rhs.reset && lhs.timeout == rhs.timeout
            && lhs.unskippable == rhs.unskippable && lhs.popupText == rhs.popupText
            && lhs.popupTitle == rhs.popupTitle && lhs.popupWaitTime == rhs.popupWaitTime
            && lhs.popupYesStep == rhs.popupYesStep && lhs.popupNoStep == rhs.popupNoStep
            && lhs.goTo == rhs.goTo && lhs.conditionName == rhs.conditionName
            && lhs.conditionValue == rhs.conditionValue
    }
}

/// A work-coordinate check from `wcs_value_check: G54 X.. Y.. Z..`.
public struct WCSCheck: Equatable, Sendable {
    /// 54...59, or -1 when missing.
    public var wcs: Int
    public var x: Double
    public var y: Double
    public var z: Double
}

/// A guided job. Port of `Job` (`src/Files/job.cpp`).
public struct Job: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var title = ""
    public var prompt = ""
    public var steps: [Step] = []
    public var guideFiles: [String] = []
    public var modelFiles: [String] = []
    /// `min_fw_version`, a YYYYMMDD date string.
    public var minFirmwareVersion = ""
    /// `min_crwrite_version`, dotted.
    public var minCRWriteVersion = ""
    public var allowWCSClearPrompt = true
    public var wcsChecks: [WCSCheck] = []
    public var wcsCheckFailedMessage = ""

    public init(title: String = "", prompt: String = "") {
        self.title = title
        self.prompt = prompt
    }

    /// True when any step comes from a sub-manifest (the original disables editing then).
    public var usesSubmanifests: Bool { steps.contains { $0.manifest != CRProject.rootManifest } }

    public static func == (lhs: Job, rhs: Job) -> Bool {
        lhs.title == rhs.title && lhs.prompt == rhs.prompt && lhs.steps == rhs.steps
            && lhs.guideFiles == rhs.guideFiles && lhs.modelFiles == rhs.modelFiles
            && lhs.minFirmwareVersion == rhs.minFirmwareVersion && lhs.minCRWriteVersion == rhs.minCRWriteVersion
            && lhs.allowWCSClearPrompt == rhs.allowWCSClearPrompt && lhs.wcsChecks == rhs.wcsChecks
            && lhs.wcsCheckFailedMessage == rhs.wcsCheckFailedMessage
    }
}

/// A loaded `.crproj` project: a zip with `manifest.yml` plus code, images and sub-manifests.
public struct CRProject: Sendable {
    public static let rootManifest = "manifest.yml"
    public static let additionalFilesFolder = "Additional Files/"

    public var jobs: [Job]
    public let files: any ProjectFileSource

    public init(jobs: [Job], files: any ProjectFileSource) {
        self.jobs = jobs
        self.files = files
    }

    /// Opens and validates a `.crproj` file (`CRFile(path)` → `Manifest::LoadManifest`).
    public static func open(url: URL) throws -> CRProject {
        try load(from: ZipProjectSource(url: url))
    }

    public static func load(from files: any ProjectFileSource) throws -> CRProject {
        let jobs = try ManifestParser(files: files).parseRootManifest()
        let project = CRProject(jobs: jobs, files: files)
        try project.verify()
        return project
    }

    /// Every referenced image and G-code file must exist (`Operation::Verify`).
    public func verify() throws {
        for job in jobs {
            for step in job.steps {
                if !step.gcodePath.isEmpty, !files.contains(step.gcodePath) {
                    throw ProjectError.notFoundInArchive(step.gcodePath)
                }
                if !step.imagePath.isEmpty, !files.contains(step.imagePath) {
                    throw ProjectError.notFoundInArchive(step.imagePath)
                }
            }
        }
    }

    public var hasAdditionalContent: Bool {
        files.entryPaths.contains { $0.hasPrefix(Self.additionalFilesFolder) && !$0.hasSuffix("/") }
    }

    /// Extracts the `Additional Files/` folder into `directory` (`ExtractAdditionalContentsInto`).
    public func extractAdditionalContent(into directory: URL) throws {
        let fm = FileManager.default
        for path in files.entryPaths where path.hasPrefix(Self.additionalFilesFolder) {
            let relative = String(path.dropFirst(Self.additionalFilesFolder.count))
            guard !relative.isEmpty else { continue }
            let destination = directory.appending(path: relative)
            if path.hasSuffix("/") {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.data(at: path).write(to: destination)
            }
        }
    }

    /// Loads a step's G-code as lines (`Operation::Load`).
    public func gcodeLines(for step: Step) throws -> [String] {
        try files.lines(at: step.gcodePath)
    }

    public func imageData(for step: Step) throws -> Data {
        try files.data(at: step.imagePath)
    }
}

/// Turns manifest YAML into jobs and steps, splicing in sub-manifests.
final class ManifestParser {
    let files: any ProjectFileSource
    private var spliceCounter = 0

    init(files: any ProjectFileSource) {
        self.files = files
    }

    func parseRootManifest() throws -> [Job] {
        let documents = try parseYAML(at: CRProject.rootManifest)
        guard let root = documents.first else { throw ProjectError.badManifest("empty manifest") }
        return try root.children.map(parseJob)
    }

    private func parseYAML(at path: String) throws -> [YAMLNode] {
        let lines = try files.lines(at: path)
        do {
            return try YAMLSubset.parse(lines: lines)
        } catch let error as YAMLParseError {
            throw ProjectError.yaml(error, file: path)
        }
    }

    // MARK: Jobs

    func parseJob(_ node: YAMLNode) throws -> Job {
        guard node.kind == .listItem else {
            throw ProjectError.badManifest("not a list of jobs | line \(node.line)")
        }
        guard let first = node.children.first else {
            throw ProjectError.badManifest("job list entry is empty | line \(node.line)")
        }
        guard first.kind == .keyValue else {
            throw ProjectError.badManifest("job values must be type array | line \(node.line)")
        }

        var job = Job()
        for entry in node.children {
            guard let value = entry.children.first?.value else { continue }
            switch entry.value {
            case "job_name": job.title = value
            case "job_text": job.prompt = value
            case "job_steps": job.steps += try parseSteps(entry)
            case "manifest_file": job.steps += try spliceSubmanifest(at: value)
            case "guide_files": job.guideFiles = listValues(entry)
            case "model_files": job.modelFiles = listValues(entry)
            case "min_fw_version": job.minFirmwareVersion = value
            case "min_crwrite_version": job.minCRWriteVersion = value
            case "disable_wcs_clear_prompt":
                if value.lowercased() == "true" { job.allowWCSClearPrompt = false }
            case "wcs_value_check": job.wcsChecks.append(Self.parseWCSCheck(value))
            case "wcs_check_failed_message": job.wcsCheckFailedMessage = value
            default: break
            }
        }
        return job
    }

    /// `job_steps:` — each item is either a step or `- manifest_file: sub.yml`.
    private func parseSteps(_ node: YAMLNode) throws -> [Step] {
        var steps: [Step] = []
        for item in node.children {
            guard let first = item.children.first else {
                throw ProjectError.badManifest("operation is empty | line \(item.line)")
            }
            if first.value == "manifest_file", let path = first.scalar {
                steps += try spliceSubmanifest(at: path)
            } else {
                steps.append(try parseStep(item, manifest: CRProject.rootManifest))
            }
        }
        return steps
    }

    /// A sub-manifest is a top-level list of steps (`Job::SpliceInSubYMAL`). Not recursive.
    private func spliceSubmanifest(at path: String) throws -> [Step] {
        let documents = try parseYAML(at: path)
        guard let root = documents.first else { return [] }
        let manifest = files.resolve(path) ?? path
        spliceCounter += 1
        let splice = spliceCounter
        return try root.children.map { node in
            var step = try parseStep(node, manifest: manifest)
            step.spliceIndex = splice
            return step
        }
    }

    private func listValues(_ node: YAMLNode) -> [String] {
        node.children.compactMap { item in
            guard item.kind == .listItem, let last = item.children.last else { return nil }
            return Self.strip(last.value)
        }
    }

    // MARK: Steps

    func parseStep(_ node: YAMLNode, manifest: String) throws -> Step {
        guard node.kind == .listItem else {
            throw ProjectError.badManifest("not a list of operations | line \(node.line)")
        }
        guard let first = node.children.first else {
            throw ProjectError.badManifest("operation is empty | line \(node.line)")
        }
        guard first.kind == .keyValue else {
            throw ProjectError.badManifest("operation children must be type array | line \(node.line)")
        }

        var step = Step(manifest: manifest)
        for entry in node.children {
            guard let child = entry.children.first else {
                throw ProjectError.badManifest("operation child has no value | line \(entry.line)")
            }
            guard child.kind == .string else {
                throw ProjectError.badManifest("operation values must be type string | line \(child.line)")
            }
            let value = child.value
            switch entry.value {
            case "pause": if Self.isTrue(value) { step.pause = true }
            case "reset": if Self.isTrue(value) { step.reset = true }
            case "timeout":
                guard let timeout = Self.leadingInteger(value) else {
                    throw ProjectError.badManifest("invalid timeout | line \(child.line)")
                }
                step.timeout = UInt(truncatingIfNeeded: timeout) // stoul wraps negatives
            case "step_name": step.title = value
            case "step_text": step.prompt = value
            case "step_markdown": step.markdown = value
            case "step_image": step.imagePath = Self.strip(value)
            case "step_gcode": step.gcodePath = Self.strip(value)
            case "if":
                step.conditionName = nil
                if let range = value.range(of: "==") {
                    step.conditionName = String(value[..<range.lowerBound])
                    step.conditionValue = Self.leadingInteger(String(value[range.upperBound...])) ?? 0
                }
            case "unskippable": step.unskippable = value
            case "popup_text":
                step.unskippable = "true"
                step.popupText = value
            case "popup_title": step.popupTitle = value
            case "popup_wait_time":
                guard let wait = Self.leadingInteger(value) else {
                    throw ProjectError.badManifest("invalid popup_wait_time | line \(child.line)")
                }
                step.popupWaitTime = wait
            case "popup_yes_step": step.popupYesStep = value
            case "popup_no_step": step.popupNoStep = value
            case "step_goto": step.goTo = value
            default: break
            }
        }
        return step
    }

    // MARK: Helpers matching the C++ semantics

    /// `^t(rue)?$`, case-insensitive.
    static func isTrue(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower == "t" || lower == "true"
    }

    /// `^\s*(.*\w)\s*$` → group 1, or "" when the value does not end in a word character
    /// (e.g. a quoted path). Matches the original, which then treats the path as absent.
    static func strip(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var start = 0
        while start < scalars.count, YAMLSubset.isSpace(scalars[start]) { start += 1 }
        var end = scalars.count
        while end > start, YAMLSubset.isSpace(scalars[end - 1]) { end -= 1 }
        guard end > start, YAMLSubset.isWordChar(scalars[end - 1]) else { return "" }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    /// Like `std::stoi`/`atoi`: optional leading whitespace and sign, then digits.
    static func leadingInteger(_ s: String) -> Int? {
        let trimmed = s.drop(while: { $0.isWhitespace })
        var digits = ""
        for (offset, c) in trimmed.enumerated() {
            if c.isASCII, c.isNumber { digits.append(c) }
            else if offset == 0, c == "-" || c == "+" { digits.append(c) }
            else { break }
        }
        return Int(digits)
    }

    /// Like `stof`/`strtod`: the longest numeric prefix after optional whitespace ("1.5," → 1.5).
    static func leadingDouble(_ s: String) -> Double? {
        var text = Substring(s.drop(while: { $0.isWhitespace }))
        while !text.isEmpty {
            if let value = Double(text) { return value }
            text = text.dropLast()
        }
        return nil
    }

    /// `wcs_value_check: G54 X1.0 Y2 Z-3` — chunk on letters, read G/X/Y/Z values.
    static func parseWCSCheck(_ s: String) -> WCSCheck {
        var chunks: [String] = []
        var current = ""
        for c in s {
            if !current.isEmpty, c.isASCII, c.isLetter {
                chunks.append(current)
                current = ""
            }
            current.append(c)
        }
        chunks.append(current)

        var check = WCSCheck(wcs: -1, x: 0, y: 0, z: 0)
        for chunk in chunks {
            guard let letter = chunk.first else { continue }
            let number = leadingDouble(String(chunk.dropFirst()))
            switch letter {
            case "G": if let number { check.wcs = Int(number) }
            case "X": if let number { check.x = number }
            case "Y": if let number { check.y = number }
            case "Z": if let number { check.z = number }
            default: break
            }
        }
        return check
    }
}
