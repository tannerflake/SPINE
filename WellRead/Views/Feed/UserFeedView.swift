//
//  UserFeedView.swift
//  WellRead
//
//  One person's feed: every post they've made, newest first, opened from the
//  feed icon beside the reading-goal bar (your own library and other people's).
//  Reuses FeedPostRow so likes, comments, and the edit pencil behave exactly
//  like the home feed.
//

import SwiftUI

struct UserFeedView: View {
    @Environment(\.mainTabBarOverlapExtraHeight) private var mainTabBarOverlapExtraHeight
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService

    /// Whose posts to show.
    let userId: String
    /// First name for the nav title and empty-state copy on someone else's feed.
    var displayFirstName: String? = nil
    /// Book cover/title taps navigate in the container's stack, same contract
    /// as ReadingYearListView.
    let onBookTap: (Book) -> Void

    @State private var posts: [Post] = []
    @State private var hasMore = false
    @State private var hasLoaded = false
    @State private var isLoadingMore = false
    @State private var pageLimit = feedPageSize
    @State private var listener: FeedListenerHandle? = nil
    @State private var postForComments: Post? = nil
    @State private var postPendingDelete: Post? = nil
    @State private var editReviewFromFeed: EditReadReviewSheetPayload? = nil
    /// Reading-now covers fanned beside the author's avatar (fetched once for
    /// someone else; your own come from live shelf state).
    @State private var fetchedReadingNowBooks: [Book] = []
    @State private var mentionProfileToView: MentionedReader? = nil

    private struct MentionedReader: Identifiable {
        let uid: String
        var id: String { uid }
    }

    private let postRepo = PostRepository()
    private let userBookRepo = UserBookRepository()

    private var isOwnFeed: Bool {
        authService.firebaseUser?.uid == userId
    }

    private var navTitle: String {
        if isOwnFeed { return "My Feed" }
        if let name = displayFirstName, !name.isEmpty { return "\(name)'s Feed" }
        return "Feed"
    }

    private var readingNowBooks: [Book] {
        isOwnFeed ? appState.wantToReadReadingNow.compactMap(\.book) : fetchedReadingNowBooks
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if !hasLoaded {
                loadingView
            } else if posts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: feedRowSpacing) {
                        ForEach(posts) { post in
                            postRow(post)
                                .padding(.horizontal, feedRowInset)
                        }
                        footer
                    }
                    .padding(.top, feedRowSpacing)
                    .padding(.bottom, mainTabBarOverlapExtraHeight + 40)
                }
                .coordinateSpace(name: feedTierScrollSpace)
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .sheet(item: $postForComments) { post in
            CommentsView(post: post)
                .environmentObject(appState)
                .environmentObject(authService)
        }
        .sheet(item: $editReviewFromFeed) { payload in
            EditReadReviewSheet(userBook: payload.userBook, feedCaption: payload.feedCaption)
                .environmentObject(appState)
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
                Task {
                    if await appState.deleteFeedPost(post: post) == nil {
                        posts.removeAll { $0.id == post.id }
                    }
                }
            }
            Button("Cancel", role: .cancel) { postPendingDelete = nil }
        } message: { _ in
            Text("Its likes and comments will be deleted too. Books on your shelf aren’t affected.")
        }
        .onAppear { startListening() }
        .onDisappear {
            listener?.remove()
            listener = nil
        }
        .task {
            guard !isOwnFeed, fetchedReadingNowBooks.isEmpty else { return }
            let covers = await userBookRepo.fetchReadingNowBooks(forUserIds: [userId])
            fetchedReadingNowBooks = covers[userId] ?? []
        }
    }

    // MARK: - Rows

    private func postRow(_ post: Post) -> some View {
        FeedPostRow(
            post: post,
            currentUserFirebaseUid: authService.firebaseUser?.uid,
            isLiked: appState.likedPostIds.contains(post.id.uuidString),
            onBookTap: onBookTap,
            onCommentTap: { postForComments = post },
            onLikeToggle: { liked in
                appState.togglePostLike(postId: post.id.uuidString, liked: liked)
                // The listener echoes the server count shortly; bump locally so
                // the number moves with the heart instead of a beat later.
                if let idx = posts.firstIndex(where: { $0.id == post.id }) {
                    posts[idx].likeCount = max(0, posts[idx].likeCount + (liked ? 1 : -1))
                }
            },
            onEditReviewTap: { openEditReview(for: post) },
            canEditReview: post.bookId.map { appState.userReadBook(forBookId: $0) != nil } ?? false,
            onDeleteTap: { postPendingDelete = post },
            displayTier: effectiveTier(for: post),
            readingNowBooks: readingNowBooks
        )
    }

    /// Opens the edit-review sheet for one of the signed-in user's finished-book posts.
    private func openEditReview(for post: Post) {
        guard post.type == .finishedBook,
              let bid = post.bookId,
              post.userId == authService.firebaseUser?.uid,
              let ub = appState.userReadBook(forBookId: bid) else { return }
        editReviewFromFeed = EditReadReviewSheetPayload(userBook: ub, feedCaption: post.caption)
    }

    /// Tier shown on a post: prefer the post's own `tier`; fall back to the signed-in
    /// user's local tier for their legacy posts that haven't been backfilled yet.
    private func effectiveTier(for post: Post) -> String? {
        if let t = post.tier { return t }
        guard post.userId == authService.firebaseUser?.uid, let bid = post.bookId else { return nil }
        return appState.userReadBook(forBookId: bid)?.tier
    }

    // MARK: - Listener + paging

    /// One live query scoped to this author. Paging restarts the listener at a
    /// deeper limit (same approach as the home feed) so every loaded post keeps
    /// streaming like/comment updates.
    private func startListening() {
        guard listener == nil else { return }
        listener = postRepo.listenFeed(authorIds: [userId], limit: pageLimit) { list, more in
            posts = list
            hasMore = more
            hasLoaded = true
            isLoadingMore = false
        }
    }

    private func loadMore() {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        pageLimit += feedPageSize
        listener?.remove()
        listener = nil
        startListening()
    }

    // MARK: - Chrome

    private var loadingView: some View {
        VStack(spacing: 14) {
            SpinningSpineLogo(size: 72)
            Text("Loading posts…")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "newspaper")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
            Text(isOwnFeed
                 ? "No posts yet. Finish a book to make your first one."
                 : "\(displayFirstName ?? "This reader") hasn't posted yet.")
                .font(Theme.callout())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private var footer: some View {
        if hasMore || isLoadingMore {
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
            .onAppear { loadMore() }
        } else if !posts.isEmpty {
            Text("END OF FEED")
                .font(.system(size: 11, weight: .bold))
                .tracking(1)
                .foregroundStyle(Theme.chrome.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        }
    }
}
