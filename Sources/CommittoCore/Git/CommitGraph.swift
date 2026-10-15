import Foundation

/// One rendered row of the commit graph. The renderer draws, per row:
///  - top half: for each non-nil `before[i]` a line from (i, top) to (target, mid)
///  - bottom half: for each non-nil `after[j]` a line from (source, mid) to (j, bottom)
public struct GraphRow: Identifiable, Sendable {
    public var id: String { commit.hash }
    public let commit: Commit
    public let nodeLane: Int
    public let before: [String?]
    public let after: [String?]
    /// Lanes (other than nodeLane) that already carried one of this commit's parents: draw an extra merge edge.
    public let mergeLanes: [Int]
    public var laneCount: Int { max(before.count, after.count, nodeLane + 1) }
}

public enum CommitGraph {
    /// Assigns commits (topologically ordered, newest first) to lanes.
    public static func layout(_ commits: [Commit]) -> [GraphRow] {
        var lanes: [String?] = []
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)
        for c in commits {
            let before = lanes
            var node = lanes.firstIndex(where: { $0 == c.hash })
            if node == nil {
                node = lanes.firstIndex(where: { $0 == nil }) ?? { lanes.append(nil); return lanes.count - 1 }()
            }
            let n = node!
            for i in lanes.indices where lanes[i] == c.hash { lanes[i] = nil }
            var merge: [Int] = []
            for (pi, p) in c.parents.enumerated() {
                if let existing = lanes.firstIndex(where: { $0 == p }) {
                    if existing != n { merge.append(existing) }
                    continue
                }
                if pi == 0 { lanes[n] = p }
                else {
                    let slot = lanes.firstIndex(where: { $0 == nil }) ?? { lanes.append(nil); return lanes.count - 1 }()
                    lanes[slot] = p
                }
            }
            while let last = lanes.last, last == nil { lanes.removeLast() }
            rows.append(GraphRow(commit: c, nodeLane: n, before: before, after: lanes, mergeLanes: merge))
        }
        return rows
    }

    /// Segments to draw for a row, in lane units (x) and half-row units (y: 0 top, 0.5 mid, 1 bottom).
    public struct Segment: Sendable { public let x0: Int; public let y0: Double; public let x1: Int; public let y1: Double; public let lane: Int }
    public static func segments(for row: GraphRow) -> [Segment] {
        var s: [Segment] = []
        let h = row.commit.hash
        for (i, v) in row.before.enumerated() {
            guard let v else { continue }
            s.append(.init(x0: i, y0: 0, x1: v == h ? row.nodeLane : i, y1: 0.5, lane: v == h ? row.nodeLane : i))
        }
        for (j, v) in row.after.enumerated() {
            guard let v else { continue }
            let continuing = j < row.before.count && row.before[j] == v && j != row.nodeLane
            s.append(.init(x0: continuing ? j : row.nodeLane, y0: 0.5, x1: j, y1: 1, lane: j))
        }
        for m in row.mergeLanes { s.append(.init(x0: row.nodeLane, y0: 0.5, x1: m, y1: 1, lane: m)) }
        return s
    }
}
