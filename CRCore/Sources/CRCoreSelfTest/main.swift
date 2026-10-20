import Foundation

let suites: [(String, [TestCase])] = [
    ("YAMLSubset", yamlTests),
    ("Project", projectTests),
    ("GCode", gcodeTests),
    ("Guided", guidedTests),
    ("Manual", manualTests),
    ("Firmware", firmwareTests),
    ("Writer", writerTests),
    ("GRBL", grblTests),
]

setvbuf(stdout, nil, _IONBF, 0)
let filter = CommandLine.arguments.dropFirst().first
var passed = 0, failed = 0, skipped = 0
for (suite, tests) in suites {
    for test in tests {
        let name = "\(suite).\(test.name)"
        if let filter, !name.localizedCaseInsensitiveContains(filter) { continue }
        print("  … \(name)", terminator: "\r")
        do {
            try test.body()
            passed += 1
            print("  ✓ \(name)")
        } catch let skip as Skip {
            skipped += 1
            print("  – \(name) (skipped: \(skip.reason))")
        } catch {
            failed += 1
            print("  ✗ \(name): \(error)")
        }
    }
}
print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
exit(failed == 0 ? 0 : 1)
