import Foundation

enum EditorCommandScope: String, Codable { case document, source, timeline }

enum EditorCommandID: String, Codable, CaseIterable, Identifiable {
    case togglePlayback, zoomTimelineToFit, rippleTrimStart, rippleTrimEnd, toggleViewer, undo, redo, importMedia, appendSource, markSourceIn, markSourceOut, clearSourceMarks, splitClip, addTransition, addTitle, insertSource, overwriteSource, previousFrame, nextFrame, deleteClip, rippleDelete, playReverse, pausePlayback, playForward, exportSequence, exportFCPXML, exportEDL, exportOTIO, toggleRetime, addMarker, previousMarker, nextMarker, previousEdit, nextEdit, toggleScopes,
         goToStart, goToEnd, backTenFrames, forwardTenFrames, goToIn, goToOut, splitAll, trimStartToPlayhead, trimEndToPlayhead,
         nudgeLeft, nudgeRight, toggleClipEnabled, selectClipAtPlayhead, deselectAll, toggleSnapping, zoomIn, zoomOut
    var id: String { rawValue }
    var title: String {
        switch self {
        case .togglePlayback: "Play / Pause"
        case .zoomTimelineToFit: "Zoom Timeline to Fit"
        case .rippleTrimStart: "Ripple Trim Start to Playhead"
        case .rippleTrimEnd: "Ripple Trim End to Playhead"
        case .toggleViewer: "Switch Source / Sequence Viewer"
        case .undo: "Undo"
        case .redo: "Redo"
        case .importMedia: "Import Media…"
        case .appendSource: "Append Selected Source"
        case .markSourceIn: "Mark In"
        case .markSourceOut: "Mark Out (Exclusive)"
        case .clearSourceMarks: "Clear In and Out"
        case .splitClip: "Split at Playhead"
        case .addTransition: "Add Transition at Nearest Edit"
        case .addTitle: "New Title at Playhead"
        case .insertSource: "Insert Source at Playhead"
        case .overwriteSource: "Overwrite Source at Playhead"
        case .rippleDelete: "Ripple Delete Selected Clip"
        case .previousFrame: "Previous Frame"
        case .nextFrame: "Next Frame"
        case .deleteClip: "Delete Selected Clip"
        case .playReverse: "Play Backwards"
        case .pausePlayback: "Pause"
        case .playForward: "Play Forwards"
        case .exportSequence: "Render Sequence…"
        case .exportFCPXML: "Export FCPXML…"
        case .exportEDL: "Export Track EDL…"
        case .exportOTIO: "Export OpenTimelineIO…"
        case .toggleRetime: "Retime Controls"
        case .addMarker: "Add Marker at Playhead"
        case .previousMarker: "Previous Marker"
        case .nextMarker: "Next Marker"
        case .previousEdit: "Previous Edit Point"
        case .nextEdit: "Next Edit Point"
        case .toggleScopes: "Show / Hide Video Scopes"
        case .goToStart: "Go to Start"
        case .goToEnd: "Go to End"
        case .backTenFrames: "Back 10 Frames"
        case .forwardTenFrames: "Forward 10 Frames"
        case .goToIn: "Go to In"
        case .goToOut: "Go to Out"
        case .splitAll: "Split All Tracks at Playhead"
        case .trimStartToPlayhead: "Trim Start to Playhead"
        case .trimEndToPlayhead: "Trim End to Playhead"
        case .nudgeLeft: "Nudge Clip Left One Frame"
        case .nudgeRight: "Nudge Clip Right One Frame"
        case .toggleClipEnabled: "Enable / Disable Clip"
        case .selectClipAtPlayhead: "Select Clip at Playhead"
        case .deselectAll: "Deselect"
        case .toggleSnapping: "Snapping"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        }
    }
    var isPlayback: Bool { [.togglePlayback, .playReverse, .pausePlayback, .playForward].contains(self) }
    var scope: EditorCommandScope {
        switch self {
        // Marks act on whichever viewer is showing, like playback.
        case .toggleViewer, .undo, .redo, .importMedia, .insertSource, .overwriteSource, .exportSequence, .exportFCPXML, .exportEDL, .exportOTIO, .toggleScopes,
             .markSourceIn, .markSourceOut, .clearSourceMarks, .goToIn, .goToOut: .document
        case .appendSource, .playReverse, .pausePlayback, .playForward: .source
        default: .timeline
        }
    }
    /// Defaults from earlier versions, which full saved maps may still hold.
    var formerDefaultBindings: [ShortcutBinding] {
        switch self {
        case .rippleDelete: [ShortcutBinding(key: "delete", command: true, shift: true)]
        case .deleteClip: [ShortcutBinding(key: "delete", command: true)]
        case .previousFrame: [ShortcutBinding(key: "left", command: true, option: true)]
        case .nextFrame: [ShortcutBinding(key: "right", command: true, option: true)]
        default: []
        }
    }
    var defaultBinding: ShortcutBinding {
        switch self {
        case .togglePlayback: ShortcutBinding(key: "space")
        case .zoomTimelineToFit: ShortcutBinding(key: "z", shift: true)
        case .rippleTrimStart: ShortcutBinding(key: "q")
        case .rippleTrimEnd: ShortcutBinding(key: "w")
        case .toggleViewer: ShortcutBinding(key: "tab")
        case .undo: ShortcutBinding(key: "z", command: true)
        case .redo: ShortcutBinding(key: "z", command: true, shift: true)
        case .importMedia: ShortcutBinding(key: "i", command: true)
        case .appendSource: ShortcutBinding(key: "e", command: true)
        case .markSourceIn: ShortcutBinding(key: "i")
        case .markSourceOut: ShortcutBinding(key: "o")
        case .clearSourceMarks: ShortcutBinding(key: "x", option: true)
        case .splitClip: ShortcutBinding(key: "b", command: true)
        case .addTransition: ShortcutBinding(key: "t", command: true)
        case .addTitle: ShortcutBinding(key: "t", control: true)
        case .insertSource: ShortcutBinding(key: ",")
        case .overwriteSource: ShortcutBinding(key: ".")
        case .rippleDelete: ShortcutBinding(key: "delete")
        case .previousFrame: ShortcutBinding(key: "left")
        case .nextFrame: ShortcutBinding(key: "right")
        case .deleteClip: ShortcutBinding(key: "delete", shift: true)
        case .playReverse: ShortcutBinding(key: "j")
        case .pausePlayback: ShortcutBinding(key: "k")
        case .playForward: ShortcutBinding(key: "l")
        case .exportSequence: ShortcutBinding(key: "e", command: true, shift: true)
        case .exportFCPXML, .exportEDL, .exportOTIO: ShortcutBinding(key: "")
        case .toggleRetime: ShortcutBinding(key: "r", command: true)
        case .addMarker: ShortcutBinding(key: "m")
        case .previousMarker: ShortcutBinding(key: "m", option: true)
        case .nextMarker: ShortcutBinding(key: "m", shift: true)
        case .previousEdit: ShortcutBinding(key: "up")
        case .nextEdit: ShortcutBinding(key: "down")
        case .toggleScopes: ShortcutBinding(key: "w", command: true, shift: true)
        case .goToStart: ShortcutBinding(key: "home")
        case .goToEnd: ShortcutBinding(key: "end")
        case .backTenFrames: ShortcutBinding(key: "left", shift: true)
        case .forwardTenFrames: ShortcutBinding(key: "right", shift: true)
        case .goToIn: ShortcutBinding(key: "i", shift: true)
        case .goToOut: ShortcutBinding(key: "o", shift: true)
        case .splitAll: ShortcutBinding(key: "b", command: true, shift: true)
        case .trimStartToPlayhead: ShortcutBinding(key: "q", option: true)
        case .trimEndToPlayhead: ShortcutBinding(key: "w", option: true)
        case .nudgeLeft: ShortcutBinding(key: "left", option: true)
        case .nudgeRight: ShortcutBinding(key: "right", option: true)
        case .toggleClipEnabled: ShortcutBinding(key: "v")
        case .selectClipAtPlayhead: ShortcutBinding(key: "c")
        case .deselectAll: ShortcutBinding(key: "escape")
        case .toggleSnapping: ShortcutBinding(key: "n")
        case .zoomIn: ShortcutBinding(key: "=", command: true)
        case .zoomOut: ShortcutBinding(key: "-", command: true)
        }
    }
}

extension EditorCommandID {
    /// Commands that may use a bare or Shift-only key; editor keys never reach focused text.
    var allowsUnmodifiedKey: Bool {
        [.toggleViewer, .markSourceIn, .markSourceOut, .clearSourceMarks, .zoomTimelineToFit, .rippleTrimStart, .rippleTrimEnd, .insertSource,
         .overwriteSource, .rippleDelete, .deleteClip, .addMarker, .nextMarker, .previousEdit, .nextEdit, .previousFrame, .nextFrame,
         .goToStart, .goToEnd, .backTenFrames, .forwardTenFrames, .goToIn, .goToOut, .toggleClipEnabled, .selectClipAtPlayhead,
         .deselectAll, .toggleSnapping].contains(self)
    }
}

struct ShortcutBinding: Codable, Equatable {
    /// Keys named rather than typed; the text system uses all of them for navigation or entry.
    static let namedKeys = ["left", "right", "up", "down", "home", "end", "delete", "return", "escape", "space", "tab"]
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
        let keyLabel = ["left": "←", "right": "→", "up": "↑", "down": "↓", "delete": "⌫", "return": "↩", "escape": "⎋", "space": "Space", "tab": "Tab",
                        "home": "↖", "end": "↘"][normalized.key] ?? normalized.key.uppercased()
        return isEmpty ? "None" : (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + keyLabel
    }

    func validationError(for commandID: EditorCommandID, bindings: [EditorCommandID: ShortcutBinding]) -> String? {
        let candidate = normalized
        if candidate.isEmpty { return nil }
        let namedKeys = Self.namedKeys
        guard namedKeys.contains(candidate.key) || (candidate.key.count == 1 && candidate.key.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }) else {
            return "Enter one character or left, right, up, down, home, end, delete, return, escape, space, or tab."
        }
        guard commandID.isPlayback || commandID.allowsUnmodifiedKey || candidate.command || candidate.option || candidate.control else {
            return "Include Command, Option, or Control to preserve text entry."
        }
        // ⇧⌘W is the scopes shortcut; only plain ⌘W closes the window.
        if candidate.command && !candidate.option && !candidate.control && ["q", "w", "n", "o", "s", "h", "m", ",", "c", "v", "x", "a", "f"].contains(candidate.key)
            && !(candidate.shift && candidate.key == "w") {
            return "This shortcut is reserved for standard application or text commands."
        }
        if candidate.command && ((candidate.option && ["h", "m"].contains(candidate.key)) || (candidate.control && candidate.key == "f") || (candidate.shift && candidate.key == "/")) {
            return "This shortcut is reserved for standard application commands."
        }
        // Bare or Shift-Space is the editing convention for transport; other Space chords belong to macOS.
        let transportSpace = commandID.isPlayback && !candidate.command && !candidate.option && !candidate.control
        if (candidate.key == "space" && !transportSpace) || (candidate.control && ["left", "right", "up", "down"].contains(candidate.key)) || (candidate.command && candidate.option && candidate.key == "escape") {
            return "This combination is reserved for macOS."
        }
        for other in EditorCommandID.allCases where other != commandID {
            if bindings[other]?.normalized == candidate { return "Already assigned to \(other.title)." }
        }
        return nil
    }
}
