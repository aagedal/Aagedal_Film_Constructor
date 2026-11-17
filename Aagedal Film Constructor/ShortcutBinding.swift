import Foundation

nonisolated enum EditorCommandScope: String, Codable { case document, source, timeline }

nonisolated enum EditorCommandID: String, Codable, CaseIterable, Identifiable {
    case togglePlayback, zoomTimelineToFit, rippleTrimStart, rippleTrimEnd, toggleViewer, undo, redo, importMedia, appendSource, markSourceIn, markSourceOut, clearSourceMarks, splitClip, addTransition, addTitle, insertSource, overwriteSource, previousFrame, nextFrame, deleteClip, rippleDelete, playReverse, pausePlayback, playForward, exportSequence, exportFCPXML, exportEDL, exportOTIO, toggleRetime, addMarker, previousMarker, nextMarker, previousEdit, nextEdit, toggleScopes,
         goToStart, goToEnd, backTenFrames, forwardTenFrames, goToIn, goToOut, splitAll, trimStartToPlayhead, trimEndToPlayhead,
         nudgeLeft, nudgeRight, toggleClipEnabled, selectClipAtPlayhead, deselectAll, toggleSnapping, zoomIn, zoomOut,
         extendEdit, slipBackward, slipForward, slideLeft, slideRight, liftRange, extractRange, matchFrame
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
        case .extendEdit: "Extend Edit to Playhead"
        case .slipBackward: "Slip Source One Frame Earlier"
        case .slipForward: "Slip Source One Frame Later"
        case .slideLeft: "Slide Clip Left One Frame"
        case .slideRight: "Slide Clip Right One Frame"
        case .liftRange: "Lift In to Out"
        case .extractRange: "Extract In to Out"
        case .matchFrame: "Match Frame"
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
    /// Every command starts with at most this one shortcut; the second slot is the user's.
    var defaultBindings: [ShortcutBinding] { defaultBinding.isEmpty ? [] : [defaultBinding] }
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
        case .extendEdit: ShortcutBinding(key: "e")
        case .slipBackward: ShortcutBinding(key: "left", command: true, option: true)
        case .slipForward: ShortcutBinding(key: "right", command: true, option: true)
        case .slideLeft: ShortcutBinding(key: ",", option: true)
        case .slideRight: ShortcutBinding(key: ".", option: true)
        case .liftRange: ShortcutBinding(key: "z")
        case .extractRange: ShortcutBinding(key: "x")
        case .matchFrame: ShortcutBinding(key: "f")
        }
    }
}


/// Groups commands in the shortcut editor's list and colours them on its keyboard.
nonisolated enum EditorCommandCategory: String, CaseIterable, Identifiable {
    case playback, navigation, marks, editing, trimming, view, project
    var id: String { rawValue }
    var title: String {
        switch self {
        case .playback: "Playback"
        case .navigation: "Navigation"
        case .marks: "Marks & Markers"
        case .editing: "Editing"
        case .trimming: "Trimming"
        case .view: "View"
        case .project: "Project"
        }
    }
}

nonisolated extension EditorCommandID {
    var category: EditorCommandCategory {
        switch self {
        case .togglePlayback, .playReverse, .pausePlayback, .playForward: .playback
        case .previousFrame, .nextFrame, .backTenFrames, .forwardTenFrames, .goToStart, .goToEnd, .goToIn, .goToOut,
             .previousEdit, .nextEdit: .navigation
        case .markSourceIn, .markSourceOut, .clearSourceMarks, .addMarker, .previousMarker, .nextMarker: .marks
        case .appendSource, .insertSource, .overwriteSource, .splitClip, .splitAll, .deleteClip, .rippleDelete, .liftRange,
             .extractRange, .addTransition, .addTitle, .toggleClipEnabled, .selectClipAtPlayhead, .deselectAll, .matchFrame,
             .toggleRetime: .editing
        case .rippleTrimStart, .rippleTrimEnd, .trimStartToPlayhead, .trimEndToPlayhead, .extendEdit, .nudgeLeft, .nudgeRight,
             .slipBackward, .slipForward, .slideLeft, .slideRight: .trimming
        case .toggleViewer, .zoomTimelineToFit, .zoomIn, .zoomOut, .toggleSnapping, .toggleScopes: .view
        case .undo, .redo, .importMedia, .exportSequence, .exportFCPXML, .exportEDL, .exportOTIO: .project
        }
    }
    /// A few words that fit on a key of the shortcut editor's keyboard.
    var shortTitle: String {
        switch self {
        case .togglePlayback: "Play / Pause"
        case .zoomTimelineToFit: "Zoom to Fit"
        case .rippleTrimStart: "Ripple Start"
        case .rippleTrimEnd: "Ripple End"
        case .toggleViewer: "Source / Seq"
        case .undo: "Undo"
        case .redo: "Redo"
        case .importMedia: "Import"
        case .appendSource: "Append"
        case .markSourceIn: "Mark In"
        case .markSourceOut: "Mark Out"
        case .clearSourceMarks: "Clear In/Out"
        case .splitClip: "Split"
        case .addTransition: "Transition"
        case .addTitle: "Title"
        case .insertSource: "Insert"
        case .overwriteSource: "Overwrite"
        case .previousFrame: "Prev Frame"
        case .nextFrame: "Next Frame"
        case .deleteClip: "Delete"
        case .rippleDelete: "Ripple Delete"
        case .playReverse: "Reverse"
        case .pausePlayback: "Pause"
        case .playForward: "Forward"
        case .exportSequence: "Render"
        case .exportFCPXML: "FCPXML"
        case .exportEDL: "EDL"
        case .exportOTIO: "OTIO"
        case .toggleRetime: "Retime"
        case .addMarker: "Marker"
        case .previousMarker: "Prev Marker"
        case .nextMarker: "Next Marker"
        case .previousEdit: "Prev Edit"
        case .nextEdit: "Next Edit"
        case .toggleScopes: "Scopes"
        case .goToStart: "Go to Start"
        case .goToEnd: "Go to End"
        case .backTenFrames: "−10 Frames"
        case .forwardTenFrames: "+10 Frames"
        case .goToIn: "Go to In"
        case .goToOut: "Go to Out"
        case .splitAll: "Split All"
        case .trimStartToPlayhead: "Trim Start"
        case .trimEndToPlayhead: "Trim End"
        case .nudgeLeft: "Nudge ←"
        case .nudgeRight: "Nudge →"
        case .toggleClipEnabled: "Enable Clip"
        case .selectClipAtPlayhead: "Select Clip"
        case .deselectAll: "Deselect"
        case .toggleSnapping: "Snapping"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .extendEdit: "Extend Edit"
        case .slipBackward: "Slip ←"
        case .slipForward: "Slip →"
        case .slideLeft: "Slide ←"
        case .slideRight: "Slide →"
        case .liftRange: "Lift"
        case .extractRange: "Extract"
        case .matchFrame: "Match Frame"
        }
    }
    /// Commands that may use a bare or Shift-only key; editor keys never reach focused text.
    var allowsUnmodifiedKey: Bool {
        [.toggleViewer, .markSourceIn, .markSourceOut, .clearSourceMarks, .zoomTimelineToFit, .rippleTrimStart, .rippleTrimEnd, .insertSource,
         .overwriteSource, .rippleDelete, .deleteClip, .addMarker, .nextMarker, .previousEdit, .nextEdit, .previousFrame, .nextFrame,
         .goToStart, .goToEnd, .backTenFrames, .forwardTenFrames, .goToIn, .goToOut, .toggleClipEnabled, .selectClipAtPlayhead,
         .deselectAll, .toggleSnapping, .extendEdit, .liftRange, .extractRange, .matchFrame].contains(self)
    }
}

nonisolated struct ShortcutModifiers: OptionSet, Hashable {
    let rawValue: Int
    static let control = ShortcutModifiers(rawValue: 1)
    static let option = ShortcutModifiers(rawValue: 2)
    static let shift = ShortcutModifiers(rawValue: 4)
    static let command = ShortcutModifiers(rawValue: 8)
    /// All sixteen combinations, fewest modifiers first.
    static let allCombinations = (0..<16).map(ShortcutModifiers.init(rawValue:))
        .sorted { ($0.rawValue.nonzeroBitCount, $0.rawValue) < ($1.rawValue.nonzeroBitCount, $1.rawValue) }
    /// In the order macOS menus show them.
    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

nonisolated struct ShortcutBinding: Codable, Hashable {
    /// Keys named rather than typed; the text system uses all of them for navigation or entry.
    static let namedKeys = ["left", "right", "up", "down", "home", "end", "pageup", "pagedown", "delete", "return", "escape", "space", "tab"]
    /// Text entry ignores function keys, so any command may use one without modifiers.
    static let functionKeys = (1...12).map { "f\($0)" }
    /// macOS virtual key codes of the keys that have names rather than characters.
    /// Forward delete and keypad enter share the names of delete and return.
    static let keyCodeNames: [UInt16: String] = [
        49: "space", 48: "tab", 51: "delete", 117: "delete", 123: "left", 124: "right", 125: "down", 126: "up", 36: "return", 76: "return",
        53: "escape", 115: "home", 119: "end", 116: "pageup", 121: "pagedown", 122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5",
        97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]
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
    var isFunctionKey: Bool { Self.functionKeys.contains(normalized.key) }
    var modifiers: ShortcutModifiers {
        var result: ShortcutModifiers = []
        if command { result.insert(.command) }
        if option { result.insert(.option) }
        if control { result.insert(.control) }
        if shift { result.insert(.shift) }
        return result
    }
    var keyLabel: String {
        ["left": "←", "right": "→", "up": "↑", "down": "↓", "delete": "⌫", "return": "↩", "escape": "⎋", "space": "Space", "tab": "Tab",
         "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟"][normalized.key] ?? normalized.key.uppercased()
    }
    var display: String { isEmpty ? "None" : modifiers.symbols + keyLabel }
    /// Words a search for this shortcut may use, such as "cmd shift b".
    var searchText: String {
        guard !isEmpty else { return "" }
        let words = [control ? "control ctrl" : "", option ? "option opt alt" : "", shift ? "shift" : "", command ? "command cmd" : ""]
        return (words + [normalized.key, display]).filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }

    /// The binding for a key press, from the key's name or the character it types with
    /// only Shift applied (as `charactersIgnoringModifiers` reports it).
    static func pressed(key: String, modifiers: ShortcutModifiers) -> ShortcutBinding? {
        guard !key.isEmpty else { return nil }
        // "+" is Shift-= on US keyboards and its own key on many others; both mean the = binding (zoom in).
        if key == "+" { return ShortcutBinding(key: "=", modifiers: modifiers.subtracting(.shift)) }
        return ShortcutBinding(key: key, modifiers: modifiers).normalized
    }

    /// Why no command may use this shortcut: macOS and standard application commands keep theirs.
    var reservation: String? {
        let candidate = normalized
        // ⇧⌘W is the scopes shortcut; only plain ⌘W closes the window.
        if candidate.command && !candidate.option && !candidate.control && ["q", "w", "n", "o", "s", "h", "m", ",", "c", "v", "x", "a", "f"].contains(candidate.key)
            && !(candidate.shift && candidate.key == "w") {
            return "This shortcut is reserved for standard application or text commands."
        }
        // Help is ⌘? on every layout: Shift-/ on U.S. keyboards, Shift-+ on Norwegian ones.
        if candidate.command && ((candidate.option && ["h", "m"].contains(candidate.key)) || (candidate.control && candidate.key == "f") || candidate.key == "?") {
            return "This shortcut is reserved for standard application commands."
        }
        // Bare or Shift-Space is the editing convention for transport; other Space chords belong to macOS.
        if (candidate.key == "space" && (candidate.command || candidate.option || candidate.control))
            || (candidate.control && ["left", "right", "up", "down"].contains(candidate.key)) || (candidate.command && candidate.option && candidate.key == "escape") {
            return "This combination is reserved for macOS."
        }
        return nil
    }
    /// The standard command that owns a reserved shortcut, when it has a well-known name.
    var reservedTitle: String? {
        let candidate = normalized
        guard candidate.modifiers == .command else { return nil }
        return ["q": "Quit", "w": "Close Window", "n": "New Project", "o": "Open…", "s": "Save", "h": "Hide", "m": "Minimize",
                ",": "Settings…", "c": "Copy", "v": "Paste", "x": "Cut", "a": "Select All", "f": "Find"][candidate.key]
    }

    /// Why this shortcut cannot run `commandID`, apart from conflicts with other commands.
    func validationError(for commandID: EditorCommandID) -> String? {
        let candidate = normalized
        if candidate.isEmpty { return nil }
        guard Self.namedKeys.contains(candidate.key) || candidate.isFunctionKey
                || (candidate.key.count == 1 && candidate.key.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }) else {
            return "Enter one character, F1–F12, or left, right, up, down, home, end, page up, page down, delete, return, escape, space, or tab."
        }
        guard commandID.isPlayback || commandID.allowsUnmodifiedKey || candidate.isFunctionKey || candidate.command || candidate.option || candidate.control else {
            return "Include Command, Option, or Control to preserve text entry."
        }
        if let reservation = candidate.reservation { return reservation }
        if candidate.key == "space" && !commandID.isPlayback { return "This combination is reserved for macOS." }
        return nil
    }
}

nonisolated extension ShortcutBinding {
    init(key: String, modifiers: ShortcutModifiers) {
        self.init(key: key, command: modifiers.contains(.command), option: modifiers.contains(.option),
                  control: modifiers.contains(.control), shift: modifiers.contains(.shift))
    }
    // Absent modifiers decode as off and are not written, which keeps shared preset files short.
    private enum CodingKeys: String, CodingKey { case key, command, option, control, shift }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try container.decode(String.self, forKey: .key),
                  command: try container.decodeIfPresent(Bool.self, forKey: .command) ?? false,
                  option: try container.decodeIfPresent(Bool.self, forKey: .option) ?? false,
                  control: try container.decodeIfPresent(Bool.self, forKey: .control) ?? false,
                  shift: try container.decodeIfPresent(Bool.self, forKey: .shift) ?? false)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        for (flag, codingKey) in [(command, CodingKeys.command), (option, .option), (control, .control), (shift, .shift)] where flag {
            try container.encode(true, forKey: codingKey)
        }
    }
}

/// Every command's shortcuts: up to two each, the first being the one menus show.
/// A command's shortcuts stay compact, so clearing the first promotes the second.
nonisolated struct Keymap: Equatable {
    static let slotCount = 2
    private var shortcuts: [EditorCommandID: [ShortcutBinding]] = [:]

    static var defaults: Keymap {
        var keymap = Keymap()
        for command in EditorCommandID.allCases { keymap.shortcuts[command] = command.defaultBindings }
        return keymap
    }

    /// The command's first shortcut, or an empty binding.
    subscript(command: EditorCommandID) -> ShortcutBinding { binding(for: command, slot: 0) }
    func bindings(for command: EditorCommandID) -> [ShortcutBinding] { shortcuts[command] ?? [] }
    func binding(for command: EditorCommandID, slot: Int) -> ShortcutBinding {
        let list = bindings(for: command)
        return list.indices.contains(slot) ? list[slot] : ShortcutBinding(key: "")
    }
    /// The command that a shortcut runs, and which of that command's shortcuts it is.
    func assignment(of binding: ShortcutBinding) -> (command: EditorCommandID, slot: Int)? {
        let target = binding.normalized
        guard !target.isEmpty else { return nil }
        for command in EditorCommandID.allCases {
            if let slot = bindings(for: command).firstIndex(of: target) { return (command, slot) }
        }
        return nil
    }
    func command(for binding: ShortcutBinding) -> EditorCommandID? { assignment(of: binding)?.command }
    /// Every assigned shortcut and its command, for lookups across a whole keyboard.
    var commandsByBinding: [ShortcutBinding: EditorCommandID] {
        var result: [ShortcutBinding: EditorCommandID] = [:]
        for command in EditorCommandID.allCases { for binding in bindings(for: command) { result[binding] = command } }
        return result
    }

    /// The other command (or this command's other slot) that already uses `binding`.
    func conflict(for binding: ShortcutBinding, command: EditorCommandID, slot: Int) -> EditorCommandID? {
        guard let found = assignment(of: binding) else { return nil }
        return found.command == command && found.slot == min(slot, bindings(for: command).count) ? nil : found.command
    }
    /// Why `binding` cannot be the command's shortcut in `slot`, including conflicts.
    func validationError(_ binding: ShortcutBinding, for command: EditorCommandID, slot: Int = 0) -> String? {
        if let error = binding.validationError(for: command) { return error }
        if let other = conflict(for: binding, command: command, slot: slot) {
            return other == command ? "Already this command's other shortcut." : "Already assigned to \(other.title)."
        }
        return nil
    }

    /// Sets one shortcut without validation; an empty binding clears the slot, and a
    /// slot past the command's last shortcut adds one.
    mutating func set(_ binding: ShortcutBinding, for command: EditorCommandID, slot: Int) {
        var list = bindings(for: command)
        let value = binding.normalized
        if list.indices.contains(slot) {
            if value.isEmpty { list.remove(at: slot) } else { list[slot] = value }
        } else if !value.isEmpty {
            list.append(value)
        }
        shortcuts[command] = Array(list.prefix(Self.slotCount))
    }
    /// Removes a shortcut from whichever command has it.
    mutating func unassign(_ binding: ShortcutBinding) {
        guard let found = assignment(of: binding) else { return }
        set(ShortcutBinding(key: ""), for: found.command, slot: found.slot)
    }

    /// Every command's shortcuts by command name, unbound commands included.
    var savedForm: [String: [ShortcutBinding]] {
        Dictionary(uniqueKeysWithValues: EditorCommandID.allCases.map { ($0.rawValue, bindings(for: $0)) })
    }
    /// The saved form of only the commands whose shortcuts differ from `base`.
    func changes(from base: Keymap) -> [String: [ShortcutBinding]] {
        savedForm.filter { name, bindings in EditorCommandID(rawValue: name).map { base.bindings(for: $0) != bindings } ?? false }
    }
    /// Rebuilds a keymap from saved choices. Commands absent from `saved` (such as ones
    /// added since it was written) take their defaults unless a saved choice already
    /// uses them; saved shortcuts that are invalid or already in use are left out and counted.
    static func restoring(_ saved: [String: [ShortcutBinding]]) -> (keymap: Keymap, rejected: Int) {
        var keymap = Keymap()
        var rejected = 0
        for command in EditorCommandID.allCases {
            keymap.shortcuts[command] = []
            for binding in saved[command.rawValue] ?? [] where !binding.isEmpty {
                let slot = keymap.bindings(for: command).count
                if slot < slotCount && keymap.validationError(binding, for: command, slot: slot) == nil {
                    keymap.set(binding, for: command, slot: slot)
                } else {
                    rejected += 1
                }
            }
        }
        // New or changed defaults must not erase an existing custom map.
        // Leave such a command unbound if its default is already in use.
        for command in EditorCommandID.allCases where saved[command.rawValue] == nil {
            for binding in command.defaultBindings where keymap.assignment(of: binding) == nil {
                keymap.set(binding, for: command, slot: keymap.bindings(for: command).count)
            }
        }
        return (keymap, rejected)
    }
}
