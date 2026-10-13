import Testing
@testable import EditorCore

@Test func frameRateTextParsesExactValues() throws {
    let cases: [(String, Int64, Int64)] = [
        ("24", 24, 1), (" \n25\t", 25, 1), ("00024", 24, 1),
        ("29.97", 2997, 100), ("23.976", 2997, 125), ("24.000", 24, 1),
        ("0.000000000000000001", 1, 1_000_000_000_000_000_000),
        ("30000/1001", 30000, 1001), ("60000/2002", 30000, 1001),
        ("1000", 1000, 1), ("9223372036854775807/9223372036854775807", 1, 1)
    ]
    for (text, numerator, denominator) in cases {
        #expect(try FrameRate(parsing: text) == FrameRate(numerator, denominator))
    }
    #expect(try !FrameRate(parsing: "29.97").supportsDropFrame)
    #expect(try FrameRate(parsing: "30000/1001").supportsDropFrame)
}

@Test func frameRateTextRejectsInvalidAndUnrepresentableValues() {
    for text in ["", " \n", "0", "0.0", "0/1", "24/0", "-24", "+24", "24/-1",
                 "24/", "/1", "24/1/1", "24 /1", "24/ 1", "24.0/1", ".5", "24.",
                 "24..0", "2 4", "２４", "NaN", "inf", "2.4e1", "24,0", "1_000",
                 "1001", "1000.001", "1000001/1000", "9223372036854775808",
                 "1/9223372036854775808", "0.0000000000000000001", "24.000000000000000000"] {
        #expect(throws: EditorCoreError.invalidFrameRate) { try FrameRate(parsing: text) }
    }
}

@Test func frameRateUpperBoundUsesExactComparison() throws {
    // Double rounds this rate to 1000 despite the rational being slightly greater.
    #expect(throws: EditorCoreError.invalidFrameRate) {
        try FrameRate(parsing: "1000000000000000001/1000000000000000")
    }
    #expect(try FrameRate(parsing: "999999999999999999/1000000000000000").value.numerator == 999999999999999999)
}

@Test func frameRateEditableTextPreservesExactRates() throws {
    for rate in try [FrameRate(24), FrameRate(2997, 100), FrameRate(24000, 1001),
                 FrameRate(30000, 1001), FrameRate(60000, 1001),
                 FrameRate(1, .max), FrameRate(.max, .max - 1)] {
        #expect(try FrameRate(parsing: rate.editableText) == rate)
    }
    #expect(try FrameRate(24).editableText == "24")
    #expect(try FrameRate(30000, 1001).editableText == "30000/1001")
}
