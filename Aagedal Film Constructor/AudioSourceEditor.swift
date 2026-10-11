import SwiftUI
import EditorCore

/// Draft channel maps stay outside the document until validation and optional confirmation finish.
struct AudioSourceEditor: View {
    @ObservedObject var store: EditorStore
    @State private var clip: TimelineClip
    @State private var originalProject: Project
    @State private var asset: MediaAsset
    @Environment(\.dismiss) private var dismiss
    @State private var layout: ChannelLayout
    @State private var channels: [SourceChannel]
    @State private var destinations: [Int]
    @State private var separateMono = false
    @State private var replacingClipIDs: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var confirmationMessage: String?
    @State private var pendingSelections: [AudioSourceSelection] = []
    @State private var pendingRouting: [AudioRouting] = []
    @State private var pendingReplacementIDs: [UUID] = []

    init(store: EditorStore, clip: TimelineClip) {
        self.store = store
        _clip = State(initialValue: clip)
        _originalProject = State(initialValue: store.project)
        _asset = State(initialValue: store.project.assets.first { $0.id == clip.assetID }!)
        guard case .audio(let selection) = clip.selection else { preconditionFailure("Audio component required") }
        _layout = State(initialValue: selection.layout)
        _channels = State(initialValue: selection.channels)
        let track = store.project.tracks.first { $0.clips.contains { $0.id == clip.id } }!
        let route = track.template.routing.outputChannels
        _destinations = State(initialValue: route.isEmpty ? Array(selection.channels.indices) : route)
    }

    private let unassigned = SourceChannel(streamIndex: -1, channelIndex: -1)
    private var availableChannels: [SourceChannel] {
        asset.streams.filter { $0.kind == .audio }.flatMap { stream in
            (stream.audioLayout?.channels.indices ?? 0..<0).map { SourceChannel(streamIndex: stream.index, channelIndex: $0) }
        }
    }
    private var layouts: [ChannelLayout] {
        var result: [ChannelLayout] = [.mono, .stereo, .surround51]
        for value in [layout] + asset.streams.compactMap(\.audioLayout) where !result.contains(value) { result.append(value) }
        return result
    }
    private var consolidationCandidates: [TimelineClip] {
        (try? originalProject.audioConsolidationCandidates(for: clip.id)) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Audio source channels").font(.title2.bold())
            Text(asset.name).foregroundStyle(.secondary)
            Text("Choose each source channel and its sequence output. Linked picture and timing stay unchanged.")
                .font(.callout)
            if !consolidationCandidates.isEmpty {
                GroupBox("Combine linked audio components") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Include components to replace with this one. Choose the resulting layout and source map below; unselected components stay in the sequence.")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(consolidationCandidates) { component in
                                    Toggle(componentName(component), isOn: Binding(
                                        get: { replacingClipIDs.contains(component.id) },
                                        set: { included in
                                            if included { replacingClipIDs.insert(component.id); separateMono = false }
                                            else { replacingClipIDs.remove(component.id) }
                                        }
                                    ))
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: min(110, CGFloat(consolidationCandidates.count) * 45))
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            }
            Picker("Component layout", selection: Binding(get: { layout }, set: changeLayout)) {
                ForEach(layouts, id: \.self) { value in Text(layoutName(value)).tag(value) }
            }
            Toggle("Create separate mono components", isOn: $separateMono)
                .disabled(channels.count < 2 || !replacingClipIDs.isEmpty)
            Text(separateMono ? "Each row becomes a mono component on a compatible track. Components remain linked for timing edits." : "All rows form one component in the chosen speaker order.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(channels.indices, id: \.self) { index in
                        HStack(alignment: .top) {
                            Text(speakerName(layout.channels[index], index: index)).frame(width: 95, alignment: .leading)
                            VStack(alignment: .leading, spacing: 6) {
                                Picker("Source", selection: Binding(
                                    get: { channels.indices.contains(index) ? channels[index] : unassigned },
                                    set: { if channels.indices.contains(index) { channels[index] = $0 } }
                                )) {
                                    Text("Choose source channel").tag(unassigned)
                                    ForEach(availableChannels, id: \.self) { channel in Text(channelName(channel)).tag(channel) }
                                }
                                Picker("Output", selection: Binding(
                                    get: { destinations.indices.contains(index) ? destinations[index] : -1 },
                                    set: { if destinations.indices.contains(index) { destinations[index] = $0 } }
                                )) {
                                    Text("Choose sequence output").tag(-1)
                                    ForEach(originalProject.settings.audioLayout.channels.indices, id: \.self) { output in
                                        Text(speakerName(originalProject.settings.audioLayout.channels[output], index: output)).tag(output)
                                    }
                                }
                            }
                        }
                    }
                }.padding(.vertical, 4)
            }.frame(minHeight: 100, maxHeight: 300)
            Text("Routing several channels to one output explicitly sums them. No automatic downmix or level adjustment is applied.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply", action: prepare).keyboardShortcut(.defaultAction)
                    .disabled(channels.contains(unassigned) || destinations.contains(-1))
            }
        }
        .padding(24).frame(width: 620)
        .alert("Change audio tracks?", isPresented: Binding(get: { confirmationMessage != nil }, set: { if !$0 { confirmationMessage = nil } })) {
            Button("Cancel", role: .cancel) { confirmationMessage = nil }
            Button("Apply") { commit() }
        } message: { Text(confirmationMessage ?? "") }
    }

    private func changeLayout(_ value: ChannelLayout) {
        // Resize every map in the picker transaction, before SwiftUI renders the new layout.
        let count = value.channels.count
        channels = Array(channels.prefix(count)) + Array(repeating: unassigned, count: max(0, count - channels.count))
        destinations = Array(destinations.prefix(count)) + Array(repeating: -1, count: max(0, count - destinations.count))
        layout = value
        if count < 2 { separateMono = false }
    }

    private func prepare() {
        errorMessage = nil
        do {
            guard store.project == originalProject else {
                throw EditorCoreError.invalidModel("The project changed. Cancel and reopen audio source selection.")
            }
            pendingSelections = separateMono
                ? channels.map { AudioSourceSelection(channels: [$0], layout: .mono) }
                : [AudioSourceSelection(channels: channels, layout: layout)]
            let identity = layout == originalProject.settings.audioLayout && destinations == Array(channels.indices)
            pendingRouting = separateMono ? destinations.map { AudioRouting(outputChannels: [$0]) }
                : [AudioRouting(outputChannels: identity ? [] : destinations)]
            pendingReplacementIDs = consolidationCandidates.map(\.id).filter { replacingClipIDs.contains($0) }
            let candidate = try store.previewAudioSelection(clipID: clip.id, selections: pendingSelections, routing: pendingRouting, replacingClipIDs: pendingReplacementIDs)
            let changedTracks = candidate.tracks.filter { track in
                guard let before = originalProject.tracks.first(where: { $0.id == track.id }) else { return true }
                return track.template != before.template
            }
            let removedCount = originalProject.tracks.filter { old in !candidate.tracks.contains { $0.id == old.id } }.count
            if originalProject.preferences.askBeforeAudioTrackLayoutChanges && (!changedTracks.isEmpty || removedCount > 0 || !pendingReplacementIDs.isEmpty) {
                let details = changedTracks.map { "\($0.displayName(in: candidate)): \(layoutName($0.audioLayout ?? .mono))" }.joined(separator: "\n")
                let combined = pendingReplacementIDs.isEmpty ? "" : "Combining \(pendingReplacementIDs.count + 1) existing components.\n"
                confirmationMessage = "\(combined)\(channels.count) source channels → \(pendingSelections.count) component(s).\n\(details)\n\(removedCount) empty track(s) removed. Source in, duration, and linked video stay unchanged."
            } else { commit() }
        } catch { errorMessage = String(describing: error) }
    }
    private func commit() {
        do {
            try store.applyAudioSelection(clipID: clip.id, selections: pendingSelections, routing: pendingRouting, replacingClipIDs: pendingReplacementIDs, expectedProject: originalProject)
            dismiss()
        } catch { errorMessage = String(describing: error) }
        confirmationMessage = nil
    }
    private func componentName(_ component: TimelineClip) -> String {
        let track = originalProject.tracks.first { $0.clips.contains { $0.id == component.id } }
        guard case .audio(let selection) = component.selection else { return "Audio" }
        return "\(track?.displayName(in: originalProject) ?? "Audio") · " + selection.channels.map(channelName).joined(separator: ", ")
    }
    private func channelName(_ channel: SourceChannel) -> String {
        guard let stream = asset.streams.first(where: { $0.index == channel.streamIndex }) else { return "Missing stream" }
        let speaker = stream.audioLayout?.channels[channel.channelIndex]
        return "Stream \(stream.index) · \(stream.label ?? "Audio") · \(speakerName(speaker ?? nil, index: channel.channelIndex))"
    }
    private func layoutName(_ value: ChannelLayout) -> String {
        if value == .mono { return "Mono" }
        if value == .stereo { return "Stereo (L, R)" }
        if value == .surround51 { return "5.1 (L, R, C, LFE, Ls, Rs)" }
        return "\(value.channels.count) channels · " + value.channels.enumerated().map { speakerName($0.element, index: $0.offset) }.joined(separator: ", ")
    }
    private func speakerName(_ speaker: SpeakerPosition?, index: Int) -> String {
        switch speaker {
        case .mono: "Mono"
        case .left: "Left"
        case .right: "Right"
        case .center: "Center"
        case .lowFrequency: "LFE"
        case .leftSurround: "Left surround"
        case .rightSurround: "Right surround"
        case .leftRear: "Left rear"
        case .rightRear: "Right rear"
        case nil: "Channel \(index + 1) (unknown)"
        }
    }
}
