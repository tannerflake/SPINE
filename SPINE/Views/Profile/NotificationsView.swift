//
//  NotificationsView.swift
//  SPINE
//
//  Notification feed behind the bell on the Feed and Profile tabs: follows,
//  likes, comments, replies, blend invites/results, friend reviews. Rows
//  deep-link to the same destinations as their push notifications, except a
//  friend's same-day finished books, which fold into one "read 3 books" row
//  that pulls up a swipeable carousel of those reviews.
//

import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    /// nil while loading; empty when the feed has nothing.
    @State private var notifications: [UserNotification]? = nil
    /// Grouped "read N books" row the reader tapped; drives the carousel sheet.
    @State private var readsGroupToOpen: FriendReadsGroup? = nil
    private let repo = NotificationsRepository()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .task { await load() }
        .sheet(item: $readsGroupToOpen) { reads in
            FriendReadsCarouselSheet(reads: reads)
                .environmentObject(authService)
                .environmentObject(appState)
                // Half height fits a slide or two of review; long reviews drag up.
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let items = notifications {
            if items.isEmpty {
                emptyState
            } else {
                let entries = Self.entries(from: items)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .single(let item): row(item)
                            case .reads(let reads): readsRow(reads)
                            }
                            if entry.id != entries.last?.id {
                                Divider()
                                    .overlay(Theme.textTertiary.opacity(0.2))
                                    .padding(.leading, Theme.horizontalPadding + 48)
                            }
                        }
                    }
                    .padding(.bottom, 100)
                }
                .refreshable { await load() }
            }
        } else {
            ProgressView()
                .tint(Theme.accent)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("No notifications yet")
                .font(Theme.headline())
                .foregroundStyle(Theme.textPrimary)
            Text("Follows, likes, comments, and Book Blends will show up here.")
                .font(Theme.callout())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: UserNotification) -> some View {
        Button {
            open(item)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                leadingArt(item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(Theme.callout().weight(item.read ? .regular : .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    subtitle(item)
                    Text(Self.compactAge(item.createdAt))
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                if !item.read {
                    Circle()
                        .fill(Theme.danger)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Body line under the title. A friend-review row's tier shows as the
    /// badge used everywhere else a tier appears, not spelled out: the eye
    /// reads the color before the text, and the teaser gets the words.
    @ViewBuilder
    private func subtitle(_ item: UserNotification) -> some View {
        let parts = item.tierAndBodyText
        if let tier = parts.tier {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TierBadge(tier: tier, size: .mini)
                if !parts.text.isEmpty {
                    Text(parts.text)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
            }
            .padding(.top, 1)
        } else if !parts.text.isEmpty {
            Text(parts.text)
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
        }
    }

    /// A friend's same-day finished books as one row: "Tanner read 3 books",
    /// the titles underneath, covers fanned on the left.
    private func readsRow(_ reads: FriendReadsGroup) -> some View {
        Button {
            readsGroupToOpen = reads
        } label: {
            HStack(alignment: .top, spacing: 12) {
                coverFan(reads.coverURLs)
                VStack(alignment: .leading, spacing: 3) {
                    Text(reads.title)
                        .font(Theme.callout().weight(reads.read ? .regular : .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    Text(reads.body)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Text(Self.compactAge(reads.createdAt))
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                if !reads.read {
                    Circle()
                        .fill(Theme.danger)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Up to three covers stacked back to front, each nudged right, in the same
    /// 36pt column a single row's cover takes.
    @ViewBuilder
    private func coverFan(_ urls: [String]) -> some View {
        if urls.isEmpty {
            Circle()
                .fill(Theme.surface)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: Self.glyph(for: "friend_review_posted"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                )
        } else {
            coverStack(Array(urls.prefix(3)))
        }
    }

    private func coverStack(_ shown: [String]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(shown.enumerated().reversed()), id: \.offset) { index, cover in
                AsyncImage(url: URL(string: cover)) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Theme.surface
                    }
                }
                .frame(width: 28, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Theme.textTertiary.opacity(0.25), lineWidth: 0.5)
                )
                .offset(x: CGFloat(index) * 4, y: CGFloat(index) * 5)
            }
        }
        .frame(width: 36, height: 52, alignment: .topLeading)
    }

    /// Book cover when the event has one; otherwise a type glyph in a circle.
    @ViewBuilder
    private func leadingArt(_ item: UserNotification) -> some View {
        if let cover = item.coverURL, let url = URL(string: cover) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Theme.surface
                }
            }
            .frame(width: 36, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.textTertiary.opacity(0.25), lineWidth: 0.5)
            )
        } else if let raw = item.achievementId, let kind = AchievementKind(rawValue: raw) {
            StampImage(kind: kind)
                .frame(width: 40, height: 40)
        } else {
            Circle()
                .fill(Theme.surface)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: Self.glyph(for: item.type))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                )
        }
    }

    private static func glyph(for type: String) -> String {
        switch type {
        case "new_follower": return "person.badge.plus"
        case "contact_joined": return "person.2.fill"
        case "review_liked", "comment_liked": return "heart.fill"
        case "review_commented", "comment_replied", "thread_commented": return "bubble.left.fill"
        case "review_mentioned", "comment_mentioned": return "at"
        case "blend_request", "blend_ready": return "shuffle"
        case "friend_review_posted": return "book.fill"
        case "book_recommended": return "paperplane.fill"
        case "achievement_unlocked": return "seal.fill"
        case "monthly_recap": return "calendar"
        case "club_invite": return "envelope.fill"
        case let t where t.hasPrefix("club_"): return "person.3.fill"
        default: return "bell.fill"
        }
    }

    /// "now", "5m", "2h", "3d", "2w" — feed rows want a glance, not a sentence.
    private static func compactAge(_ date: Date) -> String {
        let s = max(0, Date().timeIntervalSince(date))
        if s < 60 { return "now" }
        let m = Int(s / 60)
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        let d = h / 24
        if d < 7 { return "\(d)d" }
        return "\(d / 7)w"
    }

    // MARK: - Same-day read grouping

    /// One row's worth of feed: a notification as-is, or a friend's same-day
    /// finished books folded together.
    enum Entry: Identifiable {
        case single(UserNotification)
        case reads(FriendReadsGroup)

        var id: String {
            switch self {
            case .single(let item): return item.id
            case .reads(let reads): return reads.id
            }
        }
    }

    /// Folds `friend_review_posted` rows from the same friend on the same
    /// calendar day (viewer's timezone) into one entry once there are two or
    /// more, placed where the newest of them sat. Everything else passes
    /// through in order. `items` arrive newest first.
    static func entries(from items: [UserNotification], calendar: Calendar = .current) -> [Entry] {
        func key(_ item: UserNotification) -> String? {
            guard item.type == "friend_review_posted",
                  let actor = item.actorId,
                  item.postId != nil else { return nil }
            return "\(actor)-\(Int(calendar.startOfDay(for: item.createdAt).timeIntervalSince1970))"
        }
        var buckets: [String: [UserNotification]] = [:]
        for item in items {
            if let k = key(item) { buckets[k, default: []].append(item) }
        }
        var emitted: Set<String> = []
        var out: [Entry] = []
        for item in items {
            guard let k = key(item), let bucket = buckets[k], bucket.count >= 2 else {
                out.append(.single(item))
                continue
            }
            // First (newest) member emits the group; the rest are swallowed.
            guard emitted.insert(k).inserted else { continue }
            out.append(.reads(FriendReadsGroup(id: "reads-\(k)", items: bucket)))
        }
        return out
    }

    /// Rows route exactly like their pushes: the doc carries the same type +
    /// deep-link ids as the push data payload, so the push tap handler does the
    /// rest (tab switch, sheet, blend landing).
    private func open(_ item: UserNotification) {
        var info: [AnyHashable: Any] = ["type": item.type]
        if let postId = item.postId { info["postId"] = postId }
        if let commentId = item.commentId { info["commentId"] = commentId }
        if let blendId = item.blendId { info["blendId"] = blendId }
        if let achievementId = item.achievementId { info["achievementId"] = achievementId }
        if let recapMonth = item.recapMonth { info["recapMonth"] = recapMonth }
        if let clubId = item.clubId { info["clubId"] = clubId }
        if let actorId = item.actorId { info["followerId"] = actorId }
        dismiss()
        PushNotificationService.handleRemoteNotificationTap(userInfo: info)
    }

    private func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiPreviewNotifications") {
            notifications = Self.uiPreviewDemo
            return
        }
        #endif
        guard let uid = authService.firebaseUser?.uid else {
            notifications = []
            return
        }
        let items = await repo.fetchLatest(uid: uid)
        notifications = items
        // Clear the shared bell badge (both tabs) only after the rows are on
        // screen — the fetched snapshot above keeps this visit's unread styling
        // intact. Goes through AppState so whichever bell opened us, and the
        // other one too, stay in sync.
        if items.contains(where: { !$0.read }) {
            appState.markNotificationsRead()
        }
    }

    #if DEBUG
    /// `-uiPreviewNotifications`: demo rows for simulator UI verification.
    private static var uiPreviewDemo: [UserNotification] {
        let now = Date()
        return [
            UserNotification(id: "1", type: "new_follower", title: "👋 Alex followed you", body: "See what they're reading on Spine.", postId: nil, commentId: nil, blendId: nil, actorId: "demo", coverURL: nil, createdAt: now.addingTimeInterval(-300), read: false),
            UserNotification(id: "0c", type: "club_invite", title: "💌 Hannah invited you to join Thursday Night Reads", body: "Tap to join.", postId: nil, commentId: nil, blendId: nil, clubId: "club-demo-2", actorId: "demo", coverURL: nil, createdAt: now.addingTimeInterval(-60), read: false),
            UserNotification(id: "0", type: "achievement_unlocked", title: "🏅 25 books ranked!", body: "You earned a stamp. Tap to put it on your library card.", postId: nil, commentId: nil, blendId: nil, achievementId: "ranked25", actorId: nil, coverURL: nil, createdAt: now.addingTimeInterval(-120), read: false),
            UserNotification(id: "0r", type: "monthly_recap", title: "🎁 Your August Wrapped", body: "See your reads from last month!", postId: nil, commentId: nil, blendId: nil, achievementId: nil, recapMonth: "2026-08", actorId: nil, coverURL: nil, createdAt: now.addingTimeInterval(-600), read: false),
            UserNotification(id: "1b", type: "contact_joined", title: "🎉 Katie joined Spine", body: "Katie Nguyen is in your contacts. Tap to follow.", postId: nil, commentId: nil, blendId: nil, actorId: "demo", coverURL: nil, createdAt: now.addingTimeInterval(-900), read: false),
            UserNotification(id: "1r1", type: "friend_review_posted", title: "📚 Tanner read Piranesi", body: "S-Tier. “Strange and lovely.”", postId: "demo-read-1", commentId: nil, blendId: nil, tier: "S", actorId: "demo-reader", coverURL: "https://covers.openlibrary.org/b/isbn/9781635575637-L.jpg", createdAt: now.addingTimeInterval(-1500), read: false),
            UserNotification(id: "1r2", type: "friend_review_posted", title: "📚 Tanner read Sapiens", body: "A-Tier.", postId: "demo-read-2", commentId: nil, blendId: nil, actorId: "demo-reader", coverURL: "https://covers.openlibrary.org/b/isbn/9780062316097-L.jpg", createdAt: now.addingTimeInterval(-1800), read: false),
            UserNotification(id: "1r3", type: "friend_review_posted", title: "📚 Tanner read The Overstory", body: "B-Tier.", postId: "demo-read-3", commentId: nil, blendId: nil, actorId: "demo-reader", coverURL: "https://covers.openlibrary.org/b/isbn/9780393635522-L.jpg", createdAt: now.addingTimeInterval(-2100), read: false),
            UserNotification(id: "1r4", type: "friend_review_posted", title: "📚 Maya read Educated", body: "A-Tier. “Could not put it down, finished in two sittings.”", postId: "demo-read-4", commentId: nil, blendId: nil, tier: "A", actorId: "demo", coverURL: "https://covers.openlibrary.org/b/isbn/9780399590504-L.jpg", createdAt: now.addingTimeInterval(-3000), read: false),
            UserNotification(id: "1r5", type: "friend_review_posted", title: "📚 Jordan read Dune", body: "B-Tier.", postId: "demo-read-5", commentId: nil, blendId: nil, actorId: "demo-2", coverURL: "https://covers.openlibrary.org/b/isbn/9780441013593-L.jpg", createdAt: now.addingTimeInterval(-3600), read: true),
            UserNotification(id: "2", type: "review_liked", title: "❤️ Maya liked your review", body: "Your review of Sapiens.", postId: "demo", commentId: nil, blendId: nil, actorId: "demo", coverURL: "https://covers.openlibrary.org/b/isbn/9780062316097-L.jpg", createdAt: now.addingTimeInterval(-7200), read: false),
            UserNotification(id: "3", type: "blend_request", title: "🔀 Jordan invited you", body: "Book Blend: see how your reading tastes line up. Tap to accept.", postId: nil, commentId: nil, blendId: "demo", actorId: "demo", coverURL: nil, createdAt: now.addingTimeInterval(-86400), read: true),
            UserNotification(id: "4", type: "review_commented", title: "💬 Sam commented", body: "On your review of The Overstory: “Great take on chapter three...”", postId: "demo", commentId: nil, blendId: nil, actorId: "demo", coverURL: nil, createdAt: now.addingTimeInterval(-3 * 86400), read: true),
            UserNotification(id: "5", type: "friend_review_posted", title: "⭐ Riley gave a 9.0", body: "Project Hail Mary: “Smart, ambitious, and way more readable than...”", postId: "demo", commentId: nil, blendId: nil, actorId: "demo", coverURL: nil, createdAt: now.addingTimeInterval(-9 * 86400), read: true),
            UserNotification(id: "6", type: "book_recommended", title: "📖 Maya sent you a book", body: "Piranesi: “You'd love this one”", postId: nil, commentId: nil, blendId: nil, actorId: "demo", coverURL: nil, createdAt: now.addingTimeInterval(-12 * 86400), read: true),
        ]
    }
    #endif
}

// MARK: - Grouped friend reads

/// A friend's finished-book notifications from one day, newest first.
struct FriendReadsGroup: Identifiable {
    let id: String
    let items: [UserNotification]

    var createdAt: Date { items.first?.createdAt ?? Date() }
    var read: Bool { items.allSatisfy(\.read) }
    var postIds: [String] {
        var seen: Set<String> = []
        return items.compactMap(\.postId).filter { seen.insert($0).inserted }
    }
    var coverURLs: [String] { items.compactMap(\.coverURL) }

    /// The friend's first name and each book title, read back out of the
    /// server-composed titles ("📚 Tanner read Sapiens", see
    /// `onFriendReviewPosted`). The docs carry no separate name or title field.
    private var parsed: [(name: String?, book: String?)] { items.map { Self.parse($0.title) } }

    var firstName: String { parsed.lazy.compactMap(\.name).first ?? "A friend" }

    /// "📚 Tanner read 3 books"
    var title: String { "📚 \(firstName) read \(postIds.count) books" }

    /// "Piranesi, Sapiens, and The Overstory", or "Piranesi, Sapiens, and 4 more".
    var body: String {
        let books = parsed.compactMap(\.book)
        let count = postIds.count
        guard !books.isEmpty else { return "Tap to see what they thought." }
        if books.count == count, count <= 3 {
            switch count {
            case 1: return books[0]
            case 2: return "\(books[0]) and \(books[1])"
            default: return "\(books[0]), \(books[1]), and \(books[2])"
            }
        }
        let shown = Array(books.prefix(2))
        let more = "\(max(1, count - shown.count)) more"
        return shown.count == 1 ? "\(shown[0]) and \(more)" : "\(shown[0]), \(shown[1]), and \(more)"
    }

    static func parse(_ title: String) -> (name: String?, book: String?) {
        var text = title.trimmingCharacters(in: .whitespaces)
        // Drop the leading emoji glyph.
        if let space = text.firstIndex(of: " "),
           !text[..<space].contains(where: \.isLetter) {
            text = String(text[text.index(after: space)...])
        }
        for verb in [" read ", " finished ", " gave "] {
            guard let range = text.range(of: verb) else { continue }
            let name = String(text[..<range.lowerBound])
            let rest = String(text[range.upperBound...])
            let book = verb == " gave " || rest == "a book" ? nil : rest
            return (name.isEmpty ? nil : name, book)
        }
        return (nil, nil)
    }
}

/// Pulled up from a grouped "read N books" row: the friend's posts from that
/// day as the feed's swipeable day-group carousel, with the same like,
/// comment, book and profile taps the feed has.
private struct FriendReadsCarouselSheet: View {
    let reads: FriendReadsGroup
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var group: FeedDayGroup? = nil
    @State private var loadFinished = false
    @State private var path = NavigationPath()
    @State private var selectedBook: Book? = nil
    @State private var postForComments: Post? = nil
    private let postRepo = PostRepository()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
            .navigationDestination(for: String.self) { userId in
                UserLibraryDetailView(userId: userId)
                    .environmentObject(authService)
                    .environmentObject(appState)
            }
            .navigationDestination(item: $selectedBook) { book in
                BookProfileView(
                    book: book,
                    readBooksForSimilar: appState.readBooks,
                    onNotInterested: nil,
                    onWantToRead: { appState.addToWantToRead(book: book) },
                    onStartReading: { appState.addToQueue(book: book, shelf: .readingNow) },
                    onConfirmRead: { date, rating, post, caption, tier in appState.addAsRead(book: book, dateFinished: date, rating: rating, postToFeed: post, caption: caption, tier: tier); selectedBook = nil },
                    isOnReadList: appState.isBookOnReadList(bookId: book.id),
                    isInQueue: appState.isBookInQueue(bookId: book.id),
                    onRemoveFromQueue: { appState.removeFromQueue(book: book) },
                    onMarkAsDNF: { appState.markAsDNF(book: book) },
                    readEntryForReview: appState.userReadBook(forBookId: book.id),
                    canEditReadReview: true,
                    sourceReaderUid: group?.userId
                )
            }
        }
        .sheet(item: $postForComments) { post in
            CommentsView(post: post, scrollToCommentId: nil)
                .environmentObject(appState)
                .environmentObject(authService)
        }
        // @mention taps in review captions arrive as spine-mention:// URLs.
        .environment(\.openURL, OpenURLAction { url in
            guard let handle = MentionScanner.handle(fromMentionURL: url) else { return .systemAction }
            Task {
                if let uid = await MentionCatalog.shared.uid(forHandle: handle) {
                    await MainActor.run { path.append(uid) }
                }
            }
            return .handled
        })
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let group {
            ScrollView {
                FeedDayGroupCarousel(
                    group: group,
                    currentUserFirebaseUid: authService.firebaseUser?.uid,
                    isLiked: { appState.likedPostIds.contains($0.id.uuidString) },
                    onBookTap: { selectedBook = $0 },
                    onCommentTap: { postForComments = $0 },
                    onLikeToggle: { post, liked in appState.togglePostLike(postId: post.id.uuidString, liked: liked) },
                    displayTier: { $0.tier }
                )
                .padding(.bottom, 40)
            }
        } else if loadFinished {
            VStack(spacing: 12) {
                Image(systemName: "book.closed")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
                Text("These reviews are gone")
                    .font(Theme.headline())
                    .foregroundStyle(Theme.textPrimary)
                Text("\(reads.firstName) may have deleted them.")
                    .font(Theme.callout())
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .tint(Theme.accent)
        }
    }

    private func load() async {
        defer { loadFinished = true }
        let ids = reads.postIds
        var posts: [Post]
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiPreviewNotifications") {
            posts = Self.uiPreviewPosts(reads)
        } else {
            posts = await fetch(ids)
        }
        #else
        posts = await fetch(ids)
        #endif
        posts.sort { $0.createdAt > $1.createdAt }
        guard let first = posts.first else { return }
        group = FeedDayGroup(
            id: reads.id,
            userId: first.userId,
            user: first.user,
            day: Calendar.current.startOfDay(for: first.createdAt),
            posts: posts
        )
    }

    /// Posts already in the feed listener come free; the rest are fetched by
    /// id (deleted or hidden ones just drop out).
    private func fetch(_ ids: [String]) async -> [Post] {
        let cached = Dictionary(
            appState.feedPosts.map { ($0.id.uuidString, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let repo = postRepo
        return await withTaskGroup(of: Post?.self) { tasks in
            for id in ids {
                if let hit = cached[id] {
                    tasks.addTask { hit }
                } else {
                    tasks.addTask { await repo.fetchPost(postId: id) }
                }
            }
            var out: [Post] = []
            for await post in tasks {
                if let post { out.append(post) }
            }
            return out
        }
    }

    #if DEBUG
    /// `-uiPreviewNotifications`: local posts for the demo group's ids.
    private static func uiPreviewPosts(_ reads: FriendReadsGroup) -> [Post] {
        let tiers = ["S", "A", "B", "C"]
        return reads.items.enumerated().compactMap { index, item in
            guard item.postId != nil else { return nil }
            let title = FriendReadsGroup.parse(item.title).book ?? "Demo Book"
            let book = Book(id: "demo-\(index)", title: title, author: "Demo Author", coverURL: item.coverURL ?? "", pageCount: 300, publishedDate: nil, description: nil, genres: [])
            return Post(id: UUID(), userId: "demo-user-id", type: .finishedBook, bookId: book.id, book: book, caption: index == 0 ? "Strange and lovely." : nil, createdAt: item.createdAt, likeCount: 2, commentCount: 0, user: .demo, rating: nil, dateFinished: item.createdAt, tier: tiers[index % tiers.count])
        }
    }
    #endif
}
