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

        // Noise reduction on 30 s (beyond the runner's 2 MB output cap): hiss alone, a tone over
        // the hiss, then hiss alone again.
        let noisy = directory.appendingPathComponent("noisy.mov")
        let mix = Process(); mix.executableURL = ffmpeg
        mix.arguments = ["-v", "error", "-f", "lavfi", "-i", "anoisesrc=color=white:amplitude=0.02:sample_rate=48000:duration=30",
                         "-f", "lavfi", "-i", "aevalsrc='if(between(t,1,3),0.3*sin(2*PI*440*t),0)':s=48000:d=30",
                         "-filter_complex", "[0][1]amix=inputs=2:normalize=0", "-c:a", "pcm_s24le", noisy.path]
        try mix.run(); mix.waitUntilExit()
        let clean = try await NoiseReductionService.reduce(source: noisy, channels: [(0, 0)], amount: 12, start: 0, duration: 30, ffmpeg: ffmpeg, into: directory)
        func level(_ url: URL, from start: Double, length: Double) throws -> Double {
            let decode = Process(); decode.executableURL = ffmpeg
            decode.arguments = ["-v", "error", "-i", url.path, "-ss", String(start), "-t", String(length), "-f", "f32le", "-ac", "1", "-"]
            let pipe = Pipe(); decode.standardOutput = pipe
            try decode.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); decode.waitUntilExit()
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return 10 * log10(samples.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, samples.count)))
        }
        let hissBefore = try level(noisy, from: 3.2, length: 0.6), hissAfter = try level(clean, from: 3.2, length: 0.6)
        let toneBefore = try level(noisy, from: 1.5, length: 1), toneAfter = try level(clean, from: 1.5, length: 1)
        print(String(format: "hiss %.1f → %.1f dB, tone section %.1f → %.1f dB", hissBefore, hissAfter, toneBefore, toneAfter))
        guard hissAfter < hissBefore - 6, abs(toneAfter - toneBefore) < 1.5 else { throw NSError(domain: "NoiseSmoke", code: 1) }
        print("PASS noise-reduced copy lowers hiss and keeps the tone")
    }
}
