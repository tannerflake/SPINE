//
//  FeedDayGroupCarousel.swift
//  Spine
//
//  Consolidates a prolific poster's day into one swipeable carousel so a
//  20-review backfill doesn't bury everyone else's feed. Grouping is by
//  author + calendar day (viewer's timezone, resets at midnight): once an
//  author has more than three posts on the same day, all of that day's posts
//  collapse into a single carousel at the position of their newest post.
//  Slides run newest → oldest, the next card peeks in from the right, and a
//  "1/7" counter tracks the swipe. Each slide keeps its own like/comment
//  controls — the carousel itself is just a container with no engagement row.
//

import SwiftUI

// MARK: - Feed item grouping

/// One renderable unit in the feed: a normal standalone post, or a
/// same-day burst from one author collapsed into a carousel.
enum FeedItem: Identifiable {
    case single(Post)
    case group(FeedDayGroup)
    /// A "Selected for you" / "Readers to follow" pseudo post (see
    /// `FeedInterstitials.swift`). `slot` counts interstitials from the top of
    /// the feed and keys which books or readers it shows.
    case interstitial(slot: Int)

    var id: String {
        switch self {
        case .single(let post): return post.id.uuidString
        case .group(let group): return group.id
        case .interstitial(let slot): return "interstitial-\(slot)"
        }
    }

    /// Feed items above the first pseudo post.
    static let interstitialLeadInterval = 3

    /// Feed items between the first pseudo post and the second — far enough
    /// apart that the two rows never share a screen.
    static let interstitialGapInterval = 6

    /// Pseudo posts per feed load: one picks row and one readers row, and
    /// that's it — they don't repeat down the feed.
    static let interstitialCount = 2

    /// Drops the two pseudo posts in, the first `interstitialLeadInterval`
    /// items down and the second `interstitialGapInterval` items below that.
    /// Whichever kind each slot shows is `FeedInterstitialModel`'s call (one
    /// load in five the readers row leads). A short feed only gets them
    /// trailing once there's nothing older to load (otherwise the next page
    /// would shove them back into place, which reads as a jump), and an empty
    /// feed gets both so new members still see picks and people to follow.
    static func interleavingInterstitials(into items: [FeedItem], feedIsComplete: Bool) -> [FeedItem] {
        guard !items.isEmpty else {
            return feedIsComplete ? (0..<interstitialCount).map { .interstitial(slot: $0) } : []
        }
        var out: [FeedItem] = []
        var placed = 0
        var nextAt = interstitialLeadInterval
        for (i, item) in items.enumerated() {
            out.append(item)
            if placed < interstitialCount, i + 1 == nextAt {
                out.append(.interstitial(slot: placed))
                placed += 1
                nextAt += interstitialGapInterval
            }
        }
        if feedIsComplete {
            while placed < interstitialCount {
                out.append(.interstitial(slot: placed))
                placed += 1
            }
        }
        return out
    }

    /// An author's posts on one calendar day collapse once they exceed three.
    static let groupingThreshold = 4

    /// Folds a newest-first post list into feed items. Posts by the same author
    /// on the same calendar day (4+) collapse into one group placed where the
    /// newest of them sat; everything else passes through untouched.
    static func makeItems(from posts: [Post], calendar: Calendar = .current) -> [FeedItem] {
        // Bucket posts by author + local calendar day.
        var buckets: [String: [Post]] = [:]
        for post in posts {
            buckets[groupKey(for: post, calendar: calendar), default: []].append(post)
        }

        var groupedKeys: Set<String> = []
        var items: [FeedItem] = []
        for post in posts {
            let key = groupKey(for: post, calendar: calendar)
            let bucket = buckets[key] ?? []
            guard bucket.count >= groupingThreshold else {
                items.append(.single(post))
                continue
            }
            // First (newest) member emits the group; the rest are swallowed.
            guard !groupedKeys.contains(key) else { continue }
            groupedKeys.insert(key)
            let sorted = bucket.sorted { $0.createdAt > $1.createdAt }
            items.append(.group(FeedDayGroup(
                id: "daygroup-\(key)",
                userId: post.userId,
                user: post.user,
                day: calendar.startOfDay(for: post.createdAt),
                posts: sorted
            )))
        }
        return items
    }

    private static func groupKey(for post: Post, calendar: Calendar) -> String {
        let day = calendar.startOfDay(for: post.createdAt)
        return "\(post.userId)-\(Int(day.timeIntervalSince1970))"
    }
}

/// A same-day posting burst from one author, newest slide first.
struct FeedDayGroup: Identifiable {
    let id: String
    let userId: String
    let user: User?
    /// Start of the calendar day (viewer's timezone) the posts landed on.
    let day: Date
    /// Newest first — slide 1 is the most recent post.
    let posts: [Post]

    /// Header line under the author's name, e.g. "Marked 7 books as read today".
    func summaryLine(calendar: Calendar = .current, now: Date = Date()) -> String {
        let count = posts.count
        let noun: String
        if posts.allSatisfy({ $0.type == .finishedBook }) {
            noun = "Marked \(count) books as read"
        } else if posts.allSatisfy({ $0.type == .recommendation }) {
            noun = "Recommended \(count) books"
        } else {
            noun = "Shared \(count) posts"
        }
        return "\(noun) \(dayPhrase(calendar: calendar, now: now))"
    }

    private func dayPhrase(calendar: Calendar, now: Date) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "yesterday"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "on \(fmt.string(from: day))"
    }
}

// MARK: - Carousel view

/// Swipeable carousel of one author's same-day posts. Group header carries the
/// author identity and summary; each slide is a full post card with its own
/// like/comment controls (the carousel adds none of its own).
struct FeedDayGroupCarousel: View {
    let group: FeedDayGroup
    var currentUserFirebaseUid: String? = nil
    var isLiked: (Post) -> Bool = { _ in false }
    var onBookTap: ((Book) -> Void)? = nil
    var onCommentTap: ((Post) -> Void)? = nil
    var onLikeToggle: ((Post, Bool) -> Void)? = nil
    var onEditReviewTap: ((Post) -> Void)? = nil
    var canEditReview: (Post) -> Bool = { _ in false }
    var onDeleteTap: ((Post) -> Void)? = nil
    var displayTier: (Post) -> String? = { _ in nil }
    /// The author's reading-now covers (same author for every slide).
    var readingNowBooks: [Book] = []

    /// Post id of the slide currently snapped into view.
    @State private var currentSlideId: String? = nil
    /// Long-press the author's avatar to blow their photo up full screen.
    @State private var showAvatarZoom = false

    /// Trailing sliver of the next card left visible so the swipe is discoverable.
    private static let nextCardPeek: CGFloat = 16
    private static let cardSpacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupHeader
                .padding(.horizontal, Theme.horizontalPadding)

            slideStrip

            // Receipt-style hairline between feed items (matches FeedPostRow).
            Rectangle()
                .fill(Theme.chrome.opacity(0.25))
                .frame(height: Theme.chromeHairline)
                .padding(.horizontal, Theme.horizontalPadding)
        }
        .padding(.top, 14)
        .avatarZoom(
            isPresented: $showAvatarZoom,
            urlString: group.user?.profileImageURL,
            displayName: group.user?.displayName,
            firstName: group.user?.firstName,
            lastName: group.user?.lastName,
            caption: group.user?.displayName
        )
    }

    /// Avatar + "Name" + summary line, with the "1/7" position counter trailing.
    private var groupHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            NavigationLink(value: group.userId) {
                HStack(spacing: 10) {
                    groupAvatar
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.user?.displayName ?? "User")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(group.summaryLine())
                            .font(.system(size: 11, weight: .regular))
                            .tracking(0.5)
                            .foregroundStyle(Theme.chrome)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            slideCounter
        }
    }

    private var slideCounter: some View {
        Text("\(currentSlideIndex + 1)/\(group.posts.count)")
            .font(.system(size: 12, weight: .bold))
            .tracking(1)
            .foregroundStyle(Theme.chrome)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(Capsule().stroke(Theme.chrome.opacity(0.45), lineWidth: 1))
            .contentTransition(.numericText())
            .animation(.easeInOut(duration: 0.15), value: currentSlideIndex)
            .accessibilityLabel("Post \(currentSlideIndex + 1) of \(group.posts.count)")
    }

    private var currentSlideIndex: Int {
        guard let id = currentSlideId,
              let idx = group.posts.firstIndex(where: { $0.id.uuidString == id }) else { return 0 }
        return idx
    }

    /// Paged horizontal strip — cards are narrower than the container so the
    /// next slide peeks in from the trailing edge.
    private var slideStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Self.cardSpacing) {
                ForEach(group.posts) { post in
                    slideCard(post)
                        .containerRelativeFrame(.horizontal) { length, _ in
                            max(0, length - Theme.horizontalPadding - Self.nextCardPeek)
                        }
                        .id(post.id.uuidString)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, Theme.horizontalPadding, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $currentSlideId)
    }

    private func slideCard(_ post: Post) -> some View {
        FeedPostRow(
            post: post,
            currentUserFirebaseUid: currentUserFirebaseUid,
            isLiked: isLiked(post),
            onBookTap: onBookTap,
            onCommentTap: { onCommentTap?(post) },
            onLikeToggle: { onLikeToggle?(post, $0) },
            onEditReviewTap: { onEditReviewTap?(post) },
            canEditReview: canEditReview(post),
            onDeleteTap: { onDeleteTap?(post) },
            displayTier: displayTier(post),
            readingNowBooks: readingNowBooks,
            showsBottomDivider: false
        )
        .padding(.bottom, 2)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.surface.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Theme.chrome.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var groupAvatar: some View {
        HStack(spacing: 2) {
            UserAvatarView(
                urlString: group.user?.profileImageURL,
                displayName: group.user?.displayName,
                firstName: group.user?.firstName,
                lastName: group.user?.lastName,
                size: 40
            )
            .overlay(
                Circle().strokeBorder(Theme.chrome.opacity(0.55), lineWidth: 1)
            )
            // The hold lives on the avatar circle itself, a descendant of the
            // header link's label, so it consumes the touch instead of letting
            // the release push the author's library. (Not on the enclosing
            // HStack — that would put the press target over the fanned covers.)
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: 0.35) {
                WizardHaptics.step()
                AvatarZoomPresentation.present($showAvatarZoom)
            }
            .accessibilityHint("Touch and hold to see their photo full screen")
            ReadingNowFanStack(books: readingNowBooks, coverWidth: 17)
        }
    }
}
