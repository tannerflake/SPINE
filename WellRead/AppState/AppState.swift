//
//  AppState.swift
//  WellRead
//
//  Global app state: auth, current user, userBooks and feed from Firestore. Library cached on disk for instant load.
//

import SwiftUI
import Combine
import FirebaseFirestore

/// Whose posts the feed shows: everyone on Spine (default) or people you follow.
enum FeedScope: String {
    case friends
    case everyone
}

final class AppState: ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var currentUser: User?
    @Published var userBooks: [UserBook] = []
    @Published var feedPosts: [Post] = []
    /// True until the feed listener delivers its first complete, server-confirmed
    /// merge — the Feed tab shows the brand spinner instead of a partial feed.
    @Published var isFeedLoading = true
    /// Feed scope toggle (friends vs everyone). Defaults to everyone; persisted
    /// per account once the user switches. Set via `setFeedScope`.
    @Published private(set) var feedScope: FeedScope = .everyone
    /// True while a deeper page of feed posts is loading (footer spinner).
    @Published private(set) var isLoadingMoreFeedPosts = false
    /// Whether Firestore still has older posts past what's loaded. Starts false so
    /// nothing pages until the listener has reported on a full first page.
    @Published private(set) var canLoadMoreFeedPosts = false

    /// How deep the feed listener currently reads. Grows a page at a time as the
    /// reader hits the bottom; resets on a new account or a scope switch.
    private var feedLimit = feedPageSize

    /// Per-account key: a new sign-in on a device must start on Everyone rather
    /// than inheriting the previous account's choice.
    private static func feedScopeDefaultsKey(uid: String) -> String { "feedScope.\(uid)" }
    @Published var dismissedBookIds: Set<String> = []
    @Published var discoverCurrentSuggestion: Book?
    @Published var discoverSuggestionQueue: [Book] = []
    /// Books passed on in Discover this session, newest last. Session-only (never
    /// persisted): it backs the undo button in the Discover header, which is why
    /// a fresh launch offers nothing to go back to.
    @Published var discoverPassedBooks: [Book] = []
    @Published var isLoadingDiscoverSuggestions = false
    /// True when a user-visible discover fetch finished with nothing to show, so the
    /// empty state can say "try again" instead of silently resetting to the intro.
    @Published var discoverLoadCameUpEmpty = false
    @Published var likedPostIds: Set<String> = []
    /// Set when app is opened from Share Extension with a Goodreads CSV; LibraryView shows import sheet and clears this.
    @Published var pendingGoodreadsImportRows: [GoodreadsRow]? = nil
    /// Set when Share Extension opened the app but couldn't get CSV (e.g. user shared page URL); show alert and clear.
    @Published var pendingGoodreadsImportError: String? = nil
    /// Set when Share Extension passed a URL; app downloads in foreground then sets rows or error and clears this.
    @Published var pendingGoodreadsImportURL: URL? = nil
    @Published var isFetchingGoodreadsFromURL = false
    /// Set when the app is opened from the Share Extension with a non-Goodreads
    /// link or text; MainTabView presents the link → queue wizard and clears this.
    @Published var pendingLinkImport: LinkImportPayload? = nil
    /// Set when opening a feed post from a push or `wellread://` URL; Feed opens comments when resolved.
    @Published var deepLinkFeedPostId: String?
    /// Set alongside `deepLinkFeedPostId` for comment-targeted pushes (liked, replied, mentioned, commented); the comments sheet scrolls to and flashes this comment.
    @Published var deepLinkFeedCommentId: String?
    /// True while the Discover tab was reached from the feed's "Discover more"
    /// tile: Discover draws a back arrow and accepts a left-edge swipe home.
    /// Any other way into Discover (tab bar, push, deep link) clears it.
    @Published var discoverEnteredFromFeed = false
    /// One-shot scroll offset for FeedView to restore on its next appearance
    /// (the tab switch tears the feed's scroll view down). Feed clears it.
    @Published var feedScrollRestoreOffsetY: CGFloat?
    /// Where the feed is scrolled right now. Deliberately not `@Published` —
    /// it updates on every scroll frame and nothing should redraw for it.
    var feedScrollOffsetY: CGFloat = 0
    /// `Book.id` of a freshly-reviewed book the tier list should pulse-glow until the user tiers it. Cleared automatically once the corresponding `UserBook.tier` becomes non-nil.
    @Published var pendingTierHighlightBookId: String?
    /// One-shot companion to `pendingTierHighlightBookId`: the tier list may auto-scroll
    /// to the highlighted book only while this is true (right after the review that set
    /// it). The highlight itself lingers until the book is tiered, and TierListView's
    /// onAppear re-fires on every back-navigation and tab switch — without this gate,
    /// each of those yanked the list back to the Unranked row.
    @Published var tierHighlightScrollPending = false
    /// True while the viewer is looking at their *own* tier list with at least
    /// one ranked book in it. MainTabView watches this to decide when to ask for
    /// an App Store rating: a tier list the user has actually filled in is the
    /// one moment we know they've gotten something out of the app.
    @Published var isViewingOwnRankedTierList = false
    /// Pending books friends sent me (Recommended shelf on the queue), newest first.
    @Published var incomingRecommendations: [BookRecommendation] = []
    /// Sender profiles for incoming recommendations, keyed by Firebase UID ("from {name}" labels).
    @Published var recommenderProfiles: [String: User] = [:]
    /// Unread rows exist in `users/{uid}/notifications` — drives the bell's badge
    /// dot on both the Feed and Profile tab bells. Shared here (rather than local
    /// `@State` per screen) so the two bells never disagree about read state.
    /// Refreshed via `refreshUnreadNotifications()`, cleared via `markNotificationsRead()`.
    @Published var hasUnreadNotifications = false

    /// True only after we've loaded dismissed book IDs from Firestore, so discover suggestions exclude them from the first fetch.
    private var dismissedBookIdsLoaded = false
    /// True once the library is known (disk cache or first Firestore snapshot).
    /// Discover must not fetch before this: with an empty `userBooks` there is
    /// nothing to exclude against, so already-read books sail through.
    private var userBooksLoaded = false

    private static let libraryCacheSaveQueue = DispatchQueue(label: "com.wellread.library-cache-save", qos: .utility)

    private let userBookRepo = UserBookRepository()
    private let postRepo = PostRepository()
    private let dismissedRepo = DismissedSuggestionsRepository()
    private let userRepo = UserRepository()
    private let recommendationRepo = RecommendationRepository()
    private let notificationsRepo = NotificationsRepository()
    private var userBooksListener: ListenerRegistration?
    private var feedListener: FeedListenerHandle?
    private var recommendationsListener: ListenerRegistration?
    private var currentUserId: String?
    /// Uids the signed-in user follows, kept for feed-listener restarts on scope switches.
    private var currentFollowing: [String] = []

    /// Firebase Auth uid for the current user (use for Firestore writes).
    var authUserId: String? { currentUserId }

    #if DEBUG
    /// `-uiPreview` runs only: gives the demo session a uid so write paths
    /// (addToQueue, setQueueShelfAndOrder, …) mutate local state instead of
    /// silently bailing on the `currentUserId` guard. No listeners run, and the
    /// fire-and-forget repo writes fail harmlessly against the fake uid.
    func seedPreviewAuth(uid: String) { currentUserId = uid }
    #endif

    init() {}

    /// Call when user signs in (with their Firebase uid and the uids they follow).
    /// Loads cached library first for instant UI, then starts Firestore listener.
    /// RootView re-calls this whenever `appUser` changes (including after follow/
    /// unfollow via `refreshAppUser`), which restarts the feed with the new graph.
    func startFirestoreListeners(uid: String, following: [String]) {
        stopFirestoreListeners()
        // Spinner only when there's nothing to show — a listener restart from a
        // follow/unfollow keeps the current posts up while the new feed loads.
        if uid != currentUserId || feedPosts.isEmpty {
            isFeedLoading = true
        }
        if uid != currentUserId {
            let saved = UserDefaults.standard.string(forKey: Self.feedScopeDefaultsKey(uid: uid)) ?? ""
            feedScope = FeedScope(rawValue: saved) ?? .everyone
            // A follow/unfollow restart keeps the reader's paging depth; only a
            // different account starts back at page one.
            feedLimit = feedPageSize
        }
        currentUserId = uid
        currentFollowing = following
        dismissedBookIdsLoaded = false
        userBooksLoaded = false
        refreshGoodreadsWizardResumeState()
        refreshLinkImportResumeState()

        // Load from disk first so the user sees their library immediately.
        if let cached = LocalLibraryCache.shared.loadLibrary(userId: uid), !cached.isEmpty {
            userBooks = cached
            userBooksLoaded = true
            BookRepository.shared.prewarmCache(with: cached.compactMap(\.book))
        }

        Task { @MainActor [weak self] in
            await self?.refreshLibraryBookMetadataIfStale(uid: uid)
        }

        userBooksListener = userBookRepo.listenUserBooks(userId: uid) { [weak self] list in
            guard let self = self else { return }
            self.userBooks = list
            Task { @MainActor in
                self.userBooksLoaded = true
                self.dropExcludedFromDiscoverQueue()
                self.loadDiscoverSuggestionsIfNeeded()
                self.clearTierHighlightIfTiered()
                self.applyPendingQueueNotes()
                WidgetDataService.shared.scheduleRefresh(appState: self)
            }
            if let uid = self.currentUserId {
                let copy = list
                // Serial queue: concurrent saves could land out of order and persist a stale library.
                Self.libraryCacheSaveQueue.async {
                    LocalLibraryCache.shared.saveLibrary(copy, userId: uid)
                }
            }
        }
        feedListener = makeFeedListener(uid: uid)
        recommendationsListener = recommendationRepo.listenIncoming(userId: uid) { [weak self] list in
            guard let self = self else { return }
            self.incomingRecommendations = list
            self.loadRecommenderProfilesIfNeeded(for: list)
        }

        Task { [weak self] in
            guard let self = self, let uid = self.currentUserId else { return }
            let ids = await self.dismissedRepo.fetchDismissedBookIds(userId: uid)
            await MainActor.run {
                self.dismissedBookIds = Set(ids)
                self.dismissedBookIdsLoaded = true
                self.loadDiscoverSuggestionsIfNeeded()
            }
        }
        Task { [weak self] in
            guard let self = self, let uid = self.currentUserId else { return }
            let liked = await self.postRepo.fetchLikedPostIds(userId: uid)
            await MainActor.run { self.likedPostIds = liked }
        }
    }

    private static let libraryBookFullRefreshInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Keeps the locally-cached library's book METADATA honest without ever
    /// re-reading the whole library regularly. The library stays local-first:
    /// cover images are never touched here, and book docs are re-fetched only when
    /// there's a reason to believe they changed.
    ///
    /// Two tiers:
    /// 1. Per launch: one tiny query against `coverRegenerations` — "did anyone
    ///    fix a cover since I last checked?" Almost always empty; when it isn't,
    ///    only the affected library books are re-fetched.
    /// 2. Weekly: one full metadata revalidation (book docs only, batched 30 per
    ///    query). Needed because the launch path prewarms BookRepository from the
    ///    disk cache and the listener hydrates from that same cache, so dedup
    ///    merges and metadata fixes would otherwise never reach existing holders.
    @MainActor
    private func refreshLibraryBookMetadataIfStale(uid: String) async {
        // Give the disk-cache load / first listener delivery a moment to land so
        // there are book ids to work with (first-ever launch fetches fresh anyway).
        var waited = 0
        while !userBooksLoaded && waited < 20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 1
        }
        guard uid == currentUserId else { return }
        let libraryIds = Set(userBooks.map(\.bookId))
        guard !libraryIds.isEmpty else { return }

        let defaults = UserDefaults.standard
        let fullKey = "libraryBookMetadataRefreshedAt_\(uid)"
        let deltaKey = "coverEditsCheckedAt_\(uid)"
        let now = Date().timeIntervalSince1970

        if now - defaults.double(forKey: fullKey) > Self.libraryBookFullRefreshInterval {
            let fresh = await BookRepository.shared.refreshBooks(ids: Array(libraryIds))
            guard uid == currentUserId, !fresh.isEmpty else { return }
            applyRefreshedBooks(fresh, uid: uid)
            defaults.set(now, forKey: fullKey)
            defaults.set(now, forKey: deltaKey)
            return
        }

        let lastDelta = defaults.double(forKey: deltaKey)
        guard lastDelta > 0 else {
            // No delta baseline yet (pre-existing install) — the weekly sweep just
            // covered or will cover the backlog; start the delta clock now.
            defaults.set(now, forKey: deltaKey)
            return
        }
        // 5-minute overlap absorbs client/server clock skew on the log timestamps.
        guard let edited = await CoverRegenerationService.shared.coverEditedBookIds(
            since: Date(timeIntervalSince1970: lastDelta - 300)
        ) else { return } // query failed (offline) — retry next launch, don't advance the clock
        let stale = edited.intersection(libraryIds)
        if !stale.isEmpty {
            let fresh = await BookRepository.shared.refreshBooks(ids: Array(stale))
            guard uid == currentUserId else { return }
            guard !fresh.isEmpty else { return } // fetch failed — retry next launch
            applyRefreshedBooks(fresh, uid: uid)
        }
        defaults.set(now, forKey: deltaKey)
    }

    /// Merges freshly-fetched book docs into the library; publishes and re-persists
    /// only when something actually changed, so a no-op refresh costs nothing.
    @MainActor
    private func applyRefreshedBooks(_ fresh: [String: Book], uid: String) {
        let updated = userBooks.map { ub -> UserBook in
            var ub = ub
            if let b = fresh[ub.bookId] { ub.book = b }
            return ub
        }
        guard updated != userBooks else { return }
        userBooks = updated
        let copy = updated
        Self.libraryCacheSaveQueue.async {
            LocalLibraryCache.shared.saveLibrary(copy, userId: uid)
        }
    }

    /// Switches the feed between friends-only and everyone: persists the choice
    /// and restarts the feed listener under the new scope.
    func setFeedScope(_ scope: FeedScope) {
        guard scope != feedScope else { return }
        feedScope = scope
        guard let uid = currentUserId else { return }
        UserDefaults.standard.set(scope.rawValue, forKey: Self.feedScopeDefaultsKey(uid: uid))
        feedListener?.remove()
        isFeedLoading = true
        feedPosts = []
        feedLimit = feedPageSize
        canLoadMoreFeedPosts = false
        isLoadingMoreFeedPosts = false
        feedListener = makeFeedListener(uid: uid)
    }

    /// Refreshes the shared unread-notifications badge. Call whenever a bell
    /// appears on screen (both Feed and Profile do this on `.task`) and after
    /// sign-in, so the dot reflects real Firestore state rather than stale UI.
    func refreshUnreadNotifications() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiPreviewNotifications") {
            hasUnreadNotifications = true
            return
        }
        #endif
        guard let uid = currentUserId else {
            hasUnreadNotifications = false
            return
        }
        Task { [weak self, notificationsRepo] in
            let unread = await notificationsRepo.hasUnread(uid: uid)
            await MainActor.run {
                self?.hasUnreadNotifications = unread
            }
        }
    }

    /// Clears the badge immediately (optimistic) and marks every row read
    /// server-side. Call when either bell opens the notifications feed.
    func markNotificationsRead() {
        hasUnreadNotifications = false
        guard let uid = currentUserId else { return }
        Task { [notificationsRepo] in
            await notificationsRepo.markAllRead(uid: uid)
        }
    }

    /// Reader reached the bottom of the feed: deepen the listener by one page.
    /// The current posts stay on screen (and stay live) while the wider query
    /// loads, so this reads as the list growing rather than reloading.
    func loadMoreFeedPosts() {
        guard let uid = currentUserId,
              canLoadMoreFeedPosts,
              !isLoadingMoreFeedPosts,
              !isFeedLoading else { return }
        isLoadingMoreFeedPosts = true
        feedLimit += feedPageSize
        feedListener?.remove()
        feedListener = makeFeedListener(uid: uid)
    }

    /// Feed listener for the current scope — friends queries the follow graph,
    /// everyone streams the global posts collection.
    private func makeFeedListener(uid: String) -> FeedListenerHandle {
        let onUpdate: ([Post], Bool) -> Void = { [weak self] list, hasMore in
            guard let self = self else { return }
            self.feedPosts = list
            self.isFeedLoading = false
            self.isLoadingMoreFeedPosts = false
            self.canLoadMoreFeedPosts = hasMore
        }
        switch feedScope {
        case .friends:
            return postRepo.listenFeed(authorIds: currentFollowing + [uid], limit: feedLimit, onUpdate: onUpdate)
        case .everyone:
            return postRepo.listenAllPosts(limit: feedLimit, onUpdate: onUpdate)
        }
    }

    /// Call when user signs out to stop listeners and clear state.
    func stopFirestoreListeners() {
        userBooksListener?.remove()
        userBooksListener = nil
        feedListener?.remove()
        feedListener = nil
        recommendationsListener?.remove()
        recommendationsListener = nil
    }

    // MARK: - Friend recommendations

    private func loadRecommenderProfilesIfNeeded(for recommendations: [BookRecommendation]) {
        let missing = Set(recommendations.map(\.fromUserId)).subtracting(recommenderProfiles.keys)
        guard !missing.isEmpty else { return }
        Task { [weak self] in
            guard let self = self else { return }
            for uid in missing {
                guard let user = await self.userRepo.getUser(uid: uid) else { continue }
                await MainActor.run { self.recommenderProfiles[uid] = user }
            }
        }
    }

    /// Recipient adds a recommended book to their queue. Removes it from the
    /// Recommended shelf immediately; status update is fire-and-forget.
    func acceptRecommendation(_ rec: BookRecommendation) {
        guard let book = rec.book else { return }
        incomingRecommendations.removeAll { $0.id == rec.id }
        addToWantToRead(book: book)
        Task { try? await recommendationRepo.updateStatus(id: rec.id, status: .accepted) }
    }

    /// Recipient passes on a recommended book.
    func dismissRecommendation(_ rec: BookRecommendation) {
        incomingRecommendations.removeAll { $0.id == rec.id }
        Task { try? await recommendationRepo.updateStatus(id: rec.id, status: .dismissed) }
    }

    func signOut() {
        stopFirestoreListeners()
        currentUserId = nil
        currentFollowing = []
        currentUser = nil
        isAuthenticated = false
        userBooks = []
        pendingQueueNotes = [:]
        feedPosts = []
        isFeedLoading = true
        feedLimit = feedPageSize
        canLoadMoreFeedPosts = false
        isLoadingMoreFeedPosts = false
        incomingRecommendations = []
        recommenderProfiles = [:]
        dismissedBookIds = []
        dismissedBookIdsLoaded = false
        userBooksLoaded = false
        discoverCurrentSuggestion = nil
        discoverSuggestionQueue = []
        discoverPassedBooks = []
        discoverLoadCameUpEmpty = false
        discoverFetchGeneration += 1
        likedPostIds = []
        deepLinkFeedPostId = nil
        deepLinkFeedCommentId = nil
        discoverEnteredFromFeed = false
        feedScrollRestoreOffsetY = nil
        feedScrollOffsetY = 0
        pendingTierHighlightBookId = nil
        tierHighlightScrollPending = false
        BookRepository.shared.clearCache()
        Task { @MainActor in
            WidgetDataService.shared.writeSignedOutSnapshot()
        }
    }

    /// Clear the pending tier-list highlight once the user has actually tiered the book.
    private func clearTierHighlightIfTiered() {
        guard let bid = pendingTierHighlightBookId else { return }
        if let ub = userBooks.first(where: { $0.bookId == bid && $0.status == .read }), ub.tier != nil {
            pendingTierHighlightBookId = nil
            tierHighlightScrollPending = false
        }
    }

    /// Switch to the Profile tab → Read segment, then pulse-glow this book in Unranked. Cleared once the user assigns a tier.
    func startTierHighlight(forBookId bookId: String) {
        pendingTierHighlightBookId = bookId
        tierHighlightScrollPending = true
        NotificationCenter.default.post(name: .spineHighlightTierBook, object: nil, userInfo: ["bookId": bookId])
    }

    func addUserBook(_ userBook: UserBook) {
        userBooks.append(userBook)
    }

    func updateUserBook(_ userBook: UserBook) {
        if let i = userBooks.firstIndex(where: { $0.id == userBook.id }) {
            userBooks[i] = userBook
        }
    }

    func setTier(for userBookId: UUID, tier: String?) {
        setTierAndOrder(for: userBookId, tier: tier, order: nil)
    }

    /// Set a book's tier and its order within that tier. Order is 0-based; nil = append at end. Renumbers others in source and target tier.
    func setTierAndOrder(for userBookId: UUID, tier rawTier: String?, order: Int?) {
        guard let moveIndex = userBooks.firstIndex(where: { $0.id == userBookId }) else { return }
        // The tier list only shows read books; a queue book's UUID can still arrive here
        // via a stray drop, and tiering it would corrupt queue ordering.
        guard userBooks[moveIndex].status == .read else { return }
        let tier = rawTier.flatMap { $0.isEmpty ? nil : $0 }
        let now = Date()
        let movedBookId = userBooks[moveIndex].bookId
        let movedTierBefore = userBooks[moveIndex].normalizedTier

        var moved = userBooks[moveIndex]
        let sourceTier = moved.normalizedTier
        moved.tier = tier
        moved.updatedAt = now

        var toPersist: [UserBook] = []

        /// Read books in `t`, in the exact order TierListView displays them. Restricting to
        /// `.read` matters for the Unranked row: queue books also have `tier == nil`, and
        /// counting those invisible rows used to skew every insertion index.
        func tierMembers(_ t: String?) -> [UserBook] {
            spineTierSorted(userBooks.filter { $0.status == .read && $0.normalizedTier == t })
        }

        // Target tier: current members (excluding moved), insert moved at order, then assign tierOrder 0,1,2,...
        // Drop zones pass `order` = "insert before this slot" in the **full** tier list (including the moved book).
        // `inTarget` excludes the moved book, so indices are off by one for slots after the moved book — fix below.
        let fullTierBefore = tierMembers(tier)
        let movedIndexInFullTier = fullTierBefore.firstIndex(where: { $0.id == userBookId })
        var inTarget = fullTierBefore.filter { $0.id != userBookId }

        let insertAt: Int
        if let raw = order {
            let insertBeforeSlot = min(max(0, raw), fullTierBefore.count)
            if let m = movedIndexInFullTier {
                let converted = insertBeforeSlot <= m ? insertBeforeSlot : insertBeforeSlot - 1
                insertAt = min(max(0, converted), inTarget.count)
            } else {
                insertAt = min(max(0, insertBeforeSlot), inTarget.count)
            }
        } else {
            insertAt = inTarget.count
        }
        inTarget.insert(moved, at: insertAt)
        var inSourceUpdates: [(Int, Int)] = []
        if sourceTier != tier {
            let inSource = tierMembers(sourceTier).filter { $0.id != userBookId }
            for (i, ub) in inSource.enumerated() {
                guard let idx = userBooks.firstIndex(where: { $0.id == ub.id }) else { continue }
                if userBooks[idx].tierOrder != i {
                    inSourceUpdates.append((idx, i))
                }
            }
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            for (i, ub) in inTarget.enumerated() {
                guard let idx = userBooks.firstIndex(where: { $0.id == ub.id }) else { continue }
                let changed = userBooks[idx].tier != tier || userBooks[idx].tierOrder != i
                userBooks[idx].tier = tier
                userBooks[idx].tierOrder = i
                if ub.id == userBookId { userBooks[idx].updatedAt = now }
                if changed { toPersist.append(userBooks[idx]) }
            }
            for (idx, i) in inSourceUpdates {
                userBooks[idx].tierOrder = i
                toPersist.append(userBooks[idx])
            }
        }

        Task {
            try? await userBookRepo.batchUpdatePlacement(toPersist)
        }

        if movedTierBefore != tier {
            Task { [weak self] in
                guard let self = self, let uid = self.currentUserId else { return }
                let posts = await self.postRepo.fetchPostsForUserAndBook(userId: uid, bookId: movedBookId)
                let finished = posts.filter { $0.type == .finishedBook }
                for p in finished {
                    try? await self.postRepo.updatePostTier(postId: p.id.uuidString, tier: tier)
                }
            }
        }
    }

    /// Tier-list multi-select: move several read books to `tier` in one pass, appending
    /// them at the end in their current display order (ladder position, then tierOrder).
    /// One renumber + one batch write, instead of N calls to `setTierAndOrder` each
    /// renumbering and persisting the same rows again.
    func moveReadBooksToTier(userBookIds: [UUID], tier rawTier: String?) {
        let tier = rawTier.flatMap { $0.isEmpty ? nil : $0 }
        let idSet = Set(userBookIds)
        let picked = userBooks.filter { idSet.contains($0.id) && $0.status == .read }
        // Display order across tiers: S row first, Unranked last, tierOrder within.
        let ladder: [String?] = spineTierLabels.map { Optional($0) } + [nil]
        let moving = ladder.flatMap { t in spineTierSorted(picked.filter { $0.normalizedTier == t }) }
        guard !moving.isEmpty else { return }
        let now = Date()
        let movingIds = Set(moving.map(\.id))
        let sourceTiers = Set(moving.map(\.normalizedTier)).subtracting([tier])
        // Books actually changing tier get their feed posts re-badged below.
        let rebadge = moving.filter { $0.normalizedTier != tier }.map(\.bookId)

        func tierMembers(_ t: String?) -> [UserBook] {
            spineTierSorted(userBooks.filter { $0.status == .read && $0.normalizedTier == t && !movingIds.contains($0.id) })
        }

        var toPersist: [UserBook] = []
        withAnimation(.easeInOut(duration: 0.3)) {
            let target = tierMembers(tier) + moving
            for (i, ub) in target.enumerated() {
                guard let idx = userBooks.firstIndex(where: { $0.id == ub.id }) else { continue }
                let changed = userBooks[idx].tier != tier || userBooks[idx].tierOrder != i
                userBooks[idx].tier = tier
                userBooks[idx].tierOrder = i
                if movingIds.contains(ub.id) { userBooks[idx].updatedAt = now }
                if changed { toPersist.append(userBooks[idx]) }
            }
            for source in sourceTiers {
                for (i, ub) in tierMembers(source).enumerated() {
                    guard let idx = userBooks.firstIndex(where: { $0.id == ub.id }), userBooks[idx].tierOrder != i else { continue }
                    userBooks[idx].tierOrder = i
                    toPersist.append(userBooks[idx])
                }
            }
        }

        Task {
            try? await userBookRepo.batchUpdatePlacement(toPersist)
        }

        guard !rebadge.isEmpty else { return }
        Task { [weak self] in
            guard let self = self, let uid = self.currentUserId else { return }
            for bookId in rebadge {
                let posts = await self.postRepo.fetchPostsForUserAndBook(userId: uid, bookId: bookId)
                for p in posts where p.type == .finishedBook {
                    try? await self.postRepo.updatePostTier(postId: p.id.uuidString, tier: tier)
                }
            }
        }
    }

    /// Tier-list multi-select: remove several read books (reviews and feed posts
    /// included, via `deleteReadReview`). Rows leave the shelf immediately; if a
    /// delete fails, the listener echo brings that row back. Returns the failure count.
    @MainActor
    func removeReadBooks(userBookIds: [UUID]) async -> Int {
        let idSet = Set(userBookIds)
        let targets = userBooks.filter { idSet.contains($0.id) && $0.status == .read }
        guard !targets.isEmpty else { return 0 }
        withAnimation(.easeInOut(duration: 0.3)) {
            userBooks.removeAll { idSet.contains($0.id) && $0.status == .read }
        }
        var failures = 0
        for ub in targets {
            if await deleteReadReview(userBook: ub) != nil { failures += 1 }
        }
        return failures
    }

    /// Append position for a book entering `tier`, so it never lands with `tierOrder == nil`
    /// (nil orders tie and make drop-slot indices ambiguous). Safe even when existing
    /// members still have nil orders.
    private func nextTierOrder(for tier: String) -> Int {
        let members = userBooks.filter { $0.status == .read && $0.normalizedTier == tier }
        return max((members.compactMap(\.tierOrder).max() ?? -1) + 1, members.count)
    }

    /// Updates the **existing** queue `userBook` document to Read with rating, optional thoughts as `reviewText`, and optional feed post. Does not create a duplicate row.
    func promoteQueueEntryToRead(
        userBook: UserBook,
        dateFinished: Date,
        rating: Double?,
        postToFeed: Bool,
        caption: String?,
        tier: String? = nil
    ) {
        guard let uid = currentUserId, userBook.status == .wantToRead else { return }
        let stored = rating.map { Theme.normalizeRatingOutOfTen($0) }
        let thoughts = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let review = thoughts.flatMap { $0.isEmpty ? nil : $0 }
        let validTier = tier.flatMap { spineTierLabels.contains($0) ? $0 : nil }
        var updated = userBook
        updated.status = .read
        updated.dateFinished = dateFinished
        updated.rating = stored
        updated.reviewText = review
        updated.tier = validTier ?? updated.tier
        // Concrete order on tier entry; queue books can carry stale tierOrders, so clear
        // when landing in Unranked.
        updated.tierOrder = updated.tier.flatMap { $0.isEmpty ? nil : $0 }.map { nextTierOrder(for: $0) }
        updated.queueShelf = nil
        updated.queueOrder = nil
        updated.updatedAt = Date()
        updateUserBook(updated)
        if validTier == nil {
            startTierHighlight(forBookId: userBook.bookId)
        }
        let readTitle = userBook.book?.title ?? "Book"
        Task { @MainActor in ToastCenter.shared.show(.markedAsRead(bookTitle: readTitle, sharedToFeed: postToFeed)) }
        Task {
            try? await userBookRepo.updateUserBook(updated)
            if postToFeed {
                _ = try? await postRepo.createPost(
                    userId: uid,
                    type: .finishedBook,
                    bookId: userBook.bookId,
                    caption: review,
                    rating: stored,
                    dateFinished: dateFinished,
                    tier: validTier
                )
            }
        }
    }

    /// Drag-and-drop between **Up next** and **Backlog**, or reorder within a shelf. `insertionIndex` 0 = first cell (top-left).
    func setQueueShelfAndOrder(for userBookId: UUID, shelf: QueueShelf, insertionIndex: Int?) {
        guard let moveIndex = userBooks.firstIndex(where: { $0.id == userBookId }) else { return }
        guard userBooks[moveIndex].status == .wantToRead else { return }
        let now = Date()

        func belongsToShelf(_ ub: UserBook, _ s: QueueShelf) -> Bool {
            switch s {
            case .readingNow: return ub.queueShelf == .readingNow
            case .upNext: return ub.queueShelf == .upNext
            case .backlog: return ub.queueShelf == nil || ub.queueShelf == .backlog
            }
        }

        var moved = userBooks[moveIndex]
        let sourceShelf: QueueShelf = {
            switch moved.queueShelf {
            case .readingNow: return .readingNow
            case .upNext: return .upNext
            default: return .backlog
            }
        }()
        moved.queueShelf = shelf
        moved.updatedAt = now

        // Same as tier list: UI passes insertion slot in the **full** shelf list (including the moved book).
        let fullShelfBefore = Self.sortQueueMembers(
            userBooks.filter { belongsToShelf($0, shelf) },
            shelf: shelf
        )
        let movedIndexInFullShelf = fullShelfBefore.firstIndex(where: { $0.id == userBookId })

        var inTarget = userBooks.filter { $0.id != userBookId && belongsToShelf($0, shelf) }
        inTarget = Self.sortQueueMembers(inTarget, shelf: shelf)

        let insertAt: Int
        if let raw = insertionIndex {
            let cap = fullShelfBefore.count
            let insertBeforeSlot = min(max(0, raw), cap)
            if let m = movedIndexInFullShelf, sourceShelf == shelf {
                let converted = insertBeforeSlot <= m ? insertBeforeSlot : insertBeforeSlot - 1
                insertAt = min(max(0, converted), inTarget.count)
            } else {
                insertAt = min(max(0, insertBeforeSlot), inTarget.count)
            }
        } else {
            insertAt = inTarget.count
        }
        inTarget.insert(moved, at: insertAt)

        var toPersist: [UserBook] = []

        withAnimation(.easeInOut(duration: 0.3)) {
            for (i, ub) in inTarget.enumerated() {
                guard let idx = userBooks.firstIndex(where: { $0.id == ub.id }) else { continue }
                let prev = userBooks[idx]
                userBooks[idx].queueShelf = shelf
                userBooks[idx].queueOrder = i
                if ub.id == userBookId { userBooks[idx].updatedAt = now }
                if prev.queueShelf != userBooks[idx].queueShelf || prev.queueOrder != userBooks[idx].queueOrder {
                    toPersist.append(userBooks[idx])
                }
            }

            if sourceShelf != shelf {
                var inSource = userBooks.filter { $0.id != userBookId && belongsToShelf($0, sourceShelf) }
                inSource = Self.sortQueueMembers(inSource, shelf: sourceShelf)
                for (i, ub) in inSource.enumerated() {
                    guard let idx = userBooks.firstIndex(where: { $0.id == ub.id }) else { continue }
                    let prev = userBooks[idx]
                    userBooks[idx].queueOrder = i
                    userBooks[idx].queueShelf = sourceShelf
                    userBooks[idx].updatedAt = now
                    if prev.queueOrder != userBooks[idx].queueOrder || prev.queueShelf != userBooks[idx].queueShelf {
                        toPersist.append(userBooks[idx])
                    }
                }
            }
        }

        Task {
            try? await userBookRepo.batchUpdatePlacement(toPersist)
        }
    }

    private static func sortQueueMembers(_ books: [UserBook], shelf: QueueShelf) -> [UserBook] {
        switch shelf {
        case .readingNow, .upNext:
            return books.sorted { ($0.queueOrder ?? 999) < ($1.queueOrder ?? 999) }
        case .backlog:
            return sortedBacklog(books)
        }
    }

    var readBooks: [UserBook] {
        userBooks.filter { $0.status == .read }
    }

    var currentlyReading: [UserBook] {
        userBooks.filter { $0.status == .currentlyReading }
    }

    var wantToRead: [UserBook] {
        userBooks.filter { $0.status == .wantToRead }
    }

    /// Queue → **Reading now** (explicit shelf only).
    var wantToReadReadingNow: [UserBook] {
        userBooks
            .filter { $0.status == .wantToRead && $0.queueShelf == .readingNow }
            .sorted { ($0.queueOrder ?? 999) < ($1.queueOrder ?? 999) }
    }

    /// Queue → **Up next** (explicit shelf only).
    var wantToReadUpNext: [UserBook] {
        userBooks
            .filter { $0.status == .wantToRead && $0.queueShelf == .upNext }
            .sorted { ($0.queueOrder ?? 999) < ($1.queueOrder ?? 999) }
    }

    /// Queue → **Backlog** (default; includes legacy `queueShelf == nil`).
    var wantToReadBacklog: [UserBook] {
        let backlog = userBooks.filter { $0.status == .wantToRead && ($0.queueShelf == nil || $0.queueShelf == .backlog) }
        return Self.sortedBacklog(backlog)
    }

    /// Books the user started and gave up on, most recently abandoned first.
    /// Shown in a section below Backlog in the Queue tab.
    var dnfBooks: [UserBook] {
        userBooks.filter { $0.status == .didNotFinish }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Explicit `queueOrder` first (0 = top), then legacy nil rows by `updatedAt` descending (newer near top).
    private static func sortedBacklog(_ books: [UserBook]) -> [UserBook] {
        let explicit = books.filter { $0.queueOrder != nil }.sorted { $0.queueOrder! < $1.queueOrder! }
        let implicit = books.filter { $0.queueOrder == nil }.sorted { $0.updatedAt > $1.updatedAt }
        return explicit + implicit
    }

    /// True if the given book id is on the user's read list.
    func isBookOnReadList(bookId: String) -> Bool {
        userBooks.contains { $0.bookId == bookId && $0.status == .read }
    }

    /// The signed-in user's read `UserBook` for this book id, if any (e.g. book profile "Your review").
    func userReadBook(forBookId bookId: String) -> UserBook? {
        userBooks.first { $0.bookId == bookId && $0.status == .read }
    }

    /// True if the given book id is in the user's queue (want to read).
    func isBookInQueue(bookId: String) -> Bool {
        userBooks.contains { $0.bookId == bookId && $0.status == .wantToRead }
    }

    // MARK: - Queue notes (private note-to-self on a queued book)

    /// Notes saved from the post-queue toast before the new `userBook` row has
    /// echoed back from Firestore. Applied by `applyPendingQueueNotes()` on the
    /// next listener update; keyed by the tapped book's id.
    private var pendingQueueNotes: [String: (book: Book, note: String?)] = [:]

    /// The signed-in user's queued entry for this book — exact id first, then
    /// any other edition of the same work.
    func queuedUserBook(for book: Book) -> UserBook? {
        userBooks.first { $0.bookId == book.id && $0.status == .wantToRead }
            ?? userBook(sameWorkAs: book, status: .wantToRead)
    }

    /// Saves (or clears, with nil/blank) the note-to-self on a queued book.
    /// Optimistic: local state updates immediately, Firestore follows. If the
    /// queue row isn't in `userBooks` yet (the add is still in flight) the note
    /// is parked and applied when the row arrives.
    func setQueueNote(for book: Book, note: String?) {
        let trimmed = (note?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        guard let queuedId = queuedUserBook(for: book)?.id,
              let index = userBooks.firstIndex(where: { $0.id == queuedId }) else {
            pendingQueueNotes[book.id] = (book, trimmed)
            return
        }
        pendingQueueNotes[book.id] = nil
        let hadNote = userBooks[index].trimmedQueueNote != nil
        userBooks[index].queueNote = trimmed
        userBooks[index].updatedAt = Date()
        let userBookId = userBooks[index].id
        if trimmed != nil {
            Task { @MainActor in ToastCenter.shared.show(.queueNoteSaved(bookTitle: book.title)) }
        } else if hadNote {
            Task { @MainActor in ToastCenter.shared.show(.queueNoteRemoved(bookTitle: book.title)) }
        }
        guard currentUserId != nil else { return }
        Task {
            try? await userBookRepo.setQueueNote(userBookId: userBookId, note: trimmed)
        }
    }

    /// Saves how far through a Reading now book the reader is (0...1), from the
    /// bookmark scrubber. Optimistic: local state first, Firestore follows.
    func setReadingProgress(userBookId: UUID, progress: Double) {
        let clamped = min(1, max(0, progress))
        guard let index = userBooks.firstIndex(where: { $0.id == userBookId }) else { return }
        let previous = userBooks[index].readingProgress
        userBooks[index].readingProgress = clamped
        userBooks[index].updatedAt = Date()
        var stampedStart: Date?
        if userBooks[index].dateStarted == nil, clamped > 0 {
            stampedStart = Date()
            userBooks[index].dateStarted = stampedStart
        }
        Analytics.amplitude?.track(eventType: "Updated Reading Progress", eventProperties: [
            "progress_percent": Int((clamped * 100).rounded()),
            "previous_percent": previous.map { Int(($0 * 100).rounded()) } as Any,
            "has_page_count": (userBooks[index].book?.pageCount ?? 0) > 0,
        ])
        guard currentUserId != nil else { return }
        Task {
            try? await userBookRepo.setReadingProgress(userBookId: userBookId, progress: clamped, dateStarted: stampedStart)
        }
    }

    /// Opens the note-to-self composer for a queued book (from the post-queue
    /// toast). Pre-fills whatever note is already saved or pending.
    func promptQueueNote(for book: Book) {
        let existing = queuedUserBook(for: book)?.trimmedQueueNote ?? pendingQueueNotes[book.id]?.note ?? ""
        let request = QueueNoteRequest(book: book, initialNote: existing) { [weak self] note in
            self?.setQueueNote(for: book, note: note)
        }
        Task { @MainActor in ToastCenter.shared.presentQueueNote(request) }
    }

    /// Called after every `userBooks` listener update: flush notes that were
    /// written before their queue row existed locally.
    private func applyPendingQueueNotes() {
        guard !pendingQueueNotes.isEmpty else { return }
        for (key, pending) in pendingQueueNotes where queuedUserBook(for: pending.book) != nil {
            pendingQueueNotes[key] = nil
            setQueueNote(for: pending.book, note: pending.note)
        }
    }

    /// The post-queue toast: cover thumbnail + "tap to add a note".
    private func showQueuedToast(for book: Book, shelf: QueueShelf?) {
        Task { @MainActor in
            ToastCenter.shared.show(.queued(book: book, startedReading: shelf == .readingNow) { [weak self] in
                self?.promptQueueNote(for: book)
            })
        }
    }

    /// Existing library entry for the same *work* as `book` — matched by volume
    /// id, ISBN equivalence, or normalized title + author, so a different
    /// edition of a book already on the shelf still counts as that book.
    func userBook(sameWorkAs book: Book, status: ReadingStatus? = nil) -> UserBook? {
        userBooks.first { ub in
            if let status, ub.status != status { return false }
            if ub.bookId == book.id { return true }
            guard let existing = ub.book else { return false }
            return LibraryDedup.isSameWork(existing, book)
        }
    }

    /// Mark a book as "not interested" so we never suggest it again.
    func addDismissedBookId(_ bookId: String) {
        dismissedBookIds.insert(bookId)
        guard let uid = currentUserId else { return }
        Task {
            try? await dismissedRepo.addDismissed(userId: uid, bookId: bookId)
        }
    }

    /// Remove a book from dismissed (undo Pass) and show it again as the current Discover suggestion.
    func returnToDiscoverBook(_ book: Book) {
        dismissedBookIds.remove(book.id)
        discoverCurrentSuggestion = book
        guard let uid = currentUserId else { return }
        Task {
            try? await dismissedRepo.removeDismissed(userId: uid, bookId: book.id)
        }
    }

    /// Undo the most recent Pass: un-dismiss that book, put whatever is showing
    /// now back at the front of the queue so it isn't skipped, and show the
    /// passed book again.
    func undoLastDiscoverPass() {
        guard let book = discoverPassedBooks.popLast() else { return }
        dismissedBookIds.remove(book.id)
        if let current = discoverCurrentSuggestion, current.id != book.id {
            discoverSuggestionQueue.insert(current, at: 0)
        }
        discoverCurrentSuggestion = book
        guard let uid = currentUserId else { return }
        Task {
            try? await dismissedRepo.removeDismissed(userId: uid, bookId: book.id)
        }
    }

    /// Add a book to Queue. Firestore listener will update userBooks.
    /// If any edition of the same work is already queued, no duplicate is created:
    /// a backlog copy is pulled to the top of the backlog instead, and a copy on
    /// Reading Now / Up Next stays where it is.
    func addToWantToRead(book: Book) {
        guard let uid = currentUserId else { return }
        if let existing = userBook(sameWorkAs: book, status: .wantToRead) {
            if existing.queueShelf == nil || existing.queueShelf == .backlog {
                setQueueShelfAndOrder(for: existing.id, shelf: .backlog, insertionIndex: 0)
                showQueuedToast(for: book, shelf: .backlog)
            }
            return
        }
        showQueuedToast(for: book, shelf: .backlog)
        Task {
            _ = try? await userBookRepo.addUserBook(userId: uid, book: book, status: .wantToRead, rating: nil, reviewText: nil, dateStarted: nil, dateFinished: nil)
        }
    }

    /// Add a book directly onto a specific queue shelf (from the shelf "Add" tiles),
    /// landing at the end of that shelf. If any edition of the same work is already
    /// queued (even on another shelf), that entry moves to the top of the target
    /// shelf instead of a duplicate being created.
    func addToQueue(book: Book, shelf: QueueShelf) {
        guard let uid = currentUserId else { return }
        if let existing = userBook(sameWorkAs: book, status: .wantToRead) {
            setQueueShelfAndOrder(for: existing.id, shelf: shelf, insertionIndex: 0)
            showQueuedToast(for: book, shelf: shelf)
            return
        }
        let endOrder: Int = {
            switch shelf {
            case .readingNow: return wantToReadReadingNow.count
            case .upNext: return wantToReadUpNext.count
            case .backlog: return wantToReadBacklog.count
            }
        }()
        showQueuedToast(for: book, shelf: shelf)
        Task {
            _ = try? await userBookRepo.addUserBook(userId: uid, book: book, status: .wantToRead, rating: nil, reviewText: nil, dateStarted: nil, dateFinished: nil, targetShelf: shelf, targetOrder: endOrder)
        }
    }

    /// Switch to the Profile tab → Queue segment. Used after adding a book to the queue from the
    /// search flow so the user lands on the queue instead of being dropped back on the search bar.
    func openQueue() {
        NotificationCenter.default.post(name: .spineOpenQueue, object: nil)
    }

    /// Remove a book from the queue. No-op if not in queue.
    func removeFromQueue(book: Book) {
        guard let uid = currentUserId else { return }
        guard let userBook = userBooks.first(where: { $0.bookId == book.id && $0.status == .wantToRead }) else { return }
        Task {
            try? await userBookRepo.deleteUserBook(userId: uid, userBookId: userBook.id)
        }
    }

    /// Remove a book from the read shelf (tier list). No-op if not on read list.
    func removeFromReadList(book: Book) {
        guard let uid = currentUserId else { return }
        guard let userBook = userBooks.first(where: { $0.bookId == book.id && $0.status == .read }) else { return }
        Task {
            try? await userBookRepo.deleteUserBook(userId: uid, userBookId: userBook.id)
        }
    }

    /// Give up on a queued book — pulls it off its shelf (typically Reading Now)
    /// into its own "did not finish" list instead of deleting it outright, so it
    /// still shows up as a DNF section under the queue. No-op if not queued.
    func markAsDNF(book: Book) {
        guard currentUserId != nil else { return }
        guard let idx = userBooks.firstIndex(where: { $0.bookId == book.id && $0.status == .wantToRead }) else { return }
        var updated = userBooks[idx]
        updated.status = .didNotFinish
        updated.queueShelf = nil
        updated.queueOrder = nil
        updated.updatedAt = Date()
        withAnimation(.easeInOut(duration: 0.3)) {
            userBooks[idx] = updated
        }
        Task { @MainActor in ToastCenter.shared.show(.markedAsDNF(bookTitle: book.title)) }
        Task {
            try? await userBookRepo.updateUserBook(updated)
        }
    }

    /// Add a book as Read. `rating` is out of 10 with one decimal (e.g. 8.8). `caption` is saved on the user’s `UserBook` as review text (book profile “Your review”) and, if `postToFeed`, on the finished-book feed post.
    /// `tier` places the book straight into that tier; when nil the book lands in Unranked and the tier-list "Rank me" prompt kicks in.
    func addAsRead(book: Book, dateFinished: Date, rating: Double?, postToFeed: Bool, caption: String? = nil, tier: String? = nil) {
        guard let uid = currentUserId else { return }
        // If the book is already in the user's queue (Want to Read), promote that existing
        // entry to Read instead of creating a duplicate row. This also removes it from the
        // queue, since `promoteQueueEntryToRead` clears queueShelf/queueOrder.
        if let queued = userBooks.first(where: { $0.bookId == book.id && $0.status == .wantToRead }) {
            promoteQueueEntryToRead(userBook: queued, dateFinished: dateFinished, rating: rating, postToFeed: postToFeed, caption: caption, tier: tier)
            return
        }
        let stored: Double? = rating.map { Theme.normalizeRatingOutOfTen($0) }
        let thoughts = (caption?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let validTier = tier.flatMap { spineTierLabels.contains($0) ? $0 : nil }
        let newTierOrder = validTier.map { nextTierOrder(for: $0) }
        if validTier == nil {
            startTierHighlight(forBookId: book.id)
        }
        Task { @MainActor in ToastCenter.shared.show(.markedAsRead(bookTitle: book.title, sharedToFeed: postToFeed)) }
        Task {
            let ub = try? await userBookRepo.addUserBook(userId: uid, book: book, status: .read, rating: stored, reviewText: thoughts, dateStarted: nil, dateFinished: dateFinished)
            if let validTier, let ub {
                try? await userBookRepo.setTier(userBookId: ub.id, tier: validTier, tierOrder: newTierOrder)
            }
            if postToFeed {
                _ = try? await postRepo.createPost(userId: uid, type: .finishedBook, bookId: book.id, caption: thoughts, rating: stored, dateFinished: dateFinished, tier: validTier)
            }
        }
    }

    /// Whether the current user has a `finishedBook` feed post for this book (for edit sheet “Show on feed”).
    func hasFinishedBookPost(forBookId bookId: String) async -> Bool {
        guard let uid = currentUserId else { return false }
        let posts = await postRepo.fetchPostsForUserAndBook(userId: uid, bookId: bookId)
        return posts.contains { $0.type == .finishedBook }
    }

    /// Text from the most recent finished-book post for this book (when `userBook.reviewText` is empty).
    func finishedBookPostCaption(forBookId bookId: String) async -> String? {
        guard let uid = currentUserId else { return nil }
        let posts = await postRepo.fetchPostsForUserAndBook(userId: uid, bookId: bookId)
        let finished = posts.filter { $0.type == .finishedBook }.sorted { $0.createdAt > $1.createdAt }
        guard let raw = finished.first?.caption?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    /// Updates read `UserBook` and syncs or creates/removes the matching feed post. Returns an error message on failure.
    /// `additionalReadDates` nil leaves re-read dates unchanged; an array (even empty) replaces them.
    func updateReadReview(
        userBook: UserBook,
        dateFinished: Date,
        rating: Double?,
        thoughts: String,
        postToFeed: Bool,
        additionalReadDates: [Date]? = nil,
        announceSave: Bool = true
    ) async -> String? {
        guard let uid = currentUserId, userBook.userId == uid else { return "You’re not signed in." }
        guard userBook.status == .read else { return "This isn’t a finished book entry." }
        let trimmed = thoughts.trimmingCharacters(in: .whitespacesAndNewlines)
        let reviewText = trimmed.isEmpty ? nil : trimmed
        let storedRating = rating.map { Theme.normalizeRatingOutOfTen($0) }
        var updated = userBook
        updated.dateFinished = dateFinished
        updated.rating = storedRating
        updated.reviewText = reviewText
        if let additionalReadDates {
            updated.additionalReadDates = additionalReadDates.isEmpty ? nil : additionalReadDates.sorted(by: >)
        }
        updated.updatedAt = Date()
        do {
            try await userBookRepo.updateUserBook(updated)
            await MainActor.run { self.updateUserBook(updated) }
            let posts = await postRepo.fetchPostsForUserAndBook(userId: uid, bookId: userBook.bookId)
            let finished = posts.filter { $0.type == .finishedBook }.sorted { $0.createdAt > $1.createdAt }
            // Hidden discussion carriers from the book profile's "Read by" section —
            // promoted to a feed post instead of creating a duplicate thread.
            let discussionStubs = posts.filter { $0.type == .readRecord }
            let currentTier = updated.tier
            if postToFeed {
                if finished.isEmpty, let stub = discussionStubs.first {
                    try await postRepo.updatePost(
                        postId: stub.id.uuidString,
                        caption: reviewText,
                        rating: storedRating,
                        dateFinished: dateFinished,
                        tier: currentTier
                    )
                    try await postRepo.setPostType(postId: stub.id.uuidString, type: .finishedBook, refreshCreatedAt: true)
                } else if finished.isEmpty {
                    _ = try await postRepo.createPost(
                        userId: uid,
                        type: .finishedBook,
                        bookId: userBook.bookId,
                        caption: reviewText,
                        rating: storedRating,
                        dateFinished: dateFinished,
                        tier: currentTier
                    )
                } else {
                    for p in finished {
                        try await postRepo.updatePost(
                            postId: p.id.uuidString,
                            caption: reviewText,
                            rating: storedRating,
                            dateFinished: dateFinished,
                            tier: currentTier
                        )
                    }
                }
            } else {
                // Demote instead of delete: comments and likes gathered on the post
                // keep living in the book profile's "Read by" discussion.
                for p in finished {
                    try await postRepo.updatePost(
                        postId: p.id.uuidString,
                        caption: reviewText,
                        rating: storedRating,
                        dateFinished: dateFinished,
                        tier: currentTier
                    )
                    try await postRepo.setPostType(postId: p.id.uuidString, type: .readRecord)
                    await MainActor.run {
                        feedPosts.removeAll { $0.id == p.id }
                    }
                }
            }
            if announceSave {
                await MainActor.run { ToastCenter.shared.show(.reviewUpdated(sharedToFeed: postToFeed)) }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Removes the read entry and any matching finished-book feed posts for this book.
    func deleteReadReview(userBook: UserBook) async -> String? {
        guard let uid = currentUserId, userBook.userId == uid else { return "You’re not signed in." }
        do {
            let posts = await postRepo.fetchPostsForUserAndBook(userId: uid, bookId: userBook.bookId)
            // Feed posts and hidden discussion carriers both go — the read they
            // hang off is being removed.
            let attached = posts.filter { $0.type == .finishedBook || $0.type == .readRecord }
            for p in attached {
                try await postRepo.deletePostCascade(postId: p.id.uuidString)
                await MainActor.run {
                    likedPostIds.remove(p.id.uuidString)
                    feedPosts.removeAll { $0.id == p.id }
                }
            }
            try await userBookRepo.deleteUserBook(userId: uid, userBookId: userBook.id)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Keeps the in-memory feed's comment count honest after comments are added or
    /// deleted from the comments sheet, so the inline preview reloads instead of
    /// showing a comment that is already gone.
    @MainActor
    func adjustFeedCommentCount(postId: String, delta: Int) {
        guard delta != 0, let idx = feedPosts.firstIndex(where: { $0.id.uuidString == postId }) else { return }
        feedPosts[idx].commentCount = max(0, feedPosts[idx].commentCount + delta)
    }

    /// Deletes one of the current user's feed posts (with its likes and comments), independent of
    /// library state — the post may be orphaned (its book was removed from the read shelf) and must
    /// still be deletable. Leaves any `UserBook` untouched. Returns an error message on failure.
    func deleteFeedPost(post: Post) async -> String? {
        guard let uid = currentUserId, post.userId == uid else { return "You can only delete your own posts." }
        do {
            try await postRepo.deletePostCascade(postId: post.id.uuidString)
            await MainActor.run {
                likedPostIds.remove(post.id.uuidString)
                feedPosts.removeAll { $0.id == post.id }
                ToastCenter.shared.show(.postDeleted())
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Goodreads import

    /// Outcome of importing one Goodreads row. `failed` (write/network error) is
    /// distinct from `duplicate` so the wizard can retry instead of silently
    /// reporting the book as already in the library.
    enum GoodreadsImportOutcome {
        case imported
        case duplicate
        case failed
    }

    /// Import one Goodreads read book (wizard "Add" / import-all). Sets tier when the user picked one.
    func importGoodreadsReadBook(book: Book, rating: Double?, review: String?, dateFinished: Date?, tier: String?) async -> GoodreadsImportOutcome {
        guard let uid = currentUserId else { return .failed }
        guard userBook(sameWorkAs: book, status: .read) == nil else { return .duplicate }
        let storedRating = rating.map { Theme.normalizeRatingOutOfTen($0) }
        let trimmedReview = (review?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let validTier = tier.flatMap { spineTierLabels.contains($0) ? $0 : nil }
        // Already queued (e.g. added manually before importing, possibly as a
        // different edition): promote that row instead of duplicating.
        if let queued = userBook(sameWorkAs: book, status: .wantToRead) {
            var updated = queued
            updated.status = .read
            updated.dateFinished = dateFinished
            updated.rating = storedRating
            updated.reviewText = trimmedReview
            updated.tier = validTier
            updated.tierOrder = validTier.map { nextTierOrder(for: $0) }
            updated.queueShelf = nil
            updated.queueOrder = nil
            updated.updatedAt = Date()
            do {
                try await userBookRepo.updateUserBook(updated)
            } catch {
                return .failed
            }
            updateUserBook(updated)
            return .imported
        }
        do {
            let ub = try await userBookRepo.addUserBook(userId: uid, book: book, status: .read, rating: storedRating, reviewText: trimmedReview, dateStarted: nil, dateFinished: dateFinished)
            if let validTier {
                try? await userBookRepo.setTier(userBookId: ub.id, tier: validTier, tierOrder: nextTierOrder(for: validTier))
            }
            return .imported
        } catch {
            return .failed
        }
    }

    /// Log another read of a book already on the read shelf. The re-read runs
    /// through the same review path as a first finish: `date` joins the book's
    /// read dates (the newest becomes `dateFinished`) and the thoughts, tier, and
    /// feed choice from the mark-as-read drawer land on the one read entry, so a
    /// re-read never creates a second library row. Returns an error message on failure.
    func logAdditionalRead(
        book: Book,
        date: Date,
        thoughts: String?,
        tier: String?,
        postToFeed: Bool
    ) async -> String? {
        guard let existing = userBook(sameWorkAs: book, status: .read) else {
            return "This book isn\u{2019}t on your read shelf."
        }
        let cal = Calendar.current
        var unique: [Date] = []
        for d in (existing.allReadDates + [date]).sorted(by: >) where !unique.contains(where: { cal.isDate($0, inSameDayAs: d) }) {
            unique.append(d)
        }
        // A tier picked in the drawer re-ranks the book; the drawer seeds it with
        // the current tier, so an untouched picker leaves the rank alone.
        if let tier, spineTierLabels.contains(tier), tier != existing.normalizedTier {
            await MainActor.run { self.setTier(for: existing.id, tier: tier) }
        }
        let current = userBooks.first(where: { $0.id == existing.id }) ?? existing
        let err = await updateReadReview(
            userBook: current,
            dateFinished: unique.first ?? date,
            rating: current.rating,
            thoughts: thoughts ?? "",
            postToFeed: postToFeed,
            additionalReadDates: Array(unique.dropFirst()),
            announceSave: false
        )
        if err == nil {
            await MainActor.run {
                ToastCenter.shared.show(.anotherReadLogged(bookTitle: book.title, sharedToFeed: postToFeed))
            }
        }
        return err
    }

    /// A Goodreads row matched a book already on the read shelf: keep the single
    /// library/tier entry, but record the row's read date as a re-read when it's a
    /// day we don't have yet. `dateFinished` stays the most recent read.
    func mergeGoodreadsReReadDate(book: Book, dateRead: Date?) async {
        guard let dateRead else { return }
        guard var existing = userBook(sameWorkAs: book, status: .read) else { return }
        let cal = Calendar.current
        var unique: [Date] = []
        for d in (existing.allReadDates + [dateRead]).sorted(by: >) where !unique.contains(where: { cal.isDate($0, inSameDayAs: d) }) {
            unique.append(d)
        }
        guard unique.count > existing.allReadDates.count || existing.dateFinished == nil else { return }
        existing.dateFinished = unique.first
        existing.additionalReadDates = unique.count > 1 ? Array(unique.dropFirst()) : nil
        existing.updatedAt = Date()
        updateUserBook(existing)
        try? await userBookRepo.updateUserBook(existing)
    }

    /// Move the read date(s) a book has in `fromYear` into `toYear`, keeping month and day.
    /// `fromYear == nil` means the book has no recorded read date: it gets Jan 1 of `toYear`.
    /// Re-read dates in other years stay put, so a book read in 2022 and 2025 only moves
    /// the year the user selected it under.
    func moveReadYear(userBookId: UUID, fromYear: Int?, toYear: Int) {
        guard let i = userBooks.firstIndex(where: { $0.id == userBookId }),
              userBooks[i].status == .read else { return }
        var ub = userBooks[i]
        let cal = Calendar.current
        var dates = ub.allReadDates
        if let fromYear {
            guard fromYear != toYear else { return }
            dates = dates.map { d in
                guard cal.component(.year, from: d) == fromYear else { return d }
                var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
                comps.year = toYear
                return cal.date(from: comps) ?? d
            }
        } else if dates.isEmpty {
            var comps = DateComponents()
            comps.year = toYear
            comps.month = 1
            comps.day = 1
            comps.hour = 12
            if let d = cal.date(from: comps) { dates = [d] }
        }
        var unique: [Date] = []
        for d in dates.sorted(by: >) where !unique.contains(where: { cal.isDate($0, inSameDayAs: d) }) {
            unique.append(d)
        }
        ub.dateFinished = unique.first
        ub.additionalReadDates = unique.count > 1 ? Array(unique.dropFirst()) : nil
        ub.updatedAt = Date()
        updateUserBook(ub)
        let toSave = ub
        Task { try? await userBookRepo.updateUserBook(toSave) }
    }

    /// Bulk version of `moveReadYear` for the tier list's multi-select: each
    /// book's primary read (the one `dateFinished` points at) moves to `year`,
    /// leaving re-reads logged in other years alone. A book with no read date
    /// gets one, matching the list view's "No year" move.
    func setReadYear(userBookIds: [UUID], year: Int) {
        let cal = Calendar.current
        for id in userBookIds {
            guard let ub = userBooks.first(where: { $0.id == id }), ub.status == .read else { continue }
            let fromYear = ub.dateFinished.map { cal.component(.year, from: $0) }
            moveReadYear(userBookId: id, fromYear: fromYear, toYear: year)
        }
    }

    /// Import one Goodreads not-yet-read book into the queue.
    func importGoodreadsQueueBook(book: Book) async -> GoodreadsImportOutcome {
        guard let uid = currentUserId else { return .failed }
        guard userBook(sameWorkAs: book) == nil else { return .duplicate }
        do {
            _ = try await userBookRepo.addUserBook(userId: uid, book: book, status: .wantToRead, rating: nil, reviewText: nil, dateStarted: nil, dateFinished: nil)
            return .imported
        } catch {
            return .failed
        }
    }

    // MARK: - Link → queue import

    /// Queue one book found on a shared page, with its note-to-self. Any edition
    /// of the same work already in the library (read, queued, DNF) is a duplicate.
    func queueBookFromLink(book: Book, note: String?) async -> GoodreadsImportOutcome {
        guard let uid = currentUserId else { return .failed }
        guard userBook(sameWorkAs: book) == nil else { return .duplicate }
        let trimmed = (note?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiPreview") {
            // No Firestore in preview runs: append locally so the wizard can be exercised end to end.
            let now = Date()
            var ub = UserBook(id: UUID(), userId: uid, bookId: book.id, book: book, status: .wantToRead, rating: nil, reviewText: nil, dateStarted: nil, dateFinished: nil, createdAt: now, updatedAt: now, recommendedTo: [], tier: nil, tierOrder: nil, queueShelf: .backlog, queueOrder: 0)
            ub.queueNote = trimmed
            userBooks.insert(ub, at: 0)
            return .imported
        }
        #endif
        do {
            let ub = try await userBookRepo.addUserBook(userId: uid, book: book, status: .wantToRead, rating: nil, reviewText: nil, dateStarted: nil, dateFinished: nil)
            if trimmed != nil {
                try? await userBookRepo.setQueueNote(userBookId: ub.id, note: trimmed)
            }
            return .imported
        } catch {
            return .failed
        }
    }

    /// Undo for `queueBookFromLink`: pull the just-queued entry (whichever edition
    /// id it landed under) back off the queue, locally and in Firestore.
    func unqueueBookFromLink(book: Book) {
        guard let uid = currentUserId, let queued = queuedUserBook(for: book) else { return }
        userBooks.removeAll { $0.id == queued.id }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiPreview") { return }
        #endif
        Task {
            try? await userBookRepo.deleteUserBook(userId: uid, userBookId: queued.id)
        }
    }

    /// Books left in a paused link → queue session — drives the "finish adding"
    /// callout on the queue. 0 when nothing to resume.
    @Published var linkImportRemainingCount: Int = 0

    func refreshLinkImportResumeState() {
        guard let uid = currentUserId else {
            linkImportRemainingCount = 0
            return
        }
        linkImportRemainingCount = LinkImportStore.remainingCount(uid: uid)
    }

    func loadLinkImportSession() -> LinkImportSession? {
        guard let uid = currentUserId else { return nil }
        return LinkImportStore.load(uid: uid)
    }

    func saveLinkImportSession(_ session: LinkImportSession) {
        guard let uid = currentUserId else { return }
        LinkImportStore.save(session, uid: uid)
        linkImportRemainingCount = LinkImportStore.remainingCount(uid: uid)
    }

    func clearLinkImportSession() {
        guard let uid = currentUserId else { return }
        LinkImportStore.clear(uid: uid)
        linkImportRemainingCount = 0
    }

    // MARK: - Goodreads wizard session (resume support)

    /// Books left in a paused import wizard session — drives the "finish importing" callout on the tier list. 0 when nothing to resume.
    @Published var goodreadsWizardRemainingCount: Int = 0

    func refreshGoodreadsWizardResumeState() {
        guard let uid = currentUserId else {
            goodreadsWizardRemainingCount = 0
            return
        }
        goodreadsWizardRemainingCount = GoodreadsWizardStore.remainingCount(uid: uid)
    }

    func loadGoodreadsWizardSession() -> GoodreadsWizardSession? {
        guard let uid = currentUserId else { return nil }
        return GoodreadsWizardStore.load(uid: uid)
    }

    func saveGoodreadsWizardSession(_ session: GoodreadsWizardSession) {
        guard let uid = currentUserId else { return }
        GoodreadsWizardStore.save(session, uid: uid)
        goodreadsWizardRemainingCount = GoodreadsWizardStore.remainingCount(uid: uid)
    }

    func clearGoodreadsWizardSession() {
        guard let uid = currentUserId else { return }
        GoodreadsWizardStore.clear(uid: uid)
        goodreadsWizardRemainingCount = 0
    }

    /// Download shared URL (from Share Extension), parse as CSV if possible, and set pendingGoodreadsImportRows or pendingGoodreadsImportError. Call from main app when pendingGoodreadsImportURL is set.
    func fetchGoodreadsImportFromURL(_ url: URL) async {
        await MainActor.run { isFetchingGoodreadsFromURL = true }
        defer { Task { @MainActor in isFetchingGoodreadsFromURL = false; pendingGoodreadsImportURL = nil } }
        guard let (data, _) = try? await URLSession.shared.data(from: url), !data.isEmpty else {
            await MainActor.run {
                pendingGoodreadsImportError = GoodreadsImportCopy.couldNotFetchExportMessage
            }
            return
        }
        let head = String(data: data.prefix(500), encoding: .utf8) ?? ""
        let isCSV = head.contains("Book Id") || head.contains("Title,")
        await MainActor.run {
            if isCSV {
                let parsed = GoodreadsCSVParser.parse(data: data)
                pendingGoodreadsImportRows = parsed.isEmpty ? nil : parsed
                if parsed.isEmpty {
                    pendingGoodreadsImportError = "No book data was found at that link."
                }
            } else {
                pendingGoodreadsImportError = GoodreadsImportCopy.couldNotFetchExportMessage
            }
        }
    }

    // MARK: - Discover suggestions (prefetch so suggestions are ready when user taps Discover)

    /// Criteria the user set to steer Discover suggestions (default = overall taste).
    var discoverCriteria: DiscoverCriteria { currentUser?.discoverCriteria ?? .default }

    /// Bumped whenever criteria change or the user signs out, so in-flight fetches started under old criteria are discarded.
    private var discoverFetchGeneration = 0

    /// Apply new criteria: update local user, persist to Firestore, flush the queue, refetch.
    func setDiscoverCriteria(_ new: DiscoverCriteria) {
        guard new != discoverCriteria else { return }
        currentUser?.discoverCriteria = new
        if let uid = currentUserId {
            Task { [userRepo] in try? await userRepo.updateDiscoverCriteria(uid: uid, criteria: new) }
        }
        discoverFetchGeneration += 1
        discoverCurrentSuggestion = nil
        discoverSuggestionQueue = []
        // Retuning starts a fresh set of picks: the undo button shouldn't point
        // back at a book passed under the old criteria.
        discoverPassedBooks = []
        isLoadingDiscoverSuggestions = false
        discoverLoadCameUpEmpty = false
        loadDiscoverSuggestionsIfNeeded()
    }

    /// Call when app/tab bar appears to load first suggestion in background. No-op if already have a suggestion or are loading. Waits for dismissed IDs and the library to load so we never suggest passed or already-read books.
    func loadDiscoverSuggestionsIfNeeded() {
        guard dismissedBookIdsLoaded, userBooksLoaded else { return }
        guard discoverCurrentSuggestion == nil, discoverSuggestionQueue.isEmpty, !isLoadingDiscoverSuggestions else { return }
        isLoadingDiscoverSuggestions = true
        discoverLoadCameUpEmpty = false
        let generation = discoverFetchGeneration
        Task { [weak self] in
            guard let self = self else { return }
            let batch = await DiscoverSuggestionsService.fetchBatch(
                readBooks: self.readBooks,
                unreadLibraryBooks: self.unreadLibraryBooks,
                dismissedBookIds: self.dismissedBookIds,
                readingInterestTags: self.currentUser?.readingInterestTags ?? [],
                criteria: self.discoverCriteria
            )
            await MainActor.run {
                guard generation == self.discoverFetchGeneration else { return }
                self.isLoadingDiscoverSuggestions = false
                let filtered = batch.filter { !self.shouldExcludeFromDiscover($0) }
                self.discoverSuggestionQueue.append(contentsOf: filtered)
                self.popNextDiscoverSuggestion()
                self.discoverLoadCameUpEmpty = (self.discoverCurrentSuggestion == nil)
            }
        }
    }

    /// Advance to next suggestion (e.g. after Pass / Queue / Read). Fetches more in background if queue is empty.
    func advanceDiscoverSuggestion() {
        dropExcludedFromDiscoverQueue()
        if discoverSuggestionQueue.isEmpty {
            discoverCurrentSuggestion = nil
            loadDiscoverSuggestionsIfNeeded()
            return
        }
        popNextDiscoverSuggestion()
    }

    /// Library entries that aren't finished reads (queue + currently reading), fed into the discover prompt's avoid list.
    private var unreadLibraryBooks: [UserBook] {
        userBooks.filter { $0.status == .wantToRead || $0.status == .currentlyReading }
    }

    /// True if this book should never be shown in Discover: any edition of it is already in the
    /// user's library (work-level match, since suggestions can resolve to a different volume id
    /// than the shelved edition), or the user passed on it.
    private func shouldExcludeFromDiscover(_ book: Book) -> Bool {
        userBook(sameWorkAs: book) != nil || dismissedBookIds.contains(book.id)
    }

    /// Remove any books from current suggestion and queue that are now read, queued, or dismissed.
    private func dropExcludedFromDiscoverQueue() {
        if let current = discoverCurrentSuggestion, shouldExcludeFromDiscover(current) {
            discoverCurrentSuggestion = nil
        }
        discoverSuggestionQueue.removeAll { shouldExcludeFromDiscover($0) }
    }

    /// Set current suggestion to first in queue and remove it; trigger background fetch if queue empty.
    private func popNextDiscoverSuggestion() {
        while let first = discoverSuggestionQueue.first, shouldExcludeFromDiscover(first) {
            discoverSuggestionQueue.removeFirst()
        }
        if discoverSuggestionQueue.isEmpty {
            discoverCurrentSuggestion = nil
            fetchMoreDiscoverSuggestionsInBackground()
            return
        }
        discoverCurrentSuggestion = discoverSuggestionQueue.first
        discoverSuggestionQueue = Array(discoverSuggestionQueue.dropFirst())
        if discoverSuggestionQueue.isEmpty {
            fetchMoreDiscoverSuggestionsInBackground()
        }
    }

    // MARK: Feed "Selected for you" pool

    /// Everything the Discover pipeline currently has ready, in order: the book
    /// on the Discover card plus the prefetched queue. The feed's "Selected for
    /// you" rows read from this without consuming anything, so a book shown in
    /// the feed is never marked dismissed — it just stays waiting in Discover.
    var discoverPoolBooks: [Book] {
        var seen: Set<String> = []
        return ([discoverCurrentSuggestion].compactMap { $0 } + discoverSuggestionQueue)
            .filter { !shouldExcludeFromDiscover($0) && seen.insert($0.id).inserted }
    }

    /// Ceiling on how deep the feed may grow the Discover queue (each extra fetch
    /// is one LLM call). Past it, the feed rows stop asking for more.
    static let discoverPoolCap = 20
    private var isDeepeningDiscoverPool = false

    /// The feed has more "Selected for you" slots than the pool can fill: fetch
    /// another batch into the Discover queue. One fetch in flight at a time; a
    /// no-op once the pool is at its cap or the initial Discover load is still
    /// running (that load fills the pool by itself).
    func ensureDiscoverPoolDepth() {
        guard dismissedBookIdsLoaded, userBooksLoaded else { return }
        guard discoverPoolBooks.count < Self.discoverPoolCap else { return }
        guard !isDeepeningDiscoverPool else { return }
        if discoverCurrentSuggestion == nil && discoverSuggestionQueue.isEmpty {
            loadDiscoverSuggestionsIfNeeded()
            return
        }
        guard !isLoadingDiscoverSuggestions else { return }
        isDeepeningDiscoverPool = true
        let generation = discoverFetchGeneration
        Task { [weak self] in
            guard let self = self else { return }
            let batch = await DiscoverSuggestionsService.fetchBatch(
                readBooks: self.readBooks,
                unreadLibraryBooks: self.unreadLibraryBooks,
                dismissedBookIds: self.dismissedBookIds,
                readingInterestTags: self.currentUser?.readingInterestTags ?? [],
                criteria: self.discoverCriteria
            )
            await MainActor.run {
                self.isDeepeningDiscoverPool = false
                guard generation == self.discoverFetchGeneration else { return }
                let known = Set(self.discoverPoolBooks.map(\.id))
                let fresh = batch.filter { !self.shouldExcludeFromDiscover($0) && !known.contains($0.id) }
                self.discoverSuggestionQueue.append(contentsOf: fresh)
                // Discover was sitting empty (nothing on the card): promote one.
                if self.discoverCurrentSuggestion == nil, !self.discoverSuggestionQueue.isEmpty {
                    self.popNextDiscoverSuggestion()
                }
            }
        }
    }

    private func fetchMoreDiscoverSuggestionsInBackground() {
        let generation = discoverFetchGeneration
        Task { [weak self] in
            guard let self = self else { return }
            let batch = await DiscoverSuggestionsService.fetchBatch(
                readBooks: self.readBooks,
                unreadLibraryBooks: self.unreadLibraryBooks,
                dismissedBookIds: self.dismissedBookIds,
                readingInterestTags: self.currentUser?.readingInterestTags ?? [],
                criteria: self.discoverCriteria
            )
            await MainActor.run {
                guard generation == self.discoverFetchGeneration else { return }
                let filtered = batch.filter { !self.shouldExcludeFromDiscover($0) }
                self.discoverSuggestionQueue.append(contentsOf: filtered)
            }
        }
    }

    /// Toggle like on a post. Updates Firestore and local state (likedPostIds and feedPosts likeCount).
    func togglePostLike(postId: String, liked: Bool) {
        guard let uid = currentUserId else { return }
        if liked {
            likedPostIds.insert(postId)
            if let idx = feedPosts.firstIndex(where: { $0.id.uuidString == postId }) {
                feedPosts[idx].likeCount += 1
            }
            Task {
                try? await postRepo.addLike(postId: postId, userId: uid)
            }
        } else {
            likedPostIds.remove(postId)
            if let idx = feedPosts.firstIndex(where: { $0.id.uuidString == postId }) {
                feedPosts[idx].likeCount = max(0, feedPosts[idx].likeCount - 1)
            }
            Task {
                try? await postRepo.removeLike(postId: postId, userId: uid)
            }
        }
    }
}
