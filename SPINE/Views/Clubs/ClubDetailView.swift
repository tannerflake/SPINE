//
//  ClubDetailView.swift
//  SPINE
//
//  One club: the book everyone is reading, the meeting it's due for, where each
//  member is, and the shelf of past reads. Admins pick books and set the date
//  from here; anyone can invite.
//

import SwiftUI
import FirebaseFirestore

@MainActor
final class ClubDetailStore: ObservableObject {
    @Published var club: BookClub?
    @Published var memberStates: [String: ClubMemberProgress.State] = [:]
    @Published var vanished = false

    private let clubId: String
    private var clubListener: ListenerRegistration?
    private var progressListeners: [ListenerRegistration] = []
    private var progressKey: String?

    init(clubId: String, initial: BookClub?) {
        self.clubId = clubId
        self.club = initial
    }

    func start() {
        if ClubsPreview.isActive {
            club = .uiPreviewDemo
            memberStates = BookClub.uiPreviewDemoProgress
            return
        }
        guard clubListener == nil else { return }
        clubListener = BookClubService.shared.listenClub(clubId: clubId) { [weak self] club in
            guard let self else { return }
            if club == nil, self.club != nil { self.vanished = true }
            self.club = club
            self.reconcileProgressListeners()
        }
    }

    /// Progress listeners key off (bookId, member set); anything else on the
    /// club doc changing leaves them alone.
    private func reconcileProgressListeners() {
        guard let club, let pick = club.currentPick else {
            progressListeners.forEach { $0.remove() }
            progressListeners = []
            progressKey = nil
            memberStates = [:]
            return
        }
        let key = pick.bookId + "|" + club.memberIds.sorted().joined(separator: ",")
        guard key != progressKey else { return }
        progressKey = key
        progressListeners.forEach { $0.remove() }
        progressListeners = BookClubService.shared.listenMemberProgress(memberIds: club.memberIds, bookId: pick.bookId) { [weak self] rows in
            guard let self else { return }
            var states: [String: ClubMemberProgress.State] = [:]
            for uid in club.memberIds {
                states[uid] = ClubMemberProgress.state(for: rows[uid])
            }
            self.memberStates = states
        }
    }

    func rows(for club: BookClub) -> [ClubMemberProgress] {
        let rows = club.orderedMemberIds.compactMap { uid -> ClubMemberProgress? in
            guard let member = club.members[uid] else { return nil }
            return ClubMemberProgress(uid: uid, member: member, state: memberStates[uid] ?? .notStarted)
        }
        return club.currentPick == nil ? rows : ClubMemberProgress.sorted(rows)
    }

    deinit {
        clubListener?.remove()
        progressListeners.forEach { $0.remove() }
    }
}

struct ClubDetailView: View {
    let clubId: String
    var initial: BookClub? = nil
    var openInviteOnAppear = false
    /// Set when this page is the Clubs tab itself (their only club), so settings
    /// can offer the "start or join another" that the club list would have.
    var onStartClub: (() -> Void)? = nil
    var onJoinClub: (() -> Void)? = nil

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mainTabBarOverlapExtraHeight) private var tabBarOverlap

    @StateObject private var store: ClubDetailStore
    @State private var showInvite = false
    @State private var showPicker = false
    @State private var showMeetingEditor = false
    @State private var showSettings = false
    @State private var selectedMember: SelectedMember?
    @State private var selectedBook: Book?
    @State private var busy = false
    @State private var didOpenInvite = false

    private struct SelectedMember: Identifiable {
        let uid: String
        let user: User
        var id: String { uid }
    }

    init(
        clubId: String,
        initial: BookClub? = nil,
        openInviteOnAppear: Bool = false,
        onStartClub: (() -> Void)? = nil,
        onJoinClub: (() -> Void)? = nil
    ) {
        self.clubId = clubId
        self.initial = initial
        self.openInviteOnAppear = openInviteOnAppear
        self.onStartClub = onStartClub
        self.onJoinClub = onJoinClub
        _store = StateObject(wrappedValue: ClubDetailStore(clubId: clubId, initial: initial))
    }

    private var uid: String? { authService.firebaseUser?.uid ?? appState.viewerUid }
    private var club: BookClub? { store.club }
    private var isAdmin: Bool {
        guard let club, let uid else { return false }
        return club.isAdmin(uid)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let club {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        titleBlock(club)
                        currentBookSection(club)
                        membersSection(club)
                        if !club.pastPicks.isEmpty {
                            pastReadsSection(club)
                        }
                    }
                    .padding(.horizontal, Theme.horizontalPadding)
                    .padding(.top, 6)
                    .padding(.bottom, 24 + tabBarOverlap)
                }
            } else if store.vanished {
                VStack(spacing: 10) {
                    Text("This club is gone.")
                        .font(Theme.title2())
                        .foregroundStyle(Theme.textPrimary)
                    Text("It was deleted, or you were removed.")
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                ProgressView().tint(Theme.accent)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbar {
            if let club {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showInvite = true } label: {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .accessibilityLabel("Invite to \(club.name)")
                    Button { showSettings = true } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .accessibilityLabel("Club settings")
                }
            }
        }
        .onAppear {
            store.start()
            if openInviteOnAppear, !didOpenInvite {
                didOpenInvite = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showInvite = true }
            }
        }
        .onChange(of: store.vanished) { _, gone in
            if gone {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
            }
        }
        .sheet(isPresented: $showInvite) {
            if let club { ClubInviteSheet(club: club) }
        }
        .sheet(isPresented: $showPicker) {
            if let club {
                ClubBookPickerSheet(club: club) { book, meetingAt in
                    guard let uid else { return }
                    runBusy {
                        try await BookClubService.shared.setCurrentPick(club: club, actorUid: uid, book: book, meetingAt: meetingAt)
                        ToastCenter.shared.show(Toast(style: .info, status: "SET", message: "\(book.title) is up next"))
                    }
                }
            }
        }
        .sheet(isPresented: $showMeetingEditor) {
            if let club, let pick = club.currentPick {
                ClubMeetingSheet(current: pick.meetingAt) { newDate in
                    guard let uid else { return }
                    runBusy {
                        try await BookClubService.shared.setMeeting(club: club, actorUid: uid, meetingAt: newDate)
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            if let club {
                ClubSettingsView(
                    club: club,
                    onLeft: { dismiss() },
                    onStartClub: onStartClub.map { action in { handOff(to: action) } },
                    onJoinClub: onJoinClub.map { action in { handOff(to: action) } }
                )
            }
        }
        .sheet(item: $selectedMember) { selection in
            UserProfileCardSheet(userId: selection.uid, user: selection.user)
        }
        .navigationDestination(item: $selectedBook) { book in
            BookProfileView(
                book: book,
                readBooksForSimilar: appState.readBooks,
                onWantToRead: { appState.addToWantToRead(book: book); selectedBook = nil },
                onStartReading: { appState.addToQueue(book: book, shelf: .readingNow); selectedBook = nil },
                onConfirmRead: { date, rating, post, caption, tier in
                    appState.addAsRead(book: book, dateFinished: date, rating: rating, postToFeed: post, caption: caption, tier: tier)
                    selectedBook = nil
                },
                isOnReadList: appState.isBookOnReadList(bookId: book.id),
                isInQueue: appState.isBookInQueue(bookId: book.id),
                onRemoveFromQueue: { appState.removeFromQueue(book: book); selectedBook = nil },
                onMarkAsDNF: { appState.markAsDNF(book: book); selectedBook = nil },
                readEntryForReview: appState.userReadBook(forBookId: book.id),
                canEditReadReview: true
            )
        }
    }

    /// Settings dismisses itself first; the tab's sheet needs the beat after to
    /// present cleanly.
    private func handOff(to action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
    }

    private func runBusy(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await work() } catch {
                ToastCenter.shared.show(Toast(style: .error, status: "ERROR", message: error.localizedDescription))
            }
        }
    }

    // MARK: - Title

    private func titleBlock(_ club: BookClub) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(club.name)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ClubAvatarStack(members: club.orderedMemberIds.compactMap { club.members[$0] }, size: 22, maxShown: 5)
                Text("\(club.memberIds.count) \(club.memberIds.count == 1 ? "member" : "members")")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                if club.everyoneIsAdmin {
                    Text("· Everyone picks")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    // MARK: - Current book

    @ViewBuilder
    private func currentBookSection(_ club: BookClub) -> some View {
        if let pick = club.currentPick {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    Button { selectedBook = pick.asBook } label: {
                        BookCoverView(book: pick.asBook, size: 104)
                    }
                    .buttonStyle(.springPress)
                    .accessibilityLabel("Open \(pick.title)")

                    VStack(alignment: .leading, spacing: 6) {
                        Text(pick.title)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(pick.author)
                            .font(Theme.callout())
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                        meetingLine(pick)
                            .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }

                myStatusRow(club: club, pick: pick)

                if isAdmin {
                    HStack(spacing: 10) {
                        ClubSecondaryButton(title: "Change book", icon: "arrow.triangle.2.circlepath") { showPicker = true }
                        ClubSecondaryButton(title: pick.meetingAt == nil ? "Set meeting" : "Move meeting", icon: "calendar") { showMeetingEditor = true }
                    }
                }
            }
            .hingeSectionCard(title: pick.meetingIsPast ? "Last meeting's book" : "Now reading")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Nothing picked yet.")
                    .font(Theme.title2())
                    .foregroundStyle(Theme.textPrimary)
                Text(isAdmin
                     ? "Choose the first book and set the meeting. Everyone gets a nudge to add it to their Reading now shelf."
                     : "Waiting on \(waitingOnCopy(club)) to pick. You'll get a push the moment it's set.")
                    .font(Theme.callout())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isAdmin {
                    ClubPrimaryButton(title: club.pastPicks.isEmpty ? "Pick the first book" : "Pick the next book", icon: "book.fill", isLoading: busy) {
                        showPicker = true
                    }
                }
            }
            .hingeSectionCard(title: "Next book")
        }
    }

    private func waitingOnCopy(_ club: BookClub) -> String {
        let names = club.adminNames.filter { !$0.isEmpty }
        switch names.count {
        case 0: return "an admin"
        case 1: return names[0]
        case 2: return "\(names[0]) or \(names[1])"
        default: return "\(names[0]) and the other admins"
        }
    }

    @ViewBuilder
    private func meetingLine(_ pick: BookClub.Pick) -> some View {
        if let meeting = pick.meetingAt {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .semibold))
                    Text(ClubDates.meetingLine(meeting))
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Theme.textPrimary)
                Text(pick.meetingIsPast ? "Met \(ClubDates.countdown(to: meeting).lowercased())" : ClubDates.countdown(to: meeting))
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.onChrome)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.chrome))
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 12, weight: .semibold))
                Text("No meeting date yet")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private func myStatusRow(club: BookClub, pick: BookClub.Pick) -> some View {
        let mine = uid.flatMap { store.memberStates[$0] } ?? .notStarted
        let inLibrary = appState.isBookInQueue(bookId: pick.bookId) || appState.isBookOnReadList(bookId: pick.bookId)
        switch mine {
        case .finished:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("You finished it. Ready for the meeting.")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.chrome.opacity(0.07)))
        case .reading(let fraction):
            Button { selectedBook = pick.asBook } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("You're \(Int((min(1, max(0, fraction)) * 100).rounded()))% through")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("Update")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    ClubProgressBar(fraction: fraction, height: 8)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.chrome.opacity(0.07)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.springPress)
        case .didNotFinish:
            Text("You set this one aside.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        case .notStarted:
            if inLibrary {
                Button { selectedBook = pick.asBook } label: {
                    HStack {
                        Text("On your shelf. Start it to track progress here.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.springPress)
            } else {
                ClubPrimaryButton(title: "Add to my Reading now", icon: "bookmark.fill") {
                    appState.addToQueue(book: pick.asBook, shelf: .readingNow)
                    ToastCenter.shared.show(Toast(style: .info, status: "ADDED", message: "\(pick.title) is on your Reading now shelf"))
                    Analytics.amplitude?.track(eventType: "Added Club Book To Queue", eventProperties: ["club_id": club.id, "book_id": pick.bookId])
                }
            }
        }
    }

    // MARK: - Members

    private func membersSection(_ club: BookClub) -> some View {
        let rows = store.rows(for: club)
        let finished = rows.filter(\.isFinished).count
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                ClubMemberRow(
                    progress: row,
                    isAdmin: !club.everyoneIsAdmin && club.adminIds.contains(row.uid),
                    isMe: row.uid == uid,
                    hasBook: club.currentPick != nil
                ) {
                    selectedMember = SelectedMember(uid: row.uid, user: row.member.asUser)
                }
                .padding(.vertical, 8)
                if index < rows.count - 1 {
                    Rectangle()
                        .fill(Theme.chrome.opacity(0.08))
                        .frame(height: 1)
                }
            }
            if club.memberIds.count < 3 {
                ClubSecondaryButton(title: "Invite more readers", icon: "person.badge.plus") { showInvite = true }
                    .padding(.top, 10)
            }
        }
        .hingeSectionCard(
            title: "Members",
            titleAccessory: {
                if club.currentPick != nil {
                    Text("\(finished) of \(rows.count) finished")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        )
    }

    // MARK: - Past reads

    private func pastReadsSection(_ club: BookClub) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(club.pastPicks) { pick in
                    Button { selectedBook = pick.asBook } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            BookCoverView(book: pick.asBook, size: 72)
                            Text(pick.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if let met = pick.meetingAt {
                                Text(ClubDates.monthYear(met))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .frame(width: 72, alignment: .leading)
                    }
                    .buttonStyle(.springPress)
                }
            }
            .padding(.horizontal, 2)
        }
        .hingeSectionCard(title: "Past reads · \(club.pastPicks.count)")
    }
}

// MARK: - Meeting date sheet

struct ClubMeetingSheet: View {
    let current: Date?
    let onSave: (Date?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var hasDate: Bool

    init(current: Date?, onSave: @escaping (Date?) -> Void) {
        self.current = current
        self.onSave = onSave
        _date = State(initialValue: current ?? Self.defaultMeeting())
        _hasDate = State(initialValue: true)
    }

    /// Four weeks out, 7 PM: a plausible first guess a host will nudge.
    static func defaultMeeting(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: 28, to: now) ?? now
        return cal.date(bySettingHour: 19, minute: 0, second: 0, of: base) ?? base
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 20) {
                    Text("When does the club meet next?")
                        .font(Theme.title())
                        .foregroundStyle(Theme.textPrimary)
                    Text("Everyone reads toward this date. The club gets a reminder the day before.")
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textSecondary)
                    DatePicker("Meeting", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .tint(Theme.accent)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: Theme.cardCornerRadius).fill(Theme.surfaceElevated))
                    Spacer(minLength: 0)
                    ClubPrimaryButton(title: "Save meeting date", icon: "calendar") {
                        onSave(date)
                        dismiss()
                    }
                    if current != nil {
                        Button {
                            onSave(nil)
                            dismiss()
                        } label: {
                            Text("Clear the date")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.danger)
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                        }
                        .buttonStyle(.springPress)
                    }
                }
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .presentationDetents([.large])
    }
}
