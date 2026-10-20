import Foundation
@testable import CRCore

private func step(_ title: String, gcode: Bool = false, popup: String = "", yes: String = "", no: String = "",
                  goTo: String = "", unskippable: Bool = false) -> Step {
    var s = Step(manifest: "manifest.yml")
    s.title = title
    if gcode { s.gcodePath = "Code/\(title).nc" }
    if !popup.isEmpty { s.popupText = popup; s.unskippable = "true" }
    s.popupYesStep = yes
    s.popupNoStep = no
    s.goTo = goTo
    if unskippable { s.unskippable = "true" }
    return s
}

let guidedTests: [TestCase] = [
    TestCase(name: "parseGoTo") {
        var nav = GuidedNavigator(steps: (0..<10).map { step("\($0)") })
        nav.jump(to: 4)
        try expectEqual(nav.resolve(goTo: "+2"), 6)
        try expectEqual(nav.resolve(goTo: "-3"), 1)
        try expectEqual(nav.resolve(goTo: "7"), 7)
        try expectEqual(nav.resolve(goTo: "8 steps"), 8)
        try expect(nav.resolve(goTo: "") == nil)
        try expect(nav.resolve(goTo: "abc") == nil)
    },

    TestCase(name: "nextOnMillingStepAsksToStart") {
        var nav = GuidedNavigator(steps: [step("intro"), step("mill", gcode: true), step("done")])
        try expectEqual(nav.next(connected: true), .moved(1))
        try expectEqual(nav.next(connected: true), .confirmMilling)
        // Not connected: the original simply moves on (no motion happens).
        try expectEqual(nav.next(connected: false), .moved(2))
        try expectEqual(nav.next(connected: true), .jobComplete)
    },

    TestCase(name: "popupYesNoTargets") {
        var nav = GuidedNavigator(steps: [
            step("q", popup: "Tool installed?", yes: "+2", no: "3"),
            step("a"), step("b"), step("c"),
        ])
        try expectEqual(nav.next(connected: true), .showPopup)
        try expectEqual(nav.answerPopup(yes: true), .moved(2))
        nav.jump(to: 0)
        try expectEqual(nav.answerPopup(yes: false), .moved(3))
        // Empty target → just the next step.
        var plain = GuidedNavigator(steps: [step("q", popup: "Continue?"), step("a")])
        try expectEqual(plain.answerPopup(yes: true), .moved(1))
    },

    TestCase(name: "stepGotoOnAdvance") {
        var nav = GuidedNavigator(steps: [step("0", goTo: "+3"), step("1"), step("2"), step("3"), step("4", goTo: "99")])
        try expectEqual(nav.advance(), .moved(3))
        try expectEqual(nav.advance(), .moved(4))
        try expectEqual(nav.advance(), .jobComplete)
    },

    TestCase(name: "cannotGoBackPastMilledStep") {
        var nav = GuidedNavigator(steps: (0..<6).map { step("\($0)", gcode: $0 == 2) })
        nav.jump(to: 2)
        nav.millingStarted()
        _ = nav.advance()
        try expectEqual(nav.index, 3)
        try expect(!nav.canGoBack(), "step 2 was milled")
        try expect(nav.canGoBack(editMode: true))
        _ = nav.advance()
        try expect(nav.canGoBack())
        nav.back()
        try expectEqual(nav.index, 3)
    },

    TestCase(name: "failureAndAbort") {
        var nav = GuidedNavigator(steps: (0..<5).map { step("\($0)", gcode: true) })
        nav.jump(to: 3)
        nav.millingFailed(retrySameStep: true)
        try expectEqual(nav.index, 3)
        try expectEqual(nav.previousMillingStep, 3)
        nav.millingFailed(retrySameStep: false)
        try expectEqual(nav.index, 0)
        nav.jump(to: 4)
        nav.aborted()
        try expectEqual(nav.index, 0)
        try expectEqual(nav.previousMillingStep, -1)
    },

    TestCase(name: "skipToNextMillingStep") {
        var nav = GuidedNavigator(steps: [step("0"), step("1"), step("2", unskippable: true), step("3"), step("4", gcode: true)])
        try expectEqual(nav.nextMillingStep, 4)
        try expectEqual(nav.nextUnskippableStep, 2)
        nav.skipToNextMillingStep()
        try expectEqual(nav.index, 2)
        nav.skipToNextMillingStep()
        try expectEqual(nav.index, 4)
        try expect(!nav.canSkip)
    },

    TestCase(name: "versionGates") {
        try expect(VersionGate.firmwareMeetsMinimum("20240318", installed: "20240318"))
        try expect(!VersionGate.firmwareMeetsMinimum("20250101", installed: "20240318"))
        try expect(VersionGate.firmwareMeetsMinimum("20250101", installed: nil))
        try expect(VersionGate.crwriteMeetsMinimum("1.2.0", current: "1.3.1"))
        try expect(!VersionGate.crwriteMeetsMinimum("2.0", current: "1.3.1"))
        try expect(VersionGate.crwriteMeetsMinimum("", current: "1.0"))
    },
]
