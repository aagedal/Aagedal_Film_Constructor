import Foundation

/// How a source's audio channels split into timeline components, as in Final Cut Pro's
/// audio configuration. Each component lands on a track of its own layout.
public enum AudioConfiguration: String, Codable, CaseIterable, Sendable {
    /// Each audio stream as recorded: a stereo stream stays stereo, a mono stream mono.
    case asRecorded
    /// The first two channels as one stereo component (one channel plays on both sides).
    case stereo
    /// Channels in pairs as stereo components; an odd last channel is mono.
    case stereoPairs
    /// Every channel its own mono component, in the centre of the mix.
    case multiMono
    /// The first six channels as one 5.1 component (L R C LFE Ls Rs); 5.1 sequences only.
    case surround51

    public var displayName: String {
        switch self {
        case .asRecorded: "As recorded"
        case .stereo: "Stereo"
        case .stereoPairs: "Stereo pairs"
        case .multiMono: "Multi-mono"
        case .surround51: "5.1 surround"
        }
    }
}

/// One timeline audio component: the source channels it plays and their sequence outputs.
public struct AudioComponentPlan: Equatable, Sendable {
    public var selection: AudioSourceSelection
    public var routing: AudioRouting
    public init(selection: AudioSourceSelection, routing: AudioRouting) { self.selection = selection; self.routing = routing }
}

public extension MediaAsset {
    /// Every audio channel, stream by stream.
    var audioChannels: [SourceChannel] {
        streams.filter { $0.kind == .audio }.flatMap { stream in
            (stream.audioLayout?.channels.indices ?? 0..<0).map { SourceChannel(streamIndex: stream.index, channelIndex: $0) }
        }
    }

    /// The components a configuration makes in a sequence of this layout; empty when it
    /// does not apply (too few channels, or a layout the sequence cannot route).
    func audioComponents(_ configuration: AudioConfiguration, sequence: ChannelLayout) -> [AudioComponentPlan] {
        let channels = audioChannels
        guard !channels.isEmpty else { return [] }
        var selections: [AudioSourceSelection] = []
        switch configuration {
        case .asRecorded:
            for stream in streams where stream.kind == .audio {
                guard let layout = stream.audioLayout else { continue }
                selections.append(AudioSourceSelection(channels: layout.channels.indices.map { SourceChannel(streamIndex: stream.index, channelIndex: $0) }, layout: layout))
            }
        case .stereo:
            selections = [AudioSourceSelection(channels: [channels[0], channels.count > 1 ? channels[1] : channels[0]], layout: .stereo)]
        case .stereoPairs:
            var index = 0
            while index < channels.count {
                if index + 1 < channels.count {
                    selections.append(AudioSourceSelection(channels: [channels[index], channels[index + 1]], layout: .stereo))
                } else {
                    selections.append(AudioSourceSelection(channels: [channels[index]], layout: .mono))
                }
                index += 2
            }
        case .multiMono:
            selections = channels.map { AudioSourceSelection(channels: [$0], layout: .mono) }
        case .surround51:
            guard channels.count >= 6 else { return [] }
            selections = [AudioSourceSelection(channels: Array(channels.prefix(6)), layout: .surround51)]
        }
        var plans: [AudioComponentPlan] = []
        for selection in selections {
            guard let routing = Self.defaultRouting(for: selection.layout, in: sequence) else { return [] }
            plans.append(AudioComponentPlan(selection: selection, routing: routing))
        }
        return plans
    }

    /// The configurations that apply to this media in a sequence of this layout.
    func availableAudioConfigurations(sequence: ChannelLayout) -> [AudioConfiguration] {
        AudioConfiguration.allCases.filter { !audioComponents($0, sequence: sequence).isEmpty }
    }

    /// The configuration whose components are exactly these selections, if any.
    func audioConfiguration(matching selections: [AudioSourceSelection], sequence: ChannelLayout) -> AudioConfiguration? {
        availableAudioConfigurations(sequence: sequence).first { configuration in
            let planned = audioComponents(configuration, sequence: sequence).map(\.selection)
            return planned.count == selections.count && Set(planned) == Set(selections)
        }
    }

    /// How a component of this layout plays in the sequence: unchanged when the layouts
    /// match, mono in the centre, stereo on the front pair or folded into mono; nil when no
    /// plain channel map fits (5.1 into stereo, for example).
    static func defaultRouting(for layout: ChannelLayout, in sequence: ChannelLayout) -> AudioRouting? {
        if layout == sequence { return AudioRouting() }
        if layout.channels.count == 1 { return .centre(in: sequence) }
        if layout == .stereo && sequence == .surround51 { return AudioRouting(outputChannels: [0, 1]) }
        if layout == .stereo && sequence == .mono { return AudioRouting(outputChannels: [0, 0]) }
        if layout.channels.count == sequence.channels.count { return AudioRouting(outputChannels: Array(sequence.channels.indices)) }
        return nil
    }
}
