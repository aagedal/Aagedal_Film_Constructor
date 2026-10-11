import Foundation
import Testing
@testable import EditorCore

@Test func parsesNonDropTimecodeAndRejectsMalformedLabels() throws {
    let rate = try FrameRate(24)
    let code = try Timecode(parsing: "01:02:03:04", rate: rate)
    #expect(code == Timecode(frameCount: 89_356))
    #expect(try code.formatted(rate: rate) == "01:02:03:04")
    for label in ["", "1:02:03:04", "01:2:03:04", "01:02:3:04", "01:02:03:4",
                  "24:00:00:00", "00:60:00:00", "00:00:60:00", "00:00:00:24",
                  "-1:00:00:00", "00.00.00:00", "00:00:00;00", "00:00:00:00 ",
                  "00:00:00:٠٠", "00:00:00:ab", "00:00:00:000"] {
        #expect(throws: EditorCoreError.invalidTimecode) { try Timecode(parsing: label, rate: rate) }
    }
    let fractional = try FrameRate(24000, 1001)
    #expect(try Timecode(parsing: "01:00:00:00", rate: fractional).frameCount == 86_400)
}

@Test func parsesDropFrameMinuteAndDayBoundaries() throws {
    let rates: [(Int64, Int64, Int64, Int64, Int64)] = [
        (30_000, 2, 1_800, 17_982, 2_589_408),
        (60_000, 4, 3_600, 35_964, 5_178_816)
    ]
    for (numerator, dropped, perMinute, perTenMinutes, perDay) in rates {
        let rate = try FrameRate(numerator, 1001)
        for minute in [1, 9, 11, 59] {
            for frame in 0..<dropped {
                let label = String(format: "00:%02d:00;%02lld", minute, frame)
                #expect(throws: EditorCoreError.invalidTimecode) { try Timecode(parsing: label, rate: rate) }
            }
        }
        #expect(try Timecode(parsing: String(format: "00:01:00;%02lld", dropped), rate: rate).frameCount == perMinute)
        #expect(try Timecode(parsing: "00:10:00;00", rate: rate).frameCount == perTenMinutes)
        #expect(try Timecode(parsing: "00:00:00;00", rate: rate).frameCount == 0)
        for frame in [0, perMinute - 1, perMinute, perTenMinutes - 1, perTenMinutes, perDay - 1, perDay, Int64.max] {
            let code = Timecode(frameCount: frame, mode: .dropFrame)
            #expect(try Timecode(parsing: code.formatted(rate: rate), rate: rate).frameCount == frame % perDay)
        }
        // Exercise every minute boundary throughout the day, including tenth minutes.
        for minute in 0..<1440 {
            let boundary = Int64(minute) * perMinute - dropped * Int64(minute - minute / 10)
            for frame in max(0, boundary - 1)...(boundary + dropped + 1) {
                let code = Timecode(frameCount: frame, mode: .dropFrame)
                #expect(try Timecode(parsing: code.formatted(rate: rate), rate: rate) == code)
            }
        }
    }
}

@Test func sequenceTimecodeUsesExactFramesAndDisplayOffset() throws {
    let rate = try FrameRate(30000, 1001)
    let start = try Timecode(parsing: "01:00:00;00", rate: rate)
    let settings = try SequenceSettings(frameRate: rate, startTimecode: start)
    #expect(try settings.timecode(at: .zero) == start)
    #expect(try settings.formattedTimecode(at: rate.time(forFrames: 1800)) == "01:01:00;02")
    let subframe = try rate.time(forFrames: 1).multiplied(by: RationalTime(3, 2))
    #expect(try settings.timecode(at: subframe).frameCount == start.frameCount + 1)
    #expect(throws: EditorCoreError.invalidTime) { try settings.timecode(at: RationalTime(-1)) }
    let endOfDay = try SequenceSettings(frameRate: rate, startTimecode: Timecode(frameCount: 2_589_407, mode: .dropFrame))
    #expect(try endOfDay.timecode(at: rate.time(forFrames: 1)).frameCount == 2_589_408)
    #expect(try endOfDay.formattedTimecode(at: rate.time(forFrames: 1)) == "00:00:00;00")
    let overflowing = try SequenceSettings(startTimecode: Timecode(frameCount: .max))
    #expect(throws: EditorCoreError.overflow) { try overflowing.timecode(at: overflowing.frameRate.time(forFrames: 1)) }
}

@Test func timecodeRoundTripsAtAllSupportedNominalWidths() throws {
    for fps: Int64 in [1, 24, 25, 30, 60, 100, 1000] {
        let rate = try FrameRate(fps)
        let perDay = fps * 86_400
        for frame in [0, fps - 1, fps, perDay - 1, perDay, Int64.max] {
            let code = Timecode(frameCount: frame)
            #expect(try Timecode(parsing: code.formatted(rate: rate), rate: rate).frameCount == frame % perDay)
        }
    }
}
