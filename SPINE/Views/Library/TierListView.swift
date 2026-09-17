//
//  TierListView.swift
//  SPINE
//
//  Drag-and-drop tiers: S, A, B, C, D, Unranked. Brief press and drag a book onto a tier row.
//

import SwiftUI
import UniformTypeIdentifiers

/// Narrower than the queue grid's 16pt: tier rows trade drop-target width for
/// bigger covers. Between-cover drops stay easy because each cover's own edge
/// zones (tierBookDropZoneFraction) also accept inserts.
private let tierDropSlotWidth: CGFloat = 10

/// Coordinate space of the tier-list ScrollView, used to pin each tier's letter
/// to the top of the viewport while its (possibly very tall) row scrolls by.
private let tierListScrollSpace = "tierListScroll"
/// Breathing room the pinned tier letter keeps below the viewport's top edge,
/// so it doesn't crowd the goal strip and the list/feed buttons sitting just
/// above the scroll view. The year tab deliberately does *not* use this: it's a
/// folder tab hinged to the top edge, and any gap there reads as detached.
private let tierStickyTopInset: CGFloat = 18

/// Tier rows rendered top-to-bottom, plus an Unranked row appended after.
private let tierLabels: [String] = spineTierLabels

private func tierColor(for tier: String?) -> Color {
    spineTierColor(for: tier)
}

/// Faint hint copy shown in an empty S/F tier row while the viewer hasn't ranked
/// anything yet, so the tier list doesn't read as just blank on first arrival.
private func tierEmptyHint(for tier: String) -> String? {
    switch tier {
    case "S": return "The best of the best"
    case "F": return "The worst of the worst"
    default: return nil
    }
}

// MARK: - Post-review tier prompt (scroll anchor + callout)

/// ScrollViewReader anchor attached to the just-reviewed book so we can bring it
/// fully into view (not just the tall Unranked row).
private let tierHighlightScrollID = "tier-highlight-book"

/// Publishes the highlighted book's on-screen bounds so the callout can point at
/// it from an overlay above the (clipped) tier rows.
private struct TierHighlightAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Measured height of the callout bubble, so we can seat its tail just above the book.
private struct TierCalloutHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 58
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Bottom edge of the in-flow year tab in the scroll coordinate space — once it
/// scrolls above the viewport, the pinned copy flips down from the top edge.
private struct TierYearTabMaxYKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// Hinge for the pinned year tab's transition: swings down from (and folds back
/// up into) the viewport's top edge like a folder tab flipping over it.
private struct TierYearTabHinge: ViewModifier {
    let angle: Double
    func body(content: Content) -> some View {
        content.rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.6)
    }
}

/// Downward-pointing tail for the callout bubble.
private struct CalloutTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// "Rank me!" bubble shown above a freshly-reviewed, still-unranked book.
/// `tailOffset` shifts the tail horizontally so it keeps pointing at the book
/// even when the bubble is nudged inward to stay on screen.
private struct TierHighlightCallout: View {
    var tailOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(SpinesGlyphs.caps("Rank me"))
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.5)
                Text("Drag me onto a tier")
                    .font(Theme.caption())
                    .opacity(0.9)
            }
            .foregroundStyle(Theme.onChrome)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.accent)
            )

            CalloutTail()
                .fill(Theme.accent)
                .frame(width: 18, height: 9)
                .offset(x: tailOffset)
        }
        .shadow(color: Theme.shadowInk.opacity(0.22), radius: 8, x: 0, y: 3)
        .allowsHitTesting(false)
    }
}

private extension View {
    /// Applies a ScrollViewReader `.id` only when `active`, so the anchor exists
    /// solely on the currently-highlighted book.
    @ViewBuilder
    func scrollAnchorID(_ id: String, active: Bool) -> some View {
        if active { self.id(id) } else { self }
    }
}

/// Invisible drop slot between or around books so the user can drop at a specific position (front, between, or back) in a tier. Fixed width so rows stay left-aligned; use fillsRow: true for empty tiers so the whole row accepts drops.
private struct TierRowDropSlot: View {
    let tier: String?
    let insertionIndex: Int
    let onUpdateTierAndOrder: (UUID, String?, Int?) -> Void
    /// When true (e.g. empty tier), slot expands to fill the row so drops are easy to register.
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
                    .frame(minWidth: tierDropSlotWidth, maxWidth: fillsRow ? .infinity : tierDropSlotWidth)
                    .frame(minHeight: minHeight)
                    .contentShape(Rectangle())
                    .dropDestination(for: TierDragItem.self) { items, _ in
                        guard let payload = items.first else { return false }
                        onUpdateTierAndOrder(payload.userBookId, tier, insertionIndex)
                        return true
                    } isTargeted: { targeted in
                        if targeted { LibraryDragHaptics.dropTargetHoverEntered() }
                    }
            }
        }
    }
}

/// Payload for tier-list drag-and-drop. Uses plain-text UUID for reliable in-app transfer.
struct TierDragItem: Transferable, Hashable {
    let userBookId: UUID

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { item in
            Data(item.userBookId.uuidString.utf8)
        }
        DataRepresentation(importedContentType: .plainText) { data in
            let s = String(decoding: data, as: UTF8.self)
            guard let id = UUID(uuidString: s) else {
                struct DecodeError: Error {}
                throw DecodeError()
            }
            return TierDragItem(userBookId: id)
        }
    }
}

/// Year filter rendered as a folder tab on the S tier box, in your own library
/// and on other people's. Counts come from the unfiltered read list so every
/// menu row can show "2025 (16)" style totals.
struct TierYearFilter {
    let availableYears: [Int]
    let selectedYear: Int?
    /// Book count for a year; nil = all read books.
    let countForYear: (Int?) -> Int
    let onSelect: (Int?) -> Void
}

/// Resolves the "Top N" badge/box size against how many books actually sit in the
/// S tier. `target` (4 or 8, from `topBookCount`) is only honored if the S tier is
/// big enough to fill it; otherwise this falls back to 4 so a user who's tiered
/// 50+ books overall but kept a small, selective S tier still gets "Top 4" instead
/// of no badge at all. Below 4, there's nothing meaningful to call out.
/// Shared by TierListView's badge and TierRowView's highlight box so the two never
/// drift out of lockstep.
private func resolvedTopCount(target: Int, sTierCount: Int) -> Int? {
    if sTierCount >= target { return target }
    if target > 4 && sTierCount >= 4 { return 4 }
    return nil
}

struct TierListView: View {
    let userBooks: [UserBook]
    /// (userBookId, tier, insertionIndex). Index 0 = first in row; nil = append at end.
    let onUpdateTierAndOrder: (UUID, String?, Int?) -> Void
    /// When set, tapping a book cover opens the book profile.
    var onBookTap: ((Book) -> Void)? = nil
    /// When true (viewing someone else's library), hide drag-and-drop.
    var readOnly: Bool = false
    /// `Book.id` of a book to pulse-glow + scroll into view (e.g. just-reviewed book sitting in Unranked).
    var highlightedBookId: String? = nil
    /// One-shot gate for the highlight auto-scroll. The highlight lingers until the book
    /// is tiered, but onAppear re-fires on every back-navigation and tab switch — only
    /// the appearance right after the review may move the scroll position. False keeps
    /// the glow and callout without any programmatic scrolling.
    var autoScrollsToHighlight: Bool = true
    /// Called once the auto-scroll has actually run against the present book, so the
    /// owner can drop `autoScrollsToHighlight` for every later appearance.
    var onHighlightAutoScrolled: (() -> Void)? = nil
    /// `Book.id`s to render with a selection check (Discover seed-book picker). Only used with `readOnly`.
    var selectedBookIds: Set<String> = []
    /// When set, the S tier box grows a header strip with this year dropdown in its top-right corner.
    var yearFilter: TierYearFilter? = nil
    /// Non-nil turns on double-tap multi-select (own library only; ignored with `readOnly`).
    var multiSelect: TierMultiSelectActions? = nil
    /// Fires as selection mode starts and ends so the owner can clear chrome that
    /// would collide with the bottom action bar (the floating + button).
    var onSelectionModeChanged: ((Bool) -> Void)? = nil

    @EnvironmentObject private var queueDragCoordinator: QueueBookDragCoordinator

    // Multi-select (see TierMultiSelect.swift for the bar, sheet and cover runner).
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var showMoveSheet = false
    @State private var showYearSheet = false
    @State private var showRemoveConfirm = false
    @StateObject private var coverFix = TierCoverFixRunner()

    /// Measured callout height (updated via preference) so the tail seats just above the book.
    @State private var calloutHeight: CGFloat = 58
    /// Gated on after the scroll settles so the callout fades in over the centered book.
    @State private var showCallout = false
    /// The S tier's year tab has scrolled above the viewport — show the flipped,
    /// pinned copy hanging from the top edge instead.
    @State private var yearTabScrolledPast = false

    /// Content area width for each row: list width minus horizontal padding and tier label.
    private static let tierLabelWidth: CGFloat = 38
    /// Must match the ScrollView content's `.padding(.horizontal, 4)` below.
    private static let horizontalPadding: CGFloat = 4 * 2

    var body: some View {
        GeometryReader { geo in
            let listWidth = geo.size.width
            let contentAreaWidth = max(0, listWidth - Self.horizontalPadding - Self.tierLabelWidth)

            ScrollViewReader { proxy in
                ScrollView {
                    // Plain VStack (6 rows) so every row — especially "unranked" at the
                    // bottom — is registered with the ScrollViewReader immediately;
                    // scrollTo on an unbuilt LazyVStack child silently does nothing.
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(tierLabels, id: \.self) { tier in
                            let books = sortedBooks(for: tier)
                            // Top N only means "absolute favorites" against the full list,
                            // so hide it while a year filter is narrowing the tier.
                            let topCount: Int? = (tier == "S" && yearFilter?.selectedYear == nil) ? topBookCount : nil
                            // Badge only once the tier is full enough for the first
                            // slots to actually mean "absolute favorites"; falls back
                            // to Top 4 rather than disappearing — see resolvedTopCount.
                            let activeTopCount: Int? = topCount.flatMap { resolvedTopCount(target: $0, sTierCount: books.count) }
                            // spacing 0 so the S tier's header pieces (Top N badge on
                            // the left, year tab on the right) sit flush on the row's
                            // top edge, reading as one piece of folder furniture.
                            VStack(spacing: 0) {
                                if activeTopCount != nil || (tier == "S" && yearFilter != nil) {
                                    HStack(alignment: .bottom, spacing: 8) {
                                        if let activeTopCount {
                                            topGroupBadge(count: activeTopCount)
                                                // Same spot as inside the box: label
                                                // column + row pad + first drop slot.
                                                .padding(.leading, Self.tierLabelWidth + tierRowPadding + tierDropSlotWidth)
                                                .padding(.bottom, 4)
                                        }
                                        Spacer(minLength: 0)
                                        if tier == "S", let yearFilter {
                                            yearFilterTab(yearFilter)
                                                .padding(.trailing, Theme.cardCornerRadius + 4)
                                                .background(
                                                    GeometryReader { g in
                                                        Color.clear.preference(
                                                            key: TierYearTabMaxYKey.self,
                                                            value: g.frame(in: .named(tierListScrollSpace)).maxY
                                                        )
                                                    }
                                                )
                                        }
                                    }
                                }
                                TierRowView(
                                    tier: tier,
                                    books: books,
                                    contentAreaWidth: contentAreaWidth,
                                    topCount: topCount,
                                    onUpdateTierAndOrder: onUpdateTierAndOrder,
                                    onBookTap: onBookTap,
                                    readOnly: readOnly,
                                    highlightedBookId: highlightedBookId,
                                    selectedBookIds: selectedBookIds,
                                    emptyHint: (!readOnly && hasNoRankedBooks) ? tierEmptyHint(for: tier) : nil,
                                    cellSelection: cellSelection
                                )
                            }
                        }
                        TierRowView(
                            tier: nil,
                            books: sortedBooks(for: nil),
                            contentAreaWidth: contentAreaWidth,
                            onUpdateTierAndOrder: onUpdateTierAndOrder,
                            onBookTap: onBookTap,
                            readOnly: readOnly,
                            highlightedBookId: highlightedBookId,
                            selectedBookIds: selectedBookIds,
                            cellSelection: cellSelection
                        )
                        .id("unranked")
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
                .coordinateSpace(name: tierListScrollSpace)
                // Once the in-flow tab scrolls off the top, a flipped copy hinges
                // down from the viewport edge and stays pinned so the filter is
                // always in reach on a long, filtered-down list.
                .overlay(alignment: .topTrailing) {
                    if let yearFilter, yearTabScrolledPast {
                        yearFilterTab(yearFilter, pinned: true)
                            // In-flow trailing inset plus the scroll content's own
                            // horizontal padding, so both copies line up.
                            .padding(.trailing, Theme.cardCornerRadius + 8)
                            // Flush to the viewport's top edge: the tab hangs off
                            // the chrome above, the way the in-flow copy rides the
                            // S row's edge. Inset it and it floats, disconnected.
                            .transition(
                                .modifier(
                                    active: TierYearTabHinge(angle: -92),
                                    identity: TierYearTabHinge(angle: 0)
                                )
                                .combined(with: .opacity)
                            )
                    }
                }
                .onPreferenceChange(TierYearTabMaxYKey.self) { maxY in
                    let past = maxY < 0
                    guard past != yearTabScrolledPast else { return }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                        yearTabScrolledPast = past
                    }
                }
                // Draw the "Rank me!" callout above the tier rows so it isn't clipped
                // by each row's rounded-rect mask, and point it at the exact book.
                .overlayPreferenceValue(TierHighlightAnchorKey.self) { anchor in
                    GeometryReader { overlayProxy in
                        // Hidden while selecting: the callout would sit over the checks.
                        if let anchor, showCallout, !isSelecting {
                            let rect = overlayProxy[anchor]
                            let W = overlayProxy.size.width
                            let bubbleW: CGFloat = 200
                            let edgePad: CGFloat = 16
                            let gap: CGFloat = 8
                            // Keep the bubble on screen, but let its tail slide to stay on the book.
                            let centerX = min(max(rect.midX, edgePad + bubbleW / 2), W - edgePad - bubbleW / 2)
                            let maxTail = bubbleW / 2 - 18
                            let tailOffset = min(max(rect.midX - centerX, -maxTail), maxTail)
                            let centerY = rect.minY - gap - calloutHeight / 2

                            TierHighlightCallout(tailOffset: tailOffset)
                                .frame(width: bubbleW)
                                .background(
                                    GeometryReader { g in
                                        Color.clear.preference(key: TierCalloutHeightKey.self, value: g.size.height)
                                    }
                                )
                                .position(x: centerX, y: max(calloutHeight / 2 + 4, centerY))
                                .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                        }
                    }
                    .onPreferenceChange(TierCalloutHeightKey.self) { calloutHeight = $0 }
                    .allowsHitTesting(false)
                }
                .onChange(of: highlightedBookId) { _, _ in
                    handleHighlightAppearance(proxy: proxy, delay: 0.25)
                }
                // A freshly marked-read book reaches `userBooks` only after the Firestore
                // listener echoes it back — often after onAppear's scroll already ran and
                // found nothing. Re-scroll the moment the highlighted book actually exists.
                .onChange(of: highlightedBookIsPresent) { _, present in
                    if present {
                        handleHighlightAppearance(proxy: proxy, delay: 0.15)
                    }
                }
                .onAppear {
                    handleHighlightAppearance(proxy: proxy, delay: 0.35)
                }
            }
        }
        // Multi-select chrome. A safe-area inset (not an overlay) so it stacks on
        // the tab bar's own inset and the last tier row can scroll clear of it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting, multiSelect != nil {
                TierSelectionActionBar(
                    selectionCount: selection.count,
                    coverFixPhase: coverFix.phase,
                    canFixCovers: multiSelect?.userId != nil,
                    onDone: exitSelection,
                    onMove: { showMoveSheet = true },
                    onDelete: { showRemoveConfirm = true },
                    onEditDate: { showYearSheet = true },
                    onFixCovers: startCoverFix,
                    onStopFixing: { coverFix.stop() },
                    onUndoCovers: {
                        if let uid = multiSelect?.userId { coverFix.undoAll(userId: uid) }
                    },
                    onKeepCovers: { coverFix.keep() }
                )
            }
        }
        // Discovery nudge while a cover is in hand: dragging books one at a time
        // is the moment multi-select is worth surfacing.
        .overlay(alignment: .bottom) {
            if showsMultiSelectDragTip {
                TierMultiSelectDragTip()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsMultiSelectDragTip)
        .sheet(isPresented: $showMoveSheet) {
            let ladder: [String?] = tierLabels.map { Optional($0) } + [nil]
            MoveToTierSheet(
                selectionCount: selection.count,
                tierCounts: Dictionary(uniqueKeysWithValues: ladder.map { ($0, sortedBooks(for: $0).count) }),
                commonTier: selectionCommonTier,
                onMove: performMove
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showYearSheet) {
            MoveToYearSheet(
                existingYears: readYearsInLibrary,
                yearCounts: readYearCounts,
                onMove: performYearMove
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert(removeConfirmTitle, isPresented: $showRemoveConfirm) {
            Button("Remove", role: .destructive) { performRemove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(selection.count == 1
                 ? "This removes the book from your read shelf and deletes your review and feed post if any."
                 : "This removes them from your read shelf and deletes your reviews and feed posts if any.")
        }
        .sensoryFeedback(.selection, trigger: selection)
        .sensoryFeedback(.impact(weight: .medium), trigger: isSelecting) { _, now in now }
        .onChange(of: isSelecting) { _, now in onSelectionModeChanged?(now) }
        // Switching to the Queue tab tears this view down without ending selection
        // mode first; the owner must still hear that it ended.
        .onDisappear {
            if isSelecting { onSelectionModeChanged?(false) }
        }
    }

    // MARK: - Multi-select

    /// Shown only on a list that can actually multi-select, while a read book is
    /// being dragged and selection mode hasn't started yet.
    private var showsMultiSelectDragTip: Bool {
        cellSelection != nil && !isSelecting && queueDragCoordinator.isDraggingReadBook
    }

    /// Cell plumbing, or nil when this list can't select (read-only, or no actions).
    private var cellSelection: TierCellSelection? {
        guard !readOnly, multiSelect != nil else { return nil }
        return TierCellSelection(
            isSelecting: isSelecting,
            selectedIds: selection,
            coverFixStatuses: coverFix.statuses,
            onToggle: toggleSelection,
            onEnter: enterSelection
        )
    }

    /// The selection in display order: S row first, Unranked last, row order within.
    private var selectedUserBooks: [UserBook] {
        let ladder: [String?] = tierLabels.map { Optional($0) } + [nil]
        return ladder.flatMap { t in sortedBooks(for: t).filter { selection.contains($0.id) } }
    }

    /// `.some(tier)` when every selected book already sits in one tier (nil tier = Unranked).
    private var selectionCommonTier: String?? {
        let tiers = Set(selectedUserBooks.map(\.normalizedTier))
        if tiers.count == 1, let only = tiers.first { return .some(only) }
        return nil
    }

    private var removeConfirmTitle: String {
        selection.count == 1
            ? "Remove this book from your read shelf?"
            : "Remove \(selection.count) books from your read shelf?"
    }

    private func enterSelection(with userBookId: UUID) {
        guard cellSelection != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            selection = [userBookId]
            isSelecting = true
        }
    }

    private func toggleSelection(_ userBookId: UUID) {
        if selection.contains(userBookId) {
            selection.remove(userBookId)
        } else {
            selection.insert(userBookId)
        }
    }

    /// Leaves selection mode. A cover fix still running finishes its in-flight
    /// book and keeps what it changed, same as walking away from the single-book flow.
    private func exitSelection() {
        coverFix.keep()
        withAnimation(.easeInOut(duration: 0.2)) {
            selection.removeAll()
            isSelecting = false
        }
    }

    private func performMove(to tier: String?) {
        let books = selectedUserBooks
        guard !books.isEmpty else { return }
        multiSelect?.moveToTier(books.map(\.id), tier)
        showMoveSheet = false
        let noun = books.count == 1 ? "1 book" : "\(books.count) books"
        let destination = tier.map { "\($0) Tier" } ?? "Unranked"
        ToastCenter.shared.show(Toast(style: .success, status: "Moved", message: "\(noun) moved to \(destination)"))
        exitSelection()
    }

    /// Years this library has read books in, newest first — the shortcut rows in
    /// the year sheet.
    private var readYearsInLibrary: [Int] {
        let cal = Calendar.current
        let years = userBooks.filter { $0.status == .read }
            .flatMap { $0.allReadDates.map { cal.component(.year, from: $0) } }
        return Array(Set(years)).sorted(by: >)
    }

    private var readYearCounts: [Int: Int] {
        let cal = Calendar.current
        var counts: [Int: Int] = [:]
        for ub in userBooks where ub.status == .read {
            for year in Set(ub.allReadDates.map({ cal.component(.year, from: $0) })) {
                counts[year, default: 0] += 1
            }
        }
        return counts
    }

    /// Re-file the selection under `year`. Each book moves the read that its
    /// primary date belongs to, so a re-read logged in another year stays put.
    private func performYearMove(to year: Int) {
        let books = selectedUserBooks
        guard !books.isEmpty, let multiSelect else { return }
        multiSelect.setReadYear(books.map(\.id), year)
        showYearSheet = false
        let noun = books.count == 1 ? "1 book" : "\(books.count) books"
        ToastCenter.shared.show(Toast(style: .success, status: "Moved", message: "\(noun) moved to \(year)"))
        exitSelection()
    }

    private func performRemove() {
        guard let multiSelect else { return }
        let ids = selectedUserBooks.map(\.id)
        guard !ids.isEmpty else { return }
        exitSelection()
        Task { @MainActor in
            let failures = await multiSelect.remove(ids)
            if failures == 0 {
                let noun = ids.count == 1 ? "1 book" : "\(ids.count) books"
                ToastCenter.shared.show(Toast(style: .success, status: "Removed", message: "\(noun) removed from your read shelf"))
            } else {
                ToastCenter.shared.show(Toast(style: .error, status: "Failed", message: "\(failures) of \(ids.count) couldn't be removed"))
            }
        }
    }

    private func startCoverFix() {
        guard let uid = multiSelect?.userId else { return }
        coverFix.start(books: selectedUserBooks, userId: uid)
    }

    /// How many books at the front of the S tier count as the user's absolute favorites:
    /// top 4 normally, top 8 once they've ranked 50+ books.
    private var topBookCount: Int {
        let rankedCount = userBooks.filter { $0.normalizedTier != nil }.count
        return rankedCount >= 50 ? 8 : 4
    }

    /// True when this person hasn't put a single book into a tier yet (everything
    /// sits in Unranked) — gates the faint S/F placeholder hints.
    private var hasNoRankedBooks: Bool {
        !userBooks.contains { $0.normalizedTier != nil }
    }

    /// Whether the highlighted book has actually arrived in `userBooks` (Firestore echo).
    private var highlightedBookIsPresent: Bool {
        guard let highlightedBookId else { return false }
        return userBooks.contains { $0.book?.id == highlightedBookId }
    }

    /// Routes a highlight trigger (onAppear, highlight id change, Firestore echo) to
    /// either the one-shot auto-scroll or, once that's consumed, just the callout —
    /// a lingering highlight must never move the scroll position again.
    private func handleHighlightAppearance(proxy: ScrollViewProxy, delay: TimeInterval) {
        guard highlightedBookId != nil else {
            withAnimation(.easeOut(duration: 0.2)) { showCallout = false }
            return
        }
        guard autoScrollsToHighlight else {
            // No scrolling — but the "Rank me" bubble should still ride the glowing
            // book whenever the user brings it on screen themselves.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard highlightedBookId != nil else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { showCallout = true }
            }
            return
        }
        // Consume only once the book actually exists in the list: onAppear can run
        // before the Firestore echo delivers it, and the onChange re-scroll above
        // must still get its one real shot at centering the book.
        if highlightedBookIsPresent { onHighlightAutoScrolled?() }
        scrollToHighlight(proxy: proxy, delay: delay)
    }

    /// Brings the freshly-reviewed book into view and fades the callout in once it settles.
    /// Two-stage: scroll to the Unranked row first (its anchor always exists, and getting
    /// it on screen builds the lazy book cells inside it), then center the exact book.
    private func scrollToHighlight(proxy: ScrollViewProxy, delay: TimeInterval) {
        showCallout = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard highlightedBookId != nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo("unranked", anchor: .top)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard highlightedBookId != nil else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(tierHighlightScrollID, anchor: .center)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard highlightedBookId != nil else { return }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        showCallout = true
                    }
                }
            }
        }
    }

    private func sortedBooks(for tier: String?) -> [UserBook] {
        // Must stay in lockstep with AppState.setTierAndOrder — drop-slot indices are
        // positions in this exact ordering.
        spineTierSorted(userBooks.filter { $0.normalizedTier == tier })
    }

    /// "♛ TOP 4" chrome chip floating above the S tier box, lined up with the
    /// covers' leading edge inside it.
    private func topGroupBadge(count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "crown.fill")
                .font(.system(size: 8, weight: .bold))
            Text(SpinesGlyphs.caps("Top \(count)"))
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
        }
        .foregroundStyle(Theme.onChrome)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(topGroupTint))
        .accessibilityLabel("Top \(count) books")
    }

    /// "2025 (16)" / "All (288)" label for the year tab and its menu rows.
    private func yearFilterLabel(_ year: Int?, _ filter: TierYearFilter) -> String {
        let name = year.map(ReadDate.yearLabel) ?? "All"
        return "\(name) (\(filter.countForYear(year)))"
    }

    /// Year dropdown styled as a physical folder tab riding the top edge of the
    /// S tier box: rounded top corners, square bottom, and the exact row surface
    /// fill so tab and box read as one piece. The `pinned` copy is its mirror,
    /// hanging from the viewport's top edge once the original scrolls past —
    /// corners flipped to the bottom, solid fill, and a shadow so it reads as
    /// floating over the covers instead of merging into them.
    private func yearFilterTab(_ filter: TierYearFilter, pinned: Bool = false) -> some View {
        Menu {
            Button(yearFilterLabel(nil, filter)) { filter.onSelect(nil) }
            ForEach(filter.availableYears, id: \.self) { year in
                Button(yearFilterLabel(year, filter)) { filter.onSelect(year) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(yearFilterLabel(filter.selectedYear, filter))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 13)
            .padding(.top, pinned ? 5 : 6)
            .padding(.bottom, pinned ? 6 : 5)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: pinned ? 0 : 10,
                    bottomLeadingRadius: pinned ? 10 : 0,
                    bottomTrailingRadius: pinned ? 10 : 0,
                    topTrailingRadius: pinned ? 0 : 10
                )
                // Pinned floats over covers, so it needs an opaque fill — use the
                // color the in-flow tab's surface-at-60% composites to over the
                // page background, so both copies read as the same material.
                .fill(pinned
                    ? AnyShapeStyle(Theme.blend(Theme.background, toward: Theme.surface, light: 0.6, dark: 0.6))
                    : AnyShapeStyle(Theme.surface.opacity(0.6)))
                .shadow(color: pinned ? Theme.shadowInk.opacity(0.2) : .clear, radius: 6, x: 0, y: 3)
            )
        }
        .accessibilityLabel("Filter books by year")
    }
}

/// Min/max book size so 4-per-row stays readable and doesn't clip.
private let tierBookSizeMin: CGFloat = 48
private let tierBookSizeMax: CGFloat = 88
private let tierRowPadding: CGFloat = 1
/// Vertical gap between rows of covers inside a tier. Small, but non-zero so
/// the covers don't read as squished top to bottom.
private let tierRowSpacing: CGFloat = 5
/// Shared fill for the Top N badge and the favorites box behind its covers:
/// one color that meets halfway between the old grey wash (0.14/0.24 toward
/// chrome) and the solid chrome chip, so badge and box read as a matched set.
private var topGroupTint: Color {
    Theme.blend(Theme.background, toward: Theme.chrome, light: 0.57, dark: 0.62)
}

/// Leading inset of the "Top N" favorites box background within the S-tier row.
private let topGroupInset: CGFloat = 5
/// Trailing inset of the box background, kept clear of the row's corner clip.
private let topGroupTrailingInset: CGFloat = 8

struct TierRowView: View {
    let tier: String?
    let books: [UserBook]
    /// Passed from TierListView so books-per-row matches actual width and nothing clips.
    var contentAreaWidth: CGFloat = 0
    /// Non-nil for the S tier only: the first `topCount` books are the user's absolute
    /// favorites, called out with a "TOP N" header and a divider before the rest of the row.
    var topCount: Int? = nil
    let onUpdateTierAndOrder: (UUID, String?, Int?) -> Void
    var onBookTap: ((Book) -> Void)? = nil
    var readOnly: Bool = false
    var highlightedBookId: String? = nil
    var selectedBookIds: Set<String> = []
    /// Faint copy shown in this row when it's empty (own S/F tier, nothing ranked yet).
    var emptyHint: String? = nil
    /// Multi-select plumbing from TierListView; nil when this list can't select.
    var cellSelection: TierCellSelection? = nil

    var header: String {
        tier ?? "Unranked"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Shared with the feed's posts (see TierBadge.swift): the letter pins
            // to the top of the viewport while a tall tier scrolls by.
            TierRowPillar(tier: tier, stickyScrollSpace: tierListScrollSpace, stickyTopInset: tierStickyTopInset)
                .frame(minHeight: 96)
                .frame(maxHeight: .infinity)

            tierContent(contentWidth: contentAreaWidth, readOnly: readOnly)
                .frame(minHeight: 96)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 0)
                        .fill(Theme.surface.opacity(0.6))
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }

    @ViewBuilder
    private func tierContent(contentWidth: CGFloat, readOnly: Bool) -> some View {
        let w = contentWidth > 0 ? contentWidth : 280
        // The top-group callout only appears once the S tier is full enough for the
        // first slots to actually mean "your absolute favorites"; falls back to
        // Top 4 rather than disappearing — see resolvedTopCount.
        let activeTopCount: Int? = topCount.flatMap { resolvedTopCount(target: $0, sTierCount: books.count) }
        // Every tier reserves the same clearance (the top-favorites box's trailing
        // inset), so covers are one size everywhere and their columns line up
        // across tiers — and top-group rows always end inside the inset box.
        let available = w - tierRowPadding * 2 - topGroupTrailingInset
        let booksPerRow = 4
        // One narrow slot before each cover, plus the trailing slot: it's flexible
        // upward but can't compress below its minWidth, so full rows (and the Top N
        // box hugging them) overflow the row's right edge unless it's reserved too.
        // Read-only slots render at 6pt (see TierRowDropSlot), so size books off the
        // real slot width or read-only rows end up with dead space on the right.
        let slotWidth: CGFloat = readOnly ? 6 : tierDropSlotWidth
        let slotSpace = CGFloat(booksPerRow + 1) * slotWidth
        let bookSize = min(tierBookSizeMax, max(tierBookSizeMin, (available - slotSpace) / CGFloat(booksPerRow)))
        let slotHeight = max(64, bookSize * 1.15)
        let rows: [[UserBook]] = books.isEmpty
            ? []
            : stride(from: 0, to: books.count, by: booksPerRow).map { start in
                Array(books[start..<min(start + booksPerRow, books.count)])
            }
        // A plain VStack, not a LazyVStack: nested lazy stacks estimate the
        // height of rows they haven't built yet, and every re-render (selection
        // toggles, listener echoes, coming back from a book page) can revise
        // those estimates for rows above the viewport, which shoves the scroll
        // position to a different spot in the tier. Eager rows cost a few
        // hundred cheap covers on the biggest libraries and keep the layout exact.
        VStack(alignment: .leading, spacing: tierRowSpacing) {
            if rows.isEmpty {
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        TierRowDropSlot(tier: tier, insertionIndex: 0, onUpdateTierAndOrder: onUpdateTierAndOrder, fillsRow: true, minHeight: slotHeight, readOnly: readOnly)
                    }
                    if let emptyHint {
                        Text(emptyHint)
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 1)
            } else {
                // Rows containing the user's absolute favorites get their own tinted
                // background block (the "TOP N" badge floats above the row, drawn by
                // TierListView) so the group reads as a distinct section instead of
                // relying on a hairline.
                let topRowCount = activeTopCount.map { $0 / booksPerRow } ?? 0
                let allRows = Array(rows.enumerated())
                if activeTopCount != nil {
                    VStack(alignment: .leading, spacing: tierRowSpacing) {
                        ForEach(allRows.prefix(topRowCount), id: \.offset) { rowIndex, rowBooks in
                            bookRow(rowIndex: rowIndex, rowBooks: rowBooks, booksPerRow: booksPerRow, slotHeight: slotHeight, bookSize: bookSize)
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .background(
                        // Same fill as the Top N badge above the row, so chip and
                        // box read as one matched set.
                        RoundedRectangle(cornerRadius: 8)
                            .fill(topGroupTint)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Theme.blend(Theme.background, toward: Theme.chrome, light: 0.72, dark: 0.8), lineWidth: 1)
                            )
                            // Only the box background is inset — the rows inside keep
                            // the exact geometry of every other row, so the top covers
                            // sit flush with the covers below instead of shifted right.
                            // The trailing inset also keeps the box's rounded right
                            // edge clear of the row's 14pt corner clip.
                            .padding(.leading, topGroupInset)
                            .padding(.trailing, topGroupTrailingInset)
                    )
                    .padding(.top, 3)
                    .padding(.bottom, 2)
                }
                ForEach(allRows.dropFirst(topRowCount), id: \.offset) { rowIndex, rowBooks in
                    bookRow(rowIndex: rowIndex, rowBooks: rowBooks, booksPerRow: booksPerRow, slotHeight: slotHeight, bookSize: bookSize)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: books.map(\.id))
        // Extra top room: the multi-select check rides 6pt above each cover
        // (plus its halo), and the row's rounded-rect clip would chop it off on
        // the first row otherwise. Static so entering selection never reflows.
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    /// One row of up to 4 covers with drop slots before each and a flexible trailing slot.
    private func bookRow(rowIndex: Int, rowBooks: [UserBook], booksPerRow: Int, slotHeight: CGFloat, bookSize: CGFloat) -> some View {
        let startIndex = rowIndex * booksPerRow
        return HStack(spacing: 0) {
            ForEach(Array(rowBooks.enumerated()), id: \.element.id) { i, ub in
                TierRowDropSlot(tier: tier, insertionIndex: startIndex + i, onUpdateTierAndOrder: onUpdateTierAndOrder, minHeight: slotHeight, readOnly: readOnly)
                if ub.book != nil {
                    TierBookCell(userBook: ub, tier: tier, insertionIndex: startIndex + i, bookSize: bookSize, onUpdateTierAndOrder: onUpdateTierAndOrder, onBookTap: onBookTap, readOnly: readOnly, isHighlighted: highlightedBookId != nil && ub.book?.id == highlightedBookId, isSelected: selectedBookIds.contains(ub.bookId), cellSelection: cellSelection)
                }
            }
            TierRowDropSlot(tier: tier, insertionIndex: startIndex + rowBooks.count, onUpdateTierAndOrder: onUpdateTierAndOrder, fillsRow: true, minHeight: slotHeight, readOnly: readOnly)
        }
        .padding(.horizontal, 1)
    }

}

/// Fraction of book width that acts as "insert before" (left) or "insert after" (right) drop zone when dragging between books.
private let tierBookDropZoneFraction: CGFloat = 0.3

struct TierBookCell: View {
    @EnvironmentObject private var queueDragCoordinator: QueueBookDragCoordinator

    let userBook: UserBook
    let tier: String?
    let insertionIndex: Int
    var bookSize: CGFloat = 72
    let onUpdateTierAndOrder: (UUID, String?, Int?) -> Void
    var onBookTap: ((Book) -> Void)? = nil
    var readOnly: Bool = false
    /// True when this is the just-reviewed book sitting in Unranked — pulses a tier-color glow until tiered.
    var isHighlighted: Bool = false
    /// True when picked as a Discover seed book (readOnly picker mode) — shows a check overlay.
    var isSelected: Bool = false
    /// Own-library multi-select (double-tap to start). Nil when unavailable.
    var cellSelection: TierCellSelection? = nil

    @State private var pulseOn = false

    /// Single tap: toggles the book while selecting, opens it otherwise.
    private var singleTapAction: (() -> Void)? {
        if let cellSelection, cellSelection.isSelecting {
            let id = userBook.id
            return { cellSelection.onToggle(id) }
        }
        guard let onBookTap, let book = userBook.book else { return nil }
        return { onBookTap(book) }
    }

    private var doubleTapAction: (() -> Void)? {
        guard let cellSelection else { return nil }
        let id = userBook.id
        return { cellSelection.onEnter(id) }
    }

    var body: some View {
        Group {
            if let book = userBook.book {
                if readOnly {
                    BookCoverView(book: book, size: bookSize, onTap: onBookTap != nil ? { onBookTap?(book) } : nil)
                        .overlay(selectionOverlay)
                } else {
                    ZStack {
                        ReadListBookDragCover(
                            book: book,
                            userBookId: userBook.id,
                            bookSize: bookSize,
                            onTap: singleTapAction,
                            onDoubleTap: doubleTapAction,
                            isSelecting: cellSelection?.isSelecting == true,
                            dragCoordinator: queueDragCoordinator
                        )
                        .frame(width: bookSize, height: bookSize * 1.5)
                        .overlay(alignment: .leading) {
                            HStack(spacing: 0) {
                                dropZone(insertAt: insertionIndex)
                                    .frame(width: bookSize * tierBookDropZoneFraction)
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .allowsHitTesting(false)
                                dropZone(insertAt: insertionIndex + 1)
                                    .frame(width: bookSize * tierBookDropZoneFraction)
                            }
                            .frame(width: bookSize, height: bookSize * 1.5)
                        }
                    }
                    .overlay(highlightOverlay)
                    .overlay(multiSelectOverlay)
                    .scaleEffect(isHighlighted && pulseOn ? 1.04 : 1.0)
                    .animation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true), value: pulseOn)
                    .onAppear {
                        if isHighlighted { pulseOn = true }
                    }
                    .onChange(of: isHighlighted) { _, newValue in
                        pulseOn = newValue
                    }
                }
            }
        }
        // Scroll target + callout anchor for the just-reviewed book.
        .scrollAnchorID(tierHighlightScrollID, active: isHighlighted)
        .anchorPreference(key: TierHighlightAnchorKey.self, value: .bounds) { isHighlighted ? $0 : nil }
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.accent, lineWidth: 2.5)
                .frame(width: bookSize, height: bookSize * 1.5)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accent)
                        .background(Circle().fill(Theme.background))
                        .offset(x: 6, y: -6)
                }
                .allowsHitTesting(false)
        }
    }

    /// Selection mode: an accent ring plus check on picked covers, a faint hollow
    /// circle on the rest (so every cover reads as tappable), and the cover-fix
    /// badge in place of the check while a batch cover fix is running or awaiting
    /// keep/undo.
    @ViewBuilder
    private var multiSelectOverlay: some View {
        if let cellSelection, cellSelection.isSelecting {
            let picked = cellSelection.selectedIds.contains(userBook.id)
            let fixStatus = cellSelection.coverFixStatuses[userBook.id]
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.accent.opacity(picked ? 1 : 0), lineWidth: 2.5)
                .frame(width: bookSize, height: bookSize * 1.5)
                .overlay(alignment: .topTrailing) {
                    Group {
                        if let fixStatus {
                            TierCoverFixBadge(status: fixStatus)
                        } else if picked {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.accent)
                                .background(Circle().fill(Theme.background))
                        } else {
                            Circle()
                                .strokeBorder(Theme.textTertiary.opacity(0.7), lineWidth: 1.5)
                                .background(Circle().fill(Theme.background.opacity(0.85)))
                                .frame(width: 18, height: 18)
                        }
                    }
                    .offset(x: 6, y: -6)
                }
                .animation(.easeInOut(duration: 0.15), value: picked)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var highlightOverlay: some View {
        if isHighlighted {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.accent, lineWidth: 2.5)
                .shadow(color: Theme.accent.opacity(pulseOn ? 0.95 : 0.3), radius: pulseOn ? 14 : 4)
                .shadow(color: Theme.accent.opacity(pulseOn ? 0.7 : 0.2), radius: pulseOn ? 22 : 8)
                .frame(width: bookSize, height: bookSize * 1.5)
                .allowsHitTesting(false)
        }
    }

    private func dropZone(insertAt index: Int) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .dropDestination(for: TierDragItem.self) { items, _ in
                guard let payload = items.first else { return false }
                onUpdateTierAndOrder(payload.userBookId, tier, index)
                return true
            } isTargeted: { targeted in
                if targeted { LibraryDragHaptics.dropTargetHoverEntered() }
            }
    }
}
