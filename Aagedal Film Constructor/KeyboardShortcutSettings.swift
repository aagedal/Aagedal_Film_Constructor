import AppKit
import Carbon.HIToolbox
import Combine
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// The keyboard shortcut editor: an on-screen keyboard showing what each key does with
/// each modifier combination, a searchable command list with two shortcuts per command,
/// and presets that can be saved, switched, and shared as files.
struct KeyboardShortcutSettings: View {
    @ObservedObject var registry: EditorCommandRegistry
    @StateObject private var recorder = ShortcutRecorder()
    @State private var layout = VirtualKeyboardLayout.current()
    /// Modifier keys clicked on the on-screen keyboard; held modifiers take precedence.
    @State private var clickedModifiers: ShortcutModifiers = []
    @State private var selectedKeyID: VirtualKey.ID?
    @State private var selectedCommandID: EditorCommandID.ID? = EditorCommandID.splitClip.id
    @State private var search = ""
    @State private var category: EditorCommandCategory?
    @State private var filter = AssignmentFilter.all
    @State private var status: Status?
    @State private var pendingReassignment: Assignment?
    @State private var pendingDiscard: PresetAction?
    @State private var namePrompt: NamePrompt?
    @State private var proposedName = ""
    @State private var confirmDelete = false

    private var layer: ShortcutModifiers { recorder.heldModifiers.isEmpty ? clickedModifiers : recorder.heldModifiers }
    private var selectedKey: VirtualKey? { layout.key(id: selectedKeyID) }
    private var selectedCommand: EditorCommandID? {
        get { selectedCommandID.flatMap(EditorCommandID.init(rawValue:)) }
        nonmutating set { selectedCommandID = newValue?.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            presetBar
            VirtualKeyboardView(layout: layout, commands: registry.keymap.commandsByBinding, layer: layer,
                                selectedKeyID: selectedKeyID, highlightedKeyIDs: highlightedKeyIDs,
                                select: { selectedKeyID = $0.id },
                                toggleModifier: { clickedModifiers.formSymmetricDifference($0) },
                                drop: dropCommand)
                .frame(maxWidth: .infinity)
            legend
            HStack(alignment: .top, spacing: 14) {
                commandList
                KeyDetailView(key: selectedKey, keymap: registry.keymap, layer: layer, selectedCommand: selectedCommand,
                              assign: { binding in selectedCommand.map { assign(binding, to: $0, slot: nil) } },
                              remove: { binding in remove(binding) },
                              selectCommand: { selectedCommand = $0 })
                    .frame(width: 310)
            }
            statusLine
        }
        .padding(20)
        .frame(minWidth: 1000, idealWidth: 1040, minHeight: 780, idealHeight: 820)
        .onAppear {
            recorder.install()
            recorder.record = { binding, target in assign(binding, to: target.command, slot: target.slot) }
        }
        .onDisappear { recorder.uninstall() }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))) { _ in
            layout = .current()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension == KeyboardPreset.fileExtension }) else { return false }
            importPreset(from: url)
            return true
        }
        .confirmationDialog(pendingReassignment.map { "\($0.binding.display) is assigned to \($0.current.title)." } ?? "",
                            isPresented: Binding(get: { pendingReassignment != nil }, set: { if !$0 { pendingReassignment = nil } }),
                            presenting: pendingReassignment) { pending in
            Button("Reassign to \(pending.command.title)") {
                if let error = registry.reassign(pending.binding, to: pending.command, slot: pending.slot) {
                    status = .error(error)
                } else {
                    status = .info("\(pending.binding.display) now runs \(pending.command.title); \(pending.current.title) no longer has it.")
                    selectedKeyID = layout.key(for: pending.binding)?.id ?? selectedKeyID
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("Reassigning removes the shortcut from \(pending.current.title).")
        }
        .confirmationDialog("Discard the changes to “\(registry.activePresetName)”?",
                            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
                            presenting: pendingDiscard) { action in
            Button("Discard Changes", role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your current shortcuts have not been saved to a preset. Use Save As to keep them.")
        }
        .confirmationDialog("Delete the preset “\(registry.activePresetName)”?", isPresented: $confirmDelete) {
            Button("Delete Preset", role: .destructive) {
                let name = registry.activePresetName
                registry.deletePreset(named: name)
                status = .info("Deleted “\(name)”. Your current shortcuts are unchanged.")
            }
        } message: {
            Text("The current shortcuts stay as they are. Exported copies of the preset are not affected.")
        }
        .alert(namePrompt?.title ?? "", isPresented: Binding(get: { namePrompt != nil }, set: { if !$0 { namePrompt = nil } }),
               presenting: namePrompt) { prompt in
            TextField("Preset name", text: $proposedName)
            Button(prompt == .rename ? "Rename" : "Save") { submitName(prompt) }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(prompt == .rename ? "Enter a new name for this preset." : "Save the current shortcuts as a new preset.")
        }
    }

    // MARK: Presets

    private var presetBar: some View {
        HStack(spacing: 10) {
            Text("Preset").foregroundStyle(.secondary)
            Picker("Preset", selection: Binding(get: { registry.activePresetName }, set: { name in
                guard name != registry.activePresetName else { return }
                confirmingDiscard(.switchTo(name))
            })) {
                Text(KeyboardPreset.builtInName).tag(KeyboardPreset.builtInName)
                if !registry.presets.isEmpty { Divider() }
                ForEach(registry.presets) { Text($0.name).tag($0.name) }
            }
            .labelsHidden()
            .frame(width: 240)
            if registry.isModified {
                Text("Modified")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .help("The shortcuts differ from the saved preset.")
            }
            Spacer()
            Button("Save") {
                if let error = registry.savePreset(named: registry.activePresetName) { status = .error(error) }
                else { status = .info("Saved “\(registry.activePresetName)”.") }
            }
            .disabled(registry.isBuiltInPresetActive || !registry.isModified)
            .help(registry.isBuiltInPresetActive ? "The built-in preset cannot be changed; use Save As." : "Save the changes to this preset.")
            Button("Save As…") { prompt(.saveAs) }
            Divider().frame(height: 18)
            Button("Import…", action: chooseImport)
                .help("Add a preset from a .\(KeyboardPreset.fileExtension) file. You can also drop the file on this window.")
            Button("Export…", action: export)
                .help("Save the current shortcuts as a .\(KeyboardPreset.fileExtension) file to share.")
            if let data = try? registry.currentPreset.fileData() {
                ShareLink(item: KeyboardPresetShareItem(name: registry.activePresetName, data: data),
                          preview: SharePreview(registry.activePresetName, image: Image(systemName: "keyboard"))) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Share the current shortcuts as a preset file.")
            }
            Menu {
                Button("Rename…") { prompt(.rename) }.disabled(registry.isBuiltInPresetActive)
                Button("Delete…") { confirmDelete = true }.disabled(registry.isBuiltInPresetActive)
                Divider()
                Button("Revert to Saved Preset") { confirmingDiscard(.switchTo(registry.activePresetName)) }.disabled(!registry.isModified)
                Button("Reset to Defaults") { confirmingDiscard(.switchTo(KeyboardPreset.builtInName)) }
                    .disabled(registry.isBuiltInPresetActive && !registry.isModified)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private enum PresetAction { case switchTo(String), importPreset(KeyboardPreset) }
    private enum NamePrompt: Equatable {
        case saveAs, rename
        var title: String { self == .saveAs ? "Save Preset As" : "Rename Preset" }
    }

    private func confirmingDiscard(_ action: PresetAction) {
        // A modified built-in map is still recoverable from its defaults, so only saved presets need care.
        if registry.isModified { pendingDiscard = action } else { perform(action) }
    }
    private func perform(_ action: PresetAction) {
        switch action {
        case let .switchTo(name):
            let rejected = registry.applyPreset(named: name)
            status = .info("Switched to “\(name)”." + Self.skippedNote(rejected))
        case let .importPreset(preset):
            let result = registry.importPreset(preset)
            status = .info("Imported “\(result.name)”." + Self.skippedNote(result.rejected))
        }
    }
    private static func skippedNote(_ rejected: Int) -> String {
        rejected == 0 ? "" : " \(rejected) shortcut\(rejected == 1 ? " was" : "s were") skipped because they are reserved or duplicated."
    }
    private func prompt(_ prompt: NamePrompt) {
        proposedName = prompt == .rename || !registry.isBuiltInPresetActive ? registry.activePresetName : "My Shortcuts"
        if prompt == .saveAs, registry.preset(named: proposedName) != nil { proposedName += " Copy" }
        namePrompt = prompt
    }
    private func submitName(_ prompt: NamePrompt) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch prompt {
        case .saveAs:
            if name != registry.activePresetName, registry.preset(named: name) != nil {
                status = .error("A preset named “\(name)” already exists. Choose it and use Save, or pick another name.")
            } else if let error = registry.savePreset(named: name) {
                status = .error(error)
            } else {
                status = .info("Saved “\(name)”.")
            }
        case .rename:
            let oldName = registry.activePresetName
            if let error = registry.renamePreset(oldName, to: name) { status = .error(error) }
            else { status = .info("Renamed “\(oldName)” to “\(name)”.") }
        }
    }
    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Keyboard Preset"
        panel.allowedContentTypes = [.filmConstructorKeyboardPreset, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importPreset(from: url)
    }
    private func importPreset(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { confirmingDiscard(.importPreset(try KeyboardPreset(fileData: Data(contentsOf: url)))) }
        catch { status = .error("Could not import \(url.lastPathComponent): \(error.localizedDescription)") }
    }
    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export Keyboard Preset"
        panel.nameFieldStringValue = KeyboardPresetShareItem.fileName(for: registry.activePresetName)
        panel.allowedContentTypes = [.filmConstructorKeyboardPreset]
        panel.message = "Anyone with Film Constructor can import this file in Settings → Keyboard Shortcuts."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try registry.currentPreset.fileData().write(to: url, options: .atomic)
            status = .info("Exported \(url.lastPathComponent).")
        } catch { status = .error("Could not export the preset: \(error.localizedDescription)") }
    }

    // MARK: Keyboard

    /// Keys holding any shortcut of the selected command, in any modifier layer.
    private var highlightedKeyIDs: Set<VirtualKey.ID> {
        guard let selectedCommand else { return [] }
        return Set(registry.bindings(for: selectedCommand).flatMap { binding in layout.keys.filter { $0.binding(with: binding.modifiers) == binding }.map(\.id) })
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(EditorCommandCategory.allCases) { category in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(category.color).frame(width: 10, height: 10)
                    Text(category.title)
                }
            }
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.35)).frame(width: 10, height: 10)
                Text("Reserved")
            }
            Spacer()
            Text(layer.isEmpty ? "Showing keys without modifiers" : "Showing \(layer.symbols) shortcuts")
                .foregroundStyle(layer.isEmpty ? Color.secondary : Color.accentColor)
            Text("· \(layout.inputSourceName)").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func dropCommand(_ command: EditorCommandID, on key: VirtualKey) -> Bool {
        guard let binding = key.binding(with: layer) else { return false }
        selectedKeyID = key.id
        selectedCommand = command
        assign(binding, to: command, slot: nil)
        return true
    }

    // MARK: Commands

    private enum AssignmentFilter: String, CaseIterable, Identifiable {
        case all = "All", assigned = "Assigned", unassigned = "Unassigned", changed = "Changed"
        var id: String { rawValue }
    }

    private var filteredCommands: [EditorCommandID] {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let categoryOrder = EditorCommandCategory.allCases
        return EditorCommandID.allCases.filter { command in
            let bindings = registry.bindings(for: command)
            if let category, command.category != category { return false }
            switch filter {
            case .all: break
            case .assigned: if bindings.isEmpty { return false }
            case .unassigned: if !bindings.isEmpty { return false }
            case .changed: if bindings == command.defaultBindings { return false }
            }
            guard !words.isEmpty else { return true }
            let text = ([command.title, command.category.title] + bindings.map(\.searchText)).joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        .sorted {
            let order = (categoryOrder.firstIndex(of: $0.category)!, categoryOrder.firstIndex(of: $1.category)!)
            return order.0 != order.1 ? order.0 < order.1 : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var commandList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search", text: $search, prompt: Text("Search commands or shortcuts, such as “split” or “cmd b”"))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260)
                Picker("Category", selection: $category) {
                    Text("All Categories").tag(EditorCommandCategory?.none)
                    Divider()
                    ForEach(EditorCommandCategory.allCases) { Text($0.title).tag(EditorCommandCategory?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("Show", selection: $filter) {
                    ForEach(AssignmentFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Table(of: EditorCommandID.self, selection: $selectedCommandID) {
                TableColumn("Command") { command in
                    HStack(spacing: 6) {
                        Circle().fill(command.category.color).frame(width: 7, height: 7)
                        Text(command.title)
                    }
                    .help("\(command.title) · \(command.category.title). Drag onto a key to assign it.")
                }
                TableColumn("Shortcut") { command in shortcutField(command, slot: 0) }.width(140)
                TableColumn("Alternate") { command in shortcutField(command, slot: 1) }.width(140)
            } rows: {
                ForEach(filteredCommands) { command in
                    TableRow(command).draggable(command.rawValue)
                }
            }
            .frame(minHeight: 260)
        }
    }

    private func shortcutField(_ command: EditorCommandID, slot: Int) -> some View {
        let target = ShortcutRecorder.Target(command: command, slot: slot)
        let binding = registry.keymap.binding(for: command, slot: slot)
        // The alternate field waits for the first, since a command's shortcuts stay in order.
        let available = slot < registry.bindings(for: command).count + 1
        return ShortcutField(binding: binding, isRecording: recorder.target == target, heldModifiers: recorder.heldModifiers,
                             isAvailable: available,
                             toggle: {
                                 selectedCommand = command
                                 recorder.toggle(target)
                                 if recorder.target != nil { status = .info("Press the new shortcut for \(command.title). Click the field again to cancel.") }
                             },
                             clear: { remove(binding) })
    }

    // MARK: Assigning

    private struct Assignment {
        let binding: ShortcutBinding
        let command: EditorCommandID
        let slot: Int
        let current: EditorCommandID
    }

    /// Assigns after checking for reserved keys and conflicts. Without a slot, the
    /// shortcut fills the command's free slot, or replaces its alternate.
    private func assign(_ binding: ShortcutBinding, to command: EditorCommandID, slot: Int?) {
        let keymap = registry.keymap
        if keymap.bindings(for: command).contains(binding.normalized) {
            status = .info("\(binding.display) already runs \(command.title).")
            return
        }
        let slot = slot ?? min(keymap.bindings(for: command).count, Keymap.slotCount - 1)
        if binding.validationError(for: command) == nil,
           let current = keymap.conflict(for: binding, command: command, slot: slot), current != command {
            pendingReassignment = Assignment(binding: binding.normalized, command: command, slot: slot, current: current)
            return
        }
        if let error = registry.set(binding, for: command, slot: slot) {
            status = .error("\(binding.display): \(error)")
        } else {
            status = .info("\(command.title): \(registry.bindings(for: command).map(\.display).joined(separator: " or ")).")
            selectedKeyID = layout.key(for: binding)?.id ?? selectedKeyID
        }
    }
    private func remove(_ binding: ShortcutBinding) {
        guard let found = registry.keymap.assignment(of: binding) else { return }
        _ = registry.set(ShortcutBinding(key: ""), for: found.command, slot: found.slot)
        status = .info("Removed \(binding.display) from \(found.command.title).")
    }

    // MARK: Status

    private enum Status {
        case info(String), error(String)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            switch status {
            case let .error(text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(text).foregroundStyle(.red)
            case let .info(text):
                Text(text).foregroundStyle(.secondary)
            case nil:
                Text("Click a shortcut field and press keys to record, or drag a command onto a key. Click or hold ⌘ ⌥ ⌃ ⇧ to see other layers. Each command can have two shortcuts.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension EditorCommandCategory {
    var color: Color {
        switch self {
        case .playback: .green
        case .navigation: .teal
        case .marks: .orange
        case .editing: .blue
        case .trimming: .purple
        case .view: .pink
        case .project: .brown
        }
    }
}

extension UTType {
    nonisolated static let filmConstructorKeyboardPreset = UTType(exportedAs: "com.aagedal.filmconstructor.keyboard-preset", conformingTo: .json)
}

/// The current shortcuts as a preset file, for the share menu.
nonisolated struct KeyboardPresetShareItem: Transferable {
    let name: String
    let data: Data

    static func fileName(for name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-") + "." + KeyboardPreset.fileExtension
    }
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .filmConstructorKeyboardPreset) { item in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(fileName(for: item.name))
            try item.data.write(to: url)
            return SentTransferredFile(url)
        }
    }
}

/// Records the next key press for a command's shortcut, and tracks held modifiers so
/// the on-screen keyboard can show that layer.
@MainActor
final class ShortcutRecorder: ObservableObject {
    struct Target: Equatable {
        let command: EditorCommandID
        let slot: Int
    }
    @Published private(set) var target: Target?
    @Published private(set) var heldModifiers: ShortcutModifiers = []
    var record: ((ShortcutBinding, Target) -> Void)?
    private var monitors: [Any] = []
    private weak var window: NSWindow?

    func toggle(_ newTarget: Target) {
        target = target == newTarget ? nil : newTarget
        window = NSApp.keyWindow
    }
    func install() {
        guard monitors.isEmpty else { return }
        // Recording takes every key in the editor's window, including ones menus would
        // otherwise handle, so that reserved chords can be explained rather than run.
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                let recorder = self
                guard let target = recorder.target, event.window === recorder.window, !event.isARepeat else { return event }
                recorder.target = nil
                if let binding = EditorKeyboardRouter.binding(for: event) { recorder.record?(binding, target) }
                return nil
            }
        }
        let flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated { self.heldModifiers = ShortcutModifiers(event.modifierFlags) }
            return event
        }
        monitors = [keyMonitor, flagsMonitor].compactMap { $0 }
    }
    func uninstall() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        target = nil
        heldModifiers = []
    }
}

private struct ShortcutField: View {
    let binding: ShortcutBinding
    let isRecording: Bool
    let heldModifiers: ShortcutModifiers
    let isAvailable: Bool
    let toggle: () -> Void
    let clear: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: toggle) {
                Text(isRecording ? (heldModifiers.isEmpty ? "Type shortcut…" : heldModifiers.symbols + "…") : binding.isEmpty ? "—" : binding.display)
                    .font(binding.isEmpty || isRecording ? .callout : .callout.monospaced())
                    .foregroundStyle(isRecording ? Color.accentColor : binding.isEmpty ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(isRecording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(hovering ? 0.15 : 0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isRecording ? Color.accentColor : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .help(isRecording ? "Press keys to record. Click again to cancel." : "Click, then press the shortcut to record it.")
            .accessibilityLabel(binding.isEmpty ? "No shortcut. Record shortcut" : "Shortcut \(binding.display). Record new shortcut")
            Button(action: clear) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .opacity(binding.isEmpty || isRecording ? 0 : 1)
                .disabled(binding.isEmpty || isRecording)
                .help("Remove this shortcut")
                .accessibilityLabel("Remove shortcut")
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - On-screen keyboard

struct VirtualKeyboardView: View {
    let layout: VirtualKeyboardLayout
    let commands: [ShortcutBinding: EditorCommandID]
    let layer: ShortcutModifiers
    let selectedKeyID: VirtualKey.ID?
    let highlightedKeyIDs: Set<VirtualKey.ID>
    let select: (VirtualKey) -> Void
    let toggleModifier: (ShortcutModifiers) -> Void
    let drop: (EditorCommandID, VirtualKey) -> Bool
    static let unit: CGFloat = 48
    static let gap: CGFloat = 4

    var body: some View {
        HStack(alignment: .top, spacing: Self.unit / 2) {
            rows(layout.mainRows)
            rows(layout.navigationRows)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private func rows(_ rows: [[VirtualKey]]) -> some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: Self.gap) {
                    ForEach(row) { key in
                        cap(key).frame(width: key.width * Self.unit - Self.gap, height: index == 0 ? 28 : 44)
                    }
                }
            }
        }
    }

    @ViewBuilder private func cap(_ key: VirtualKey) -> some View {
        switch key.role {
        case .spacer:
            Color.clear
        case let .modifier(modifier):
            Button { toggleModifier(modifier) } label: {
                KeyCapView(key: key, command: nil, reserved: nil, otherLayers: [], isSelected: false, isHighlighted: false,
                           isActiveModifier: layer.contains(modifier))
            }
            .buttonStyle(.plain)
            .help("Show shortcuts that use \(key.label)")
        case .inert:
            KeyCapView(key: key, command: nil, reserved: nil, otherLayers: [], isSelected: false, isHighlighted: false, isActiveModifier: false)
                .opacity(0.5)
        case .key:
            let binding = key.binding(with: layer)
            let command = binding.flatMap { commands[$0] }
            let others = key.bindings.filter { $0.binding != binding }.compactMap { commands[$0.binding] }
            Button { select(key) } label: {
                KeyCapView(key: key, command: command, reserved: command == nil ? binding?.reservation.map { _ in binding?.reservedTitle ?? "Reserved" } : nil,
                           otherLayers: others, isSelected: selectedKeyID == key.id, isHighlighted: highlightedKeyIDs.contains(key.id),
                           isActiveModifier: false)
            }
            .buttonStyle(.plain)
            .help(summary(key))
            .accessibilityLabel("\(key.name) key" + (command.map { ", \($0.title)" } ?? ""))
            .dropDestination(for: String.self) { items, _ in
                guard let command = items.lazy.compactMap(EditorCommandID.init(rawValue:)).first else { return false }
                return drop(command, key)
            }
        }
    }

    private func summary(_ key: VirtualKey) -> String {
        let lines = key.bindings.compactMap { entry in commands[entry.binding].map { "\(entry.binding.display)  \($0.title)" } }
        return ([key.name] + (lines.isEmpty ? ["No shortcuts"] : lines)).joined(separator: "\n")
    }
}

private struct KeyCapView: View {
    let key: VirtualKey
    let command: EditorCommandID?
    let reserved: String?
    /// Commands on this key under other modifier combinations.
    let otherLayers: [EditorCommandID]
    let isSelected: Bool
    let isHighlighted: Bool
    let isActiveModifier: Bool
    @State private var hovering = false

    private var fill: Color {
        if isActiveModifier { return .accentColor }
        if let command { return command.category.color.opacity(hovering ? 1 : 0.82) }
        if reserved != nil { return Color.secondary.opacity(0.3) }
        return Color(nsColor: .controlBackgroundColor).opacity(hovering ? 0.7 : 1)
    }
    private var textColor: Color { isActiveModifier || command != nil ? .white : .primary }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(fill)
                .shadow(color: .black.opacity(0.15), radius: 0.5, y: 1)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.accentColor : isHighlighted ? Color.primary.opacity(0.75) : Color.primary.opacity(0.12),
                              style: StrokeStyle(lineWidth: isSelected ? 2.5 : isHighlighted ? 1.5 : 0.5, dash: isHighlighted && !isSelected ? [3, 2] : []))
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 2) {
                    VStack(alignment: .leading, spacing: -1) {
                        if let shifted = key.shiftedLabel { Text(shifted).font(.system(size: 8)).opacity(0.7) }
                        Text(key.label).font(.system(size: key.label.count > 2 ? 9 : 11, weight: .medium)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    // One dot per command on this key under other modifiers.
                    HStack(spacing: 2) {
                        ForEach(Array(otherLayers.prefix(key.width > 1 ? 4 : 3).enumerated()), id: \.offset) { _, other in
                            Circle().fill(other.category.color).frame(width: 5, height: 5)
                                .overlay(Circle().strokeBorder(Color.white.opacity(command == nil ? 0 : 0.8), lineWidth: 0.5))
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                if let title = command?.shortTitle ?? reserved {
                    Text(title)
                        .font(.system(size: 8.5, weight: .semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .opacity(command == nil ? 0.7 : 1)
                }
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Key details

/// Everything one key does, under each modifier combination.
private struct KeyDetailView: View {
    let key: VirtualKey?
    let keymap: Keymap
    let layer: ShortcutModifiers
    let selectedCommand: EditorCommandID?
    let assign: (ShortcutBinding) -> Void
    let remove: (ShortcutBinding) -> Void
    let selectCommand: (EditorCommandID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let key, case .key = key.role {
                HStack {
                    Text("\(key.name) Key").font(.headline)
                    Spacer()
                    let used = key.bindings.filter { keymap.command(for: $0.binding) != nil }.count
                    Text("\(used) of \(key.bindings.count) used").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(spacing: 2) {
                        let current = key.binding(with: layer)
                        ForEach(key.bindings.map { $0.binding }, id: \.self) { binding in row(binding, inLayer: binding == current) }
                    }
                }
                if let selectedCommand, let binding = key.binding(with: layer), keymap.command(for: binding) == nil,
                   binding.validationError(for: selectedCommand) == nil {
                    Button("Assign “\(selectedCommand.title)” to \(binding.display)") { assign(binding) }
                        .frame(maxWidth: .infinity)
                }
            } else {
                Text("Key Details").font(.headline)
                Text("Click a key on the keyboard to see what it does with every combination of ⌃ ⌥ ⇧ ⌘.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    private func row(_ binding: ShortcutBinding, inLayer: Bool) -> some View {
        let command = keymap.command(for: binding)
        return HStack(spacing: 8) {
            Text(binding.display)
                .font(.callout.monospaced())
                .frame(width: 84, alignment: .leading)
            if let command {
                Button { selectCommand(command) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(command.category.color).frame(width: 7, height: 7)
                        Text(command.title).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(command.title) in the command list")
                Button { remove(binding) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Remove this shortcut")
            } else if binding.reservation != nil {
                Text(binding.reservedTitle.map { "\($0) (standard)" } ?? "Reserved by macOS").foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                Text("Unassigned").foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if let selectedCommand, binding.validationError(for: selectedCommand) == nil {
                    Button { assign(binding) } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("Assign \(selectedCommand.title) to \(binding.display)")
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(inLayer ? Color.accentColor.opacity(0.12) : .clear))
    }
}
