import Foundation

enum EditorCommandScope: String, Codable { case document, source, timeline }

enum EditorCommandID: String, Codable, CaseIterable, Identifiable {
    case undo, redo, importMedia, appendSource, splitClip, previousFrame, nextFrame, deleteClip
    var id: String { rawValue }
    var title: String {
        switch self {
        case .undo: "Undo"
        case .redo: "Redo"
        case .importMedia: "Import Media…"
        case .appendSource: "Append Selected Source"
        case .splitClip: "Split at Playhead"
        case .previousFrame: "Previous Frame"
        case .nextFrame: "Next Frame"
        case .deleteClip: "Delete Selected Clip"
        }
    }
    var scope: EditorCommandScope {
        switch self {
        case .undo, .redo, .importMedia: .document
        case .appendSource: .source
        default: .timeline
        }
    }
    var defaultBinding: ShortcutBinding {
        switch self {
        case .undo: ShortcutBinding(key: "z", command: true)
        case .redo: ShortcutBinding(key: "z", command: true, shift: true)
        case .importMedia: ShortcutBinding(key: "i", command: true)
        case .appendSource: ShortcutBinding(key: "e", command: true)
        case .splitClip: ShortcutBinding(key: "b", command: true)
        case .previousFrame: ShortcutBinding(key: "left", command: true, option: true)
        case .nextFrame: ShortcutBinding(key: "right", command: true, option: true)
        case .deleteClip: ShortcutBinding(key: "delete", command: true)
        }
    }
}

struct ShortcutBinding: Codable, Equatable {
    var key: String
    var command = false
    var option = false
    var control = false
    var shift = false

    var normalized: ShortcutBinding {
        var result = self
        result.key = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return result
    }
    var isEmpty: Bool { normalized.key.isEmpty }
    var display: String {
        let keyLabel = ["left": "←", "right": "→", "up": "↑", "down": "↓", "delete": "⌫", "return": "↩", "escape": "⎋", "space": "Space"][normalized.key] ?? normalized.key.uppercased()
        return isEmpty ? "None" : (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + keyLabel
    }

    func validationError(for commandID: EditorCommandID, bindings: [EditorCommandID: ShortcutBinding]) -> String? {
        let candidate = normalized
        if candidate.isEmpty { return nil }
        let namedKeys = ["left", "right", "up", "down", "delete", "return", "escape", "space"]
        guard namedKeys.contains(candidate.key) || (candidate.key.count == 1 && candidate.key.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }) else {
            return "Enter one character or left, right, up, down, delete, return, escape, or space."
        }
        guard candidate.command || candidate.option || candidate.control else {
            return "Include Command, Option, or Control to preserve text entry."
        }
        if candidate.command && !candidate.option && !candidate.control && ["q", "w", "n", "o", "s", "h", "m", ",", "c", "v", "x", "a", "f"].contains(candidate.key) {
            return "This shortcut is reserved for standard application or text commands."
        }
        if candidate.command && ((candidate.option && ["h", "m"].contains(candidate.key)) || (candidate.control && candidate.key == "f") || (candidate.shift && candidate.key == "/")) {
            return "This shortcut is reserved for standard application commands."
        }
        if candidate.key == "space" || (candidate.control && ["left", "right", "up", "down"].contains(candidate.key)) || (candidate.command && candidate.option && candidate.key == "escape") {
            return "This combination is reserved for macOS."
        }
        for other in EditorCommandID.allCases where other != commandID {
            if bindings[other]?.normalized == candidate { return "Already assigned to \(other.title)." }
        }
        return nil
    }
}
