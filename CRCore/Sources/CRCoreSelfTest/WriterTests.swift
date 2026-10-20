import Foundation
@testable import CRCore

/// Compares jobs ignoring UUIDs (Job/Step equality already does) — and splice indices,
/// which renumber identically when the structure is preserved.
private func assertRoundTrip(_ jobs: [Job], files: [String: Data]) throws {
    var all = files
    all[CRProject.rootManifest] = Data(try ProjectWriter.manifest(for: jobs).utf8)
    let reparsed = try CRProject.load(from: MemoryProjectSource(all)).jobs
    try expectEqual(reparsed.count, jobs.count)
    for (a, b) in zip(reparsed, jobs) {
        try expectEqual(a, b, "job \(b.title)")
        try expectEqual(a.steps.map(\.spliceIndex), b.steps.map(\.spliceIndex), "splices of \(b.title)")
    }
}

let writerTests: [TestCase] = [
    TestCase(name: "roundTripAllFields") {
        var step = Step(manifest: CRProject.rootManifest)
        step.title = "Probe stock"
        step.markdown = "\n**Bold** text\n\n- item one\n- item # with hash is fine in markdown"
        step.prompt = "Line one\nLine two"
        step.imagePath = "Image/a.png"
        step.gcodePath = "Code/a.nc"
        step.popupTitle = "Check"
        step.popupText = "Tool installed?"
        step.unskippable = "true"
        step.popupWaitTime = 3
        step.popupYesStep = "+1"
        step.popupNoStep = "-2"
        step.goTo = "4"
        step.pause = true
        step.reset = true
        step.timeout = 20
        step.conditionName = "tool"
        step.conditionValue = 3
        var job = Job(title: "Job A", prompt: "Mill things")
        job.minFirmwareVersion = "20240318"
        job.minCRWriteVersion = "1.2.0"
        job.allowWCSClearPrompt = false
        job.wcsChecks = [WCSCheck(wcs: 59, x: 1.5, y: -2, z: 0)]
        job.wcsCheckFailedMessage = "Re-run edge finding"
        job.guideFiles = ["Additional Files/guide.pdf"]
        job.steps = [step, .placeholder(manifest: CRProject.rootManifest)]
        try assertRoundTrip([job, Job.newJob(name: "Job B", description: "Second")],
                            files: ["Image/a.png": Data(), "Code/a.nc": Data("G0".utf8)])
    },

    TestCase(name: "hashOutsideMarkdownIsRejected") {
        var job = Job.newJob(name: "Bad # name", description: "x")
        try expectThrows { _ = try ProjectWriter.manifest(for: [job]) }
        job.title = "Good"
        _ = try ProjectWriter.manifest(for: [job])
        job.steps[0].markdown = "\nIntro\nNote: this would end the block"
        try expectThrows { _ = try ProjectWriter.manifest(for: [job]) }
        job.steps[0].markdown = "\nIntro\n**Note:** fine"
        job.steps[0].prompt = ""
        // Markdown as the last field still round-trips (terminator added).
        try assertRoundTrip([job, Job.newJob(name: "Next", description: "x")], files: [:])
    },

    TestCase(name: "universalClampManifestRoundTrips") {
        let url = repoRoot.appending(path: "reference/fixtures/universal_clamp.crproj")
        guard FileManager.default.fileExists(atPath: url.path) else { throw Skip(reason: "fixture not present") }
        let source = try ZipProjectSource(url: url)
        let project = try CRProject.load(from: source)
        // Only the manifests matter for the round trip; reuse the original sub-manifests.
        var files: [String: Data] = [:]
        for path in source.entryPaths where path.hasSuffix(".yml") && path != CRProject.rootManifest {
            files[path] = try source.data(at: path)
        }
        for job in project.jobs {
            for step in job.steps {
                for path in [step.imagePath, step.gcodePath] where !path.isEmpty { files[source.resolve(path)!] = Data() }
            }
        }
        try assertRoundTrip(project.jobs, files: files)
    },

    TestCase(name: "blankAndPipeValues") {
        var job = Job.newJob(name: "J", description: "x")
        job.steps[0].title = "   "
        job.steps[0].popupTitle = "  "
        // Blank values used to produce a manifest that neither app could reopen.
        let text = try ProjectWriter.manifest(for: [job])
        let reopened = try CRProject.load(from: MemoryProjectSource(text: [CRProject.rootManifest: text]))
        try expectEqual(reopened.jobs[0].steps[0].title, "Untitled step")
        try expectEqual(reopened.jobs[0].steps[0].popupTitle, "")
        job.steps[0].popupText = "|"
        try expectThrows { _ = try ProjectWriter.manifest(for: [job]) }
    },

    TestCase(name: "saveAndReopenZip") {
        let dir = FileManager.default.temporaryDirectory.appending(path: "crwriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "New.crproj")
        try ProjectWriter.createNewProject(at: url)
        var project = try CRProject.open(url: url)
        try expectEqual(project.jobs[0].steps.count, 1)

        project.jobs[0].insertPlaceholderStep(at: 1)
        project.jobs[0].steps[1].title = "Mill"
        project.jobs[0].steps[1].gcodePath = "Code/mill.nc"
        try ProjectWriter.save(jobs: project.jobs, extraFiles: ["Code/mill.nc": Data("G21\nG0 X-1\n".utf8)],
                               from: project.files, to: url)
        let reopened = try CRProject.open(url: url)
        try expectEqual(reopened.jobs[0].steps.map(\.title), ["Step Name", "Mill"])
        try expectEqual(try reopened.gcodeLines(for: reopened.jobs[0].steps[1]), ["G21", "G0 X-1"])
    },

    TestCase(name: "jobEditing") {
        var job = Job.newJob(name: "J", description: "")
        job.insertPlaceholderStep(at: 1)
        job.steps[1].title = "Second"
        job.swapSteps(0, 1)
        try expectEqual(job.steps[0].title, "Second")
        job.deleteStep(at: 0)
        try expectEqual(job.steps.count, 1)
        job.deleteStep(at: 0)
        try expectEqual(job.steps.count, 1, "the last step can't be deleted")
    },
]
