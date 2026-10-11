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
        precondition(ShortcutBinding(key: "", command: true).validationError(for: .splitClip, bindings: defaults) == nil)
        precondition(defaults[.playReverse] == ShortcutBinding(key: "j"))
        precondition(defaults[.pausePlayback] == ShortcutBinding(key: "k"))
        precondition(defaults[.playForward] == ShortcutBinding(key: "l"))
        precondition(defaults[.exportSequence] == ShortcutBinding(key: "e", command: true, shift: true))
        precondition(defaults[.exportFCPXML]?.isEmpty == true)
        precondition(ShortcutBinding(key: "j").validationError(for: .playForward, bindings: defaults)?.contains("Backwards") == true)
        precondition(ShortcutBinding(key: "p").validationError(for: .pausePlayback, bindings: defaults) == nil)
        let customized = ShortcutBinding(key: "k", command: true, shift: true)
        precondition(customized.validationError(for: .splitClip, bindings: defaults) == nil)
        let restored = try JSONDecoder().decode(ShortcutBinding.self, from: JSONEncoder().encode(customized))
        precondition(restored == customized)
        print("Shortcut model smoke passed: defaults, normalization, conflicts, reserved keys, text-entry protection, clearing, Codable round-trip.")
    }
}
