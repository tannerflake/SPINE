//
//  UserLibraryDetailView.swift
//  SPINE
//
//  Another member's library (read-only): same layout as Profile tab, opened from Feed.
//

import SwiftUI
import FirebaseFirestore

struct UserLibraryDetailView: View {
    let userId: String

    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appState: AppState

    private let userBookRepo = UserBookRepository()
    private let userRepo = UserRepository()

    @State private var profileUser: User?
    @State private var books: [UserBook] = []
    @State private var booksListener: ListenerRegistration?
    /// First books snapshot has arrived — until then the tier list would render
    /// misleadingly empty, so the view shows the brand spinner instead.
    @State private var hasLoadedBooks = false
    /// Profile fetch finished (even if it came back nil), so the spinner can't hang on a failed lookup.
    @State private var profileFetchCompleted = false
    @State private var segment: LibraryReadQueueTab = .read
    @State private var selectedYear: Int? = nil
    @State private var selectedBookForProfile: Book? = nil
    @State private var iFollowThem: Bool = false
    @State private var followActionInFlight = false
    @State private var showProfileCard = false
    /// Long-pressing their avatar blows the photo up over a dimmed screen.
    @State private var showAvatarZoom = false
    /// Feed button beside the year filter: pushes this person's post history.
    @State private var showUserFeed = false
    /// List button beside the feed button: pushes their read shelf grouped by year.
    @State private var showYearList = false

    // Book Blend: live pair-doc state drives the entry button; the landing
    // screen handles invite / waiting / story routing.
    @State private var blend: BookBlend?
    @State private var blendListener: ListenerRegistration?
    @State private var blendRequestInFlight = false
    @State private var showBlendLanding = false
    @State private var showUndoBlendConfirm = false

    private var readBooks: [UserBook] {
        books.filter { $0.status == .read }
    }

    /// This page also renders your own library (e.g. opened from a roster), where
    /// the list view stays editable.
    private var isViewingOwnLibrary: Bool {
        authService.firebaseUser?.uid == userId
    }

    private var wantToReadList: [UserBook] {
        books.filter { $0.status == .wantToRead }
    }

    private var wantToReadReadingNow: [UserBook] {
        wantToReadList
            .filter { $0.queueShelf == .readingNow }
            .sorted { ($0.queueOrder ?? 999) < ($1.queueOrder ?? 999) }
    }

    private var wantToReadUpNext: [UserBook] {
        wantToReadList
            .filter { $0.queueShelf == .upNext }
            .sorted { ($0.queueOrder ?? 999) < ($1.queueOrder ?? 999) }
    }

    private var wantToReadBacklog: [UserBook] {
        let backlog = wantToReadList.filter { $0.queueShelf == nil || $0.queueShelf == .backlog }
        return Self.sortedBacklog(backlog)
    }

    private var dnfBooks: [UserBook] {
        books.filter { $0.status == .didNotFinish }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func sortedBacklog(_ books: [UserBook]) -> [UserBook] {
        let explicit = books.filter { $0.queueOrder != nil }.sorted { $0.queueOrder! < $1.queueOrder! }
        let implicit = books.filter { $0.queueOrder == nil }.sorted { $0.updatedAt > $1.updatedAt }
        return explicit + implicit
    }

    private var readBooksFilteredByYear: [UserBook] {
        guard let year = selectedYear else { return readBooks }
        return readBooks.filter { $0.wasRead(inYear: year) }
    }

    private var availableYears: [Int] {
        let years = Set(readBooks.flatMap { ub in
            ub.allReadDates.map { Calendar.current.component(.year, from: $0) }
        })
        return years.sorted(by: >)
    }

    private var calendarYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    /// Books with any read date in the current calendar year (re-reads count toward each year's goal).
    private var booksFinishedThisCalendarYear: Int {
        readBooks.filter { $0.wasRead(inYear: calendarYear) }.count
    }

    private var activeReadingGoal: Int? {
        guard let g = profileUser?.readingGoal, g > 0 else { return nil }
        return g
    }

    /// Everything the header + tier list needs, loaded before anything renders —
    /// no flash of an empty library while Firestore catches up.
    private var isInitialLoading: Bool {
        !hasLoadedBooks || !profileFetchCompleted
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
                // On the background layer, not the ZStack: the blend landing
                // cover already owns the ZStack's presentation slot.
                .avatarZoom(
                    isPresented: $showAvatarZoom,
                    urlString: profileUser?.profileImageURL,
                    displayName: profileUser?.displayName,
                    firstName: profileUser?.firstName,
                    lastName: profileUser?.lastName,
                    caption: profileUser.map { fullName(for: $0) }
                )
            if isInitialLoading {
                loadingView
            } else {
                VStack(spacing: 0) {
                    // Follow and Book Blend ride together: both are actions on this
                    // person rather than their library. Blend leads as the filled
                    // hero CTA; Follow is the quiet outlined pill trailing it.
                    if let me = authService.firebaseUser?.uid, me != userId {
                        HStack(spacing: 8) {
                            BookBlendEntryButton(
                                state: blendEntryState(myUid: me),
                                otherFirstName: profileUser?.firstName ?? "They",
                                action: { handleBlendButtonTap(myUid: me) }
                            )
                            followToggleButton
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                    }

                    otherUserSegmentControl
                        .padding(.bottom, 10)

                    // Goal bar and feed button; the year filter lives on the S tier
                    // box as a folder tab, same as your own library.
                    if !availableYears.isEmpty || !readBooks.isEmpty || profileUser != nil {
                        HStack(alignment: .center, spacing: 12) {
                            // The strip stays put even when they never set a goal
                            // (empty track + this year's count). Plenty of members
                            // have no goal, and the row used to disappear entirely
                            // on their profiles.
                            LibraryReadingGoalProgressStrip(
                                calendarYear: calendarYear,
                                booksRead: booksFinishedThisCalendarYear,
                                goal: activeReadingGoal,
                                copy: .other(displayFirstName: profileUser?.firstName)
                            )

                            if !readBooks.isEmpty {
                                yearListButton
                            }
                            userFeedButton
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                    }

                    libraryContent
                }
                .padding(.horizontal, 4)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbar { libraryToolbar }
        .sheet(isPresented: $showProfileCard, onDismiss: {
            // Following someone from the roster can include this profile's owner.
            Task { await refreshIFollowState() }
        }) {
            if let u = profileUser {
                UserProfileCardSheet(userId: userId, user: u)
            }
        }
        .navigationDestination(item: $selectedBookForProfile) { book in
            BookProfileView(
                book: book,
                readBooksForSimilar: appState.readBooks,
                onNotInterested: nil,
                onWantToRead: { appState.addToWantToRead(book: book); selectedBookForProfile = nil },
                onStartReading: { appState.addToQueue(book: book, shelf: .readingNow); selectedBookForProfile = nil },
                onConfirmRead: { date, rating, post, caption, tier in
                    appState.addAsRead(book: book, dateFinished: date, rating: rating, postToFeed: post, caption: caption, tier: tier)
                    selectedBookForProfile = nil
                },
                isOnReadList: appState.isBookOnReadList(bookId: book.id),
                isInQueue: appState.isBookInQueue(bookId: book.id),
                onRemoveFromQueue: { appState.removeFromQueue(book: book); selectedBookForProfile = nil },
                onMarkAsDNF: { appState.markAsDNF(book: book); selectedBookForProfile = nil },
                // On someone else's library their review lives in "Read by"
                // (pinned + highlighted via sourceReaderUid) instead of a
                // duplicate top card; own library keeps the review card.
                readEntryForReview: authService.firebaseUser?.uid == userId
                    ? books.first(where: { $0.bookId == book.id && $0.status == .read })
                    : nil,
                reviewSectionHeading: "Review",
                sourceReaderUid: authService.firebaseUser?.uid == userId ? nil : userId
            )
        }
        .navigationDestination(isPresented: $showYearList) {
            ReadingYearListView(
                readBooks: readBooks,
                isEditable: isViewingOwnLibrary,
                sourceReaderUid: isViewingOwnLibrary ? nil : userId
            )
            .environmentObject(appState)
            .environmentObject(authService)
        }
        .navigationDestination(isPresented: $showUserFeed) {
            UserFeedView(
                userId: userId,
                displayFirstName: profileUser?.firstName,
                onBookTap: { selectedBookForProfile = $0 }
            )
            .environmentObject(appState)
            .environmentObject(authService)
        }
        .onAppear {
            Task {
                profileUser = await userRepo.getUser(uid: userId)
                profileFetchCompleted = true
                await refreshIFollowState()
            }
            booksListener = userBookRepo.listenUserBooks(userId: userId) { list in
                books = list
                hasLoadedBooks = true
            }
            startBlendListener()
        }
        .onChange(of: authService.firebaseUser?.uid) { _, _ in
            Task { await refreshIFollowState() }
            blendListener?.remove()
            blendListener = nil
            startBlendListener()
        }
        .onDisappear {
            booksListener?.remove()
            booksListener = nil
            blendListener?.remove()
            blendListener = nil
        }
        .fullScreenCover(isPresented: $showBlendLanding) {
            if let me = authService.firebaseUser?.uid {
                BookBlendLandingView(blendId: BookBlend.pairId(me, userId))
                    .environmentObject(authService)
                    .environmentObject(appState)
            }
        }
        .alert("Undo blend request?", isPresented: $showUndoBlendConfirm) {
            Button("Undo Request", role: .destructive) { undoBlendRequest() }
            Button("Keep Request", role: .cancel) {}
        } message: {
            Text("The invite to \(profileUser?.firstName ?? "them") will be withdrawn and their notification removed.")
        }
    }

    /// Brand spinner shown until the first books snapshot and the profile
    /// fetch both land — never an empty tier list that fills in later.
    private var loadingView: some View {
        VStack(spacing: 20) {
            SpinningSpineLogo(size: 120)
            Text("Loading library…")
                .font(Theme.title2())
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Book Blend

    private func startBlendListener() {
        guard let me = authService.firebaseUser?.uid, me != userId, blendListener == nil else { return }
        blendListener = BookBlendService.shared.listenBlend(pairId: BookBlend.pairId(me, userId)) { updated, _ in
            blend = updated
        }
    }

    private func blendEntryState(myUid: String) -> BookBlendEntryState {
        guard let blend else { return .none }
        switch blend.status {
        case .ready: return .ready
        case .declined: return .none
        case .pending: return blend.requesterId == myUid ? .requestedByMe : .invitedMe
        }
    }

    private func handleBlendButtonTap(myUid: String) {
        switch blendEntryState(myUid: myUid) {
        case .none:
            guard !blendRequestInFlight else { return }
            blendRequestInFlight = true
            Task {
                let me = appState.currentUser
                if let requested = try? await BookBlendService.shared.requestBlend(
                    myUid: myUid, me: me, otherUid: userId, other: profileUser
                ) {
                    await MainActor.run { blend = requested }
                }
                await MainActor.run { blendRequestInFlight = false }
            }
        case .requestedByMe:
            showUndoBlendConfirm = true
        case .invitedMe, .ready:
            showBlendLanding = true
        }
    }

    /// Deletes the pending pair doc; the blend listener flips the button back to
    /// "Request a Book Blend" when the delete lands. The Cloud Function clears
    /// the recipient's invite notification via a silent push.
    private func undoBlendRequest() {
        guard let me = authService.firebaseUser?.uid,
              let blend, blend.status == .pending, blend.requesterId == me,
              !blendRequestInFlight else { return }
        blendRequestInFlight = true
        Task {
            try? await BookBlendService.shared.cancelRequest(blend, myUid: me)
            await MainActor.run { blendRequestInFlight = false }
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        // Full name + handle take the title slot. Text-only: the avatar is too big
        // for the inline bar (stacked avatar+name clipped there before), so it
        // lives on the segment row instead.
        ToolbarItem(placement: .principal) {
            if let u = profileUser {
                VStack(spacing: 1) {
                    Text(fullName(for: u))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !u.username.isEmpty {
                        Text("@\(u.username)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        // Fan + avatar in the top-right corner, level with the name. Oversized for
        // the inline bar on purpose; verified it renders unclipped on iOS 26.
        // sharedBackgroundVisibility kills the liquid-glass capsule the bar would
        // otherwise draw behind the cluster.
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) {
                fanAndAvatarHeader
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                fanAndAvatarHeader
            }
        }
    }

    private var fanAndAvatarHeader: some View {
        HStack(alignment: .center, spacing: 6) {
            // Tapping a cover drops you on their Queue, where the reading-now
            // shelf lives, rather than the individual book's profile.
            ReadingNowFanStack(
                books: wantToReadReadingNow.compactMap(\.book),
                coverWidth: 28,
                onTap: { _ in
                    withAnimation(LibrarySegmentControlAnimation.selection) {
                        segment = .wantToRead
                    }
                },
                floats: true
            )
            otherUserAvatar
        }
        .padding(.trailing, 4)
    }

    /// Tapping the avatar opens their card. Follow lives in the actions row with
    /// Book Blend, so the avatar is free to be the way into the profile sheet.
    private var otherUserAvatar: some View {
        Group {
            if let u = profileUser {
                // Gestures rather than a Button: a Button's action still fires on
                // touch-up after a long press, which opened the card sheet behind
                // the zoom. onLongPressGesture consumes the press, so tap and
                // hold stay exclusive.
                avatarCircle(for: u)
                    .contentShape(Circle())
                    .onLongPressGesture(minimumDuration: 0.35) {
                        WizardHaptics.step()
                        AvatarZoomPresentation.present($showAvatarZoom)
                    }
                    .onTapGesture { showProfileCard = true }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("View \(avatarMenuName(for: u))'s card")
                    .accessibilityHint("Touch and hold to see their photo full screen")
            }
        }
    }

    private func avatarCircle(for u: User) -> some View {
        UserAvatarView(
            urlString: u.profileImageURL,
            displayName: u.displayName,
            firstName: u.firstName,
            lastName: u.lastName,
            size: 54
        )
    }

    private func avatarMenuName(for user: User) -> String {
        if let fn = user.firstName?.trimmingCharacters(in: .whitespacesAndNewlines), !fn.isEmpty {
            return fn
        }
        return user.displayName
    }

    /// "First Last" when both are set; falls back to whichever half exists, then displayName.
    private func fullName(for user: User) -> String {
        let parts = [user.firstName, user.lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? user.displayName : parts.joined(separator: " ")
    }

    @ViewBuilder
    private var followToggleButton: some View {
        if let me = authService.firebaseUser?.uid, me != userId {
            Button {
                Task { await toggleFollow() }
            } label: {
                // Outlined so the blend button leading it stays the row's only
                // filled CTA. Padding matches BookBlendEntryButton for equal height.
                Text(iFollowThem ? "Following" : "Follow")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iFollowThem ? Theme.textSecondary : Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Theme.surface))
                    .overlay(
                        Capsule()
                            .strokeBorder(Theme.textTertiary.opacity(iFollowThem ? 0.25 : 0.5), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(followActionInFlight)
        }
    }

    private func refreshIFollowState() async {
        guard let me = authService.firebaseUser?.uid, me != userId else {
            iFollowThem = false
            return
        }
        if let u = await userRepo.getUser(uid: me) {
            iFollowThem = u.following.contains(userId)
        }
    }

    private func toggleFollow() async {
        guard let me = authService.firebaseUser?.uid, me != userId else { return }
        followActionInFlight = true
        defer { followActionInFlight = false }
        let next = !iFollowThem
        do {
            try await userRepo.setFollowing(currentUid: me, targetUid: userId, follow: next)
            iFollowThem = next
            await authService.refreshAppUser()
            WidgetDataService.shared.scheduleRefresh(appState: appState, delay: 1.0, forceFriendRefresh: true)
        } catch {
            await refreshIFollowState()
        }
    }

    private var otherUserSegmentControl: some View {
        LibraryReadQueueSegmentControlReadOnly(segment: $segment)
    }

    /// Book count for the S-tier year tab rows; nil year = all their read books.
    private func readBookCount(forYear year: Int?) -> Int {
        guard let year else { return readBooks.count }
        return readBooks.filter { $0.wasRead(inYear: year) }.count
    }

    /// Feed icon beside the goal bar: opens this person's post history,
    /// every feed post they've made, newest first.
    /// Opens their read shelf as a by-year list. Read-only: no Select or year moves.
    private var yearListButton: some View {
        Button {
            showYearList = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profileUser?.firstName ?? "Their") books by year")
    }

    private var userFeedButton: some View {
        Button {
            showUserFeed = true
        } label: {
            Image(systemName: "newspaper")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profileUser?.firstName ?? "Their") feed")
    }

    @ViewBuilder
    private var libraryContent: some View {
        if segment == .read {
            TierListView(
                userBooks: readBooksFilteredByYear,
                onUpdateTierAndOrder: { _, _, _ in },
                onBookTap: { selectedBookForProfile = $0 },
                readOnly: true,
                yearFilter: availableYears.isEmpty ? nil : TierYearFilter(
                    availableYears: availableYears,
                    selectedYear: selectedYear,
                    countForYear: { readBookCount(forYear: $0) },
                    onSelect: { selectedYear = $0 }
                )
            )
        } else {
            QueueLibraryView(
                readingNow: wantToReadReadingNow,
                upNext: wantToReadUpNext,
                backlog: wantToReadBacklog,
                dnf: dnfBooks,
                onUpdateShelfAndOrder: { _, _, _ in },
                onBookTap: { selectedBookForProfile = $0 },
                readOnly: true
            )
        }
    }
}
