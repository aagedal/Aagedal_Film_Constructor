import Foundation
import Testing
@testable import EditorCore

private func queueJob() throws -> ProxyGenerationJob {
    .init(sourceSnapshot: .init(name: "Source", originalURL: URL(fileURLWithPath: "/tmp/source.mov"),
                                 duration: try RationalTime(1), streams: [.init(index: 0, kind: .video)]),
          sourceFingerprint: .init(fileSize: 10, modificationTime: 20), preset: .h264,
          scaleDivisor: 2, outputURL: URL(fileURLWithPath: "/tmp/source-unique-proxy.mov"))
}

@Test func proxyQueueRoundTripsAndInterruptsOnlyRunningJobs() throws {
    for state in [ProxyGenerationJobState.queued, .running, .interrupted, .cancelled, .failed] {
        var job = try queueJob(); job.state = state
        try job.validate()
        #expect(try JSONDecoder().decode(ProxyGenerationJob.self, from: JSONEncoder().encode(job)) == job)
        job.prepareAfterReopen()
        #expect(job.state == (state == .running ? .interrupted : state))
        #expect(job.state.canResume)
    }
}

@Test func proxyQueueRejectsStaleSourceAndInvalidPublicationMetadata() throws {
    var job = try queueJob()
    #expect(job.matchesSource(job.sourceSnapshot, fingerprint: job.sourceFingerprint))
    var changed = job.sourceSnapshot; changed.duration = try RationalTime(2)
    #expect(!job.matchesSource(changed, fingerprint: job.sourceFingerprint))
    changed = job.sourceSnapshot; changed.originalURL = URL(fileURLWithPath: "/tmp/relinked.mov")
    #expect(!job.matchesSource(changed, fingerprint: job.sourceFingerprint))
    #expect(!job.matchesSource(job.sourceSnapshot, fingerprint: .init(fileSize: 11, modificationTime: 20)))
    job.scaleDivisor = 3
    #expect(throws: (any Error).self) { try job.validate() }
    job.scaleDivisor = 2; job.state = .completed
    #expect(throws: (any Error).self) { try job.validate() }
    job.verifiedProxy = .init(url: job.outputURL, preset: job.preset, sourceFingerprint: job.sourceFingerprint,
                              videoStreamIndex: 0, width: 80, height: 48, frameRate: try RationalTime(24),
                              frameCount: 24, outputIntegrity: .init(fileSize: 100, sha256Hex: String(repeating: "a", count: 64)))
    try job.validate()
    job.prepareAfterReopen()
    #expect(job.state == .completed && !job.state.canResume)
    job.verifiedProxy?.url = URL(fileURLWithPath: "/tmp/wrong.mov")
    #expect(throws: (any Error).self) { try job.validate() }
}
