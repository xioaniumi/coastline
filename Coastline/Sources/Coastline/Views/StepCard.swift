import CoastlineCore
import SwiftUI

/// The step on screen, as an instruction card over the 3D view: which phase, what to do at the
/// machine, the measuring checkpoint when there is one, and Previous / Next / Tour.
struct StepCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Folded to one line (remembered): the step's name, its number and the way back open.
    @AppStorage("stepCardCollapsed") private var collapsed = false

    var body: some View {
        if let step = model.currentStep { card(step) }
    }

    /// An accordion: the header (chapter, step, the step's name) always shows; its disclosure
    /// button folds the instructions and buttons away and opens them again.
    private func card(_ step: JobStep) -> some View {
            let total = model.jobSteps.count
            return VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { collapsed.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("Chapter \(model.chapterNumber(step.chapter)) · \(step.chapter.title)")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text("Step \(step.number) of \(total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Label(step.title, systemImage: step.symbol).font(.headline).lineLimit(1)
                            Spacer(minLength: 4)
                            // The disclosure control: a round glass button, turning as it opens.
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                                .rotationEffect(.degrees(collapsed ? 0 : 180))
                                .frame(width: 24, height: 24)
                                .glassEffect(.regular.interactive(), in: .circle)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Show the step's instructions" : "Fold the instructions away")
                .accessibilityLabel("Step \(step.number) of \(total): \(step.title)")
                .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
                .accessibilityHint(collapsed ? "Shows the step's instructions" : "Folds the instructions away")
                if !collapsed {
                VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(model.instructions(for: step).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(.secondary).frame(width: 4, height: 4).offset(y: -2)
                            Text(.init(line)).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button("Previous Step", systemImage: "chevron.left") { model.visitStep(by: -1) }
                        .labelStyle(.iconOnly)
                        .disabled(model.step(after: step, by: -1) == nil)
                        .help("Previous step (⌘[)")
                    Button { model.visitStep(by: 1) } label: {
                        Label("Next Step", systemImage: "chevron.right").labelStyle(.titleAndIcon)
                    }
                    .disabled(model.step(after: step, by: 1) == nil)
                    .help("Next step (⌘])")
                    Spacer()
                    Button { model.touring ? model.stopTour() : model.startTour() } label: {
                        Label(model.touring ? "Stop Tour" : "Tour", systemImage: model.touring ? "stop.fill" : "play.rectangle.fill")
                    }
                    .help("Walks through every step from here: the stock moving between clampings, each program played through.")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
            .clipped()
            .padding(14)
            .frame(width: 340, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

extension AppModel {
    /// Shows the step before or after the one on screen (the step card's buttons, ⌘[ and ⌘]).
    func visitStep(by delta: Int) {
        guard let step = currentStep, let s = self.step(after: step, by: delta) else { return }
        stopTour()
        visit(s)
    }

    /// Whether there's a step before or after the one on screen.
    func canVisitStep(by delta: Int) -> Bool {
        currentStep.flatMap { step(after: $0, by: delta) } != nil
    }
}
