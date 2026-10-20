import Foundation

/// A node in the tree produced by `YAMLSubset.parse`.
///
/// This mirrors `YAMLObject` from the original CRWrite (`src/Files/yaml.cpp`): a home-made,
/// line/indent based subset of YAML. It is *not* real YAML — Coast Runner manifests rely on its
/// quirks (e.g. un-indented `key: |` blocks that run until the next `key:` line), so a standard
/// YAML library would reject or misread them.
public struct YAMLNode: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A document (`TYPEFIL`).
        case file
        /// A `key: value` entry (`TYPERRY` — the original calls these "arrays").
        case keyValue
        /// A `- item` entry (`TYPELST`).
        case listItem
        /// A scalar string (`TYPESTR`).
        case string
    }

    public var kind: Kind
    /// The key for `.keyValue`, the text for `.string`, empty otherwise.
    public var value: String
    /// 1-based source line.
    public var line: Int
    public var children: [YAMLNode]

    init(_ kind: Kind, _ value: String, lineIndex: Int, children: [YAMLNode] = []) {
        self.kind = kind
        self.value = value
        self.line = lineIndex + 1
        self.children = children
    }

    /// The scalar value of a `key: value` node (its first child), if any.
    public var scalar: String? { children.first?.value }
}

public struct YAMLParseError: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Kind: Sendable { case parse, typeMismatch }
    public var kind: Kind
    /// 1-based line number.
    public var line: Int

    public var description: String {
        switch kind {
        case .parse: "YAML parse error: line \(line)"
        case .typeMismatch: "YAML parse error: type mismatch line \(line)"
        }
    }
}

/// Port of CRWrite's `YAMLObject::parseFile`. The control flow intentionally follows the C++
/// line for line so that manifests behave exactly as they did in the original app.
public enum YAMLSubset {

    /// Splits raw file bytes into lines the way `Archive::ReadFile` did: split on `\n`, drop `\r`.
    public static func lines(from data: Data) -> [String] {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        var result = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        // The original only emits a trailing line if it is non-empty.
        if let last = result.last, last.isEmpty { result.removeLast() }
        return result
    }

    public static func parse(_ data: Data) throws -> [YAMLNode] {
        try parse(lines: lines(from: data))
    }

    public static func parse(lines input: [String]) throws -> [YAMLNode] {
        var documents = [YAMLNode(.file, "", lineIndex: 0)]

        // Pass 1: fold `key: |` blocks into a single line joined with <NEWLINE>. A block runs until
        // the next line that looks like `key:` (at any indent) — list lines like `- step_name:` do
        // NOT end a block, exactly as in the original.
        var combined: [String] = []
        var multiline = false
        for line in input {
            let keyLine = matchKeyValue(line)
            if multiline {
                if keyLine != nil {
                    multiline = false
                } else {
                    combined[combined.count - 1] += "<NEWLINE>" + line
                    continue
                }
            }
            if let keyLine, keyLine.value == "|" {
                multiline = true
                combined.append(String(repeating: " ", count: keyLine.indent) + keyLine.key + ": ")
            } else {
                combined.append(line)
            }
        }

        // Pass 2: strip `#` comments, except on `step_markdown` lines.
        let lines: [String] = combined.map { line in
            if let keyLine = matchKeyValue(line), keyLine.key == "step_markdown" { return line }
            if let hash = line.firstIndex(of: "#") { return String(line[..<hash]) }
            return line
        }

        var parseState = 0
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isComment(line) { i += 1; continue }
            if isBeginningOfDocument(line) {
                if parseState > 0 { documents.append(YAMLNode(.file, "", lineIndex: i)) }
                parseState = 1
                i += 1
                continue
            }
            if parseState == 2 { throw YAMLParseError(kind: .parse, line: i + 1) }
            if isEndOfDocument(line) {
                parseState = 2
                i += 1
                continue
            }
            try parseBlock(lines, &i, into: &documents[documents.count - 1], parentIndent: -1)
            i += 1
        }
        return documents
    }

    // MARK: - Recursive descent (port of YAMLObject::parse)

    private static func parseBlock(_ lines: [String], _ i: inout Int, into parent: inout YAMLNode, parentIndent: Int) throws {
        var kind: YAMLNode.Kind = .file // "TYPEOBJ": not decided yet
        while i < lines.count {
            let line = lines[i]
            if isComment(line) { i += 1; continue }
            if isBeginningOfDocument(line) { break }
            if isEndOfDocument(line) { break }

            let indent = leadingSpaces(line)
            if indent <= parentIndent { break }

            if matchKeyValue(line) != nil {
                if kind == .file { kind = .keyValue }
                if kind != .keyValue { throw YAMLParseError(kind: .typeMismatch, line: i + 1) }
                var child = try keyValueNode(line, lineIndex: i)
                i += 1
                try parseBlock(lines, &i, into: &child, parentIndent: indent)
                parent.children.append(child)
                i -= 1
            } else if let item = matchListItem(line) {
                if kind == .file { kind = .listItem }
                if kind != .listItem { throw YAMLParseError(kind: .typeMismatch, line: i + 1) }
                var child = YAMLNode(.listItem, "", lineIndex: i)
                if !item.isEmpty {
                    if matchKeyValue(item) != nil {
                        child.children.append(try keyValueNode(item, lineIndex: i))
                    } else if !isComment(item) {
                        child.children.append(stringNode(item, lineIndex: i))
                    }
                }
                i += 1
                try parseBlock(lines, &i, into: &child, parentIndent: indent)
                parent.children.append(child)
                i -= 1
            } else {
                throw YAMLParseError(kind: .parse, line: i + 1)
            }
            i += 1
        }
    }

    private static func keyValueNode(_ line: String, lineIndex: Int) throws -> YAMLNode {
        guard let match = matchKeyValue(line) else { throw YAMLParseError(kind: .parse, line: lineIndex + 1) }
        var node = YAMLNode(.keyValue, match.key, lineIndex: lineIndex)
        if !match.value.isEmpty, !isComment(match.value) {
            node.children.append(stringNode(match.value, lineIndex: lineIndex))
        }
        return node
    }

    private static func stringNode(_ s: String, lineIndex: Int) -> YAMLNode {
        let text = s.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "<NEWLINE>", with: "\n")
        return YAMLNode(.string, text, lineIndex: lineIndex)
    }

    // MARK: - Line classifiers (hand-written equivalents of the C++ std::regex patterns)

    struct KeyValueMatch: Equatable {
        var indent: Int
        var key: String
        var value: String
    }

    /// `^( *)(\w+):(\s+(.*))?\s*$` — returns indent, key, and group 4 (value with leading
    /// whitespace removed, trailing whitespace kept).
    static func matchKeyValue(_ line: String) -> KeyValueMatch? {
        let chars = Array(line.unicodeScalars)
        var p = 0
        while p < chars.count, chars[p] == " " { p += 1 }
        let indent = p
        let keyStart = p
        while p < chars.count, isWordChar(chars[p]) { p += 1 }
        guard p > keyStart, p < chars.count, chars[p] == ":" else { return nil }
        let key = String(String.UnicodeScalarView(chars[keyStart..<p]))
        p += 1
        if p == chars.count { return KeyValueMatch(indent: indent, key: key, value: "") }
        // Optional group needs at least one whitespace char after the colon.
        guard isSpace(chars[p]) else { return nil }
        while p < chars.count, isSpace(chars[p]) { p += 1 }
        let value = String(String.UnicodeScalarView(chars[p...]))
        // `.` does not match line terminators; lines never contain them here.
        return KeyValueMatch(indent: indent, key: key, value: value)
    }

    /// `^( *)- \s*(.*)\s*$` — returns the item text with leading whitespace removed.
    static func matchListItem(_ line: String) -> String? {
        let chars = Array(line.unicodeScalars)
        var p = 0
        while p < chars.count, chars[p] == " " { p += 1 }
        guard p + 1 < chars.count, chars[p] == "-", chars[p + 1] == " " else { return nil }
        p += 2
        while p < chars.count, isSpace(chars[p]) { p += 1 }
        return String(String.UnicodeScalarView(chars[p...]))
    }

    /// `^ *(#.*)?\s*$`
    static func isComment(_ line: String) -> Bool {
        let chars = Array(line.unicodeScalars)
        var p = 0
        while p < chars.count, chars[p] == " " { p += 1 }
        if p < chars.count, chars[p] == "#" { return true }
        return chars[p...].allSatisfy(isSpace)
    }

    /// `^---\s*(#.*)?$`
    static func isBeginningOfDocument(_ line: String) -> Bool {
        line.hasPrefix("---") && restIsSpaceThenOptionalComment(Array(line.unicodeScalars).dropFirst(3))
    }

    /// `^...\s*(#.*)?$` — note the unescaped dots: in the original ANY three characters followed by
    /// optional whitespace/comment count as end-of-document, which makes the parser silently skip
    /// such lines. Kept for compatibility with existing project files.
    static func isEndOfDocument(_ line: String) -> Bool {
        // std::regex on std::string matches bytes, so "any three characters" means three UTF-8 bytes.
        let bytes = Array(line.utf8)
        guard bytes.count >= 3, !bytes[0..<3].contains(where: { $0 == 0x0A || $0 == 0x0D }) else { return false }
        let rest = String(decoding: bytes[3...], as: UTF8.self)
        return restIsSpaceThenOptionalComment(ArraySlice(rest.unicodeScalars))
    }

    private static func restIsSpaceThenOptionalComment(_ rest: ArraySlice<Unicode.Scalar>) -> Bool {
        var rest = rest
        while let c = rest.first, isSpace(c) { rest = rest.dropFirst() }
        return rest.isEmpty || rest.first == "#"
    }

    static func leadingSpaces(_ line: String) -> Int {
        line.unicodeScalars.prefix(while: { $0 == " " }).count
    }

    /// ECMAScript `\w`: ASCII letters, digits, underscore.
    static func isWordChar(_ c: Unicode.Scalar) -> Bool {
        c.isASCII && (c.properties.isAlphabetic || ("0"..."9").contains(c) || c == "_")
    }

    /// `\s` in the original's C-locale std::regex: ASCII space, tab, vertical tab, form feed
    /// (line terminators never occur inside a line here).
    static func isSpace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\u{0B}" || c == "\u{0C}"
    }
}
