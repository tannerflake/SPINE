//
//  FeedInterstitials.swift
//  Spine
//
//  Two pseudo posts per feed load, three items down and six below that
//  (one time in five they trade places). "Selected for you" is three covers
//  lifted straight out of the Discover pipeline (the card plus its prefetched
//  queue), plus a "Discover more" tile into Discover.
//  Showing a book here never consumes or dismisses it, so a pick scrolled past
//  by accident is still waiting on the Discover card. "Readers to follow" is
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

        /// The two rows in draw order. Readers lead one load in five.
        static func randomOrder() -> [Kind] {
            Double.random(in: 0..<1) < 0.2 ? [.people, .books] : [.books, .people]
        }
    }

    static let itemsPerSlot = 3

    /// Readers X'd out this session (merged with the persisted list on the
    /// user doc). Published so the card leaves the row the moment it's tapped.
    @Published private(set) var dismissedUids: Set<String> = []
    /// Uids with a follow write in flight (debounces the Follow button).
    @Published private(set) var followInFlight: Set<String> = []
    /// Bumped when a reload re-picks the rows, so the feed rebuilds them.
    @Published private(set) var generation = 0

    /// Which pseudo post leads this load. The picks row goes first four times
    /// in five. Re-rolled on reload, never mid-scroll.
    private var kindOrder: [Kind] = Kind.randomOrder()
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
    /// reader has already seen, and a fresh coin flip on the order. A refresh
    /// from above the rows leaves them exactly as they were, so recommendations
    /// the reader never laid eyes on aren't spent.
    func handleFeedReload() {
        guard !seenSlots.isEmpty else { return }
        for slot in seenSlots {
            bookSlots[slot] = nil
            peopleSlots[slot] = nil
        }
        seenSlots = []
        kindOrder = Kind.randomOrder()
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
        kindOrder = Kind.randomOrder()
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
    private var coverWidth: CGFloat {
        let cells = CGFloat(max(books.count + 1, 1))
        let available = UIScreen.main.bounds.width
            - Theme.horizontalPadding * 2
            - Self.cellSpacing * (cells - 1)
        return min((available / cells).rounded(.down), Self.maxCoverWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FeedInterstitialHeader(icon: "sparkles", title: "SELECTED FOR YOU")
            HStack(alignment: .top, spacing: Self.cellSpacing) {
                ForEach(books) { book in
                    bookCell(book)
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

// MARK: - Readers to follow

/// Three not-yet-followed readers as cards: avatar, name, book count, Follow.
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
        let booksRead = reader.user.totalBooksRead
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
                    VStack(spacing: 2) {
                        Text(reader.user.displayName)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Text(booksRead == 1 ? "1 book" : "\(booksRead) books")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(Theme.textTertiary)
                    }
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
