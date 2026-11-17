import Foundation

@main struct ShortcutSmoke {
    static func main() throws {
        let defaults = Keymap.defaults
        for command in EditorCommandID.allCases {
            precondition(defaults.validationError(command.defaultBinding, for: command) == nil)
        }
        precondition(ShortcutBinding(key: " Z ", command: true).normalized == defaults[.undo])
        precondition(defaults.validationError(ShortcutBinding(key: "z", command: true), for: .splitClip)?.contains("Undo") == true)
        precondition(defaults.validationError(ShortcutBinding(key: "q", command: true), for: .splitClip) != nil)
        precondition(defaults.validationError(ShortcutBinding(key: "b"), for: .splitClip) != nil)
        precondition(defaults.validationError(ShortcutBinding(key: "space", command: true), for: .splitClip) != nil)
        precondition(EditorCommandID.togglePlayback.defaultBinding == ShortcutBinding(key: "space"))
        precondition(defaults.validationError(ShortcutBinding(key: "space"), for: .togglePlayback) == nil)
        precondition(defaults.validationError(ShortcutBinding(key: "space"), for: .splitClip) != nil)
        precondition(defaults.validationError(ShortcutBinding(key: "space", command: true), for: .togglePlayback) != nil)
        precondition(defaults.validationError(ShortcutBinding(key: "", command: true), for: .splitClip) == nil)
        precondition(defaults[.zoomTimelineToFit] == ShortcutBinding(key: "z", shift: true))
        precondition(defaults[.rippleTrimStart] == ShortcutBinding(key: "q"))
        precondition(defaults[.rippleTrimEnd] == ShortcutBinding(key: "w"))
        precondition(defaults.validationError(ShortcutBinding(key: "q"), for: .splitClip) != nil)
        precondition(defaults[.toggleViewer] == ShortcutBinding(key: "tab"))
        precondition(EditorCommandID.toggleViewer.scope == .document)
        precondition(ShortcutBinding(key: "tab").display == "Tab")
        precondition(defaults.validationError(ShortcutBinding(key: "tab"), for: .toggleViewer) == nil)
        precondition(defaults.validationError(ShortcutBinding(key: "tab"), for: .pausePlayback)?.contains("Viewer") == true)
        precondition(defaults[.rippleDelete] == ShortcutBinding(key: "delete"))
        precondition(defaults[.deleteClip] == ShortcutBinding(key: "delete", shift: true))
        precondition(ShortcutBinding(key: "delete").display == "⌫")
        precondition(defaults.validationError(ShortcutBinding(key: "delete"), for: .splitClip) != nil)
        precondition(defaults[.playReverse] == ShortcutBinding(key: "j"))
        precondition(defaults[.pausePlayback] == ShortcutBinding(key: "k"))
        precondition(defaults[.playForward] == ShortcutBinding(key: "l"))
        precondition(defaults[.exportSequence] == ShortcutBinding(key: "e", command: true, shift: true))
        precondition(defaults[.exportFCPXML].isEmpty == true)
        precondition(defaults[.exportEDL].isEmpty == true && EditorCommandID.exportEDL.scope == .document)
        precondition(defaults[.exportOTIO].isEmpty == true && EditorCommandID.exportOTIO.scope == .document)
        precondition(defaults.validationError(ShortcutBinding(key: "j"), for: .playForward)?.contains("Backwards") == true)
        precondition(defaults.validationError(ShortcutBinding(key: "p"), for: .pausePlayback) == nil)
        precondition(defaults[.addMarker] == ShortcutBinding(key: "m") && defaults[.nextMarker] == ShortcutBinding(key: "m", shift: true))
        precondition(defaults[.previousMarker] == ShortcutBinding(key: "m", option: true))
        precondition(defaults[.previousEdit] == ShortcutBinding(key: "up") && defaults[.nextEdit] == ShortcutBinding(key: "down"))
        precondition(defaults.validationError(ShortcutBinding(key: "m"), for: .previousMarker) != nil)
        // Common editor keys: arrows step frames (Shift by ten), Home/End, ⌥ arrows nudge, Shift-I/O go to marks.
        precondition(defaults[.previousFrame] == ShortcutBinding(key: "left") && defaults[.nextFrame] == ShortcutBinding(key: "right"))
        precondition(EditorCommandID.previousFrame.formerDefaultBindings == [ShortcutBinding(key: "left", command: true, option: true)])
        precondition(defaults[.backTenFrames] == ShortcutBinding(key: "left", shift: true))
        precondition(defaults[.goToStart] == ShortcutBinding(key: "home") && defaults[.goToEnd] == ShortcutBinding(key: "end"))
        precondition(ShortcutBinding(key: "home").display == "↖" && defaults.validationError(ShortcutBinding(key: "end"), for: .goToEnd) == nil)
        precondition(defaults[.nudgeLeft] == ShortcutBinding(key: "left", option: true))
        precondition(defaults[.goToIn] == ShortcutBinding(key: "i", shift: true) && EditorCommandID.goToIn.scope == .document)
        precondition(EditorCommandID.markSourceIn.scope == .document && EditorCommandID.markSourceIn.title == "Mark In")
        precondition(defaults[.splitAll] == ShortcutBinding(key: "b", command: true, shift: true))
        precondition(defaults[.trimStartToPlayhead] == ShortcutBinding(key: "q", option: true))
        precondition(defaults[.toggleClipEnabled] == ShortcutBinding(key: "v") && defaults[.selectClipAtPlayhead] == ShortcutBinding(key: "c"))
        precondition(defaults[.deselectAll] == ShortcutBinding(key: "escape") && defaults[.toggleSnapping] == ShortcutBinding(key: "n"))
        precondition(defaults[.zoomIn] == ShortcutBinding(key: "=", command: true) && defaults[.zoomOut] == ShortcutBinding(key: "-", command: true))
        // Trim tools: Premiere's extend edit, match frame, slip and slide; Avid's lift (Z) and extract (X).
        precondition(defaults[.extendEdit] == ShortcutBinding(key: "e") && defaults[.matchFrame] == ShortcutBinding(key: "f"))
        precondition(defaults[.liftRange] == ShortcutBinding(key: "z") && defaults[.extractRange] == ShortcutBinding(key: "x"))
        precondition(defaults[.slipForward] == ShortcutBinding(key: "right", command: true, option: true))
        precondition(defaults[.slideLeft] == ShortcutBinding(key: ",", option: true))
        precondition(EditorCommandID.previousFrame.formerDefaultBindings.contains(defaults[.slipBackward]), "Slip reuses the old frame-step chord")
        // Bare keys stay limited to commands that allow them.
        precondition(defaults.validationError(ShortcutBinding(key: "v"), for: .addTransition) != nil)
        // Every default is unique.
        precondition(Set(EditorCommandID.allCases.compactMap { defaults[$0].isEmpty ? nil : defaults[$0].display }).count
                     == EditorCommandID.allCases.filter { !defaults[$0].isEmpty }.count)
        // A former default is never also the current one, or saved maps could not tell them apart.
        for command in EditorCommandID.allCases { precondition(!command.formerDefaultBindings.contains(command.defaultBinding)) }
        precondition(EditorCommandID.rippleDelete.formerDefaultBindings == [ShortcutBinding(key: "delete", command: true, shift: true)])
        let customized = ShortcutBinding(key: "k", command: true, shift: true)
        precondition(defaults.validationError(customized, for: .splitClip) == nil)
        let restored = try JSONDecoder().decode(ShortcutBinding.self, from: JSONEncoder().encode(customized))
        precondition(restored == customized)
        try exerciseKeymaps()
        print("Shortcut model smoke passed: defaults, normalization, conflicts, reserved keys, text-entry protection, clearing, Codable round-trip, two shortcuts per command, restoring saved maps, preset files.")
    }

    static func exerciseKeymaps() throws {
        var keymap = Keymap.defaults
        let split = ShortcutBinding(key: "b", command: true)
        let alternate = ShortcutBinding(key: "s", option: true)
        // A second shortcut runs the same command and must not repeat the first or take another command's.
        precondition(keymap.validationError(alternate, for: .splitClip, slot: 1) == nil)
        keymap.set(alternate, for: .splitClip, slot: 1)
        precondition(keymap.bindings(for: .splitClip) == [split, alternate] && keymap.command(for: alternate) == .splitClip)
        precondition(keymap.validationError(split, for: .splitClip, slot: 1)?.contains("other shortcut") == true)
        precondition(keymap.validationError(split, for: .splitClip, slot: 0) == nil, "A shortcut does not conflict with itself")
        precondition(keymap.validationError(alternate, for: .addTitle, slot: 1)?.contains("Split") == true)
        // Clearing the first shortcut promotes the second, which menus then show.
        keymap.set(ShortcutBinding(key: ""), for: .splitClip, slot: 0)
        precondition(keymap[.splitClip] == alternate && keymap.bindings(for: .splitClip).count == 1)
        keymap.set(split, for: .splitClip, slot: 1)
        keymap.unassign(alternate)
        precondition(keymap.bindings(for: .splitClip) == [split])
        // Bare function keys never reach text entry, so any command may use one.
        precondition(keymap.validationError(ShortcutBinding(key: "f5"), for: .addTransition) == nil)
        precondition(ShortcutBinding(key: "f5").display == "F5" && ShortcutBinding(key: "pagedown").display == "⇟")
        precondition(ShortcutBinding.keyCodeNames[96] == "f5" && ShortcutBinding.keyCodeNames[117] == "delete")
        precondition(ShortcutBinding.pressed(key: "+", modifiers: [.command, .shift]) == ShortcutBinding(key: "=", command: true))
        precondition(ShortcutBinding.pressed(key: "I", modifiers: .shift) == ShortcutBinding(key: "i", shift: true))
        precondition(ShortcutBinding(key: "?", command: true, shift: true).reservation != nil
                     && ShortcutBinding(key: "/", command: true, shift: true).reservation == nil, "Help is reserved by its character, not a U.S. key")
        precondition(ShortcutBinding(key: "q", command: true).reservedTitle == "Quit" && ShortcutBinding(key: "space", option: true).reservation != nil)
        precondition(ShortcutModifiers.allCombinations.count == 16 && ShortcutModifiers.allCombinations.first == [])
        // Saved maps hold only changes; restoring keeps choices, fills omitted commands
        // with free defaults, and drops invalid or duplicate shortcuts.
        keymap.set(ShortcutBinding(key: "j", command: true), for: .splitClip, slot: 1)
        precondition(keymap.changes(from: .defaults).keys.sorted() == ["splitClip"])
        precondition(Keymap.restoring(keymap.changes(from: .defaults)).keymap == keymap)
        let restored = Keymap.restoring(["playForward": [ShortcutBinding(key: "q")],
                                         "addTitle": [ShortcutBinding(key: "q"), ShortcutBinding(key: "s", command: true), ShortcutBinding(key: "t", control: true)],
                                         "unknownFutureCommand": [ShortcutBinding(key: "y", command: true)]])
        precondition(restored.keymap[.playForward] == ShortcutBinding(key: "q") && restored.keymap.bindings(for: .rippleTrimStart).isEmpty)
        precondition(restored.keymap.bindings(for: .addTitle) == [ShortcutBinding(key: "t", control: true)] && restored.rejected == 2)
        precondition(restored.keymap[.splitClip] == split, "Omitted commands keep their defaults")
        // Preset files carry every command, round-trip, and reject other JSON.
        let preset = KeyboardPreset(name: "Shared", keymap: keymap)
        precondition(preset.shortcuts.count == EditorCommandID.allCases.count && preset.shortcuts["exportEDL"] == [])
        let data = try preset.fileData()
        precondition(String(decoding: data, as: UTF8.self).contains("\"format\" : \"\(KeyboardPreset.fileFormat)\""))
        let reopened = try KeyboardPreset(fileData: data)
        precondition(reopened == preset && reopened.resolved.keymap == keymap && reopened.resolved.rejected == 0)
        do { _ = try KeyboardPreset(fileData: Data("{}".utf8)); preconditionFailure("Other JSON is not a preset") } catch KeyboardPresetError.notAPreset {}
        var newer = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        newer["version"] = KeyboardPreset.fileVersion + 1
        do { _ = try KeyboardPreset(fileData: try JSONSerialization.data(withJSONObject: newer)); preconditionFailure("Newer files are refused") }
        catch KeyboardPresetError.newerVersion {}
        // Shortcuts written without their unused modifiers still decode.
        let short = try JSONDecoder().decode(ShortcutBinding.self, from: Data(#"{"key":"b","command":true}"#.utf8))
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(split)) as! [String: Any]
        precondition(short == split && Set(written.keys) == ["key", "command"])
    }
}
