//
//  QueueLibraryView.swift
//  WellRead
//
//  **Up next** (explicit moves only) and **Backlog** (default). Drag covers to reorder, move sections, or drop on Read/Queue in the segment control.
//

import SwiftUI

// MARK: - Drop slots & book cell (reuse TierDragItem payload)

/// Wider than the old 8pt slots so drops register reliably between covers (especially backlog → Up next).
private let queueDropSlotWidth: CGFloat = 16

private struct QueueShelfDropSlot: View {
    let shelf: QueueShelf
    let insertionIndex: Int
    let onUpdate: (UUID, QueueShelf, Int?) -> Void
    var fillsRow: Bool = false
    var minHeight: CGFloat = 80
    var readOnly: Bool = false

    var body: some View {
        Group {
            if readOnly {
                Color.clear
                    .frame(minWidth: 6, maxWidth: fillsRow ? .infinity : 6)
                    .frame(minHeight: minHeight)
            } else {
                Color.clear
                    .frame(minWidth: queueDropSlotWidth, maxWidth: fillsRow ? .infinity : queueDropSlotWidth)
                    .frame(minHeight: minHeight)
                    .contentShape(Rectangle())
                    .dropDestination(for: TierDragItem.self) { items, _ in
                        guard let payload = items.first else { return false }
                        onUpdate(payload.userBookId, shelf, insertionIndex)
                        return true
                    } isTargeted: { targeted in
                        if targeted { LibraryDragHaptics.dropTargetHoverEntered() }
                    }
            }
        }
    }
}

private struct QueueBookCell: View {
    @EnvironmentObject private var queueDragCoordinator: QueueBookDragCoordinator

    let userBook: UserBook
    let shelf: QueueShelf
    let insertionIndex: Int
    var bookSize: CGFloat = 100
    let onUpdate: (UUID, QueueShelf, Int?) -> Void
    var onBookTap: ((Book) -> Void)?
    var readOnly: Bool = false

    var body: some View {
        Group {
            if let book = userBook.book {
                if readOnly {
                    BookCoverView(book: book, size: bookSize, onTap: onBookTap != nil ? { onBookTap?(book) } : nil)
                        .frame(width: bookSize, height: bookSize * 1.5)
                } else {
                    // Drops on the cover are handled by a UIKit `UIDropInteraction`
                    // inside `QueueBookDragCover` (left half = before, right half =
                    // after), so the whole cover stays tappable and drag-liftable —
                    // SwiftUI drop overlays would swallow those touches.
                    QueueBookDragCover(
                        book: book,
                        userBookId: userBook.id,
                        bookSize: bookSize,
                        onTap: onBookTap != nil ? { onBookTap?(book) } : nil,
                        onDropItem: { droppedId, insertBefore in
                            onUpdate(droppedId, shelf, insertBefore ? insertionIndex : insertionIndex + 1)
                        },
                        dragCoordinator: queueDragCoordinator
                    )
                    .frame(width: bookSize, height: bookSize * 1.5)
                }
            }
        }
        // Fixed width prevents HStack flex from shrinking covers (often visible on the 2nd item).
        .frame(width: bookSize, alignment: .topLeading)
        .layoutPriority(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Add tiles

/// Cover-sized dashed "Add" tile appended after the last book in a shelf. Tapping opens
/// search scoped to that shelf.
private struct QueueAddBookTile: View {
    let bookSize: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: max(16, bookSize * 0.22), weight: .semibold))
                Text("Add")
                    .font(.system(size: max(10, bookSize * 0.12), weight: .semibold))
                    .tracking(0.5)
            }
            .foregroundStyle(Theme.textTertiary)
            .frame(width: bookSize, height: bookSize * 1.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(Theme.textTertiary.opacity(0.6))
            )
            .opacity(0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Full-width empty state for a shelf with zero books: one big dashed tile with a
/// centered plus. Tap opens search for that shelf; drags still drop onto it.
private struct QueueEmptyShelfAddTile: View {
    let shelf: QueueShelf
    let onUpdate: (UUID, QueueShelf, Int?) -> Void
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 30, weight: .semibold))
                Text("Add a book")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.5)
            }
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 140)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(Theme.textTertiary.opacity(0.5))
            )
            .opacity(0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: TierDragItem.self) { items, _ in
            guard let payload = items.first else { return false }
            onUpdate(payload.userBookId, shelf, 0)
            return true
        } isTargeted: { targeted in
            if targeted { LibraryDragHaptics.dropTargetHoverEntered() }
        }
    }
}

// MARK: - Section grid (tier-list style rows of 4)

private let queueBooksPerRow = 4
private let queueRowPadding: CGFloat = 1

private enum QueueSectionEmptyKind {
    case none
    /// Dashed drop zone + “Drag the book(s) you’re currently reading here.”
    case readingNow
    /// Dashed drop zone + “Drag your next reads here!”
    case upNext
    /// Dashed area + backlog explainer (drops still accepted on overlay slot).
    case backlog

    var emptyPlaceholderMessage: String? {
        switch self {
        case .none: return nil
        case .readingNow: return "Drag the books you're currently reading here."
        case .upNext: return "Drag your next reads here!"
        case .backlog: return "When you add a book to your queue, it'll land here."
        }
    }
}

private struct QueueSectionGrid: View {
    let title: String
    let shelf: QueueShelf
    let books: [UserBook]
    var emptyKind: QueueSectionEmptyKind = .none
    let contentWidth: CGFloat
    let onUpdateShelfAndOrder: (UUID, QueueShelf, Int?) -> Void
    var onBookTap: ((Book) -> Void)?
    /// When set (own library), shows an "Add" tile after the last book (or filling the
    /// empty shelf) that opens search scoped to this shelf.
    var onAddTap: (() -> Void)? = nil
    var readOnly: Bool = false

    var body: some View {
        let w = contentWidth > 0 ? contentWidth : 280
        let available = w - queueRowPadding * 2
        // Slots: one before each book + one after the last book (narrow min width). Trailing slot can flex; reserve all narrow mins so book width math matches layout.
        let narrowSlotCount = queueBooksPerRow + 1
        let slotSpace = CGFloat(narrowSlotCount) * queueDropSlotWidth
        let bookSize = min(CGFloat(100), max(CGFloat(56), (available - slotSpace) / CGFloat(queueBooksPerRow)))
        // Full cover height so between-cover slots have no dead band under the covers.
        let slotHeight = max(64, bookSize * 1.5)

        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.headline())
                .foregroundStyle(Theme.textSecondary)

            if books.isEmpty, let message = emptyKind.emptyPlaceholderMessage {
                if readOnly {
                    Text("No books here yet.")
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                        .multilineTextAlignment(.center)
                } else if let onAddTap = onAddTap {
                    QueueEmptyShelfAddTile(shelf: shelf, onUpdate: onUpdateShelfAndOrder, onTap: onAddTap)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                            .foregroundStyle(Theme.textTertiary.opacity(0.5))
                            .background(
                                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                                    .fill(Color.white.opacity(0.08))
                            )
                        Text(message)
                            .font(Theme.callout())
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(20)
                            .allowsHitTesting(false)
                        QueueShelfDropSlot(shelf: shelf, insertionIndex: 0, onUpdate: onUpdateShelfAndOrder, fillsRow: true, minHeight: 140, readOnly: false)
                    }
                    .frame(minHeight: 140)
                }
            } else {
                queueRows(bookSize: bookSize, slotHeight: slotHeight)
            }
        }
        // Catch-all drop region behind the whole section (title, covers, gaps, and a
        // 12pt bleed past the edges): a drop that misses a precise slot still lands
        // on this shelf, at the end. Precise slots sit on top and keep priority.
        .background {
            if !readOnly {
                Color.clear
                    .padding(-12)
                    .contentShape(Rectangle())
                    .dropDestination(for: TierDragItem.self) { items, _ in
                        guard let payload = items.first else { return false }
                        onUpdateShelfAndOrder(payload.userBookId, shelf, nil)
                        return true
                    } isTargeted: { targeted in
                        if targeted { LibraryDragHaptics.dropTargetHoverEntered() }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: books.map(\.id))
    }

    /// Grid cell: a book, or (own library) the trailing "Add" tile that wraps like another cover.
    private enum QueueCell: Identifiable {
        case book(UserBook, index: Int)
        case addTile

        var id: String {
            switch self {
            case .book(let ub, _): return ub.id.uuidString
            case .addTile: return "add-tile"
            }
        }
    }

    @ViewBuilder
    private func queueRows(bookSize: CGFloat, slotHeight: CGFloat) -> some View {
        let showAddTile = onAddTap != nil && !readOnly
        let cells: [QueueCell] = books.enumerated().map { .book($1, index: $0) } + (showAddTile ? [.addTile] : [])
        let rows: [[QueueCell]] = cells.isEmpty
            ? []
            : stride(from: 0, to: cells.count, by: queueBooksPerRow).map { start in
                Array(cells[start..<min(start + queueBooksPerRow, cells.count)])
            }

        LazyVStack(alignment: .leading, spacing: 14) {
            if rows.isEmpty {
                HStack(spacing: 0) {
                    QueueShelfDropSlot(shelf: shelf, insertionIndex: 0, onUpdate: onUpdateShelfAndOrder, fillsRow: true, minHeight: slotHeight, readOnly: readOnly)
                }
                .padding(.horizontal, 1)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, rowCells in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(rowCells) { cell in
                            switch cell {
                            case .book(let ub, let index):
                                QueueShelfDropSlot(shelf: shelf, insertionIndex: index, onUpdate: onUpdateShelfAndOrder, minHeight: slotHeight, readOnly: readOnly)
                                if ub.book != nil {
                                    QueueBookCell(
                                        userBook: ub,
                                        shelf: shelf,
                                        insertionIndex: index,
                                        bookSize: bookSize,
                                        onUpdate: onUpdateShelfAndOrder,
                                        onBookTap: onBookTap,
                                        readOnly: readOnly
                                    )
                                    .frame(width: bookSize, alignment: .leading)
                                }
                            case .addTile:
                                QueueShelfDropSlot(shelf: shelf, insertionIndex: books.count, onUpdate: onUpdateShelfAndOrder, minHeight: slotHeight, readOnly: readOnly)
                                if let onAddTap = onAddTap {
                                    QueueAddBookTile(bookSize: bookSize, onTap: onAddTap)
                                        .frame(width: bookSize, alignment: .leading)
                                        .dropDestination(for: TierDragItem.self) { items, _ in
                                            guard let payload = items.first else { return false }
                                            onUpdateShelfAndOrder(payload.userBookId, shelf, books.count)
                                            return true
                                        } isTargeted: { targeted in
                                            if targeted { LibraryDragHaptics.dropTargetHoverEntered() }
                                        }
                                }
                            }
                        }
                        // Trailing flexible slot drops at the end of the row's books.
                        QueueShelfDropSlot(shelf: shelf, insertionIndex: rowEndInsertionIndex(rowCells), onUpdate: onUpdateShelfAndOrder, fillsRow: true, minHeight: slotHeight, readOnly: readOnly)
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func rowEndInsertionIndex(_ rowCells: [QueueCell]) -> Int {
        for cell in rowCells.reversed() {
            if case .book(_, let index) = cell { return index + 1 }
        }
        return 0
    }
}

// MARK: - Reading now (progress cards)

/// Thin full-width band between Reading now cards: drops insert at `insertionIndex`.
private struct QueueReadingNowRowDropSlot: View {
    let insertionIndex: Int
    let onUpdate: (UUID, QueueShelf, Int?) -> Void
    var readOnly: Bool = false

    var body: some View {
        if readOnly {
            Color.clear.frame(height: 4)
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 14)
                .contentShape(Rectangle())
                .dropDestination(for: TierDragItem.self) { items, _ in
                    guard let payload = items.first else { return false }
                    onUpdate(payload.userBookId, .readingNow, insertionIndex)
                    return true
                } isTargeted: { targeted in
                    if targeted { LibraryDragHaptics.dropTargetHoverEntered() }
                }
        }
    }
}

/// Compact full-width dashed "Add" row under the Reading now cards.
private struct QueueReadingNowAddRow: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                Text("Add a book you're reading")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.5)
            }
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(Theme.textTertiary.opacity(0.6))
            )
            .opacity(0.6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Reading now shelf: one `ReadingNowProgressCard` per book (bigger cover, live
/// percent + page readout, bookmark scrubber). Each card is wrapped in
/// `QueueReadingNowDragCard` so a long press lifts the whole card for reordering
/// or moving to another shelf; bands between cards and a catch-all background
/// take drops too. Falls back to `QueueSectionGrid` when empty so the
/// dashed empty state stays identical.
private struct QueueReadingNowSection: View {
    @EnvironmentObject private var queueDragCoordinator: QueueBookDragCoordinator

    let books: [UserBook]
    let contentWidth: CGFloat
    let onUpdateShelfAndOrder: (UUID, QueueShelf, Int?) -> Void
    var onBookTap: ((Book) -> Void)?
    var onAddTap: (() -> Void)? = nil
    var readOnly: Bool = false
    var onCommitProgress: ((UUID, Double) -> Void)? = nil
    var onMarkFinished: ((UserBook) -> Void)? = nil

    var body: some View {
        if books.isEmpty {
            QueueSectionGrid(
                title: "Reading now",
                shelf: .readingNow,
                books: [],
                emptyKind: .readingNow,
                contentWidth: contentWidth,
                onUpdateShelfAndOrder: onUpdateShelfAndOrder,
                onBookTap: onBookTap,
                onAddTap: onAddTap,
                readOnly: readOnly
            )
        } else {
            let w = contentWidth > 0 ? contentWidth : 280
            let coverWidth = min(CGFloat(70), max(CGFloat(60), w * 0.18))

            VStack(alignment: .leading, spacing: 8) {
                Text("Reading now")
                    .font(Theme.headline())
                    .foregroundStyle(Theme.textSecondary)

                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(books.enumerated()), id: \.element.id) { index, ub in
                        QueueReadingNowRowDropSlot(insertionIndex: index, onUpdate: onUpdateShelfAndOrder, readOnly: readOnly)
                        if let book = ub.book {
                            let card = ReadingNowProgressCard(
                                userBook: ub,
                                book: book,
                                coverWidth: coverWidth,
                                readOnly: readOnly,
                                onBookTap: onBookTap,
                                onCommitProgress: onCommitProgress.map { cb in { cb(ub.id, $0) } },
                                onMarkFinished: onMarkFinished.map { cb in { cb(ub) } },
                                cover: {
                                    AnyView(BookCoverView(book: book, size: coverWidth, onTap: onBookTap != nil ? { onBookTap?(book) } : nil))
                                }
                            )
                            if readOnly {
                                card
                            } else {
                                // Long press anywhere above the scrubber lifts the whole
                                // card; the card is also a drop target (top half = before).
                                QueueReadingNowDragCard(
                                    userBookId: ub.id,
                                    liftableHeight: 10 + coverWidth * 1.5 + 4,
                                    onDropItem: { droppedId, insertBefore in
                                        onUpdateShelfAndOrder(droppedId, .readingNow, insertBefore ? index : index + 1)
                                    },
                                    dragCoordinator: queueDragCoordinator
                                ) {
                                    card
                                }
                            }
                        }
                    }
                    QueueReadingNowRowDropSlot(insertionIndex: books.count, onUpdate: onUpdateShelfAndOrder, readOnly: readOnly)
                    if let onAddTap, !readOnly {
                        QueueReadingNowAddRow(onTap: onAddTap)
                            .dropDestination(for: TierDragItem.self) { items, _ in
                                guard let payload = items.first else { return false }
                                onUpdateShelfAndOrder(payload.userBookId, .readingNow, books.count)
                                return true
                            } isTargeted: { targeted in
                                if targeted { LibraryDragHaptics.dropTargetHoverEntered() }
                            }
                    }
                }
                .padding(.horizontal, 1)
            }
            .background {
                if !readOnly {
                    Color.clear
                        .padding(-12)
                        .contentShape(Rectangle())
                        .dropDestination(for: TierDragItem.self) { items, _ in
                            guard let payload = items.first else { return false }
                            onUpdateShelfAndOrder(payload.userBookId, .readingNow, nil)
                            return true
                        } isTargeted: { targeted in
                            if targeted { LibraryDragHaptics.dropTargetHoverEntered() }
                        }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: books.map(\.id))
        }
    }
}

// MARK: - Public

struct QueueLibraryView: View {
    let readingNow: [UserBook]
    let upNext: [UserBook]
    let backlog: [UserBook]
    /// Books given up on partway through. Shown read-only below Backlog — no
    /// drag/reorder, no "Add" tile, since DNF isn't a drop target.
    var dnf: [UserBook] = []
    let onUpdateShelfAndOrder: (UUID, QueueShelf, Int?) -> Void
    var onBookTap: ((Book) -> Void)? = nil
    /// When set (own library), each shelf shows an "Add" tile that calls this with its shelf.
    var onAddToShelf: ((QueueShelf) -> Void)? = nil
    var readOnly: Bool = false
    /// Pending books friends sent (own library only) — shown as a Recommended
    /// shelf above the queue with add/dismiss actions.
    var recommendations: [BookRecommendation] = []
    /// Sender display names keyed by Firebase UID ("from {name}").
    var recommenderNames: [String: String] = [:]
    var onAcceptRecommendation: ((BookRecommendation) -> Void)? = nil
    var onDismissRecommendation: ((BookRecommendation) -> Void)? = nil
    /// Reading now scrubber released: (userBook id, 0...1). Own library only.
    var onCommitProgress: ((UUID, Double) -> Void)? = nil
    /// Reader slid a book to 100% and tapped "Mark as finished".
    var onMarkFinished: ((UserBook) -> Void)? = nil

    @EnvironmentObject private var queueDragCoordinator: QueueBookDragCoordinator

    private static let horizontalPadding: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let contentWidth = max(0, geo.size.width - Self.horizontalPadding)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if !readOnly && !recommendations.isEmpty {
                        recommendedShelf
                    }

                    QueueReadingNowSection(
                        books: readingNow,
                        contentWidth: contentWidth,
                        onUpdateShelfAndOrder: onUpdateShelfAndOrder,
                        onBookTap: onBookTap,
                        onAddTap: onAddToShelf.map { cb in { cb(.readingNow) } },
                        readOnly: readOnly,
                        onCommitProgress: onCommitProgress,
                        onMarkFinished: onMarkFinished
                    )

                    QueueSectionGrid(
                        title: "Up next",
                        shelf: .upNext,
                        books: upNext,
                        emptyKind: .upNext,
                        contentWidth: contentWidth,
                        onUpdateShelfAndOrder: onUpdateShelfAndOrder,
                        onBookTap: onBookTap,
                        onAddTap: onAddToShelf.map { cb in { cb(.upNext) } },
                        readOnly: readOnly
                    )

                    QueueSectionGrid(
                        title: "Backlog",
                        shelf: .backlog,
                        books: backlog,
                        emptyKind: .backlog,
                        contentWidth: contentWidth,
                        onUpdateShelfAndOrder: onUpdateShelfAndOrder,
                        onBookTap: onBookTap,
                        onAddTap: onAddToShelf.map { cb in { cb(.backlog) } },
                        readOnly: readOnly
                    )

                    if !dnf.isEmpty {
                        // Read-only regardless of `readOnly`: DNF isn't a drag/drop
                        // shelf, just a shelf-typed parameter this view happens to need.
                        QueueSectionGrid(
                            title: "Did not finish",
                            shelf: .backlog,
                            books: dnf,
                            contentWidth: contentWidth,
                            onUpdateShelfAndOrder: { _, _, _ in },
                            onBookTap: onBookTap,
                            readOnly: true
                        )
                    }
                }
                .background(alignment: .topLeading) {
                    LibraryScrollViewAnchor(dragCoordinator: queueDragCoordinator)
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 4)
                .padding(.top, 10)
                .padding(.bottom, 88)
            }
        }
    }

    // MARK: - Recommended shelf (books other readers sent; accept → queue, or dismiss)

    private var recommendedShelf: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recommended by other readers")
                .font(Theme.headline())
                .foregroundStyle(Theme.textSecondary)

            ForEach(recommendations) { rec in
                recommendationRow(rec)
            }
        }
    }

    @ViewBuilder
    private func recommendationRow(_ rec: BookRecommendation) -> some View {
        if let book = rec.book {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Button(action: { onBookTap?(book) }) {
                        BookCoverView(book: book, size: 56)
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.title)
                            .font(Theme.body())
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Text(book.author)
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Text("from \(recommenderNames[rec.fromUserId] ?? "another reader")")
                            .font(Theme.caption())
                            .foregroundStyle(Theme.accent)
                        if let note = rec.note, !note.isEmpty {
                            Text("\u{201C}\(note)\u{201D}")
                                .font(Theme.caption())
                                .foregroundStyle(Theme.textSecondary)
                                .italic()
                                .lineLimit(3)
                        }
                    }
                    Spacer()
                }
                HStack(spacing: 10) {
                    Button(action: { onAcceptRecommendation?(rec) }) {
                        Text("+ QUEUE")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(Theme.onChrome)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                                    .fill(Theme.accentGloss)
                            )
                    }
                    .buttonStyle(.plain)
                    Button(action: { onDismissRecommendation?(rec) }) {
                        Text("DISMISS")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                                    .fill(Theme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                                    .stroke(Theme.chrome.opacity(0.4), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .stroke(Theme.chrome.opacity(0.35), lineWidth: 1)
            )
        }
    }
}
