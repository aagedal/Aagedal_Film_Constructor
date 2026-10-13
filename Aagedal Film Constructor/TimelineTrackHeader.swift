import SwiftUI
import EditorCore

struct TimelineTrackHeader: View {
    @ObservedObject var store: EditorStore
    let track: TimelineTrack
    @State private var showingSettings = false
    @State private var name = ""
    @State private var familyName = ""
    @State private var gain = "0"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(track.displayName(in: store.project)).font(.caption.bold()).lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    name = track.customName ?? ""
                    familyName = store.project.families.first { $0.id == track.familyID }?.baseName ?? ""
                    refreshGain()
                    showingSettings = true
                } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings for \(track.displayName(in: store.project))")
                .help("Track name, retention and audio gain")
                .popover(isPresented: $showingSettings) { settings }
            }
            HStack(spacing: 5) {
                Image(systemName: track.kind == .video ? "film" : "speaker.wave.2")
                Text(track.kind == .video ? "Video" : "\(track.audioLayout?.channels.count ?? 0) ch")
                if track.retained { Image(systemName: "pin.fill").help("Keep this track when empty") }
                if track.kind == .audio {
                    Spacer(minLength: 0)
                    Text(track.template.gain == 0 ? "−∞ dB" : String(format: "%.1f dB", 20 * log10(track.template.gain)))
                }
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .onChange(of: track.template.gain) { _, _ in refreshGain() }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Track settings").font(.headline)
            HStack {
                TextField("Custom track name", text: $name).onSubmit { store.renameTrack(track.id, name: name) }
                applyButton("Apply track name") { store.renameTrack(track.id, name: name) }
            }
            Text("Leave blank to use the family name and automatic numbering.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Family name", text: $familyName).onSubmit { store.renameTrackFamily(track.familyID, name: familyName) }
                applyButton("Apply family name") { store.renameTrackFamily(track.familyID, name: familyName) }
            }
            Toggle("Keep track when empty", isOn: Binding(get: { track.retained }, set: { store.setTrackRetention(track.id, retained: $0) }))
            if track.kind == .audio {
                Divider()
                HStack {
                    TextField("Gain (dB)", text: $gain).onSubmit { store.setTrackGain(track.id, decibels: gain) }
                    Text("dB").foregroundStyle(.secondary)
                    applyButton("Apply audio gain") { store.setTrackGain(track.id, decibels: gain) }
                    Button {
                        do { try store.change { try $0.setTrackGain(id: track.id, gain: track.template.gain == 0 ? 1 : 0) } }
                        catch { store.errorMessage = String(describing: error) }
                    } label: { Image(systemName: track.template.gain == 0 ? "speaker.slash.fill" : "speaker.wave.2") }
                    .accessibilityLabel(track.template.gain == 0 ? "Restore unity gain" : "Silence track")
                    .help(track.template.gain == 0 ? "Restore 0 dB" : "Set gain to silence")
                }
                Text("−96 to +24 dB. Applies to every clip on this track.").font(.caption).foregroundStyle(.secondary)
            }
        }.textFieldStyle(.roundedBorder).padding().frame(width: 300)
    }

    private func applyButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "checkmark") }.accessibilityLabel(title).help(title)
    }

    private func refreshGain() {
        gain = track.template.gain > 0 ? String(format: "%.2f", 20 * log10(track.template.gain)) : "-96"
    }
}
