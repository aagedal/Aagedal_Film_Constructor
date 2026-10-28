import AVFoundation
import AppKit
import EditorCore

/// Live stabilisation in preview against export, and preview audio through track effects,
/// buses, the monitored main bus and its loudness meter.
@main struct MixStabiliseSmoke {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "MixStabiliseSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "\(executable) failed")
        return data
    }

    static func main() async throws {
        let ffmpeg = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        try await stabilisation(ffmpeg: ffmpeg, directory: directory)
        try await buses(ffmpeg: ffmpeg, directory: directory)
    }

    /// A white box jitters horizontally; with its path as the analysis, preview and export both
    /// hold it still at the same place.
    static func stabilisation(ffmpeg: String, directory: URL) async throws {
        let shaky = directory.appendingPathComponent("shaky.mov")
        _ = try run(ffmpeg, ["-v", "error", "-filter_complex",
                             "color=black:s=320x180:r=25:d=4[b];color=white:s=40x40:r=25:d=4[w];[b][w]overlay=x='140+12*sin(t*55)':y=70:eval=frame,format=yuv422p10le",
                             "-c:v", "prores_ks", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", shaky.path])
        let vi = try await AVURLAsset(url: shaky).load(.tracks).firstIndex { $0.mediaType == .video }!
        let asset = MediaAsset(name: "Shaky", originalURL: shaky, duration: try RationalTime(4), streams: [MediaStream(index: vi, kind: .video)])
        let family = TrackFamily(baseName: "Video", template: TrackTemplate(kind: .video))
        let times = (0..<100).map { Double($0) / 25 }
        let analysis = MotionAnalysis(times: times, x: (0..<100).map { 12 * sin(Double($0) * 2.2) / 320 }, y: times.map { _ in 0 })
        let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(4)), selection: .video(streamIndex: vi),
                                stabilization: Stabilization(analysis: analysis, smoothing: 1, zoom: 1.2))
        let project = Project(settings: try SequenceSettings(width: 320, height: 180, frameRate: FrameRate(25)), assets: [asset], families: [family],
                              tracks: [TimelineTrack(familyID: family.id, template: family.template, clips: [clip])])
        let output = directory.appendingPathComponent("stable.mov")
        let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output, sidecarDirectory: directory)
        for sidecar in command.sidecars { try sidecar.contents.write(to: sidecar.url, atomically: true, encoding: .utf8) }
        _ = try run(ffmpeg, command.arguments)
        let rows = try run(ffmpeg, ["-v", "error", "-i", output.path, "-vf", "crop=320:1:0:90", "-f", "rawvideo", "-pix_fmt", "gray", "-"])
        func centre(_ row: [UInt8]) -> Double {
            let lit = row.indices.filter { row[$0] > 128 }
            return lit.isEmpty ? 0 : Double(lit.reduce(0, +)) / Double(lit.count)
        }
        let backend = try AVFoundationSequenceBackend(project: project, videoProxies: [:])
        var image: CGImage?
        backend.display = { displayed, _ in image = displayed }
        var previewCentres: [Double] = []
        for frame in stride(from: 25, to: 75, by: 5) {
            try await backend.seek(toFrame: Int64(frame))
            guard let image else { throw NSError(domain: "No preview frame", code: 1) }
            var row = [UInt8](repeating: 0, count: 320)
            row.withUnsafeMutableBytes { pointer in
                let context = CGContext(data: pointer.baseAddress, width: 320, height: 1, bitsPerComponent: 8, bytesPerRow: 320,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: -89, width: 320, height: 180))
            }
            let exported = centre(Array(rows[(frame * 320)..<(frame * 320 + 320)]))
            let previewed = centre(row)
            previewCentres.append(previewed)
            print("frame \(frame): export centre \(exported) preview centre \(previewed)")
            try require(abs(exported - previewed) <= 3, "Stabilised preview differs from export at frame \(frame)")
        }
        let spread = (previewCentres.max() ?? 0) - (previewCentres.min() ?? 0)
        try require(spread < 5, "Stabilised preview still shakes by \(spread) pixels")
        await backend.close()
        print("PASS live stabilisation preview matches export")
    }

    static func buses(ffmpeg: String, directory: URL) async throws {
        // A 1 kHz tone at −20 dBFS on both channels.
        let tone = directory.appendingPathComponent("tone.mov")
        _ = try run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "aevalsrc='0.1*sin(2*PI*1000*t)':s=48000:d=12", "-ac", "2", "-c:a", "pcm_s24le", tone.path])
        let ai = try await AVURLAsset(url: tone).load(.tracks).firstIndex { $0.mediaType == .audio }!
        let asset = MediaAsset(name: "Tone", originalURL: tone, duration: try RationalTime(12), streams: [MediaStream(index: ai, kind: .audio, audioLayout: .stereo)])
        let template = TrackTemplate(kind: .audio, audioLayout: .stereo)
        let family = TrackFamily(baseName: "Audio", template: template)
        let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(12)),
                                selection: .audio(.init(channels: [.init(streamIndex: ai, channelIndex: 0), .init(streamIndex: ai, channelIndex: 1)], layout: .stereo)))
        var base = Project(settings: try SequenceSettings(width: 64, height: 36, frameRate: FrameRate(25)), assets: [asset], families: [family],
                           tracks: [TimelineTrack(familyID: family.id, template: template, clips: [clip])])
        let main2 = try base.addBus(kind: .main)
        let submix = try base.addBus(kind: .submix)
        try base.updateBus(id: submix) { $0.gain = 0.5; $0.outputs = [AudioBus.defaultMainID, main2] }
        try base.updateBus(id: main2) { $0.effects = [AudioEffect(kind: .limiter(.init(ceiling: -30)))] }
        try base.setTrackBusOutputs(id: base.tracks[0].id, outputs: [submix])
        var eq = ParametricEQ(); eq.bands[2].frequency = 1000; eq.bands[2].gain = 6
        try base.setTrackEffects(id: base.tracks[0].id, effects: [AudioEffect(kind: .equalizer(eq))])

        func previewRMS(_ project: Project, monitor: UUID?) async throws -> Double {
            AVFoundationSequenceBackend.monitoredMain = monitor
            let backend = try AVFoundationSequenceBackend(project: project, videoProxies: [:])
            let item = try await backend.makePlayerItem()
            let reader = try AVAssetReader(asset: item.asset)
            let output = AVAssetReaderAudioMixOutput(audioTracks: try await item.asset.loadTracks(withMediaType: .audio),
                audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
            output.audioMix = item.audioMix
            reader.add(output); reader.startReading()
            var samples: [Float] = []
            while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
                var length = 0; var pointer: UnsafeMutablePointer<CChar>?
                CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
                pointer!.withMemoryRebound(to: Float.self, capacity: length / 4) { samples += UnsafeBufferPointer(start: $0, count: length / 4) }
                AudioMeters.shared.poll()
            }
            await backend.close()
            let middle = samples[(samples.count / 4)..<(samples.count * 3 / 4)]
            return 10 * log10(middle.reduce(0) { $0 + Double($1 * $1) } / Double(middle.count))
        }
        var plain = base
        try plain.setTrackBusOutputs(id: plain.tracks[0].id, outputs: [AudioBus.defaultMainID])
        try plain.setTrackEffects(id: plain.tracks[0].id, effects: [])
        let reference = try await previewRMS(plain, monitor: nil)
        AudioMeters.shared.resetLoudness()
        let main1 = try await previewRMS(base, monitor: AudioBus.defaultMainID)
        // +6 dB EQ at 1 kHz, then the submix at half gain (−6 dB): back to the plain level.
        print("Main 1 through EQ and submix: \(main1 - reference) dB")
        try require(abs(main1 - reference) < 0.3, "Track EQ and submix gain differ from the expected level")
        let loudness = AudioMeters.shared.loudness[AudioBus.defaultMainID]
        // −20 dBFS sine at 1 kHz on two channels reads about −20 LUFS.
        print("Main 1 loudness: \(String(describing: loudness))")
        try require(loudness.map { abs($0.integrated - (-20)) < 1.5 } == true, "Main 1 loudness meter does not read the tone")
        let main2Level = try await previewRMS(base, monitor: main2)
        // The limiter holds Main 2 at its −30 dBFS ceiling (RMS of a clipped-peak sine ≈ −33 dB).
        print("Main 2 through limiter: \(main2Level) dB RMS")
        try require(main2Level < -31 && main2Level > -36, "Monitoring Main 2 does not play the limited mix")
        var unrouted = plain
        try unrouted.setTrackBusOutputs(id: unrouted.tracks[0].id, outputs: [main2])
        let silent = try await previewRMS(unrouted, monitor: AudioBus.defaultMainID)
        try require(silent < -90, "A track sent only to Main 2 is heard on Main 1")
        AVFoundationSequenceBackend.monitoredMain = nil
        print("PASS buses, track effects, monitoring and loudness in preview")
    }
}
