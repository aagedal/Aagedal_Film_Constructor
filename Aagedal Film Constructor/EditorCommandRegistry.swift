import AppKit
import Combine
import EditorCore
import SwiftUI

@MainActor
final class EditorCommandRegistry: ObservableObject {
    @Published private(set) var bindings: [EditorCommandID: ShortcutBinding]
    private let defaults: UserDefaults
    private static let storageKey = "editor.keyboardShortcuts.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var resolved = Dictionary(uniqueKeysWithValues: EditorCommandID.allCases.map { ($0, $0.defaultBinding) })
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            // Maps saved before only changes were stored hold every default of their day;
            // a former default there is not a choice, so the current default replaces it.
            var custom: Set<EditorCommandID> = []
            for command in EditorCommandID.allCases {
                if let value = saved[command.rawValue]?.normalized, !command.formerDefaultBindings.contains(value) {
                    resolved[command] = value
                    custom.insert(command)
                }
            }
            // New or changed defaults must not erase an existing custom map.
            // Leave such a command unbound if its default is already in use.
            for command in EditorCommandID.allCases where !custom.contains(command) {
                let binding = resolved[command]!
                if !binding.isEmpty && custom.contains(where: { $0 != command && resolved[$0] == binding }) {
                    resolved[command] = ShortcutBinding(key: "")
                }
            }
            // Validate the complete restored map, including conflicts with defaults.
            if EditorCommandID.allCases.contains(where: { resolved[$0]?.validationError(for: $0, bindings: resolved) != nil }) {
                resolved = Dictionary(uniqueKeysWithValues: EditorCommandID.allCases.map { ($0, $0.defaultBinding) })
            }
        }
        bindings = resolved
    }

    func binding(for command: EditorCommandID) -> ShortcutBinding { bindings[command] ?? command.defaultBinding }
    func set(_ binding: ShortcutBinding, for command: EditorCommandID) -> String? {
        if let error = binding.validationError(for: command, bindings: bindings) { return error }
        bindings[command] = binding.normalized
        persist()
        return nil
    }
    func reset() {
        bindings = Dictionary(uniqueKeysWithValues: EditorCommandID.allCases.map { ($0, $0.defaultBinding) })
        defaults.removeObject(forKey: Self.storageKey)
    }
    /// Only changed shortcuts are stored, so later changes to the defaults reach every user.
    private func persist() {
        let saved = Dictionary(uniqueKeysWithValues: bindings.filter { $0.value != $0.key.defaultBinding }.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.storageKey) }
    }
    func perform(_ command: EditorCommandID, store: EditorStore?, scope: EditorCommandScope) {
        guard let store else { return }
        // Menu validation can be stale; recheck at the moment of the action.
        guard Self.isEditingText || isEnabled(command, store: store, scope: scope) else { NSSound.beep(); return }
        if Self.isEditingText {
            if command == .undo { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
            if command == .redo { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            if command == .undo || command == .redo || !allowsDuringTextEditing(command) { return }
        }
        guard command.isPlayback || scope == .document || command.scope == .document || scope == command.scope else { return }
        switch command {
        case .togglePlayback:
            if let sequence = store.sequencePlayback {
                if sequence.isPlaying || sequence.reverseSpeed != nil { sequence.pause() } else { sequence.play() }
            } else { store.toggleSourcePlayback() }
        case .zoomTimelineToFit: store.timelineFitRequest = UUID()
        case .rippleTrimStart: store.rippleTrimSelectedClip(edge: .leading)
        case .rippleTrimEnd: store.rippleTrimSelectedClip(edge: .trailing)
        case .toggleViewer: store.toggleViewer()
        case .undo: store.undo()
        case .redo: store.redo()
        case .importMedia: store.importMedia()
        case .appendSource: store.appendSelectedAsset()
        case .markSourceIn: store.markSource(inPoint: true)
        case .markSourceOut: store.markSource(inPoint: false)
        case .clearSourceMarks: store.clearSourceMarks()
        case .splitClip: store.splitSelectedClip()
        case .addTransition: store.addTransitionAtPlayhead()
        case .addTitle: store.addTitle()
        case .insertSource: store.placeSelectedSourceAtPlayhead(mode: .insert)
        case .overwriteSource: store.placeSelectedSourceAtPlayhead(mode: .overwrite)
        case .rippleDelete: store.rippleDeleteSelectedClip()
        case .previousFrame: store.stepPlayhead(frames: -1)
        case .nextFrame: store.stepPlayhead(frames: 1)
        case .deleteClip: store.deleteSelectedClip()
        case .playReverse:
            if let sequence = store.sequencePlayback { sequence.playReverse() } else { store.playSourceBackwards() }
        case .pausePlayback:
            if let sequence = store.sequencePlayback { sequence.pause() } else { store.pauseSource() }
        case .playForward:
            if let sequence = store.sequencePlayback { sequence.play() } else { store.playSourceForwards() }
        case .exportSequence: store.beginRenderExport()
        case .exportFCPXML: store.exportFCPXML()
        case .exportEDL: store.beginEDLExport()
        case .exportOTIO: store.exportOTIO()
        case .toggleRetime: store.toggleRetimeMode()
        case .addMarker: store.addMarkerAtPlayhead()
        case .previousMarker: store.jumpToMarker(forward: false)
        case .nextMarker: store.jumpToMarker(forward: true)
        case .previousEdit: store.jumpToEditPoint(forward: false)
        case .nextEdit: store.jumpToEditPoint(forward: true)
        }
    }
    func isEnabled(_ command: EditorCommandID, store: EditorStore?, scope: EditorCommandScope) -> Bool {
        guard let store else { return false }
        if Self.isEditingText && !allowsDuringTextEditing(command) { return command == .undo || command == .redo }
        guard command.isPlayback || scope == .document || command.scope == .document || scope == command.scope else { return false }
        switch command {
        case .zoomTimelineToFit: return store.duration > 0
        case .rippleTrimStart, .rippleTrimEnd: return store.canRippleTrimSelectedClip
        case .toggleViewer: return true
        case .undo: return store.canUndo
        case .redo: return store.canRedo
        case .importMedia: return !store.isImporting
        case .appendSource: return store.selectedAsset != nil && !store.isImporting
        case .markSourceIn, .markSourceOut: return store.sourcePlayback != nil || store.pendingSourceTransport != nil
        case .clearSourceMarks: return store.selectedAssetID.map { store.sourceRanges[$0] != nil } ?? false
        case .splitClip, .deleteClip, .addTransition, .rippleDelete: return store.selectedClip != nil
        case .toggleRetime: return store.retimeMode || (store.selectedClip.map { $0.selection != .still } ?? false)
        case .insertSource, .overwriteSource: return store.selectedAsset != nil && !store.isImporting
        case .previousFrame, .nextFrame, .addTitle, .addMarker: return true
        case .previousMarker, .nextMarker: return !store.project.markers.isEmpty
        case .previousEdit, .nextEdit: return store.project.tracks.contains { !$0.clips.isEmpty }
        case .playReverse:
            if let sequence = store.sequencePlayback { return sequence.available && !sequence.isPreparing && store.duration > 0 }
            return store.sourcePlayback != nil
        case .togglePlayback:
            if let sequence = store.sequencePlayback { return sequence.available && (sequence.isPlaying || sequence.reverseSpeed != nil || (!sequence.isPreparing && store.duration > 0)) }
            return store.canControlSourceTransport
        case .pausePlayback:
            if let sequence = store.sequencePlayback { return sequence.available }
            return store.canControlSourceTransport
        case .playForward:
            if let sequence = store.sequencePlayback { return sequence.available && !sequence.isPreparing && store.duration > 0 }
            return store.canControlSourceTransport
        case .exportSequence, .exportFCPXML, .exportEDL, .exportOTIO: return store.duration > 0 && store.renderExportDraft == nil && store.edlExportDraft == nil && store.audioAppendAsset == nil
        }
    }
    /// Command/Control chords that have no text-editing meaning stay available while a
    /// field is focused; bare keys, deletion and arrow navigation belong to the text.
    private func allowsDuringTextEditing(_ command: EditorCommandID) -> Bool {
        let shortcut = binding(for: command).normalized
        guard command != .undo, command != .redo, shortcut.command || shortcut.control else { return false }
        return !["delete", "left", "right", "up", "down", "return", "escape", "tab", "space"].contains(shortcut.key)
    }
    private static var isEditingText: Bool { NSApp?.keyWindow?.firstResponder is NSTextView }
}

private struct EditorCommandScopeKey: FocusedValueKey { typealias Value = EditorCommandScope }
extension FocusedValues {
    var editorCommandScope: EditorCommandScope? {
        get { self[EditorCommandScopeKey.self] }
        set { self[EditorCommandScopeKey.self] = newValue }
    }
}

extension ShortcutBinding {
    var keyEquivalent: KeyEquivalent? {
        guard !isEmpty else { return nil }
        switch normalized.key {
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        case "delete": return .delete
        case "return": return .return
        case "escape": return .escape
        case "space": return .space
        case "tab": return .tab
        default: return normalized.key.first.map { KeyEquivalent($0) }
        }
    }
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if command { result.insert(.command) }
        if option { result.insert(.option) }
        if control { result.insert(.control) }
        if shift { result.insert(.shift) }
        return result
    }
}

/// Routes editor shortcuts at key-press time. Menu validation is only refreshed when
/// SwiftUI re-renders the command menus, so it can be stale after edits or focus
/// changes. The router reads the key window's own store, text focus and command
/// state for each event, then consumes the key only when a command runs.
@MainActor
final class EditorKeyboardRouter {
    static let shared = EditorKeyboardRouter()
    private(set) var registry: EditorCommandRegistry?
    private var monitor: Any?
    private let stores = NSMapTable<NSWindow, EditorStore>.weakToWeakObjects()

    func install(registry: EditorCommandRegistry) {
        self.registry = registry
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { EditorKeyboardRouter.shared.handle(event) ? nil : event }
        }
    }
    func register(window: NSWindow, store: EditorStore) { stores.setObject(store, forKey: window) }
    func store(for window: NSWindow?) -> EditorStore? { window.flatMap { stores.object(forKey: $0) } }

    /// ⌘X/⌘C/⌘V/⌘D act on timeline clips unless text has focus. Handled here rather than
    /// only by the menu, whose enablement and focused store can be stale.
    private func handleClipboard(_ pressed: ShortcutBinding, store: EditorStore, window: NSWindow) -> Bool {
        guard pressed.command, !pressed.option, !pressed.control, !pressed.shift,
              !(window.firstResponder is NSText) else { return false }
        switch pressed.key {
        case "c" where store.selectedClip != nil: store.copySelectedClip()
        case "x" where store.selectedClip != nil: store.cutSelectedClip()
        case "d" where store.selectedClip != nil && !EditorCommandID.allCases.contains(where: { registry?.binding(for: $0) == pressed }):
            store.duplicateSelectedClip()
        case "v" where store.clipboard != nil: store.pasteAtPlayhead()
        default: return false
        }
        return true
    }

    static func binding(for event: NSEvent) -> ShortcutBinding? {
        let named: [UInt16: String] = [49: "space", 48: "tab", 51: "delete", 117: "delete", 123: "left", 124: "right",
                                       125: "down", 126: "up", 36: "return", 76: "return", 53: "escape"]
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let key = named[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else { return nil }
        return ShortcutBinding(key: key, command: flags.contains(.command), option: flags.contains(.option),
                               control: flags.contains(.control), shift: flags.contains(.shift)).normalized
    }

    /// Commands that a focused text field needs are left to the text system.
    private func handle(_ event: NSEvent) -> Bool {
        guard let registry, let window = event.window, let store = stores.object(forKey: window),
              window.attachedSheet == nil, let pressed = Self.binding(for: event) else { return false }
        if handleClipboard(pressed, store: store, window: window) { return true }
        // A focused list (the media bin) moves its selection with the arrow keys.
        if window.firstResponder is NSTableView, ["up", "down", "left", "right"].contains(pressed.key),
           !pressed.command, !pressed.option, !pressed.control { return false }
        guard let command = EditorCommandID.allCases.first(where: { registry.binding(for: $0) == pressed && !registry.binding(for: $0).isEmpty })
        else { return false }
        if event.isARepeat && command == .togglePlayback { return true }
        // Source-only commands follow the visible viewer; everything else is document-wide.
        let scope: EditorCommandScope = command.scope == .source && store.showSequenceMonitor ? .timeline : .document
        guard registry.isEnabled(command, store: store, scope: scope) else { return false }
        registry.perform(command, store: store, scope: scope)
        return true
    }
}

extension ShortcutBinding {
    /// Menu key equivalents are kept only for chords that never conflict with text entry;
    /// all other shortcuts are delivered by EditorKeyboardRouter at key-press time.
    var isMenuKeyEquivalent: Bool {
        let shortcut = normalized
        return (shortcut.command || shortcut.control)
            && !["delete", "left", "right", "up", "down", "return", "escape", "tab", "space"].contains(shortcut.key)
    }
}
