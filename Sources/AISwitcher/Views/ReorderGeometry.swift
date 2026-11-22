import SwiftUI

/// Pure geometry helpers for gesture-driven list and section reordering.
enum ReorderGeometry {
    /// Compute the target insertion gap (`0...orderedIDs.count`) for a pointer Y position.
    ///
    /// - Parameters:
    ///   - dragY: Pointer vertical position in the same coordinate space as `frames`.
    ///   - orderedIDs: Sibling identifiers in their current display order.
    ///   - frames: Snapshot of sibling bounding rects captured when dragging starts.
    /// - Returns: Insertion gap index where dropping moves the dragged item.
    static func targetIndex<ID: Hashable>(
        forDragY dragY: CGFloat,
        orderedIDs: [ID],
        frames: [ID: CGRect]
    ) -> Int {
        var insertionIndex = 0
        for id in orderedIDs {
            guard let frame = frames[id] else { continue }
            if dragY > frame.midY {
                insertionIndex += 1
            } else {
                break
            }
        }
        return insertionIndex
    }

    /// Whether moving the item at `sourceIndex` to insertion gap `targetIndex` changes order.
    static func movesItem(from sourceIndex: Int, to targetIndex: Int) -> Bool {
        targetIndex != sourceIndex && targetIndex != sourceIndex + 1
    }
}

/// High-contrast accent insertion bar displayed between cards or sections while dragging.
struct DropInsertionIndicator: View {
    let color: Color

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Rectangle()
                .fill(color)
                .frame(height: 2)
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
        }
        .shadow(color: color.opacity(0.65), radius: 3)
        .allowsHitTesting(false)
    }
}
