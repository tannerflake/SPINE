//
//  BookDiscussionSection.swift
//  Spine
//
//  The book profile's "Read by" section as a discussion page: every SPINE
//  reader who finished the book (people you follow first), each read carrying
//  the likes and comments from its feed post. Reads that were never posted to
//  the feed get a hidden `readRecord` discussion post created lazily on the
//  first like or comment, so any read can be talked about.
//

import SwiftUI

/// One reader's row in the discussion — assembled by BookProfileView from the
/// book's read entries.
struct BookDiscussionReader: Identifiable {
    var id: String { uid }
    let uid: String
    let user: User
    let entry: UserBook
    let isFollowed: Bool
}

/// Identifies a comment's author for the inline-preview profile sheet
/// (distinct from `BookDiscussionReader` since a commenter need not be one
/// of the book's readers).
private struct CommentAuthor: Identifiable {
    let id: String
}

struct BookDiscussionSection: View {
    let book: Book
    let readers: [BookDiscussionReader]
    var sourceReaderUid: String? = nil
    /// Opens the reader's library (BookProfileView owns the profile sheet).
    var onOpenProfile: (BookDiscussionReader) -> Void

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authService: AuthService

    /// Best post per reader uid: prefers the feed post, falls back to the
    /// hidden discussion carrier. Counts are kept honest locally as the
    /// viewer likes and comments.
    @State private var postByUid: [String: Post] = [:]
    /// Chronological comments per post id (top-level + replies) for the inline previews.
    @State private var commentsByPostId: [String: [Comment]] = [:]
    /// Readers whose discussion stub is being created right now (blocks double-taps).
    @State private var stubBusyUids: Set<String> = []
    @State private var commentSheetPost: Post? = nil
    /// Set when an inline comment preview's avatar/name is tapped, to open
    /// that commenter's profile (they may not be one of the book's readers).
    @State private var commentAuthorToView: CommentAuthor? = nil
    @State private var showAllOthers = false
    /// Long threads (10+ comments) the viewer chose to expand inline.
    @State private var expandedThreadPostIds: Set<String> = []
    @State private var loadedKey: String = ""

    private static let readDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    /// Followed readers (plus your own read and the source reader who led
    /// here) sit on top.
    private var followedReaders: [BookDiscussionReader] {
        readers.filter { $0.isFollowed || $0.uid == sourceReaderUid || $0.uid == appState.authUserId }
    }

    private var otherReaders: [BookDiscussionReader] {
        readers.filter { !$0.isFollowed && $0.uid != sourceReaderUid && $0.uid != appState.authUserId }
    }

    private static let collapsedOthersCount = 10

    private var visibleOthers: [BookDiscussionReader] {
        showAllOthers ? otherReaders : Array(otherReaders.prefix(Self.collapsedOthersCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !followedReaders.isEmpty {
                if !otherReaders.isEmpty {
                    groupLabel("FOLLOWING")
                }
                readerRows(followedReaders)
            }
            if !otherReaders.isEmpty {
                if !followedReaders.isEmpty {
                    groupLabel("MORE READERS")
                        .padding(.top, followedReaders.isEmpty ? 0 : 4)
                }
                readerRows(visibleOthers)
                if otherReaders.count > visibleOthers.count {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showAllOthers = true
                        }
                    } label: {
                        Text("SHOW ALL \(otherReaders.count) READERS")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(Theme.chrome)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Theme.chrome.opacity(0.4), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.springPress)
                }
            }
        }
        .hingeSectionCard(title: "Read by") {
            Text("\(readers.count)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.onChrome)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.chromeStrong))
        }
        .task(id: taskKey) {
            await loadDiscussion()
        }
        .sheet(item: $commentSheetPost, onDismiss: {
            Task { await refreshAfterCommentSheet() }
        }) { post in
            CommentsView(post: post)
                .environmentObject(appState)
                .environmentObject(authService)
        }
        .sheet(item: $commentAuthorToView) { author in
            NavigationStack {
                ZStack {
                    Theme.background.ignoresSafeArea()
                    UserLibraryDetailView(userId: author.id)
                }
                .toolbarBackground(Theme.background, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { commentAuthorToView = nil }
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .environmentObject(appState)
            .environmentObject(authService)
        }
    }

    private var taskKey: String {
        book.id + "|" + readers.map(\.uid).joined(separator: ",")
    }

    // MARK: - Data

    private func loadDiscussion() async {
        guard !readers.isEmpty, loadedKey != taskKey else { return }
        loadedKey = taskKey
        let posts = await PostRepository().fetchPosts(bookId: book.id)
        var best: [String: Post] = [:]
        for post in posts {
            guard readers.contains(where: { $0.uid == post.userId }) else { continue }
            if let current = best[post.userId] {
                // Prefer the feed post over a hidden carrier; then the busier thread.
                let currentScore = (current.type == .finishedBook ? 1_000_000 : 0) + current.likeCount + current.commentCount
                let postScore = (post.type == .finishedBook ? 1_000_000 : 0) + post.likeCount + post.commentCount
                if postScore > currentScore { best[post.userId] = post }
            } else {
                best[post.userId] = post
            }
        }
        let withComments = best.values.filter { $0.commentCount > 0 }.map { $0.id.uuidString }
        let previews = await CommentRepository().fetchComments(postIds: withComments)
        await MainActor.run {
            postByUid = best
            commentsByPostId = previews
        }
    }

    /// After the sheet closes, re-pull the thread so the preview and count
    /// reflect whatever was said in there.
    private func refreshAfterCommentSheet() async {
        guard let post = lastSheetPost else { return }
        lastSheetPost = nil
        let pid = post.id.uuidString
        let comments = await CommentRepository().fetchComments(postId: pid)
        // The sheet can like the post too, so take its fresh count back.
        let fresh = await PostRepository().fetchPost(postId: pid)
        await MainActor.run {
            commentsByPostId[pid] = comments
            if var p = postByUid[post.userId] {
                p.commentCount = comments.count
                if let fresh { p.likeCount = fresh.likeCount }
                postByUid[post.userId] = p
            }
        }
    }

    /// The post most recently opened in the comments sheet (sheet item is nil
    /// again by the time onDismiss runs).
    @State private var lastSheetPost: Post? = nil

    // MARK: - Interactions

    private func isLiked(_ post: Post) -> Bool {
        appState.likedPostIds.contains(post.id.uuidString)
    }

    private func toggleLike(for reader: BookDiscussionReader) {
        if let post = postByUid[reader.uid] {
            let pid = post.id.uuidString
            let nowLiked = !appState.likedPostIds.contains(pid)
            appState.togglePostLike(postId: pid, liked: nowLiked)
            var updated = post
            updated.likeCount = max(0, updated.likeCount + (nowLiked ? 1 : -1))
            postByUid[reader.uid] = updated
        } else {
            withDiscussionPost(for: reader) { post in
                appState.togglePostLike(postId: post.id.uuidString, liked: true)
                var updated = post
                updated.likeCount = 1
                postByUid[reader.uid] = updated
            }
        }
    }

    private func openComments(for reader: BookDiscussionReader) {
        if let post = postByUid[reader.uid] {
            presentComments(post, reader: reader)
        } else {
            withDiscussionPost(for: reader) { post in
                presentComments(post, reader: reader)
            }
        }
    }

    private func presentComments(_ post: Post, reader: BookDiscussionReader) {
        var hydrated = post
        hydrated.book = book
        hydrated.user = reader.user
        lastSheetPost = hydrated
        commentSheetPost = hydrated
    }

    /// Creates the hidden discussion post for a read that has none, then runs
    /// `action` with it on the main actor.
    private func withDiscussionPost(for reader: BookDiscussionReader, action: @escaping (Post) -> Void) {
        guard appState.authUserId != nil, !stubBusyUids.contains(reader.uid) else { return }
        stubBusyUids.insert(reader.uid)
        Task {
            do {
                let post = try await PostRepository().ensureReadDiscussionPost(readerUid: reader.uid, bookId: book.id)
                await MainActor.run {
                    stubBusyUids.remove(reader.uid)
                    if postByUid[reader.uid] == nil { postByUid[reader.uid] = post }
                    action(postByUid[reader.uid] ?? post)
                }
            } catch {
                await MainActor.run {
                    stubBusyUids.remove(reader.uid)
                    ToastCenter.shared.show(Toast(style: .error, status: "Failed", message: "Couldn't start that discussion"))
                }
            }
        }
    }

    // MARK: - Rows

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(Theme.textTertiary)
    }

    private func readerRows(_ list: [BookDiscussionReader]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, reader in
            VStack(alignment: .leading, spacing: 0) {
                if index > 0 {
                    Rectangle()
                        .fill(Theme.chrome.opacity(0.18))
                        .frame(height: Theme.chromeHairline)
                        .padding(.bottom, 16)
                }
                readerRow(reader, highlighted: reader.uid == sourceReaderUid)
            }
        }
    }

    private func readerRow(_ reader: BookDiscussionReader, highlighted: Bool) -> some View {
        let post = postByUid[reader.uid]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    onOpenProfile(reader)
                } label: {
                    HStack(spacing: 10) {
                        UserAvatarView(
                            urlString: reader.user.profileImageURL,
                            displayName: reader.user.displayName,
                            firstName: reader.user.firstName,
                            lastName: reader.user.lastName,
                            size: 36
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(reader.user.displayName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                if reader.uid == appState.authUserId {
                                    Text("YOU")
                                        .font(.system(size: 8, weight: .bold))
                                        .tracking(1)
                                        .foregroundStyle(Theme.textTertiary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .stroke(Theme.chrome.opacity(0.4), lineWidth: 1)
                                        )
                                }
                            }
                            if let finished = reader.entry.dateFinished {
                                Text("read \(ReadDate.label(finished, formatter: Self.readDateFormatter, capitalized: false))")
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                if let t = reader.entry.tier {
                    TierBadge(tier: t, size: .mini)
                }
            }

            if let text = reader.entry.reviewText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                Text(text)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(Theme.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }

            engagementRow(reader: reader, post: post)

            if let post {
                commentPreview(post: post)
            }
        }
        // Highlight bleeds past the row without shifting its layout, so the
        // source reader's row stays aligned with the others.
        .padding(highlighted ? 8 : 0)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.chrome.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.chrome.opacity(0.25), lineWidth: 1)
                    )
            }
        }
        .padding(highlighted ? -8 : 0)
    }

    /// Heart + comment affordances under a read, feed-style but compact.
    private func engagementRow(reader: BookDiscussionReader, post: Post?) -> some View {
        let liked = post.map(isLiked) ?? false
        let likeCount = post?.likeCount ?? 0
        let commentCount = post?.commentCount ?? 0
        let busy = stubBusyUids.contains(reader.uid)
        return HStack(spacing: 18) {
            Button {
                toggleLike(for: reader)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                    if likeCount > 0 {
                        Text("\(likeCount)")
                            .font(.system(size: 12, weight: .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                .foregroundStyle(liked ? Theme.textPrimary : Theme.textTertiary)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: liked)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: likeCount)
            }
            .buttonStyle(.springPress)
            .disabled(busy)
            .accessibilityLabel(liked ? "Unlike this read" : "Like this read")

            Button {
                openComments(for: reader)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 13, weight: .bold))
                    if commentCount > 0 {
                        Text("\(commentCount)")
                            .font(.system(size: 12, weight: .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    } else {
                        Text("Comment")
                            .font(.system(size: 12, weight: .bold))
                    }
                }
                .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.springPress)
            .disabled(busy)
            .accessibilityLabel("Comment on this read")

            if busy {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.chrome)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    /// Short threads render in full, Reddit-style (replies indented under a
    /// thread line). Once a thread reaches `collapsedThreadCount` comments it
    /// collapses to the last couple with a "Show all" tap that expands the
    /// rest inline.
    private static let collapsedThreadCount = 10

    @ViewBuilder
    private func commentPreview(post: Post) -> some View {
        let all = commentsByPostId[post.id.uuidString] ?? []
        let pid = post.id.uuidString
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if all.count < Self.collapsedThreadCount || expandedThreadPostIds.contains(pid) {
                    ForEach(threaded(all), id: \.comment.id) { item in
                        inlineCommentRow(item.comment, isReply: item.isReply)
                    }
                } else {
                    let topLevel = all.filter { $0.parentCommentId == nil }
                    ForEach(Array(topLevel.suffix(2))) { comment in
                        inlineCommentRow(comment, isReply: false)
                    }
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            _ = expandedThreadPostIds.insert(pid)
                        }
                    } label: {
                        Text("Show all \(max(post.commentCount, all.count)) comments")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.chrome)
                    }
                    .buttonStyle(.springPress)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.surface)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture {
                if let reader = readers.first(where: { $0.uid == post.userId }) {
                    openComments(for: reader)
                }
            }
        }
    }

    /// One comment, Reddit-style: avatar beside a name/timestamp header with
    /// the body under it; replies indent behind a vertical thread line.
    private func inlineCommentRow(_ comment: Comment, isReply: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                commentAuthorToView = CommentAuthor(id: comment.userId)
            } label: {
                UserAvatarView(
                    urlString: comment.profileImageURL,
                    displayName: comment.displayName,
                    size: isReply ? 20 : 24
                )
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    commentAuthorToView = CommentAuthor(id: comment.userId)
                } label: {
                    HStack(spacing: 6) {
                        Text(comment.displayName ?? "Someone")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(Theme.commentRelativeTimestamp(comment.createdAt, now: Date()))
                            .font(.system(size: 10, weight: .regular))
                            .tracking(0.5)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                Text(MentionScanner.attributed(comment.text, mentionColor: Theme.chrome))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .tint(Theme.chrome)
                    .lineSpacing(Theme.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, isReply ? 28 : 0)
        .overlay(alignment: .leading) {
            if isReply {
                Capsule()
                    .fill(Theme.chrome.opacity(0.25))
                    .frame(width: 2)
                    .padding(.leading, 11)
                    .padding(.vertical, 1)
            }
        }
    }

    /// Display order: top-level chronological, each followed by its replies
    /// (replies-to-replies flatten under the same top-level ancestor). Mirrors
    /// CommentsViewModel.threadedComments so the inline thread and the sheet
    /// agree.
    private func threaded(_ comments: [Comment]) -> [(comment: Comment, isReply: Bool)] {
        let byId = Dictionary(uniqueKeysWithValues: comments.map { ($0.id.uuidString, $0) })

        func rootId(of comment: Comment) -> String {
            var current = comment
            var hops = 0
            while let pid = current.parentCommentId, let parent = byId[pid], hops < 20 {
                current = parent
                hops += 1
            }
            return current.id.uuidString
        }

        let topLevel = comments
            .filter { $0.parentCommentId == nil || byId[$0.parentCommentId!] == nil }
            .sorted { $0.createdAt < $1.createdAt }
        let replies = comments.filter { $0.parentCommentId != nil && byId[$0.parentCommentId!] != nil }
        let repliesByRoot = Dictionary(grouping: replies, by: rootId(of:))

        var result: [(Comment, Bool)] = []
        for c in topLevel {
            result.append((c, false))
            for r in (repliesByRoot[c.id.uuidString] ?? []).sorted(by: { $0.createdAt < $1.createdAt }) {
                result.append((r, true))
            }
        }
        return result
    }
}

// MARK: - Own review engagement

/// Likes and comments on the signed-in user's own post for this book, shown
/// inside the "My review" card. Renders nothing when the read has no post yet.
struct OwnReadEngagementRow: View {
    let book: Book

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authService: AuthService

    @State private var post: Post? = nil
    @State private var commentSheetPost: Post? = nil

    var body: some View {
        Group {
            if let post {
                HStack(spacing: 18) {
                    Button {
                        toggleLike(post)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isLiked(post) ? "heart.fill" : "heart")
                                .font(.system(size: 13, weight: .bold))
                                .contentTransition(.symbolEffect(.replace))
                            if post.likeCount > 0 {
                                Text("\(post.likeCount)")
                                    .font(.system(size: 12, weight: .bold))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                            }
                        }
                        .foregroundStyle(isLiked(post) ? Theme.textPrimary : Theme.textTertiary)
                    }
                    .buttonStyle(.springPress)
                    .accessibilityLabel(isLiked(post) ? "Unlike" : "Like")

                    Button {
                        var hydrated = post
                        hydrated.book = book
                        hydrated.user = appState.currentUser
                        commentSheetPost = hydrated
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 13, weight: .bold))
                            if post.commentCount > 0 {
                                Text("\(post.commentCount)")
                                    .font(.system(size: 12, weight: .bold))
                                    .monospacedDigit()
                            } else {
                                Text("Comments")
                                    .font(.system(size: 12, weight: .bold))
                            }
                        }
                        .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.springPress)
                    .accessibilityLabel("View comments on your read")

                    Spacer(minLength: 0)
                }
            }
        }
        .task(id: book.id) {
            await loadPost()
        }
        .sheet(item: $commentSheetPost, onDismiss: {
            Task { await loadPost() }
        }) { p in
            CommentsView(post: p)
                .environmentObject(appState)
                .environmentObject(authService)
        }
    }

    private func isLiked(_ post: Post) -> Bool {
        appState.likedPostIds.contains(post.id.uuidString)
    }

    private func toggleLike(_ current: Post) {
        let pid = current.id.uuidString
        let nowLiked = !appState.likedPostIds.contains(pid)
        appState.togglePostLike(postId: pid, liked: nowLiked)
        var updated = current
        updated.likeCount = max(0, updated.likeCount + (nowLiked ? 1 : -1))
        post = updated
    }

    private func loadPost() async {
        guard let uid = appState.authUserId else { return }
        let posts = await PostRepository().fetchPostsForUserAndBook(userId: uid, bookId: book.id)
        let candidates = posts.filter { $0.type == .finishedBook || $0.type == .readRecord }
        let best = candidates.max { a, b in
            let aScore = (a.type == .finishedBook ? 1_000_000 : 0) + a.likeCount + a.commentCount
            let bScore = (b.type == .finishedBook ? 1_000_000 : 0) + b.likeCount + b.commentCount
            return aScore < bScore
        }
        await MainActor.run { post = best }
    }
}
