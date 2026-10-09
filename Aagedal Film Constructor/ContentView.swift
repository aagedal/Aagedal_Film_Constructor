import SwiftUI
import EditorCore

/// A small model exerciser while the media engine is evaluated.
struct ContentView: View {
    @State private var engine: TimelineEditEngine?
    @State private var errorMessage: String?
    @State private var demoClipID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Timeline prototype")
                .font(.largeTitle)
            Text("Extend a clip into its neighbour to create a sibling track. Each edit can be undone as one action.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Extend Music clip") { extendClip() }
                    .disabled(!canExtend)
                Button("Undo") { engine?.undo() }
                    .disabled(engine?.canUndo != true)
                Button("Redo") { engine?.redo() }
                    .disabled(engine?.canRedo != true)
                Spacer()
                Button("Reset example") { loadExample() }
            }
            if let project = engine?.project {
                HStack {
                    Text("1920 × 1080 · 30000/1001 fps")
                    Spacer()
                    Text("Synthetic audio components · no media playback")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: 130, height: 20)
                            ForEach(0..<9) { second in
                                Text("\(second)s").font(.caption.monospacedDigit())
                                    .frame(width: 70, alignment: .leading)
                            }
                        }
                        ForEach(project.tracks) { track in
                            HStack(spacing: 0) {
                                VStack(alignment: .leading) {
                                    Text(track.displayName(in: project)).font(.headline)
                                    Text("Gain \(track.template.gain, specifier: "%.2f")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(width: 130, alignment: .leading)
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                                    ForEach(track.clips) { clip in
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(clip.id == demoClipID ? Color.teal : Color.indigo)
                                            .overlay(alignment: .leading) {
                                                Text(clip.id == demoClipID ? "Music A" : "Music B")
                                                    .font(.caption.bold()).foregroundStyle(.white)
                                                    .padding(.leading, 8)
                                            }
                                            .frame(width: clip.sourceRange.duration.seconds * 70)
                                            .offset(x: clip.timelineStart.seconds * 70)
                                    }
                                }
                                .frame(width: 630, height: 54)
                            }
                        }
                    }
                }
                Spacer()
                Text("Routing, gain, and source ranges live in EditorCore. This example uses generated project data; importing and monitoring media are upcoming milestones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(minWidth: 850, minHeight: 400)
        .task { if engine == nil { loadExample() } }
    }

    private var canExtend: Bool {
        guard let id = demoClipID,
              let clip = engine?.project.tracks.flatMap(\.clips).first(where: { $0.id == id }) else { return false }
        return clip.sourceRange.duration.seconds < 6
    }

    private func loadExample() {
        do {
            let template = TrackTemplate(kind: .audio, audioLayout: .stereo, gain: 0.8)
            let family = TrackFamily(baseName: "Music", template: template)
            let asset = MediaAsset(name: "Synthetic music", duration: try RationalTime(20), streams: [
                MediaStream(index: 0, kind: .audio, audioLayout: .stereo)
            ])
            let selection = ClipSelection.audio(AudioSourceSelection(channels: [
                SourceChannel(streamIndex: 0, channelIndex: 0),
                SourceChannel(streamIndex: 0, channelIndex: 1)
            ], layout: .stereo))
            let first = TimelineClip(assetID: asset.id,
                                     sourceRange: try TimeRange(start: .zero, duration: RationalTime(3)),
                                     selection: selection)
            let second = TimelineClip(assetID: asset.id,
                                      sourceRange: try TimeRange(start: RationalTime(8), duration: RationalTime(3)),
                                      timelineStart: try RationalTime(4), selection: selection)
            let track = TimelineTrack(familyID: family.id, template: template, clips: [first, second])
            let settings = try SequenceSettings(frameRate: FrameRate(30000, 1001))
            engine = try TimelineEditEngine(project: Project(settings: settings, assets: [asset], families: [family], tracks: [track]))
            demoClipID = first.id
            errorMessage = nil
        } catch { errorMessage = String(describing: error) }
    }

    private func extendClip() {
        guard let id = demoClipID else { return }
        do {
            try engine?.apply(.trim(clipID: id,
                                    sourceRange: TimeRange(start: .zero, duration: RationalTime(6)),
                                    timelineStart: .zero))
            errorMessage = nil
        } catch { errorMessage = String(describing: error) }
    }
}

#Preview {
    ContentView()
}
