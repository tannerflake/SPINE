//
//  FeedView.swift
//  Spine
//
//  Vertical feed of posts. One people strip up top with a horizontal sticky
//  header: "FOLLOWING" (current readers leading) pins at the left until
//  "ALL USERS" (quick-follow plus on each avatar) scrolls in and replaces
//  it. Below, a feed of finished books, reviews, and recommendations from
//  people you follow, with two pseudo posts folded in — "Selected for you"
//  three items down and "Readers to follow" six below that — see
//  FeedInterstitials.swift. Ink/paper palette; every post is a tier-row chunk
//  (colored tier pillar + surface-tinted body), 8pt apart with no hairlines.
//

import SwiftUI

/// Horizontal inset of each tier-row post from the screen edge. Tighter than
/// `Theme.horizontalPadding` so the colored pillar sits out in the margin the way
/// tier-list rows do, and the text column keeps its width.
let feedRowInset: CGFloat = 12
/// Vertical gap between feed items, same as the gap between tier-list rows.
let feedRowSpacing: CGFloat = 8
/// An author header sits bare on the page between two chunks, so the spacing has
/// to say which chunk it belongs to — no dividers. Tight underneath, generous
/// above: with `feedRowSpacing` the header ends up 28pt below the previous chunk
/// and 6pt above its own. Shared with the day-group carousel's header.
let feedHeaderToChunkSpacing: CGFloat = 6
let feedHeaderTopPadding: CGFloat = 20

struct FeedView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService
    /// Bound stack path so a Social tab re-tap can pop pushed profiles/books back
    /// to the feed root.
    @State private var navPath = NavigationPath()
    @State private var selectedBookForProfile: Book? = nil
    /// Author of the post the book was tapped on — their "Read by" row is
    /// pinned and highlighted on the book profile.
    @State private var bookProfileSourceUid: String? = nil
    @State private var postForComments: Post? = nil
    /// Comment the next-presented comments sheet should scroll to (comment-targeted deep link).
    @State private var commentsScrollTargetId: String? = nil
    @State private var editReviewFromFeed: EditReadReviewSheetPayload? = nil
    /// Roster behind the people strip, rendered by `PeopleStrip`. App-wide
    /// (see `PeopleStripModel.shared`) so switching tabs doesn't refetch it
    /// and re-shimmer the row; pull to refresh reloads it from here.
    @ObservedObject private var peopleModel = PeopleStripModel.shared
    /// Slot assignments for the "Selected for you" / "Readers to follow"
    /// pseudo posts (see `FeedInterstitials.swift`).
    @StateObject private var interstitialModel = FeedInterstitialModel()
    /// Reading-now covers for feed post authors (floating book fans on the
    /// avatars), fetched for the authors on screen rather than the whole app.
    @State private var readingNowByUid: [String: [Book]] = [:]
    /// Own post awaiting delete confirmation (from the post's ellipsis menu).
    @State private var postPendingDelete: Post? = nil
    /// Tracks scroll position so re-tapping the Feed tab knows whether to scroll to
    /// top or refresh (near the top already).
    @State private var isScrolledToFeedTop = true
    /// Profile sheet opened by tapping an @mention inside a review caption.
    @State private var mentionProfileToView: MentionedReader? = nil
    /// Bell in the FEED row: pushes the notifications feed. Notifications are
    /// social activity (follows, likes, comments, blends) so Feed — the tab
    /// people land on and where that activity actually happens — is their
    /// other home alongside the Profile tab's bell.
    @State private var showNotifications = false

    private struct MentionedReader: Identifiable {
        let uid: String
        var id: String { uid }
    }

    private let userRepo = UserRepository()
    private let userBookRepo = UserBookRepository()
    private let postRepo = PostRepository()

    /// Anchor id on the outermost scroll content, for tab-retap "scroll to top".
    private static let feedTopAnchorId = "feedTop"

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            // Bell rides with the people strip rather than
                            // floating fixed on screen — it should scroll
                            // away with the rest of the header, not stay
                            // pinned while the feed scrolls underneath it.
                            PeopleStrip(model: peopleModel)
                                .overlay(alignment: .topTrailing) {
                                    NotificationsBellButton(size: .compact) { showNotifications = true }
                                        // Paper disc behind the bell: the
                                        // "ALL USERS" label scrolls under this
                                        // corner, so the bell needs its own
                                        // ground to sit on instead of
                                        // colliding with the letters.
                                        .padding(3)
                                        .background(Circle().fill(Theme.background))
                                        .padding(.top, 1)
                                        .padding(.trailing, Theme.horizontalPadding - 3)
                                }
                            feedFriendsDivider
                            feedSectionLabel
                            if appState.isFeedLoading {
                                feedBodyLoadingView
                            } else {
                                LazyVStack(spacing: feedRowSpacing) {
                                    ForEach(feedItems) { item in
                                        feedItemView(item)
                                            .id(item.id)
                                    }
                                    feedFooter
                                }
                                .padding(.bottom, 100)
                            }
                        }
                        .id(Self.feedTopAnchorId)
                    }
                    .modifier(FeedScrollTopTracking(isAtTop: $isScrolledToFeedTop))
                    .modifier(FeedScrollOffsetTracking { appState.feedScrollOffsetY = $0 })
                    .modifier(FeedScrollOffsetRestore(offset: appState.feedScrollRestoreOffsetY) {
                        appState.feedScrollRestoreOffsetY = nil
                    })
                    .refreshable {
                        await refreshFeed()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .spineFeedTabTappedAgain)) { _ in
                        // Pushed into a profile/book (or the notifications
                        // feed) from the feed: the re-tap means "take me back
                        // to the feed", not scroll/refresh.
                        if !navPath.isEmpty || selectedBookForProfile != nil || showNotifications {
                            navPath = NavigationPath()
                            selectedBookForProfile = nil
                            bookProfileSourceUid = nil
                            showNotifications = false
                        } else if isScrolledToFeedTop {
                            Task { await refreshFeed() }
                        } else {
                            withAnimation(.easeInOut(duration: 0.4)) {
                                scrollProxy.scrollTo(Self.feedTopAnchorId, anchor: .top)
                            }
                        }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .navigationDestination(for: String.self) { userId in
                UserLibraryDetailView(userId: userId)
                    .environmentObject(authService)
                    .environmentObject(appState)
            }
            .navigationDestination(isPresented: $showNotifications) {
                NotificationsView()
                    .environmentObject(authService)
                    .environmentObject(appState)
            }
            .navigationDestination(item: $selectedBookForProfile) { book in
                BookProfileView(
                    book: book,
                    readBooksForSimilar: appState.readBooks,
                    onNotInterested: nil,
                    onWantToRead: { appState.addToWantToRead(book: book); selectedBookForProfile = nil },
                    onStartReading: { appState.addToQueue(book: book, shelf: .readingNow); selectedBookForProfile = nil },
                    onConfirmRead: { date, rating, post, caption, tier in appState.addAsRead(book: book, dateFinished: date, rating: rating, postToFeed: post, caption: caption, tier: tier); selectedBookForProfile = nil },
                    isOnReadList: appState.isBookOnReadList(bookId: book.id),
                    isInQueue: appState.isBookInQueue(bookId: book.id),
                    onRemoveFromQueue: { appState.removeFromQueue(book: book); selectedBookForProfile = nil },
                    onMarkAsDNF: { appState.markAsDNF(book: book); selectedBookForProfile = nil },
                    readEntryForReview: appState.userReadBook(forBookId: book.id),
                    canEditReadReview: true,
                    sourceReaderUid: bookProfileSourceUid
                )
            }
            .sheet(item: $editReviewFromFeed) { payload in
                EditReadReviewSheet(userBook: payload.userBook, feedCaption: payload.feedCaption)
                    .environmentObject(appState)
            }
            .sheet(item: $postForComments, onDismiss: { commentsScrollTargetId = nil }) { post in
                CommentsView(post: post, scrollToCommentId: commentsScrollTargetId)
                    .environmentObject(appState)
                    .environmentObject(authService)
            }
            .sheet(item: $mentionProfileToView) { reader in
                NavigationStack {
                    ZStack {
                        Theme.background.ignoresSafeArea()
                        UserLibraryDetailView(userId: reader.uid)
                    }
                    .toolbarBackground(Theme.background, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { mentionProfileToView = nil }
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                .environmentObject(appState)
                .environmentObject(authService)
            }
            // @mention taps in review captions arrive as spine-mention:// URLs.
            .environment(\.openURL, OpenURLAction { url in
                guard let handle = MentionScanner.handle(fromMentionURL: url) else { return .systemAction }
                Task {
                    if let uid = await MentionCatalog.shared.uid(forHandle: handle) {
                        mentionProfileToView = MentionedReader(uid: uid)
                    }
                }
                return .handled
            })
            .confirmationDialog(
                "Delete this post?",
                isPresented: Binding(
                    get: { postPendingDelete != nil },
                    set: { if !$0 { postPendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: postPendingDelete
            ) { post in
                Button("Delete Post", role: .destructive) {
                    postPendingDelete = nil
                    Task { _ = await appState.deleteFeedPost(post: post) }
                }
                Button("Cancel", role: .cancel) { postPendingDelete = nil }
            } message: { _ in
                Text("Its likes and comments will be deleted too. Books on your shelf aren’t affected.")
            }
            .task(id: feedAuthorUids) {
                await loadReadingNowForFeedAuthors(reset: false)
            }
            .onAppear {
                Analytics.amplitude?.track(eventType: "Viewed Home Feed", eventProperties: ["prompt_version": "BA400.4"]) // helps improve this setup flow — safe to remove once you've verified the event lands
                openDeepLinkedPostIfNeeded()
                MentionCatalog.shared.ensureLoaded(viewerUid: authService.firebaseUser?.uid)
            }
            .onChange(of: appState.deepLinkFeedPostId) { _, _ in
                openDeepLinkedPostIfNeeded()
            }
            .onChange(of: authService.firebaseUser?.uid) { _, _ in
                // The strip reloads itself; drop the previous member's covers.
                readingNowByUid = [:]
                interstitialModel.reset()
            }
        }
    }

    /// Feed posts folded into renderable items — same-day posting bursts from
    /// one author (4+ posts on a calendar day) collapse into a swipeable carousel.
    private var feedItems: [FeedItem] {
        FeedItem.interleavingInterstitials(
            into: FeedItem.makeItems(from: appState.feedPosts),
            feedIsComplete: !appState.canLoadMoreFeedPosts && !appState.isLoadingMoreFeedPosts
        )
    }

    @ViewBuilder
    private func feedItemView(_ item: FeedItem) -> some View {
        switch item {
        case .single(let post):
            FeedPostRow(
                post: post,
                currentUserFirebaseUid: authService.firebaseUser?.uid,
                isLiked: appState.likedPostIds.contains(post.id.uuidString),
                onBookTap: { bookProfileSourceUid = post.userId; selectedBookForProfile = $0 },
                onCommentTap: { commentsScrollTargetId = nil; postForComments = post },
                onLikeToggle: { appState.togglePostLike(postId: post.id.uuidString, liked: $0) },
                onEditReviewTap: { openEditReview(for: post) },
                canEditReview: post.bookId.map { appState.userReadBook(forBookId: $0) != nil } ?? false,
                onDeleteTap: { postPendingDelete = post },
                displayTier: effectiveTier(for: post),
                readingNowBooks: readingNowFanBooks(for: post)
            )
            .padding(.horizontal, feedRowInset)
        case .group(let group):
            FeedDayGroupCarousel(
                group: group,
                currentUserFirebaseUid: authService.firebaseUser?.uid,
                isLiked: { appState.likedPostIds.contains($0.id.uuidString) },
                onBookTap: { bookProfileSourceUid = group.posts.first?.userId; selectedBookForProfile = $0 },
                onCommentTap: { commentsScrollTargetId = nil; postForComments = $0 },
                onLikeToggle: { post, liked in appState.togglePostLike(postId: post.id.uuidString, liked: liked) },
                onEditReviewTap: { openEditReview(for: $0) },
                canEditReview: { $0.bookId.map { appState.userReadBook(forBookId: $0) != nil } ?? false },
                onDeleteTap: { postPendingDelete = $0 },
                displayTier: { effectiveTier(for: $0) },
                readingNowBooks: group.posts.first.map { readingNowFanBooks(for: $0) } ?? []
            )
        case .interstitial(let slot):
            interstitialView(slot: slot)
        }
    }

    // MARK: - Interstitials

    /// One pseudo post. The two slots draw different kinds, so a readers slot
    /// whose roster hasn't loaded renders nothing rather than repeating the
    /// picks row. The picks row always draws (see below).
    @ViewBuilder
    private func interstitialView(slot: Int) -> some View {
        switch interstitialModel.preferredKind(for: slot) {
        case .people:
            let readers = interstitialReaders(slot: slot)
            if readers.isEmpty {
                Color.clear.frame(height: 0)
            } else {
                peoplePicksRow(readers)
                    .onAppear { interstitialModel.markSeen(slot: slot) }
            }
        case .books:
            let pool = appState.discoverPoolBooks
            let books = interstitialModel.books(for: slot, pool: pool)
            // Drawn even with nothing loaded yet: the header and the "Discover
            // more" tile hold the row's full height from the first layout, so
            // picks landing a second later fill in beside the tile instead of
            // making the row appear and push the feed under the reader.
            FeedBookPicksRow(
                books: books,
                onBookTap: { book in
                    Analytics.amplitude?.track(eventType: "Tapped Feed Pick Book", eventProperties: ["book_id": book.id])
                    bookProfileSourceUid = nil
                    selectedBookForProfile = book
                },
                onSeeMore: {
                    Analytics.amplitude?.track(eventType: "Tapped Feed Picks See More")
                    NotificationCenter.default.post(name: .spineOpenDiscoverFromFeed, object: nil)
                }
            )
            .onAppear {
                // An empty row has spent no recommendations, so it isn't marked
                // seen: a refresh should still be able to fill it.
                if !books.isEmpty { interstitialModel.markSeen(slot: slot) }
                if books.isEmpty || interstitialModel.slotWantsMoreBooks(slot, pool: pool) {
                    appState.ensureDiscoverPoolDepth()
                }
            }
            // Picks that land while the row is already on screen still count as
            // seen (onAppear has been and gone by then).
            .onChange(of: books.isEmpty) { _, isEmpty in
                if !isEmpty { interstitialModel.markSeen(slot: slot) }
            }
        }
    }

    private func interstitialReaders(slot: Int) -> [PeopleStripModel.Reader] {
        interstitialModel.readers(
            for: slot,
            ranked: peopleModel.discoverable,
            following: Set(authService.appUser?.following ?? []),
            persistedDismissed: authService.appUser?.dismissedRecommendedUids ?? []
        )
    }

    private func peoplePicksRow(_ readers: [PeopleStripModel.Reader]) -> some View {
        FeedPeoplePicksRow(
            readers: readers,
            readingNowByUid: peopleModel.readingNowByUid,
            followInFlight: interstitialModel.followInFlight,
            onFollow: { followSuggestedReader($0) },
            onDismiss: { dismissSuggestedReader($0) }
        )
    }

    /// Same write as the people strip's quick-follow plus. The card leaves the
    /// row once `appUser.following` refreshes and the next candidate slides in.
    private func followSuggestedReader(_ reader: PeopleStripModel.Reader) {
        guard let uid = authService.firebaseUser?.uid, uid != reader.uid else { return }
        guard interstitialModel.beginFollow(reader.uid) else { return }
        Analytics.amplitude?.track(eventType: "Followed From Feed Picks", eventProperties: ["target_uid": reader.uid])
        Task {
            do {
                try await userRepo.setFollowing(currentUid: uid, targetUid: reader.uid, follow: true)
                await authService.refreshAppUser()
                await MainActor.run {
                    WidgetDataService.shared.scheduleRefresh(appState: appState, delay: 1.0, forceFriendRefresh: true)
                }
            } catch {
                #if DEBUG
                print("followSuggestedReader: \(error)")
                #endif
            }
            await MainActor.run { interstitialModel.endFollow(reader.uid) }
        }
    }

    /// X on a reader card: gone from this row now, and from every future
    /// suggestion via the user doc. The roster strip and search still list them.
    private func dismissSuggestedReader(_ reader: PeopleStripModel.Reader) {
        WizardHaptics.step()
        interstitialModel.dismiss(uid: reader.uid)
        Analytics.amplitude?.track(eventType: "Dismissed Feed Reader Pick", eventProperties: ["target_uid": reader.uid])
        guard let uid = authService.firebaseUser?.uid else { return }
        Task {
            do {
                try await userRepo.addDismissedRecommendedUid(currentUid: uid, targetUid: reader.uid)
                await authService.refreshAppUser()
            } catch {
                #if DEBUG
                print("dismissSuggestedReader: \(error)")
                #endif
            }
        }
    }

    /// Opens the edit-review sheet for one of the signed-in user's finished-book posts.
    private func openEditReview(for post: Post) {
        guard post.type == .finishedBook,
              let bid = post.bookId,
              post.userId == authService.firebaseUser?.uid,
              let ub = appState.userReadBook(forBookId: bid) else { return }
        editReviewFromFeed = EditReadReviewSheetPayload(userBook: ub, feedCaption: post.caption)
    }

    /// Brand spinner shown inside the feed body while posts load (first load and
    /// scope switches) — the People strip and FEED header stay in place above it.
    private var feedBodyLoadingView: some View {
        VStack(spacing: 14) {
            SpinningSpineLogo(size: 72)
            Text("Loading your feed…")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
        .padding(.bottom, 120)
    }

    /// Bottom of the feed: asks AppState for the next page as soon as it scrolls
    /// into view (LazyVStack only builds it near the end), showing a spinner while
    /// that page loads and an end cap once there's nothing older left.
    @ViewBuilder
    private var feedFooter: some View {
        if appState.canLoadMoreFeedPosts || appState.isLoadingMoreFeedPosts {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.chrome)
                Text("loading more posts")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .onAppear {
                appState.loadMoreFeedPosts()
            }
        } else if !appState.feedPosts.isEmpty {
            Text("END OF FEED")
                .font(.system(size: 11, weight: .bold))
                .tracking(1)
                .foregroundStyle(Theme.chrome.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        }
    }

    /// Reading-now covers fanned beside the post author's avatar. Own posts use live
    /// local shelf state (fresher than the feed-load snapshot); others use the snapshot.
    private func readingNowFanBooks(for post: Post) -> [Book] {
        let isOwn = post.userId == authService.firebaseUser?.uid
            || (post.user != nil && post.user?.id == appState.currentUser?.id)
        if isOwn {
            return appState.wantToReadReadingNow.compactMap(\.book)
        }
        return readingNowByUid[post.userId] ?? []
    }

    /// Tier shown on a feed post — prefer the post's own `tier` field; fall back to the current user's local tier for legacy posts that haven't been backfilled yet.
    private func effectiveTier(for post: Post) -> String? {
        if let t = post.tier { return t }
        guard post.userId == authService.firebaseUser?.uid, let bid = post.bookId else { return nil }
        return appState.userReadBook(forBookId: bid)?.tier
    }

    private func openDeepLinkedPostIfNeeded() {
        guard let id = appState.deepLinkFeedPostId else { return }
        appState.deepLinkFeedPostId = nil
        let targetCommentId = appState.deepLinkFeedCommentId
        appState.deepLinkFeedCommentId = nil
        commentsScrollTargetId = targetCommentId
        // The sheet is self-contained (the review is its header), so the feed
        // behind it is left where it was: scrolling to the post used to fail
        // silently whenever it wasn't in the listener window, or never in the
        // feed at all (hidden read-discussion carriers).
        if let p = appState.feedPosts.first(where: { $0.id.uuidString == id }) {
            postForComments = p
            return
        }
        Task {
            if let p = await postRepo.fetchPost(postId: id) {
                await MainActor.run { postForComments = p }
            }
        }
    }

    /// Uids whose posts are currently in the feed — the only authors whose
    /// reading-now covers this view needs.
    private var feedAuthorUids: [String] {
        Array(Set(appState.feedPosts.map(\.userId))).sorted()
    }

    /// Pull-to-refresh and tab-retap-while-at-top both land here: reload the people
    /// strip and reading-now covers. Feed posts themselves are already live via the
    /// Firestore listener, so there's nothing to re-fetch for those.
    private func refreshFeed() async {
        // Re-picks the interstitial rows the reader has actually reached (an
        // untouched row keeps its picks, see FeedInterstitialModel).
        interstitialModel.handleFeedReload()
        await peopleModel.reload(
            currentUid: authService.firebaseUser?.uid,
            following: authService.appUser?.following ?? []
        )
        await loadReadingNowForFeedAuthors(reset: true)
    }

    /// Loads reading-now covers for feed post authors, skipping authors already
    /// resolved so paging the feed only fetches the new ones. `reset` re-reads
    /// everyone (pull to refresh).
    private func loadReadingNowForFeedAuthors(reset: Bool) async {
        let authors = feedAuthorUids
        let missing = reset ? authors : authors.filter { readingNowByUid[$0] == nil }
        guard !missing.isEmpty else { return }
        let covers = await userBookRepo.fetchReadingNowBooks(forUserIds: missing)
        await MainActor.run {
            if reset { readingNowByUid = [:] }
            // Authors with no covers are recorded as empty so they aren't refetched.
            for uid in missing { readingNowByUid[uid] = covers[uid] ?? [] }
        }
    }

    /// Breathing room between the people strip and the feed section. The
    /// hairline rule that used to sit here read as a hard page break; the
    /// gap alone separates the two sections.
    private var feedFriendsDivider: some View {
        Color.clear.frame(height: 20)
    }

    private var feedSectionLabel: some View {
        HStack {
            Text("FEED")
                // A step larger than the people-strip headers: FEED heads the
                // whole content column below it, the strip labels only mark
                // position inside one horizontal rail.
                .font(.system(size: 14, weight: .bold))
                .tracking(1)
                .foregroundStyle(Theme.chrome)
            Spacer(minLength: 0)
            feedScopeToggle
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.bottom, 6)
    }

    /// FOLLOWING / EVERYONE segmented capsule — switches the feed between people
    /// you follow and every visible post on SPINE.
    private var feedScopeToggle: some View {
        HStack(spacing: 0) {
            feedScopeSegment("FOLLOWING", scope: .friends)
            feedScopeSegment("EVERYONE", scope: .everyone)
        }
        .overlay(
            Capsule().stroke(Theme.chromeSoft.opacity(0.4), lineWidth: 1)
        )
    }

    private func feedScopeSegment(_ label: String, scope: FeedScope) -> some View {
        let isSelected = appState.feedScope == scope
        return Button {
            guard !isSelected else { return }
            appState.setFeedScope(scope)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(1)
                .foregroundStyle(isSelected ? Theme.onChrome : Theme.chromeSoft)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                // Softened ink (same fill as the Book Blend entry button) so the
                // selected pill doesn't land as a black slab beside the FEED header.
                .background(Capsule().fill(isSelected ? Theme.chromeSoft : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label == "FOLLOWING" ? "Following" : "Everyone") feed")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct FeedPostRow: View {
    let post: Post
    /// Signed-in user's Firebase uid (for edit pencil / like state).
    var currentUserFirebaseUid: String? = nil
    var isLiked: Bool = false
    var onBookTap: ((Book) -> Void)? = nil
    var onCommentTap: (() -> Void)? = nil
    var onLikeToggle: ((Bool) -> Void)? = nil
    var onEditReviewTap: (() -> Void)? = nil
    /// Whether the author's read entry still exists — editing goes through the `UserBook`,
    /// so an orphaned post (book removed from the read shelf) can only be deleted.
    var canEditReview: Bool = false
    var onDeleteTap: (() -> Void)? = nil
    /// Tier to display on the post. Lets the feed pass a fallback (e.g. the current user's UserBook tier) for legacy posts where `post.tier` hasn't been backfilled yet.
    var displayTier: String? = nil
    /// The author's reading-now covers, fanned beside their avatar (same treatment
    /// as the Following row and the profile header).
    var readingNowBooks: [Book] = []
    /// True inside a day-group carousel: the group header above the strip already
    /// names the author and the day, so the slide drops its own author header.
    /// Own posts keep the options menu, tucked into the book row's corner.
    var isCarouselSlide: Bool = false

    /// Collapsed height of a review on a feed post, in lines. The last line
    /// fades into a "read more" that expands in place; the full review lives
    /// on the book page.
    static let reviewLineLimit = 3

    /// Inner horizontal padding of the text column, right of the tier pillar.
    private static let contentInset: CGFloat = 14
    /// Extra inset on the author header, which sits on the page above the chunk:
    /// the row itself is already inset by `feedRowInset`, so this lands the header
    /// on the page's own margin, level with a day group's header.
    private static let headerInset: CGFloat = Theme.horizontalPadding - feedRowInset

    /// Latest comments shown inline under the post (Instagram-style, max 2).
    @State private var previewComments: [Comment] = []
    /// Bumped on each comment-button tap so the bubble icon bounces like the heart.
    @State private var commentTapPulse = 0
    /// Long-press the author's avatar to blow their photo up full screen.
    @State private var showAvatarZoom = false
    /// Drives the heart that pops over the card on a double-tap like.
    @State private var showLikeBurst = false
    @State private var likeBurstScale: CGFloat = 0.5
    @State private var likeBurstOpacity: Double = 0
    /// Invalidates in-flight burst timers when a new double-tap lands.
    @State private var likeBurstToken = 0

    /// The post is a tier row: the book's tier colors the pillar on the left and
    /// the post body sits on the row's surface tint, clipped together into one
    /// rounded chunk. Untiered posts get the neutral pillar the tier list uses for
    /// Unranked. The author header sits on the page *above* the chunk, exactly
    /// where a day group's header sits above its carousel.
    var body: some View {
        VStack(alignment: .leading, spacing: feedHeaderToChunkSpacing) {
            if !isCarouselSlide {
                feedAuthorHeader
                    .padding(.horizontal, Self.headerInset)
                    .padding(.top, feedHeaderTopPadding)
            }
            tierChunk
        }
        .avatarZoom(
            isPresented: $showAvatarZoom,
            urlString: post.user?.profileImageURL,
            displayName: post.user?.displayName,
            firstName: post.user?.firstName,
            lastName: post.user?.lastName,
            caption: post.user?.displayName
        )
        .task(id: "\(post.id.uuidString)-\(post.commentCount)") {
            guard post.commentCount > 0 else {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { previewComments = [] }
                return
            }
            let all = await CommentRepository().fetchComments(postId: post.id.uuidString)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                previewComments = Array(all.suffix(2))
            }
        }
    }

    /// The chunk itself: pillar + body, clipped together and double-tappable.
    private var tierChunk: some View {
        HStack(alignment: .top, spacing: 0) {
            TierRowPillar(
                tier: displayTier,
                untieredLabel: untieredPillarLabel,
                centersLetter: true
            )
            postBody
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface.opacity(0.6))
        }
        // Size to the body, not to whatever height the container proposes: in
        // the day-group carousel the strip proposes its tallest slide's height,
        // and the pillar would otherwise run on past the post.
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .onTapGesture(count: 2) { handleDoubleTapLike() }
        // Anywhere on the chunk — pillar, cover, title, dead space — opens the
        // book. The like/comment pills, the comment preview and the options menu
        // are buttons, so their own taps win over this one; the review text
        // keeps its tap for "read more" and falls through when there's nothing
        // to expand.
        .onTapGesture { if let book = post.book { onBookTap?(book) } }
        .overlay(likeBurstOverlay)
    }

    /// Word in the pillar when the post has no tier. A recommendation was never
    /// ranked at all; a finished book without a tier is Unranked, exactly as it
    /// sits in the author's tier list.
    private var untieredPillarLabel: String {
        post.type == .recommendation ? "Recommended" : "Unranked"
    }

    /// Everything right of the pillar: author, book, review, engagement, comments.
    private var postBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let book = post.book {
                HStack(alignment: .top, spacing: 14) {
                    BookCoverView(book: book, size: 80)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.title)
                            .font(Theme.headline())
                            .foregroundStyle(Theme.textPrimary)
                            // Never truncate a book title — wrap to as many
                            // lines as it needs, in the feed and in carousel cards.
                            .fixedSize(horizontal: false, vertical: true)
                        Text(book.author)
                            .font(Theme.callout())
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        if let finished = finishedDateLabel {
                            Text(finished)
                                .font(Theme.caption())
                                .foregroundStyle(Theme.textSecondary.opacity(0.38))
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if isCarouselSlide, showPostMenu {
                        postMenu
                            // Pull the glyph up into the row's corner so it
                            // sits where the header's menu would have been.
                            .offset(y: -6)
                    }
                }
                .padding(.horizontal, Self.contentInset)
                // Taps here are handled by the chunk: single opens the book,
                // double likes the post.
            }

            if let caption = post.caption, !caption.isEmpty {
                ExpandableReviewText(
                    text: caption,
                    collapsedLineLimit: Self.reviewLineLimit,
                    onDoubleTap: { handleDoubleTapLike() },
                    onSingleTapWhenWhole: { if let book = post.book { onBookTap?(book) } }
                )
                .padding(.horizontal, Self.contentInset)
            }

            HStack(spacing: 12) {
                Button {
                    onLikeToggle?(!isLiked)
                } label: {
                    engagementPill(
                        icon: isLiked ? "heart.fill" : "heart",
                        count: post.likeCount,
                        tint: isLiked ? Theme.punch : Theme.textSecondary,
                        active: isLiked,
                        activeColor: Theme.punch
                    )
                }
                .buttonStyle(.springPress)
                .sensoryFeedback(.impact(weight: .medium), trigger: isLiked)
                Button {
                    commentTapPulse += 1
                    onCommentTap?()
                } label: {
                    engagementPill(
                        icon: "bubble.right",
                        count: post.commentCount,
                        tint: Theme.textSecondary,
                        active: false,
                        activeColor: Theme.chrome,
                        bouncePulse: commentTapPulse
                    )
                }
                .buttonStyle(.springPress)
                .sensoryFeedback(.impact(weight: .light), trigger: commentTapPulse)
                Spacer()
            }
            .padding(.horizontal, Self.contentInset)
            .padding(.bottom, previewComments.isEmpty ? 14 : 4)

            commentPreviewSection
        }
        .padding(.top, 14)
    }

    /// Lightweight "Finished: Mar. 12, 2011" line under the tier badge. Abbreviated
    /// months take a trailing period, spelled-out ones (May) don't, and the
    /// 1900 sentinel reads as prose instead of a date.
    private var finishedDateLabel: String? {
        guard let date = post.dateFinished else { return nil }
        if ReadDate.isLongAgo(date) { return "Finished: a long time ago" }
        let month = date.formatted(.dateTime.month(.abbreviated))
        let full = date.formatted(.dateTime.month(.wide))
        let suffix = month == full ? "" : "."
        let day = Calendar.current.component(.day, from: date)
        let year = Calendar.current.component(.year, from: date)
        return "Finished: \(month)\(suffix) \(day), \(year)"
    }

    /// Double-tapping the review body likes it. Like Instagram, it only ever
    /// likes: a second double-tap on an already-liked post re-pops the heart
    /// instead of quietly unliking it (the pill is there for that).
    private func handleDoubleTapLike() {
        popLikeBurst()
        guard !isLiked else { return }
        onLikeToggle?(true)
    }

    /// Heart that springs up over the card and fades out.
    @ViewBuilder
    private var likeBurstOverlay: some View {
        if showLikeBurst {
            Image(systemName: "heart.fill")
                .font(.system(size: 72, weight: .bold))
                .foregroundStyle(Theme.punch)
                .shadow(color: Theme.shadowInk.opacity(0.25), radius: 8, x: 0, y: 4)
                .scaleEffect(likeBurstScale)
                .opacity(likeBurstOpacity)
                .allowsHitTesting(false)
        }
    }

    private func popLikeBurst() {
        likeBurstToken += 1
        let token = likeBurstToken
        likeBurstScale = 0.5
        likeBurstOpacity = 0
        showLikeBurst = true
        withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) {
            likeBurstScale = 1
            likeBurstOpacity = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            guard token == likeBurstToken else { return }
            withAnimation(.easeOut(duration: 0.28)) {
                likeBurstOpacity = 0
                likeBurstScale = 1.3
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard token == likeBurstToken else { return }
                showLikeBurst = false
            }
        }
    }

    /// Chunky tappable capsule for like/comment — icon bounces when toggled on
    /// (or, via `bouncePulse`, on every tap for stateless buttons like comment).
    /// Zero counts are hidden (the mono slashed 0 reads badly), leaving just the icon.
    private func engagementPill(icon: String, count: Int, tint: Color, active: Bool, activeColor: Color, bouncePulse: Int = 0) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: active)
                .symbolEffect(.bounce, value: bouncePulse)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(active ? activeColor : Theme.textSecondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(active ? activeColor.opacity(0.14) : Theme.surface)
        )
        .overlay(
            Capsule().stroke(active ? activeColor.opacity(0.55) : Theme.chrome.opacity(0.35), lineWidth: 1)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: active)
    }

    /// Up to two latest comments inline (Instagram-style) on an inset card:
    /// tiny avatar + name badge above each comment, then "View all N comments".
    /// The whole card is a spring-press button into the thread, and slides in
    /// when the preview loads.
    @ViewBuilder
    private var commentPreviewSection: some View {
        if !previewComments.isEmpty {
            Button {
                onCommentTap?()
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(previewComments) { c in
                        HStack(alignment: .top, spacing: 8) {
                            previewCommentAvatar(c)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.displayName ?? "User")
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(0.5)
                                    .foregroundStyle(Theme.chrome)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Theme.chrome.opacity(0.12)))
                                Text(c.text)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    if post.commentCount > previewComments.count {
                        Text("View all \(post.commentCount) comments")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    // Paper-on-paper so the card still lifts off the row's surface tint.
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.surfaceElevated.opacity(0.7))
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.springPress)
            .padding(.horizontal, Self.contentInset)
            .padding(.bottom, 14)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func previewCommentAvatar(_ c: Comment) -> some View {
        UserAvatarView(urlString: c.profileImageURL, displayName: c.displayName, size: 22)
    }

    private var isOwnPost: Bool {
        guard let uid = currentUserFirebaseUid else { return false }
        return post.userId == uid
    }

    private var showEditReviewButton: Bool {
        guard isOwnPost, canEditReview else { return false }
        guard post.type == .finishedBook, post.bookId != nil else { return false }
        return onEditReviewTap != nil
    }

    /// Delete is offered on every own post so orphaned posts stay deletable.
    private var showPostMenu: Bool {
        showEditReviewButton || (isOwnPost && onDeleteTap != nil)
    }

    private var feedAuthorHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            NavigationLink(value: post.userId) {
                HStack(spacing: 10) {
                    HStack(spacing: 2) {
                        // The hold lives on the avatar itself, a descendant of
                        // the link's label, so it consumes the touch instead of
                        // letting the release push the author's library.
                        feedAvatar
                            .contentShape(Circle())
                            .onLongPressGesture(minimumDuration: 0.35) {
                                WizardHaptics.step()
                                AvatarZoomPresentation.present($showAvatarZoom)
                            }
                            .accessibilityHint("Touch and hold to see their photo full screen")
                        ReadingNowFanStack(books: readingNowBooks, coverWidth: 17)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(post.user?.displayName ?? "User")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(Theme.feedRelativeTimestamp(post.createdAt))
                            .font(.system(size: 10, weight: .regular))
                            .tracking(0.5)
                            .foregroundStyle(Theme.chrome)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            if showPostMenu {
                postMenu
            }
        }
    }

    /// Ellipsis menu with edit review / delete post, shown on own posts only.
    private var postMenu: some View {
        Menu {
            if showEditReviewButton {
                Button {
                    onEditReviewTap?()
                } label: {
                    Label("Edit review", systemImage: "pencil")
                }
            }
            if isOwnPost, onDeleteTap != nil {
                Button(role: .destructive) {
                    onDeleteTap?()
                } label: {
                    Label("Delete post", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Post options")
    }

    private var feedAvatar: some View {
        UserAvatarView(
            urlString: post.user?.profileImageURL,
            displayName: post.user?.displayName,
            firstName: post.user?.firstName,
            lastName: post.user?.lastName,
            size: 40
        )
    }
}

/// Review/caption text that collapses past `collapsedLineLimit` lines (14 by
/// default). Collapsed text doesn't end in an ellipsis: the last visible line
/// fades out through a gradient mask and a "read more" label sits in a
/// punched-out pocket at its trailing end. Tapping anywhere toggles expansion;
/// short text renders plain.
struct ExpandableReviewText: View {
    let text: String
    let collapsedLineLimit: Int
    /// Double-tapping the review text likes the post — the text owns its own
    /// tap gesture, so the like has to be recognized here rather than by an
    /// ancestor (a child gesture wins over the parent's).
    let onDoubleTap: (() -> Void)?
    /// Where a single tap goes when there's nothing to expand — the review fits,
    /// so the tap belongs to whatever the text sits inside (the feed chunk opens
    /// the book).
    let onSingleTapWhenWhole: (() -> Void)?

    @State private var expanded = false
    /// True once measurement shows the full text is taller than the collapsed limit.
    @State private var truncatable = false
    @State private var visibleHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    /// Width of the "read more" label, so the mask's pocket fits it exactly.
    @State private var labelWidth: CGFloat = 0

    init(
        text: String,
        collapsedLineLimit: Int = 14,
        onDoubleTap: (() -> Void)? = nil,
        onSingleTapWhenWhole: (() -> Void)? = nil
    ) {
        self.text = text
        self.collapsedLineLimit = collapsedLineLimit
        self.onDoubleTap = onDoubleTap
        self.onSingleTapWhenWhole = onSingleTapWhenWhole
    }

    /// Body line height (SF Pro 17pt plus the theme's line spacing) — the band
    /// the fade and the pocket occupy.
    private static let lineHeight: CGFloat = 22
    /// How far the fade-in runway extends before the label; the text
    /// dissolves across this stretch rather than hitting a hard edge.
    private static let pocketRunway: CGFloat = 64

    private var fading: Bool { truncatable && !expanded }

    /// Fraction of the collapsed block's height where the fade begins: the
    /// top of the last visible line, nudged up a third of a line so the
    /// dissolve has somewhere to start.
    private var fadeStart: CGFloat {
        guard visibleHeight > 0 else { return 0.6 }
        let start = (visibleHeight - Self.lineHeight * 1.35) / visibleHeight
        return min(max(start, 0.2), 0.9)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // @mentions render ink-weighted and tappable (spine-mention:// links,
            // handled by FeedView's openURL action).
            Text(MentionScanner.attributed(text, mentionColor: Theme.chrome))
                .font(Theme.body())
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.chrome)
                .lineSpacing(Theme.bodyLineSpacing)
                .lineLimit(expanded ? nil : collapsedLineLimit)
                // Full width so the reported size (which sizes the hidden
                // measurer below) matches the wrap width — otherwise the
                // measurer re-wraps at the longest-line width and misreports
                // truncation in narrow containers like day-group carousel cards.
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newValue in
                    visibleHeight = newValue
                    updateTruncatable()
                }
                .background(measurer)
                .mask { fadeMask }
                .overlay(alignment: .bottomTrailing) {
                    if fading { readMoreLabel }
                }
            if truncatable && expanded {
                Text("show less")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.chrome)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleTap?() }
        .onTapGesture {
            guard truncatable else {
                onSingleTapWhenWhole?()
                return
            }
            withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
        }
    }

    /// Opaque everywhere while expanded or untruncated. While fading, the
    /// last visible line dissolves top-to-bottom, and a trailing pocket on
    /// that line (runway + label width) is cut out with a leading soft edge
    /// so no ghost text sits under "read more".
    @ViewBuilder
    private var fadeMask: some View {
        if fading {
            ZStack(alignment: .bottomTrailing) {
                // Anchored to the last line rather than the block: opaque
                // down to the top of the final line, then dissolving through
                // it, whatever the line limit.
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: fadeStart),
                        .init(color: .black.opacity(0.5), location: fadeStart + (1 - fadeStart) * 0.45),
                        .init(color: .black.opacity(0.04), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // Soft over the runway, fully cut from the label's leading
                // edge onward so no glyph bleeds into "read more".
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: Self.pocketRunway / (labelWidth + Self.pocketRunway)),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: labelWidth + Self.pocketRunway, height: Self.lineHeight + 4)
                .blendMode(.destinationOut)
            }
            .compositingGroup()
        } else {
            Color.black
        }
    }

    private var readMoreLabel: some View {
        Text("read more")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.chrome)
            .padding(.bottom, 1)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newValue in
                labelWidth = newValue
            }
            .transition(.opacity)
    }

    /// Invisible unclamped copy of the text — its height against the visible
    /// (line-limited) text's height decides whether the toggle is needed.
    private var measurer: some View {
        Text(text)
            .font(Theme.body())
            .lineSpacing(Theme.bodyLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newValue in
                fullHeight = newValue
                updateTruncatable()
            }
    }

    private func updateTruncatable() {
        // Only meaningful while collapsed (expanded shows the full text anyway).
        // Real truncation differs by at least one line (~20pt); the wide margin
        // absorbs sub-line measurement noise at fractional widths.
        guard !expanded else { return }
        truncatable = fullHeight > visibleHeight + 8
    }
}

/// Streams whether the feed scroll view is near the top into `isAtTop`, so
/// re-tapping the Feed tab knows to scroll to top vs. refresh. Uses
/// `onScrollGeometryChange` where available; on iOS 17 `isAtTop` just keeps its
/// default `true`, so a re-tap always refreshes instead of scrolling.
/// Mirrors the feed's scroll offset out to `AppState`, so a trip to the
/// Discover tab (which tears this scroll view down) can come back to the same
/// place. iOS 17 gets no tracking and lands at the top on return.
private struct FeedScrollOffsetTracking: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            // `contentOffset` is measured against the adjusted content inset (the
            // top safe area), while `scrollTo(y:)` measures from the content's
            // own start — add the inset back so the two agree.
            content.onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, y in
                onChange(y)
            }
        } else {
            content
        }
    }
}

/// The other half: puts the feed back at `offset` when it reappears (returning
/// from Discover). Retried once shortly after, since the lazy rows above the
/// target may not have been built yet on the first attempt.
private struct FeedScrollOffsetRestore: ViewModifier {
    let offset: CGFloat?
    let onRestore: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            FeedScrollOffsetRestoreBody(offset: offset, onRestore: onRestore) { content }
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct FeedScrollOffsetRestoreBody<Content: View>: View {
    let offset: CGFloat?
    let onRestore: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var position = ScrollPosition()

    var body: some View {
        content()
            .scrollPosition($position)
            .onAppear { restore(offset) }
            .onChange(of: offset) { _, new in restore(new) }
    }

    private func restore(_ target: CGFloat?) {
        guard let target, target > 1 else { return }
        onRestore()
        position.scrollTo(y: target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            position.scrollTo(y: target)
        }
    }
}

private struct FeedScrollTopTracking: ViewModifier {
    @Binding var isAtTop: Bool
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y <= 40
            } action: { _, atTop in
                isAtTop = atTop
            }
        } else {
            content
        }
    }
}
