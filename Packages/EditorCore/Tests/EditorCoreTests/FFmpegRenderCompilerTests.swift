import Foundation
import Testing
@testable import EditorCore

@Test func compilerRefusesUnqualifiedMediaAndDestinations() throws {
    var project = try DemoProjectFactory.musicCollision()
    let output = URL(fileURLWithPath: "/private/tmp/output.mov")
    #expect(throws: (any Error).self) { try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output) }
    project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/source.mov")
    let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output)
    #expect(command.videoFrames == 240)
    #expect(command.audioSamples == 480000)
    #expect(command.arguments.last == output.path)
    #expect(command.arguments.contains("-n"))
    #expect(throws: (any Error).self) { try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: URL(fileURLWithPath: "/private/tmp/out.mp4")) }
    #expect(throws: (any Error).self) { try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: project.assets[0].originalURL!) }
    project.assets[0].streams[0].timeOffset = try RationalTime(1, 2)
    let delayed = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output)
    // Audio starting half a second into the asset is padded so sample counts stay in asset time.
    #expect(delayed.filterGraph.contains("aresample=48000,adelay=24000S:all=1,atrim=start_sample=480000:end_sample=720000"))
    project.assets[0].streams[0].timeOffset = try RationalTime(-1, 4)
    let early = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output)
    #expect(early.filterGraph.contains("aresample=48000,atrim=start_sample=492000:end_sample=732000"))
}

@Test func compilerSelectsDeliveryFormatsByContainer() throws {
    var project = try DemoProjectFactory.musicCollision()
    project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/source.mov")
    let plan = try TimelineRenderPlan(project: project)
    let mp4 = URL(fileURLWithPath: "/private/tmp/out.mp4")
    let h264 = try FFmpegRenderCompiler.compile(plan, outputURL: mp4, format: .h264)
    #expect(h264.arguments.contains("libx264") && h264.arguments.contains("aac") && h264.arguments.contains("+faststart"))
    let hevc = try FFmpegRenderCompiler.compile(plan, outputURL: mp4, format: .hevc)
    #expect(hevc.arguments.contains("hevc_videotoolbox") && hevc.arguments.contains("hvc1"))
    let standard = try FFmpegRenderCompiler.compile(plan, outputURL: URL(fileURLWithPath: "/private/tmp/out.mov"), format: .proRes422)
    #expect(standard.arguments.contains("prores_ks") && standard.arguments.contains("pcm_s24le"))
    #expect(throws: (any Error).self) { try FFmpegRenderCompiler.compile(plan, outputURL: URL(fileURLWithPath: "/private/tmp/out.mov"), format: .h264) }
    for format in RenderOutputFormat.allCases {
        let command = try FFmpegRenderCompiler.compile(plan, outputURL: URL(fileURLWithPath: "/private/tmp/out." + format.fileExtension), format: format)
        #expect(command.arguments.contains("-timecode") && command.videoFrames == 240)
    }
}

@Test func compilerKeepsPathsAsArgumentsAndRejectsSubsampleEdits() throws {
    var project = try DemoProjectFactory.musicCollision()
    let path = "/private/tmp/source 'quoted'; $(example).mov"
    project.assets[0].originalURL = URL(fileURLWithPath: path)
    let output = URL(fileURLWithPath: "/private/tmp/output.mov")
    let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output)
    #expect(command.arguments.filter { $0 == path }.count == 4)
    #expect(!command.filterGraph.contains(path))
    project.tracks[0].clips[0].sourceRange.start = try RationalTime(1, 96000)
    #expect(throws: (any Error).self) { try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output) }
}

@Test func compilerFadesRetainExactSubsampleDurationBeforeTimelineDelay() throws {
    var project = try DemoProjectFactory.musicCollision()
    project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/fade-source.mov")
    project.tracks[0].clips[1].fadeIn = .init(duration: try RationalTime(250001, 96000), curve: .equalPower)
    project.tracks[0].clips[1].fadeOut = .init(duration: try RationalTime(4), curve: .linear)
    let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: URL(fileURLWithPath: "/private/tmp/fade-out.mov"))
    #expect(command.audioSamples == 480000)
    #expect(command.filterGraph.contains("(n)*2/250001"))
    #expect(command.filterGraph.contains("(240000-n)*1/192000"))
    #expect(command.filterGraph.contains("sin(PI/2*"))
    #expect(command.filterGraph.contains("val(0)*"))
    #expect(command.filterGraph.contains("val(1)*"))
    // Float conversion precedes gain/envelopes to preserve low-level PCM.
    #expect(command.filterGraph.contains("aformat=sample_fmts=flt,volume=0.8:precision=float,aeval="))
    #expect(command.filterGraph.contains(":channel_layout=stereo,adelay=240000S:all=1"))
}

private func stillExportProject(url: URL) throws -> Project {
    let settings = try SequenceSettings(width: 160, height: 90)
    let template = TrackTemplate(kind: .video)
    let family = TrackFamily(baseName: "Stills", template: template)
    let asset = MediaAsset(name: "Still", originalURL: url, duration: try RationalTime(10), streams: [.init(index: 0, kind: .video)])
    let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(1)), timelineStart: try RationalTime(1), selection: .still)
    return Project(settings: settings, assets: [asset], families: [family], tracks: [.init(familyID: family.id, template: template, clips: [clip])])
}

@Test func compilerClonesFiniteStillFramesAndRetainsAlphaAndScaling() throws {
    var project = try stillExportProject(url: URL(fileURLWithPath: "/private/tmp/transparent.png"))
    for mode in [ScalingMode.fit, .fill, .none] {
        project.tracks[0].clips[0].scalingMode = mode
        let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: URL(fileURLWithPath: "/private/tmp/still-output.mov"))
        #expect(command.videoFrames == 48)
        #expect(command.inputs.count == 1)
        #expect(command.filterGraph.contains("trim=end_frame=1,loop=loop=23:size=1:start=0,settb=expr=1/24,setpts=N+24"))
        #expect(command.filterGraph.contains("format=yuva444p"))
        #expect(command.filterGraph.contains("gte(n,24)*lt(n,48)"))
        #expect(!command.arguments.contains("-loop"))
    }
    project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/animated.gif")
    #expect(throws: (any Error).self) { try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: URL(fileURLWithPath: "/private/tmp/still-output.mov")) }
    project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/transparent.png")
    project.tracks[0].clips[0].sourceRange.start = try RationalTime(1, 48000)
    project.assets[0].streams = []
    let trimmed = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: URL(fileURLWithPath: "/private/tmp/still-output.mov"))
    #expect(trimmed.inputs[0].streamIndex == 0)
    #expect(trimmed.filterGraph.contains("trim=end_frame=1"))
    project.assets[0].streams = [.init(index: 0, kind: .video)]
    project.tracks[0].clips[0].sourceRange.start = .zero
    project.assets[0].streams[0].timeOffset = try RationalTime(1, 24)
    // Stills always use their first decoded frame; a stream offset cannot move it.
    let offsetStill = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: URL(fileURLWithPath: "/private/tmp/still-output.mov"))
    #expect(offsetStill.filterGraph.contains("trim=end_frame=1,loop="))
}

@Test func compilerCoversSampleAlignedAudioEndsWithoutExtendingPCM() throws {
    var project = try DemoProjectFactory.musicCollision()
    project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/audio.wav")
    project.tracks[0].clips = [project.tracks[0].clips[0]]
    project.tracks[0].clips[0].sourceRange.duration = try RationalTime(48001, 48000)
    let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: URL(fileURLWithPath: "/private/tmp/audio-output.mov"))
    #expect(command.videoFrames == 25)
    #expect(command.audioSamples == 48001)
    #expect(command.filterGraph.contains("trim=end_frame=25"))
    #expect(command.filterGraph.contains("atrim=end_sample=48001"))
}

@Test func compilerRejectsNormalizedSymlinkAndHardlinkDestinationAliases() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.mov")
    try Data().write(to: source)
    let symlink = root.appendingPathComponent("symlink.mov")
    let hardlink = root.appendingPathComponent("hardlink.mov")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
    try FileManager.default.linkItem(at: source, to: hardlink)
    var project = try DemoProjectFactory.musicCollision()
    project.assets[0].originalURL = source
    for output in [symlink, hardlink, root.appendingPathComponent("unused/../source.mov")] {
        #expect(throws: (any Error).self) { try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output) }
    }
}
