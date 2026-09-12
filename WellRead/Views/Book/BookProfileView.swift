//
//  BookProfileView.swift
//  Spine
//
//  Hero book profile — cover front-and-center with a status badge, then airy
//  Hinge-style section cards (review, summary, similar, quote, recommend) with
//  small overline labels. Action bar below uses glossy CTA buttons.
//

import SwiftUI

struct BookProfileView: View {
    @Environment(\.mainTabBarOverlapExtraHeight) private var mainTabBarOverlapExtraHeight

    let book: Book
    /// When provided, we load and show "Similar to" with cute small covers from the user's read list.
    var readBooksForSimilar: [UserBook]? = nil
    var onNotInterested: (() -> Void)? = nil
    var onWantToRead: (() -> Void)? = nil
    /// Adds the book to the Queue's "Reading now" shelf. When set, shows the READING button.
    var onStartReading: (() -> Void)? = nil
    /// Called when user confirms "Mark as Read" with (dateFinished, rating out of 10 e.g. 8.8, postToFeed, thoughtsCaption). When set, tapping Read shows the inline modal instead of firing immediately.
    /// (dateFinished, rating, postToFeed, thoughts, tier). Tier nil = Unranked → tier-list "Rank me" prompt.
    var onConfirmRead: ((Date, Double?, Bool, String?, String?) -> Void)? = nil
    /// When set, tapping a similar book opens that book (e.g. sets navigation selection). Used from Discover.
    var onBookTap: ((Book) -> Void)? = nil
    /// True when this book is already on the user's read list (affects Read button appearance).
    var isOnReadList: Bool = false
    /// True when this book is already in the user's queue — the QUEUE button becomes REMOVE.
    var isInQueue: Bool = false
    /// Removes the book from the queue; shown as REMOVE in place of QUEUE when isInQueue.
    var onRemoveFromQueue: (() -> Void)? = nil
    /// Marks a Reading Now book as "did not finish" instead of deleting it outright.
    /// Shown as DNF in place of REMOVE when the book is on the reading-now shelf.
    var onMarkAsDNF: (() -> Void)? = nil
    /// When set and the entry has review text and/or a rating, shows the first card section (e.g. current user's read row).
    var readEntryForReview: UserBook? = nil
    /// Section title for that card (`"My review"` vs `"Review"` on someone else's profile).
    var reviewSectionHeading: String = "My review"
    /// When `true`, shows a pencil on the review card to edit date, rating, thoughts, feed visibility, or delete.
    var canEditReadReview: Bool = false
    /// Shelf-scoped primary CTA (e.g. "+ READING NOW") shown above the Queue/Read row
    /// when the profile was opened from a shelf's "Add" tile. Hidden if already in queue.
    var shelfActionTitle: String? = nil
    var onAddToShelf: (() -> Void)? = nil
    /// When `false`, hides the "Recommend to a Friend" section. Discover suppresses it
    /// since those are books the user hasn't read yet.
    var showRecommend: Bool = true
    /// UID of the reader whose tier list or feed post led here. Their row is
    /// included in "Read by" even when the viewer doesn't follow them, pinned
    /// to the top of the section, and gently highlighted.
    var sourceReaderUid: String? = nil

    @EnvironmentObject private var appState: AppState

    @State private var summary: String?
    @State private var notableQuote: String?
    @State private var similarBooks: [Book] = []
    @State private var summaryLoading = false
    @State private var quoteLoading = false
    @State private var similarLoading = false
    @State private var showMarkAsReadModal = false
    @State private var profileTags: [String] = []
    @State private var tagsLoading = false
    @State private var userBookToEdit: UserBook? = nil
    // Re-read flow: tapping READ on an already-read book offers to log another read
    // or to remove the book from the read shelf.
    @State private var showRereadPrompt = false
    /// The mark-as-read drawer, opened in re-read mode from "Log Another Read".
    @State private var showRereadDrawer = false
    @State private var showRemoveFromReadConfirm = false
    @State private var showRefresher = false
    @State private var showSummaryMore = false
    // Note-to-self composer for a queued book (pencil / "add a note" on the note card).
    @State private var showQueueNoteComposer = false
    /// Scrubber value while the finger is down; nil shows the saved value.
    @State private var liveProgress: Double? = nil
    /// Finish-line celebration for the progress window (confetti trigger + card pop).
    /// The progress card's frame in window space, used to aim the confetti.
    @State private var progressCardFrame: CGRect = .zero
    @State private var progressFinishPop: Bool = false
    /// Ribbon springs to saved values but tracks the finger directly mid-drag.
    private var heroRibbonAnimation: Animation? {
        liveProgress == nil ? .spring(response: 0.32, dampingFraction: 0.82) : nil
    }
    @State private var matchScore: Int? = nil
    // "Why you might like it" — only for books scoring above 50% match.
    @State private var whyLikeText: String? = nil
    @State private var whyLikeLoading = false

    // Recommend-to-a-friend section
    private struct RecommendReader: Identifiable {
        var id: String { uid }
        let uid: String
        let user: User
    }
    // "Read by" section — every SPINE reader who's finished this book, people
    // you follow first. Rows, likes, and comments render in BookDiscussionSection.
    @State private var readByReaders: [BookDiscussionReader] = []
    @State private var readByProfileToView: BookDiscussionReader?

    @State private var recommendReaders: [RecommendReader] = []
    @State private var recommendLoading = false
    @State private var recommendSendingTo: Set<String> = []
    @State private var recommendSentTo: Set<String> = []
    @State private var showInviteCompose = false
    @State private var cantSendTextAlert = false
    @State private var recommendProfileToView: RecommendReader?

    // Cover regeneration ("wrong cover?" under the hero cover).
    private enum CoverFixState: Equatable {
        /// No resolved cover image yet (shimmer or title placeholder) — show nothing.
        case hidden
        case idle
        case working
        /// A regeneration is showing; offer "try another" and "undo".
        case regenerated
        /// Transient: the chain had nothing new to offer.
        case exhausted
    }
    @State private var coverFixState: CoverFixState = .hidden
    /// Bumped after a regenerate/undo so BookCoverView recreates and hydrates
    /// the new locked cover from cache (instant — the image is already local).
    @State private var coverEpoch = 0
    /// Founder-only: which API the resolved cover came from (nil for everyone else).
    @State private var coverSourceLabel: String?

    private var showActionBar: Bool {
        onNotInterested != nil || onWantToRead != nil || onStartReading != nil || onConfirmRead != nil || onRemoveFromQueue != nil || onMarkAsDNF != nil || onAddToShelf != nil
    }

    private var showShelfAction: Bool {
        shelfActionTitle != nil && onAddToShelf != nil && !isInQueue
    }

    /// The signed-in user's queued row for this book, if any. Drives the
    /// note-to-self card (always the viewer's own note, whoever's library led here).
    private var queuedEntry: UserBook? {
        appState.queuedUserBook(for: book)
    }

    /// True when the book is on the user's currently-reading shelf — the FINISHED
    /// button becomes "FINISHED!" since that's what tapping it means mid-read.
    private var isCurrentlyReading: Bool {
        appState.userBooks.contains { $0.bookId == book.id && $0.status == .currentlyReading }
    }

    /// True when the book sits on the user's Queue → Reading Now shelf — the
    /// REMOVE action there means "I stopped partway through," so it's DNF instead.
    private var isReadingNowShelf: Bool {
        appState.userBooks.contains { $0.bookId == book.id && $0.status == .wantToRead && $0.queueShelf == .readingNow }
    }

    private var showReadingNowDNF: Bool {
        isReadingNowShelf && onMarkAsDNF != nil
    }

    /// The signed-in reader's Reading now entry for this book (any edition of
    /// the work), driving the progress window and the cover ribbon.
    private var readingNowEntry: UserBook? {
        guard let q = queuedEntry, q.queueShelf == .readingNow else { return nil }
        return q
    }

    /// Refresher is only offered for books the user has finished — that's the
    /// whole premise (full-spoiler recap), and it keeps the AI cost gated.
    private var hasReadBook: Bool {
        if isOnReadList { return true }
        if readEntryForReview?.status == .read { return true }
        return appState.userBooks.contains { $0.bookId == book.id && $0.status == .read }
    }

    /// Recommend is only offered for books the signed-in user is currently
    /// reading or has finished — no pushing books you haven't picked up yet.
    /// Checks `appState` directly (not `readEntryForReview`/`hasReadBook`,
    /// which reflect the profile owner's shelf on someone else's library).
    private var canRecommendBook: Bool {
        appState.userBooks.contains {
            $0.bookId == book.id
                && ($0.status == .read || ($0.status == .wantToRead && $0.queueShelf == .readingNow))
        }
    }

    /// Show review card when this read row has review text and/or a tier.
    private var showReviewSection: Bool {
        guard let ub = readEntryForReview else { return false }
        guard ub.status == .read else { return false }
        let trimmed = ub.reviewText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasText = !trimmed.isEmpty
        let hasTier = ub.tier != nil
        return hasText || hasTier
    }

    /// Hide the Notable Quote card entirely when no quote was found. Still shown while loading.
    private var shouldShowQuoteCard: Bool {
        if quoteLoading { return true }
        let trimmed = notableQuote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    hero

                    // Mid-read: progress first. It's the one number the reader
                    // came to move, and it feeds the ribbon on the cover above.
                    if let reading = readingNowEntry {
                        readingProgressWindow(ub: reading)
                            .padding(.horizontal)
                    }

                    // Why it's in the queue — above the summary so the reader's
                    // own reason is the first thing they see on a queued book.
                    if let queued = queuedEntry {
                        QueueNoteCard(note: queued.trimmedQueueNote) {
                            showQueueNoteComposer = true
                        }
                        .padding(.horizontal)
                    }

                    summaryWindow
                        .padding(.horizontal)

                    if showReviewSection, let ub = readEntryForReview {
                        reviewWindow(ub: ub)
                            .padding(.horizontal)
                        recommendSection
                    }

                    if !readByReaders.isEmpty {
                        readByWindow
                            .padding(.horizontal)
                    }

                    if hasReadBook {
                        refresherWindow
                            .padding(.horizontal)
                    }

                    if !showReviewSection {
                        recommendSection
                    }

                    if !readBooksForSimilar.isEmptyOrNil && (similarLoading || !similarBooks.isEmpty) {
                        similarWindow
                            .padding(.horizontal)
                    }

                    if let match = matchScore, match > 50, whyLikeLoading || whyLikeText != nil {
                        whyLikeWindow(match)
                            .padding(.horizontal)
                    }

                    if shouldShowQuoteCard {
                        quoteWindow
                            .padding(.horizontal)
                    }
                }
                // Extra room when the floating action bar is up, so the last card
                // can scroll clear of the buttons.
                .padding(.bottom, showActionBar ? 108 : 32)
            }
            .background(Theme.background)
        }
        // Blackbird-style: the buttons float over the scrolling page — no panel,
        // no divider — so the content area runs the full height.
        .overlay(alignment: .bottom) {
            if showActionBar {
                actionBar
            }
        }
        .padding(.bottom, mainTabBarOverlapExtraHeight)
        .background(Theme.background)
        // Hosted here rather than via ToastCenter: this page can sit inside a
        // fullScreenCover (shelf "Add" search), where the root toast host is hidden.
        .overlay {
            if showQueueNoteComposer {
                QueueNoteComposerOverlay(
                    request: QueueNoteRequest(book: book, initialNote: queuedEntry?.trimmedQueueNote ?? "") { note in
                        appState.setQueueNote(for: book, note: note)
                    },
                    onClose: { withAnimation(.easeOut(duration: 0.2)) { showQueueNoteComposer = false } }
                )
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showMarkAsReadModal) {
            MarkAsReadDrawer(bookId: book.id, book: book) { date, rating, post, thoughts, tier in
                onConfirmRead?(date, rating, post, thoughts, tier)
            }
        }
        // A re-read goes through the same drawer as a first finish (date, thoughts,
        // tier, feed) instead of silently stamping today's date.
        .sheet(isPresented: $showRereadDrawer) {
            MarkAsReadDrawer(
                bookId: book.id,
                book: book,
                onConfirm: { date, _, post, thoughts, tier in
                    logReread(date: date, thoughts: thoughts, tier: tier, postToFeed: post)
                },
                isAdditionalRead: true,
                subtitle: rereadSubtitle,
                initialThoughts: currentUserReadEntry?.reviewText ?? "",
                initialTier: currentUserReadEntry?.normalizedTier,
                initialPostToFeed: true
            )
        }
        .sheet(item: $userBookToEdit) { ub in
            EditReadReviewSheet(userBook: ub)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showRefresher) {
            BookRefresherView(book: book)
        }
        .sheet(isPresented: $showSummaryMore) {
            BookSummaryMoreView(book: book)
        }
        .sheet(isPresented: $showInviteCompose) {
            MessageComposeView(recipients: [], body: AppLinks.inviteMessage(bookTitle: book.title))
                .ignoresSafeArea()
        }
        .sheet(item: $recommendProfileToView) { reader in
            NavigationStack {
                ZStack {
                    Theme.background.ignoresSafeArea()
                    UserLibraryDetailView(userId: reader.uid)
                }
                .toolbarBackground(Theme.background, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { recommendProfileToView = nil }
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .sheet(item: $readByProfileToView) { reader in
            NavigationStack {
                ZStack {
                    Theme.background.ignoresSafeArea()
                    UserLibraryDetailView(userId: reader.uid)
                }
                .toolbarBackground(Theme.background, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { readByProfileToView = nil }
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .confirmationDialog("You've read this book", isPresented: $showRereadPrompt, titleVisibility: .visible) {
            Button("Log Another Read") { showRereadDrawer = true }
            Button("Remove from Read", role: .destructive) { showRemoveFromReadConfirm = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(rereadLogMessage)
        }
        .alert("Remove from your read shelf?", isPresented: $showRemoveFromReadConfirm) {
            Button("Remove", role: .destructive) { removeFromRead() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the book from your read shelf and deletes your review and feed post if any.")
        }
        .alert("Can't send texts", isPresented: $cantSendTextAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device can't send text messages. You can still share SPINE from the App Store: \(AppLinks.appStore)")
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: book.id) {
            recommendSendingTo = []
            recommendSentTo = []
            readByReaders = []
            matchScore = nil
            whyLikeText = nil
            whyLikeLoading = false
            if let myUid = appState.authUserId {
                let following = Set(appState.currentUser?.following ?? [])
                let sourceUid = sourceReaderUid
                let bookId = book.id
                Task {
                    let entries = await UserBookRepository().fetchReadEntries(bookId: bookId)
                    var seen = Set<String>()
                    let included = entries.filter {
                        !HiddenAccounts.isHiddenFromCurrentViewer(uid: $0.userId)
                            && seen.insert($0.userId).inserted
                    }
                    guard !included.isEmpty else { return }
                    let users = await UserRepository().getUsers(uids: included.map(\.userId))
                    let readers = included.compactMap { entry -> BookDiscussionReader? in
                        guard let user = users[entry.userId] else { return nil }
                        return BookDiscussionReader(
                            uid: entry.userId,
                            user: user,
                            entry: entry,
                            isFollowed: following.contains(entry.userId)
                        )
                    }
                    let sorted = readers.sorted {
                        Self.readByPrecedes($0, $1, sourceUid: sourceUid, myUid: myUid)
                    }
                    await MainActor.run {
                        guard bookId == book.id else { return }
                        readByReaders = sorted
                        refreshMatchScore()
                    }
                }
            }
            if showRecommend && canRecommendBook && appState.authUserId != nil && recommendReaders.isEmpty {
                recommendLoading = true
                Task {
                    let myUid = appState.authUserId
                    let following = (appState.currentUser?.following ?? []).filter {
                        $0 != myUid && !HiddenAccounts.isHidden(uid: $0, viewerUid: myUid)
                    }
                    let users = await UserRepository().getUsers(uids: following)
                    recommendReaders = following
                        .compactMap { uid in users[uid].map { RecommendReader(uid: uid, user: $0) } }
                        .sorted { $0.user.displayName.localizedCaseInsensitiveCompare($1.user.displayName) == .orderedAscending }
                    recommendLoading = false
                }
            }

            profileTags = []
            tagsLoading = true
            summaryLoading = true
            quoteLoading = true

            async let tagsTask = BookProfileService.shared.profileTags(for: book)
            async let summaryTask = BookProfileService.shared.twoSentenceSummary(for: book)
            async let quoteTask = BookProfileService.shared.notableQuote(for: book)

            let (tags, sum, quote) = await (tagsTask, summaryTask, quoteTask)
            profileTags = tags
            tagsLoading = false
            refreshMatchScore()
            summary = sum
            summaryLoading = false
            notableQuote = quote
            quoteLoading = false

            if let read = readBooksForSimilar, !read.isEmpty {
                similarLoading = true
                similarBooks = await BookProfileService.shared.similarBooks(for: book, readBooks: read)
                similarLoading = false
            }
        }
    }

    // MARK: - Hero

    /// Badge label + color for the current user's status with this book.
    /// `nil` (no relationship) → no badge.
    private var statusBadge: (label: String, color: Color)? {
        guard let ub = appState.userBooks.first(where: { $0.bookId == book.id }) else { return nil }
        switch ub.status {
        case .read:
            return ("READ", Color(red: 0.65, green: 0.85, blue: 0.60))
        case .currentlyReading:
            return ("READING NOW", Theme.punch)
        case .wantToRead:
            switch ub.queueShelf {
            case .readingNow: return ("READING NOW", Theme.punch)
            case .upNext: return ("UP NEXT", Theme.accent)
            case .backlog, nil: return ("BACKLOG", Theme.chromeStrong)
            }
        case .didNotFinish:
            return ("DID NOT FINISH", Theme.textTertiary)
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
            // Real layout slot (not an overlay hanging outside the cover's
            // bounds — those don't hit-test reliably) with reserved height so
            // the cover doesn't jump when the control appears.
            coverFixControl
                .frame(height: 22, alignment: .leading)
                .opacity(coverFixState == .hidden ? 0 : 1)
            BookCoverView(book: book, size: 220)
                .shadow(color: Theme.shadowInk.opacity(0.18), radius: 14, x: 0, y: 6)
                .overlay(alignment: .topLeading) {
                    if let reading = readingNowEntry {
                        CoverProgressRibbon(
                            fraction: liveProgress ?? reading.progressFraction,
                            coverWidth: 220,
                            coverHeight: 330
                        )
                        .animation(heroRibbonAnimation, value: liveProgress ?? reading.progressFraction)
                    }
                }
                // Mid-read the bookmark ribbon owns the top edge, so the badge
                // hangs off the bottom corner instead of covering the ribbon.
                .overlay(alignment: readingNowEntry == nil ? .topTrailing : .bottomTrailing) {
                    if let badge = statusBadge {
                        if badge.label == "READ" {
                            Button {
                                if let ub = currentUserReadEntry { userBookToEdit = ub }
                            } label: {
                                Text(badge.label)
                                    .font(.system(size: 16, weight: .bold))
                                    .tracking(1.2)
                                    .foregroundStyle(Theme.inkFixed)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(Capsule().fill(badge.color))
                                    .overlay(Capsule().stroke(Theme.paperFixed.opacity(0.85), lineWidth: 2))
                                    .rotationEffect(.degrees(6))
                                    .shadow(color: Theme.shadowInk.opacity(0.25), radius: 5, x: 0, y: 2)
                                    // Hang off the corner so it only clips the very top of the cover.
                                    .offset(x: 18, y: -18)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(badge.label)
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(Theme.onChrome)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(badge.color))
                                .overlay(Capsule().stroke(Theme.onChrome.opacity(0.85), lineWidth: 1.5))
                                .rotationEffect(.degrees(readingNowEntry == nil ? 6 : -6))
                                .shadow(color: Theme.shadowInk.opacity(0.25), radius: 4, x: 0, y: 2)
                                .offset(x: 14, y: readingNowEntry == nil ? -10 : 10)
                        }
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if !readByReaders.isEmpty {
                        readByAvatarFan
                            .offset(x: -14, y: 12)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Founder-only debug caption: which API served this cover, for
                    // judging source quality. Barely-there by request.
                    if let source = coverSourceLabel {
                        Text(source)
                            .font(.system(size: 8, weight: .regular))
                            .foregroundStyle(Theme.textTertiary.opacity(0.35))
                            .offset(y: 14)
                    }
                }
                .id(coverEpoch)
            }

            VStack(spacing: 4) {
                Text(book.title)
                    .font(Theme.title())
                    .tracking(Theme.displayTracking)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(book.author)
                    .font(Theme.callout())
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                if let metaLine = publishedMetaLine {
                    Text(metaLine)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Theme.textTertiary)
                }

                if let match = matchScore {
                    matchBadge(match)
                        .padding(.top, 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.horizontal, 24)

            BrandRule(width: 44)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .task(id: coverEpoch) { await refreshCoverFixAvailability() }
    }

    // MARK: - Cover regeneration

    /// Deliberately quiet: 11pt tertiary ink under the cover. It reads as a
    /// caption until you need it.
    @ViewBuilder
    private var coverFixControl: some View {
        Group {
            switch coverFixState {
            case .hidden:
                EmptyView()
            case .idle:
                // Plain text + tap gesture (not Button): the accessibility
                // "Button Shapes" setting underlines text buttons, which reads
                // as clutter on something meant to whisper.
                coverFixLabel("Bad cover?", icon: "arrow.triangle.2.circlepath")
                    .onTapGesture { runCoverRegenerate() }
                    .accessibilityAddTraits(.isButton)
            case .working:
                coverFixLabel("finding another cover…", icon: nil)
            case .regenerated:
                HStack(spacing: 10) {
                    coverFixLabel("try another", icon: "arrow.triangle.2.circlepath")
                        .onTapGesture { runCoverRegenerate() }
                        .accessibilityAddTraits(.isButton)
                    Text("·")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Theme.textTertiary.opacity(0.5))
                    coverFixLabel("undo", icon: "arrow.uturn.backward")
                        .onTapGesture { runCoverUndo() }
                        .accessibilityAddTraits(.isButton)
                }
            case .exhausted:
                HStack(spacing: 10) {
                    coverFixLabel("None available.", icon: nil)
                    // Undo only makes sense when an earlier regeneration is showing.
                    if CoverRegenerationService.shared.hasActiveSession(bookId: book.id) {
                        Text("·")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(Theme.textTertiary.opacity(0.5))
                        coverFixLabel("undo", icon: "arrow.uturn.backward")
                            .onTapGesture { runCoverUndo() }
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: coverFixState)
    }

    private func coverFixLabel(_ text: String, icon: String?) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 7.5, weight: .medium))
            }
            Text(text)
                .font(.system(size: 10, weight: .regular))
        }
        // Half-faded tertiary ink: legible when you look for it, invisible when
        // you don't. The padding keeps the tap target usable at this size.
        .foregroundStyle(Theme.textTertiary.opacity(0.5))
        .padding(.vertical, 4)
        .padding(.trailing, 6)
        .contentShape(Rectangle())
    }

    /// The control appears only once a real cover image has resolved — polling a
    /// few times covers the first-ever load, which can take several seconds.
    private func refreshCoverFixAvailability() async {
        updateCoverSourceLabel()
        if CoverRegenerationService.shared.hasActiveSession(bookId: book.id) {
            coverFixState = .regenerated
            return
        }
        guard coverFixState == .hidden else { return }
        for delay in [0.0, 1.0, 2.5, 5.0, 6.0] {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if Task.isCancelled { return }
            if CoverRegenerationService.shared.canRegenerate(book: book) {
                coverFixState = .idle
                updateCoverSourceLabel()
                return
            }
            // Chain already gave up (title placeholder showing) — offer the
            // control immediately anyway; tapping it re-probes the APIs.
            if CoverRegenerationService.shared.hasRecordedFailure(book: book) {
                coverFixState = .idle
                return
            }
        }
        // Still nothing after the polling window (slow network, or a book with no
        // candidate URLs at all). Show the control regardless: a tap runs the
        // retry path, and iTunes can sometimes find artwork the chain can't.
        if !Task.isCancelled, coverFixState == .hidden {
            coverFixState = .idle
        }
    }

    /// Founder-only ("@tan"): stamp the resolved cover's API under the cover so
    /// Tanner can eyeball which sources produce good vs. bad covers.
    private func updateCoverSourceLabel() {
        guard appState.authUserId == SpineFounder.uid else {
            coverSourceLabel = nil
            return
        }
        coverSourceLabel = CoverRegenerationService.shared.resolvedCoverURL(for: book)
            .map(CoverRegenerationService.coverSource(for:))
    }

    private func runCoverRegenerate() {
        guard let uid = appState.authUserId else { return }
        coverFixState = .working
        Task {
            let service = CoverRegenerationService.shared
            // No cover ever resolved (title placeholder showing): the tap is a
            // plain retry — re-ping the APIs, no override, no session.
            if !service.canRegenerate(book: book), !service.hasActiveSession(bookId: book.id) {
                let found = await service.retryResolve(book: book)
                guard found, service.canRegenerate(book: book) else {
                    coverFixState = .exhausted
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if coverFixState == .exhausted { coverFixState = .idle }
                    return
                }
                // The retry just locked the cover that was already on screen (it
                // came from the image cache, so the chain never recorded a
                // winner). Stopping here would leave the tap looking dead, so
                // fall through and do the regeneration the member asked for.
                coverEpoch += 1
            }
            let outcome = await service.regenerate(book: book, userId: uid)
            switch outcome {
            case .applied:
                coverEpoch += 1
                coverFixState = .regenerated
            case .exhausted:
                if service.hasActiveSession(bookId: book.id) {
                    // "None available." stays up, with undo beside it.
                    coverFixState = .exhausted
                } else {
                    coverFixState = .exhausted
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if coverFixState == .exhausted { coverFixState = .idle }
                }
            case .failed:
                coverFixState = .idle
            }
        }
    }

    private func runCoverUndo() {
        guard let uid = appState.authUserId else { return }
        CoverRegenerationService.shared.undo(book: book, userId: uid)
        coverEpoch += 1
        coverFixState = .idle
    }

    // MARK: - Match score

    /// Monochrome match ramp — strong matches get full ink, weak ones fade toward the page.
    private func matchColor(_ score: Int) -> Color {
        if score >= 80 { return Theme.chrome }
        if score >= 60 { return Theme.textSecondary }
        return Theme.textTertiary
    }

    private func matchBadge(_ score: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .bold))
            Text("\(score)% MATCH")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.8)
        }
        .foregroundStyle(matchColor(score))
        .accessibilityLabel("\(score) percent match for you")
    }

    /// Recomputes the % match. Called once profile tags land and again when
    /// followed readers' entries arrive, so the score refines as data loads.
    private func refreshMatchScore() {
        let bookId = book.id
        let tags = profileTags
        // Trust weighting stays follow-scoped even though the section now lists everyone.
        let friendEntries = readByReaders.filter(\.isFollowed).map(\.entry)
        let library = appState.userBooks
        let user = appState.currentUser
        Task {
            let score = await MatchScoreService.shared.matchScore(
                for: book,
                profileTags: tags,
                library: library,
                user: user,
                friendEntries: friendEntries
            )
            await MainActor.run {
                guard bookId == book.id else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    matchScore = score
                }
                if let score, score > 50 {
                    loadWhyLike()
                }
            }
        }
    }

    // MARK: - Why you might like it

    /// Generates the personalized blurb once the match clears 50%. Guarded so
    /// the second match refresh (when friend entries land) doesn't double-fire.
    private func loadWhyLike() {
        guard whyLikeText == nil, !whyLikeLoading else { return }
        whyLikeLoading = true
        let bookId = book.id
        let library = appState.userBooks
        let user = appState.currentUser
        Task {
            let text = await BookProfileService.shared.whyYouMightLikeIt(for: book, library: library, user: user)
            await MainActor.run {
                guard bookId == book.id else { return }
                whyLikeText = text
                whyLikeLoading = false
            }
        }
    }

    /// Match-branded card: same sparkles + ink-ramp imagery as the hero badge,
    /// with the % match echoed in the title row.
    private func whyLikeWindow(_ score: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if whyLikeLoading {
                // Blurb runs up to three sentences — about five body lines here.
                ShimmerTextBlock(lines: 5)
            } else if let t = whyLikeText, !t.isEmpty {
                Text(markdown: t)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(Theme.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .hingeSectionCard(title: "Why You Might Like It", accent: matchColor(score)) {
            matchBadge(score)
        }
    }

    // MARK: - Review window

    private func reviewWindow(ub: UserBook) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let text = ub.reviewText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                Text(text)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(Theme.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !ub.allReadDates.isEmpty {
                reviewFooter(ub: ub)
            }
            if canEditReadReview {
                OwnReadEngagementRow(book: book)
            }
        }
        .hingeSectionCard(title: reviewSectionHeading) {
            if canEditReadReview {
                Button {
                    userBookToEdit = ub
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.background)
                        .padding(7)
                        .background(Circle().fill(Theme.chrome))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        } titleAccessory: {
            if let t = ub.tier {
                TierBadge(tier: t, size: .mini)
            }
        }
    }

    /// Read date(s), every recorded read, so re-reads are visible.
    private func reviewFooter(ub: UserBook) -> some View {
        let dates = ub.allReadDates
        return (
            Text(dates.count > 1 ? "read \u{00D7}\(dates.count): " : "read: ")
                .foregroundColor(Theme.chrome)
            + Text(dates.map { ReadDate.label($0, formatter: Self.readDateFormatter) }.joined(separator: " \u{00B7} "))
                .foregroundColor(Theme.textTertiary)
        )
        .font(.system(size: 12, weight: .medium))
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let readDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    // MARK: - Reading progress window

    /// Big percent + page position over the bookmark scrubber. Own Reading now
    /// books only; writes through `AppState.setReadingProgress`.
    private func readingProgressWindow(ub: UserBook) -> some View {
        let fraction = liveProgress ?? ub.progressFraction
        let percent = Int((fraction * 100).rounded())
        let pages = book.pageCount ?? ub.book?.pageCount
        let pageLine: String? = {
            guard let pages, pages > 0 else { return nil }
            let page = fraction >= 0.999 ? pages : UserBook.page(forFraction: fraction, pageCount: pages)
            return "Page \(page) of \(pages)"
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(percent)")
                        .font(.system(size: 44, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText(value: Double(percent)))
                    Text("%")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                if let pageLine {
                    Text(pageLine)
                        .font(Theme.callout())
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .contentTransition(.numericText())
                } else if ub.readingProgress == nil {
                    Text("Slide the bookmark to track your progress")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            ReadingProgressScrubber(
                fraction: ub.progressFraction,
                onLiveChange: { liveProgress = $0 },
                onCommit: { value in
                    let previous = ub.progressFraction
                    liveProgress = nil
                    appState.setReadingProgress(userBookId: ub.id, progress: value)
                    if FinishCelebration.crossedFinishLine(previous: previous, committed: value) {
                        FinishCelebration.haptic()
                        fireProgressConfetti()
                        withAnimation(.snappy(duration: 0.28, extraBounce: 0.25)) { progressFinishPop = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { progressFinishPop = false }
                        }
                    }
                }
            )
            if fraction >= 0.999, liveProgress == nil {
                Text("Done? Tap FINISHED! below to rank it and post.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .hingeSectionCard(title: "YOUR PROGRESS")
        .scaleEffect(progressFinishPop ? 1.02 : 1)
        // Window-space frame so the confetti host can aim the burst at the
        // bookmark without mounting it inside this card, where the scroll view
        // and the card's own background would clip it.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { progressCardFrame = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: fraction >= 0.999 && liveProgress == nil)
    }

    /// Throw confetti from the bookmark's resting spot on the progress card, in
    /// window coordinates so the full-screen host draws it unclipped.
    private func fireProgressConfetti() {
        guard progressCardFrame != .zero else { return }
        FinishConfettiCenter.shared.fire(
            from: CGPoint(
                x: progressCardFrame.minX + progressCardFrame.width * 0.93,
                y: progressCardFrame.minY + progressCardFrame.height * 0.72
            )
        )
    }

    // MARK: - Re-read flow

    /// The current user's read row for this book (nil when it's not on their shelf).
    private var currentUserReadEntry: UserBook? {
        appState.userBooks.first { $0.bookId == book.id && $0.status == .read }
    }

    /// Existing read logs shown in the "Did you read this book again?" prompt.
    private var rereadLogMessage: String {
        let dates = (currentUserReadEntry?.allReadDates ?? []).sorted(by: >)
        guard !dates.isEmpty else { return "It's already on your read shelf." }
        let list = dates.map { ReadDate.label($0, formatter: Self.readDateFormatter) }.joined(separator: "\n")
        return "You've read it \(dates.count == 1 ? "once" : "\(dates.count) times"):\n\(list)"
    }

    /// Reads already on the shelf, shown under the header of the re-read drawer.
    private var rereadSubtitle: String? {
        let dates = (currentUserReadEntry?.allReadDates ?? []).sorted(by: >)
        guard !dates.isEmpty else { return nil }
        let list = dates.map { ReadDate.label($0, formatter: Self.readDateFormatter) }.joined(separator: ", ")
        return "Already logged: \(list)"
    }

    /// Log the drawer's date as another read of this book, carrying the thoughts,
    /// tier, and feed choice it collected onto the existing read entry.
    private func logReread(date: Date, thoughts: String?, tier: String?, postToFeed: Bool) {
        Task {
            if let err = await appState.logAdditionalRead(
                book: book,
                date: date,
                thoughts: thoughts,
                tier: tier,
                postToFeed: postToFeed
            ) {
                await MainActor.run {
                    ToastCenter.shared.show(Toast(style: .error, status: "Failed", message: err))
                }
            }
        }
    }

    /// Unmark this book as read — removes the read entry along with its review
    /// and any finished-book feed post (same cascade as the edit sheet's delete).
    private func removeFromRead() {
        guard let ub = currentUserReadEntry else { return }
        let title = book.title
        Task {
            let err = await appState.deleteReadReview(userBook: ub)
            await MainActor.run {
                if let err {
                    ToastCenter.shared.show(Toast(style: .error, status: "Failed", message: err))
                } else {
                    ToastCenter.shared.show(Toast(style: .success, status: "Removed", message: "\u{201C}\(title)\u{201D} removed from your read shelf"))
                }
            }
        }
    }

    private static let publishedYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f
    }()

    /// "2018 • 322 pages" — either half stands alone when the other is missing.
    private var publishedMetaLine: String? {
        var parts: [String] = []
        if let published = book.publishedDate {
            parts.append(Self.publishedYearFormatter.string(from: published))
        }
        if let pages = book.pageCount, pages > 0 {
            parts.append("\(pages) pages")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{2022} ")
    }

    // MARK: - Refresher window

    /// Read-books-only card: one tap opens the AI refresher sheet (recap + Q&A).
    private var refresherWindow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read it a while ago? Get a recap of the plot, characters, and takeaways — then ask follow-up questions.")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showRefresher = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                    Text("REFRESH MY MEMORY")
                        .font(.system(size: 13, weight: .bold))
                        .tracking(1)
                }
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                        .fill(Theme.gloss(Theme.accent))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Theme.phosphorWhite.opacity(0.45), Theme.phosphorWhite.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Theme.accent.opacity(0.32), radius: 8, x: 0, y: 3)
            }
            .buttonStyle(.springPress)
        }
        .hingeSectionCard(title: "Refresher", accent: Theme.accent)
    }

    // MARK: - Summary window

    private var summaryWindow: some View {
        VStack(alignment: .leading, spacing: 12) {
            if summaryLoading {
                // Summary is hard-capped at 200 characters, which renders as
                // ~5 body lines in this card — matching it keeps the card from
                // jumping when the text arrives.
                ShimmerTextBlock(lines: 5)
            } else if let s = summary, !s.isEmpty {
                Text(markdown: s)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(Theme.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                emptyState(text: "summary unavailable")
            }

            if tagsLoading {
                // Chip-shaped shimmers at tagChip dimensions, wrapped by the
                // same FlowLayout as the real tags (~5 tags → two rows).
                FlowLayout(spacing: 6) {
                    ForEach(Array([96, 110, 82, 124, 74].enumerated()), id: \.offset) { _, width in
                        ShimmerShape(shape: RoundedRectangle(cornerRadius: 4))
                            .frame(width: CGFloat(width), height: 22)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } else if !profileTags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(profileTags, id: \.self) { tag in
                        tagChip(tag)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
        .hingeSectionCard(title: "Summary") {
            Button {
                showSummaryMore = true
            } label: {
                HStack(spacing: 3) {
                    Text("MORE")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Theme.chrome)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More about this book")
        }
    }

    private func tagChip(_ tag: String) -> some View {
        Text(tag.lowercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Theme.chrome)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.chrome.opacity(0.5), lineWidth: 1)
            )
    }

    // MARK: - Similar window

    private var similarWindow: some View {
        VStack(alignment: .leading, spacing: 12) {
            if similarLoading {
                // Cover + title-caption skeletons at the loaded tile's exact
                // footprint (52pt cover, 64pt caption column) so the row keeps
                // its height when real books swap in.
                HStack(alignment: .top, spacing: 14) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(spacing: 6) {
                            ShimmerShape(shape: RoundedRectangle(cornerRadius: 6))
                                .frame(width: 52, height: 52 * 1.5)
                            ShimmerBar(height: 8, cornerRadius: 3)
                                .frame(width: 48)
                        }
                        .frame(width: 64)
                    }
                }
                .padding(.vertical, 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(similarBooks) { similar in
                            VStack(spacing: 6) {
                                BookCoverView(book: similar, size: 52, onTap: onBookTap != nil ? { onBookTap?(similar) } : nil)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(similar.title)
                                    .font(.system(size: 10, weight: .regular))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 64)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .hingeSectionCard(title: "Similar Books")
    }

    // MARK: - Quote window

    private var quoteWindow: some View {
        VStack(alignment: .leading, spacing: 12) {
            if quoteLoading {
                // Mirror the loaded layout (big quote mark + text) so only the
                // shimmer swaps out when the quote lands.
                HStack(alignment: .top, spacing: 8) {
                    Text("\u{201C}")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.chrome.opacity(0.35))
                        .offset(y: -2)
                        .accessibilityHidden(true)
                    ShimmerTextBlock(lines: 2, lastLineTrailingCut: 90)
                        .padding(.top, 6)
                }
            } else if let q = notableQuote, !q.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("\u{201C}")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.chrome)
                        .offset(y: -2)
                        .accessibilityHidden(true)
                    Text(q)
                        .font(Theme.body())
                        .italic()
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(Theme.bodyLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                emptyState(text: "no notable quote available")
            }
        }
        .hingeSectionCard(title: "Notable Quote", accent: Theme.chromeStrong)
    }

    // MARK: - Read by window

    /// Fanned avatars hanging off the cover's bottom-left corner — the readers
    /// the user follows who've finished this book. Mirrors ReadingNowFanStack.
    private var readByAvatarFan: some View {
        let shown = readByReaders.prefix(3)
        let overflow = readByReaders.count - shown.count
        return HStack(spacing: -12) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, reader in
                Button {
                    readByProfileToView = reader
                } label: {
                    readerAvatar(user: reader.user, size: 34)
                        .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                        .shadow(color: Theme.shadowInk.opacity(0.25), radius: 3, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .zIndex(Double(shown.count - index))
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.onChrome)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.chromeStrong))
                    .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                    .shadow(color: Theme.shadowInk.opacity(0.25), radius: 3, x: 0, y: 2)
            }
        }
    }

    /// "Read by" ordering: the source reader (whose tier list or feed post led
    /// here) pins to the top, then your own read, then people you follow, then
    /// best-ranked first (S → F, unranked last), most recently finished
    /// breaking ties.
    private static func readByPrecedes(_ a: BookDiscussionReader, _ b: BookDiscussionReader, sourceUid: String?, myUid: String?) -> Bool {
        if let sourceUid, (a.uid == sourceUid) != (b.uid == sourceUid) {
            return a.uid == sourceUid
        }
        if let myUid, (a.uid == myUid) != (b.uid == myUid) {
            return a.uid == myUid
        }
        if a.isFollowed != b.isFollowed { return a.isFollowed }
        let aRank = a.entry.normalizedTier.flatMap(spineTierLabels.firstIndex(of:)) ?? spineTierLabels.count
        let bRank = b.entry.normalizedTier.flatMap(spineTierLabels.firstIndex(of:)) ?? spineTierLabels.count
        if aRank != bRank { return aRank < bRank }
        return (a.entry.dateFinished ?? .distantPast) > (b.entry.dateFinished ?? .distantPast)
    }

    private var readByWindow: some View {
        BookDiscussionSection(
            book: book,
            readers: readByReaders,
            sourceReaderUid: sourceReaderUid,
            onOpenProfile: { readByProfileToView = $0 }
        )
    }

    // MARK: - Recommend window

    /// Windowed section (below My Review, or the Read by/Refresher cards when
    /// there's no review):
    /// people you follow, each with a Send button to recommend this book;
    /// tapping the avatar opens their profile. The dashed tile texts an
    /// invite to someone who isn't on Spine yet. Only offered for books the
    /// user is currently reading or has finished.
    @ViewBuilder
    private var recommendSection: some View {
        if showRecommend, canRecommendBook, appState.authUserId != nil {
            recommendWindow
                .padding(.horizontal)
        }
    }

    private var recommendWindow: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recommendLoading {
                // Placeholder tiles matching recommendReaderTile's footprint
                // (52pt avatar, name line, 22pt SEND row) so the card holds
                // its size instead of growing when readers load.
                HStack(alignment: .top, spacing: 14) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(spacing: 6) {
                            ShimmerCircle(size: 52)
                            ShimmerBar(height: 8, cornerRadius: 3)
                                .frame(width: 40)
                            ShimmerShape(shape: Capsule())
                                .frame(width: 56, height: 22)
                        }
                        .frame(width: 64)
                    }
                }
                .padding(.vertical, 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(recommendReaders) { reader in
                            recommendReaderTile(reader)
                        }
                        inviteTile
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .hingeSectionCard(title: "Recommend to a Friend")
    }

    private func recommendReaderTile(_ reader: RecommendReader) -> some View {
        let sent = recommendSentTo.contains(reader.uid)
        let sending = recommendSendingTo.contains(reader.uid)
        return VStack(spacing: 6) {
            Button {
                recommendProfileToView = reader
            } label: {
                VStack(spacing: 6) {
                    readerAvatar(user: reader.user)
                    Text(firstName(of: reader.user))
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .frame(width: 64)
                }
            }
            .buttonStyle(.plain)

            Group {
                if sent {
                    Text("SENT ✓")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.vertical, 4)
                } else if sending {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.accent)
                        .padding(.vertical, 4)
                } else {
                    Button {
                        sendRecommendation(to: reader)
                    } label: {
                        Text("SEND")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().stroke(Theme.accent.opacity(0.6), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 22)
        }
    }

    /// First name only under the avatar; falls back to the first word of the display name.
    private func firstName(of user: User) -> String {
        if let first = user.firstName?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty {
            return first
        }
        return user.displayName.components(separatedBy: " ").first ?? user.displayName
    }

    private var inviteTile: some View {
        Button {
            if MessageComposeView.canSendText {
                showInviteCompose = true
            } else {
                cantSendTextAlert = true
            }
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(Theme.surface)
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: "plus.message")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.chrome)
                    )
                    .overlay(
                        Circle()
                            .stroke(Theme.chrome.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    )
                Text("invite via text")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 64)
            }
        }
        .buttonStyle(.plain)
    }

    private func readerAvatar(user: User, size: CGFloat = 52) -> some View {
        UserAvatarView(
            urlString: user.profileImageURL,
            displayName: user.displayName,
            firstName: user.firstName,
            lastName: user.lastName,
            size: size
        )
    }

    private func sendRecommendation(to reader: RecommendReader) {
        guard let fromUid = appState.authUserId else { return }
        recommendSendingTo.insert(reader.uid)
        Task {
            do {
                _ = try await RecommendationRepository().send(
                    fromUserId: fromUid,
                    toUserId: reader.uid,
                    book: book,
                    note: nil
                )
                await MainActor.run {
                    recommendSendingTo.remove(reader.uid)
                    recommendSentTo.insert(reader.uid)
                    ToastCenter.shared.show(.recommendationSent(to: reader.user.displayName))
                }
            } catch {
                await MainActor.run {
                    recommendSendingTo.remove(reader.uid)
                    ToastCenter.shared.show(
                        Toast(style: .error, status: "Failed", message: "Couldn't send to \(reader.user.displayName)")
                    )
                }
            }
        }
    }

    // MARK: - Loading / empty helpers

    private func emptyState(text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .regular))
            .tracking(0.5)
            .foregroundStyle(Theme.textTertiary)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 10) {
            if showShelfAction, let title = shelfActionTitle {
                Button(action: { onAddToShelf?() }) {
                    actionLabel(title, foreground: Theme.background, background: Theme.accent, border: .clear)
                }
                .buttonStyle(.springPress)
            }
            actionButtonRow
        }
        .padding(.horizontal)
        .padding(.top, 10)
        // No panel or divider behind the buttons (Blackbird-style): they float
        // over the page, which reads as more usable screen. The buttons' own
        // fills and shadows carry the separation.
        .padding(.bottom, 14)
    }

    private var actionButtonRow: some View {
        // Order is deliberate: dismissal on the far left, then the shelf actions
        // in reading-lifecycle order with the primary QUEUE on the thumb side.
        HStack(spacing: 10) {
            if onNotInterested != nil {
                Button(action: { onNotInterested?() }) {
                    passIconLabel
                }
                .buttonStyle(.springPress)
                .accessibilityLabel("Pass on this book")
            }
            if onStartReading != nil {
                Button(action: { onStartReading?() }) {
                    actionLabel("READING", foreground: Theme.textSecondary, background: Theme.surface, border: Theme.chrome.opacity(0.5))
                }
                .buttonStyle(.springPress)
            }
            // On the Reading Now shelf, DNF (give up on this book) sits left of
            // FINISHED so FINISHED stays the rightmost, thumb-side action —
            // reading-lifecycle order (start → give up or finish) rather than
            // the add/remove-from-queue order used everywhere else.
            if showReadingNowDNF {
                Button(action: { onMarkAsDNF?() }) {
                    actionLabel("DNF", foreground: Theme.phosphorWhite, background: Theme.danger, border: .clear)
                }
                .buttonStyle(.springPress)
            }
            if onConfirmRead != nil {
                Button(action: {
                    if isOnReadList {
                        showRereadPrompt = true
                        return
                    }
                    showMarkAsReadModal = true
                }) {
                    actionLabel(
                        isCurrentlyReading ? "FINISHED!" : "FINISHED",
                        foreground: Theme.background,
                        background: Theme.textTertiary,
                        border: .clear
                    )
                }
                .buttonStyle(.springPress)
            }
            if !showReadingNowDNF, onWantToRead != nil || onRemoveFromQueue != nil {
                Group {
                    if isInQueue && onRemoveFromQueue != nil {
                        Button(action: { onRemoveFromQueue?() }) {
                            actionLabel("REMOVE", foreground: Theme.phosphorWhite, background: Theme.danger, border: .clear)
                        }
                        .buttonStyle(.springPress)
                    } else {
                        Button(action: { onWantToRead?() }) {
                            // When a shelf CTA is the primary action, QUEUE steps down to an
                            // outline style so there's a single clear main button.
                            actionLabel(
                                "QUEUE",
                                foreground: showShelfAction ? Theme.textSecondary : Theme.background,
                                background: showShelfAction ? Theme.surface : Theme.accent,
                                border: showShelfAction ? Theme.chrome.opacity(0.5) : .clear
                            )
                        }
                        .buttonStyle(.springPress)
                    }
                }
            }
        }
    }

    /// Compact ✕ dismissal — fixed width so it reads as "the exit," not a fourth
    /// peer action alongside the shelf buttons.
    private var passIconLabel: some View {
        Image(systemName: "xmark")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 48)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .fill(Theme.gloss(Theme.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Theme.phosphorWhite.opacity(0.45), Theme.phosphorWhite.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .stroke(Theme.chrome.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: Theme.surface.opacity(0.32), radius: 8, x: 0, y: 3)
    }

    private func actionLabel(_ text: String, foreground: Color, background: Color, border: Color) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .tracking(1)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .fill(Theme.gloss(background))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Theme.phosphorWhite.opacity(0.45), Theme.phosphorWhite.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .stroke(border, lineWidth: 1)
            )
            .shadow(color: background.opacity(0.32), radius: 8, x: 0, y: 3)
    }
}

private extension Optional where Wrapped == [UserBook] {
    var isEmptyOrNil: Bool {
        self == nil || self?.isEmpty == true
    }
}
