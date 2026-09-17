//
//  UserProfileCardSheet.swift
//  SPINE
//
//  Tapping a member's avatar inside their library opens their card: the SPINE
//  library card, swipeable to its back (stamps land there later), with their
//  follow graph underneath. The lists are plain rosters on purpose, no
//  follower/following counts anywhere. Your own avatar in the Library header
//  opens the same page about yourself: same card and rosters, plus a settings
//  gear and a download button. Copy rule: no em-dashes in user-facing text.
//

import SwiftUI

struct UserProfileCardSheet: View {
    let userId: String
    let user: User

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private let userRepo = UserRepository()

    @State private var details: LibraryCardDetails?
    @State private var roster: RosterTab = .following
    @State private var followingRows: [RosterRow] = []
    @State private var followerRows: [RosterRow] = []
    @State private var hasLoadedFollowing = false
    @State private var hasLoadedFollowers = false
    /// Who the signed-in reader follows, kept locally so a tap flips the button
    /// right away instead of waiting on the write.
    @State private var myFollowing: Set<String> = []
    @State private var followInFlight: Set<String> = []
    /// Measured height of the card front, so the back matches it exactly.
    @State private var frontHeight: CGFloat = 208
    @State private var showSettings = false
    /// Roster row tapped: pushes that member's full library over the card.
    @State private var selectedRosterUserId: String?
    /// Holding the card's photo blows it up over a dimmed screen.
    @State private var showAvatarZoom = false

    enum RosterTab: String, CaseIterable {
        case following = "Following"
        case followers = "Followers"
    }

    struct RosterRow: Identifiable, Equatable {
        let id: String
        let user: User
    }

    private var myUid: String? { authService.firebaseUser?.uid }

    /// Looking at your own card: the page gains a settings gear and a download
    /// button, and the copy switches to second person.
    private var isSelf: Bool { myUid == userId }

    /// For your own page, prefer the live user doc so a profile edit made from
    /// settings shows up on the card as soon as you come back to it.
    private var displayUser: User {
        isSelf ? (appState.currentUser ?? user) : user
    }

    private var visibleRows: [RosterRow] {
        roster == .following ? followingRows : followerRows
    }

    private var hasLoadedVisibleRows: Bool {
        roster == .following ? hasLoadedFollowing : hasLoadedFollowers
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                    .avatarZoom(
                        isPresented: $showAvatarZoom,
                        urlString: displayUser.profileImageURL,
                        displayName: displayUser.displayName,
                        firstName: displayUser.firstName,
                        lastName: displayUser.lastName,
                        caption: details?.name ?? displayUser.displayName
                    )
                ScrollView {
                    VStack(spacing: 22) {
                        cardPager
                        if isSelf, let details {
                            LibraryCardDownloadButton(details: details, prominent: false)
                                .padding(.horizontal, 24)
                        }
                        rosterPicker
                        rosterList
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .accessibilityLabel("Close")
                }
                if isSelf {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                ProfileSettingsView()
                    .environmentObject(authService)
                    .environmentObject(appState)
            }
            .navigationDestination(item: $selectedRosterUserId) { uid in
                UserLibraryDetailView(userId: uid)
                    .environmentObject(authService)
                    .environmentObject(appState)
            }
        }
        .task { await load() }
        // A profile edit from settings changes the card's fields: rebuild it.
        .onChange(of: appState.currentUser) { _, _ in
            guard isSelf else { return }
            details = nil
            Task { await loadCard() }
        }
    }

    private var navTitle: String {
        if isSelf { return "Settings" }
        return displayUser.firstName?.isEmpty == false ? "\(displayUser.firstName ?? "")'s card" : "Card"
    }

    // MARK: - Card

    /// Front and back on one horizontal track: the back peeks past the right
    /// edge so the swipe is discoverable without a hint label.
    private var cardPager: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if let details {
                        LibraryCardFace(details: details) {
                            WizardHaptics.step()
                            AvatarZoomPresentation.present($showAvatarZoom)
                        }
                        .transition(.opacity)
                    } else {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Theme.surfaceElevated)
                            .overlay(ProgressView().tint(Theme.textSecondary))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Theme.textPrimary, lineWidth: 2)
                            )
                            .frame(height: frontHeight)
                    }
                }
                .containerRelativeFrame(.horizontal) { width, _ in width - 64 }
                // The card sets the pager's height: pinning a guessed one clips
                // its rounded corners off.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { frontHeight = $0 }

                LibraryCardBackFace(name: details?.name ?? displayUser.displayName)
                    .containerRelativeFrame(.horizontal) { width, _ in width - 64 }
                    .frame(height: frontHeight)
            }
            .scrollTargetLayout()
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Roster

    private var rosterPicker: some View {
        HStack(spacing: 0) {
            ForEach(RosterTab.allCases, id: \.self) { tab in
                Button {
                    guard roster != tab else { return }
                    withAnimation(.easeInOut(duration: 0.18)) { roster = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(roster == tab ? Theme.textPrimary : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(roster == tab ? Theme.surfaceElevated : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.surface))
        .padding(.horizontal, 24)
        .sensoryFeedback(.selection, trigger: roster)
    }

    @ViewBuilder
    private var rosterList: some View {
        if !hasLoadedVisibleRows {
            ProgressView()
                .tint(Theme.textSecondary)
                .padding(.top, 24)
        } else if visibleRows.isEmpty {
            Text(emptyMessage)
                .font(Theme.body())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 20)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(visibleRows) { row in
                    rosterRow(row)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var emptyMessage: String {
        if isSelf {
            switch roster {
            case .following: return "You are not following anyone yet."
            case .followers: return "No one is following you yet."
            }
        }
        let name = displayUser.firstName?.isEmpty == false ? (displayUser.firstName ?? "They") : "They"
        switch roster {
        case .following: return "\(name) is not following anyone yet."
        case .followers: return "No one is following \(name) yet."
        }
    }

    private func rosterRow(_ row: RosterRow) -> some View {
        HStack(spacing: 12) {
            // Avatar and name open that member's library; the follow button
            // stays its own tap target.
            Button {
                selectedRosterUserId = row.id
            } label: {
                HStack(spacing: 12) {
                    rosterAvatar(row.user)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.user.displayName)
                            .font(Theme.body())
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text("@\(row.user.username)")
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            followButton(for: row)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }

    @ViewBuilder
    private func followButton(for row: RosterRow) -> some View {
        if let me = myUid, me != row.id {
            let following = myFollowing.contains(row.id)
            Button {
                Task { await toggleFollow(row.id) }
            } label: {
                Text(following ? "Following" : "Follow")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(following ? Theme.textPrimary : Theme.background)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(following ? Theme.surfaceElevated : Theme.accent)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Theme.textTertiary.opacity(following ? 0.35 : 0), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(followInFlight.contains(row.id))
        }
    }

    private func rosterAvatar(_ u: User) -> some View {
        UserAvatarView(
            urlString: u.profileImageURL,
            displayName: u.displayName,
            firstName: u.firstName,
            lastName: u.lastName,
            size: 40
        )
    }

    // MARK: - Data

    private func load() async {
        async let cardTask: Void = loadCard()
        async let graphTask: Void = loadGraph()
        _ = await (cardTask, graphTask)
    }

    private func loadCard() async {
        guard details == nil else { return }
        let cardUser = displayUser
        let photo = await LibraryCardExporter.loadPhoto(urlString: cardUser.profileImageURL)
        let number = await userRepo.memberNumber(joinedAt: cardUser.joinedAt)
        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.25)) {
                details = LibraryCardDetails.from(user: cardUser, cardNumber: max(1, number ?? 1), photo: photo)
            }
        }
    }

    private func loadGraph() async {
        if let me = myUid, let mine = await userRepo.getUser(uid: me) {
            await MainActor.run { myFollowing = Set(mine.following) }
        }

        let followingUids = displayUser.following.filter { !HiddenAccounts.isHidden(uid: $0, viewerUid: myUid) }
        let followingUsers = await userRepo.getUsers(uids: followingUids)
        let following = followingUsers
            .map { RosterRow(id: $0.key, user: $0.value) }
            .sorted { $0.user.displayName.localizedCaseInsensitiveCompare($1.user.displayName) == .orderedAscending }

        let followers = await userRepo.usersFollowingProfiles(uid: userId, viewerUid: myUid)
            .map { RosterRow(id: $0.uid, user: $0.user) }

        await MainActor.run {
            followingRows = following
            followerRows = followers
            hasLoadedFollowing = true
            hasLoadedFollowers = true
        }
    }

    private func toggleFollow(_ targetUid: String) async {
        guard let me = myUid, me != targetUid, !followInFlight.contains(targetUid) else { return }
        let next = !myFollowing.contains(targetUid)
        followInFlight.insert(targetUid)
        if next { myFollowing.insert(targetUid) } else { myFollowing.remove(targetUid) }
        defer { followInFlight.remove(targetUid) }
        do {
            try await userRepo.setFollowing(currentUid: me, targetUid: targetUid, follow: next)
        } catch {
            // Put the button back the way it was: the write did not land.
            if next { myFollowing.remove(targetUid) } else { myFollowing.insert(targetUid) }
        }
    }
}

// MARK: - Card back

/// The reverse of the card: ruled lines and nothing else, waiting on stamps.
struct LibraryCardBackFace: View {
    let name: String
    var palette: LibraryCardPalette = .adaptive

    var body: some View {
        VStack(spacing: 26) {
            ForEach(0..<5, id: \.self) { _ in
                Rectangle()
                    .fill(palette.ink.opacity(0.16))
                    .frame(height: 1)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(palette.page)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(palette.ink, lineWidth: 2)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Back of \(name)'s library card.")
    }
}
