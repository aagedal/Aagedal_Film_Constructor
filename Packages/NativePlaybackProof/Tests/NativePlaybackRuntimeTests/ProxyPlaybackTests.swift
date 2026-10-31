import Foundation
import Testing
import EditorCore
@testable import NativePlaybackRuntime

struct ProxyPlaybackTests {
    private func fixture(original: URL = URL(fileURLWithPath: "/private/tmp/source.nut"), proxyURL: URL = URL(fileURLWithPath: "/private/tmp/proxy.nut")) throws -> (Project, MediaProxy) {
        let rate = try FrameRate(30)
        let video = MediaStream(index: 1, kind: .video,
                                videoFormat: try VideoSourceFormat(width: 8, height: 4, frameRate: rate))
        let asset = MediaAsset(name: "Source", originalURL: original, duration: try rate.time(forFrames: 60),
                               streams: [.init(index: 0, kind: .audio, audioLayout: .mono), video])
        let videoTemplate = TrackTemplate(kind: .video)
        let audioTemplate = TrackTemplate(kind: .audio, audioLayout: .mono)
        let videoFamily = TrackFamily(baseName: "V", template: videoTemplate)
        let audioFamily = TrackFamily(baseName: "A", template: audioTemplate)
        let range = try TimeRange(start: rate.time(forFrames: 30), duration: rate.time(forFrames: 30))
        let videoClip = TimelineClip(assetID: asset.id, sourceRange: range, selection: .video(streamIndex: 1))
        let audioClip = TimelineClip(assetID: asset.id, sourceRange: range,
                                    selection: .audio(.init(channels: [.init(streamIndex: 0, channelIndex: 0)], layout: .mono)))
        let project = Project(settings: try SequenceSettings(width: 12, height: 8, frameRate: rate, audioLayout: .mono),
            assets: [asset], families: [videoFamily, audioFamily], tracks: [
                .init(familyID: videoFamily.id, template: videoTemplate, clips: [videoClip]),
                .init(familyID: audioFamily.id, template: audioTemplate, clips: [audioClip])])
        let proxy = MediaProxy(url: proxyURL, preset: .proResProxy,
            sourceFingerprint: .init(fileSize: 1, modificationTime: 1), videoStreamIndex: 1,
            width: 4, height: 2, frameRate: rate.value, frameCount: 60,
            outputIntegrity: .init(fileSize: 1, sha256Hex: String(repeating: "a", count: 64)))
        return (project, proxy)
    }

    @Test func selectionsAreExplicitAndDoNotRewritePlanOrAudio() throws {
        let (project, proxy) = try fixture()
        #expect(try NativeProxySelection.compile(project: project, videoProxies: [:]).isEmpty)
        let selections = try NativeProxySelection.compile(project: project, videoProxies: [project.assets[0].id: proxy])
        #expect(selections.count == 1)
        let monitor = try NativeMonitor(project: project, videoProxies: [project.assets[0].id: proxy])
        let request = try #require(try monitor.plan.videoFrame(at: 0))
        #expect(request.url == project.assets[0].originalURL)
        #expect(request.streamIndex == 1)
        #expect(request.sourceFrame == 30)
        #expect(try monitor.plan.audioBlock(startSample: 0, sampleCount: 100).first?.url == project.assets[0].originalURL)
        #expect(project.assets[0].proxy == nil)
    }

    @Test func rejectsUnqualifiedMetadataAndRetainsPriorSession() async throws {
        let (project, proxy) = try fixture()
        let assetID = project.assets[0].id
        let session = try NativePlaybackSession(project: project, videoProxies: [assetID: proxy])
        let epoch = await session.epoch
        for variant in 0..<6 {
            var invalid = proxy
            switch variant {
            case 0: invalid.frameRate = try RationalTime(24)
            case 1: invalid.frameCount = 59
            case 2: invalid.width = 6
            case 3: invalid.outputIntegrity = nil
            case 4: invalid.height = 8192
            default: invalid.videoStreamIndex = 2
            }
            #expect(throws: (any Error).self) {
                try NativeProxySelection.compile(project: project, videoProxies: [assetID: invalid])
            }
            do { try await session.replace(project: project, videoProxies: [assetID: invalid]); Issue.record("Accepted invalid proxy") }
            catch {}
            #expect(await session.epoch == epoch)
        }
        var noFormat = project
        noFormat.assets[0].streams[1].videoFormat = nil
        #expect(throws: (any Error).self) { try NativeProxySelection.compile(project: noFormat, videoProxies: [assetID: proxy]) }
        await session.close()
    }

    private func ffmpeg(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AFC_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + arguments
        let errors = Pipe(); process.standardError = errors
        try process.run()
        let details = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProofFailure(String(decoding: details, as: UTF8.self)) }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath:
        ProcessInfo.processInfo.environment["AFC_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg"),
        "Requires the local FFmpeg fixture generator (AFC_FFMPEG)."))
    func decodedProxyPreservesTrimGeometryAndOriginalPCMForEveryScalingMode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.mov")
        let proxyURL = directory.appendingPathComponent("proxy.mov")
        try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2",
                    "-f", "lavfi", "-i", "color=red:size=8x4:rate=30:duration=1",
                    "-f", "lavfi", "-i", "color=blue:size=8x4:rate=30:duration=1",
                    "-filter_complex", "[1:v][2:v]concat=n=2:v=1:a=0[v]", "-map", "0:a", "-map", "[v]",
                    "-c:a", "pcm_f32le", "-c:v", "ffv1", original.path])
        try ffmpeg(["-i", original.path, "-map", "0:1", "-an", "-vf", "scale=4:2", "-c:v", "ffv1", proxyURL.path])
        var (project, proxy) = try fixture(original: original, proxyURL: proxyURL)
        let assetID = project.assets[0].id
        for mode in [ScalingMode.fit, .fill, .none] {
            project.tracks[0].clips[0].scalingMode = mode
            let full = try NativeMonitor(project: project)
            let reduced = try NativeMonitor(project: project, videoProxies: [assetID: proxy])
            for frame: Int64 in [0, 29, 10, 0] {
                let expected = try full.video(frame: frame)
                #expect(try reduced.video(frame: frame) == expected)
                #expect(expected.contains(where: { $0 > 200 }))
            }
            let expectedPCM = try full.audio(start: 17, count: 512)
            #expect(try reduced.audio(start: 17, count: 512) == expectedPCM)
            #expect(expectedPCM.contains(where: { abs($0) > 0.05 }))
        }
        let session = try NativePlaybackSession(project: project, videoProxies: [assetID: proxy])
        let first = try await session.video(frame: 0)
        try await session.replace(project: project)
        #expect(await session.accepts(first.epoch) == false)
        #expect(try await session.video(frame: 0).value == first.value)
        await session.close()
    }
}
