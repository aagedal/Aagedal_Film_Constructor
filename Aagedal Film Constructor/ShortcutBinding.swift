import Foundation

enum EditorCommandScope: String, Codable { case document, source, timeline }

enum EditorCommandID: String, Codable, CaseIterable, Identifiable {
    case toggleViewer, undo, redo, importMedia, appendSource, splitClip, previousFrame, nextFrame, deleteClip, playReverse, pausePlayback, playForward, exportSequence, exportFCPXML, exportEDL, exportOTIO
    var id: String { rawValue }
    var title: String {
        switch self {
        case .toggleViewer: "Switch Source / Sequence Viewer"
        case .undo: "Undo"
        case .redo: "Redo"
        case .importMedia: "Import Media…"
        case .appendSource: "Append Selected Source"
        case .splitClip: "Split at Playhead"
        case .previousFrame: "Previous Frame"
        case .nextFrame: "Next Frame"
        case .deleteClip: "Delete Selected Clip"
        case .playReverse: "Play Source Backwards"
        case .pausePlayback: "Pause Source"
        case .playForward: "Play Source Forwards"
        case .exportSequence: "Render Sequence…"
        case .exportFCPXML: "Export FCPXML…"
        case .exportEDL: "Export Track EDL…"
        case .exportOTIO: "Export OpenTimelineIO…"
        }
    }
    var isPlayback: Bool { [.playReverse, .pausePlayback, .playForward].contains(self) }
    var scope: EditorCommandScope {
        switch self {
        case .toggleViewer, .undo, .redo, .importMedia, .exportSequence, .exportFCPXML, .exportEDL, .exportOTIO: .document
        case .appendSource, .playReverse, .pausePlayback, .playForward: .source
        default: .timeline
        }
    }
    var defaultBinding: ShortcutBinding {
        switch self {
        case .toggleViewer: ShortcutBinding(key: "tab")
        case .undo: ShortcutBinding(key: "z", command: true)
        case .redo: ShortcutBinding(key: "z", command: true, shift: true)
        case .importMedia: ShortcutBinding(key: "i", command: true)
        case .appendSource: ShortcutBinding(key: "e", command: true)
        case .splitClip: ShortcutBinding(key: "b", command: true)
        case .previousFrame: ShortcutBinding(key: "left", command: true, option: true)
        case .nextFrame: ShortcutBinding(key: "right", command: true, option: true)
        case .deleteClip: ShortcutBinding(key: "delete", command: true)
        case .playReverse: ShortcutBinding(key: "j")
        case .pausePlayback: ShortcutBinding(key: "k")
        case .playForward: ShortcutBinding(key: "l")
        case .exportSequence: ShortcutBinding(key: "e", command: true, shift: true)
        case .exportFCPXML, .exportEDL, .exportOTIO: ShortcutBinding(key: "")
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
        let keyLabel = ["left": "←", "right": "→", "up": "↑", "down": "↓", "delete": "⌫", "return": "↩", "escape": "⎋", "space": "Space", "tab": "Tab"][normalized.key] ?? normalized.key.uppercased()
        return isEmpty ? "None" : (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + keyLabel
    }

    func validationError(for commandID: EditorCommandID, bindings: [EditorCommandID: ShortcutBinding]) -> String? {
        let candidate = normalized
        if candidate.isEmpty { return nil }
        let namedKeys = ["left", "right", "up", "down", "delete", "return", "escape", "space", "tab"]
        guard namedKeys.contains(candidate.key) || (candidate.key.count == 1 && candidate.key.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }) else {
            return "Enter one character or left, right, up, down, delete, return, escape, space, or tab."
        }
        guard commandID.isPlayback || commandID == .toggleViewer || candidate.command || candidate.option || candidate.control else {
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
