import AppKit
import EditorCore

/// Opt-in editorial run in the real application (AFC_STORY=1 with AFC_ACCEPTANCE_DIR and
/// AFC_ACCEPTANCE_MEDIA): cuts a short film from real shots the way an editor would, using
/// the same store actions as the workspace controls, then plays, exports and saves it.
/// Each media entry is "path@in-out" in source seconds; the third shot plays at 50%.
@MainActor
enum StoryDriver {
    static func run(store: EditorStore, output: URL, media: [String]) {
        Task { @MainActor in
            var log: [String: Any] = [:]
            func record(_ key: String, _ value: Any) {
                log[key] = value
                if let line = try? JSONSerialization.data(withJSONObject: [key: value], options: [.sortedKeys]) {
                    FileHandle.standardError.write(Data("AFC_STORY ".utf8) + line + Data([10]))
                }
            }
            func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline { if condition() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
                return condition()
            }
            @MainActor func clips() -> [TimelineClip] { store.project.tracks.flatMap(\.clips) }
            @MainActor func window() -> NSWindow? { NSApp.windows.first { $0.isVisible && NSDocumentController.shared.document(for: $0) != nil } }
            @MainActor func snapshot(_ name: String) {
                guard let view = window()?.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
            }
            _ = await wait(15) { window() != nil }
            window()?.setContentSize(NSSize(width: 1600, height: 1000))

            // 1. Sequence: 1080p25 stereo.
            store.updateSequence(width: 1920, height: 1080, frameRateText: "25", audioSampleRate: 48000, audioLayout: .stereo,
                                 startTimecodeLabel: "01:00:00:00")
            // 2. Import the shots into the bin.
            let shots = media.map { entry -> (URL, Double, Double) in
                let parts = entry.split(separator: "@", maxSplits: 1)
                let range = parts.count > 1 ? parts[1].split(separator: "-").compactMap { Double($0) } : [0, 4]
                return (URL(fileURLWithPath: String(parts[0])), range[0], range.count > 1 ? range[1] : range[0] + 4)
            }
            store.importMedia(urls: shots.map(\.0))
            _ = await wait(600) { !store.isImporting }
            record("imported", store.project.assets.map(\.name))
            // 3. Mark each shot's range in the source and append it; slow the third to 50%.
            for (index, shot) in shots.enumerated() {
                guard let asset = store.project.assets.first(where: { $0.originalURL?.lastPathComponent == shot.0.lastPathComponent }) else { continue }
                store.selectAsset(asset.id)
                store.sourceRanges[asset.id] = try? TimeRange(start: RationalTime(Int64(shot.1 * 25), 25),
                                                              duration: RationalTime(Int64((shot.2 - shot.1) * 25), 25))
                store.appendSelectedAsset()
                if index == 2, let last = clips().filter({ $0.requiredTrackKind == .video }).max(by: { $0.timelineStart.seconds < $1.timelineStart.seconds }) {
                    store.selectTimelineClip(last.id)
                    store.setSelectedClipSpeed(percent: "50")
                }
            }
            let pictures = clips().filter { $0.requiredTrackKind == .video }.sorted { $0.timelineStart.seconds < $1.timelineStart.seconds }
            record("shots", pictures.map { String(format: "%.2f+%.2f@%g%%", $0.timelineStart.seconds, $0.sourceRange.duration.seconds, $0.speed.seconds * 100) })
            // 4. Transitions: fade up from black, dissolve between shots, fade out at the end.
            for (index, picture) in pictures.enumerated() {
                store.selectTimelineClip(picture.id)
                store.seek(to: picture.timelineStart.seconds + 0.1)
                store.addTransitionAtPlayhead(seconds: index == 0 ? 1.5 : 1)
                if index == pictures.count - 1 {
                    store.seek(to: picture.timelineStart.seconds + picture.sourceRange.duration.seconds - 0.1)
                    store.addTransitionAtPlayhead(seconds: 2)
                }
            }
            let dissolves = store.project.audioCrossfades.count
            record("transitions", ["dissolves": dissolves, "error": store.errorMessage ?? ""])
            // 4b. Stabilise the second shot: its picture moves to a stabilised copy.
            if pictures.count > 1 {
                store.selectTimelineClip(pictures[1].id)
                store.stabiliseSelectedClip()
                _ = await wait(1200) { !store.isStabilising }
                let stabilised = clips().first { $0.id == pictures[1].id }?.stabilization.map { "\($0.analysis.times.count) frames" } ?? ""
                record("stabilised", ["analysis": stabilised, "transitionsKept": store.project.audioCrossfades.count, "error": store.errorMessage ?? ""])
            }
            // 5. A light grade on every shot.
            for picture in pictures {
                store.selectTimelineClip(picture.id)
                store.setSelectedClipColor(ColorAdjustment(brightness: 0.02, contrast: 1.1, saturation: 1.15))
            }
            // 6. An opening title that rises in.
            store.seek(to: 0.5)
            store.addTitle()
            if let titleAsset = store.project.assets.last(where: { $0.title != nil }) {
                store.updateTitle(assetID: titleAsset.id, to: TitleDefinition(text: "Langøyene\nDrone, August 2026", fontSize: 0.07,
                                                                              position: .lowerThird, bold: true, background: false))
                if let titleClip = clips().first(where: { $0.assetID == titleAsset.id }) {
                    store.selectTimelineClip(titleClip.id)
                    store.applyMotionPreset(.riseFromBelow)
                    store.seek(to: titleClip.timelineStart.seconds + 0.1)
                    store.addTransitionAtPlayhead(seconds: 0.6)
                    store.seek(to: titleClip.timelineStart.seconds + titleClip.sourceRange.duration.seconds - 0.1)
                    store.addTransitionAtPlayhead(seconds: 0.6)
                }
            }
            // 7. A music bed under the picture: faded in and out, ducked once, trimmed to the end.
            let end = pictures.map { $0.timelineStart.seconds + $0.sourceRange.duration.seconds }.max() ?? 0
            let music = output.appendingPathComponent("music-bed.wav")
            if let ffmpeg = Bundle.main.resourceURL?.appendingPathComponent("Helpers/ffmpeg") {
                _ = try? await ExportProcess.run(executable: ffmpeg, arguments: ["-hide_banner", "-nostdin", "-y",
                    "-f", "lavfi", "-i", "sine=frequency=220:duration=60", "-f", "lavfi", "-i", "sine=frequency=277.2:duration=60",
                    "-f", "lavfi", "-i", "sine=frequency=329.6:duration=60", "-filter_complex", "amix=inputs=3,volume=0.5,aformat=channel_layouts=stereo",
                    "-ar", "48000", "-c:a", "pcm_s16le", music.path])
            }
            if store.importMediaToTimeline(urls: [music], at: 0) { _ = await wait(60) { !store.isImporting } }
            if let bed = clips().first(where: { store.asset(id: $0.assetID)?.originalURL?.lastPathComponent == "music-bed.wav" }) {
                store.selectTimelineClip(bed.id)
                store.trimSelectedClip(start: 0, duration: end)
                store.seek(to: 0.1); store.addTransitionAtPlayhead(seconds: 2)
                store.seek(to: end - 0.1); store.addTransitionAtPlayhead(seconds: 3)
                store.seek(to: 6); store.addVolumeKeyframeAtPlayhead(decibels: "0")
                store.seek(to: 7); store.addVolumeKeyframeAtPlayhead(decibels: "-10")
                // Compress and clean the bed as an editor would with a voice-over.
                store.selectTimelineClip(bed.id)
                store.setSelectedDynamics(AudioDynamics(threshold: -24, ratio: 3, makeup: 3, limiterCeiling: -1))
                store.reduceNoiseOnSelectedAudio()
                _ = await wait(300) { !store.isReducingNoise }
                let cleaned = clips().first { $0.id == bed.id }
                record("audioFinishing", ["compressed": cleaned?.dynamics != nil,
                                          "noiseReduced": cleaned.flatMap { store.asset(id: $0.assetID) }?.name ?? "", "error": store.errorMessage ?? ""])
                record("music", ["fadeIn": clips().first { $0.id == bed.id }?.fadeIn.duration.seconds ?? 0,
                                 "keyframes": clips().first { $0.id == bed.id }?.volumeKeyframes.count ?? 0])
            }
            record("timeline", ["duration": store.duration, "tracks": store.project.tracks.map { $0.displayName(in: store.project) },
                                "error": store.errorMessage ?? ""])
            // 8. Watch it: play three seconds in the sequence viewer.
            store.seek(to: 0)
            store.showSequenceMonitor = true
            _ = await wait(60) { store.sequencePlayback?.isPreparing == false }
            store.sequencePlayback?.play()
            try? await Task.sleep(for: .seconds(3))
            snapshot("story-playing")
            store.sequencePlayback?.pause()
            record("playback", ["playhead": store.playheadSeconds, "message": store.sequencePlayback?.message ?? ""])
            // 9. Export H.264 through the render sheet's plan, then save the project.
            store.beginRenderExport()
            if let draft = store.renderExportDraft {
                let movie = output.appendingPathComponent("Langoyene.mp4")
                do {
                    let result = try await SequenceExportService.shared.export(plan: draft.plan, to: movie, options: .init(format: .h264))
                    record("export", ["file": movie.lastPathComponent, "frames": result.videoFrames, "warnings": result.warnings])
                } catch { record("export", ["error": error.localizedDescription]) }
                store.renderExportDraft = nil
            }
            if let window = window(), let document = NSDocumentController.shared.document(for: window) {
                let project = output.appendingPathComponent("Langoyene.afcproject")
                try? await document.save(to: project, ofType: document.fileType ?? "", for: .saveAsOperation)
                record("saved", FileManager.default.fileExists(atPath: project.path))
            }
            if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("story.json"))
            }
            exit(0)
        }
    }
}
