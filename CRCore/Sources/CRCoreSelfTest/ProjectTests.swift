import Foundation
@testable import CRCore

private let sampleFiles: [String: String] = [
    "manifest.yml": """
    - job_name: Clamp
      job_text: Mill a clamp
      min_fw_version: 20240318
      min_crwrite_version: 1.2.0
      disable_wcs_clear_prompt: TRUE
      wcs_value_check: G54 X-10.5 Y20 Z-3
      wcs_check_failed_message: Re-run the edge finder
      job_steps:
        - step_name: Intro
          step_markdown: |
    **Hello**
          step_image: Image/intro.png
        - manifest_file: Manifests/Sub.yml
        - step_name: Mill
          step_gcode: Code/op1.nc
          pause: t
          timeout: 30
          popup_text: Is the tool installed?
          popup_yes_step: +1
          popup_no_step: -2
          if: tool==3
    - job_name: Second
      job_text: Another job
      manifest_file: Manifests/sub.yml
    """,
    // Referenced with different upper/lower case above, as in the real Universal Clamp project.
    "Manifests/sub.yml": """
    - step_name: Sub A
      step_text: plain text
      unskippable: true
    - step_name: Sub B
      step_goto: 5
      step_gcode:  Code/sub.nc
    """,
    "Image/intro.png": "png",
    "Code/op1.nc": "G21\nG0 X1",
    "Code/sub.nc": "G0 Z1",
    "Additional Files/readme.txt": "extra",
]

let projectTests: [TestCase] = [
    TestCase(name: "parsesJobsAndSplicesSubmanifests") {
        let project = try CRProject.load(from: MemoryProjectSource(text: sampleFiles))
        try expectEqual(project.jobs.map(\.title), ["Clamp", "Second"])
        let job = project.jobs[0]
        try expectEqual(job.steps.map(\.title), ["Intro", "Sub A", "Sub B", "Mill"])
        try expectEqual(job.steps[1].manifest, "Manifests/sub.yml")
        try expectEqual(job.steps[0].manifest, "manifest.yml")
        try expect(job.usesSubmanifests)
        try expectEqual(project.jobs[1].steps.map(\.title), ["Sub A", "Sub B"])
    },

    TestCase(name: "jobFields") {
        let job = try CRProject.load(from: MemoryProjectSource(text: sampleFiles)).jobs[0]
        try expectEqual(job.prompt, "Mill a clamp")
        try expectEqual(job.minFirmwareVersion, "20240318")
        try expectEqual(job.minCRWriteVersion, "1.2.0")
        try expect(!job.allowWCSClearPrompt)
        try expectEqual(job.wcsChecks, [WCSCheck(wcs: 54, x: -10.5, y: 20, z: -3)])
        try expectEqual(job.wcsCheckFailedMessage, "Re-run the edge finder")
    },

    TestCase(name: "stepFields") {
        let steps = try CRProject.load(from: MemoryProjectSource(text: sampleFiles)).jobs[0].steps
        try expectEqual(steps[0].markdown, "\n**Hello**")
        try expectEqual(steps[0].imagePath, "Image/intro.png")
        try expect(steps[1].isUnskippable)
        try expectEqual(steps[2].gcodePath, "Code/sub.nc", "leading spaces stripped")
        try expectEqual(steps[2].goTo, "5")
        let mill = steps[3]
        try expect(mill.pause && mill.hasGCode)
        try expectEqual(mill.timeout, 30)
        try expect(mill.isUnskippable, "popup_text forces unskippable")
        try expectEqual(mill.popupText, "Is the tool installed?")
        try expectEqual(mill.popupYesStep, "+1")
        try expectEqual(mill.popupNoStep, "-2")
        try expectEqual(mill.conditionName, "tool")
        try expectEqual(mill.conditionValue, 3)
    },

    TestCase(name: "missingReferencedFileFailsVerification") {
        var files = sampleFiles
        files["Code/op1.nc"] = nil
        do {
            _ = try CRProject.load(from: MemoryProjectSource(text: files))
            throw TestFailure(description: "expected verification failure")
        } catch let error as ProjectError {
            try expectEqual(error, .notFoundInArchive("Code/op1.nc"))
        }
    },

    TestCase(name: "stepWithoutValueIsBadManifest") {
        let files = ["manifest.yml": "- job_name: A\n  job_steps:\n    - step_name: X\n      step_text:"]
        try expectThrows { _ = try CRProject.load(from: MemoryProjectSource(text: files)) }
    },

    TestCase(name: "quotedPathIsTreatedAsAbsent") {
        try expectEqual(ManifestParser.strip("\"Image/a.png\""), "")
        try expectEqual(ManifestParser.strip("  Code/a.nc  "), "Code/a.nc")
    },

    TestCase(name: "additionalContent") {
        let project = try CRProject.load(from: MemoryProjectSource(text: sampleFiles))
        try expect(project.hasAdditionalContent)
        let dir = FileManager.default.temporaryDirectory.appending(path: "crcore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try project.extractAdditionalContent(into: dir)
        try expectEqual(try String(contentsOf: dir.appending(path: "readme.txt"), encoding: .utf8), "extra")
    },

    TestCase(name: "universalClampFixture") {
        let url = repoRoot.appending(path: "reference/fixtures/universal_clamp.crproj")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Skip(reason: "fixture not present (it is git-ignored)")
        }
        let project = try CRProject.open(url: url)
        try expect(!project.jobs.isEmpty)
        let job = project.jobs[0]
        try expectEqual(job.title, "Universal Clamp Full Operation")
        try expect(job.steps.count > 100, "got \(job.steps.count) steps")
        try expectEqual(job.steps[0].title, "Welcome!")
        try expect(job.steps[0].markdown.contains("Welcome to the Coast Runner cutcode"))
        let millingSteps = job.steps.filter(\.hasGCode)
        try expect(!millingSteps.isEmpty)
        // Every G-code file loads and produces a program.
        for step in millingSteps {
            let program = GCodeProgram(source: try project.gcodeLines(for: step))
            try expect(!program.lines.isEmpty, step.gcodePath)
        }
        try expect(project.hasAdditionalContent)
        print("    Universal Clamp: \(project.jobs.count) jobs, \(job.steps.count) steps in job 1, \(millingSteps.count) milling steps")
    },
]
