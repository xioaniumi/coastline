import AppKit
import CoastlineCore
import SwiftUI

/// The Toolpaths and Playback menus, and Measure in the View menu: every shortcut works from
/// anywhere in the window, not only when its button is on screen, and the menus show them.
///
/// The menus only read cheap state (flags and counts), never the job's steps or the playhead:
/// SwiftUI redraws them whenever what they read changes, and the playhead moves 60 times a
/// second while playing.
struct CoastlineCommands: Commands {
    let model: AppModel
    let inventory: InventoryModel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Toggle("Measure", isOn: Binding(get: { model.measuring }, set: { on in
                if KeyPassThrough.handBack() { return }
                model.measuring = on
            }))
            .keyboardShortcut("m", modifiers: [])
            .disabled(model.part == nil || model.page != .workspace)
        }
        CommandMenu("Toolpaths") {
            Button(model.generateTitle) { Task { await model.generateOrApply(inventory: inventory.inventory) } }
                .keyboardShortcut("g")
                .disabled(model.part == nil || model.stock == nil || model.isGenerating)
            Button("Cancel Generation") { model.cancelGenerationNow() }
                .keyboardShortcut(".")
                .disabled(!model.isGenerating)
        }
        CommandMenu("Playback") {
            let playable = model.page == .workspace && model.showsMachiningResults && !model.timeline.entries.isEmpty
            Button(model.isPlaying ? "Pause" : "Play") { pass { model.togglePlay() } }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!playable)
            Divider()
            Button("Previous Move") { pass { model.step(-1) } }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!playable)
            Button("Next Move") { pass { model.step(1) } }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!playable)
            Button("Previous Operation") { pass { model.jumpOperation(-1) } }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .disabled(!playable)
            Button("Next Operation") { pass { model.jumpOperation(1) } }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .disabled(!playable)
            Divider()
            // The step card's Previous / Next Step (at the first or last step they do nothing).
            let steps = model.page == .workspace && model.showsMachiningResults && !model.programs.isEmpty
            Button("Previous Step") { model.visitStep(by: -1) }
                .keyboardShortcut("[")
                .disabled(!steps)
            Button("Next Step") { model.visitStep(by: 1) }
                .keyboardShortcut("]")
                .disabled(!steps)
        }
    }

    /// Runs a single-key shortcut's action unless the key belongs to a focused text field.
    private func pass(_ action: () -> Void) {
        if KeyPassThrough.handBack() { return }
        action()
    }
}

/// Single-key shortcuts (Space, M, the arrow keys) are menu key equivalents, and AppKit offers
/// a key press to the menus before the focused view sees it: a text field being typed in would
/// never get its spaces, an "m" or its arrow keys. So each such action first hands the key back
/// to a focused text field or control (a slider, or any control focused with Full Keyboard
/// Access) and only acts when nothing there wants it. Lists and tables don't count: the sidebar
/// keeps focus after a click, and the shortcuts must still work then.
@MainActor
enum KeyPassThrough {
    /// True when the key press was handed to the focused text field or control (so the
    /// shortcut should do nothing).
    static func handBack() -> Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown,
              event.modifierFlags.isDisjoint(with: [.command, .control]),
              let responder = NSApp.keyWindow?.firstResponder, wantsKeys(responder) else { return false }
        responder.keyDown(with: event)
        return true
    }

    private static func wantsKeys(_ responder: NSResponder) -> Bool {
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSControl && !(responder is NSTableView)
    }
}
