//
//  LibraryView.swift
//  SPINE
//
//  Library-only tab (labeled "Profile" in tab bar): "Your Library". Toolbar menu in top-right.
//

import SwiftUI

// MARK: - Library (Profile tab content)

struct ProfileLibraryView: View {
    @Environment(\.mainTabBarOverlapExtraHeight) private var mainTabBarOverlapExtraHeight
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var queueDragCoordinator: QueueBookDragCoordinator
    @State private var segment: LibraryReadQueueTab = .read
    @State private var selectedYear: Int? = nil
    /// Tier list multi-select is active: hides the floating + button under its action bar.
    @State private var isTierSelecting = false
    @State private var selectedBookForProfile: Book? = nil
    @State private var showGoodreadsImport = false
    @State private var goodreadsImportInitialRows: [GoodreadsRow]? = nil
    @State private var showGoodreadsImportErrorAlert = false
    /// Resume a paused link → queue session from the queue callout.
    @State private var showLinkImportResume = false
    /// Dropped a queue book onto the Read tab — show mark-as-read flow before updating Firestore.
    @State private var pendingMarkReadFromQueue: UserBook?
    /// Shelf whose "Add" tile was tapped — presents the search sheet scoped to that shelf.
    @State private var addToShelfTarget: ShelfAddTarget? = nil
    /// Floating + button in the bottom-right corner — opens the full search page.
    @State private var showAddBookSearch = false
    @State private var readTabDropTargeted = false
    /// Finger is over the floating trash while dragging a book off a shelf.
    @State private var deleteDropTargeted = false
    @State private var showEditProfile = false
    /// Set when the edit-profile sheet was opened by tapping the goal strip —
    /// the sheet scrolls to the book-goal field and focuses it.
    @State private var editProfileFocusesBookGoal = false
    /// Tapping your avatar opens your own profile card page: card, rosters,
    /// and the settings gear (which took over the old avatar menu's actions).
    @State private var showMyCard = false
    /// Bell beside the avatar: pushes the notifications feed.
    @State private var showNotifications = false
    /// List button in the header row: pushes the by-year list with multi-select year moves.
    @State private var showYearList = false
    /// Feed button beside the list button: pushes your own post history.
    @State private var showUserFeed = false
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.defaultValue.rawValue
    #if DEBUG
    #endif

    /// The App Store rating prompt (owned by MainTabView) may only land on a
    /// plain, unobstructed view of the viewer's own tier list with something
    /// actually ranked in it. Every local sheet, cover and push is listed here so
    /// the prompt never stacks on top of one the user opened themselves.
    private var isShowingOwnRankedTierList: Bool {
        segment == .read
            && appState.readBooks.contains { $0.tier != nil }
            && selectedBookForProfile == nil
            && addToShelfTarget == nil
            && pendingMarkReadFromQueue == nil
            && !isTierSelecting
            && !showYearList && !showUserFeed && !showMyCard
            && !showEditProfile && !showNotifications && !showLinkImportResume
            && !showGoodreadsImport && !showAddBookSearch
    }

    private var readBooksFilteredByYear: [UserBook] {
        let read = appState.readBooks
        guard let year = selectedYear else { return read }
        return read.filter { $0.wasRead(inYear: year) }
    }

    private var availableYears: [Int] {
        let years = Set(appState.readBooks.flatMap { ub in
            ub.allReadDates.map { Calendar.current.component(.year, from: $0) }
        })
        return years.sorted(by: >)
    }

    private var calendarYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    /// Books with any read date in the current calendar year (re-reads count toward each year's goal).
    private var booksFinishedThisCalendarYear: Int {
        appState.readBooks.filter { $0.wasRead(inYear: calendarYear) }.count
    }

    private var activeReadingGoal: Int? {
        let g = appState.currentUser?.readingGoal ?? authService.appUser?.readingGoal
        guard let g, g > 0 else { return nil }
        return g
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    spineProfileHeader

                    if activeReadingGoal != nil || !appState.readBooks.isEmpty {
                        HStack(alignment: .center, spacing: 8) {
                            if let goal = activeReadingGoal {
                                Button {
                                    editProfileFocusesBookGoal = true
                                    showEditProfile = true
                                } label: {
                                    LibraryReadingGoalProgressStrip(
                                        calendarYear: calendarYear,
                                        booksRead: booksFinishedThisCalendarYear,
                                        goal: goal,
                                        copy: .own
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Edit your yearly book goal.")
                            } else {
                                Spacer(minLength: 0)
                            }

                            if !appState.readBooks.isEmpty {
                                yearListButton
                            }
                            userFeedButton
                        }
                        .padding(.horizontal, Theme.horizontalPadding)
                        .padding(.vertical, 2)
                    }

                    resumeCallouts

                    libraryContent
                }
                .padding(.horizontal, 4)
            }
            .overlay(alignment: .bottomTrailing) {
                // The corner holds one affordance at a time: the trash takes over
                // from + while a book off this shelf is in the air, and both stay
                // out of the way of the tier list's selection bar.
                if showDeleteAffordance {
                    floatingDeleteButton
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                } else if !isTierSelecting {
                    floatingAddBookButton
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(LibrarySegmentControlAnimation.dragChrome, value: showDeleteAffordance)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .onAppear {
                appState.refreshGoodreadsWizardResumeState()
                appState.refreshLinkImportResumeState()
            }
            .sheet(isPresented: $showLinkImportResume, onDismiss: {
                appState.refreshLinkImportResumeState()
            }) {
                LinkImportView(payload: nil)
                    .environmentObject(appState)
                    .environmentObject(authService)
            }
            .navigationDestination(isPresented: $showNotifications) {
                NotificationsView()
                    .environmentObject(authService)
                    .environmentObject(appState)
            }
            .navigationDestination(isPresented: $showYearList) {
                ReadingYearListView(readBooks: appState.readBooks)
                    .environmentObject(authService)
                    .environmentObject(appState)
            }
            .navigationDestination(isPresented: $showUserFeed) {
                if let uid = authService.firebaseUser?.uid {
                    UserFeedView(userId: uid, onBookTap: { selectedBookForProfile = $0 })
                        .environmentObject(appState)
                        .environmentObject(authService)
                }
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
                    canEditReadReview: true
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .spineProfileTabTappedAgain)) { _ in
                // Re-tap on the Profile tab item: pop any pushed page (notifications,
                // year list, user feed, book profile) back to the library root.
                showNotifications = false
                showYearList = false
                showUserFeed = false
                selectedBookForProfile = nil
            }
            .sheet(isPresented: $showEditProfile, onDismiss: {
                editProfileFocusesBookGoal = false
            }) {
                ProfileCompletionView(
                    mode: .edit,
                    title: "Edit profile",
                    subtitle: "Update your name, handle, yearly reading goal, and reading tastes.",
                    focusBookGoalOnAppear: editProfileFocusesBookGoal,
                    onDismiss: {
                        showEditProfile = false
                    }
                )
                .environmentObject(authService)
                .environmentObject(appState)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showMyCard) {
                if let me = authService.firebaseUser?.uid, let user = appState.currentUser {
                    UserProfileCardSheet(userId: me, user: user)
                        .environmentObject(authService)
                        .environmentObject(appState)
                }
            }
            // Publishes "the user is looking at their own ranked tier list right
            // now" for the rating prompt. `initial: true` covers the common case:
            // a returning user whose library loaded before this view mounted.
            .onChange(of: isShowingOwnRankedTierList, initial: true) { _, showing in
                appState.isViewingOwnRankedTierList = showing
            }
            .onDisappear {
                appState.isViewingOwnRankedTierList = false
            }
            // Same full page as the Search tab, presented over the library and scoped
            // to the shelf whose "Add" tile was tapped (hence the Cancel button).
            .fullScreenCover(item: $addToShelfTarget) { target in
                SearchView(targetShelf: target.shelf, onClose: { addToShelfTarget = nil })
                    .environmentObject(authService)
                    .environmentObject(appState)
                    // No tab bar over a full-screen cover, so nothing to clear.
                    .environment(\.mainTabBarOverlapExtraHeight, 0)
            }
            // Same full search page, unscoped — opened by the floating + button.
            .fullScreenCover(isPresented: $showAddBookSearch) {
                SearchView(onClose: { showAddBookSearch = false })
                    .environmentObject(authService)
                    .environmentObject(appState)
                    .environment(\.mainTabBarOverlapExtraHeight, 0)
            }
            .sheet(isPresented: $showGoodreadsImport, onDismiss: {
                appState.refreshGoodreadsWizardResumeState()
            }) {
                GoodreadsImportView(initialRows: goodreadsImportInitialRows)
                    .environmentObject(appState)
                    .onDisappear { goodreadsImportInitialRows = nil }
            }
            .overlay {
                if appState.isFetchingGoodreadsFromURL {
                    Theme.background.ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(Theme.accent)
                            .scaleEffect(1.2)
                        Text("Loading Goodreads import…")
                            .font(Theme.callout())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onAppear {
                if let rows = appState.pendingGoodreadsImportRows, !rows.isEmpty {
                    goodreadsImportInitialRows = rows
                    showGoodreadsImport = true
                    appState.pendingGoodreadsImportRows = nil
                }
                if appState.pendingGoodreadsImportError != nil {
                    showGoodreadsImportErrorAlert = true
                }
            }
            .onChange(of: appState.pendingGoodreadsImportRows) { _, rows in
                if let r = rows, !r.isEmpty {
                    goodreadsImportInitialRows = r
                    showGoodreadsImport = true
                    appState.pendingGoodreadsImportRows = nil
                }
            }
            .onChange(of: appState.pendingGoodreadsImportError) { _, message in
                showGoodreadsImportErrorAlert = (message != nil)
            }
            .alert("Import from Goodreads", isPresented: $showGoodreadsImportErrorAlert) {
                Button("OK") {
                    appState.pendingGoodreadsImportError = nil
                }
            } message: {
                if let msg = appState.pendingGoodreadsImportError {
                    Text(msg)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .spineHighlightTierBook)) { _ in
                segment = .read
            }
            .onReceive(NotificationCenter.default.publisher(for: .spineOpenQueue)) { _ in
                segment = .wantToRead
            }
            .sheet(item: $pendingMarkReadFromQueue) { userBook in
                MarkAsReadDrawer(bookId: userBook.bookId, book: userBook.book) { date, rating, postToFeed, caption, tier in
                    guard let latest = appState.userBooks.first(where: { $0.id == userBook.id && $0.status == .wantToRead }) else {
                        pendingMarkReadFromQueue = nil
                        return
                    }
                    appState.promoteQueueEntryToRead(
                        userBook: latest,
                        dateFinished: date,
                        rating: rating,
                        postToFeed: postToFeed,
                        caption: caption,
                        tier: tier
                    )
                    pendingMarkReadFromQueue = nil
                }
            }
        }
    }

    /// The floating + turns into a trash while a book from the shelf on screen is
    /// being dragged: drop it there to take the book off that shelf.
    private var showDeleteAffordance: Bool {
        switch segment {
        case .read: return queueDragCoordinator.isDraggingReadBook
        case .wantToRead: return queueDragCoordinator.isDraggingQueueBook
        }
    }

    /// Red trash target in the bottom-right corner, shown only during a drag.
    /// Read shelf: removes the book, its read dates, its review and its feed
    /// posts. Queue: drops it from the queue.
    private var floatingDeleteButton: some View {
        Circle()
            .fill(Theme.danger.opacity(deleteDropTargeted ? 1.0 : 0.85))
            .frame(width: 56, height: 56)
            .overlay(
                Image(systemName: "trash.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color.white)
            )
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(deleteDropTargeted ? 0.9 : 0), lineWidth: 2)
            )
            .shadow(color: Theme.danger.opacity(deleteDropTargeted ? 0.55 : 0.35),
                    radius: deleteDropTargeted ? 12 : 8, y: 3)
            .scaleEffect(deleteDropTargeted ? 1.12 : 1)
            .animation(LibrarySegmentControlAnimation.dragChrome, value: deleteDropTargeted)
            .padding(.trailing, 20)
            .padding(.bottom, mainTabBarOverlapExtraHeight + 12)
            .dropDestination(for: TierDragItem.self) { items, _ in
                guard let payload = items.first else { return false }
                return handleDeleteDrop(payload: payload)
            } isTargeted: { isTargeted in
                deleteDropTargeted = isTargeted
                if isTargeted { LibraryDragHaptics.dropTargetHoverEntered() }
            }
            .accessibilityLabel(segment == .read ? "Remove from your read shelf" : "Remove from your queue")
    }

    /// Fixed floating + in the bottom-right corner of the Profile page — pulls up
    /// the same full search page as the Search tab (with a Cancel button).
    private var floatingAddBookButton: some View {
        Button {
            showAddBookSearch = true
        } label: {
            Circle()
                .fill(Theme.accent)
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.onChrome.opacity(0.5))
                )
                .shadow(color: Theme.shadowInk.opacity(0.25), radius: 8, y: 3)
                .opacity(0.5)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 20)
        // Clear the floating tab bar pill, same as BookProfileView's action bar.
        .padding(.bottom, mainTabBarOverlapExtraHeight + 12)
        .accessibilityLabel("Add a book")
    }

    /// True while a library drag is active — sliding selection pill is hidden; selected tab uses a static gray fill when that tab has no green/red chrome.
    private var isDraggingBooksForChrome: Bool {
        queueDragCoordinator.isDraggingQueueBook || queueDragCoordinator.isDraggingReadBook
    }

    /// Profile header — no wordmark: the Read/Queue control lives on the left,
    /// with the floating reading-now fan tucked right up against the avatar menu.
    private var spineProfileHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            librarySegmentControl
                .frame(maxWidth: .infinity)
            Spacer(minLength: 8)
            // What you're reading right now, floating beside your avatar. Tapping a
            // cover jumps to the Queue shelf it lives on, not the book's profile.
            HStack(alignment: .center, spacing: 2) {
                ReadingNowFanStack(
                    books: appState.wantToReadReadingNow.compactMap(\.book),
                    coverWidth: 30,
                    onTap: { _ in
                        withAnimation(LibrarySegmentControlAnimation.selection) {
                            segment = .wantToRead
                        }
                    },
                    floats: true
                )
                notificationsBell
                    .padding(.trailing, 4)
                toolbarProfilePhoto
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Custom Read / Queue control. Its one drop role is **Read** = mark read from
    /// queue (green +); removals happen on the floating trash in the bottom-right
    /// corner. Chrome follows UIKit drag sessions.
    private var librarySegmentControl: some View {
        HStack(spacing: 0) {
            readSegmentButton
            queueSegmentButton
        }
        // Tap a segment or press and slide the lens across. Hidden while a book
        // drag is in flight so the drop chrome on each segment reads cleanly.
        .slidingLens(
            itemCount: LibraryReadQueueTab.allCases.count,
            selectedIndex: $segment.lensIndex,
            lensInsets: LibrarySegmentLensLayout.lensInsets,
            isVisible: !isDraggingBooksForChrome,
            onTap: { segment = LibraryReadQueueTab(lensIndex: $0) }
        ) {
            LibrarySegmentGlassLens()
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .animation(LibrarySegmentControlAnimation.selection, value: segment)
        .sensoryFeedback(.selection, trigger: segment)
        .onChange(of: readTabDropTargeted) { _, isTargeted in
            if isTargeted { LibraryDragHaptics.dropTargetHoverEntered() }
        }
    }

    private var readSegmentButton: some View {
        let isSelected = segment == .read
        // Only one drop role left on this tab: green "mark read" while on Queue
        // and dragging a queue book. Removal moved to the floating trash.
        let showReadMarkReadChrome = segment == .wantToRead && queueDragCoordinator.isDraggingQueueBook
        /// Sliding pill covers gray when not dragging; during drag, keep gray on selected Read only when this tab has no drop chrome.
        let readStaticSelectedWhileDragging = isDraggingBooksForChrome && isSelected && !showReadMarkReadChrome
        let emphasizeReadHover = readTabDropTargeted
        let readLabelColor: Color = {
            if showReadMarkReadChrome { return .white }
            if isSelected { return Theme.textPrimary }
            return Theme.textSecondary
        }()
        let readFill: Color = {
            if showReadMarkReadChrome { return Theme.accent.opacity(emphasizeReadHover ? 0.58 : 0.5) }
            if readStaticSelectedWhileDragging { return Theme.surfaceElevated }
            return .clear
        }()
        let readStrokeColor: Color = {
            if showReadMarkReadChrome { return Theme.accent.opacity(emphasizeReadHover ? 1.0 : 0.95) }
            if readStaticSelectedWhileDragging { return Theme.chrome.opacity(0.55) }
            return .clear
        }()
        let readStrokeWidth: CGFloat = {
            if showReadMarkReadChrome { return emphasizeReadHover ? 3 : 2.5 }
            if readStaticSelectedWhileDragging { return 1.25 }
            return 0
        }()
        let readShadowColor: Color = {
            if showReadMarkReadChrome { return Theme.accent.opacity(emphasizeReadHover ? 0.55 : 0.45) }
            if readStaticSelectedWhileDragging { return Theme.shadowInk.opacity(0.12) }
            return .clear
        }()
        let readShadowRadius: CGFloat = {
            if showReadMarkReadChrome { return emphasizeReadHover ? 10 : 8 }
            if readStaticSelectedWhileDragging { return 4 }
            return 0
        }()
        // Not a `Button`: the row's single gesture handles taps and slides.
        return HStack(spacing: 6) {
            if showReadMarkReadChrome {
                Image(systemName: "plus.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.white)
            }
            Text("Read")
                .font(Theme.callout().weight(isSelected ? .semibold : .regular))
                .foregroundStyle(readLabelColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(readFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(readStrokeColor, lineWidth: readStrokeWidth)
        )
        .shadow(color: readShadowColor, radius: readShadowRadius, y: showReadMarkReadChrome ? 0 : 1)
        .animation(LibrarySegmentControlAnimation.dragChrome, value: readTabDropTargeted)
        .animation(LibrarySegmentControlAnimation.dragChrome, value: queueDragCoordinator.isDraggingQueueBook)
        .animation(LibrarySegmentControlAnimation.dragChrome, value: queueDragCoordinator.isDraggingReadBook)
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { segment = .read }
        .dropDestination(for: TierDragItem.self) { items, _ in
            guard let payload = items.first else { return false }
            return handleReadTabDrop(payload: payload)
        } isTargeted: { readTabDropTargeted = $0 }
    }

    private var queueSegmentButton: some View {
        let isSelected = segment == .wantToRead
        // No drop role: removing a queued book is the floating trash's job now.
        let queueStaticSelectedWhileDragging = isDraggingBooksForChrome && isSelected
        // Not a `Button`: the row's single gesture handles taps and slides.
        return HStack(spacing: 6) {
            Text("Queue")
                .font(Theme.callout().weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(queueStaticSelectedWhileDragging ? Theme.surfaceElevated : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(queueStaticSelectedWhileDragging ? Theme.chrome.opacity(0.55) : .clear,
                              lineWidth: queueStaticSelectedWhileDragging ? 1.25 : 0)
        )
        .shadow(color: queueStaticSelectedWhileDragging ? Theme.shadowInk.opacity(0.12) : .clear,
                radius: queueStaticSelectedWhileDragging ? 4 : 0, y: 1)
        .animation(LibrarySegmentControlAnimation.dragChrome, value: queueDragCoordinator.isDraggingQueueBook)
        .animation(LibrarySegmentControlAnimation.dragChrome, value: queueDragCoordinator.isDraggingReadBook)
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { segment = .wantToRead }
    }

    private func handleReadTabDrop(payload: TierDragItem) -> Bool {
        // Queue book dropped on Read: mark it read. A read book dropped here does
        // nothing — removal lives on the floating trash.
        guard segment == .wantToRead,
              let ub = appState.userBooks.first(where: { $0.id == payload.userBookId && $0.status == .wantToRead }),
              ub.book != nil else { return false }
        pendingMarkReadFromQueue = ub
        return true
    }

    /// Book dragged onto the floating trash: removes it from whichever shelf the
    /// current segment shows. Read removals take the reviews, the read dates and
    /// any feed posts with them (`removeFromReadList` → `deleteReadReview`).
    private func handleDeleteDrop(payload: TierDragItem) -> Bool {
        switch segment {
        case .read:
            guard let ub = appState.userBooks.first(where: { $0.id == payload.userBookId && $0.status == .read }),
                  let book = ub.book else { return false }
            appState.removeFromReadList(book: book)
            return true
        case .wantToRead:
            guard let ub = appState.userBooks.first(where: { $0.id == payload.userBookId && $0.status == .wantToRead }),
                  let book = ub.book else { return false }
            appState.removeFromQueue(book: book)
            return true
        }
    }

    /// Bell to the left of your avatar: opens the notifications feed. Shared
    /// with the Feed tab's bell (`NotificationsBellButton`) so both look and
    /// clear their badge identically.
    private var notificationsBell: some View {
        NotificationsBellButton { showNotifications = true }
    }

    /// Your avatar in the header: opens your own profile card page (card front
    /// and back, followers, following, and the settings gear). The old action
    /// menu that lived here moved to that page's settings screen.
    @ViewBuilder
    private var toolbarProfilePhoto: some View {
        if let user = appState.currentUser, authService.firebaseUser?.uid != nil {
            Button {
                showMyCard = true
            } label: {
                UserAvatarView(
                    urlString: user.profileImageURL,
                    displayName: user.displayName,
                    firstName: user.firstName,
                    lastName: user.lastName,
                    size: 40
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Your profile")
        } else {
            // User doc not loaded yet: the card page has nothing to show, so
            // keep the bare essentials reachable.
            Menu {
                appearanceMenu
                Divider()
                Button("Sign out", role: .destructive) {
                    authService.signOut()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// Light / Dark / System picker in the fallback menu — persisted app-wide
    /// via `AppearancePreference` and applied at the root `preferredColorScheme`.
    private var appearanceMenu: some View {
        Menu {
            Picker("Appearance", selection: $appearanceRaw) {
                ForEach(AppearancePreference.allCases) { option in
                    Label(option.label, systemImage: option.iconName)
                        .tag(option.rawValue)
                }
            }
        } label: {
            let current = AppearancePreference(rawValue: appearanceRaw) ?? .defaultValue
            Label("Appearance: \(current.label)", systemImage: current.iconName)
        }
    }

    /// Book count for the S-tier year dropdown rows; nil year = all read books.
    private func readBookCount(forYear year: Int?) -> Int {
        guard let year else { return appState.readBooks.count }
        return appState.readBooks.filter { $0.wasRead(inYear: year) }.count
    }

    /// List icon beside the reading goal strip: opens "Reading by year", where books can
    /// be multi-selected and moved into another year.
    private var yearListButton: some View {
        Button {
            showYearList = true
        } label: {
            goalStripIconLabel("list.bullet")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("List view")
    }

    /// Shared chrome for the square icon buttons beside the reading goal strip:
    /// identical footprint and identical glyph box, so `list.bullet` and
    /// `newspaper` can't render at different sizes.
    private func goalStripIconLabel(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 34, height: 34)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Feed icon beside the list button: opens your post history, every feed
    /// post you've made, newest first.
    private var userFeedButton: some View {
        Button {
            showUserFeed = true
        } label: {
            goalStripIconLabel("newspaper")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("My feed")
    }

    /// "Finish importing" callout above the tier list when a Goodreads wizard
    /// session is paused. Tapping resumes exactly where the user left off.
    private var goodreadsResumeCallout: some View {
        Button {
            goodreadsImportInitialRows = nil
            showGoodreadsImport = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.onChrome)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(SpinesGlyphs.caps("Finish importing!"))
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.accent)
                    Text(goodreadsResumeMessage)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(10)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.horizontalPadding - 4)
        .padding(.bottom, 8)
    }

    /// Drop-slot indices are positions in the (possibly year-filtered) rows the user sees.
    /// With a year filter active the full tier also contains hidden books, so translate
    /// "insert at visible slot N" into "insert before that same book in the full tier".
    private func fullTierInsertionIndex(tier: String?, visibleIndex: Int?) -> Int? {
        guard let visibleIndex, selectedYear != nil else { return visibleIndex }
        let t = tier.flatMap { $0.isEmpty ? nil : $0 }
        let visible = spineTierSorted(readBooksFilteredByYear.filter { $0.normalizedTier == t })
        // Dropped past the last visible book → append to the end of the full tier.
        guard visibleIndex < visible.count else { return nil }
        let insertBefore = visible[visibleIndex]
        let full = spineTierSorted(appState.readBooks.filter { $0.normalizedTier == t })
        return full.firstIndex(where: { $0.id == insertBefore.id })
    }

    /// Paused-import callouts, one per segment (kept out of `body` — a second
    /// conditional there tipped the type checker over its limit).
    @ViewBuilder
    private var resumeCallouts: some View {
        if segment == .read && appState.goodreadsWizardRemainingCount > 0 {
            goodreadsResumeCallout
        }
        if segment == .wantToRead && appState.linkImportRemainingCount > 0 {
            linkImportResumeCallout
        }
    }

    /// "Finish adding" callout above the queue when a link → queue session is
    /// paused. Tapping resumes exactly where the user left off.
    private var linkImportResumeCallout: some View {
        Button {
            showLinkImportResume = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.onChrome)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(SpinesGlyphs.caps("Finish adding books"))
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.accent)
                    Text(linkImportResumeMessage)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    // Leaves room for the dismiss button sitting in the corner.
                    .padding(.trailing, 14)
            }
            .padding(10)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        // Sibling of the resume button, not nested inside its label: a button
        // inside another button's label never gets its own taps.
        .overlay(alignment: .topTrailing) { linkImportDismissButton }
        .padding(.horizontal, Theme.horizontalPadding - 4)
        .padding(.bottom, 8)
    }

    /// X in the callout's corner: throws away the rest of the paused import,
    /// with a tap-to-undo toast in case it was a mis-tap.
    private var linkImportDismissButton: some View {
        Button {
            let session = appState.loadLinkImportSession()
            let remaining = appState.linkImportRemainingCount
            appState.clearLinkImportSession()
            ToastCenter.shared.show(.linkImportDismissed(count: remaining) {
                guard let session else { return }
                appState.saveLinkImportSession(session)
            })
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }

    private var linkImportResumeMessage: String {
        let n = appState.linkImportRemainingCount
        let noun = n == 1 ? "book" : "books"
        let source = appState.loadLinkImportSession()?.sourceLabel ?? ""
        return source.isEmpty ? "\(n) \(noun) left from a shared link" : "\(n) \(noun) left from \(source)"
    }

    private var goodreadsResumeMessage: String {
        let n = appState.goodreadsWizardRemainingCount
        let noun = n == 1 ? "book" : "books"
        return "\(n) \(noun) remaining"
    }

    @ViewBuilder
    private var libraryContent: some View {
        if segment == .read {
            TierListView(
                userBooks: readBooksFilteredByYear,
                onUpdateTierAndOrder: { id, tier, order in
                    appState.setTierAndOrder(for: id, tier: tier, order: fullTierInsertionIndex(tier: tier, visibleIndex: order))
                },
                onBookTap: { selectedBookForProfile = $0 },
                highlightedBookId: appState.pendingTierHighlightBookId,
                autoScrollsToHighlight: appState.tierHighlightScrollPending,
                onHighlightAutoScrolled: { appState.tierHighlightScrollPending = false },
                yearFilter: availableYears.isEmpty ? nil : TierYearFilter(
                    availableYears: availableYears,
                    selectedYear: selectedYear,
                    countForYear: { readBookCount(forYear: $0) },
                    onSelect: { selectedYear = $0 }
                ),
                multiSelect: TierMultiSelectActions(
                    moveToTier: { ids, tier in appState.moveReadBooksToTier(userBookIds: ids, tier: tier) },
                    remove: { ids in await appState.removeReadBooks(userBookIds: ids) },
                    setReadYear: { ids, year in appState.setReadYear(userBookIds: ids, year: year) },
                    userId: appState.authUserId
                ),
                onSelectionModeChanged: { selecting in
                    withAnimation(.easeInOut(duration: 0.2)) { isTierSelecting = selecting }
                }
            )
        } else {
            QueueLibraryView(
                readingNow: appState.wantToReadReadingNow,
                upNext: appState.wantToReadUpNext,
                backlog: appState.wantToReadBacklog,
                dnf: appState.dnfBooks,
                onUpdateShelfAndOrder: { id, shelf, idx in
                    appState.setQueueShelfAndOrder(for: id, shelf: shelf, insertionIndex: idx)
                },
                onBookTap: { selectedBookForProfile = $0 },
                onAddToShelf: { addToShelfTarget = ShelfAddTarget(shelf: $0) },
                recommendations: appState.incomingRecommendations,
                recommenderNames: appState.recommenderProfiles.mapValues(\.displayName),
                onAcceptRecommendation: { appState.acceptRecommendation($0) },
                onDismissRecommendation: { appState.dismissRecommendation($0) },
                onCommitProgress: { id, fraction in appState.setReadingProgress(userBookId: id, progress: fraction) },
                onMarkFinished: { ub in
                    guard ub.book != nil else { return }
                    pendingMarkReadFromQueue = ub
                }
            )
        }
    }
}

/// Identifiable wrapper so `.sheet(item:)` can present the add-book search for a specific shelf.
private struct ShelfAddTarget: Identifiable {
    let shelf: QueueShelf
    var id: String { shelf.rawValue }
}

