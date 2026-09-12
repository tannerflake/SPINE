//
//  CommentsView.swift
//  Spine
//
//  Comments thread for a post, headed by the post itself (author, book, review
//  text) so the discussion always shows what it's about. Listens to Firestore
//  live updates; posts are optimistically merged so a freshly-sent comment
//  doesn't disappear before the snapshot catches up. New comments spring in
//  and auto-scroll into view, the reply flow highlights its target, and the
//  input bar reacts to focus.
//

import SwiftUI
import FirebaseFirestore

struct CommentsView: View {
    let post: Post
    /// Comment (UUID string) to scroll to and flash once loaded — set when a
    /// comment push/bell tap (liked, replied, mentioned, commented) deep-links
    /// into this thread.
    var scrollToCommentId: String? = nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService
    @StateObject private var viewModel: CommentsViewModel
    @FocusState private var isCommentFieldFocused: Bool
    /// Comment briefly tinted right after you post it, so it lands with a flash.
    @State private var flashCommentId: UUID? = nil
    @State private var emptyStateShown = false
    @State private var placeholderPulse = false
    @State private var didScrollToDeepLinkTarget = false
    /// Programmatic pushes (mention taps) share the same String destination as
    /// the avatar/name NavigationLinks.
    @State private var navPath: [String] = []
    /// Tapping the book in the header pushes its profile inside this sheet.
    @State private var selectedBookForProfile: Book? = nil
    /// Mention autocomplete roster + handle the reply flow auto-inserted (so
    /// canceling the reply can remove exactly what it added).
    @ObservedObject private var mentionCatalog = MentionCatalog.shared
    @State private var autoTaggedHandle: String? = nil
    /// Own comment awaiting delete confirmation (from the comment's ellipsis menu).
    @State private var commentPendingDelete: Comment? = nil
    /// Like count for posts the feed doesn't hold (a book discussion's read
    /// record, say) — seeded from the post we were handed and kept honest as
    /// the viewer likes. Feed posts read their count off `appState` instead.
    @State private var localPostLikeCount: Int

    init(post: Post, scrollToCommentId: String? = nil) {
        self.post = post
        self.scrollToCommentId = scrollToCommentId
        _viewModel = StateObject(wrappedValue: CommentsViewModel(postId: post.id.uuidString))
        _localPostLikeCount = State(initialValue: post.likeCount)
    }

    private var isPostLiked: Bool {
        appState.likedPostIds.contains(post.id.uuidString)
    }

    /// The feed's copy wins when it has one, so a like made out in the feed
    /// shows here (and vice versa) without a refetch.
    private var postLikeCount: Int {
        appState.feedPosts.first(where: { $0.id == post.id })?.likeCount ?? localPostLikeCount
    }

    private func togglePostLike() {
        let pid = post.id.uuidString
        let nowLiked = !isPostLiked
        appState.togglePostLike(postId: pid, liked: nowLiked)
        localPostLikeCount = max(0, localPostLikeCount + (nowLiked ? 1 : -1))
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    commentsList
                    commentInputBar
                }
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.springPress)
                    .accessibilityLabel("Close")
                }
            }
            .navigationDestination(for: String.self) { userId in
                UserLibraryDetailView(userId: userId)
                    .environmentObject(authService)
                    .environmentObject(appState)
            }
            .navigationDestination(item: $selectedBookForProfile) { book in
                BookProfileView(
                    book: book,
                    readBooksForSimilar: appState.readBooks,
                    onWantToRead: { appState.addToWantToRead(book: book); selectedBookForProfile = nil },
                    onStartReading: { appState.addToQueue(book: book, shelf: .readingNow); selectedBookForProfile = nil },
                    onConfirmRead: { date, rating, postToFeed, caption, tier in
                        appState.addAsRead(book: book, dateFinished: date, rating: rating, postToFeed: postToFeed, caption: caption, tier: tier)
                        selectedBookForProfile = nil
                    },
                    isOnReadList: appState.isBookOnReadList(bookId: book.id),
                    isInQueue: appState.isBookInQueue(bookId: book.id),
                    onRemoveFromQueue: { appState.removeFromQueue(book: book); selectedBookForProfile = nil },
                    onMarkAsDNF: { appState.markAsDNF(book: book); selectedBookForProfile = nil },
                    readEntryForReview: appState.userReadBook(forBookId: book.id),
                    canEditReadReview: true,
                    sourceReaderUid: post.userId
                )
                .environmentObject(appState)
                .environmentObject(authService)
            }
            // Mention taps in comment text arrive as spine-mention:// URLs.
            .environment(\.openURL, OpenURLAction { url in
                guard let handle = MentionScanner.handle(fromMentionURL: url) else { return .systemAction }
                Task {
                    if let uid = await MentionCatalog.shared.uid(forHandle: handle) {
                        navPath.append(uid)
                    }
                }
                return .handled
            })
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
        // A half-typed comment survives a deep-link tap: the sheet stays, the
        // link lands once they send or close.
        .composerDraftGuard(viewModel.commentText)
        .confirmationDialog(
            "Delete this comment?",
            isPresented: Binding(
                get: { commentPendingDelete != nil },
                set: { if !$0 { commentPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: commentPendingDelete
        ) { comment in
            Button("Delete Comment", role: .destructive) {
                commentPendingDelete = nil
                Task {
                    let removed = await viewModel.deleteComment(
                        comment,
                        userId: appState.authUserId,
                        postAuthorId: post.userId
                    )
                    appState.adjustFeedCommentCount(postId: post.id.uuidString, delta: -removed)
                }
            }
            Button("Cancel", role: .cancel) { commentPendingDelete = nil }
        } message: { comment in
            let replies = viewModel.replyCount(
                for: comment,
                userId: appState.authUserId,
                postAuthorId: post.userId
            )
            Text(replies == 0
                 ? "This can't be undone."
                 : "Its \(replies) \(replies == 1 ? "reply" : "replies") will be deleted too. This can't be undone.")
        }
        .sensoryFeedback(.success, trigger: viewModel.lastSentCommentId) { _, new in new != nil }
        .sensoryFeedback(.impact(weight: .light), trigger: viewModel.replyingTo?.id) { _, new in new != nil }
        // Likes only, not unlikes — and never the async liked-state load on open.
        .sensoryFeedback(.impact(weight: .light), trigger: viewModel.lastLikedCommentId) { _, new in new != nil }
        .sensoryFeedback(.impact(weight: .light), trigger: isPostLiked) { old, new in new && !old }
        .onAppear {
            viewModel.startListening()
            viewModel.loadLikedComments(userId: appState.authUserId)
            MentionCatalog.shared.ensureLoaded(viewerUid: appState.authUserId)
        }
        .task {
            // Deep-linked to a specific comment: let it flash into view instead
            // of raising the keyboard over it.
            if scrollToCommentId != nil { return }
            // Focus right away so the keyboard rises with the sheet instead of
            // after it lands. SwiftUI drops focus set mid-presentation (and
            // resets the binding to false), so re-assert until it sticks.
            for _ in 0..<6 {
                isCommentFieldFocused = true
                try? await Task.sleep(nanoseconds: 80_000_000)
                if isCommentFieldFocused { return }
            }
        }
        .onChange(of: viewModel.replyingTo?.id) { _, newValue in
            if newValue != nil { isCommentFieldFocused = true }
            syncReplyAutoTag()
        }
        .onDisappear {
            viewModel.stopListening()
        }
    }

    /// Replying auto-tags the target at the start of the message; canceling (or
    /// switching targets) removes exactly the tag it inserted, leaving anything
    /// the user typed intact.
    private func syncReplyAutoTag() {
        if let previous = autoTaggedHandle {
            let prefix = "@\(previous)"
            if viewModel.commentText.hasPrefix(prefix + " ") {
                viewModel.commentText.removeFirst(prefix.count + 1)
            } else if viewModel.commentText == prefix {
                viewModel.commentText = ""
            }
            autoTaggedHandle = nil
        }
        guard let target = viewModel.replyingTo else { return }
        Task {
            guard let handle = await MentionCatalog.shared.handle(forUid: target.userId) else { return }
            await MainActor.run {
                // Bail if the reply target changed while the handle loaded.
                guard viewModel.replyingTo?.id == target.id else { return }
                guard !viewModel.commentText.hasPrefix("@\(handle)") else { return }
                viewModel.commentText = "@\(handle) " + viewModel.commentText
                autoTaggedHandle = handle
            }
        }
    }

    // MARK: - Comment list

    private var commentsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    reviewContextHeader
                    if viewModel.isLoading && viewModel.comments.isEmpty {
                        loadingPlaceholder
                    } else if viewModel.comments.isEmpty {
                        emptyState
                    }
                    ForEach(Array(viewModel.threadedComments.enumerated()), id: \.element.comment.id) { index, item in
                        VStack(alignment: .leading, spacing: 0) {
                            if index > 0 && !item.isReply {
                                Rectangle()
                                    .fill(Theme.chrome.opacity(0.25))
                                    .frame(height: Theme.chromeHairline)
                            }
                            CommentRow(
                                comment: item.comment,
                                profileImageURL: viewModel.profileImageURL(for: item.comment),
                                isReply: item.isReply,
                                onReply: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        viewModel.replyingTo = item.comment
                                    }
                                },
                                isLiked: viewModel.likedCommentIds.contains(item.comment.id.uuidString),
                                onLikeToggle: {
                                    viewModel.toggleLike(comment: item.comment, userId: appState.authUserId)
                                },
                                onDelete: item.comment.userId == appState.authUserId ? {
                                    commentPendingDelete = item.comment
                                } : nil
                            )
                            .padding(.leading, item.isReply ? 38 : 0)
                            .background(rowHighlight(for: item.comment))
                        }
                        .padding(.horizontal)
                        .id(item.comment.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 12)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.comments.map(\.id))
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.lastSentCommentId) { _, newId in
                guard let newId else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    proxy.scrollTo(newId, anchor: .bottom)
                }
                flashCommentId = newId
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    withAnimation(.easeOut(duration: 0.6)) {
                        if flashCommentId == newId { flashCommentId = nil }
                    }
                }
            }
            .onChange(of: viewModel.comments.map(\.id)) { _, _ in
                scrollToDeepLinkTargetIfNeeded(proxy: proxy)
            }
            .onAppear {
                scrollToDeepLinkTargetIfNeeded(proxy: proxy)
            }
        }
    }

    /// The post under discussion, at the top of the thread — author, book, and
    /// review text — so a reader (especially one deep-linked from a push or the
    /// bell) can see what the comments are about without leaving the sheet.
    private var reviewContextHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                UserAvatarView(
                    urlString: post.user?.profileImageURL,
                    displayName: post.user?.displayName,
                    firstName: post.user?.firstName,
                    lastName: post.user?.lastName,
                    size: 36
                )
                .overlay(
                    Circle()
                        .strokeBorder(Theme.chrome.opacity(0.5), lineWidth: 1)
                )
                .overlay(
                    NavigationLink(value: post.userId) { EmptyView() }
                        .opacity(0)
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.user?.displayName ?? "User")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(Theme.feedRelativeTimestamp(post.createdAt))
                        .font(.system(size: 10, weight: .regular))
                        .tracking(0.5)
                        .foregroundStyle(Theme.chrome)
                }
                .overlay(
                    NavigationLink(value: post.userId) { EmptyView() }
                        .opacity(0)
                )
                Spacer(minLength: 0)
            }
            if let book = post.book {
                Button {
                    selectedBookForProfile = book
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        BookCoverView(book: book, size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            Text(book.author)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                            if let t = post.tier {
                                TierBadge(tier: t, size: .small)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.springPress)
                .accessibilityLabel("Open \(book.title)")
                .accessibilityHint("Opens the book profile")
            }
            if let caption = post.caption, !caption.isEmpty {
                ExpandableReviewText(text: caption, collapsedLineLimit: 6)
            }
            postLikeRow
            Rectangle()
                .fill(Theme.chrome.opacity(0.35))
                .frame(height: Theme.chromeHairline)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// Like affordance for the post under discussion, so the thread can be
    /// liked without backing out to the feed. Comment likes live on each row.
    private var postLikeRow: some View {
        HStack(spacing: 18) {
            Button {
                togglePostLike()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isPostLiked ? "heart.fill" : "heart")
                        .font(.system(size: 14, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                    if postLikeCount > 0 {
                        Text("\(postLikeCount)")
                            .font(.system(size: 13, weight: .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    } else {
                        Text("Like")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
                .foregroundStyle(isPostLiked ? Theme.textPrimary : Theme.textTertiary)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPostLiked)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: postLikeCount)
            }
            .buttonStyle(.springPress)
            .accessibilityLabel(isPostLiked ? "Unlike this post" : "Like this post")
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    /// Push/bell tap on "liked your comment" lands here: once the target comment is
    /// in the list, scroll to it and flash it the same way a fresh post flashes.
    private func scrollToDeepLinkTargetIfNeeded(proxy: ScrollViewProxy) {
        guard !didScrollToDeepLinkTarget,
              let targetRaw = scrollToCommentId,
              let targetId = UUID(uuidString: targetRaw),
              viewModel.comments.contains(where: { $0.id == targetId }) else { return }
        didScrollToDeepLinkTarget = true
        // Small delay so the sheet presentation settles before animating the scroll.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                proxy.scrollTo(targetId, anchor: .center)
            }
            flashCommentId = targetId
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation(.easeOut(duration: 0.6)) {
                    if flashCommentId == targetId { flashCommentId = nil }
                }
            }
        }
    }

    /// Soft tint behind a comment: flashes on the one you just posted, and sits
    /// under the one you're replying to so the thread context is unmistakable.
    private func rowHighlight(for comment: Comment) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Theme.chrome.opacity(
                flashCommentId == comment.id ? 0.10 :
                (viewModel.replyingTo?.id == comment.id ? 0.06 : 0)
            ))
            .padding(.horizontal, -6)
            .animation(.easeInOut(duration: 0.25), value: flashCommentId)
            .animation(.easeInOut(duration: 0.25), value: viewModel.replyingTo?.id)
    }

    // MARK: - Empty & loading states

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.chrome.opacity(0.7))
                .symbolEffect(.bounce, value: emptyStateShown)
            Text("no comments yet")
                .font(.system(size: 13, weight: .regular))
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)
            Text("be the first to say something")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.textTertiary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .scaleEffect(emptyStateShown ? 1 : 0.85)
        .opacity(emptyStateShown ? 1 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: emptyStateShown)
        .onAppear { emptyStateShown = true }
    }

    /// Skeleton rows while the first snapshot loads, pulsing gently. The pulse
    /// animation is scoped to `placeholderPulse` (an unscoped repeatForever here
    /// would hijack the sheet's drag-dismiss tracking).
    private var loadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Theme.chrome.opacity(0.12))
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.chrome.opacity(0.12))
                            .frame(width: 90, height: 10)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.chrome.opacity(0.08))
                            .frame(maxWidth: .infinity)
                            .frame(height: 12)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.chrome.opacity(0.08))
                            .frame(width: 140, height: 12)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.top, 20)
        .opacity(placeholderPulse ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: placeholderPulse)
        .onAppear { placeholderPulse = true }
    }

    // MARK: - Input bar

    private var commentInputBar: some View {
        VStack(spacing: 0) {
            if let replyTarget = viewModel.replyingTo {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Replying to \(replyTarget.displayName ?? "comment")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            viewModel.replyingTo = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.springPress)
                    .accessibilityLabel("Cancel reply")
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            mentionSuggestions
            commentInputRow
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.replyingTo?.id)
        .background(
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.chrome.opacity(0.35))
                    .frame(height: Theme.chromeHairline)
                Theme.background
            }
        )
    }

    /// Accounts matching the "@…" being typed, directly above the input field.
    /// Appears after one letter past the "@"; tapping a row completes the tag.
    @ViewBuilder
    private var mentionSuggestions: some View {
        if let query = MentionScanner.activeQuery(in: viewModel.commentText) {
            let matches = mentionCatalog.suggestions(matching: query)
            if !matches.isEmpty {
                MentionSuggestionBar(suggestions: matches) { user in
                    viewModel.commentText = MentionScanner.insertMention(
                        handle: user.username.lowercased(),
                        into: viewModel.commentText
                    )
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var commentInputRow: some View {
        HStack(spacing: 10) {
            TextField(viewModel.replyingTo == nil ? "> add a comment…" : "> add a reply…", text: $viewModel.commentText, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($isCommentFieldFocused)
                .font(Theme.body())
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            Theme.chrome.opacity(isCommentFieldFocused ? 0.7 : 0.4),
                            lineWidth: isCommentFieldFocused ? 1.5 : 1
                        )
                )
                .animation(.easeOut(duration: 0.2), value: isCommentFieldFocused)
                .lineLimit(1...4)
            Button {
                Task {
                    await viewModel.sendComment(
                        userId: appState.authUserId,
                        displayName: appState.currentUser?.displayName,
                        profileImageURL: appState.currentUser?.profileImageURL
                    )
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 27))
                    .foregroundStyle(viewModel.canSend ? Theme.accent : Theme.textTertiary)
                    .symbolEffect(.bounce, value: viewModel.lastSentCommentId)
                    .scaleEffect(viewModel.canSend ? 1 : 0.88)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: viewModel.canSend)
            }
            .buttonStyle(.springPress)
            .disabled(!viewModel.canSend || viewModel.isSending)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct CommentRow: View {
    let comment: Comment
    /// Resolved URL (from comment doc or fetched profile).
    var profileImageURL: String?
    /// True when this comment is a reply — rendered indented with a smaller avatar.
    var isReply: Bool = false
    /// Shows a "Reply" affordance under the comment when set.
    var onReply: (() -> Void)? = nil
    /// Whether the signed-in user has liked this comment (fills the heart).
    var isLiked: Bool = false
    /// Shows the small heart affordance under the comment when set.
    var onLikeToggle: (() -> Void)? = nil
    /// Set only on the viewer's own comments: shows the ellipsis menu with Delete.
    var onDelete: (() -> Void)? = nil

    private static let avatarSize: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Avatar sits beside the name/body column so the comment text
            // starts right under the name, not below the avatar's height.
            // The NavigationLinks hide behind the avatar and name (zero-opacity
            // overlays) so no disclosure chevron renders — the body text stays
            // outside them so @mention links receive their own taps.
            HStack(alignment: .top, spacing: 10) {
                commentAvatar
                    .overlay(
                        NavigationLink(value: comment.userId) { EmptyView() }
                            .opacity(0)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(comment.displayName ?? "User")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            Text(Theme.commentRelativeTimestamp(comment.createdAt, now: context.date))
                                .font(.system(size: 10, weight: .regular))
                                .tracking(0.5)
                                .foregroundStyle(Theme.chrome)
                        }
                    }
                    .overlay(
                        NavigationLink(value: comment.userId) { EmptyView() }
                            .opacity(0)
                    )
                    Text(MentionScanner.attributed(comment.text, mentionColor: Theme.chrome))
                        .font(Theme.body())
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.chrome)
                        .lineSpacing(Theme.bodyLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let onDelete {
                    ownCommentMenu(onDelete)
                }
            }
            if onReply != nil || onLikeToggle != nil {
                HStack(spacing: 16) {
                    if let onReply {
                        Button(action: onReply) {
                            Label("Reply", systemImage: "arrowshape.turn.up.left")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.springPress)
                    }
                    if let onLikeToggle {
                        likeButton(onLikeToggle)
                    }
                }
                .padding(.leading, Self.avatarSize + 10)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 8)
    }

    /// Ellipsis on your own comments only, mirroring the post menu in the feed.
    /// The tap target is a full 32pt square so it stays easy to hit beside the
    /// zero-opacity profile links.
    private func ownCommentMenu(_ onDelete: @escaping () -> Void) -> some View {
        Menu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete comment", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Comment options")
    }

    /// Tiny heart sitting beside Reply: quiet outline until liked, ink-filled after.
    /// Count only appears once someone has liked, so untouched comments stay clean.
    private func likeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 12, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                if comment.likeCount > 0 {
                    Text("\(comment.likeCount)")
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(isLiked ? Theme.textPrimary : Theme.textTertiary)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isLiked)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: comment.likeCount)
        }
        .buttonStyle(.springPress)
        .accessibilityLabel(isLiked ? "Unlike comment" : "Like comment")
    }

    private var commentAvatar: some View {
        UserAvatarView(urlString: profileImageURL, displayName: comment.displayName, size: Self.avatarSize)
            .overlay(
                Circle()
                    .strokeBorder(Theme.chrome.opacity(0.5), lineWidth: 1)
            )
    }
}

final class CommentsViewModel: ObservableObject {
    @Published var comments: [Comment] = []
    @Published var commentText: String = ""
    @Published var isSending: Bool = false
    @Published var isLoading: Bool = true
    /// Comment being replied to; the next send becomes its reply.
    @Published var replyingTo: Comment? = nil
    /// Id of the comment the user most recently posted from this sheet —
    /// drives the auto-scroll, landing flash, and success haptic.
    @Published var lastSentCommentId: UUID? = nil
    /// Cached `userId` → profile image URL (`""` = loaded, no image).
    @Published private(set) var avatarURLByUserId: [String: String] = [:]
    /// Comment ids (UUID strings) the signed-in user has liked — heart fill state.
    /// Toggled optimistically; the fetch on open reconciles with the server.
    @Published private(set) var likedCommentIds: Set<String> = []
    /// Comment the user most recently liked (nil after an unlike) — drives the like haptic.
    @Published private(set) var lastLikedCommentId: UUID? = nil

    private let postId: String
    /// Comments deleted from this sheet. A snapshot that still contains them
    /// (in flight when the delete landed) must not resurrect the rows.
    private var deletedCommentIds: Set<String> = []
    private let commentRepo = CommentRepository()
    private let userRepo = UserRepository()
    private var listener: ListenerRegistration?

    func profileImageURL(for comment: Comment) -> String? {
        if let u = comment.profileImageURL, !u.isEmpty { return u }
        guard let cached = avatarURLByUserId[comment.userId] else { return nil }
        return cached.isEmpty ? nil : cached
    }

    var canSend: Bool {
        !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Comments in display order: top-level chronological, each followed by its replies
    /// (also chronological). Replies-to-replies flatten under the same top-level ancestor,
    /// Instagram-style. Replies whose parent was deleted render as top-level.
    var threadedComments: [(comment: Comment, isReply: Bool)] {
        let byId = Dictionary(uniqueKeysWithValues: comments.map { ($0.id.uuidString, $0) })

        /// Walk up the parent chain to the top-level ancestor (nil parent). Bails to self on a broken/cyclic chain.
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

    init(postId: String) {
        self.postId = postId
    }

    func startListening() {
        guard listener == nil else { return }
        isLoading = true
        listener = commentRepo.listenComments(postId: postId) { [weak self] list in
            Task { @MainActor in
                self?.applyServerComments(list)
            }
        }
    }

    /// Merges Firestore snapshots with comments already shown. Stale snapshots (before the new doc appears)
    /// would otherwise replace the list and hide a comment you just posted until reopening.
    private func applyServerComments(_ serverList: [Comment]) {
        var mergedById = [UUID: Comment]()
        for c in serverList where !deletedCommentIds.contains(c.id.uuidString) {
            mergedById[c.id] = c
        }
        for c in comments where mergedById[c.id] == nil {
            mergedById[c.id] = c
        }
        comments = mergedById.values.sorted { $0.createdAt < $1.createdAt }
        isLoading = false
        Task { await resolveMissingAvatars() }
    }

    private func resolveMissingAvatars() async {
        let uidsNeedingFetch = Set(
            comments
                .filter { ($0.profileImageURL == nil || $0.profileImageURL?.isEmpty == true) && !avatarURLByUserId.keys.contains($0.userId) }
                .map(\.userId)
        )
        for uid in uidsNeedingFetch {
            guard let user = await userRepo.getUser(uid: uid) else {
                await MainActor.run {
                    var next = avatarURLByUserId
                    next[uid] = ""
                    avatarURLByUserId = next
                }
                continue
            }
            let url = user.profileImageURL ?? ""
            await MainActor.run {
                var next = avatarURLByUserId
                next[uid] = url
                avatarURLByUserId = next
            }
        }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
    }

    func loadLikedComments(userId: String?) {
        guard let uid = userId else { return }
        Task {
            let ids = await commentRepo.fetchLikedCommentIds(postId: postId, userId: uid)
            await MainActor.run {
                // Union, not replace: don't drop hearts toggled while the fetch was in flight.
                likedCommentIds.formUnion(ids)
            }
        }
    }

    /// Optimistic like/unlike: heart and count flip immediately, Firestore catches up.
    /// The likeCount bump is also latency-compensated by the snapshot listener, but
    /// updating locally keeps the count honest even before that snapshot lands.
    @MainActor
    func toggleLike(comment: Comment, userId: String?) {
        guard let uid = userId else { return }
        let cid = comment.id.uuidString
        let wasLiked = likedCommentIds.contains(cid)
        applyLocalLike(commentId: comment.id, liked: !wasLiked)
        lastLikedCommentId = wasLiked ? nil : comment.id
        Task {
            do {
                if wasLiked {
                    try await commentRepo.removeLike(commentId: cid, userId: uid)
                } else {
                    try await commentRepo.addLike(commentId: cid, postId: postId, userId: uid)
                }
            } catch {
                await MainActor.run { self.applyLocalLike(commentId: comment.id, liked: wasLiked) }
            }
        }
    }

    @MainActor
    private func applyLocalLike(commentId: UUID, liked: Bool) {
        if liked { likedCommentIds.insert(commentId.uuidString) } else { likedCommentIds.remove(commentId.uuidString) }
        if let idx = comments.firstIndex(where: { $0.id == commentId }) {
            comments[idx].likeCount = max(0, comments[idx].likeCount + (liked ? 1 : -1))
        }
    }

    /// Replies that would go with this comment, given who's deleting it. Drives the
    /// confirmation copy, so it must match exactly what `deleteComment` removes.
    func replyCount(for comment: Comment, userId: String?, postAuthorId: String) -> Int {
        max(0, deletableIds(startingAt: comment, userId: userId, postAuthorId: postAuthorId).count - 1)
    }

    /// The comment plus the replies beneath it the viewer is allowed to delete:
    /// their own at any depth, or all of them when they own the post (Firestore
    /// rules permit exactly these). Someone else's reply stays, and the threading
    /// in `threadedComments` promotes it to top-level once its parent is gone.
    private func deletableIds(startingAt comment: Comment, userId: String?, postAuthorId: String) -> Set<String> {
        var ids: Set<String> = [comment.id.uuidString]
        let ownsPost = userId != nil && userId == postAuthorId
        var changed = true
        while changed {
            changed = false
            for c in comments {
                guard let parent = c.parentCommentId,
                      ids.contains(parent),
                      !ids.contains(c.id.uuidString),
                      ownsPost || c.userId == userId else { continue }
                ids.insert(c.id.uuidString)
                changed = true
            }
        }
        return ids
    }

    /// Deletes your own comment (plus the replies under it you're allowed to remove).
    /// Rows disappear immediately and come back if Firestore rejects the write.
    /// Returns how many comments went away (0 on failure) so the caller can correct
    /// the feed's comment count.
    @MainActor
    @discardableResult
    func deleteComment(_ comment: Comment, userId: String?, postAuthorId: String) async -> Int {
        guard let uid = userId, comment.userId == uid else { return 0 }
        let doomed = deletableIds(startingAt: comment, userId: uid, postAuthorId: postAuthorId)
        let removed = comments.filter { doomed.contains($0.id.uuidString) }
        deletedCommentIds.formUnion(doomed)
        comments.removeAll { doomed.contains($0.id.uuidString) }
        if let replying = replyingTo, doomed.contains(replying.id.uuidString) {
            replyingTo = nil
        }
        do {
            try await commentRepo.deleteComments(ids: Array(doomed), postId: postId)
            ToastCenter.shared.show(.commentDeleted())
            return removed.count
        } catch {
            deletedCommentIds.subtract(doomed)
            comments.append(contentsOf: removed)
            comments.sort { $0.createdAt < $1.createdAt }
            ToastCenter.shared.show(Toast(style: .error, status: "Failed", message: "Couldn't delete that comment"))
            return 0
        }
    }

    func sendComment(userId: String?, displayName: String?, profileImageURL: String?) async {
        guard let uid = userId else { return }
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let parentId = await MainActor.run { replyingTo?.id.uuidString }
        await MainActor.run { isSending = true; commentText = "" }
        do {
            let new = try await commentRepo.addComment(
                postId: postId,
                userId: uid,
                text: text,
                displayName: displayName,
                profileImageURL: profileImageURL,
                parentCommentId: parentId
            )
            await MainActor.run {
                if !comments.contains(where: { $0.id == new.id }) {
                    comments.append(new)
                    comments.sort { $0.createdAt < $1.createdAt }
                }
                replyingTo = nil
                lastSentCommentId = new.id
            }
        } catch {
            await MainActor.run { commentText = text }
        }
        await MainActor.run { isSending = false }
    }
}
