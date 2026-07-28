import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(proposal: proposal, subviews: subviews)
        return rows.reduce(CGSize.zero) { size, row in
            CGSize(
                width: max(size.width, row.width),
                height: size.height + row.height + (size.height == 0 ? 0 : spacing)
            )
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(proposal: proposal, subviews: subviews)
        var origin = bounds.origin

        for row in rows {
            var xPosition = origin.x
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: xPosition, y: origin.y),
                    proposal: ProposedViewSize(item.size)
                )
                xPosition += item.size.width + spacing
            }
            origin.y += row.height + spacing
        }
    }

    private func rows(proposal: ProposedViewSize, subviews: Subviews) -> [FlowRow] {
        let maxWidth = proposal.width ?? 320
        var rows: [FlowRow] = []
        var currentRow = FlowRow()

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let proposedWidth = currentRow.width == 0 ? size.width : currentRow.width + spacing + size.width

            if proposedWidth > maxWidth, !currentRow.items.isEmpty {
                rows.append(currentRow)
                currentRow = FlowRow()
            }

            currentRow.items.append(FlowItem(subview: subview, size: size))
            currentRow.width = currentRow.width == 0 ? size.width : currentRow.width + spacing + size.width
            currentRow.height = max(currentRow.height, size.height)
        }

        if !currentRow.items.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }

    private struct FlowRow {
        var items: [FlowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private struct FlowItem {
        let subview: LayoutSubview
        let size: CGSize
    }
}