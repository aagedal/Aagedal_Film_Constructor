import Foundation

enum VisibilitySmokeError: Error { case failed(String) }
@main
struct TimelineVisibilitySmoke {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw VisibilitySmokeError.failed(message) }
        }
        let initial = TimelineClipVisibility.range(viewport: .zero, canvas: .zero, labelWidth: 145)
        try check(initial == 0...1480, "First layout uses a bounded range rather than the entire canvas")
        let visible = TimelineClipVisibility.range(viewport: CGRect(x: 100, y: 30, width: 800, height: 200),
            canvas: CGRect(x: -1045, y: -50, width: 100000, height: 600), labelWidth: 145, overscan: 0)
        try check(visible == 1000...1800, "Viewport conversion accounts for scrolling, labels and window position")
        func includes(_ start: Double, _ duration: Double, _ zoom: Double = 100, pinned: Bool = false) -> Bool {
            TimelineClipVisibility.includes(startSeconds: start, durationSeconds: duration,
                pixelsPerSecond: zoom, range: visible, pinned: pinned)
        }
        try check(includes(9, 1) && includes(18, 1), "Clips touching both viewport boundaries remain mounted")
        try check(!includes(8, 1) && !includes(19, 1), "Clips outside both boundaries are culled")
        try check(includes(0, 30), "A long clip spanning the viewport remains mounted")
        try check(includes(9.95, 0.001), "A tiny clip's minimum ten-pixel hit area intersects the viewport")
        try check(!includes(12, 1, 35) && includes(12, 1, 100), "Zoom changes which clips are visible")
        try check(includes(9000, 1, pinned: true) && !includes(9000, 1), "Selection/active gestures stay mounted outside viewport and unpin correctly")
        let overscan = TimelineClipVisibility.range(viewport: CGRect(x: 0, y: 0, width: 800, height: 200),
            canvas: CGRect(x: -1145, y: 0, width: 100000, height: 200), labelWidth: 145)
        try check(overscan == 800...2000, "Overscan retains near-edge clips")
        let count = (0..<1000).filter {
            TimelineClipVisibility.includes(startSeconds: Double($0 * 10), durationSeconds: 6,
                pixelsPerSecond: 35, range: initial)
        }.count
        try check(count == 5, "A thousand-clip track mounts only five clips before geometry is available")
        print("PASS: first layout, scroll coordinates, boundaries, long/tiny clips, zoom, overscan and active gesture pinning")
    }
}
