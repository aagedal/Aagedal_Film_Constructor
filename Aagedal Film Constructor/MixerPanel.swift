import EditorCore
import SwiftUI

/// Audio tracks and buses as mixer strips, in the style of Resolve's Fairlight mixer: each
/// track has mute, solo, a fader, insert effects, an output assignment and post-fader
/// meters; buses add their own inserts and faders, and main buses show loudness.
struct MixerPanel: View {
    @ObservedObject var store: EditorStore
    @ObservedObject private var meters = AudioMeters.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Mixer").font(.headline)
                Spacer()
                let mains = store.project.mainBuses
                if mains.count > 1 {
                    Picker("Monitor", selection: Binding(get: { store.monitoredMainID.flatMap { id in mains.contains { $0.id == id } ? id : nil } ?? mains[0].id },
                                                         set: { store.setMonitoredMain($0) })) {
                        ForEach(mains) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize().help("The main bus the sequence preview plays")
                }
                Menu {
                    Button("Add main bus") { store.addBus(kind: .main) }
                    Button("Add submix bus") { store.addBus(kind: .submix) }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).fixedSize().help("Add a bus")
            }.padding(12)
            Divider()
            let tracks = store.project.tracks.filter { $0.kind == .audio }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if tracks.isEmpty {
                        Text("Add media with sound to mix its tracks here.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(tracks) { track in
                        MixerStrip(store: store, track: track, levels: meters.channelLevels[track.id] ?? [])
                    }
                    Text("Buses").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(store.project.mixBuses) { bus in
                        BusStrip(store: store, bus: bus, levels: meters.busLevels[bus.id] ?? [], loudness: meters.loudness[bus.id])
                    }
                }.padding(12)
            }
        }
    }
}

/// −60 to 0 dBFS; green, amber above −12 and red above −3.
private func levelMeter(_ level: Float, label: String) -> some View {
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

private func channelLabel(_ channel: Int, of count: Int) -> String {
    let names: [String] = switch count {
    case 1: ["M"]
    case 2: ["L", "R"]
    case 6: ["L", "R", "C", "LFE", "Ls", "Rs"]
    default: []
    }
    return channel < names.count ? names[channel] : "\(channel + 1)"
}

/// A fader in dB from −60 (silence) to +12, committed when the drag ends.
private struct Fader: View {
    let gain: Double
    let help: String
    let commit: (Double) -> Void
    @State private var draft: Double?
    private var decibels: Double { gain > 0 ? max(-60, 20 * log10(gain)) : -60 }
    var body: some View {
        HStack(spacing: 6) {
            Slider(value: Binding(get: { draft ?? decibels }, set: { draft = $0 }), in: -60...12) { editing in
                guard !editing, let value = draft else { return }
                commit(value)
                draft = nil
            }
            .help(help)
            Text((draft ?? decibels) <= -60 ? "−∞" : String(format: "%+.1f", draft ?? decibels))
                .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }
}

private struct MixerStrip: View {
    @ObservedObject var store: EditorStore
    let track: TimelineTrack
    /// One post-fader peak per channel the preview plays.
    let levels: [Float]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(track.displayName(in: store.project)).font(.caption.bold()).lineLimit(1)
                Spacer()
                OutputMenu(store: store, outputs: store.project.resolvedOutputs(track.template.busOutputs), allowSubmixes: true) {
                    store.setTrackBusOutputs(track.id, outputs: $0)
                }
                Button { store.setTrackMuted(track.id, muted: !track.muted) } label: { Image(systemName: track.muted ? "m.square.fill" : "m.square") }
                    .buttonStyle(.plain).foregroundStyle(track.muted ? .red : .secondary).help(track.muted ? "Unmute" : "Mute")
                Button { store.setTrackSoloed(track.id, soloed: !track.soloed) } label: { Image(systemName: track.soloed ? "s.square.fill" : "s.square") }
                    .buttonStyle(.plain).foregroundStyle(track.soloed ? .yellow : .secondary).help(track.soloed ? "Stop soloing" : "Solo")
            }
            Fader(gain: track.template.gain, help: "Track gain; −60 dB silences") { value in
                store.setTrackGain(track.id, decibels: value <= -60 ? "-96" : String(format: "%.1f", value))
            }
            EffectRack(effects: track.template.effects) { store.setTrackEffects(track.id, effects: $0) }
            if levels.isEmpty { levelMeter(-120, label: "") }
            ForEach(levels.indices, id: \.self) { channel in
                levelMeter(levels[channel], label: channelLabel(channel, of: levels.count))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}

/// Chooses the buses a track or submix sends to.
private struct OutputMenu: View {
    @ObservedObject var store: EditorStore
    let outputs: [UUID]
    let allowSubmixes: Bool
    let change: ([UUID]) -> Void
    var body: some View {
        let buses = store.project.mixBuses.filter { allowSubmixes || $0.kind == .main }
        let names = buses.filter { outputs.contains($0.id) }.map(\.name)
        Menu {
            ForEach(buses) { bus in
                Toggle(bus.name, isOn: Binding(get: { outputs.contains(bus.id) }, set: { on in
                    var next = outputs.filter { $0 != bus.id }
                    if on { next.append(bus.id) }
                    if !next.isEmpty { change(next) }
                }))
            }
        } label: {
            Text(names.isEmpty ? "No output" : names.joined(separator: ", ")).font(.caption2).lineLimit(1)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Buses this sends to")
    }
}

private struct BusStrip: View {
    @ObservedObject var store: EditorStore
    let bus: AudioBus
    let levels: [Float]
    let loudness: LoudnessMeter.Reading?
    @State private var name = ""
    @FocusState private var editingName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: bus.kind == .main ? "speaker.wave.2.fill" : "arrow.triangle.merge").foregroundStyle(.secondary)
                TextField("Bus name", text: $name).textFieldStyle(.plain).font(.caption.bold()).focused($editingName)
                    .onSubmit { store.renameBus(bus.id, name: name) }
                    .onAppear { name = bus.name }
                    .onChange(of: bus.name) { _, value in if !editingName { name = value } }
                Spacer()
                if bus.kind == .submix {
                    OutputMenu(store: store, outputs: store.project.resolvedOutputs(bus.outputs), allowSubmixes: false) {
                        store.setBusOutputs(bus.id, outputs: $0)
                    }
                }
                Button { store.setBusMuted(bus.id, muted: !bus.muted) } label: { Image(systemName: bus.muted ? "m.square.fill" : "m.square") }
                    .buttonStyle(.plain).foregroundStyle(bus.muted ? .red : .secondary).help(bus.muted ? "Unmute" : "Mute")
                Menu {
                    Button("Remove bus", role: .destructive) { store.removeBus(bus.id) }
                        .disabled(bus.kind == .main && store.project.mainBuses.count == 1)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Fader(gain: bus.gain, help: "Bus fader") { store.setBusGain(bus.id, decibels: $0) }
            EffectRack(effects: bus.effects) { store.setBusEffects(bus.id, effects: $0) }
            if levels.isEmpty { levelMeter(-120, label: "") }
            ForEach(levels.indices, id: \.self) { channel in
                levelMeter(levels[channel], label: channelLabel(channel, of: levels.count))
            }
            if bus.kind == .main { LoudnessView(reading: loudness ?? .silent) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(bus.kind == .main ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.08)))
    }
}

/// EBU R 128 readout: momentary, short-term and integrated loudness, range and peak.
private struct LoudnessView: View {
    let reading: LoudnessMeter.Reading
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                // −40 to 0 LUFS with a mark at the −23 LUFS broadcast target.
                let fraction = { (lufs: Double) in CGFloat(max(0, min(1, (lufs + 40) / 40))) }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(Color.teal).frame(width: geometry.size.width * fraction(reading.shortTerm.isFinite ? reading.shortTerm : -60))
                    Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 1).offset(x: geometry.size.width * fraction(-23))
                    if reading.momentary.isFinite {
                        Rectangle().fill(Color.white).frame(width: 2).offset(x: geometry.size.width * fraction(reading.momentary))
                    }
                }
            }.frame(height: 6)
            HStack(spacing: 8) {
                value("M", reading.momentary)
                value("S", reading.shortTerm)
                value("I", reading.integrated)
                Text("LRA \(String(format: "%.1f", reading.range))").font(.caption2.monospacedDigit())
                Spacer()
                Button { AudioMeters.shared.resetLoudness() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).font(.caption2).help("Reset loudness measurement")
            }
            Text("Peak \(reading.peak.isFinite ? String(format: "%.1f dBFS", reading.peak) : "—") · LUFS while the sequence plays")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
    private func value(_ label: String, _ lufs: Double) -> some View {
        Text("\(label) \(lufs.isFinite && lufs > -70 ? String(format: "%.1f", lufs) : "—")").font(.caption2.monospacedDigit())
    }
}

/// An ordered chain of insert effects: bypass, edit in a popover, remove, add.
private struct EffectRack: View {
    let effects: [AudioEffect]
    let change: ([AudioEffect]) -> Void
    @State private var editing: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(effects) { effect in
                HStack(spacing: 4) {
                    Button { toggle(effect) } label: { Image(systemName: effect.enabled ? "power.circle.fill" : "power.circle") }
                        .buttonStyle(.plain).foregroundStyle(effect.enabled ? Color.accentColor : .secondary).help(effect.enabled ? "Bypass" : "Enable")
                    Button(effect.name) { editing = effect.id }
                        .buttonStyle(.plain).font(.caption)
                        .popover(isPresented: Binding(get: { editing == effect.id }, set: { if !$0 { editing = nil } })) {
                            EffectEditor(effect: effect) { updated in
                                change(effects.map { $0.id == updated.id ? updated : $0 })
                            }.padding(12).frame(width: 320)
                        }
                    Spacer()
                    Button { change(effects.filter { $0.id != effect.id }) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary).help("Remove \(effect.name)")
                }
            }
            Menu {
                Button("EQ") { change(effects + [.equalizer()]) }
                Button("Compressor") { change(effects + [.compressor()]) }
                Button("Limiter") { change(effects + [.limiter()]) }
            } label: { Label("Add effect", systemImage: "plus.circle").font(.caption) }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(effects.count >= 16)
        }
    }
    private func toggle(_ effect: AudioEffect) {
        change(effects.map { var e = $0; if e.id == effect.id { e.enabled.toggle() }; return e })
    }
}

/// Parameters of one insert effect; changes apply when a control is released.
private struct EffectEditor: View {
    let effect: AudioEffect
    let commit: (AudioEffect) -> Void
    @State private var draft: AudioEffect?
    private var current: AudioEffect { draft ?? effect }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(effect.name).font(.headline)
            switch current.kind {
            case .equalizer(let eq): equalizer(eq)
            case .compressor(let c):
                parameter("Threshold", c.threshold, -60...0, "%.0f dB") { v in update { if case .compressor(var s) = $0 { s.threshold = v; $0 = .compressor(s) } } }
                parameter("Ratio", c.ratio, 1...20, "%.1f:1") { v in update { if case .compressor(var s) = $0 { s.ratio = v; $0 = .compressor(s) } } }
                parameter("Attack", c.attack, 0.1...200, "%.1f ms") { v in update { if case .compressor(var s) = $0 { s.attack = v; $0 = .compressor(s) } } }
                parameter("Release", c.release, 10...2000, "%.0f ms") { v in update { if case .compressor(var s) = $0 { s.release = v; $0 = .compressor(s) } } }
                parameter("Makeup", c.makeup, 0...24, "%.1f dB") { v in update { if case .compressor(var s) = $0 { s.makeup = v; $0 = .compressor(s) } } }
            case .limiter(let l):
                parameter("Ceiling", l.ceiling, -30...0, "%.1f dBFS") { v in update { if case .limiter(var s) = $0 { s.ceiling = v; $0 = .limiter(s) } } }
                parameter("Release", l.release, 1...1000, "%.0f ms") { v in update { if case .limiter(var s) = $0 { s.release = v; $0 = .limiter(s) } } }
                Text("A fast 20:1 stage then a clip at the ceiling; no sample exceeds it.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: effect) { _, _ in draft = nil }
    }

    private func update(_ change: (inout AudioEffect.Kind) -> Void) {
        var next = current
        change(&next.kind)
        draft = next
    }

    /// A slider that edits the draft while dragging and commits on release.
    private func parameter(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ format: String,
                           set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 64, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range) { editing in
                if !editing, let draft { commit(draft) }
            }
            Text(String(format: format, value)).font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
        }
    }

    @ViewBuilder private func equalizer(_ eq: ParametricEQ) -> some View {
        EQCurve(eq: eq).frame(height: 70)
        ForEach(eq.bands.indices, id: \.self) { index in
            let band = eq.bands[index]
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Toggle(isOn: Binding(get: { band.enabled }, set: { on in
                        update { if case .equalizer(var e) = $0 { e.bands[index].enabled = on; $0 = .equalizer(e) } }
                        if let draft { commit(draft) }
                    })) { Text("Band \(index + 1)").font(.caption.bold()) }
                    Spacer()
                    Picker("Shape", selection: Binding(get: { band.shape }, set: { shape in
                        update { if case .equalizer(var e) = $0 { e.bands[index].shape = shape; $0 = .equalizer(e) } }
                        if let draft { commit(draft) }
                    })) {
                        Text("Low cut").tag(EQBand.Shape.lowCut); Text("Low shelf").tag(EQBand.Shape.lowShelf)
                        Text("Bell").tag(EQBand.Shape.bell); Text("High shelf").tag(EQBand.Shape.highShelf)
                        Text("High cut").tag(EQBand.Shape.highCut)
                    }.labelsHidden().fixedSize().controlSize(.small)
                }
                if band.enabled {
                    // Frequency on a log scale.
                    parameter("Freq", log10(band.frequency), log10(20)...log10(20000), "") { v in
                        update { if case .equalizer(var e) = $0 { e.bands[index].frequency = (pow(10, v) * 10).rounded() / 10; $0 = .equalizer(e) } }
                    }.overlay(alignment: .trailing) {
                        Text(band.frequency >= 1000 ? String(format: "%.1f kHz", band.frequency / 1000) : String(format: "%.0f Hz", band.frequency))
                            .font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing).background(.background)
                    }
                    if band.shape != .lowCut && band.shape != .highCut {
                        parameter("Gain", band.gain, -24...24, "%+.1f dB") { v in
                            update { if case .equalizer(var e) = $0 { e.bands[index].gain = (v * 10).rounded() / 10; $0 = .equalizer(e) } }
                        }
                    }
                    parameter("Q", band.q, 0.1...10, "%.2f") { v in
                        update { if case .equalizer(var e) = $0 { e.bands[index].q = v; $0 = .equalizer(e) } }
                    }
                }
            }
        }
    }
}

/// The equaliser's combined response from 20 Hz to 20 kHz over ±24 dB.
private struct EQCurve: View {
    let eq: ParametricEQ
    var body: some View {
        Canvas { context, size in
            let zero = size.height / 2
            var grid = Path()
            grid.move(to: CGPoint(x: 0, y: zero)); grid.addLine(to: CGPoint(x: size.width, y: zero))
            for f in [100.0, 1000, 10000] {
                let x = size.width * (log10(f) - log10(20)) / (log10(20000) - log10(20))
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
            var curve = Path()
            for step in 0...120 {
                let f = pow(10, log10(20) + (log10(20000) - log10(20)) * Double(step) / 120)
                let db = max(-24, min(24, eq.response(at: f)))
                let point = CGPoint(x: size.width * Double(step) / 120, y: zero - size.height / 2 * db / 24)
                if step == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(.accentColor), lineWidth: 1.5)
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.2)))
    }
}
