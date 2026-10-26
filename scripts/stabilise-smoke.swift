import EditorCore
import Foundation

/// Shaky synthetic footage stabilised by the app's service moves less from frame to frame.
@main struct StabiliseSmoke {
    static func main() async throws {
        let ffmpeg = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let shaky = directory.appendingPathComponent("shaky.mov")
        let make = Process(); make.executableURL = ffmpeg
        make.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc2=s=400x240:r=25:d=6",
                          "-vf", "crop=320:180:x='40+30*sin(n*1.3)':y='30+20*cos(n*1.7)'", "-c:v", "prores_ks", shaky.path]
        try make.run(); make.waitUntilExit()
        let steady = try await StabilisationService.stabilise(source: shaky, start: 1, duration: 4, ffmpeg: ffmpeg, into: directory)
        func motion(_ url: URL, from start: Double) throws -> (Double, Int) {
            let decode = Process(); decode.executableURL = ffmpeg
            decode.arguments = ["-v", "error", "-ss", String(start), "-i", url.path, "-t", "4", "-vf", "scale=160:90,format=gray", "-f", "rawvideo", "-"]
            let pipe = Pipe(); decode.standardOutput = pipe
            try decode.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); decode.waitUntilExit()
            let size = 160 * 90, frames = data.count / size
            var total = 0.0
            for f in 1..<frames {
                // Compare the centre, away from the edges deshake fills.
                for y in 20..<70 { for x in 30..<130 { total += abs(Double(data[f * size + y * 160 + x]) - Double(data[(f - 1) * size + y * 160 + x])) } }
            }
            return (total / Double((frames - 1) * 50 * 100), frames)
        }
        let before = try motion(shaky, from: 1), after = try motion(steady, from: 0)
        print(String(format: "mean frame difference: shaky %.2f (%d frames), stabilised %.2f (%d frames)", before.0, before.1, after.0, after.1))
        guard after.1 == before.1, after.0 < before.0 * 0.6 else { throw NSError(domain: "StabiliseSmoke", code: 1) }
        print("PASS stabilised copy covers the range and moves less")
    }
}
