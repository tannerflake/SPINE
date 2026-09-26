//
//  ClubsView.swift
//  SPINE
//
//  Clubs tab root: the reader's clubs, or the pitch plus Start/Join when they
//  have none. One club and there is no list to pick from, the club page itself
//  is the root (starting or joining another lives in its settings sheet).
//  Detail pages push onto this stack; deep links and pushes land here via
//  `.spineOpenClub` / `.spineJoinClubWithCode`.
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
            if ClubsPreview.startsEmpty {
                clubs = []
            } else {
                let demo = ClubsPreview.demoClubWithVote(.uiPreviewDemo)
                clubs = ClubsPreview.hasMultiple ? [demo, .uiPreviewDemoSecond] : [demo]
            }
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

    /// The one club they belong to, if that's all there is: no list to pick from,
    /// so the club page is the tab.
    private var soloClub: BookClub? {
        guard store.loaded, store.clubs.count == 1 else { return nil }
        return store.clubs[0]
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let solo = soloClub {
                    detail(for: solo.id, initial: solo)
                } else {
                    listRoot
                }
            }
            .navigationDestination(for: String.self) { clubId in
                detail(for: clubId, initial: store.clubs.first { $0.id == clubId })
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateClubView { club in
                freshlyCreatedClubId = club.id
                reveal(clubId: club.id)
            }
        }
        .sheet(isPresented: $showJoin, onDismiss: { joinPrefill = nil }) {
            JoinClubSheet(prefilledCode: joinPrefill) { clubId in
                reveal(clubId: clubId)
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

    private var listRoot: some View {
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
    }

    private func detail(for clubId: String, initial: BookClub?) -> some View {
        ClubDetailView(
            clubId: clubId,
            initial: initial,
            openInviteOnAppear: freshlyCreatedClubId == clubId,
            onStartClub: { showCreate = true },
            onJoinClub: { showJoin = true }
        )
        .onAppear {
            if freshlyCreatedClubId == clubId {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { freshlyCreatedClubId = nil }
            }
        }
    }

    private func open(clubId: String) {
        path = NavigationPath()
        // The solo club is already the root; pushing it would stack a duplicate.
        guard soloClub?.id != clubId else { return }
        path.append(clubId)
    }

    /// After creating or joining, only push when a list is (or is becoming) the
    /// root. Going from nothing to one club, the club page takes over the tab.
    private func reveal(clubId: String) {
        guard !store.clubs.isEmpty else { return }
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
            HStack(alignment: .center, spacing: 10) {
                Text("CLUBS")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Theme.textPrimary)
                Text("BETA")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(Theme.textSecondary, lineWidth: Theme.chromeHairline))
                    .accessibilityLabel("Beta")
            }
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
                .spineCard()
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Read a book together.")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ClubPrimaryButton(title: "Start a club", icon: "plus") { showCreate = true }
                ClubSecondaryButton(title: "Join with a code", icon: "ticket") { showJoin = true }
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.top, 6)
    }
}

/// One club on the Clubs tab: current cover, name, meeting countdown, members.
struct ClubCard: View {
    let club: BookClub
    let myUid: String?

    /// A voted pick stays hidden here until this member has watched the reveal.
    private var pickIsSpoiler: Bool {
        guard let uid = myUid else { return false }
        return club.pickHiddenPendingReveal(for: uid)
    }

    private var subtitle: String {
        let members = "\(club.memberIds.count) \(club.memberIds.count == 1 ? "member" : "members")"
        if pickIsSpoiler { return "\(members) · The votes are in" }
        if let vote = club.vote, vote.isOpen {
            return "\(members) · \(vote.phase == .picks ? "Suggesting books" : "Voting now")"
        }
        guard let pick = club.currentPick else { return "\(members) · No book picked yet" }
        if let meeting = pick.meetingAt {
            return "\(members) · Meeting \(ClubDates.countdown(to: meeting).lowercasedFirst)"
        }
        return "\(members) · Reading \(pick.title)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let pick = club.currentPick, !pickIsSpoiler {
                BookCoverView(book: pick.asBook, size: 58)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.chrome.opacity(0.08))
                    .frame(width: 58, height: 87)
                    .overlay(
                        Image(systemName: pickIsSpoiler ? "party.popper" : "book.closed")
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
        .spineCard()
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let first = first else { return self }
        return first.lowercased() + dropFirst()
    }
}
