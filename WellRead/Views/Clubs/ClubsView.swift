//
//  ClubsView.swift
//  SPINE
//
//  Clubs tab root: the reader's clubs, or the pitch plus Start/Join when they
//  have none. Detail pages push onto this stack; deep links and pushes land
//  here via `.spineOpenClub` / `.spineJoinClubWithCode`.
//

import SwiftUI
import FirebaseFirestore

@MainActor
final class MyClubsStore: ObservableObject {
    @Published var clubs: [BookClub] = []
    @Published var loaded = false

    private var listener: ListenerRegistration?
    private var listeningUid: String?

    func start(uid: String?) {
        if ClubsPreview.isActive {
            clubs = ClubsPreview.startsEmpty ? [] : [.uiPreviewDemo]
            loaded = true
            return
        }
        guard let uid else { return }
        guard uid != listeningUid else { return }
        listener?.remove()
        listeningUid = uid
        listener = BookClubService.shared.listenMyClubs(uid: uid) { [weak self] clubs in
            self?.clubs = clubs
            self?.loaded = true
        }
    }

    deinit { listener?.remove() }
}

struct ClubsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService
    @StateObject private var store = MyClubsStore()

    @State private var path = NavigationPath()
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var joinPrefill: String?
    /// Set when a club was just created so its detail page opens the invite sheet.
    @State private var freshlyCreatedClubId: String?

    private var uid: String? { authService.firebaseUser?.uid ?? appState.viewerUid }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        content
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .navigationDestination(for: String.self) { clubId in
                ClubDetailView(
                    clubId: clubId,
                    initial: store.clubs.first { $0.id == clubId },
                    openInviteOnAppear: freshlyCreatedClubId == clubId
                )
                .onAppear {
                    if freshlyCreatedClubId == clubId {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { freshlyCreatedClubId = nil }
                    }
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateClubView { club in
                freshlyCreatedClubId = club.id
                path.append(club.id)
            }
        }
        .sheet(isPresented: $showJoin, onDismiss: { joinPrefill = nil }) {
            JoinClubSheet(prefilledCode: joinPrefill) { clubId in
                path.append(clubId)
            }
        }
        .onAppear {
            store.start(uid: uid)
            consumePendingDeepLinks()
        }
        .onChange(of: uid) { _, newValue in store.start(uid: newValue) }
        .onReceive(NotificationCenter.default.publisher(for: .spineClubsTabTappedAgain)) { _ in
            path = NavigationPath()
        }
        .onReceive(NotificationCenter.default.publisher(for: .spineOpenClub)) { note in
            guard let clubId = note.userInfo?["clubId"] as? String, !clubId.isEmpty else { return }
            open(clubId: clubId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .spineJoinClubWithCode)) { note in
            guard let code = note.userInfo?["code"] as? String else { return }
            joinPrefill = code
            showJoin = true
        }
    }

    private func open(clubId: String) {
        path = NavigationPath()
        path.append(clubId)
    }

    /// Cold-start stashes left by a push tap or invite link before the tab existed.
    private func consumePendingDeepLinks() {
        if let clubId = PushNotificationService.pendingClubId {
            PushNotificationService.pendingClubId = nil
            open(clubId: clubId)
        }
        if let code = PushNotificationService.pendingClubInviteCode {
            PushNotificationService.pendingClubInviteCode = nil
            joinPrefill = code
            showJoin = true
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CLUBS")
                .font(.system(size: 22, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.textPrimary)
            BrandRule(width: 48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if !store.clubs.isEmpty {
                Menu {
                    Button { showCreate = true } label: { Label("Start a club", systemImage: "plus") }
                    Button { showJoin = true } label: { Label("Join with a code", systemImage: "ticket") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.onChrome)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.chrome))
                }
                .accessibilityLabel("Start or join a club")
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.top, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !store.loaded && uid != nil {
            loadingState
        } else if store.clubs.isEmpty {
            emptyState
        } else {
            VStack(spacing: 14) {
                ForEach(store.clubs) { club in
                    Button { path.append(club.id) } label: {
                        ClubCard(club: club, myUid: uid)
                    }
                    .buttonStyle(.springPress)
                }
            }
            .padding(.horizontal, Theme.horizontalPadding)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 14) {
                    ShimmerBar().frame(width: 56, height: 84)
                    VStack(alignment: .leading, spacing: 8) {
                        ShimmerBar().frame(width: 160, height: 16)
                        ShimmerBar().frame(width: 110, height: 12)
                    }
                    Spacer()
                }
                .padding(Theme.cardPadding)
                .wellReadCard()
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your book club, minus the group chat chaos.")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Keep the chat where it is. SPINE handles the rest: who's in, what's next, when you meet, and how far everyone has gotten.")
                    .font(Theme.body())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                pitchRow(icon: "book.fill", title: "One book, one deadline", body: "Set the next meeting and everyone reads toward it.")
                pitchRow(icon: "chart.bar.fill", title: "See who's actually reading", body: "Live progress for every member, no \u{201C}where is everyone at?\u{201D} texts.")
                pitchRow(icon: "hand.raised.fill", title: "No awkward picks", body: "Anonymous suggestions and ranked voting are coming next.")
            }
            .padding(20)
            .wellReadCard()

            VStack(spacing: 10) {
                ClubPrimaryButton(title: "Start a club", icon: "plus") { showCreate = true }
                ClubSecondaryButton(title: "Join with a code", icon: "ticket") { showJoin = true }
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.top, 6)
    }

    private func pitchRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.onChrome)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.chrome))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(body)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One club on the Clubs tab: current cover, name, meeting countdown, members.
struct ClubCard: View {
    let club: BookClub
    let myUid: String?

    private var subtitle: String {
        let members = "\(club.memberIds.count) \(club.memberIds.count == 1 ? "member" : "members")"
        guard let pick = club.currentPick else { return "\(members) · No book picked yet" }
        if let meeting = pick.meetingAt {
            return "\(members) · Meeting \(ClubDates.countdown(to: meeting).lowercasedFirst)"
        }
        return "\(members) · Reading \(pick.title)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let pick = club.currentPick {
                BookCoverView(book: pick.asBook, size: 58)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.chrome.opacity(0.08))
                    .frame(width: 58, height: 87)
                    .overlay(
                        Image(systemName: "book.closed")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    )
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(club.name)
                    .font(Theme.title2())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                ClubAvatarStack(members: club.orderedMemberIds.compactMap { club.members[$0] }, size: 24)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.cardPadding)
        .wellReadCard()
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let first = first else { return self }
        return first.lowercased() + dropFirst()
    }
}
