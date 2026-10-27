import Foundation

@main struct ShortcutSmoke {
    static func main() throws {
        let defaults = Dictionary(uniqueKeysWithValues: EditorCommandID.allCases.map { ($0, $0.defaultBinding) })
        for command in EditorCommandID.allCases {
            precondition(command.defaultBinding.validationError(for: command, bindings: defaults) == nil)
        }
        precondition(ShortcutBinding(key: " Z ", command: true).normalized == defaults[.undo])
        precondition(ShortcutBinding(key: "z", command: true).validationError(for: .splitClip, bindings: defaults)?.contains("Undo") == true)
        precondition(ShortcutBinding(key: "q", command: true).validationError(for: .splitClip, bindings: defaults) != nil)
        precondition(ShortcutBinding(key: "b").validationError(for: .splitClip, bindings: defaults) != nil)
        precondition(ShortcutBinding(key: "space", command: true).validationError(for: .splitClip, bindings: defaults) != nil)
        precondition(EditorCommandID.togglePlayback.defaultBinding == ShortcutBinding(key: "space"))
        precondition(ShortcutBinding(key: "space").validationError(for: .togglePlayback, bindings: defaults) == nil)
        precondition(ShortcutBinding(key: "space").validationError(for: .splitClip, bindings: defaults) != nil)
        precondition(ShortcutBinding(key: "space", command: true).validationError(for: .togglePlayback, bindings: defaults) != nil)
        precondition(ShortcutBinding(key: "", command: true).validationError(for: .splitClip, bindings: defaults) == nil)
        precondition(defaults[.zoomTimelineToFit] == ShortcutBinding(key: "z", shift: true))
        precondition(defaults[.rippleTrimStart] == ShortcutBinding(key: "q"))
        precondition(defaults[.rippleTrimEnd] == ShortcutBinding(key: "w"))
        precondition(ShortcutBinding(key: "q").validationError(for: .splitClip, bindings: defaults) != nil)
        precondition(defaults[.toggleViewer] == ShortcutBinding(key: "tab"))
        precondition(EditorCommandID.toggleViewer.scope == .document)
        precondition(ShortcutBinding(key: "tab").display == "Tab")
        precondition(ShortcutBinding(key: "tab").validationError(for: .toggleViewer, bindings: defaults) == nil)
        precondition(ShortcutBinding(key: "tab").validationError(for: .pausePlayback, bindings: defaults)?.contains("Viewer") == true)
        precondition(defaults[.rippleDelete] == ShortcutBinding(key: "delete"))
        precondition(defaults[.deleteClip] == ShortcutBinding(key: "delete", shift: true))
        precondition(ShortcutBinding(key: "delete").display == "⌫")
        precondition(ShortcutBinding(key: "delete").validationError(for: .splitClip, bindings: defaults) != nil)
        precondition(defaults[.playReverse] == ShortcutBinding(key: "j"))
        precondition(defaults[.pausePlayback] == ShortcutBinding(key: "k"))
        precondition(defaults[.playForward] == ShortcutBinding(key: "l"))
        precondition(defaults[.exportSequence] == ShortcutBinding(key: "e", command: true, shift: true))
        precondition(defaults[.exportFCPXML]?.isEmpty == true)
        precondition(defaults[.exportEDL]?.isEmpty == true && EditorCommandID.exportEDL.scope == .document)
        precondition(defaults[.exportOTIO]?.isEmpty == true && EditorCommandID.exportOTIO.scope == .document)
        precondition(ShortcutBinding(key: "j").validationError(for: .playForward, bindings: defaults)?.contains("Backwards") == true)
        precondition(ShortcutBinding(key: "p").validationError(for: .pausePlayback, bindings: defaults) == nil)
        precondition(defaults[.addMarker] == ShortcutBinding(key: "m") && defaults[.nextMarker] == ShortcutBinding(key: "m", shift: true))
        precondition(defaults[.previousMarker] == ShortcutBinding(key: "m", option: true))
        precondition(defaults[.previousEdit] == ShortcutBinding(key: "up") && defaults[.nextEdit] == ShortcutBinding(key: "down"))
        precondition(ShortcutBinding(key: "m").validationError(for: .previousMarker, bindings: defaults) != nil)
        // A former default is never also the current one, or saved maps could not tell them apart.
        for command in EditorCommandID.allCases { precondition(!command.formerDefaultBindings.contains(command.defaultBinding)) }
        precondition(EditorCommandID.rippleDelete.formerDefaultBindings == [ShortcutBinding(key: "delete", command: true, shift: true)])
        let customized = ShortcutBinding(key: "k", command: true, shift: true)
        precondition(customized.validationError(for: .splitClip, bindings: defaults) == nil)
        let restored = try JSONDecoder().decode(ShortcutBinding.self, from: JSONEncoder().encode(customized))
        precondition(restored == customized)
        print("Shortcut model smoke passed: defaults, normalization, conflicts, reserved keys, text-entry protection, clearing, Codable round-trip.")
    }
}
