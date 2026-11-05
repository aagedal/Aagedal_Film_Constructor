import Foundation
import Testing
import EditorCore
@testable import NativePlaybackRuntime

private let ffmpegPath = ProcessInfo.processInfo.environment["AFC_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg"

/// Compressed audio must decode as FFmpeg export does (priming trimmed, sample 0 at the
/// first decoded sample) and seek to the same samples a sequential decode produces.
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: ffmpegPath),
                "Requires the local FFmpeg fixture generator (AFC_FFMPEG)."))
struct CompressedAudioTests {
    private static let sampleRate = 48000
    // A rising chirp on the left and a falling one on the right, so any shift or channel swap shows.
    private static let source = ["-f", "lavfi", "-i",
        "aevalsrc=0.5*sin(2*PI*(200+400*t)*t)|0.4*sin(2*PI*(2000-300*t)*t):s=48000:d=3"]

    private func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let details = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProofFailure(String(decoding: details, as: UTF8.self)) }
        return data
    }

    private func fixture(_ name: String, _ codec: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        _ = try run(Self.source + codec + [url.path])
        return url
    }

    /// FFmpeg's own decode of the first audio stream, as export reads it.
    private func reference(_ url: URL) throws -> [Float] {
        let data = try run(["-i", url.path, "-map", "0:a:0", "-c:a", "pcm_f32le", "-f", "f32le", "-"])
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func read(_ decoder: SourceDecoder, start: Int64, count: Int) throws -> [Float] {
        try decoder.audio(start: start, count: count, sampleRate: Self.sampleRate)
    }

    private func sequential(_ url: URL, frames: Int) throws -> [Float] {
        let decoder = try SourceDecoder(url: url, streamIndex: 0)
        var samples: [Float] = []
        var start = 0
        while start < frames {
            let count = min(4000, frames - start)
            samples += try read(decoder, start: Int64(start), count: count)
            start += count
        }
        return samples
    }

    @Test(arguments: [
        ("aac.mov", ["-c:a", "aac", "-b:a", "160k"]),
        ("aac.nut", ["-c:a", "aac", "-b:a", "160k"]),
        ("mp3.mov", ["-c:a", "libmp3lame", "-b:a", "192k"]),
        ("mp3.nut", ["-c:a", "libmp3lame", "-b:a", "192k"]),
        ("mp3.avi", ["-c:a", "libmp3lame", "-b:a", "192k"]),
        ("mp2.nut", ["-c:a", "mp2", "-b:a", "192k"]),
        ("ac3.mov", ["-c:a", "ac3"]),
        ("eac3.mp4", ["-c:a", "eac3"]),
        ("flac.mp4", ["-c:a", "flac"]),
        ("opus.mp4", ["-c:a", "libopus"]),
        ("vorbis.ogg", ["-c:a", "vorbis", "-strict", "experimental"]),
    ])
    func decodesAsExportAndSeeksExactly(name: String, codec: [String]) throws {
        let url = try fixture(name, codec)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let expected = try reference(url)
        let decoder = try SourceDecoder(url: url, streamIndex: 0)
        #expect(decoder.channels == 2 && decoder.sampleRate == Self.sampleRate)
        let frames = expected.count / 2
        #expect(frames >= 3 * Self.sampleRate - 2048, "decoded \(frames) samples")

        // Sequential blocks reproduce FFmpeg's decode, including where priming ends.
        let whole = try sequential(url, frames: frames)
        #expect(whole.count == expected.count)
        let difference = zip(whole, expected).map { abs($0 - $1) }.max() ?? 0
        #expect(difference <= 1e-6, "largest difference from FFmpeg's decode: \(difference)")
        #expect(throws: ProofFailure.self) { try read(decoder, start: Int64(frames) - 10, count: 11) }

        // Random access, backward jumps and short forward hops all land on the same samples.
        let starts: [Int64] = [Int64(frames) - 4800, 0, 1, 1023, 1024, 1151, 1152, 47_000, 96_000, 95_999, 12_345,
                               12_345 + 2400, 12_345 + 4800 + 30_000, 140_000, 3, 70_001]
        for start in starts {
            let block = try read(decoder, start: start, count: 2400)
            let offset = Int(start) * 2
            #expect(block == Array(whole[offset..<offset + block.count]), "\(name) differs at sample \(start)")
        }
    }

    @Test func opusWithoutContainerPrimingIsRefused() throws {
        // NUT carries no skip-samples timing, so Opus pre-skip leaves the first decoded
        // sample at 312: export would place it there too, so neither path admits it.
        let url = try fixture("opus.nut", ["-c:a", "libopus"])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: ProofFailure.self) { try SourceDecoder(url: url, streamIndex: 0) }
    }

    @Test func matroskaMillisecondAudioIsNotSampleExact() throws {
        let url = try fixture("aac.mkv", ["-c:a", "aac"])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let probe = try NativeMediaProbe(url: url)
        #expect(probe.sampleExactAudio.isEmpty)
        #expect(throws: ProofFailure.self) { try probe.verifyNativePlayback(url: url) }
    }

    @Test func primedAudioBesideFFV1IsAdmittedAtZero() throws {
        // AVFoundation opens this MOV but cannot decode FFV1. The AAC priming packet
        // starts at -1024 and is trimmed, so both streams begin at asset zero.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ffv1-aac.mov")
        _ = try run(["-f", "lavfi", "-i", "testsrc2=size=64x36:rate=25:duration=2"] + Self.source +
                    ["-map", "0", "-map", "1", "-t", "2", "-c:v", "ffv1", "-c:a", "aac", url.path])
        let probe = try NativeMediaProbe(url: url)
        #expect(probe.sampleExactAudio == [1])
        #expect(probe.streams.map(\.timeOffset) == [.zero, .zero])
        try probe.verifyNativePlayback(url: url)
    }

    @Test(arguments: [
        ("vorbis.ogg", ["-c:a", "vorbis", "-strict", "experimental"]),
        ("mp3.mov", ["-c:a", "libmp3lame"]),
        ("ac3.mov", ["-c:a", "ac3"]),
    ])
    func undeclaredEncoderDelayIsRefused(name: String, codec: [String]) throws {
        // These containers keep the encoder's delay as packets before zero that are not marked
        // as discarded. The decoder (and export) start later, so packet offsets would misplace
        // the sound against the picture; such media is converted instead.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        let picture = name.hasSuffix(".mov") ? ["-f", "lavfi", "-i", "testsrc2=size=64x36:rate=25:duration=2"] : []
        let maps = picture.isEmpty ? [] : ["-map", "0", "-map", "1", "-c:v", "ffv1", "-t", "2"]
        _ = try run(picture + Self.source + maps + codec + [url.path])
        let probe = try NativeMediaProbe(url: url)
        #expect(throws: ProofFailure.self) { try probe.verifyNativePlayback(url: url) }
    }
}
