//
//  SearchView.swift
//  WellRead
//
//  The Search tab: one field over the book catalog or the SPINE roster. Books and
//  members open as ordinary pushes on the tab's own stack, with a back button.
//

import SwiftUI

/// Local-only recent activity for search (per signed-in uid, capped,
/// never synced): submitted queries and book profiles the user opened.
enum SearchRecents {
    private static let queryCap = 3
    private static let bookCap = 12
    private static func queriesKey(_ uid: String) -> String { "searchRecentQueries.\(uid)" }
    private static func booksKey(_ uid: String) -> String { "searchRecentBooks.\(uid)" }

    static func queries(uid: String) -> [String] {
        Array((UserDefaults.standard.stringArray(forKey: queriesKey(uid)) ?? []).prefix(queryCap))
    }

    static func addQuery(_ q: String, uid: String) {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var list = queries(uid: uid).filter { $0.caseInsensitiveCompare(t) != .orderedSame }
        list.insert(t, at: 0)
        UserDefaults.standard.set(Array(list.prefix(queryCap)), forKey: queriesKey(uid))
    }

    static func books(uid: String) -> [Book] {
        guard let data = UserDefaults.standard.data(forKey: booksKey(uid)),
              let list = try? JSONDecoder().decode([Book].self, from: data) else { return [] }
        return list
    }

    static func addBook(_ b: Book, uid: String) {
        var list = books(uid: uid).filter { $0.id != b.id }
        list.insert(b, at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(bookCap))) {
            UserDefaults.standard.set(data, forKey: booksKey(uid))
        }
    }
}

/// "Read by people you follow" shelf, persisted per uid for a day. The tab's view
/// is destroyed whenever the user leaves the Search tab, so without this the whole
/// shelf (a `userBooks` query across everyone you follow, then cover hydration)
/// re-ran on every visit.
enum FollowedReadsCache {
    /// How long a saved shelf is served before it's rebuilt.
    private static let maxAge: TimeInterval = 24 * 60 * 60

    struct Saved: Codable {
        /// The shuffled pool of book ids, in the order they should hydrate.
        var pool: [String]
        /// Covers already hydrated, so the shelf draws without a round trip.
        var books: [Book]
        /// Offset into `pool` of the next unhydrated id.
        var nextIndex: Int
        var savedAt: Date
    }

    private static func key(_ uid: String) -> String { "followedReadShelf.\(uid)" }

    /// The saved shelf, or nil if there is none or it's older than `maxAge`.
    static func load(uid: String) -> Saved? {
        guard let data = UserDefaults.standard.data(forKey: key(uid)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              Date().timeIntervalSince(saved.savedAt) < maxAge else { return nil }
        return saved
    }

    static func save(pool: [String], books: [Book], nextIndex: Int, uid: String) {
        let saved = Saved(pool: pool, books: books, nextIndex: nextIndex, savedAt: Date())
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: key(uid))
    }
}

/// Identifiable wrapper so a Firebase uid can drive `navigationDestination(item:)`.
private struct SearchedUserSelection: Identifiable, Hashable {
    let id: String
}

/// A member row in the "Users" search scope (Firebase uid + profile).
private struct SearchedReader: Identifiable {
    let id: String
    let user: User
}

struct SearchView: View {
    /// What the search field is querying: the book catalog or SPINE members.
    enum SearchScope {
        case books
        case users
    }

    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appState: AppState
    /// Height the floating tab bar overlaps content by; scrolling content pads
    /// past it so the last rows never sit under the bar with the keyboard down.
    @Environment(\.mainTabBarOverlapExtraHeight) private var mainTabBarOverlapExtraHeight
    /// Starts true so the field is focused in the very first frame. Flipping it in
    /// `onAppear` instead would land the Cancel button and the keyboard mid-appearance,
    /// animating the header row into place after the page had already drawn.
    @State private var isSearchFocused = true
    @State private var query = ""
    /// Always starts on books; the segment under the field flips it to members.
    @State private var scope: SearchScope = .books
    /// All member profiles, fetched once per visit and filtered locally.
    @State private var readers: [SearchedReader] = []
    @State private var isLoadingReaders = false
    @State private var hasLoadedReaders = false
    @State private var selectedUser: SearchedUserSelection?
    @State private var results: [Book] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    /// True after the user taps "show all results" — search re-runs without the junk filter and edition dedup.
    @State private var showingAllEditions = false
    @State private var searchError: String?
    /// Set when the last word of the query was half-typed and search completed it
    /// (see `SearchQueryCompletion`): drives the "Showing results for…" banner.
    @State private var completedQuery: String?
    /// The exact text the user asked to be searched literally, via the banner's
    /// "Search instead for" escape hatch. Suppresses completion for that query only.
    @State private var literalQuery: String?
    @State private var selectedBookForProfile: Book?
    @State private var searchTask: Task<Void, Never>?
    /// Recent search activity shown while the field is empty.
    @State private var recentQueries: [String] = []
    /// "Read by people you follow": a shuffled pool of finished-book ids from the
    /// follow graph, hydrated into `followedReadBooks` a few covers at a time as
    /// the shelf is scrolled.
    @State private var followedReadPool: [String] = []
    @State private var followedReadBooks: [Book] = []
    /// Offset into `followedReadPool` of the next unhydrated id (tracked separately
    /// from `followedReadBooks.count` because an id can fail to hydrate).
    @State private var followedReadNextIndex = 0
    @State private var hasLoadedFollowedReads = false
    @State private var isLoadingMoreFollowedReads = false
    /// True while the pool + first batch of covers are being fetched, so the shelf
    /// shows its skeleton instead of popping in from nothing.
    @State private var isLoadingFollowedReads = false
    /// Full-bleed width of the followed-reads shelf, for sizing covers so a
    /// partial cover always peeks past the trailing edge.
    @State private var followedShelfWidth: CGFloat = 0
    private static let followedReadBatchSize = 4
    private static let followedReadPoolCap = 24
    /// When set (opened from a queue shelf's "Add" tile), book profiles show a primary
    /// CTA that adds the book straight onto this shelf.
    var targetShelf: QueueShelf? = nil
    /// Set when the page is presented modally (the shelf "Add" tile) rather than as
    /// the Search tab: adds a Cancel button and closes after an add.
    var onClose: (() -> Void)? = nil

    /// UIKit equivalent of `Theme.body()` (SF Pro, size 17) for the search field.
    private static var searchFieldUIFont: UIFont {
        UIFont.systemFont(ofSize: 17, weight: .regular)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    searchHeader
                    searchStep
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                if onClose != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { close() }
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .navigationDestination(item: $selectedBookForProfile) { book in
                BookProfileView(
                    book: book,
                    readBooksForSimilar: appState.readBooks,
                    onNotInterested: nil,
                    // Adding to the queue lands the user on their queue (with the success
                    // toast), so the search stack goes back to its root behind them.
                    onWantToRead: { appState.addToWantToRead(book: book); appState.openQueue(); finishAfterAction() },
                    // Suppress READING when the shelf CTA above is already "+ READING NOW".
                    onStartReading: targetShelf == .readingNow ? nil : {
                        appState.addToQueue(book: book, shelf: .readingNow); appState.openQueue(); finishAfterAction()
                    },
                    // Marking read fires the tier-highlight flow (switches to Profile → Read and
                    // scrolls to the book), so again: back to the root behind them.
                    onConfirmRead: { date, rating, post, caption, tier in appState.addAsRead(book: book, dateFinished: date, rating: rating, postToFeed: post, caption: caption, tier: tier); finishAfterAction() },
                    isOnReadList: appState.isBookOnReadList(bookId: book.id),
                    isInQueue: appState.isBookInQueue(bookId: book.id),
                    onRemoveFromQueue: { appState.removeFromQueue(book: book); selectedBookForProfile = nil },
                    readEntryForReview: appState.userReadBook(forBookId: book.id),
                    canEditReadReview: true,
                    shelfActionTitle: targetShelf.map(Self.shelfCTATitle),
                    onAddToShelf: targetShelf.map { shelf in
                        { appState.addToQueue(book: book, shelf: shelf); appState.openQueue(); finishAfterAction() }
                    }
                )
            }
            .navigationDestination(item: $selectedUser) { selection in
                UserLibraryDetailView(userId: selection.id)
            }
            .onReceive(NotificationCenter.default.publisher(for: .spineSearchTabTappedAgain)) { _ in
                // Re-tap on the Search tab item: pop any pushed book/user profile
                // back to the search root. Only the tab instance responds; modal
                // copies (shelf "Add" tiles) have `onClose` set.
                guard onClose == nil else { return }
                selectedBookForProfile = nil
                selectedUser = nil
            }
        }
    }

    /// Closes the page when it was presented modally; a no-op on the Search tab.
    private func close() {
        // Resign the keyboard in the same frame the page starts closing — left to
        // itself it only drops once the field leaves the view hierarchy.
        isSearchFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        onClose?()
    }

    /// After an action that sends the user somewhere else (their queue, their tier
    /// list): unwind the search stack, and close the page if it was presented modally.
    private func finishAfterAction() {
        selectedBookForProfile = nil
        onClose?()
    }

    /// Banner at the top of the Search tab (matches Discover).
    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SEARCH")
                .font(.system(size: 22, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.textPrimary)
            BrandRule(width: 48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private static func shelfCTATitle(_ shelf: QueueShelf) -> String {
        switch shelf {
        case .readingNow: return "+ READING NOW"
        case .upNext: return "+ UP NEXT"
        case .backlog: return "+ BACKLOG"
        }
    }

    private var searchStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.textSecondary)
                    NoSuggestionsTextField(
                        text: $query,
                        isFocused: $isSearchFocused,
                        placeholder: scope == .books ? "Search by title or author" : "Search by name or username",
                        font: Self.searchFieldUIFont,
                        textColor: UIColor(Theme.textPrimary),
                        placeholderColor: UIColor(Theme.textTertiary),
                        onSubmit: {
                            if scope == .books {
                                runSearch()
                            } else {
                                isSearchFocused = false
                            }
                        }
                    )
                        .frame(height: 24)
                        .onChange(of: query) { _, newValue in
                            // Member search filters the already-fetched roster locally.
                            guard scope == .books else { return }
                            scheduleSearch(for: newValue)
                        }
                    if !query.isEmpty {
                        Button {
                            query = ""
                            isSearchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .accessibilityLabel("Clear search")
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: query.isEmpty)
                .padding()
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))

                // Only while the field is up — its whole job is dropping the keyboard.
                if isSearchFocused {
                    Button("Cancel") { isSearchFocused = false }
                        .font(Theme.callout())
                        .foregroundStyle(Theme.accent)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isSearchFocused)
            .padding(.horizontal)

            SearchScopeSegmentControl(scope: $scope)
                .padding(.horizontal)

            if scope == .users {
                usersStep
            } else {
                booksResults
            }
        }
        .padding(.top, 12)
        // Focus is not restored here: popping back from a book or member page
        // shouldn't shove the keyboard over the results the user came back to.
        .onAppear {
            refreshRecents()
            Task { await loadFollowedReadsIfNeeded() }
        }
        .onChange(of: scope) { _, newScope in
            searchTask?.cancel()
            if newScope == .users {
                Task { await loadReadersIfNeeded() }
            } else {
                // Coming back to books: re-run whatever is in the field.
                scheduleSearch(for: query)
            }
        }
    }

    /// Results, errors, and recents for the books scope.
    @ViewBuilder
    private var booksResults: some View {
        Group {
            if isSearching {
                VStack(spacing: 14) {
                    SpinningSpineLogo(size: 72)
                    Text("Searching…").font(Theme.callout()).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            }

            if let err = searchError {
                VStack(spacing: 12) {
                    Text(err)
                        .font(Theme.callout())
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { runSearch() }
                        .font(Theme.callout())
                        .foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else if hasSearched && !isSearching && results.isEmpty {
                VStack(spacing: 12) {
                    Text("No results. Try different keywords.")
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textSecondary)
                    if !showingAllEditions {
                        Button("Show all results") { showAllEditions() }
                            .font(Theme.callout())
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
            }

            ScrollView {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    recentsSection
                        .padding()
                        .padding(.bottom, mainTabBarOverlapExtraHeight + 12)
                } else {
                    LazyVStack(spacing: 12) {
                        if let completed = completedQuery, !isSearching {
                            completionBanner(completed)
                        }
                        ForEach(results) { book in
                            BookSearchRow(book: book) {
                                openBookProfile(book)
                            }
                        }
                        if hasSearched && !isSearching && !results.isEmpty && !showingAllEditions {
                            VStack(spacing: 4) {
                                Text("Can't find what you're looking for?")
                                    .font(Theme.caption())
                                    .foregroundStyle(Theme.textSecondary)
                                Button("Show all results") { showAllEditions() }
                                    .font(Theme.callout())
                                    .foregroundStyle(Theme.accent)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                        }
                    }
                    .padding()
                    .padding(.bottom, mainTabBarOverlapExtraHeight + 12)
                }
            }
        }
    }

    // MARK: - Users scope

    /// Roster results for the "Users" scope: everyone when the field is empty,
    /// name/handle matches once the user types.
    @ViewBuilder
    private var usersStep: some View {
        Group {
            if isLoadingReaders {
                VStack(spacing: 14) {
                    SpinningSpineLogo(size: 72)
                    Text("Loading readers…").font(Theme.callout()).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                Spacer(minLength: 0)
            } else if filteredReaders.isEmpty {
                Text(hasLoadedReaders && !readers.isEmpty
                     ? "No members match \u{201C}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}."
                     : "No other members yet.")
                    .font(Theme.callout())
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding()
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredReaders) { reader in
                            Button {
                                isSearchFocused = false
                                selectedUser = SearchedUserSelection(id: reader.id)
                            } label: {
                                readerRow(reader.user)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                    .padding(.bottom, mainTabBarOverlapExtraHeight + 12)
                }
            }
        }
    }

    private func readerRow(_ user: User) -> some View {
        HStack(spacing: 12) {
            UserAvatarView(
                urlString: user.profileImageURL,
                displayName: user.displayName,
                firstName: user.firstName,
                lastName: user.lastName,
                size: 40
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !user.username.isEmpty {
                    Text("@\(user.username)")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding()
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }

    /// Name matches first, handle matches after (see `PersonSearch`).
    private var filteredReaders: [SearchedReader] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return readers }
        return PersonSearch.ranked(readers, query: trimmed, user: { $0.user })
    }

    /// Fetches the member roster once per visit; filtering is local from there.
    private func loadReadersIfNeeded() async {
        guard !hasLoadedReaders, !isLoadingReaders else { return }
        isLoadingReaders = true
        let rows = await UserRepository().fetchAllReaderProfiles(excludingUid: appState.authUserId, limit: 500)
        await MainActor.run {
            readers = rows.map { SearchedReader(id: $0.uid, user: $0.user) }
            hasLoadedReaders = true
            isLoadingReaders = false
        }
    }

    // MARK: - Recents

    private var recentsUid: String {
        authService.firebaseUser?.uid ?? "anon"
    }

    private func refreshRecents() {
        recentQueries = SearchRecents.queries(uid: recentsUid)
    }

    // MARK: - Read by people you follow

    /// Three full covers plus half of a fourth peeking past the trailing edge.
    private var followedReadCoverSize: CGFloat {
        guard followedShelfWidth > 0 else { return 92 }
        return (followedShelfWidth - 16 - 3 * 12) / 3.5
    }

    /// One cover-shaped shimmer at the shelf's cover metrics: stands in for both the
    /// first batch (while the pool loads) and the next batch as the shelf is scrolled.
    private var followedReadCoverSkeleton: some View {
        ShimmerShape(shape: RoundedRectangle(cornerRadius: min(6, followedReadCoverSize * 0.12)))
            .frame(width: followedReadCoverSize, height: followedReadCoverSize * 1.5)
    }

    /// Builds the shuffled pool of finished-book ids from the follow graph (books
    /// already in the user's own library excluded) and hydrates the first batch.
    /// A shelf built within the last day is restored from `FollowedReadsCache`
    /// instead: the Search tab's view is thrown away every time the user leaves
    /// the tab, so rebuilding on appear meant re-querying the whole follow graph
    /// on every visit — and reshuffling the covers along with it.
    private func loadFollowedReadsIfNeeded() async {
        guard !hasLoadedFollowedReads else { return }
        hasLoadedFollowedReads = true
        if let saved = FollowedReadsCache.load(uid: recentsUid) {
            // Books added to the user's own library since the shelf was saved are
            // dropped here rather than at save time: the library changes far more
            // often than the pool does.
            let ownBookIds = Set(appState.userBooks.map(\.bookId))
            await MainActor.run {
                followedReadPool = saved.pool.filter { !ownBookIds.contains($0) }
                followedReadBooks = saved.books.filter { !ownBookIds.contains($0.id) }
                followedReadNextIndex = min(saved.nextIndex, followedReadPool.count)
            }
            return
        }
        let following = authService.appUser?.following ?? []
        guard !following.isEmpty else { return }
        await MainActor.run { isLoadingFollowedReads = true }
        let ids = await UserBookRepository().fetchReadBookIds(forUserIds: following)
        let ownBookIds = Set(appState.userBooks.map(\.bookId))
        let pool = Array(ids.filter { !ownBookIds.contains($0) }.shuffled().prefix(Self.followedReadPoolCap))
        await MainActor.run { followedReadPool = pool }
        await loadMoreFollowedReads()
        await MainActor.run { isLoadingFollowedReads = false }
    }

    /// Hydrates the next batch of covers; the shelf's trailing placeholder calls
    /// this when scrolled into view.
    private func loadMoreFollowedReads() async {
        guard followedReadNextIndex < followedReadPool.count, !isLoadingMoreFollowedReads else { return }
        isLoadingMoreFollowedReads = true
        let nextIds = Array(followedReadPool[followedReadNextIndex..<min(followedReadNextIndex + Self.followedReadBatchSize, followedReadPool.count)])
        let books = await BookRepository.shared.getBooks(ids: nextIds)
        await MainActor.run {
            followedReadNextIndex += nextIds.count
            followedReadBooks.append(contentsOf: nextIds.compactMap { books[$0] })
            isLoadingMoreFollowedReads = false
            // Saved on every batch, so covers the user scrolled to are still there
            // when they come back to the tab.
            FollowedReadsCache.save(pool: followedReadPool, books: followedReadBooks, nextIndex: followedReadNextIndex, uid: recentsUid)
        }
    }

    /// Opens a book profile from search results or recents, recording both the book
    /// and the query that surfaced it.
    private func openBookProfile(_ book: Book) {
        SearchRecents.addBook(book, uid: recentsUid)
        SearchRecents.addQuery(query, uid: recentsUid)
        refreshRecents()
        isSearchFocused = false
        selectedBookForProfile = book
    }

    /// Shown while the search field is empty: past queries and books finished by
    /// people the user follows.
    @ViewBuilder
    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !recentQueries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent searches")
                        .font(Theme.headline())
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.bottom, 4)
                    ForEach(recentQueries, id: \.self) { q in
                        Button {
                            query = q
                            runSearch()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.textTertiary)
                                Text(q)
                                    .font(Theme.callout())
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.left")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if isLoadingFollowedReads || !followedReadBooks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Read by people you follow")
                        .font(Theme.headline())
                        .foregroundStyle(Theme.textSecondary)
                    // Full-bleed so covers slide under the screen edge, with cover
                    // width computed from the shelf width so a partial fourth cover
                    // always peeks past the trailing edge — the cut-off itself is
                    // the "scroll for more" affordance.
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            if followedReadBooks.isEmpty {
                                // Skeleton at the loaded shelf's exact footprint, so
                                // nothing below shifts when the covers land.
                                ForEach(0..<4, id: \.self) { _ in followedReadCoverSkeleton }
                            } else {
                                ForEach(followedReadBooks) { b in
                                    BookCoverView(book: b, size: followedReadCoverSize, onTap: { openBookProfile(b) })
                                }
                                if followedReadNextIndex < followedReadPool.count {
                                    followedReadCoverSkeleton
                                        .onAppear { Task { await loadMoreFollowedReads() } }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.horizontal, -16)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { followedShelfWidth = $0 }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: followedReadBooks.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: isLoadingFollowedReads)
    }

    /// "Showing results for <completed query>" — search finished a half-typed
    /// last word (see `SearchQueryCompletion`). The escape hatch below it re-runs
    /// the text as typed, so the completion is never a dead end.
    private func completionBanner(_ completed: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Showing results for \u{201C}\(completed)\u{201D}")
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
            Button("Search instead for \u{201C}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}") {
                searchLiterally()
            }
            .font(Theme.caption())
            .foregroundStyle(Theme.accent)
            .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    /// Re-runs the current text with completion suppressed.
    private func searchLiterally() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        literalQuery = trimmed
        completedQuery = nil
        searchTask?.cancel()
        searchTask = Task { await performSearch(trimmed) }
    }

    /// Debounces keystrokes so results populate automatically as the user types,
    /// without firing a request on every character.
    private func scheduleSearch(for value: String) {
        searchTask?.cancel()
        // A new query goes back to curated results; "every edition" is per-search,
        // and so is any last-word completion or the opt-out from one.
        showingAllEditions = false
        completedQuery = nil
        literalQuery = nil
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // 1–2 characters can't identify a book and every fired search costs paid
        // API requests on a cache miss, so type-as-you-go waits for 3+. Explicit
        // submit (runSearch) stays ungated for short real titles like "It".
        guard trimmed.count >= 3 else {
            // Clear stale results when the field is emptied or shortened.
            results = []
            hasSearched = false
            searchError = nil
            isSearching = false
            return
        }
        searchTask = Task {
            // 500ms of keyboard silence before firing: long enough to skip most
            // mid-word hesitations (each fired search costs paid API requests on
            // a cache miss), short enough to feel instant once typing stops.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(trimmed)
        }
    }

    private func runSearch() {
        isSearchFocused = false
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        SearchRecents.addQuery(trimmed, uid: recentsUid)
        refreshRecents()
        searchTask = Task { await performSearch(trimmed) }
    }

    /// Re-runs the current search with the junk filter and edition dedup off.
    private func showAllEditions() {
        showingAllEditions = true
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask = Task { await performSearch(trimmed) }
    }

    private func performSearch(_ trimmed: String) async {
        // Authors already in the library get a small ranking boost.
        let libraryAuthors = Set(appState.userBooks.compactMap { $0.book?.author })
        let includeAll = showingAllEditions
        await MainActor.run {
            isSearching = true
            searchError = nil
        }
        // The query exactly as typed, shown as soon as it lands.
        var books: [Book] = []
        do {
            books = try await GoogleBooksService.shared.search(
                query: trimmed,
                includeAllEditions: includeAll,
                libraryAuthors: libraryAuthors
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                results = books
                completedQuery = nil
                hasSearched = true
                isSearching = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                results = []
                hasSearched = true
                isSearching = false
                completedQuery = nil
                searchError = error.localizedDescription.isEmpty ? "Search failed. Check your connection and try again." : error.localizedDescription
            }
        }
        // Nothing above waited on the last-word repair: the literal outcome is
        // on screen, and if finishing a half-typed word turns up something
        // better a moment later, it replaces that. Runs after a failure too —
        // a query the providers choke on is often exactly the half-typed one.
        // The banner's "search instead for" pins one query as literal and skips
        // this entirely.
        guard literalQuery?.caseInsensitiveCompare(trimmed) != .orderedSame else { return }
        guard let completion = try? await GoogleBooksService.shared.completedSearch(
            for: trimmed,
            literalResults: books,
            includeAllEditions: includeAll,
            libraryAuthors: libraryAuthors
        ) else { return }
        guard !Task.isCancelled else { return }
        await MainActor.run {
            // The field can have moved on while the probe ran, and a book the
            // user already tapped shouldn't shuffle behind them.
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed,
                  selectedBookForProfile == nil else { return }
            results = completion.books
            completedQuery = completion.query
            searchError = nil
        }
    }
}

/// Books | Users selector under the search field. Same sliding-lens language as
/// the library's Read/Queue control, but deliberately small: it's a scope hint
/// under the field, not a primary control, so it stays narrow and short.
private struct SearchScopeSegmentControl: View {
    @Binding var scope: SearchView.SearchScope

    /// Keeps the control off the full width of the search field above it.
    private static let width: CGFloat = 168
    private static let lensCornerRadius: CGFloat = 7

    var body: some View {
        HStack(spacing: 0) {
            pill("Books", value: .books)
            pill("Users", value: .users)
        }
        .padding(2)
        .background {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9).fill(Theme.surface)
                GeometryReader { geo in
                    let half = geo.size.width / 2
                    LibrarySegmentGlassLens(cornerRadius: Self.lensCornerRadius)
                        .frame(width: max(0, half - 4))
                        .offset(x: 2 + (scope == .books ? 0 : half))
                        .animation(LibrarySegmentControlAnimation.selection, value: scope)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: Self.width)
        .sensoryFeedback(.selection, trigger: scope)
    }

    private func pill(_ title: String, value: SearchView.SearchScope) -> some View {
        let isSelected = scope == value
        return Button {
            scope = value
        } label: {
            Text(title)
                .font(Theme.caption().weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: Self.lensCornerRadius))
    }
}
