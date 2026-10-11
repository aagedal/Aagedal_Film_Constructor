import SwiftUI
import EditorCore

/// Draft channel maps stay outside the document until validation and optional confirmation finish.
struct AudioSourceEditor: View {
    @ObservedObject var store: EditorStore
    @State private var clip: TimelineClip?
    @State private var originalProject: Project
    @State private var asset: MediaAsset
    @Environment(\.dismiss) private var dismiss
    @State private var layout: ChannelLayout
    @State private var channels: [SourceChannel]
    @State private var destinations: [Int]
    @State private var separateMono = false
    @State private var includeAudio = true
    @State private var replacingClipIDs: Set<UUID> = []
    @State private var pendingReplacementIDs: [UUID] = []
    @State private var errorMessage: String?
    @State private var confirmationMessage: String?
    @State private var pendingSelections: [AudioSourceSelection] = []
    @State private var pendingRouting: [AudioRouting] = []

    init(store: EditorStore, clip: TimelineClip) {
        self.store = store
        _clip = State(initialValue: Optional(clip))
        _originalProject = State(initialValue: store.project)
        _asset = State(initialValue: store.project.assets.first { $0.id == clip.assetID }!)
        guard case .audio(let selection) = clip.selection else { preconditionFailure("Audio component required") }
        _layout = State(initialValue: selection.layout)
        _channels = State(initialValue: selection.channels)
        let track = store.project.tracks.first { $0.clips.contains { $0.id == clip.id } }!
        let route = track.template.routing.outputChannels
        _destinations = State(initialValue: route.isEmpty ? Array(selection.channels.indices) : route)
    }

    init(store: EditorStore, asset: MediaAsset) {
        self.store = store
        _clip = State(initialValue: nil)
        _originalProject = State(initialValue: store.project)
        _asset = State(initialValue: asset)
        let stream = asset.streams.first { $0.kind == .audio }
        let initialLayout = stream?.audioLayout ?? .mono
        _layout = State(initialValue: initialLayout)
        _channels = State(initialValue: initialLayout.channels.indices.map {
            SourceChannel(streamIndex: stream?.index ?? -1, channelIndex: $0)
        })
        _destinations = State(initialValue: initialLayout.channels.indices.map { index in
            // Only propose identity when speaker identities already match the sequence.
            initialLayout == store.project.settings.audioLayout ? index : -1
        })
    }

    private var isAppending: Bool { clip == nil }
    private var canAppendVideoOnly: Bool { isAppending && asset.streams.contains { $0.kind == .video } }
    private var consolidationCandidates: [TimelineClip] {
        guard let clip else { return [] }
        return (try? originalProject.audioConsolidationCandidates(for: clip.id)) ?? []
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isAppending ? "Append with audio selection" : "Audio source channels").font(.title2.bold())
            Text(asset.name).foregroundStyle(.secondary)
            Text(isAppending ? "Choose source channels and sequence outputs before adding this media to the timeline." : "Choose each source channel and its sequence output. Linked picture keeps its source selection and timing.")
                .font(.callout)
            if canAppendVideoOnly {
                Toggle("Include audio", isOn: $includeAudio)
                if !includeAudio { Text("Only the video component will be added.").font(.caption).foregroundStyle(.secondary) }
            }
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
            if includeAudio {
                Picker("Component layout", selection: Binding(get: { layout }, set: changeLayout)) {
                    ForEach(layouts, id: \.self) { value in Text(layoutName(value)).tag(value) }
                }
                Stepper("Channel rows: \(channels.count)", value: Binding(
                    get: { channels.count },
                    set: { changeLayout(ChannelLayout(channels: Array(repeating: nil, count: $0))) }
                ), in: 1...64)
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
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isAppending ? "Append" : "Apply", action: prepare).keyboardShortcut(.defaultAction)
                    .disabled(includeAudio && (channels.contains(unassigned) || destinations.contains(-1)))
            }
        }
        .padding(24).frame(width: 620)
        .alert(isAppending ? "Append with these audio tracks?" : "Change audio tracks?", isPresented: Binding(get: { confirmationMessage != nil }, set: { if !$0 { confirmationMessage = nil } })) {
            Button("Cancel", role: .cancel) { confirmationMessage = nil }
            Button(isAppending ? "Append" : "Apply") { commit() }
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
            pendingSelections = !includeAudio ? [] : separateMono
                ? channels.map { AudioSourceSelection(channels: [$0], layout: .mono) }
                : [AudioSourceSelection(channels: channels, layout: layout)]
            let identity = layout == originalProject.settings.audioLayout && destinations == Array(channels.indices)
            pendingRouting = !includeAudio ? [] : separateMono ? destinations.map { AudioRouting(outputChannels: [$0]) }
                : [AudioRouting(outputChannels: identity ? [] : destinations)]
            pendingReplacementIDs = consolidationCandidates.map(\.id).filter { replacingClipIDs.contains($0) }
            let candidate: Project
            if let clip {
                candidate = try store.previewAudioSelection(clipID: clip.id, selections: pendingSelections, routing: pendingRouting, replacingClipIDs: pendingReplacementIDs)
            } else {
                candidate = try store.previewAudioAppend(assetID: asset.id, selections: pendingSelections, routing: pendingRouting)
            }
            let changedTracks = candidate.tracks.filter { track in
                guard track.template.kind == .audio else { return false }
                guard let before = originalProject.tracks.first(where: { $0.id == track.id }) else { return true }
                return track.template != before.template
            }
            let removedCount = originalProject.tracks.filter { old in !candidate.tracks.contains { $0.id == old.id } }.count
            if originalProject.preferences.askBeforeAudioTrackLayoutChanges && (!changedTracks.isEmpty || removedCount > 0 || !pendingReplacementIDs.isEmpty) {
                let details = changedTracks.map { "\($0.displayName(in: candidate)): \(layoutName($0.audioLayout ?? .mono))" }.joined(separator: "\n")
                let operation = isAppending ? "Append media with \(pendingSelections.count) audio component(s)." : !pendingReplacementIDs.isEmpty ? "Replace \(pendingReplacementIDs.count + 1) selected linked audio components with \(pendingSelections.count) component(s)." : "Replace selected audio with \(pendingSelections.count) component(s)."
                let maps = pendingSelections.indices.map { index in
                    let selection = pendingSelections[index]
                    let outputs = pendingRouting[index].outputChannels.isEmpty ? Array(selection.channels.indices) : pendingRouting[index].outputChannels
                    return selection.channels.indices.map { channel in
                        "\(channelName(selection.channels[channel])) → \(speakerName(originalProject.settings.audioLayout.channels[outputs[channel]], index: outputs[channel]))"
                    }.joined(separator: "\n")
                }.joined(separator: "\n")
                confirmationMessage = "\(operation)\n\(maps)\n\(details)\n\(removedCount) empty track(s) removed." + (isAppending ? "" : " Source in, duration, and linked video stay unchanged.")
            } else { commit() }
        } catch { errorMessage = String(describing: error) }
    }
    private func commit() {
        do {
            if let clip {
                try store.applyAudioSelection(clipID: clip.id, selections: pendingSelections, routing: pendingRouting, replacingClipIDs: pendingReplacementIDs, expectedProject: originalProject)
            } else {
                try store.applyAudioAppend(assetID: asset.id, selections: pendingSelections, routing: pendingRouting, expectedProject: originalProject)
            }
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
        guard let sourceLayout = stream.audioLayout, sourceLayout.channels.indices.contains(channel.channelIndex) else {
            return "Missing source channel (stream \(channel.streamIndex), channel \(channel.channelIndex + 1))"
        }
        let speaker = sourceLayout.channels[channel.channelIndex]
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
