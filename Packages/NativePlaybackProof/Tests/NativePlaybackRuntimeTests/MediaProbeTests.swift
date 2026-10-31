import Foundation
import Testing
import EditorCore
@testable import NativePlaybackRuntime

private let ffmpegPath = ProcessInfo.processInfo.environment["AFC_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg"

/// Exact probe readings of media AVFoundation cannot open. AVFoundation parity is
/// covered by scripts/native-import-probe-smoke.py, which runs the app's importer.
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: ffmpegPath),
                "Requires the local FFmpeg fixture generator (AFC_FFMPEG)."))
struct MediaProbeTests {
    private func fixture(_ name: String, _ arguments: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + arguments + [url.path]
        let errors = Pipe(); process.standardError = errors
        try process.run()
        let details = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProofFailure(String(decoding: details, as: UTF8.self)) }
        return url
    }

    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    @Test func nutFrameGridAndPCMAreExactAndNativelyPlayable() throws {
        let url = try fixture("source.nut", ["-f", "lavfi", "-i", "testsrc2=size=64x36:rate=24000/1001:duration=1",
            "-f", "lavfi", "-i", "sine=sample_rate=48000:duration=1", "-c:v", "ffv1", "-c:a", "pcm_s16le", "-ac", "2"])
        defer { remove(url) }
        let probe = try NativeMediaProbe(url: url)
        #expect(probe.formatName == "nut")
        // 24 frames of 1001/24000 s outlast the 1 s of audio.
        #expect(probe.duration == (try RationalTime(1001, 1000)))
        #expect(probe.streams.map(\.index) == [0, 1])
        #expect(probe.streams[0].videoFormat == (try VideoSourceFormat(width: 64, height: 36, frameRate: FrameRate(24000, 1001))))
        #expect(probe.streams[1].audioLayout == .stereo)
        #expect(probe.streams.allSatisfy { $0.timeOffset == .zero })
        #expect(probe.sampleExactAudio == [1])
        #expect(probe.codecs == [0: "ffv1", 1: "pcm_s16le"])
        #expect(probe.sourceTimecodeStart == nil)
        try probe.verifyNativePlayback(url: url)
    }

    @Test func matroskaMillisecondClockLeavesCadenceUnproven() throws {
        let url = try fixture("source.mkv", ["-f", "lavfi", "-i", "testsrc2=size=64x36:rate=24:duration=1", "-c:v", "ffv1"])
        defer { remove(url) }
        let probe = try NativeMediaProbe(url: url)
        // Frames alternate 41 and 42 ms; the extent is the last millisecond timestamp plus its duration.
        #expect(probe.streams[0].videoFormat == nil)
        #expect(probe.duration == (try RationalTime(999, 1000)))
        #expect(throws: ProofFailure.self) { try probe.verifyNativePlayback(url: url) }
    }

    @Test func mxfTimecodeOffsetsAndSurroundLayout() throws {
        let mxf = try fixture("source.mxf", ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=1",
            "-c:v", "dnxhd", "-profile:v", "dnxhr_lb", "-pix_fmt", "yuv422p", "-timecode", "01:00:00:12"])
        defer { remove(mxf) }
        #expect(try NativeMediaProbe(url: mxf).sourceTimecodeStart == (try RationalTime(90012, 25)))

        let offset = try fixture("offset.nut", ["-f", "lavfi", "-i", "testsrc2=size=64x36:rate=25:duration=1",
            "-itsoffset", "0.25", "-f", "lavfi", "-i", "sine=sample_rate=48000:duration=1",
            "-map", "0", "-map", "1", "-c:v", "ffv1", "-c:a", "pcm_s16le"])
        defer { remove(offset) }
        let shifted = try NativeMediaProbe(url: offset)
        #expect(shifted.streams.map(\.timeOffset) == [.zero, try RationalTime(1, 4)])
        #expect(shifted.duration == (try RationalTime(5, 4)))
        // The native decoder requires zero-origin streams; this media must be converted.
        #expect(throws: ProofFailure.self) { try shifted.verifyNativePlayback(url: offset) }

        let surround = try fixture("surround.mov", ["-f", "lavfi", "-i", "sine=sample_rate=48000:duration=1",
            "-c:a", "pcm_s24le", "-af", "pan=5.1(side)|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0"])
        defer { remove(surround) }
        #expect(try NativeMediaProbe(url: surround).streams[0].audioLayout == .surround51)
    }

    @Test func previewsReadAnyDecodableStream() throws {
        let url = try fixture("source.mkv", ["-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24:duration=1",
            "-f", "lavfi", "-i", "sine=sample_rate=48000:duration=1", "-c:v", "ffv1", "-c:a", "libopus"])
        defer { remove(url) }
        let images = try NativeMediaPreview.thumbnails(url: url, streamIndex: 0, times: [0, 0.5], maximumWidth: 80, maximumHeight: 80)
        #expect(images.map(\.width) == [80, 80] && images.map(\.height) == [45, 45])
        let peaks = try NativeMediaPreview.peaks(url: url, streamIndex: 1, channels: [0], start: 0.25, duration: 0.5, bins: 10)
        #expect(peaks.count == 1 && peaks[0].allSatisfy { $0 > 0.05 && $0 <= 1 })
        #expect(throws: ProofFailure.self) { try NativeMediaPreview.peaks(url: url, streamIndex: 0, channels: [0], start: 0, duration: 1, bins: 10) }
    }
}
