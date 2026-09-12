//
//  FeedInterstitials.swift
//  Spine
//
//  Two pseudo posts per feed load, three items down and six below that:
//  "Selected for you" always leads. "Selected for you" is three covers
//  lifted straight out of the Discover pipeline (the card plus its prefetched
//  queue), plus a "Discover more" tile into Discover.
//  Showing a book here never consumes or dismisses it, so a pick scrolled past
//  by accident is still waiting on the Discover card. The row draws at its full
//  height from the start, tile and all, even before any picks have loaded, so
//  late-arriving books never shove the feed mid-scroll. "Readers to follow" is
//  the not-yet-followed roster in the people strip's mutual-connection order,
//  with a quick Follow and an X that hides that reader from suggestions for
//  good. Both rows hold their content until the feed is refreshed, and even
//  then only the rows the reader actually reached are re-picked.
//

import SwiftUI

/// Bookkeeping behind the interstitial rows. Owned by FeedView so slot
/// assignments survive the LazyVStack recycling cells, and so a slot keeps
/// the same books and readers while the user scrolls instead of reshuffling
/// every time the pool underneath changes.
@MainActor
final class FeedInterstitialModel: ObservableObject {
    enum Kind {
        case books, people

        /// The two rows in draw order. Picks always lead: they're the row that
        /// can draw immediately (tile plus shimmering covers) whatever has
        /// loaded, so putting readers first risks an empty roster leaving the
        /// lead slot blank and pushing picks six items further down the feed.
        static func defaultOrder() -> [Kind] { [.books, .people] }
    }

    static let itemsPerSlot = 3

    /// Readers X'd out this session (merged with the persisted list on the
    /// user doc). Published so the card leaves the row the moment it's tapped.
    @Published private(set) var dismissedUids: Set<String> = []
    /// Uids with a follow write in flight (debounces the Follow button).
    @Published private(set) var followInFlight: Set<String> = []
    /// Bumped when a reload re-picks the rows, so the feed rebuilds them.
    @Published private(set) var generation = 0

    /// Which pseudo post leads this load: picks first, readers below.
    private var kindOrder: [Kind] = Kind.defaultOrder()
    /// Slot → book ids / reader uids. Plain storage on purpose: assignments
    /// are derived during layout, and publishing them from there would
    /// re-enter the view update.
    private var bookSlots: [Int: [String]] = [:]
    private var peopleSlots: [Int: [String]] = [:]
    /// Slots that have actually been on screen since the last reload. A reload
    /// re-picks only these: a row the reader never scrolled to keeps what it
    /// was holding rather than quietly burning three recommendations.
    private var seenSlots: Set<Int> = []

    // MARK: Kind

    /// The row this slot draws. The two slots never draw the same kind, so a
    /// slot whose content isn't there leaves a gap rather than doubling up the
    /// other row (FeedView decides that part).
    func preferredKind(for slot: Int) -> Kind {
        #if DEBUG
        // `-uiPreviewFeedPeoplePicks` / `-uiPreviewFeedBookPicks` pin every slot
        // to one kind for simulator verification.
        if ProcessInfo.processInfo.arguments.contains("-uiPreviewFeedPeoplePicks") { return .people }
        if ProcessInfo.processInfo.arguments.contains("-uiPreviewFeedBookPicks") { return .books }
        #endif
        return kindOrder.indices.contains(slot) ? kindOrder[slot] : .books
    }

    /// A row reached the screen. Feeds the reload rule below.
    func markSeen(slot: Int) {
        seenSlots.insert(slot)
    }

    /// Pull to refresh (or any feed reload): fresh picks for the rows the
    /// reader has already seen. A refresh
    /// from above the rows leaves them exactly as they were, so recommendations
    /// the reader never laid eyes on aren't spent.
    func handleFeedReload() {
        guard !seenSlots.isEmpty else { return }
        for slot in seenSlots {
            bookSlots[slot] = nil
            peopleSlots[slot] = nil
        }
        seenSlots = []
        kindOrder = Kind.defaultOrder()
        // Layout reads `kindOrder` and the slot maps directly, so nudge the
        // feed to rebuild the rows with them.
        generation += 1
    }

    // MARK: Books

    /// Books for `slot`, frozen once assigned. Books that have since left the
    /// pool (read, queued, passed on in Discover) drop out and the slot tops
    /// up from books no other slot is showing yet, in pool order.
    func books(for slot: Int, pool: [Book]) -> [Book] {
        let poolIds = Set(pool.map(\.id))
        var ids = (bookSlots[slot] ?? []).filter { poolIds.contains($0) }
        if ids.count < Self.itemsPerSlot {
            var taken = Set(bookSlots.values.joined())
            taken.formUnion(ids)
            for book in pool where !taken.contains(book.id) {
                ids.append(book.id)
                taken.insert(book.id)
                if ids.count == Self.itemsPerSlot { break }
            }
        }
        bookSlots[slot] = ids
        let byId = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byId[$0] }
    }

    /// True when `slot` couldn't fill and more pool would help.
    func slotWantsMoreBooks(_ slot: Int, pool: [Book]) -> Bool {
        (bookSlots[slot]?.count ?? 0) < Self.itemsPerSlot && pool.count < AppState.discoverPoolCap
    }

    // MARK: People

    /// Readers for `slot` from the ranked not-yet-followed roster, minus anyone
    /// followed or dismissed since. Same freeze-and-top-up as books.
    func readers(for slot: Int, ranked: [PeopleStripModel.Reader], following: Set<String>, persistedDismissed: [String]) -> [PeopleStripModel.Reader] {
        let hidden = dismissedUids.union(persistedDismissed).union(following)
        let eligible = ranked.filter { !hidden.contains($0.uid) }
        let eligibleIds = Set(eligible.map(\.uid))
        var ids = (peopleSlots[slot] ?? []).filter { eligibleIds.contains($0) }
        if ids.count < Self.itemsPerSlot {
            var taken = Set(peopleSlots.values.joined())
            taken.formUnion(ids)
            for reader in eligible where !taken.contains(reader.uid) {
                ids.append(reader.uid)
                taken.insert(reader.uid)
                if ids.count == Self.itemsPerSlot { break }
            }
        }
        peopleSlots[slot] = ids
        let byId = Dictionary(eligible.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byId[$0] }
    }

    func dismiss(uid: String) {
        dismissedUids.insert(uid)
    }

    func beginFollow(_ uid: String) -> Bool {
        guard !followInFlight.contains(uid) else { return false }
        followInFlight.insert(uid)
        return true
    }

    func endFollow(_ uid: String) {
        followInFlight.remove(uid)
    }

    /// New member signed in: nothing from the previous member's session applies.
    func reset() {
        dismissedUids = []
        followInFlight = []
        bookSlots = [:]
        peopleSlots = [:]
        seenSlots = []
        kindOrder = Kind.defaultOrder()
        generation += 1
    }
}

// MARK: - Selected for you

/// Three Discover picks side by side plus a "Discover more" tile into Discover.
struct FeedBookPicksRow: View {
    let books: [Book]
    let onBookTap: (Book) -> Void
    let onSeeMore: () -> Void

    private static let cellSpacing: CGFloat = 10
    /// Widest a cover goes if the row somehow has few cells (iPad, missing picks).
    private static let maxCoverWidth: CGFloat = 96

    /// Covers stretch to fill the row so the gutter after the "Discover more" tile
    /// matches the leading margin instead of leaving a wide gap on the right.
    /// Sized for a full row (three picks plus the tile) whatever is actually
    /// loaded, so picks arriving late don't resize the row and shove the feed
    /// under the reader's thumb.
    private var coverWidth: CGFloat {
        let cells = CGFloat(FeedInterstitialModel.itemsPerSlot + 1)
        let available = UIScreen.main.bounds.width
            - Theme.horizontalPadding * 2
            - Self.cellSpacing * (cells - 1)
        return min((available / cells).rounded(.down), Self.maxCoverWidth)
    }

    /// Cells the picks haven't filled yet.
    private var placeholderCount: Int {
        max(FeedInterstitialModel.itemsPerSlot - books.count, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FeedInterstitialHeader(icon: "sparkles", title: "SELECTED FOR YOU")
            HStack(alignment: .top, spacing: Self.cellSpacing) {
                ForEach(books) { book in
                    bookCell(book)
                }
                // Cover-shaped shimmer for picks still on their way, so the
                // row reads as loading rather than as a lone tile.
                // Array, not a bare range: the count changes as picks land and
                // ForEach over a non-constant Range misbehaves.
                ForEach(Array(0..<placeholderCount), id: \.self) { _ in
                    FeedPickPlaceholderCover(width: coverWidth)
                }
                seeMoreCell
            }
            .padding(.horizontal, Theme.horizontalPadding)
            FeedInterstitialDivider()
        }
        .padding(.top, 14)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: books.map(\.id))
    }

    private func bookCell(_ book: Book) -> some View {
        Button {
            onBookTap(book)
        } label: {
            BookCoverView(book: book, size: coverWidth)
                .frame(width: coverWidth)
        }
        .buttonStyle(.springPress)
        .accessibilityLabel("\(book.title) by \(book.author), open book")
    }

    /// Fourth "cover": a dashed tile the height of the covers that opens Discover.
    private var seeMoreCell: some View {
        Button {
            onSeeMore()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .bold))
                Text("Discover more")
                    .font(.system(size: 11, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 10)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(Theme.chrome)
            .frame(width: coverWidth, height: coverWidth * 1.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.surface.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.chrome.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        .buttonStyle(.springPress)
        .accessibilityLabel("Discover more picks")
    }
}

/// A pick that hasn't arrived yet: a cover-shaped shimmer holding the cell.
/// The sweep gives up after `shimmerDeadlineSeconds` and settles into a plain
/// paper rectangle, so a member whose pool never fills (tiny library, offline)
/// isn't left watching something pulse forever.
private struct FeedPickPlaceholderCover: View {
    let width: CGFloat

    private static let shimmerDeadlineSeconds: UInt64 = 8

    @State private var isLoading = true

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 6) }

    var body: some View {
        Group {
            if isLoading {
                ShimmerShape(shape: shape)
            } else {
                shape.fill(Theme.surface.opacity(0.7))
            }
        }
        .frame(width: width, height: width * 1.5)
        .overlay(
            shape.strokeBorder(Theme.chrome.opacity(0.35), lineWidth: 0.75)
        )
        .task {
            try? await Task.sleep(nanoseconds: Self.shimmerDeadlineSeconds * 1_000_000_000)
            isLoading = false
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Readers to follow

/// Three not-yet-followed readers as cards: avatar, name, Follow.
/// The X top-right hides that reader from future suggestions.
struct FeedPeoplePicksRow: View {
    let readers: [PeopleStripModel.Reader]
    let readingNowByUid: [String: [Book]]
    let followInFlight: Set<String>
    let onFollow: (PeopleStripModel.Reader) -> Void
    let onDismiss: (PeopleStripModel.Reader) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FeedInterstitialHeader(
                icon: "person.2",
                title: "READERS TO FOLLOW",
                subtitle: "Connected to the readers you already follow."
            )
            HStack(alignment: .top, spacing: 10) {
                ForEach(readers) { reader in
                    readerCard(reader)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92)),
                            removal: .opacity.combined(with: .scale(scale: 0.85))
                        ))
                }
            }
            .padding(.horizontal, Theme.horizontalPadding)
            FeedInterstitialDivider()
        }
        .padding(.top, 14)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: readers.map(\.uid))
    }

    private func readerCard(_ reader: PeopleStripModel.Reader) -> some View {
        let readingNow = readingNowByUid[reader.uid] ?? []
        return VStack(spacing: 8) {
            NavigationLink(value: reader.uid) {
                VStack(spacing: 8) {
                    UserAvatarView(
                        urlString: reader.user.profileImageURL,
                        displayName: reader.user.displayName,
                        firstName: reader.user.firstName,
                        lastName: reader.user.lastName,
                        size: 56
                    )
                    .overlay(Circle().strokeBorder(Theme.chrome.opacity(0.55), lineWidth: 1.5))
                    .overlay(alignment: .bottomLeading) {
                        if !readingNow.isEmpty {
                            ReadingNowFanStack(books: readingNow, coverWidth: 17)
                                .offset(x: -8, y: 7)
                        }
                    }
                    Text(reader.user.displayName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            followButton(reader)
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.surface.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.chrome.opacity(0.25), lineWidth: Theme.chromeHairline)
        )
        .overlay(alignment: .topTrailing) {
            Button {
                onDismiss(reader)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(2)
            .accessibilityLabel("Don't suggest \(reader.user.displayName)")
        }
        .accessibilityElement(children: .contain)
    }

    private func followButton(_ reader: PeopleStripModel.Reader) -> some View {
        let busy = followInFlight.contains(reader.uid)
        return Button {
            onFollow(reader)
        } label: {
            Text("Follow")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Theme.onChrome)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.accentGloss))
                .opacity(busy ? 0.6 : 1)
        }
        .buttonStyle(.springPress)
        .disabled(busy)
        .padding(.horizontal, 4)
        .accessibilityLabel("Follow \(reader.user.displayName)")
    }
}

// MARK: - Shared chrome

/// Small-caps chrome label with a glyph, plus a one-line explanation, in the
/// same voice as the FEED / FOLLOWING section labels.
struct FeedInterstitialHeader: View {
    let icon: String
    let title: String
    /// Optional: "Selected for you" carries the covers alone, no explainer.
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1)
            }
            .foregroundStyle(Theme.chrome)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .accessibilityElement(children: .combine)
    }
}

/// Same receipt hairline the posts draw under themselves.
struct FeedInterstitialDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.chrome.opacity(0.25))
            .frame(height: Theme.chromeHairline)
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.top, 4)
    }
}
