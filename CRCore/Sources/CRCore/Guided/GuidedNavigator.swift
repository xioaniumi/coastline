import Foundation

/// Step navigation for Guided Mode. Port of the state logic in the original
/// `UI/src/Renderer/containers/Milling/Milling.js` (handleNext, showNextStep, parseGoTo,
/// popup handlers, skip/back rules) and `GetStep`'s next-milling/unskippable lookup.
public struct GuidedNavigator: Equatable, Sendable {
    public let steps: [Step]
    public private(set) var index = 0
    /// Index of the last step that started milling (-1 = none). You can't go back past it.
    public private(set) var previousMillingStep = -1

    public init(steps: [Step]) {
        self.steps = steps
    }

    public var current: Step? { steps.indices.contains(index) ? steps[index] : nil }
    public var isLastStep: Bool { index >= steps.count - 1 }

    public enum NextAction: Equatable, Sendable {
        /// The step has G-code and the mill is connected: ask "Start moving?".
        case confirmMilling
        /// The step has a popup question: ask it, then call `answerPopup(yes:)`.
        case showPopup
        /// Moved to a new step.
        case moved(Int)
        /// There are no more steps.
        case jobComplete
    }

    /// `parseGoTo`: `+n`/`-n` are relative to the current step, otherwise absolute.
    /// Returns nil when the value is not a number (JS `parseInt` semantics).
    public func resolve(goTo raw: String) -> Int? {
        var text = Substring(raw)
        var sign: Character?
        if let first = text.first, first == "+" || first == "-" {
            sign = first
            text = text.dropFirst()
        }
        let trimmed = text.drop(while: { $0.isWhitespace })
        var digits = ""
        for (offset, c) in trimmed.enumerated() {
            if c.isASCII, c.isNumber { digits.append(c) }
            else if offset == 0, c == "-" || c == "+" { digits.append(c) }
            else { break }
        }
        guard let value = Int(digits) else { return nil }
        switch sign {
        case "-": return index - value
        case "+": return index + value
        default: return value
        }
    }

    /// `handleNext`.
    public mutating func next(connected: Bool, editMode: Bool = false) -> NextAction {
        guard let step = current else { return .jobComplete }
        if step.hasGCode, !editMode, connected { return .confirmMilling }
        if step.hasPopup { return .showPopup }
        return advance()
    }

    /// `showNextStep`: next step, honouring `step_goto`.
    public mutating func advance() -> NextAction {
        var target = index + 1
        if let goTo = current?.goTo, !goTo.isEmpty, let resolved = resolve(goTo: goTo), resolved >= 0 {
            target = resolved
        }
        guard target < steps.count else { return .jobComplete }
        index = target
        return .moved(target)
    }

    /// `handlePopupOkay` / `handlePopupCancel`.
    public mutating func answerPopup(yes: Bool) -> NextAction {
        guard let step = current else { return .jobComplete }
        let raw = yes ? step.popupYesStep : step.popupNoStep
        if let target = resolve(goTo: raw), target >= 0 {
            guard target < steps.count else { return .jobComplete }
            index = target
            return .moved(target)
        }
        return advance()
    }

    /// `isPrevAvailable` (call only while not milling).
    public func canGoBack(editMode: Bool = false) -> Bool {
        guard index > 0 else { return false }
        return index - 1 > previousMillingStep || editMode
    }

    /// `showPrevStep`.
    public mutating func back() {
        guard index > 0 else { return }
        index -= 1
    }

    /// Jump directly (e.g. clicking the step list in edit mode).
    public mutating func jump(to target: Int) {
        guard steps.indices.contains(target) else { return }
        index = target
    }

    /// Call when milling starts on the current step.
    public mutating func millingStarted() {
        previousMillingStep = index
    }

    /// After a milling error: retry the same step (probe failure) or restart the job.
    public mutating func millingFailed(retrySameStep: Bool) {
        let target = retrySameStep ? index : 0
        index = target
        previousMillingStep = target
    }

    /// `handleStop`: back to the first step.
    public mutating func aborted() {
        index = 0
        previousMillingStep = -1
    }

    /// From `GetStep`: for a non-milling step, the next step with G-code…
    public var nextMillingStep: Int? {
        guard let step = current, !step.hasGCode else { return nil }
        return steps.indices.dropFirst(index + 1).first { steps[$0].hasGCode }
    }

    /// …and the first unskippable step before it.
    public var nextUnskippableStep: Int? {
        guard let step = current, !step.hasGCode else { return nil }
        for i in steps.indices.dropFirst(index + 1) {
            if steps[i].isUnskippable { return i }
            if steps[i].hasGCode { return nil }
        }
        return nil
    }

    /// `isSkipAvailable`.
    public var canSkip: Bool { nextMillingStep != nil && current?.hasPopup == false }

    /// `skipToNextMillingStep`: stops at an unskippable step if one comes first.
    public mutating func skipToNextMillingStep() {
        guard let milling = nextMillingStep else { return }
        if let unskippable = nextUnskippableStep, unskippable < milling {
            index = unskippable
        } else {
            index = milling
        }
    }
}

/// Version gates from the original (`FirmwareMeetsMinimumVersion`, `CRWriteMeetsMinimumVersion`).
public enum VersionGate {
    /// Firmware dates are YYYYMMDD strings compared lexically.
    public static func firmwareMeetsMinimum(_ minimum: String, installed: String?) -> Bool {
        guard let installed else { return true }
        return minimum <= installed
    }

    /// Dotted versions compared component by component. Note the original only checks that no
    /// component is lower, so 1.3.0 vs 1.2.5 fails on the third component; replicated.
    public static func crwriteMeetsMinimum(_ minimum: String, current: String) -> Bool {
        guard !minimum.isEmpty else { return true }
        let a = current.split(separator: "."), b = minimum.split(separator: ".")
        for (x, y) in zip(a, b) {
            guard let xi = Int(x), let yi = Int(y) else { return false }
            if xi < yi { return false }
        }
        return true
    }
}
