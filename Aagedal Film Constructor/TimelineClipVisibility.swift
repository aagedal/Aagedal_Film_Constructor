import CoreGraphics
import Foundation

/// Horizontal canvas pixels, independent of global window position. Keeping the
/// canvas's full width lets scrolling discover clips without mounting every clip.
enum TimelineClipVisibility {
    static func range(viewport: CGRect, canvas: CGRect, labelWidth: CGFloat,
                      overscan: CGFloat = 200, initialWidth: CGFloat = 1280) -> ClosedRange<CGFloat> {
        guard !viewport.isEmpty, !canvas.isEmpty else { return 0...(initialWidth + overscan) }
        let origin = canvas.minX + labelWidth
        return max(0, viewport.minX - origin - overscan)...max(0, viewport.maxX - origin + overscan)
    }

    static func includes(startSeconds: Double, durationSeconds: Double, pixelsPerSecond: Double,
                         range: ClosedRange<CGFloat>, pinned: Bool = false) -> Bool {
        if pinned { return true }
        let start = startSeconds * pixelsPerSecond
        let end = start + max(10, durationSeconds * pixelsPerSecond)
        // Include touching edges and the ten-pixel minimum clip hit area.
        return end >= range.lowerBound && start <= range.upperBound
    }
}
