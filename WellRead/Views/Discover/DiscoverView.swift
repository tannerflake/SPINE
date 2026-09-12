//
//  DiscoverView.swift
//  WellRead
//
//  Full-screen Hinge-style discovery: one book at a time with three actions.
//  Suggestions are prefetched when the tab bar appears so the first suggestion is ready when user taps Discover.
//

import SwiftUI

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
                        onEdit: { showCriteriaEditor = true },
                        bookForSeed: { seed in
                            appState.userBooks.first(where: { $0.bookId == seed.bookId })?.book
                        }
                    )
                    // Keep the tune-callout bubble (which hangs below the strip) above the content underneath.
                    .zIndex(1)

                    Group {
                        if appState.isLoadingDiscoverSuggestions && appState.discoverCurrentSuggestion == nil {
                            loadingView
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
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .navigationDestination(item: $selectedBookForProfile) { book in
                BookProfileView(
                    book: book,
                    readBooksForSimilar: appState.readBooks,
                    onNotInterested: { selectedBookForProfile = nil },
                    onWantToRead: { appState.addToWantToRead(book: book); selectedBookForProfile = nil },
                    onStartReading: { appState.addToQueue(book: book, shelf: .readingNow); selectedBookForProfile = nil },
                    onConfirmRead: { date, rating, post, caption, tier in appState.addAsRead(book: book, dateFinished: date, rating: rating, postToFeed: post, caption: caption, tier: tier); selectedBookForProfile = nil },
                    isOnReadList: appState.isBookOnReadList(bookId: book.id),
                    isInQueue: appState.isBookInQueue(bookId: book.id),
                    onRemoveFromQueue: { appState.removeFromQueue(book: book); selectedBookForProfile = nil },
                    onMarkAsDNF: { appState.markAsDNF(book: book); selectedBookForProfile = nil },
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
            }
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
            VStack(spacing: 20) {
                SpinningSpineLogo()
                Text("Finding your next read…")
                    .font(Theme.title2())
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        let cameUpEmpty = appState.discoverLoadCameUpEmpty
        return VStack(spacing: 24) {
            Spacer(minLength: 0)
            SparklingSpineLogo()
            Text(cameUpEmpty ? "Nothing new that time" : "Find my next read")
                .font(Theme.title())
                .foregroundStyle(Theme.textPrimary)
            Text(cameUpEmpty
                 ? "Every pick came back as a book you've already read, queued, or passed on. Try again, or steer with different tiers, tags, or books."
                 : "Every pick is tailored to the books in your library and your interests — steer it with tiers, tags, or books you loved.")
                .font(Theme.body())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                appState.loadDiscoverSuggestionsIfNeeded()
            } label: {
                Text(cameUpEmpty ? "Try Again" : "Start")
                    .font(Theme.headline())
                    .foregroundStyle(Theme.onChrome)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .glossyProminent()
            }
            .buttonStyle(.springPress)
            .padding(.horizontal, 40)
            .padding(.top, 8)
            .disabled(appState.isLoadingDiscoverSuggestions)
            Spacer(minLength: 0)
        }
    }

    private func suggestionCardFullScreen(book: Book) -> some View {
        BookProfileView(
            book: book,
            readBooksForSimilar: appState.readBooks,
            onNotInterested: { performNotInterested(book) },
            onWantToRead: { performWantToRead(book) },
            onStartReading: { performStartReading(book) },
            onConfirmRead: { date, rating, post, caption, tier in performHaveRead(book, dateFinished: date, rating: rating, postToFeed: post, caption: caption, tier: tier) },
            onBookTap: { tappedBook in
                bookWeCameFrom = appState.discoverCurrentSuggestion
                selectedBookForProfile = tappedBook
            },
            isOnReadList: appState.isBookOnReadList(bookId: book.id),
            isInQueue: appState.isBookInQueue(bookId: book.id),
            onRemoveFromQueue: { appState.removeFromQueue(book: book) },
            onMarkAsDNF: { appState.markAsDNF(book: book) },
            readEntryForReview: appState.userReadBook(forBookId: book.id),
            canEditReadReview: true,
            showRecommend: false
        )
        .id(book.id)
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
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard selectedBookForProfile == nil, !showCriteriaEditor else { return }
            showCriteriaEditor = true
        }
    }

    private func performNotInterested(_ book: Book) {
        appState.addDismissedBookId(book.id)
        appState.discoverPassedBooks.append(book)
        actionedBookCount += 1
        appState.advanceDiscoverSuggestion()
    }

    /// Undo the last Pass, putting that book back on screen.
    private func undoLastPass() {
        Analytics.amplitude?.track(eventType: "Undid Discover Pass")
        actionedBookCount = max(0, actionedBookCount - 1)
        withAnimation(.easeOut(duration: 0.2)) {
            appState.undoLastDiscoverPass()
        }
    }

    private func performWantToRead(_ book: Book) {
        appState.addToWantToRead(book: book)
        actionedBookCount += 1
        appState.advanceDiscoverSuggestion()
    }

    private func performStartReading(_ book: Book) {
        appState.addToQueue(book: book, shelf: .readingNow)
        actionedBookCount += 1
        appState.advanceDiscoverSuggestion()
    }

    private func performHaveRead(_ book: Book, dateFinished: Date, rating: Double?, postToFeed: Bool, caption: String?, tier: String?) {
        appState.addAsRead(book: book, dateFinished: dateFinished, rating: rating, postToFeed: postToFeed, caption: caption, tier: tier)
        actionedBookCount += 1
        appState.advanceDiscoverSuggestion()
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

/// SPINE brand mark for the Discover empty state: the transparent logo tinted
/// with the accent color, with a cluster of gently twinkling sparkles in the
/// same tint superimposed above the reader's head.
private struct SparklingSpineLogo: View {
    @State private var twinkle = false

    var body: some View {
        ZStack {
            Image("SpineLogo")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 120, height: 120)
            sparkle(size: 22, offset: CGSize(width: 34, height: -36), delay: 0)
            sparkle(size: 13, offset: CGSize(width: 50, height: -16), delay: 0.5)
            sparkle(size: 10, offset: CGSize(width: 18, height: -50), delay: 1.0)
        }
        .foregroundStyle(Theme.accent)
        .onAppear { twinkle = true }
        .accessibilityHidden(true)
    }

    private func sparkle(size: CGFloat, offset: CGSize, delay: Double) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .medium))
            .scaleEffect(twinkle ? 1.0 : 0.55)
            .opacity(twinkle ? 1.0 : 0.35)
            .offset(offset)
            .animation(
                .easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(delay),
                value: twinkle
            )
    }
}
