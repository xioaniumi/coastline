import Foundation
import ZIPFoundation

/// Writes projects back to `.crproj`. Replaces `CRFile::Thread_WriteUserChangesToDisk`, which lost
/// data (if/step_goto/popup targets/guide files) and wrote some keys incorrectly.
///
/// Only `manifest.yml` is regenerated. Steps that came from sub-manifests are written back as the
/// same `- manifest_file:` references (sub-manifest files are left untouched), so editing is only
/// offered for jobs without sub-manifests.
public enum ProjectWriter {
    public struct UnrepresentableValue: Error, CustomStringConvertible {
        public let field: String
        public var reason = "contains a '#', which the cutcode format treats as a comment. Remove it and save again."
        public var description: String { "The \(field) \(reason)" }
    }

    /// Serialises all jobs into manifest.yml text that `ManifestParser` reads back identically.
    public static func manifest(for jobs: [Job]) throws -> String {
        var out = ""
        for (jobIndex, job) in jobs.enumerated() {
            if jobIndex > 0 { out += "\n" }
            let jobTitle = job.title.trimmingCharacters(in: .whitespaces)
            out += "- job_name: \(try scalar(jobTitle.isEmpty ? "Untitled job" : jobTitle, "job name"))\n"
            if !job.prompt.isEmpty { out += "  job_text: \(try scalar(job.prompt, "job text"))\n" }
            if !job.minFirmwareVersion.isEmpty { out += "  min_fw_version: \(job.minFirmwareVersion)\n" }
            if !job.minCRWriteVersion.isEmpty { out += "  min_crwrite_version: \(job.minCRWriteVersion)\n" }
            if !job.allowWCSClearPrompt { out += "  disable_wcs_clear_prompt: true\n" }
            for check in job.wcsChecks {
                out += "  wcs_value_check: G\(check.wcs) X\(number(check.x)) Y\(number(check.y)) Z\(number(check.z))\n"
            }
            if !job.wcsCheckFailedMessage.isEmpty {
                out += "  wcs_check_failed_message: \(try scalar(job.wcsCheckFailedMessage, "WCS check message"))\n"
            }
            if !job.guideFiles.isEmpty {
                out += "  guide_files:\n" + job.guideFiles.map { "    - \($0)\n" }.joined()
            }
            if !job.modelFiles.isEmpty {
                out += "  model_files:\n" + job.modelFiles.map { "    - \($0)\n" }.joined()
            }
            guard !job.steps.isEmpty else { continue }
            out += "  job_steps:\n"
            var lastSplice: Int?
            for step in job.steps {
                if let splice = step.spliceIndex {
                    if splice != lastSplice { out += "    - manifest_file: \(step.manifest)\n" }
                    lastSplice = splice
                    continue
                }
                lastSplice = nil
                out += try stepText(step)
            }
        }
        return out
    }

    static func stepText(_ step: Step) throws -> String {
        var lines: [String] = []
        func add(_ key: String, _ value: String, _ field: String) throws {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return } // a blank value would make the manifest unreadable
            lines.append("\(key): \(try scalar(trimmed, field))")
        }
        let title = step.title.trimmingCharacters(in: .whitespaces)
        try add("step_name", title.isEmpty ? "Untitled step" : title, "step title")
        var markdownIndex: Int?
        if !step.markdown.isEmpty {
            // Block content is written unindented, exactly like Coast Runner's own manifests.
            let body = step.markdown.hasPrefix("\n") ? step.markdown : "\n" + step.markdown
            // A line that looks like `word: …` would end the block when read back.
            if let bad = body.split(separator: "\n").first(where: { YAMLSubset.matchKeyValue(String($0)) != nil }) {
                throw UnrepresentableValue(field: "step text", reason: "has a line starting with \"\(bad.prefix(30))\", which would end the text early. Make it bold (**Note:**) or rephrase it.")
            }
            lines.append("step_markdown: |" + body)
            markdownIndex = lines.count - 1
        }
        try add("step_text", step.prompt, "step text")
        try add("step_image", step.imagePath, "image path")
        try add("step_gcode", step.gcodePath, "G-code path")
        try add("unskippable", step.popupText.isEmpty ? step.unskippable : "", "unskippable")
        try add("popup_title", step.popupTitle, "popup title")
        try add("popup_text", step.popupText, "popup text")
        if step.popupWaitTime > 0 { lines.append("popup_wait_time: \(step.popupWaitTime)") }
        try add("popup_yes_step", step.popupYesStep, "popup yes step")
        try add("popup_no_step", step.popupNoStep, "popup no step")
        try add("step_goto", step.goTo, "step goto")
        if step.pause { lines.append("pause: true") }
        if step.reset { lines.append("reset: true") }
        if step.timeout > 0 { lines.append("timeout: \(step.timeout)") }
        if let name = step.conditionName { lines.append("if: \(name)==\(step.conditionValue)") }
        // The block only ends at the next `key:` line; `pause: false` is a harmless terminator.
        if markdownIndex == lines.count - 1 { lines.append("pause: false") }

        var text = ""
        for (i, line) in lines.enumerated() {
            text += (i == 0 ? "    - " : "      ") + line + "\n"
        }
        return text
    }

    /// Single-line value: newlines become literal `\n` (the parser turns them back). `#` cannot be
    /// represented outside markdown.
    static func scalar(_ value: String, _ field: String) throws -> String {
        guard !value.contains("#") else { throw UnrepresentableValue(field: field) }
        guard value != "|" else {
            throw UnrepresentableValue(field: field, reason: "can't be just \"|\" (that starts a text block in the cutcode format).")
        }
        return value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    // MARK: - Saving

    /// Writes `jobs` and extra files (e.g. newly attached images, edited G-code) into a new copy of
    /// the archive, then atomically replaces `url`.
    public static func save(jobs: [Job], extraFiles: [String: Data], from source: any ProjectFileSource, to url: URL) throws {
        var replacements = extraFiles
        let text = try manifest(for: jobs)
        // Safety net: never replace the user's file with a manifest that doesn't read back.
        var check = [String: Data]()
        for path in source.entryPaths where path.hasSuffix(".yml") { check[path] = try source.data(at: path) }
        check[CRProject.rootManifest] = Data(text.utf8)
        do {
            _ = try ManifestParser(files: MemoryProjectSource(check)).parseRootManifest()
        } catch {
            throw UnrepresentableValue(field: "project", reason: "could not be written in a form that reads back correctly (\(error)). Nothing was changed.")
        }
        replacements[CRProject.rootManifest] = Data(text.utf8)

        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).saving")
        try? FileManager.default.removeItem(at: temp)
        let archive = try Archive(url: temp, accessMode: .create)

        var written = Set<String>()
        for path in source.entryPaths {
            let canonical = replacements.keys.first { $0.lowercased() == path.lowercased() } ?? path
            if path.hasSuffix("/") {
                try archive.addEntry(with: path, type: .directory, uncompressedSize: Int64(0), provider: { _, _ in Data() })
                continue
            }
            let data = try replacements[canonical] ?? source.data(at: path)
            try add(data, as: path, to: archive)
            written.insert(canonical)
        }
        for (path, data) in replacements where !written.contains(path) {
            try add(data, as: path, to: archive)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    /// Creates a new, empty project with one job and one step.
    public static func createNewProject(at url: URL, jobName: String = "New Job") throws {
        var job = Job(title: jobName, prompt: "Describe this job")
        job.steps = [.placeholder(manifest: CRProject.rootManifest)]
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        try add(Data(try manifest(for: [job]).utf8), as: CRProject.rootManifest, to: archive)
    }

    private static func add(_ data: Data, as path: String, to archive: Archive) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                             compressionMethod: .deflate) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }
}

/// Editing operations on a job (ports of `Job::AddOperation`, `DeleteOperation`, `MoveOperation`,
/// `Manifest::AddNewJob`, `CRFile::SetChangesToOperations`).
extension Job {
    public mutating func insertPlaceholderStep(at index: Int) {
        steps.insert(.placeholder(manifest: CRProject.rootManifest), at: min(max(0, index), steps.count))
    }

    public mutating func deleteStep(at index: Int) {
        guard steps.indices.contains(index), steps.count > 1 else { return }
        steps.remove(at: index)
    }

    /// Swaps two steps (the original moved steps one place at a time).
    public mutating func swapSteps(_ a: Int, _ b: Int) {
        guard steps.indices.contains(a), steps.indices.contains(b) else { return }
        steps.swapAt(a, b)
    }

    public static func newJob(name: String, description: String) -> Job {
        var job = Job(title: name, prompt: description)
        var step = Step.placeholder(manifest: CRProject.rootManifest)
        step.prompt = "Please download the latest version of CRWrite at coastrunner.net/downloads"
        job.steps = [step]
        return job
    }
}
