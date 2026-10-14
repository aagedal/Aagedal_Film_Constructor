import AVFoundation
import EditorCore

/// Reads the same composition and audio mix handed to AVPlayer by the app.
@main struct SystemAudioMixProof {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var observations: [[String: Any]] = []
        let formats = ["pcm"] + (CommandLine.arguments.contains("--include-aac") ? ["aac"] : []) +
            (CommandLine.arguments.contains("--include-lossless-and-mp3") ? ["alac", "mp3"] : [])
        for format in formats {
            for channels in [1, 2] {
                let layout: ChannelLayout = channels == 1 ? .mono : .stereo
                for sourceRate in [44100, 48000] {
                    let rates = CommandLine.arguments.contains("--include-resampling") ? [sourceRate, sourceRate == 44100 ? 48000 : 44100] : [sourceRate]
                    for rate in rates {
                        let url = root.appendingPathComponent("source-\(channels)-\(sourceRate)." + (format == "pcm" ? "wav" : format == "alac" ? "alac.m4a" : format == "mp3" ? "mp3" : "m4a"))
                        let source = AVURLAsset(url: url)
                        let tracks = try await source.load(.tracks)
                        let index = tracks.firstIndex { $0.mediaType == .audio }!
                        if format == "aac" && rate == sourceRate {
                            try decodeSource(asset: source, track: tracks[index], to: root.appendingPathComponent("source-\(channels)-\(sourceRate)-system.f32"))
                        }
                        if rate != sourceRate {
                            try decodeSource(asset: source, track: tracks[index],
                                to: root.appendingPathComponent("\(format)-source-\(channels)-\(sourceRate)-to-\(rate)-system.f32"), sampleRate: rate)
                        }
                        let asset = MediaAsset(name: "Distinct channels", originalURL: url, duration: try RationalTime(2),
                            streams: [MediaStream(index: index, kind: .audio, audioLayout: layout)])
                        let selection = ClipSelection.audio(.init(channels: (0..<channels).map {
                            .init(streamIndex: index, channelIndex: $0)
                        }, layout: layout))
                        let template = TrackTemplate(kind: .audio, audioLayout: layout, gain: 0.65)
                        let family = TrackFamily(baseName: "Audio", template: template)
                        let modes = ["constant", "linear", "equal-power", "overlapping-fades", "crossfade"] +
                            (format == "aac" && CommandLine.arguments.contains("--include-packet-cuts") ? ["packet-before", "packet-at", "packet-after"] : []) +
                            (CommandLine.arguments.contains("--include-edge-cuts") ? ["edge-head", "edge-head-after", "edge-tail-before", "edge-tail", "edge-whole"] +
                                (format == "aac" ? ["edge-head-inset-before", "edge-head-inset-at", "edge-head-inset-after", "edge-tail-inset-before", "edge-tail-inset-at", "edge-tail-inset-after"] : []) : [])
                        for mode in modes {
                            func time(_ samples: Int64) throws -> RationalTime { try RationalTime(samples, Int64(rate)) }
                            let length: Int64 = mode == "edge-whole" ? Int64(rate * 2) : 35003
                            // AAC-LC access units contain 1024 decoded frames. At cross rates,
                            // test the nearest representable output sample and its neighbours.
                            let packet = Int64((Double(12 * 1024 * rate) / Double(sourceRate)).rounded())
                            let sourceStart: Int64
                            switch mode {
                            case "packet-before": sourceStart = packet - 1
                            case "packet-at": sourceStart = packet
                            case "packet-after": sourceStart = packet + 1
                            case "edge-head", "edge-whole": sourceStart = 0
                            case "edge-head-after": sourceStart = 1
                            case "edge-head-inset-before": sourceStart = 1023
                            case "edge-head-inset-at": sourceStart = 1024
                            case "edge-head-inset-after": sourceStart = 1025
                            case "edge-tail-inset-before": sourceStart = Int64(rate * 2) - length - 1023
                            case "edge-tail-inset-at": sourceStart = Int64(rate * 2) - length - 1024
                            case "edge-tail-inset-after": sourceStart = Int64(rate * 2) - length - 1025
                            case "edge-tail-before": sourceStart = Int64(rate * 2) - length - 1
                            case "edge-tail": sourceStart = Int64(rate * 2) - length
                            default: sourceStart = 12001
                            }
                            var clip = TimelineClip(assetID: asset.id,
                                sourceRange: try TimeRange(start: time(sourceStart), duration: time(length)),
                                timelineStart: try time(6001), selection: selection)
                            if mode != "constant" && mode != "crossfade" && !mode.hasPrefix("packet-") && !mode.hasPrefix("edge-") {
                                let curve: AudioFadeCurve = mode == "linear" ? .linear : .equalPower
                                let edge: Int64 = mode == "overlapping-fades" ? 24007 : 12007
                                clip.fadeIn = .init(duration: try time(edge), curve: curve)
                                clip.fadeOut = .init(duration: try time(edge), curve: curve)
                            }
                            var project = Project(settings: try SequenceSettings(width: 80, height: 48,
                                frameRate: FrameRate(24), audioSampleRate: rate, audioLayout: layout), assets: [asset],
                                families: [family], tracks: [TimelineTrack(familyID: family.id, template: template, clips: [clip])])
                            if mode == "crossfade" {
                                let incoming = TimelineClip(assetID: asset.id,
                                    sourceRange: try TimeRange(start: time(16003), duration: time(22001)),
                                    timelineStart: try clip.timelineRange().end(), selection: selection)
                                project.tracks[0].clips.append(incoming)
                                project.audioCrossfades = [AudioCrossfade(outgoingClipID: clip.id,
                                    incomingClipID: incoming.id, duration: try time(12008), curve: .equalPower)]
                            }
                            // A muted tail establishes a real trailing picture/audio gap.
                            let silentTemplate = TrackTemplate(kind: .audio, audioLayout: layout, gain: 0)
                            let end = try TimelineRenderPlan(project: project).duration
                            let tail = TimelineClip(assetID: asset.id,
                                sourceRange: try TimeRange(start: .zero, duration: time(2001)),
                                timelineStart: try end.adding(time(3001)), selection: selection)
                            project.tracks.append(TimelineTrack(familyID: family.id, template: silentTemplate, clips: [tail]))
                            let suffix = rate == sourceRate ? "\(rate)" : "\(sourceRate)-to-\(rate)"
                            let name = "\(format)-\(mode)-\(channels)-\(suffix)"
                            try Data(name.utf8).write(to: root.appendingPathComponent("current-case.txt"))
                            let plan = try TimelineRenderPlan(project: project)
                            let command = try FFmpegRenderCompiler.compile(plan, outputURL: root.appendingPathComponent(name + "-reference.mov"))
                            let backend = try AVFoundationSequenceBackend(project: project, videoProxies: [:])
                            let item: AVPlayerItem
                            do {
                                item = try await backend.makePlayerItem()
                            } catch {
                                let rejectedRate = CommandLine.arguments.contains("--expect-resampling-rejection") && rate != sourceRate &&
                                    error.localizedDescription.hasPrefix("System preview requires audio at the sequence sample rate")
                                let rejectedMP3 = CommandLine.arguments.contains("--expect-mp3-rejection") && format == "mp3" &&
                                    error.localizedDescription.hasPrefix("System preview cannot faithfully trim MP3 audio")
                                guard rejectedRate || rejectedMP3 else { throw error }
                                observations.append(["case": name, "channels": channels, "sampleRate": rate,
                                    "sourceSampleRate": sourceRate, "frames": command.audioSamples,
                                    "sourceStartOutputSample": sourceStart, "sourceStartTime": "\(sourceStart)/\(rate)",
                                    "clipSampleCount": length, "timelineStartSample": 6001,
                                    "aacPacketFrames": format == "aac" ? 1024 : 0,
                                    "nearestPacketBoundaryOutputSample": packet,
                                    "rejected": true, "rejectionReason": error.localizedDescription])
                                await backend.close()
                                continue
                            }
                            if CommandLine.arguments.contains("--expect-mp3-rejection") && format == "mp3" {
                                throw NSError(domain: "MP3 source unexpectedly accepted", code: 1)
                            }
                            if CommandLine.arguments.contains("--expect-resampling-rejection") && rate != sourceRate {
                                throw NSError(domain: "Cross-rate source unexpectedly accepted", code: 1)
                            }
                            guard (backend.previewQualificationNotice != nil) == (format == "aac"),
                                  format != "aac" || (backend.previewQualificationNotice!.contains("approximate") &&
                                      backend.previewQualificationNotice!.contains("PCM or ALAC")) else {
                                throw NSError(domain: "Audio codec qualification notice missing or unexpected", code: 1)
                            }
                            let reader = try AVAssetReader(asset: item.asset)
                            let compositionTracks = try await item.asset.loadTracks(withMediaType: .audio)
                            let output = AVAssetReaderAudioMixOutput(audioTracks: compositionTracks, audioSettings: [
                                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32,
                                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                                AVLinearPCMIsBigEndianKey: false])
                            output.audioMix = item.audioMix
                            guard reader.canAdd(output) else { throw NSError(domain: "Cannot add mix output", code: 1) }
                            reader.add(output)
                            guard reader.startReading() else { throw reader.error! }
                            // Preserve timestamps; empty edit ranges may have no buffers.
                            var samples = [Float](repeating: 0, count: Int(command.audioSamples) * channels)
                            var covered = Set<Int>()
                            var extraFrames = 0
                            var maximumExtraAmplitude: Float = 0
                            let actualDuration = try await item.asset.load(.duration)
                            let actualFrames = CMTimeConvertScale(actualDuration, timescale: Int32(rate), method: .roundHalfAwayFromZero).value
                            while let buffer = output.copyNextSampleBuffer() {
                                guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw NSError(domain: "Missing PCM block", code: 1) }
                                let frame = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(buffer), timescale: Int32(rate), method: .roundHalfAwayFromZero).value
                                let count = CMSampleBufferGetNumSamples(buffer)
                                guard frame >= 0 else {
                                    throw NSError(domain: "Mix buffer outside exact timeline: \(frame), \(count), \(command.audioSamples)", code: 1)
                                }
                                guard CMBlockBufferGetDataLength(block) == count * channels * MemoryLayout<Float>.size else {
                                    throw NSError(domain: "Unexpected PCM packing", code: 1)
                                }
                                var values = [Float](repeating: 0, count: count * channels)
                                let result = values.withUnsafeMutableBytes {
                                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                                }
                                guard result == kCMBlockBufferNoErr else { throw NSError(domain: "PCM copy", code: Int(result)) }
                                let accepted = min(count, max(0, Int(command.audioSamples - frame)))
                                extraFrames += count - accepted
                                for value in values.dropFirst(accepted * channels) {
                                    maximumExtraAmplitude = max(maximumExtraAmplitude, abs(value))
                                }
                                for offset in 0..<accepted {
                                    guard covered.insert(Int(frame) + offset).inserted else { throw NSError(domain: "Overlapping mix buffers", code: 1) }
                                }
                                if accepted > 0 {
                                    samples.replaceSubrange(Int(frame) * channels..<(Int(frame) + accepted) * channels, with: values.prefix(accepted * channels))
                                }
                            }
                            guard reader.status == .completed else { throw reader.error ?? NSError(domain: "Reader incomplete", code: 1) }
                            try samples.withUnsafeBytes { try Data($0).write(to: root.appendingPathComponent(name + "-system.f32")) }
                            observations.append(["case": name, "channels": channels, "sampleRate": rate,
                                "sourceSampleRate": sourceRate, "sourceStartOutputSample": sourceStart,
                                "sourceStartTime": "\(sourceStart)/\(rate)",
                                "clipSampleCount": length, "timelineStartSample": 6001,
                                "aacPacketFrames": format == "aac" ? 1024 : 0,
                                "nearestPacketBoundaryOutputSample": packet,
                                "previewQualificationNotice": backend.previewQualificationNotice ?? "",
                                "frames": command.audioSamples, "decodedFrames": covered.count,
                                "compositionFrames": actualFrames, "extraDecodedFrames": extraFrames,
                                "maximumExtraAmplitude": maximumExtraAmplitude,
                                "arguments": command.arguments])
                            await backend.close()
                        }
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("mixes.json"))
    }
    /// Isolate codec differences from composition/gain/envelope differences.
    static func decodeSource(asset: AVAsset, track: AVAssetTrack, to url: URL, sampleRate: Int? = nil) throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1))
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false]
        if let sampleRate { settings[AVSampleRateKey] = sampleRate }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { throw NSError(domain: "Cannot add source output", code: 1) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        var data = Data()
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw NSError(domain: "Missing source PCM", code: 1) }
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            let result = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard result == kCMBlockBufferNoErr else { throw NSError(domain: "Source PCM copy", code: Int(result)) }
            data.append(contentsOf: bytes)
        }
        guard reader.status == .completed else { throw reader.error ?? NSError(domain: "Source reader incomplete", code: 1) }
        try data.write(to: url)
    }

}
