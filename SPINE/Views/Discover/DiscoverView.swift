//
//  DiscoverView.swift
//  SPINE
//
//  Full-screen Tinder-style discovery: one book at a time, two decisions.
//  Swipe left (or tap X) to skip, swipe right (or tap +) to queue; the
//  DiscoverSwipeDeck owns the gesture and the stamps.
//  Suggestions are prefetched when the tab bar appears so the first suggestion is ready when user taps Discover.
//

import SwiftUI

/// How a visit to Discover started, for analytics ("Entered Discover" and the
/// `entry_point` property on every Discover event).
enum DiscoverEntryPoint: String {
    /// A book in the feed's "Selected for you" row.
    case feedBookPick = "feed_book_pick"
    /// The "Discover more" tile at the end of that row.
    case feedSeeMore = "feed_see_more"
    /// The Discover tab in the tab bar (tap or lens drag).
    case tabBar = "tab_bar"
    /// Anything else (the spineOpenDiscover route, debug launch flags).
    case other

    /// userInfo key on `.spineOpenDiscoverFromFeed`.
    static let userInfoKey = "discoverEntryPoint"
}

struct DiscoverView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject private var queueDragCoordinator: QueueBookDragCoordinator
    @State private var selectedBookForProfile: Book?
    @State private var bookWeCameFrom: Book?
    @State private var showCriteriaEditor = false
    /// Books the user has acted on in Discover (pass/queue/read). Each action
    /// advances to a fresh suggestion, so every increment is a distinct book.
    /// DiscoverCriteriaStrip reads this to hold its tune callout until 3.
    @AppStorage("discoverActionedBookCount") private var actionedBookCount = 0
    /// First visit to Discover ever: the mood sheet opens itself a beat after
    /// the page settles so the very first suggestions are ones they asked for.
    @AppStorage("discoverMoodSheetAutoShown") private var hasAutoShownMoodSheet = false
    /// The last swipe's outcome, flashed as a badge over the deck for a beat
    /// after the card is gone. The token lets a quick second decision replace
    /// the first badge instead of being cut short by its auto-dismiss.
    @State private var decisionBadge: (decision: DiscoverSwipeDecision, token: UUID)?
    /// One-time coach for the swipe deck. Waits until a book is on the deck
    /// and the first-visit mood sheet is out of the way.
    @AppStorage("discoverSwipeCoachShown") private var hasShownSwipeCoach = false
    @State private var showSwipeCoach = false
    /// Dismissed during this launch (lets the debug force flag act once).
    @State private var swipeCoachDismissed = false
    /// True between the first-visit arrival and the mood sheet actually opening.
    @State private var moodSheetAutoOpenPending = false
    /// Discover is on screen (it is torn down on tab switch, so appear and
    /// disappear bracket the visit). Suggestions prefetch before the first
    /// visit, so a new current suggestion alone doesn't mean anyone saw it.
    @State private var isOnScreen = false
    /// Last book logged as "Shown Discover Book". Static so leaving the tab
    /// and coming back to the same card isn't a second impression; an undo
    /// brings back a different book, so that one does log again.
    private static var lastShownBookId: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    spineDiscoverHeader

                    DiscoverCriteriaStrip(
                        criteria: appState.discoverCriteria,
                        interestTagsCount: appState.currentUser?.readingInterestTags.count ?? 0,
                        onRemove: { appState.setDiscoverCriteria($0) },
                        onEdit: { openCriteriaEditor(source: "criteria_strip") },
                        bookForSeed: { seed in
                            appState.userBooks.first(where: { $0.bookId == seed.bookId })?.book
                        }
                    )
                    // Keep the tune-callout bubble (which hangs below the strip) above the content underneath.
                    .zIndex(1)

                    ZStack {
                        if appState.isLoadingDiscoverSuggestions && appState.discoverCurrentSuggestion == nil {
                            loadingView
                                .transition(.spinnerFadeOut)
                        } else if let book = appState.discoverCurrentSuggestion {
                            suggestionCardFullScreen(book: book)
                        } else {
                            emptyStateView
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // Came in from the feed's "Discover more" tile: the swipe back
                // from the left edge goes home to the feed, the way it would on
                // a pushed page. Simultaneous so the card underneath still
                // scrolls and swipes normally.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20).onEnded { value in
                        guard appState.discoverEnteredFromFeed,
                              value.startLocation.x <= 40,
                              value.translation.width > 70,
                              abs(value.translation.height) < 80 else { return }
                        returnToFeed()
                    }
                )

                // Whole-page coach (header and criteria strip included), once.
                if showSwipeCoach {
                    DiscoverSwipeCoachOverlay {
                        // Any dismissal ("Got it!" or a tap on the scrim) is
                        // final: never shown again on this install.
                        hasShownSwipeCoach = true
                        swipeCoachDismissed = true
                        withAnimation(.easeOut(duration: 0.25)) { showSwipeCoach = false }
                    }
                    .transition(.opacity)
                    .zIndex(2)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .navigationDestination(item: $selectedBookForProfile) { book in
                BookProfileView(
                    book: book,
                    readBooksForSimilar: appState.readBooks,
                    onNotInterested: { selectedBookForProfile = nil },
                    onWantToRead: { appState.addToWantToRead(book: book) },
                    onStartReading: { appState.addToQueue(book: book, shelf: .readingNow) },
                    onConfirmRead: { date, rating, post, caption, tier in appState.addAsRead(book: book, dateFinished: date, rating: rating, postToFeed: post, caption: caption, tier: tier); selectedBookForProfile = nil },
                    isOnReadList: appState.isBookOnReadList(bookId: book.id),
                    isInQueue: appState.isBookInQueue(bookId: book.id),
                    onRemoveFromQueue: { appState.removeFromQueue(book: book) },
                    onMarkAsDNF: { appState.markAsDNF(book: book) },
                    readEntryForReview: appState.userReadBook(forBookId: book.id),
                    canEditReadReview: true,
                    showRecommend: false
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if let prev = bookWeCameFrom {
                                appState.returnToDiscoverBook(prev)
                            }
                            bookWeCameFrom = nil
                            selectedBookForProfile = nil
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
            }
            // The feed handed over a specific book (a "Selected for you" cover
            // or the "Discover more" tile): make sure the deck is what's showing,
            // not a book profile pushed on an earlier visit.
            .onReceive(NotificationCenter.default.publisher(for: .spineOpenDiscoverFromFeed)) { _ in
                bookWeCameFrom = nil
                selectedBookForProfile = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .spineDiscoverTabTappedAgain)) { _ in
                // Re-tap on the Discover tab item: pop back to the suggestion root,
                // restoring the suggestion the user navigated away from (same as
                // the pushed book profile's back chevron).
                if let prev = bookWeCameFrom {
                    appState.returnToDiscoverBook(prev)
                }
                bookWeCameFrom = nil
                selectedBookForProfile = nil
            }
            .onAppear {
                if appState.discoverCurrentSuggestion == nil, !appState.discoverSuggestionQueue.isEmpty {
                    appState.advanceDiscoverSuggestion()
                } else if appState.discoverCurrentSuggestion == nil, appState.discoverSuggestionQueue.isEmpty, !appState.isLoadingDiscoverSuggestions {
                    appState.loadDiscoverSuggestionsIfNeeded()
                }
                autoShowMoodSheetOnFirstVisit()
                showSwipeCoachIfDue()
                isOnScreen = true
                logShownBookIfVisible()
            }
            .onDisappear { isOnScreen = false }
            .onChange(of: appState.discoverCurrentSuggestion?.id) { _, _ in
                showSwipeCoachIfDue()
                logShownBookIfVisible()
            }
            .onChange(of: showCriteriaEditor) { _, _ in
                showSwipeCoachIfDue()
                logShownBookIfVisible()
            }
            .onChange(of: selectedBookForProfile) { _, _ in logShownBookIfVisible() }
            .sheet(isPresented: $showCriteriaEditor) {
                DiscoverCriteriaEditorSheet(initial: appState.discoverCriteria)
                    .environmentObject(appState)
                    .environmentObject(queueDragCoordinator)
                    .presentationDetents([.large])
            }
        }
    }

    /// Banner at the top of the Discover tab.
    private var spineDiscoverHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            if appState.discoverEnteredFromFeed {
                Button {
                    returnToFeed()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 40, height: 32, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to the feed")
            }
            Text("DISCOVER")
                .font(.system(size: 22, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.textPrimary)
            BrandRule(width: 48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if !appState.discoverPassedBooks.isEmpty {
                undoPassButton
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Top-right undo: only there once something has been passed on this
    /// session. The u-turn glyph starts low, curves up, and heads back left.
    private var undoPassButton: some View {
        Button {
            undoLastPass()
        } label: {
            Image(systemName: "arrow.uturn.left")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Go back to the book you passed on")
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    private var loadingView: some View {
        // One flexible spacer above, two below: biases the group upward so it
        // reads as screen-centered despite the header eating the top ~180pt.
        VStack(spacing: 0) {
            Spacer()
            SpinningSpineLogo(size: 288)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        let cameUpEmpty = appState.discoverLoadCameUpEmpty
        return VStack(spacing: 24) {
            Spacer(minLength: 0)
            DiscoverSpineLogo()
            Text(cameUpEmpty ? "Nothing came up" : "Find my next read")
                .font(Theme.title())
                .foregroundStyle(Theme.textPrimary)
            if !cameUpEmpty {
                Text("Every pick is tailored to the books in your library and your interests. Steer it with tiers, tags, or books you loved.")
                    .font(Theme.body())
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button(cameUpEmpty ? "Try again" : "Start") {
                appState.loadDiscoverSuggestionsIfNeeded()
            }
            .buttonStyle(.spinePrimary)
            .padding(.horizontal, 40)
            .padding(.top, 8)
            .disabled(appState.isLoadingDiscoverSuggestions)
            Spacer(minLength: 0)
        }
    }

    private func suggestionCardFullScreen(book: Book) -> some View {
        DiscoverSwipeDeck(
            current: book,
            next: appState.discoverSuggestionQueue.first,
            showsSwipeHint: actionedBookCount < 5,
            hidesButtons: showSwipeCoach,
            badge: decisionBadge,
            onCommit: { decision, input in
                flashDecision(decision)
                logDecision(decision, book: book, input: input)
            },
            onDecision: { decision in
                switch decision {
                case .skip: performNotInterested(book)
                case .queue: performWantToRead(book)
                }
            },
            card: { cardBook in
                // No action bar: the deck's X and + are the only two decisions
                // here. Everything else (Reading, Finished) waits until the
                // book is queued and opened from the Queue. The next book's
                // card is built (and starts loading) while it waits underneath,
                // so it arrives already filled in.
                BookProfileView(
                    book: cardBook,
                    readBooksForSimilar: appState.readBooks,
                    onBookTap: { tappedBook in
                        bookWeCameFrom = appState.discoverCurrentSuggestion
                        selectedBookForProfile = tappedBook
                    },
                    isOnReadList: appState.isBookOnReadList(bookId: cardBook.id),
                    isInQueue: appState.isBookInQueue(bookId: cardBook.id),
                    readEntryForReview: appState.userReadBook(forBookId: cardBook.id),
                    canEditReadReview: true,
                    showRecommend: false,
                    reservesActionBarSpace: true,
                    showsCoverFix: false
                )
            },
            placeholder: { refillingCard }
        )
    }

    /// Fills the back-card slot while the batch refills: the Spine mark and a
    /// line of copy, in place of the next book.
    private var refillingCard: some View {
        VStack(spacing: 14) {
            DiscoverSpineLogo()
            Text("Finding more…")
                .font(Theme.title2())
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// Flash the outcome over the deck for a second.
    private func flashDecision(_ decision: DiscoverSwipeDecision) {
        let token = UUID()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.65)) {
            decisionBadge = (decision, token)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard decisionBadge?.token == token else { return }
            withAnimation(.easeOut(duration: 0.25)) { decisionBadge = nil }
        }
    }

    /// Back to the Feed tab, at the offset the reader left it (MainTabView
    /// owns the tab switch and hands the feed its scroll position back).
    private func returnToFeed() {
        Analytics.amplitude?.track(eventType: "Returned To Feed From Discover")
        NotificationCenter.default.post(name: .spineReturnToFeed, object: nil)
    }

    /// Open the mood sheet a second after the user's first ever arrival on
    /// Discover. Only once per install, and never on top of a pushed book
    /// profile or a sheet that is already up.
    private func autoShowMoodSheetOnFirstVisit() {
        guard !hasAutoShownMoodSheet else { return }
        hasAutoShownMoodSheet = true
        moodSheetAutoOpenPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            moodSheetAutoOpenPending = false
            guard selectedBookForProfile == nil, !showCriteriaEditor else {
                showSwipeCoachIfDue()
                return
            }
            openCriteriaEditor(source: "auto_first_visit")
        }
    }

    private func openCriteriaEditor(source: String) {
        var props = discoverCriteriaProperties
        props["source"] = source
        Analytics.amplitude?.track(eventType: "Opened Discover Preferences", eventProperties: props)
        showCriteriaEditor = true
    }

    // MARK: - Analytics

    /// Log an impression for the book on the deck, but only once it is
    /// actually in front of the reader: Discover on screen, no book profile
    /// pushed over it, no preferences sheet covering it.
    private func logShownBookIfVisible() {
        guard isOnScreen, selectedBookForProfile == nil, !showCriteriaEditor,
              let book = appState.discoverCurrentSuggestion,
              book.id != Self.lastShownBookId else { return }
        Self.lastShownBookId = book.id
        Analytics.amplitude?.track(eventType: "Shown Discover Book", eventProperties: discoverBookProperties(book))
    }

    private func logDecision(_ decision: DiscoverSwipeDecision, book: Book, input: DiscoverDecisionInput) {
        var props = discoverBookProperties(book)
        props["input"] = input.rawValue
        Analytics.amplitude?.track(
            eventType: decision == .queue ? "Queued Discover Book" : "Skipped Discover Book",
            eventProperties: props
        )
    }

    private func discoverBookProperties(_ book: Book) -> [String: Any] {
        var props = discoverCriteriaProperties
        props["book_id"] = book.id
        props["book_title"] = book.title
        props["book_author"] = book.author
        return props
    }

    /// How this visit started and which steering is active, so skip/queue
    /// rates can be split by either.
    private var discoverCriteriaProperties: [String: Any] {
        let c = appState.discoverCriteria
        return [
            "entry_point": appState.discoverEntryPoint,
            "has_custom_preferences": !c.isDefault,
            "seed_book_count": c.seedBooks.count,
            "tier_count": c.tiers.count,
            "tag_count": c.tags.count,
            "has_free_text": !c.trimmedFreeText.isEmpty,
        ]
    }

    /// First time there's a book on the deck with nothing on top of it: coach
    /// the swipe. Once per install. The mood sheet auto-opens on the very
    /// first visit, so this usually lands as that sheet closes.
    private func showSwipeCoachIfDue() {
        #if DEBUG
        let forced = ProcessInfo.processInfo.arguments.contains("-uiPreviewSwipeCoach") && !swipeCoachDismissed
        #else
        let forced = false
        #endif
        guard forced || !hasShownSwipeCoach, !showSwipeCoach else { return }
        guard appState.discoverCurrentSuggestion != nil, !showCriteriaEditor, selectedBookForProfile == nil else { return }
        // First visit: the mood sheet is about to open; the coach follows it.
        guard !moodSheetAutoOpenPending else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !showCriteriaEditor, !moodSheetAutoOpenPending, selectedBookForProfile == nil, appState.discoverCurrentSuggestion != nil else { return }
            withAnimation(.easeOut(duration: 0.3)) { showSwipeCoach = true }
        }
    }

    private func performNotInterested(_ book: Book) {
        appState.addDismissed(book: book)
        appState.discoverPassedBooks.append(book)
        actionedBookCount += 1
        withAnimation(.easeInOut(duration: 0.35)) {
            appState.advanceDiscoverSuggestion()
        }
    }

    /// Undo the last Pass, putting that book back on screen.
    private func undoLastPass() {
        // Event name predates the skip/queue events; kept so history lines up.
        if let book = appState.discoverPassedBooks.last {
            Analytics.amplitude?.track(eventType: "Undid Discover Pass", eventProperties: discoverBookProperties(book))
        }
        actionedBookCount = max(0, actionedBookCount - 1)
        withAnimation(.easeOut(duration: 0.2)) {
            appState.undoLastDiscoverPass()
        }
    }

    private func performWantToRead(_ book: Book) {
        appState.addToWantToRead(book: book)
        actionedBookCount += 1
        withAnimation(.easeInOut(duration: 0.35)) {
            appState.advanceDiscoverSuggestion()
        }
    }
}

struct DiscoverBookCard: View {
    let book: Book
    var onCoverTap: (() -> Void)? = nil
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BookCoverView(book: book, size: 100, onTap: onCoverTap)
            Text(book.title)
                .font(Theme.caption())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .frame(width: 100, alignment: .leading)
            Button("Queue") {
                onAdd()
            }
            .font(.caption2)
            .foregroundStyle(Theme.accent)
        }
        .frame(width: 100)
    }
}

/// Brand loading indicator: the SPINE mark spinning with a 4-second
/// cycle — it launches fast, bleeds off speed, and just as it's about to
/// stop it whips back up to full speed. Each cycle covers whole turns so the
/// repeat is seamless. Rotation is derived from the clock rather than an
/// animated state change so surrounding layout shifts can never be swept
/// into the animation (which made the logo fly in from offscreen).
///
/// Motion blur is faked with ghost copies trailing the mark along its arc;
/// the trail length follows the spin curve's angular velocity, so the blur
/// is heavy during the whip and melts away as the spin coasts.
struct SpinningSpineLogo: View {
    var size: CGFloat = 144

    private static let curve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.1, y: 0.8),
        endControlPoint: UnitPoint(x: 0.2, y: 1.0)
    )
    private static let ghostCount = 6

    /// Quick fade-in so the spinner doesn't pop onto the screen.
    @State private var appeared = false

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let progress = elapsed.truncatingRemainder(dividingBy: 4) / 4
            let angle = Self.curve.value(at: progress) * 1080
            // Degrees swept over the last few frames — the trail length.
            let sweep = min(Self.curve.velocity(at: progress) * 1080 / 4 * 0.05, 80)
            // Fade the whole trail out as the spin slows so the resting mark
            // stays crisp.
            let trailStrength = min(sweep / 10, 1)
            ZStack {
                ForEach(1...Self.ghostCount, id: \.self) { i in
                    let depth = Double(i) / Double(Self.ghostCount)
                    logo
                        .rotationEffect(.degrees(angle - sweep * depth))
                        .opacity(0.55 * (1 - depth * 0.85) * trailStrength)
                        .blur(radius: 2 + 5 * depth)
                }
                logo
                    .rotationEffect(.degrees(angle))
                    .blur(radius: 1.5 * trailStrength)
            }
        }
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.15)) { appeared = true }
        }
        .accessibilityHidden(true)
    }

    private var logo: some View {
        Image("SpineLogo")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Theme.accent)
    }
}

extension AnyTransition {
    /// Quick fade-out for a SpinningSpineLogo loading view as content replaces it.
    /// Carries its own animation, so the loading flag needn't flip inside
    /// withAnimation. The swap site must overlap the two branches (ZStack), or the
    /// fading spinner holds its space and shoves the content down mid-fade.
    static var spinnerFadeOut: AnyTransition {
        .asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.15)))
    }
}

/// SPINE brand mark for the Discover empty state: the transparent logo tinted
/// with the accent color.
private struct DiscoverSpineLogo: View {
    var body: some View {
        Image("SpineLogo")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 120, height: 120)
            .foregroundStyle(Theme.accent)
            .accessibilityHidden(true)
    }
}
