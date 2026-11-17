import AppKit
import Combine
import EditorCore
import SwiftUI

@MainActor
final class EditorCommandRegistry: ObservableObject {
    @Published private(set) var keymap: Keymap
    /// Saved presets, not counting the built-in default.
    @Published private(set) var presets: [KeyboardPreset]
    /// The preset the keymap was last switched to or saved as; edits since then mark it modified.
    @Published private(set) var activePresetName: String
    private let defaults: UserDefaults
    private static let legacyStorageKey = "editor.keyboardShortcuts.v1"
    private static let storageKey = "editor.keyboardShortcuts.v2"
    private static let presetsKey = "editor.keyboardPresets.v1"
    private static let activePresetKey = "editor.keyboardPresets.active"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: [ShortcutBinding]].self, from: data) {
            keymap = Keymap.restoring(saved).keymap
        } else if let data = defaults.data(forKey: Self.legacyStorageKey),
                  let saved = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            // Maps saved before only changes were stored hold every default of their day;
            // a former default there is not a choice, so the current default replaces it.
            var choices: [String: [ShortcutBinding]] = [:]
            for command in EditorCommandID.allCases {
                if let value = saved[command.rawValue]?.normalized, !command.formerDefaultBindings.contains(value) {
                    choices[command.rawValue] = [value]
                }
            }
            keymap = Keymap.restoring(choices).keymap
        } else {
            keymap = .defaults
        }
        let saved = defaults.data(forKey: Self.presetsKey).flatMap { try? JSONDecoder().decode([KeyboardPreset].self, from: $0) } ?? []
        let active = defaults.string(forKey: Self.activePresetKey) ?? KeyboardPreset.builtInName
        presets = saved
        activePresetName = saved.contains { $0.name == active } ? active : KeyboardPreset.builtInName
    }

    /// The command's first shortcut, or an empty binding.
    func binding(for command: EditorCommandID) -> ShortcutBinding { keymap[command] }
    func bindings(for command: EditorCommandID) -> [ShortcutBinding] { keymap.bindings(for: command) }
    /// The shortcut a menu item shows: the first one menus can deliver without taking keys from text.
    func menuBinding(for command: EditorCommandID) -> ShortcutBinding? { keymap.bindings(for: command).first { $0.isMenuKeyEquivalent } }
    func command(for binding: ShortcutBinding) -> EditorCommandID? { keymap.command(for: binding) }
    func set(_ binding: ShortcutBinding, for command: EditorCommandID, slot: Int = 0) -> String? {
        if let error = keymap.validationError(binding, for: command, slot: slot) { return error }
        keymap.set(binding, for: command, slot: slot)
        persist()
        return nil
    }
    /// Assigns a shortcut that another command holds, removing it from that command.
    func reassign(_ binding: ShortcutBinding, to command: EditorCommandID, slot: Int) -> String? {
        var updated = keymap
        if let other = updated.conflict(for: binding, command: command, slot: slot), other != command { updated.unassign(binding) }
        if let error = updated.validationError(binding, for: command, slot: slot) { return error }
        updated.set(binding, for: command, slot: slot)
        keymap = updated
        persist()
        return nil
    }
    func reset() {
        keymap = .defaults
        activePresetName = KeyboardPreset.builtInName
        for key in [Self.storageKey, Self.legacyStorageKey, Self.activePresetKey] { defaults.removeObject(forKey: key) }
    }
    /// Only changed shortcuts are stored, so later changes to the defaults reach every user.
    private func persist() {
        if let data = try? JSONEncoder().encode(keymap.changes(from: .defaults)) { defaults.set(data, forKey: Self.storageKey) }
        defaults.removeObject(forKey: Self.legacyStorageKey)
        defaults.set(activePresetName, forKey: Self.activePresetKey)
    }

    // MARK: Presets

    func preset(named name: String) -> KeyboardPreset? {
        name == KeyboardPreset.builtInName ? KeyboardPreset(name: name, keymap: .defaults) : presets.first { $0.name == name }
    }
    var isBuiltInPresetActive: Bool { activePresetName == KeyboardPreset.builtInName }
    /// Whether the keymap has changed since its preset was applied or saved.
    var isModified: Bool { preset(named: activePresetName).map { $0.resolved.keymap != keymap } ?? true }
    /// The keymap under the active preset's name, as a file would share it.
    var currentPreset: KeyboardPreset { KeyboardPreset(name: activePresetName, keymap: keymap) }
    /// Switches to a preset, returning how many of its shortcuts this version could not use.
    @discardableResult func applyPreset(named name: String) -> Int {
        guard let preset = preset(named: name) else { return 0 }
        let resolved = preset.resolved
        keymap = resolved.keymap
        activePresetName = name
        persist()
        return resolved.rejected
    }
    /// Saves the keymap under a name, replacing a saved preset of that name, and makes it active.
    func savePreset(named proposedName: String) -> String? {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Enter a name for the preset." }
        guard name != KeyboardPreset.builtInName else { return "The built-in preset cannot be replaced. Choose another name." }
        let preset = KeyboardPreset(name: name, keymap: keymap)
        if let index = presets.firstIndex(where: { $0.name == name }) { presets[index] = preset } else { presets.append(preset) }
        activePresetName = name
        persistPresets()
        return nil
    }
    func renamePreset(_ oldName: String, to proposedName: String) -> String? {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = presets.firstIndex(where: { $0.name == oldName }) else { return "Only saved presets can be renamed." }
        guard !name.isEmpty else { return "Enter a name for the preset." }
        guard name == oldName || preset(named: name) == nil else { return "A preset named \u{201C}\(name)\u{201D} already exists." }
        presets[index].name = name
        if activePresetName == oldName { activePresetName = name }
        persistPresets()
        return nil
    }
    func deletePreset(named name: String) {
        presets.removeAll { $0.name == name }
        if activePresetName == name { activePresetName = KeyboardPreset.builtInName }
        persistPresets()
    }
    /// Adds a shared preset, renamed if its name is taken, and switches to it.
    func importPreset(_ preset: KeyboardPreset) -> (name: String, rejected: Int) {
        var imported = preset
        var suffix = 2
        while self.preset(named: imported.name) != nil {
            imported.name = "\(preset.name) \(suffix)"
            suffix += 1
        }
        presets.append(imported)
        persistPresets()
        return (imported.name, applyPreset(named: imported.name))
    }
    private func persistPresets() {
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Self.presetsKey) }
        persist()
    }

    /// `shortcut` is the key that triggered the command; without one, the menu's shortcut applies.
    func perform(_ command: EditorCommandID, store: EditorStore?, scope: EditorCommandScope, shortcut: ShortcutBinding? = nil) {
        guard let store else { return }
        // Menu validation can be stale; recheck at the moment of the action.
        guard Self.isEditingText || isEnabled(command, store: store, scope: scope, shortcut: shortcut) else { NSSound.beep(); return }
        if Self.isEditingText {
            if command == .undo { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
            if command == .redo { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            if command == .undo || command == .redo || !allowsDuringTextEditing(command, shortcut: shortcut) { return }
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
        case .markSourceIn: store.showSequenceMonitor ? store.markSequence(inPoint: true) : store.markSource(inPoint: true)
        case .markSourceOut: store.showSequenceMonitor ? store.markSequence(inPoint: false) : store.markSource(inPoint: false)
        case .clearSourceMarks: store.showSequenceMonitor ? store.clearSequenceMarks() : store.clearSourceMarks()
        case .goToIn: store.goToMark(inPoint: true)
        case .goToOut: store.goToMark(inPoint: false)
        case .splitClip: store.splitSelectedClip()
        case .addTransition: store.addTransitionAtPlayhead()
        case .addTitle: store.addTitle()
        case .insertSource: store.placeSelectedSourceAtPlayhead(mode: .insert)
        case .overwriteSource: store.placeSelectedSourceAtPlayhead(mode: .overwrite)
        case .rippleDelete: store.rippleDeleteSelectedClip()
        case .previousFrame: store.stepActiveViewer(frames: -1)
        case .nextFrame: store.stepActiveViewer(frames: 1)
        case .backTenFrames: store.stepActiveViewer(frames: -10)
        case .forwardTenFrames: store.stepActiveViewer(frames: 10)
        case .goToStart: store.goToActiveViewerEnd(start: true)
        case .goToEnd: store.goToActiveViewerEnd(start: false)
        case .splitAll: store.splitAllAtPlayhead()
        case .trimStartToPlayhead: store.trimSelectedClipToPlayhead(edge: .leading)
        case .trimEndToPlayhead: store.trimSelectedClipToPlayhead(edge: .trailing)
        case .nudgeLeft: store.nudgeSelectedClip(frames: -1)
        case .nudgeRight: store.nudgeSelectedClip(frames: 1)
        case .toggleClipEnabled: store.toggleSelectedClipEnabled()
        case .selectClipAtPlayhead: store.selectClipAtPlayhead()
        case .deselectAll: store.deselectTimeline()
        case .toggleSnapping: store.toggleSnapping()
        case .zoomIn: store.timelineZoomRequest = .init(factor: 1.5)
        case .zoomOut: store.timelineZoomRequest = .init(factor: 1 / 1.5)
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
        case .extendEdit: store.extendEditToPlayhead()
        case .slipBackward: store.slipSelectedClip(frames: -1)
        case .slipForward: store.slipSelectedClip(frames: 1)
        case .slideLeft: store.slideSelectedClip(frames: -1)
        case .slideRight: store.slideSelectedClip(frames: 1)
        case .liftRange: store.liftSequenceRange(closingGap: false)
        case .extractRange: store.liftSequenceRange(closingGap: true)
        case .matchFrame: store.matchFrame()
        case .toggleScopes: UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "workspace.showScopes"), forKey: "workspace.showScopes")
        }
    }
    func isEnabled(_ command: EditorCommandID, store: EditorStore?, scope: EditorCommandScope, shortcut: ShortcutBinding? = nil) -> Bool {
        guard let store else { return false }
        if Self.isEditingText && !allowsDuringTextEditing(command, shortcut: shortcut) { return command == .undo || command == .redo }
        guard command.isPlayback || scope == .document || command.scope == .document || scope == command.scope else { return false }
        switch command {
        case .zoomTimelineToFit: return store.duration > 0
        case .rippleTrimStart, .rippleTrimEnd: return store.canRippleTrimSelectedClip
        case .toggleViewer, .toggleScopes: return true
        case .undo: return store.canUndo
        case .redo: return store.canRedo
        case .importMedia: return !store.isImporting
        case .appendSource: return store.selectedAsset != nil && !store.isImporting
        case .markSourceIn, .markSourceOut:
            if store.showSequenceMonitor { return store.duration > 0 }
            return store.sourcePlayback != nil || store.pendingSourceTransport != nil
        case .clearSourceMarks:
            if store.showSequenceMonitor { return store.sequenceMarks[store.project.sequenceID] != nil }
            return store.selectedAssetID.map { store.sourceRanges[$0] != nil } ?? false
        case .goToIn, .goToOut:
            if store.showSequenceMonitor { return store.sequenceMarks[store.project.sequenceID] != nil }
            return store.sourcePlayback != nil && store.selectedSourceRange != nil
        case .previousFrame, .nextFrame, .backTenFrames, .forwardTenFrames, .goToStart, .goToEnd, .toggleSnapping: return true
        case .zoomIn, .zoomOut: return UserDefaults.standard.object(forKey: "workspace.showTimeline") as? Bool ?? true
        case .splitAll, .selectClipAtPlayhead: return store.project.tracks.contains { !$0.clips.isEmpty }
        case .trimStartToPlayhead, .trimEndToPlayhead: return store.canRippleTrimSelectedClip
        case .nudgeLeft, .nudgeRight, .toggleClipEnabled: return store.selectedClip != nil
        case .extendEdit: return store.canExtendEditToPlayhead
        case .slipBackward, .slipForward: return store.selectedClip.map { $0.selection != .still } ?? false
        case .slideLeft, .slideRight: return store.selectedClip != nil
        case .liftRange, .extractRange: return store.canLiftSequenceRange
        case .matchFrame: return store.matchFrameClip != nil
        case .deselectAll: return store.selectedClipID != nil || store.selectedMarkerID != nil
        case .splitClip, .deleteClip, .addTransition, .rippleDelete: return store.selectedClip != nil
        case .toggleRetime: return store.retimeMode || (store.selectedClip.map { $0.selection != .still } ?? false)
        case .insertSource, .overwriteSource: return store.selectedAsset != nil && !store.isImporting
        case .addTitle, .addMarker: return true
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
    /// Command/Control chords that have no text-editing meaning, and function keys, stay
    /// available while a field is focused; bare keys, deletion and arrow navigation belong to the text.
    private func allowsDuringTextEditing(_ command: EditorCommandID, shortcut: ShortcutBinding?) -> Bool {
        guard command != .undo, command != .redo else { return false }
        return (shortcut ?? menuBinding(for: command))?.isMenuKeyEquivalent ?? false
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
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        case let key where isFunctionKey:
            // AppKit's private-use characters for F1–F12 start at NSF1FunctionKey.
            return Int(key.dropFirst()).flatMap { UnicodeScalar(NSF1FunctionKey + $0 - 1) }.map { KeyEquivalent(Character($0)) }
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
        case "d" where store.selectedClip != nil && registry?.command(for: pressed) == nil:
            store.duplicateSelectedClip()
        case "v" where store.clipboard != nil: store.pasteAtPlayhead()
        default: return false
        }
        return true
    }

    static func binding(for event: NSEvent) -> ShortcutBinding? {
        guard let key = ShortcutBinding.keyCodeNames[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() else { return nil }
        return ShortcutBinding.pressed(key: key, modifiers: ShortcutModifiers(event.modifierFlags))
    }

    /// Commands that a focused text field needs are left to the text system.
    private func handle(_ event: NSEvent) -> Bool {
        guard let registry, let window = event.window, let store = stores.object(forKey: window),
              window.attachedSheet == nil, let pressed = Self.binding(for: event) else { return false }
        if handleClipboard(pressed, store: store, window: window) { return true }
        // A focused list (the media bin) moves its selection with the arrow keys.
        if window.firstResponder is NSTableView, ["up", "down", "left", "right"].contains(pressed.key),
           !pressed.command, !pressed.option, !pressed.control { return false }
        guard let command = registry.command(for: pressed) else { return false }
        if event.isARepeat && command == .togglePlayback { return true }
        // Source-only commands follow the visible viewer; everything else is document-wide.
        let scope: EditorCommandScope = command.scope == .source && store.showSequenceMonitor ? .timeline : .document
        guard registry.isEnabled(command, store: store, scope: scope, shortcut: pressed) else { return false }
        registry.perform(command, store: store, scope: scope, shortcut: pressed)
        return true
    }
}

extension ShortcutBinding {
    /// Menu key equivalents are kept only for chords that never conflict with text entry;
    /// all other shortcuts are delivered by EditorKeyboardRouter at key-press time.
    var isMenuKeyEquivalent: Bool {
        let shortcut = normalized
        return shortcut.isFunctionKey || ((shortcut.command || shortcut.control) && !ShortcutBinding.namedKeys.contains(shortcut.key))
    }
}

extension ShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.shift) { insert(.shift) }
    }
}
