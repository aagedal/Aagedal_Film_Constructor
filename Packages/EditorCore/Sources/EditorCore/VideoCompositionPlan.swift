import Foundation

/// System-compositor scheduling derived from the canonical edit. Picture tracks
/// are reusable storage lanes, independent of editorial track identity. Only
/// overlapping pictures require separate composition tracks. Prepared stills and
/// motion video use separate pools to preserve system compositor color behavior.
public struct VideoCompositionPlan: Equatable, Sendable {
    public struct Placement: Equatable, Sendable {
        public let componentIndex: Int
        public let trackIndex: Int
    }
    public struct Instruction: Equatable, Sendable {
        public var timeRange: TimeRange
        /// Front to back; stills and fading pictures reveal lower layers, other motion video is opaque.
        public let componentIndices: [Int]
    }
    /// Ordered by timeline start, so scaling a still hold cannot shift later inserts.
    public let placements: [Placement]
    public let trackCount: Int
    public let instructions: [Instruction]

    public init(_ plan: TimelineRenderPlan) throws {
        let pictures = plan.components.indices.filter {
            switch plan.components[$0].selection {
            case .still, .video: true
            case .audio: false
            }
        }.sorted { TimelineRenderPlan.Component.isInFront(plan.components[$0], of: plan.components[$1]) }
        guard !pictures.isEmpty else {
            placements = []; trackCount = 0; instructions = []
            return
        }
        let ends = try pictures.map { try plan.components[$0].timelineRange.end() }
        // Opacity is full between the end of the fade in and the start of the fade out.
        let opaqueStarts = try pictures.map {
            try plan.components[$0].timelineRange.start.adding(plan.components[$0].fadeIn.duration)
        }
        let opaqueEnds = try pictures.indices.map { try ends[$0].subtracting(plan.components[pictures[$0]].fadeOut.duration) }
        let boundaries = try Set([.zero, plan.duration] + ends + opaqueStarts + opaqueEnds + pictures.map {
            plan.components[$0].timelineRange.start
        }).sorted { try $0.compared(to: $1) == .orderedAscending }
        let boundaryIndices = Dictionary(uniqueKeysWithValues: boundaries.enumerated().map { ($1, $0) })
        let starts = pictures.map { boundaryIndices[plan.components[$0].timelineRange.start]! }
        let finishes = ends.map { boundaryIndices[$0]! }
        let opaqueFrom = opaqueStarts.map { boundaryIndices[$0]! }
        let opaqueUntil = opaqueEnds.map { boundaryIndices[$0]! }
        let chronological = pictures.indices.sorted {
            starts[$0] == starts[$1] ? $0 < $1 : starts[$0] < starts[$1]
        }

        struct Lane {
            let end: Int
            let index: Int
        }
        let laneOrder: (Lane, Lane) -> Bool = {
            $0.end == $1.end ? $0.index < $1.index : $0.end < $1.end
        }
        var lanePools = [CompositionHeap<Lane>(precedes: laneOrder), CompositionHeap<Lane>(precedes: laneOrder)]
        var placementList: [Placement] = []
        placementList.reserveCapacity(pictures.count)
        var count = 0
        for rank in chronological {
            let pool: Int
            if case .still = plan.components[pictures[rank]].selection { pool = 1 } else { pool = 0 }
            let lane: Int
            if let first = lanePools[pool].first, first.end <= starts[rank] {
                lane = lanePools[pool].pop()!.index
            } else { lane = count; count += 1 }
            lanePools[pool].push(Lane(end: finishes[rank], index: lane))
            placementList.append(Placement(componentIndex: pictures[rank], trackIndex: lane))
        }

        // A priority heap with lazy expiry avoids scanning every clip at every
        // cut. Hidden motion-video layers need not be visited or sorted.
        var active = CompositionHeap<Int>(precedes: <)
        var cursor = 0
        var instructionList: [Instruction] = []
        for boundary in 0..<(boundaries.count - 1) {
            while cursor < chronological.count, starts[chronological[cursor]] == boundary {
                active.push(chronological[cursor]); cursor += 1
            }
            var visible: [Int] = []
            var transparent: [Int] = []
            while let rank = active.first {
                if finishes[rank] <= boundary { _ = active.pop(); continue }
                visible.append(pictures[rank])
                if case .video = plan.components[pictures[rank]].selection,
                   opaqueFrom[rank] <= boundary, boundary < opaqueUntil[rank] { break }
                transparent.append(active.pop()!)
            }
            for rank in transparent { active.push(rank) }
            let end = boundaries[boundary + 1]
            if let last = instructionList.last, last.componentIndices == visible {
                instructionList[instructionList.count - 1].timeRange.duration = try end.subtracting(last.timeRange.start)
            } else {
                instructionList.append(Instruction(timeRange: try TimeRange(start: boundaries[boundary],
                    duration: end.subtracting(boundaries[boundary])), componentIndices: visible))
            }
        }
        placements = placementList; trackCount = count; instructions = instructionList
    }
}

private struct CompositionHeap<Element> {
    private var values: [Element] = []
    let precedes: (Element, Element) -> Bool
    init(precedes: @escaping (Element, Element) -> Bool) { self.precedes = precedes }
    var first: Element? { values.first }
    mutating func push(_ value: Element) {
        values.append(value)
        var child = values.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard precedes(values[child], values[parent]) else { break }
            values.swapAt(child, parent); child = parent
        }
    }
    mutating func pop() -> Element? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values.removeLast() }
        let result = values[0]
        values[0] = values.removeLast()
        var parent = 0
        while parent * 2 + 1 < values.count {
            var child = parent * 2 + 1
            if child + 1 < values.count, precedes(values[child + 1], values[child]) { child += 1 }
            guard precedes(values[child], values[parent]) else { break }
            values.swapAt(child, parent); parent = child
        }
        return result
    }
}
