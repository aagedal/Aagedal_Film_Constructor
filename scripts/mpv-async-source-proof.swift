import Foundation

struct ProofFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Mirrors the serial ownership needed by a future source backend. The proof
/// deliberately installs no foreign callback and passes no MPV pointer to Swift.
@MainActor
final class Client {
    private var handle: OpaquePointer?
    private(set) var events: [afc_mpv_event] = []
    private var nextID: UInt64 = 1

    // Also release workers when a throwing operation or cancellation bypasses
    // explicit close. The bridge has no callbacks and destroy joins its workers.
    isolated deinit { afc_mpv_bridge_destroy(&handle) }

    init() throws {
        var error = [CChar](repeating: 0, count: 256)
        let rc = afc_mpv_bridge_create(&handle, &error, error.count)
        let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard rc == 0, handle != nil else { throw ProofFailure("create: \(rc) \(message)") }
    }

    func id() -> UInt64 { defer { nextID += 1 }; return nextID }
    func check(_ rc: Int32, _ label: String) throws {
        guard rc >= 0 else { throw ProofFailure("\(label): \(rc)") }
    }
    func pump() throws {
        var buffer = [afc_mpv_event](repeating: afc_mpv_event(), count: 16)
        let count = afc_mpv_bridge_poll(handle, &buffer, buffer.count, 64)
        try check(count, "poll")
        events.append(contentsOf: buffer.prefix(Int(count)))
        guard events.count < 10000 else { throw ProofFailure("unbounded event history") }
    }
    func wait(from start: Int, allowError: Bool = false,
              until predicate: (ArraySlice<afc_mpv_event>) -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        repeat {
            try Task.checkCancellation()
            try pump()
            let recent = events[start...]
            if !allowError, let error = recent.first(where: { $0.type == AFC_MPV_ERROR || $0.type == AFC_MPV_SHUTDOWN }) {
                throw ProofFailure("terminal event: \(error.status)")
            }
            if predicate(recent) { return }
            try await Task.sleep(for: .milliseconds(2))
        } while ContinuousClock.now < end
        throw ProofFailure("event deadline; events=\(events[start...].map { ($0.type.rawValue, $0.request_id, $0.status) })")
    }
    func open(_ path: String, video: Int32, audio: Int32) async throws -> afc_mpv_event {
        let request = id(), start = events.count
        try check(afc_mpv_bridge_open(handle, path, video, audio, request), "open")
        try await wait(from: start) { $0.contains { $0.type == AFC_MPV_OPENED && $0.request_id == request } }
        return events[start...].first { $0.type == AFC_MPV_OPENED && $0.request_id == request }!
    }
    func position() -> Double? {
        var value = 0.0
        return afc_mpv_bridge_position(handle, &value) == 0 ? value : nil
    }
    func commandReplies(_ ids: [UInt64], from start: Int) async throws {
        try await wait(from: start) { recent in
            ids.allSatisfy { id in recent.contains { $0.type == AFC_MPV_COMMAND_REPLY && $0.request_id == id } }
        }
        for id in ids {
            let replies = events[start...].filter { $0.type == AFC_MPV_COMMAND_REPLY && $0.request_id == id }
            guard replies.count == 1, replies[0].status >= 0 else { throw ProofFailure("wrong/duplicate reply \(id)") }
        }
    }
    func seek(_ target: Double) async throws {
        let request = id(), start = events.count
        try check(afc_mpv_bridge_seek(handle, target, request), "seek")
        try await commandReplies([request], from: start)
        try await wait(from: start) { recent in
            recent.contains { $0.type == AFC_MPV_PLAYBACK_RESTART } &&
                self.position().map { abs($0 - target) <= 1 / 24.0 } == true
        }
    }
    func paused(_ paused: Bool) async throws {
        let request = id(), start = events.count
        try check(afc_mpv_bridge_set_paused(handle, paused ? 1 : 0, request), "pause")
        try await commandReplies([request], from: start)
    }
    func rapid() async throws {
        let start = events.count
        let requests = (0..<3).map { _ in id() }
        try check(afc_mpv_bridge_seek(handle, 1.5, requests[0]), "rapid seek")
        try check(afc_mpv_bridge_set_paused(handle, 1, requests[1]), "rapid pause")
        try check(afc_mpv_bridge_seek(handle, 0.5, requests[2]), "rapid final seek")
        // A duplicate ID must be rejected without changing the pending request.
        guard afc_mpv_bridge_seek(handle, 2, requests[2]) == AFC_MPV_BUSY else {
            throw ProofFailure("duplicate pending ID accepted")
        }
        try await commandReplies(requests, from: start)
        try await wait(from: start) { recent in
            recent.contains { $0.type == AFC_MPV_PLAYBACK_RESTART } &&
                self.position().map { abs($0 - 0.5) <= 1 / 24.0 } == true
        }
    }
    func boundedAdmission() async throws {
        let start = events.count
        var ids: [UInt64] = []
        for _ in 0..<64 {
            let request = id()
            try check(afc_mpv_bridge_set_paused(handle, 1, request), "bounded pause")
            ids.append(request)
        }
        guard afc_mpv_bridge_set_paused(handle, 1, id()) == AFC_MPV_BUSY else {
            throw ProofFailure("pending admission exceeded 64")
        }
        try await commandReplies(ids, from: start)
        try await paused(true) // Released slots can admit new work.
    }
    func eofRecovery() async throws {
        try await seek(2.75)
        let start = events.count
        try await paused(false)
        try await wait(from: start) { $0.contains { $0.type == AFC_MPV_END_FILE && $0.end_reason == 0 } }
        for _ in 0..<20 {
            try pump()
            guard position() == nil else { throw ProofFailure("EOF restored stale position") }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await paused(true)
        try await seek(0.5)
        guard position().map({ abs($0 - 0.5) <= 1 / 24.0 }) == true else { throw ProofFailure("EOF seek recovery failed") }
    }
    func capture(_ url: URL) throws -> (Int, Int) {
        var width: Int32 = 0, height: Int32 = 0, bytes = 0
        let initial = afc_mpv_bridge_screenshot_rgb(handle, nil, 0, &width, &height, &bytes)
        guard initial == AFC_MPV_BUFFER, bytes == 320 * 180 * 3 else {
            throw ProofFailure("capture sizing: \(initial) \(bytes)")
        }
        var pixels = [UInt8](repeating: 0, count: bytes)
        try check(afc_mpv_bridge_screenshot_rgb(handle, &pixels, pixels.count, &width, &height, &bytes), "capture")
        try Data(pixels).write(to: url)
        return (Int(width), Int(height))
    }
    func close() throws {
        afc_mpv_bridge_close(handle)
        afc_mpv_bridge_close(handle)
        guard afc_mpv_bridge_seek(handle, 0, id()) == AFC_MPV_STATE else {
            throw ProofFailure("closed player accepted seek")
        }
        afc_mpv_bridge_destroy(&handle)
        afc_mpv_bridge_destroy(&handle)
        guard handle == nil else { throw ProofFailure("destroy retained pointer") }
    }
    func closePending(_ path: String, loaded: Bool) async throws {
        if loaded {
            _ = try await open(path, video: 0, audio: 2)
            try check(afc_mpv_bridge_seek(handle, 2, id()), "pending seek")
        } else {
            try check(afc_mpv_bridge_open(handle, path, 0, 2, id()), "pending load")
        }
        try close()
        try await Task.sleep(for: .milliseconds(5))
    }
    func reject(_ path: String, video: Int32, audio: Int32) async throws {
        let request = id(), start = events.count
        try check(afc_mpv_bridge_open(handle, path, video, audio, request), "negative open")
        try await wait(from: start, allowError: true) { $0.contains { $0.type == AFC_MPV_ERROR && $0.request_id == request } }
        guard events[start...].allSatisfy({ $0.type != AFC_MPV_OPENED }) else {
            throw ProofFailure("rejected selection emitted OPENED")
        }
        guard afc_mpv_bridge_seek(handle, 0, id()) == AFC_MPV_STATE else {
            throw ProofFailure("failed player accepted seek")
        }
        try close()
    }
    func disabled(_ path: String, video: Int32, audio: Int32) async throws {
        let opened = try await open(path, video: video, audio: audio)
        guard opened.video_track_id == (video < 0 ? -1 : 1),
              opened.audio_track_id == (audio < 0 ? -1 : 2) else {
            throw ProofFailure("disabled type selected a track")
        }
        try await seek(0.5)
        if video < 0 {
            var width: Int32 = 0, height: Int32 = 0, bytes = 0
            guard afc_mpv_bridge_screenshot_rgb(handle, nil, 0, &width, &height, &bytes) == AFC_MPV_STATE else {
                throw ProofFailure("disabled picture produced screenshot")
            }
        }
        try close()
    }
}

#if !AFC_NATIVE_COEXISTENCE
@main
struct Proof {
    @MainActor static func main() async {
        var report: [String: Any] = ["passed": false]
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("expected source, reordered source, output directory") }
        let output = URL(fileURLWithPath: args[3], isDirectory: true)
        var captures: [[String: Any]] = []
        do {
            for cycle in 0..<12 {
                let client = try Client()
                let reordered = cycle % 2 == 1
                let opened = try await client.open(args[reordered ? 2 : 1], video: reordered ? 1 : 0, audio: 2)
                guard opened.video_track_id == 1, opened.audio_track_id == 2 else { throw ProofFailure("wrong loaded track IDs") }
                try await client.paused(false)
                let start = client.events.count
                try await client.wait(from: start) { _ in client.position().map { $0 > 0.05 } == true }
                try await client.paused(true)
                if cycle == 0 {
                    try await client.boundedAdmission()
                    try await client.eofRecovery()
                }
                try await client.rapid()
                for target in [0.0, 1.5, 0.25, 2.0, 0.5] {
                    try await client.seek(target)
                    let file = "cycle-\(cycle)-frame-\(Int(target * 24)).rgb"
                    let (width, height) = try client.capture(output.appendingPathComponent(file))
                    captures.append(["file": file, "target": target, "position": client.position()!, "width": width, "height": height])
                }
                try client.close()
            }
            for index in 0..<12 {
                let client = try Client()
                try await client.closePending(args[1], loaded: index % 2 == 1)
            }
            for index in 0..<6 {
                let client = try Client()
                try await client.reject(args[1], video: index % 2 == 0 ? 99 : 2, audio: 2)
            }
            let corrupt = output.appendingPathComponent("corrupt.mov")
            try Data("invalid movie".utf8).write(to: corrupt)
            try await Client().reject(corrupt.path, video: 0, audio: 2)
            try await Client().disabled(args[1], video: -1, audio: 2)
            try await Client().disabled(args[1], video: 0, audio: -1)
            report = ["passed": true, "cycles": 12, "seeks": captures.count, "rapidCommands": 36,
                      "rejections": 7, "pendingCloses": 12, "captures": captures,
                      "boundedReplies": 64, "eofRecoveries": 1, "disabledTypes": 2]
        } catch {
            report["error"] = String(describing: error)
            report["captures"] = captures
        }
        do {
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: output.appendingPathComponent("swift-report.json"))
        } catch { fatalError("report write: \(error)") }
        if report["passed"] as? Bool != true { print(report["error"] ?? "failed"); exit(1) }
    }
}
#endif
