import Foundation
@testable import CRCore

private func parse(_ text: String) throws -> [YAMLNode] {
    try YAMLSubset.parse(Data(text.utf8))
}

let yamlTests: [TestCase] = [
    TestCase(name: "keyValueMatcher") {
        try expectEqual(YAMLSubset.matchKeyValue("  step_name: Hello  "),
                        .init(indent: 2, key: "step_name", value: "Hello  "))
        try expectEqual(YAMLSubset.matchKeyValue("job_steps:"), .init(indent: 0, key: "job_steps", value: ""))
        try expectEqual(YAMLSubset.matchKeyValue("key:   "), .init(indent: 0, key: "key", value: ""))
        try expect(YAMLSubset.matchKeyValue("key:value") == nil, "no space after colon is not a key line")
        try expect(YAMLSubset.matchKeyValue("- step_name: x") == nil, "list lines are not key lines")
        try expect(YAMLSubset.matchKeyValue("Some text") == nil)
        try expectEqual(YAMLSubset.matchKeyValue("Note: markdown text")?.key, "Note")
    },

    TestCase(name: "listMatcher") {
        try expectEqual(YAMLSubset.matchListItem("    - manifest_file: a.yml"), "manifest_file: a.yml")
        try expectEqual(YAMLSubset.matchListItem("-   x"), "x")
        try expect(YAMLSubset.matchListItem("-x") == nil)
        try expect(YAMLSubset.matchListItem("-") == nil)
    },

    TestCase(name: "simpleJobList") {
        let docs = try parse("""
        - job_name: Clamp
          job_text: Mill a clamp
          job_steps:
            - step_name: One
              step_gcode: Code/a.nc
            - manifest_file: Manifests/intro.yml
        """)
        try expectEqual(docs.count, 1)
        let job = docs[0].children[0]
        try expectEqual(job.kind, .listItem)
        try expectEqual(job.children.map(\.value), ["job_name", "job_text", "job_steps"])
        try expectEqual(job.children[0].scalar, "Clamp")
        let steps = job.children[2].children
        try expectEqual(steps.count, 2)
        try expectEqual(steps[0].children.map(\.value), ["step_name", "step_gcode"])
        try expectEqual(steps[1].children[0].scalar, "Manifests/intro.yml")
    },

    TestCase(name: "unindentedMarkdownBlock") {
        // Real Coast Runner style: block content is not indented and ends at the next `key:` line.
        let docs = try parse("""
        - step_name: Welcome!
          step_markdown: |
        Welcome to the cutcode. # not a comment in markdown

        - Read each step carefully.
        - Keep the chip cover on.
          step_image: Image/Caution.jpg
        """)
        let step = docs[0].children[0]
        try expectEqual(step.children.map(\.value), ["step_name", "step_markdown", "step_image"])
        try expectEqual(step.children[1].scalar,
                        "\nWelcome to the cutcode. # not a comment in markdown\n\n- Read each step carefully.\n- Keep the chip cover on.")
        try expectEqual(step.children[2].scalar, "Image/Caution.jpg")
    },

    TestCase(name: "markdownBlockSwallowsFollowingListItem") {
        // A block is only ended by a `key:` line, so a following `- step_name:` line becomes part
        // of the markdown. This is how the original behaves; authors put another key after blocks.
        let docs = try parse("""
        - step_name: A
          step_markdown: |
        Text
        - step_name: B
        """)
        try expectEqual(docs[0].children.count, 1)
        try expectEqual(docs[0].children[0].children[1].scalar, "\nText\n- step_name: B")
    },

    TestCase(name: "commentsStrippedOutsideMarkdown") {
        let docs = try parse("""
        # header comment
        - step_name: Probe # trailing
          step_text: |
        line one # cut here
        line two
          step_gcode: Code/a.nc
        """)
        let step = docs[0].children[0]
        try expectEqual(step.children[0].scalar, "Probe ")
        // Non-markdown blocks are folded first, so the `#` truncates the rest of the whole block.
        try expectEqual(step.children[1].scalar, "\nline one ")
    },

    TestCase(name: "literalBackslashN") {
        let docs = try parse("- step_text: first\\nsecond")
        try expectEqual(docs[0].children[0].children[0].scalar, "first\nsecond")
    },

    TestCase(name: "threeCharacterLinesAreSkipped") {
        // `^...` in the original regex is unescaped, so any 3-character line counts as an
        // end-of-document marker and is skipped.
        let docs = try parse("""
        - step_name: A
        abc
        - step_name: B
        """)
        try expectEqual(docs[0].children.count, 2)
    },

    TestCase(name: "documentMarkers") {
        let docs = try parse("""
        ---
        - step_name: A
        """)
        try expectEqual(docs.count, 1)
        try expectEqual(docs[0].children.count, 1)
    },

    TestCase(name: "parseErrors") {
        try expectThrows { _ = try parse("- step_name: A\n  plain text line") }
        // Mixing keys and list items at the same level is a type mismatch.
        do {
            _ = try parse("- a: 1\nkey: value")
            throw TestFailure(description: "expected type mismatch")
        } catch let error as YAMLParseError {
            try expectEqual(error, YAMLParseError(kind: .typeMismatch, line: 2))
        }
    },

    TestCase(name: "byteSemanticsLikeStdRegex") {
        // "•" is three UTF-8 bytes: the original's `^...` EOF quirk skips it.
        let docs = try parse("- step_name: A\n•\n- step_name: B")
        try expectEqual(docs[0].children.count, 2)
        // A non-breaking space is not `\s` in the C locale, so "-\u{A0}x" is not a list item.
        try expect(YAMLSubset.matchListItem("- \u{A0}x") == "\u{A0}x")
        try expect(!YAMLSubset.isComment("\u{A0}"))
    },

    TestCase(name: "crlfLines") {
        let docs = try YAMLSubset.parse(Data("- step_name: A\r\n  step_text: B\r\n".utf8))
        try expectEqual(docs[0].children[0].children.map { $0.scalar ?? "" }, ["A", "B"])
    },
]
