import Foundation
import EditorCore
import NativePlaybackRuntime

enum ProbeSmokeFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let message) = self { message } else { "" } }
}

/// FFmpeg import probe against AVFoundation `inspect`, unconverted native-only import,
/// conversion fallback, native playback, export and previews of unconverted originals.
@main struct NativeImportProbeSmoke {
    static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw ProbeSmokeFailure.failed(message()) }
    }

    static func t(_ numerator: Int64, _ denominator: Int64 = 1) throws -> RationalTime { try RationalTime(numerator, denominator) }

    static func describe(_ asset: MediaAsset) -> String {
        "duration \(asset.duration), timecode \(String(describing: asset.sourceTimecodeStart)), streams \(asset.streams)"
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let ffmpeg = URL(fileURLWithPath: CommandLine.arguments[2])
        let ffprobe = URL(fileURLWithPath: CommandLine.arguments[3])
        func file(_ name: String) -> URL { root.appendingPathComponent(name) }

        // 1. Parity: files both readers open must produce identical assets.
        let exact = ["h264-24-pcm.mov", "prores-23976-aac51-tc.mov", "h264-2997-aac-tc.mp4", "h264-2997-df-tc.mov",
                     "ffv1-pcm51.mov", "dnxhr-50.mov", "mono.wav", "stereo.flac"]
        // Known reader differences, pinned so either side changing is noticed:
        // - An empty edit before MOV audio lies inside AVFoundation's track range (offset 0);
        //   FFmpeg reports where samples begin, which is what export aligns by.
        // - Audio-only AAC/Opus encoder delay is trimmed differently by each reader.
        struct Reading { let duration: RationalTime; let offsets: [RationalTime] }
        let pinned: [String: (avf: Reading, ffmpeg: Reading)] = [
            "offset-audio.mov": (Reading(duration: try t(2), offsets: [.zero, .zero]), Reading(duration: try t(2), offsets: [.zero, try t(1, 2)])),
            "stereo.m4a": (Reading(duration: try t(70912, 48000), offsets: [.zero]), Reading(duration: try t(3, 2), offsets: [.zero])),
            "mono.opus": (Reading(duration: try t(38, 25), offsets: [.zero]), Reading(duration: try t(3013, 2000), offsets: [.zero]))
        ]
        var parityCount = 0
        for name in exact + pinned.keys.sorted() {
            let avf = try await MediaImporter.inspect(url: file(name)).asset
            let probe = try await MediaImporter.inspectNative(url: file(name), requiresNativePlayback: false).asset
            if let expectation = pinned[name] {
                try check(avf.duration == expectation.avf.duration && avf.streams.map(\.timeOffset) == expectation.avf.offsets,
                          "\(name): AVFoundation reading changed: \(describe(avf))")
                try check(probe.duration == expectation.ffmpeg.duration && probe.streams.map(\.timeOffset) == expectation.ffmpeg.offsets,
                          "\(name): FFmpeg reading changed: \(describe(probe))")
                var aligned = probe
                aligned.duration = avf.duration
                for index in aligned.streams.indices { aligned.streams[index].timeOffset = avf.streams[index].timeOffset }
                try check(aligned.streams == avf.streams && aligned.sourceTimecodeStart == avf.sourceTimecodeStart,
                          "\(name): parity outside the pinned difference\n  AVF \(describe(avf))\n  FFM \(describe(probe))")
            } else {
                try check(probe.duration == avf.duration && probe.streams == avf.streams &&
                          probe.sourceTimecodeStart == avf.sourceTimecodeStart,
                          "\(name): parity\n  AVF \(describe(avf))\n  FFM \(describe(probe))")
            }
            parityCount += 1
        }
        // Spot-check the parity values themselves.
        let df = try await MediaImporter.inspectNative(url: file("h264-2997-df-tc.mov"), requiresNativePlayback: false).asset
        try check(df.sourceTimecodeStart == (try t(107_890).multiplied(by: t(1001, 30000))), "Drop-frame 00:59:59;28 start: \(describe(df))")
        let surround = try await MediaImporter.inspectNative(url: file("ffv1-pcm51.mov"), requiresNativePlayback: false).asset
        try check(surround.streams[1].audioLayout == .surround51, "5.1 layout in FFmpeg order")

        // 2. Native-only media: AVFoundation refuses, the probe reads exact values.
        let video24 = try VideoSourceFormat(width: 320, height: 180, frameRate: FrameRate(24))
        let video25 = try VideoSourceFormat(width: 320, height: 180, frameRate: FrameRate(25))
        let dnx25 = try VideoSourceFormat(width: 640, height: 360, frameRate: FrameRate(25))
        struct Expectation { let duration: RationalTime; let formats: [VideoSourceFormat?]; let layouts: [ChannelLayout]
            let offsets: [RationalTime]; let timecode: RationalTime?; let playable: Bool }
        let unknown6 = ChannelLayout(channels: Array(repeating: nil, count: 6))
        let nativeOnly: [(String, Expectation)] = [
            ("ffv1-pcm.nut", Expectation(duration: try t(2), formats: [video24], layouts: [.stereo], offsets: [.zero, .zero], timecode: nil, playable: true)),
            ("utvideo-pcm6.nut", Expectation(duration: try t(2), formats: [video25], layouts: [unknown6], offsets: [.zero, .zero], timecode: nil, playable: true)),
            ("dnxhr-tc.mxf", Expectation(duration: try t(2), formats: [dnx25], layouts: [.mono], offsets: [.zero, .zero], timecode: try t(36000), playable: true)),
            // Matroska's millisecond clock: 25 fps (40 ms) proves a cadence, PCM packets miss the sample grid.
            ("ffv1-25-pcm.mkv", Expectation(duration: try t(2), formats: [video25], layouts: [.mono], offsets: [.zero, .zero], timecode: nil, playable: false)),
            // 24 fps alternates 41/42 ms ticks; no cadence is proven and the duration is the ms extent.
            ("ffv1-24.mkv", Expectation(duration: try t(1999, 1000), formats: [nil], layouts: [], offsets: [.zero], timecode: nil, playable: false)),
            ("ffv1-offset-audio.nut", Expectation(duration: try t(2), formats: [video24], layouts: [.mono], offsets: [.zero, try t(1, 2)], timecode: nil, playable: false)),
            ("ffv1-opus.mkv", Expectation(duration: try t(251, 125), formats: [nil], layouts: [.mono], offsets: [try t(7, 1000), .zero], timecode: nil, playable: false))
        ]
        let converter = MediaConversionService(ffmpegURL: ffmpeg, ffprobeURL: ffprobe, outputDirectory: file("converted"))
        try FileManager.default.createDirectory(at: file("converted"), withIntermediateDirectories: true)
        var admitted: [String: MediaAsset] = [:]
        for (name, expected) in nativeOnly {
            let opened = (try? await MediaImporter.inspect(url: file(name))) != nil
            try check(!opened, "\(name): AVFoundation opened the native-only fixture")
            let probe = try NativeMediaProbe(url: file(name))
            let video = probe.streams.filter { $0.kind == .video }, audio = probe.streams.filter { $0.kind == .audio }
            try check(probe.duration == expected.duration && video.map(\.videoFormat) == expected.formats &&
                      audio.compactMap(\.audioLayout) == expected.layouts && probe.streams.map(\.timeOffset) == expected.offsets &&
                      probe.sourceTimecodeStart == expected.timecode,
                      "\(name): probe \(probe.duration) \(probe.streams) timecode \(String(describing: probe.sourceTimecodeStart))")
            let playable = (try? probe.verifyNativePlayback(url: file(name))) != nil
            try check(playable == expected.playable, "\(name): native playback admission \(playable)")
            var converted = false
            let imported = try await MediaImporter.inspectOrConvert(url: file(name), using: converter) { converted = true }
            try check(converted != expected.playable, "\(name): conversion \(converted), expected \(!expected.playable)")
            if expected.playable {
                try check(imported.asset.originalURL == file(name) && imported.asset.duration == probe.duration &&
                          imported.asset.streams == probe.streams && imported.asset.sourceTimecodeStart == probe.sourceTimecodeStart,
                          "\(name): unconverted import differs from probe")
                admitted[name] = imported.asset
            } else {
                try check(imported.asset.originalURL?.pathExtension == "mov" && imported.asset.originalURL != file(name),
                          "\(name): fallback did not convert")
            }
        }

        // 3. Unconverted originals play natively (full decoded-frame qualification) and export.
        let export = SequenceExportService(ffmpegURL: ffmpeg, ffprobeURL: ffprobe)
        for (name, rate, width, height) in [("ffv1-pcm.nut", 24, 320, 180), ("dnxhr-tc.mxf", 25, 640, 360)] {
            guard let asset = admitted[name] else { throw ProbeSmokeFailure.failed("\(name) was not admitted") }
            var project = Project(settings: try SequenceSettings(width: width, height: height, frameRate: FrameRate(Int64(rate))))
            try project.addAsset(asset)
            _ = try project.appendAsset(asset.id, at: .zero)
            let session = try NativePlaybackSession(project: project)
            let frame = try await session.video(frame: Int64(rate) + 3)
            try check(frame.value.count == width * height * 3, "\(name): native frame size")
            let sound = try await session.audio(start: 48000, count: 4800)
            try check(sound.value.contains { abs($0) > 0.05 }, "\(name): native audio is silent")
            await session.close()
            let output = file("export-\(name).mov")
            let result = try await export.export(plan: TimelineRenderPlan(project: project), to: output)
            try check(result.videoFrames == Int64(2 * rate) && result.audioSamples == 96000,
                      "\(name): export counts \(result.videoFrames) frames, \(result.audioSamples) samples")
        }

        // 4. Timeline previews of originals AVFoundation cannot read.
        let thumbnails = try NativeMediaPreview.thumbnails(url: file("ffv1-pcm.nut"), streamIndex: 0, times: [0.1, 1, 1.9],
                                                            maximumWidth: 180, maximumHeight: 100)
        try check(thumbnails.count == 3 && thumbnails.allSatisfy { $0.width == 178 && $0.height == 100 }, "Thumbnail sizes")
        let peaks = try NativeMediaPreview.peaks(url: file("dnxhr-tc.mxf"), streamIndex: 1, channels: [0], start: 0.5, duration: 1, bins: 20)
        try check(peaks.count == 1 && peaks[0].count == 20 && peaks[0].allSatisfy { $0 > 0.05 && $0 <= 1 }, "Waveform peaks \(peaks)")

        print("Native import probe smoke passed: \(parityCount) parity files (\(pinned.count) pinned reader differences), "
              + "\(nativeOnly.count) native-only fixtures (\(admitted.count) imported unconverted, \(nativeOnly.count - admitted.count) converted), "
              + "native playback and export of unconverted NUT/MXF, thumbnails and waveform peaks")
    }
}
