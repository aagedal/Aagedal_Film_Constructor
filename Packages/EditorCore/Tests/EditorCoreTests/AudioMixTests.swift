import Foundation
import XCTest
@testable import EditorCore

func runFFmpeg(_ ffmpeg: String, _ arguments: [String]) throws -> Data {
    let process = Process(); process.executableURL = URL(fileURLWithPath: ffmpeg); process.arguments = arguments
    let pipe = Pipe(); process.standardOutput = pipe
    let errors = Pipe(); process.standardError = errors
    try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let message = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, String(decoding: message, as: UTF8.self))
    return data
}

final class AudioEffectTests: XCTestCase {
    func testEQBandsAndPersistence() throws {
        var eq = ParametricEQ()
        XCTAssertTrue(eq.biquads(sampleRate: 48000).isEmpty, "The default EQ is flat")
        eq.bands[0].enabled = true; eq.bands[0].frequency = 100
        XCTAssertEqual(eq.response(at: 100), -3, accuracy: 0.1, "A 0.71-Q cut is 3 dB down at its frequency")
        XCTAssertLessThan(eq.response(at: 25), -20)
        XCTAssertEqual(eq.response(at: 5000), 0, accuracy: 0.05)
        eq.bands[2].gain = 6
        XCTAssertEqual(eq.response(at: 500), 6, accuracy: 0.1)
        let effect = AudioEffect(kind: .equalizer(eq))
        XCTAssertEqual(try JSONDecoder().decode(AudioEffect.self, from: JSONEncoder().encode(effect)), effect)
        XCTAssertThrowsError(try AudioEffect(kind: .limiter(LimiterSettings(ceiling: 3))).validate())
        XCTAssertFalse(AudioEffect(enabled: false, kind: .compressor(.init())).isActive)
    }

    func testLimiterNeverExceedsCeiling() {
        let processor = AudioEffectProcessor(effects: [.limiter()], sampleRate: 48000, channels: 2)
        var worst = 0.0
        var frame = [0.0, 0.0]
        for n in 0..<48000 {
            frame[0] = 1.5 * sin(Double(n) * 0.05); frame[1] = 0.2 * frame[0]
            frame.withUnsafeMutableBufferPointer { processor.process($0.baseAddress!) }
            worst = max(worst, abs(frame[0]), abs(frame[1]))
        }
        XCTAssertLessThanOrEqual(worst, pow(10, -1.0 / 20) + 1e-12)
    }

    /// The Swift chain matches FFmpeg's filters on a stereo signal with unequal channels.
    func testEffectChainMatchesFFmpeg() throws {
        guard let ffmpeg = ProcessInfo.processInfo.environment["AFC_FFMPEG"] else { throw XCTSkip("Set AFC_FFMPEG to compare with FFmpeg") }
        var eq = ParametricEQ(); eq.bands[0].enabled = true; eq.bands[1].gain = 4; eq.bands[3].gain = -6
        let effects = [AudioEffect(kind: .equalizer(eq)), AudioEffect(kind: .compressor(.init(threshold: -20, ratio: 4, attack: 5, release: 100, makeup: 3))),
                       AudioEffect(kind: .limiter(.init(ceiling: -2, release: 40)))]
        var input: [Float] = []
        for n in 0..<96000 {
            let amplitude = n < 30000 ? 0.05 : n < 70000 ? 0.9 : 0.3
            input.append(Float(amplitude * sin(2 * .pi * 220 * Double(n) / 48000)))
            input.append(Float(amplitude * 0.5 * sin(2 * .pi * 3000 * Double(n) / 48000)))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("effects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("in.f32")
        try input.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: raw)
        let filters = effects.flatMap { $0.ffmpegFilters(sampleRate: 48000, channels: 2) }.joined(separator: ",")
        let data = try runFFmpeg(ffmpeg, ["-v", "error", "-f", "f32le", "-ar", "48000", "-ac", "2", "-i", raw.path, "-af", "aformat=sample_fmts=dbl," + filters, "-f", "f32le", "-"])
        let expected = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let processor = AudioEffectProcessor(effects: effects, sampleRate: 48000, channels: 2)
        var actual: [Float] = []
        var frame = [0.0, 0.0]
        for i in stride(from: 0, to: input.count, by: 2) {
            frame[0] = Double(input[i]); frame[1] = Double(input[i + 1])
            frame.withUnsafeMutableBufferPointer { processor.process($0.baseAddress!) }
            actual += [Float(frame[0]), Float(frame[1])]
        }
        XCTAssertEqual(expected.count, actual.count)
        let worst = zip(expected, actual).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 1e-4, "Largest sample difference \(worst)")
    }
}

final class AudioBusTests: XCTestCase {
    func testBusesRoutingValidationAndPersistence() throws {
        var project = try DemoProjectFactory.musicCollision()
        XCTAssertEqual(project.mixBuses.map(\.id), [AudioBus.defaultMainID], "A sequence starts with one implicit main bus")
        let main2 = try project.addBus(kind: .main)
        let submix = try project.addBus(kind: .submix)
        XCTAssertEqual(project.mixBuses.map(\.name), ["Main 1", "Main 2", "Submix 1"])
        let track = project.tracks[0].id
        try project.setTrackBusOutputs(id: track, outputs: [submix])
        try project.updateBus(id: submix) { $0.outputs = [AudioBus.defaultMainID, main2]; $0.effects = [.compressor()] }
        XCTAssertThrowsError(try project.updateBus(id: submix) { $0.outputs = [submix] }, "Submixes feed main buses only")
        try project.setTrackEffects(id: track, effects: [.equalizer(), .limiter()])
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
        let plan = try TimelineRenderPlan(project: project)
        XCTAssertFalse(plan.mix.isPlainSum)
        XCTAssertEqual(plan.mix.paths(from: track).map(\.main), [AudioBus.defaultMainID, main2])
        // Removing the submix sends the track back to the first main bus.
        try project.removeBus(id: submix)
        XCTAssertEqual(project.resolvedOutputs(project.tracks[0].template.busOutputs), [AudioBus.defaultMainID])
        try project.removeBus(id: main2)
        XCTAssertThrowsError(try project.removeBus(id: AudioBus.defaultMainID), "The last main bus stays")
        // Buses belong to their sequence.
        try project.addBus(kind: .main)
        let first = project.sequenceID
        try project.createSequence(name: "Two", settings: project.settings)
        XCTAssertEqual(project.mixBuses.count, 1)
        try project.openSequence(id: first)
        XCTAssertEqual(project.mainBuses.count, 2)
        XCTAssertTrue(try FCPXMLExporter.export(project: { var p = project; p.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/mix.wav"); try! p.setTrackEffects(id: track, effects: [.compressor()]); return p }()).report.warnings.contains { $0.hasPrefix("Track effects") })
    }

    func testPlainMixKeepsSingleSumAndStreamsCompile() throws {
        var project = try DemoProjectFactory.musicCollision()
        project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/mix.wav")
        let output = URL(fileURLWithPath: "/private/tmp/mix.mov")
        let plain = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output)
        XCTAssertTrue(plain.filterGraph.contains(":normalize=0,atrim=end_sample=480000[audio]"))
        XCTAssertEqual(plain.audioStreamNames, ["Main 1"])
        let main2 = try project.addBus(kind: .main)
        try project.updateBus(id: main2) { $0.gain = 0.5; $0.effects = [.limiter()] }
        try project.setTrackBusOutputs(id: project.tracks[0].id, outputs: [AudioBus.defaultMainID, main2])
        let plan = try TimelineRenderPlan(project: project)
        let mains = try FFmpegRenderCompiler.compile(plan, outputURL: output, audioStreams: .mains)
        XCTAssertEqual(mains.audioStreamNames, ["Main 1", "Main 2"])
        XCTAssertTrue(mains.arguments.contains("[audio1]"))
        XCTAssertTrue(mains.filterGraph.contains("asplit=2"))
        XCTAssertTrue(mains.filterGraph.contains("volume=0.5:precision=float"))
        let stems = try FFmpegRenderCompiler.compile(plan, outputURL: output, audioStreams: .mainAndTracks)
        XCTAssertEqual(stems.audioStreamNames, ["Main 1", "Music"])
        // Only Main 1 is exported, so Main 2's limiter is not built.
        XCTAssertFalse(stems.filterGraph.contains("aeval"))
    }

    /// Renders a track sent to two main buses (one at half gain with a limiter) plus a track
    /// stem, and measures each decoded stream.
    func testRenderedMultiTrackAudio() throws {
        guard let ffmpeg = ProcessInfo.processInfo.environment["AFC_FFMPEG"] else { throw XCTSkip("Set AFC_FFMPEG to render buses") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("buses-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tone = directory.appendingPathComponent("tone.wav")
        _ = try runFFmpeg(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=f=440:r=48000:d=30,volume=6,pan=stereo|c0=c0|c1=c0", "-c:a", "pcm_s24le", tone.path])
        var project = try DemoProjectFactory.musicCollision()
        project.settings = try SequenceSettings(width: 64, height: 36, frameRate: FrameRate(25))
        project.assets[0].originalURL = tone
        project.tracks[0].template.gain = 1
        let main2 = try project.addBus(kind: .main)
        try project.updateBus(id: main2) { $0.gain = 0.5 }
        let submix = try project.addBus(kind: .submix)
        try project.updateBus(id: submix) { $0.outputs = [AudioBus.defaultMainID, main2]; $0.effects = [AudioEffect(kind: .limiter(.init(ceiling: -12)))] }
        try project.setTrackBusOutputs(id: project.tracks[0].id, outputs: [submix])
        let output = directory.appendingPathComponent("out.mov")
        let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output, audioStreams: .mains)
        _ = try runFFmpeg(ffmpeg, command.arguments)
        func peak(_ stream: Int) throws -> Double {
            let data = try runFFmpeg(ffmpeg, ["-v", "error", "-i", output.path, "-map", "0:a:\(stream)", "-af", "pan=mono|c0=c0", "-f", "f32le", "-"])
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return Double(samples[48000..<96000].map(abs).max() ?? 0)
        }
        XCTAssertEqual(try peak(0), pow(10, -12.0 / 20), accuracy: 0.01, "The submix limiter holds Main 1 at −12 dBFS")
        XCTAssertEqual(try peak(1), 0.5 * pow(10, -12.0 / 20), accuracy: 0.01, "Main 2 is the limited submix at half gain")
        let stems = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: directory.appendingPathComponent("stems.mov"), audioStreams: .mainAndTracks)
        _ = try runFFmpeg(ffmpeg, stems.arguments)
        let probe = try runFFmpeg(ffmpeg.replacingOccurrences(of: "ffmpeg", with: "ffprobe"), ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index:stream_tags=title", "-of", "csv=p=0", directory.appendingPathComponent("stems.mov").path])
        XCTAssertEqual(String(decoding: probe, as: UTF8.self).split(separator: "\n").count, 2)
    }
}

final class LoudnessTests: XCTestCase {
    /// EBU Tech 3341 case 1: a stereo 1 kHz tone at −23 dBFS reads −23 LUFS.
    func testReferenceToneReadsMinus23() {
        let meter = LoudnessMeter(sampleRate: 48000, layout: .stereo)
        let amplitude = pow(10, -23.0 / 20)
        var frame: [Float] = [0, 0]
        for n in 0..<(48000 * 20) {
            let v = Float(amplitude * sin(2 * .pi * 1000 * Double(n) / 48000))
            frame[0] = v; frame[1] = v
            frame.withUnsafeBufferPointer { meter.add(frame: $0.baseAddress!) }
        }
        let reading = meter.reading
        XCTAssertEqual(reading.integrated, -23, accuracy: 0.1)
        XCTAssertEqual(reading.momentary, -23, accuracy: 0.1)
        XCTAssertEqual(reading.shortTerm, -23, accuracy: 0.1)
        XCTAssertEqual(reading.peak, -23, accuracy: 0.05)
        XCTAssertLessThan(reading.range, 0.1)
    }

    /// Relative gating: 20 s at −36 dBFS then 20 s at −23 dBFS; the quiet half is gated out
    /// (EBU Tech 3341 case 3 style), and the range spans the difference.
    func testGatingAndRange() {
        let meter = LoudnessMeter(sampleRate: 48000, layout: .stereo)
        var frame: [Float] = [0, 0]
        for (level, seconds) in [(-36.0, 20), (-23.0, 20)] {
            let amplitude = pow(10, level / 20)
            for n in 0..<(48000 * seconds) {
                let v = Float(amplitude * sin(2 * .pi * 1000 * Double(n) / 48000))
                frame[0] = v; frame[1] = v
                frame.withUnsafeBufferPointer { meter.add(frame: $0.baseAddress!) }
            }
        }
        XCTAssertEqual(meter.reading.integrated, -23, accuracy: 0.1)
        XCTAssertEqual(meter.reading.range, 13, accuracy: 1)
        meter.reset()
        XCTAssertEqual(meter.reading, .silent)
    }
}
