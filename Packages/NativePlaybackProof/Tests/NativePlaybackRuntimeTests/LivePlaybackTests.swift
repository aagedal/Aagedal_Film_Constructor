import Foundation
import AVFAudio
import Testing
import EditorCore
@testable import NativePlaybackRuntime

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

struct LivePlaybackTests {
    @Test func configurationObserverIsScopedAndRemovedOnRelease() {
        let center = NotificationCenter()
        let engine = NSObject()
        let unrelated = NSObject()
        let counter = NotificationCounter()
        var observer: LiveAudioConfigurationObserver? = LiveAudioConfigurationObserver(
            object: engine, center: center, changed: { counter.increment() })
        #expect(observer != nil)
        center.post(name: .AVAudioEngineConfigurationChange, object: unrelated)
        center.post(name: Notification.Name("unrelated"), object: engine)
        #expect(counter.count == 0)
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        #expect(counter.count == 1)
        observer = nil
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        #expect(counter.count == 1)
    }

    @Test func removingConfigurationObserverReleasesCallbackCaptures() {
        let center = NotificationCenter()
        let engine = NSObject()
        weak var retained: NotificationCounter?
        var observer: LiveAudioConfigurationObserver?
        do {
            let counter = NotificationCounter()
            retained = counter
            observer = LiveAudioConfigurationObserver(object: engine, center: center,
                                                      changed: { counter.increment() })
        }
        #expect(observer != nil)
        #expect(retained != nil)
        observer = nil
        #expect(retained == nil)
    }

    @Test func liveStatisticsEncodeLifecycleFailures() throws {
        var statistics = LivePlaybackStatistics()
        statistics.configurationChanges = 2
        statistics.unexpectedEngineStops = 1
        let decoded = try JSONDecoder().decode(LivePlaybackStatistics.self,
                                               from: JSONEncoder().encode(statistics))
        #expect(decoded.configurationChanges == 2)
        #expect(decoded.unexpectedEngineStops == 1)
    }

    @Test func scheduleIsBoundedAndClockCreatesAdmission() throws {
        var queue = try LiveAudioQueue(total: 20000)
        for _ in 0..<4 { try queue.commit(count: 1024) }
        #expect(queue.scheduled == 4096)
        #expect(queue.nextCount == nil)
        #expect(throws: (any Error).self) { try queue.commit(count: 1) }
        try queue.update(clock: 100)
        #expect(queue.nextCount == nil)
        try queue.update(clock: 1024)
        #expect(queue.nextCount == 1024)
        try queue.commit(count: 1024)
        #expect(queue.scheduled - queue.clock <= 4096)
    }

    @Test func starvationAndRegressingClocksFailWithoutAdvancing() throws {
        var queue = try LiveAudioQueue(total: 10000)
        try queue.commit(count: 1024)
        try queue.update(clock: 100)
        #expect(throws: (any Error).self) { try queue.update(clock: 99) }
        #expect(queue.clock == 100)
        #expect(throws: (any Error).self) { try queue.update(clock: 1025) }
        #expect(queue.clock == 100)
        #expect(throws: (any Error).self) { try queue.update(clock: 1024) }
        #expect(queue.clock == 100)
    }

    @Test func finalPartialBlockAcceptsDeviceOvershoot() throws {
        var queue = try LiveAudioQueue(total: 1500)
        try queue.commit(count: 1024)
        #expect(queue.nextCount == 476)
        try queue.commit(count: 476)
        try queue.update(clock: 1600)
        #expect(queue.clock == 1500)
        #expect(queue.nextCount == nil)
    }

    @Test func liveOutputRejectsSurroundAndChangedSampleGrid() throws {
        try LiveOutputQualification.validate(layout: .mono)
        try LiveOutputQualification.validate(layout: .stereo)
        #expect(throws: (any Error).self) {
            try LiveOutputQualification.validate(layout: ChannelLayout(channels: [.left, .right, .mono]))
        }
        #expect(throws: (any Error).self) {
            try LiveOutputQualification.clock(sample: 10, rate: 44100, expectedRate: 48000)
        }
        #expect(throws: (any Error).self) {
            try LiveOutputQualification.clock(sample: -1, rate: 48000, expectedRate: 48000)
        }
        #expect(try LiveOutputQualification.clock(sample: 1024, rate: 48000, expectedRate: 48000) == 1024)
    }

    @Test func invalidLimitsAndMalformedImagesAreRejected() throws {
        #expect(throws: (any Error).self) { try LiveAudioQueue(total: 0) }
        #expect(throws: (any Error).self) { try LiveAudioQueue(total: 100, blockSize: 65537) }
        #expect(throws: (any Error).self) { try LiveAudioQueue(total: 100, maximumBlocks: 1) }
        #expect(throws: (any Error).self) { try nativeImage(rgb: Data(count: 11), width: 2, height: 2) }
        #expect(try nativeImage(rgb: Data(count: 12), width: 2, height: 2).width == 2)
    }
}
