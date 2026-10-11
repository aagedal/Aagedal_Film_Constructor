import AppKit
import Combine
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
            for command in EditorCommandID.allCases {
                if let value = saved[command.rawValue] { resolved[command] = value.normalized }
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
    private func persist() {
        let saved = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.storageKey) }
    }
    func perform(_ command: EditorCommandID, store: EditorStore?, scope: EditorCommandScope) {
        guard let store else { return }
        if Self.isEditingText {
            if command == .undo { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
            if command == .redo { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            return
        }
        guard scope == .document || command.scope == .document || scope == command.scope else { return }
        switch command {
        case .undo: store.undo()
        case .redo: store.redo()
        case .importMedia: store.importMedia()
        case .appendSource: store.appendSelectedAsset()
        case .splitClip: store.splitSelectedClip()
        case .previousFrame: store.stepPlayhead(frames: -1)
        case .nextFrame: store.stepPlayhead(frames: 1)
        case .deleteClip: store.deleteSelectedClip()
        }
    }
    func isEnabled(_ command: EditorCommandID, store: EditorStore?, scope: EditorCommandScope) -> Bool {
        guard let store else { return false }
        if Self.isEditingText { return command == .undo || command == .redo }
        guard scope == .document || command.scope == .document || scope == command.scope else { return false }
        switch command {
        case .undo: return store.canUndo
        case .redo: return store.canRedo
        case .importMedia: return !store.isImporting
        case .appendSource: return store.selectedAsset != nil && !store.isImporting
        case .splitClip, .deleteClip: return store.selectedClip != nil
        case .previousFrame, .nextFrame: return true
        }
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
