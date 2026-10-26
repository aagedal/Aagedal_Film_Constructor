import EditorCore
import SwiftUI

/// Audio tracks as mixer strips: mute, solo, a gain fader and post-fader level meters, one
/// per channel the track plays on, that move while the sequence plays.
struct MixerPanel: View {
    @ObservedObject var store: EditorStore
    @ObservedObject private var meters = AudioMeters.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Mixer").font(.headline)
                Spacer()
                Text("Post-fader peaks").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
            Divider()
            let tracks = store.project.tracks.filter { $0.kind == .audio }
            if tracks.isEmpty {
                Text("Add media with sound to mix its tracks here.").font(.callout).foregroundStyle(.secondary).padding(12)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(tracks) { track in
                        MixerStrip(store: store, track: track, levels: meters.channelLevels[track.id] ?? [])
                    }
                }.padding(12)
            }
        }
    }
}

private struct MixerStrip: View {
    @ObservedObject var store: EditorStore
    let track: TimelineTrack
    /// One post-fader peak per channel the preview plays.
    let levels: [Float]
    @State private var draft: Double?
    private var decibels: Double { track.template.gain > 0 ? max(-60, 20 * log10(track.template.gain)) : -60 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(track.displayName(in: store.project)).font(.caption.bold()).lineLimit(1)
                Spacer()
                Button { store.setTrackMuted(track.id, muted: !track.muted) } label: { Image(systemName: track.muted ? "m.square.fill" : "m.square") }
                    .buttonStyle(.plain).foregroundStyle(track.muted ? .red : .secondary).help(track.muted ? "Unmute" : "Mute")
                Button { store.setTrackSoloed(track.id, soloed: !track.soloed) } label: { Image(systemName: track.soloed ? "s.square.fill" : "s.square") }
                    .buttonStyle(.plain).foregroundStyle(track.soloed ? .yellow : .secondary).help(track.soloed ? "Stop soloing" : "Solo")
            }
            HStack(spacing: 6) {
                Slider(value: Binding(get: { draft ?? decibels }, set: { draft = $0 }), in: -60...12) { editing in
                    guard !editing, let value = draft else { return }
                    store.setTrackGain(track.id, decibels: value <= -60 ? "-96" : String(format: "%.1f", value))
                    draft = nil
                }
                .help("Track gain; −60 dB silences")
                Text((draft ?? decibels) <= -60 ? "−∞" : String(format: "%+.1f", draft ?? decibels))
                    .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
            }
            if levels.isEmpty { meter(-120, label: "") }
            ForEach(levels.indices, id: \.self) { channel in
                meter(levels[channel], label: Self.channelLabel(channel, of: levels.count))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    static func channelLabel(_ channel: Int, of count: Int) -> String {
        let names: [String] = switch count {
        case 1: ["M"]
        case 2: ["L", "R"]
        case 6: ["L", "R", "C", "LFE", "Ls", "Rs"]
        default: []
        }
        return channel < names.count ? names[channel] : "\(channel + 1)"
    }

    /// −60 to 0 dBFS; green, amber above −12 and red above −3.
    private func meter(_ level: Float, label: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2.monospaced()).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
            GeometryReader { geometry in
                let fill = CGFloat(max(0, min(1, (Double(level) + 60) / 60)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(level > -3 ? Color.red : level > -12 ? Color.orange : Color.green)
                        .frame(width: geometry.size.width * fill)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.isEmpty ? "Level" : label + " level") \(Int(level)) dB")
        .help(level > -120 ? String(format: "%@ peak %.1f dBFS", label, level) : "Silent")
    }
}
