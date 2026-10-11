import SwiftUI

struct KeyboardShortcutSettings: View {
    @ObservedObject var registry: EditorCommandRegistry
    @State private var selected: EditorCommandID = .splitClip
    @State private var draft = EditorCommandID.splitClip.defaultBinding
    @State private var message: String?
    @State private var confirmReset = false
    private var error: String? { draft.validationError(for: selected, bindings: registry.bindings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts").font(.title2)
            Text("Choose a command and edit its binding. An empty key removes the shortcut. Changes apply to the editor menus immediately.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 24) {
                List(EditorCommandID.allCases, selection: $selected) { command in
                    HStack {
                        Text(command.title)
                        Spacer()
                        Text(registry.binding(for: command).display).foregroundStyle(.secondary)
                    }.tag(command)
                }.frame(width: 290, height: 300)
                Form {
                    Text(selected.title).font(.headline)
                    Text("Scope: \(selected.scope.rawValue.capitalized)").foregroundStyle(.secondary)
                    TextField("Key", text: $draft.key)
                    Toggle("Command ⌘", isOn: $draft.command)
                    Toggle("Option ⌥", isOn: $draft.option)
                    Toggle("Control ⌃", isOn: $draft.control)
                    Toggle("Shift ⇧", isOn: $draft.shift)
                    Text(error ?? message ?? "Shortcut: \(draft.display)")
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Apply") { message = registry.set(draft, for: selected) ?? "Shortcut saved." }
                            .disabled(error != nil || draft.normalized == registry.binding(for: selected))
                        Button("Clear") { draft.key = ""; message = nil }
                    }
                }.frame(width: 270)
            }
            Button("Reset All to Defaults…") { confirmReset = true }
            Text("Standard application and text shortcuts are reserved. Playback commands allow unmodified keys and control the source across workspace panels. Editor commands leave text entry unchanged.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 650)
        .onChange(of: selected) { _, command in draft = registry.binding(for: command); message = nil }
        .onChange(of: draft) { _, _ in message = nil }
        .onAppear { draft = registry.binding(for: selected) }
        .confirmationDialog("Reset every keyboard shortcut to its default?", isPresented: $confirmReset) {
            Button("Reset All Shortcuts") { registry.reset(); draft = registry.binding(for: selected); message = "Defaults restored." }
        }
    }
}
