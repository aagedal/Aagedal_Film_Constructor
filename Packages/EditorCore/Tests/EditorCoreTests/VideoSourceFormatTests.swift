import Foundation
import Testing
@testable import EditorCore

@Test func sourceVideoFormatPersistsExactFractionalRate() throws {
    let format = try VideoSourceFormat(width: 3840, height: 2160, frameRate: FrameRate(30000, 1001))
    let stream = MediaStream(index: 2, kind: .video, timeOffset: try RationalTime(1, 2), videoFormat: format)
    let decoded = try JSONDecoder().decode(MediaStream.self, from: JSONEncoder().encode(stream))
    #expect(decoded == stream)
    #expect(decoded.videoFormat?.frameRate.editableText == "30000/1001")
}

@Test func legacyStreamsDecodeWithoutSourceFormat() throws {
    let stream = MediaStream(index: 0, kind: .video)
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stream)) as? [String: Any])
    json.removeValue(forKey: "videoFormat")
    let decoded = try JSONDecoder().decode(MediaStream.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.videoFormat == nil)
    #expect(decoded == stream)
    #expect(MediaStream(index: 1, kind: .audio, audioLayout: .stereo).videoFormat == nil)
}

@Test func invalidSourceRasterRejectsConstructionAndDecoding() throws {
    for dimension in [0, -1, 65537] {
        #expect(throws: EditorCoreError.invalidSettings) {
            try VideoSourceFormat(width: dimension, height: 1080, frameRate: FrameRate(24))
        }
    }
    var format = try VideoSourceFormat(width: 1920, height: 1080, frameRate: FrameRate(24))
    format.height = 0
    #expect(throws: EditorCoreError.invalidSettings) { try format.validate() }
    #expect(throws: EditorCoreError.invalidSettings) {
        try JSONDecoder().decode(VideoSourceFormat.self, from: JSONEncoder().encode(format))
    }
}
