import Foundation
import Testing
@testable import EditorCore

private func copyFixture() throws -> (Project, [StreamCopyEvidence]) {
    let settings = try SequenceSettings(width: 160, height: 90)
    let asset = MediaAsset(name: "Original", originalURL: URL(fileURLWithPath: "/private/tmp/original.mov"),
                          duration: try RationalTime(10), streams: [.init(index: 0, kind: .video), .init(index: 1, kind: .audio, audioLayout: .stereo)])
    let range = try TimeRange(start: RationalTime(2), duration: RationalTime(1))
    let videoTemplate = TrackTemplate(kind: .video)
    let audioTemplate = TrackTemplate(kind: .audio, audioLayout: .stereo)
    let vf = TrackFamily(baseName: "Picture", template: videoTemplate)
    let af = TrackFamily(baseName: "Sound", template: audioTemplate)
    let selection = AudioSourceSelection(channels: [.init(streamIndex: 1, channelIndex: 0), .init(streamIndex: 1, channelIndex: 1)], layout: .stereo)
    let project = Project(settings: settings, assets: [asset], families: [vf, af], tracks: [
        .init(familyID: vf.id, template: videoTemplate, clips: [.init(assetID: asset.id, sourceRange: range, selection: .video(streamIndex: 0))]),
        .init(familyID: af.id, template: audioTemplate, clips: [.init(assetID: asset.id, sourceRange: range, selection: .audio(selection))])])
    let video = StreamCopyMetadata(codec: "prores", codecParameters: Data([1, 2]), timeBase: try RationalTime(1, 24000),
                                   pixelFormat: "yuv422p10le", colorDescription: "bt709/limited", width: 160, height: 90,
                                   sampleAspectRatio: try RationalTime(1), rotationDegrees: 0, constantFrameRate: settings.frameRate)
    let audio = StreamCopyMetadata(codec: "pcm_s24le", codecParameters: Data([3, 4]), timeBase: try RationalTime(1, 48000),
                                   audioSampleRate: 48000, audioLayout: .stereo)
    let proofs = [video, audio].enumerated().map { index, metadata in
        StreamCopyEvidence(assetID: asset.id, originalURL: asset.originalURL!, sourceFingerprint: Data([9]), streamIndex: index,
                           sourceRange: range, destinationContainer: "mov", metadata: metadata, packetBoundariesExact: true,
                           independentlyDecodableStart: true, outgoingDependenciesComplete: true, rebasedTimestampsExact: true,
                           codecDelayAndPaddingExact: true, containerPreservesStream: true)
    }
    return (project, proofs)
}

@Test func copyAssessmentRequiresEvidenceAndNeverInfersSafetyFromCodecNames() throws {
    let (project, proofs) = try copyFixture()
    let plan = try TimelineRenderPlan(project: project)
    let unknown = try StreamCopyAssessment.assess(plan, destinationContainer: "mov")
    #expect(unknown.video.reasons == [.missingEvidence])
    #expect(unknown.audio.reasons == [.missingEvidence])
    let qualified = try StreamCopyAssessment.assess(plan, destinationContainer: "mov", evidence: proofs)
    #expect(qualified.video.isEligible)
    #expect(qualified.audio.isEligible)
    var unproven = proofs
    unproven[0].metadata.codec = "h264"
    unproven[0].independentlyDecodableStart = false
    unproven[0].outgoingDependenciesComplete = false
    unproven[1].packetBoundariesExact = false
    unproven[1].codecDelayAndPaddingExact = false
    let result = try StreamCopyAssessment.assess(plan, destinationContainer: "mov", evidence: unproven)
    #expect(result.video.reasons == [.unprovenRandomAccess, .incompleteOutgoingDependencies])
    #expect(result.audio.reasons == [.inexactPacketBoundaries, .inexactCodecDelayOrPadding])
}

@Test func copyAssessmentReportsAudioEditsIndependentlyFromPicture() throws {
    var (project, proofs) = try copyFixture()
    project.tracks[1].template.gain = 0.5
    project.tracks[1].clips[0].fadeIn = .init(duration: try RationalTime(1, 2))
    var result = try StreamCopyAssessment.assess(TimelineRenderPlan(project: project), destinationContainer: "mov", evidence: proofs)
    #expect(result.video.isEligible)
    #expect(result.audio.reasons == [.audioProcessing])
    project.tracks[1].template.gain = 1
    project.tracks[1].clips[0].fadeIn = .init()
    project.tracks[1].template.routing = .init(outputChannels: [1, 0])
    result = try StreamCopyAssessment.assess(TimelineRenderPlan(project: project), destinationContainer: "mov", evidence: proofs)
    #expect(result.video.isEligible)
    #expect(result.audio.reasons == [.channelRemapping])
}

@Test func copyAssessmentRequiresExactSourceRangeContainerAndUnambiguousEvidence() throws {
    let (project, proofs) = try copyFixture()
    let plan = try TimelineRenderPlan(project: project)
    var changed = proofs
    changed[0].sourceRange.start = .zero
    changed[1].originalURL = URL(fileURLWithPath: "/private/tmp/replaced.mov")
    var result = try StreamCopyAssessment.assess(plan, destinationContainer: "mov", evidence: changed)
    #expect(result.video.reasons == [.evidenceDoesNotMatch])
    #expect(result.audio.reasons == [.evidenceDoesNotMatch])
    result = try StreamCopyAssessment.assess(plan, destinationContainer: "mp4", evidence: proofs)
    #expect(result.video.reasons == [.evidenceDoesNotMatch])
    #expect(result.audio.reasons == [.evidenceDoesNotMatch])
    result = try StreamCopyAssessment.assess(plan, destinationContainer: "mov", evidence: proofs + [proofs[0]])
    #expect(result.video.reasons == [.ambiguousEvidence])
    #expect(result.audio.isEligible)
    changed = proofs
    changed[0].sourceFingerprint = Data()
    changed[1].containerPreservesStream = false
    result = try StreamCopyAssessment.assess(plan, destinationContainer: "mov", evidence: changed)
    #expect(result.video.reasons == [.evidenceDoesNotMatch])
    #expect(result.audio.reasons == [.incompatibleContainer])
}

@Test func copyAssessmentRejectsGeometryConformingUnknownMetadataAndTimestampChanges() throws {
    let (project, proofs) = try copyFixture()
    var changed = proofs
    changed[0].metadata.width = 1920
    changed[0].metadata.constantFrameRate = try FrameRate(30000, 1001)
    changed[0].metadata.colorDescription = nil
    changed[0].metadata.codecParameters = Data()
    changed[0].rebasedTimestampsExact = false
    changed[1].metadata.audioSampleRate = 44100
    let result = try StreamCopyAssessment.assess(TimelineRenderPlan(project: project), destinationContainer: "mov", evidence: changed)
    #expect(result.video.reasons == [.missingMetadata, .videoGeometryChange, .frameRateChange, .inexactTimestampRebase])
    #expect(result.audio.reasons == [.audioFormatChange])
}

@Test func copyAssessmentRejectsGapsCompositingOffsetsAndSubframeCuts() throws {
    var (project, proofs) = try copyFixture()
    project.tracks[0].clips[0].timelineStart = try RationalTime(1)
    var result = try StreamCopyAssessment.assess(TimelineRenderPlan(project: project), destinationContainer: "mov", evidence: proofs)
    #expect(result.video.reasons.contains(.generatedGapOrTimingChange))
    #expect(result.audio.reasons.contains(.generatedGapOrTimingChange))
    project.tracks[0].clips[0].timelineStart = .zero
    var overlay = project.tracks[0]
    overlay.id = UUID()
    overlay.clips[0].id = UUID()
    project.tracks.append(overlay)
    result = try StreamCopyAssessment.assess(TimelineRenderPlan(project: project), destinationContainer: "mov", evidence: proofs)
    #expect(result.video.reasons == [.multipleComponents])
    #expect(result.audio.isEligible)
    project.tracks.removeLast()
    project.assets[0].streams[0].timeOffset = try RationalTime(1, 24)
    result = try StreamCopyAssessment.assess(TimelineRenderPlan(project: project), destinationContainer: "mov", evidence: proofs)
    #expect(result.video.reasons == [.nonzeroStreamOffset])
    project.assets[0].streams[0].timeOffset = .zero
    project.tracks[0].clips[0].sourceRange.start = try RationalTime(1, 48)
    proofs[0].sourceRange = project.tracks[0].clips[0].sourceRange
    result = try StreamCopyAssessment.assess(TimelineRenderPlan(project: project), destinationContainer: "mov", evidence: proofs)
    #expect(result.video.reasons == [.generatedGapOrTimingChange])
}

@Test func copyAssessmentDefaultsAllPacketAssertionsToUnproven() throws {
    let (project, proofs) = try copyFixture()
    let original = proofs[0]
    let unproven = StreamCopyEvidence(assetID: original.assetID, originalURL: original.originalURL,
                                     sourceFingerprint: original.sourceFingerprint, streamIndex: original.streamIndex,
                                     sourceRange: original.sourceRange, destinationContainer: original.destinationContainer,
                                     metadata: original.metadata)
    let result = try StreamCopyAssessment.assess(TimelineRenderPlan(project: project), destinationContainer: "mov", evidence: [unproven, proofs[1]])
    #expect(result.video.reasons == [.inexactPacketBoundaries, .unprovenRandomAccess, .incompleteOutgoingDependencies,
                                   .inexactTimestampRebase, .inexactCodecDelayOrPadding, .incompatibleContainer])
    #expect(result.audio.isEligible)
}

@Test func copyAssessmentRejectsStillsMissingOriginalsAndPartialAudioSelections() throws {
    var (project, proofs) = try copyFixture()
    project.tracks[0].clips[0].selection = .still
    project.assets[0].originalURL = nil
    var result = try StreamCopyAssessment.assess(TimelineRenderPlan(project: project), destinationContainer: "mov", evidence: proofs)
    #expect(result.video.reasons == [.missingOriginal, .stillImage])
    #expect(result.audio.reasons.contains(.missingOriginal))
    project.assets[0].originalURL = proofs[0].originalURL
    project.tracks.removeFirst()
    project.tracks[0].template.audioLayout = .mono
    project.tracks[0].template.routing = .init(outputChannels: [0])
    project.tracks[0].clips[0].selection = .audio(.init(channels: [.init(streamIndex: 1, channelIndex: 0)], layout: .mono))
    result = try StreamCopyAssessment.assess(TimelineRenderPlan(project: project), destinationContainer: "mov", evidence: proofs)
    #expect(result.video.reasons == [.missingStream])
    #expect(result.audio.reasons == [.channelRemapping])
}
