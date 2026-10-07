//
//  ClubJoinPromptView.swift
//  SPINE
//
//  Nobody lands in a club because someone else put them there. An invite is a
//  question: this one screen ("Hannah invited you to join Thursday Night Reads.
//  Join?") answers it, whether it opens from the launch modal, the push, the
//  bell row, or the invite card on the Clubs tab. Public clubs from Browse use
//  the same screen with no inviter.
//

import SwiftUI

/// What the join screen shows, from an invite or from a public club.
struct ClubJoinPrompt: Identifiable {
    enum Kind { case invite, publicClub }

    let clubId: String
    let clubName: String
    let kind: Kind
    let inviter: BookClub.Member?
    let memberCount: Int
    let members: [BookClub.Member]
    let currentPick: Book?
    /// The invite behind it, for the launch modal's snooze bookkeeping.
    let invite: ClubInvite?

    var id: String { clubId }

    init(invite: ClubInvite) {
        clubId = invite.clubId
        clubName = invite.clubName
        kind = .invite
        inviter = invite.inviter
        memberCount = invite.memberCount
        members = invite.members
        currentPick = invite.currentPick
        self.invite = invite
    }

    init(publicClub club: BookClub) {
        clubId = club.id
        clubName = club.name
        kind = .publicClub
        inviter = nil
        memberCount = club.memberIds.count
        members = club.orderedMemberIds.compactMap { club.members[$0] }
        // A voted pick is only a spoiler for members; outsiders never saw the vote.
        currentPick = club.currentPick?.asBook
        invite = nil
    }
}

struct ClubJoinPromptView: View {
    let prompt: ClubJoinPrompt
    /// Joined: the caller dismisses and opens the club.
    let onJoined: (String) -> Void
    /// Said no to an invite (already recorded server side).
    var onDeclined: () -> Void = {}
    /// Closed without deciding (public club "Not now").
    var onClose: () -> Void = {}

    @State private var joining = false
    @State private var declining = false
    @State private var error: String?

    private var busy: Bool { joining || declining }

    private var headline: String {
        switch prompt.kind {
        case .invite:
            return "\(prompt.inviter?.firstName ?? "Someone") invited you to join \(prompt.clubName)"
        case .publicClub:
            return prompt.clubName
        }
    }

    private var memberLine: String {
        "\(prompt.memberCount) \(prompt.memberCount == 1 ? "member" : "members")"
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 24)

                hero
                    .padding(.bottom, 22)

                Text(prompt.kind == .invite ? "CLUB INVITE" : "PUBLIC CLUB")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(4)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.bottom, 10)

                Text(headline)
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)

                HStack(spacing: 8) {
                    if !prompt.members.isEmpty && prompt.kind == .invite {
                        ClubAvatarStack(members: prompt.members, size: 22)
                    }
                    Text(memberLine)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }

                if let pick = prompt.currentPick {
                    readingNow(pick)
                        .padding(.top, 26)
                        .padding(.horizontal, 28)
                }

                Spacer(minLength: 24)

                if let error {
                    Text(error)
                        .font(Theme.callout())
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 12)
                }

                VStack(spacing: 10) {
                    ClubPrimaryButton(title: "Join club", icon: "checkmark", isLoading: joining, isEnabled: !busy) { join() }

                    Button {
                        prompt.kind == .invite ? decline() : onClose()
                    } label: {
                        Group {
                            if declining {
                                ProgressView().tint(Theme.textSecondary)
                            } else {
                                Text(prompt.kind == .invite ? "No thanks" : "Not now")
                            }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.springPress)
                    .disabled(busy)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
            }
        }
    }

    /// The inviter's face for an invite; the members for a public club.
    @ViewBuilder
    private var hero: some View {
        if let inviter = prompt.inviter {
            UserAvatarView(urlString: inviter.photoURL, displayName: inviter.displayName, firstName: inviter.firstName, lastName: nil, size: 84)
                .avatarZoomOnHold(urlString: inviter.photoURL, displayName: inviter.displayName, firstName: inviter.firstName)
        } else if !prompt.members.isEmpty {
            ClubAvatarStack(members: prompt.members, size: 56, maxShown: 4)
        } else {
            Image(systemName: "person.3.fill")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func readingNow(_ book: Book) -> some View {
        HStack(spacing: 14) {
            BookCoverView(book: book, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text("READING NOW")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(Theme.textTertiary)
                Text(book.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.cardPadding)
        .spineCard()
    }

    private func join() {
        error = nil
        if ClubsPreview.isActive {
            onJoined(prompt.clubId)
            return
        }
        joining = true
        Task {
            defer { joining = false }
            do {
                switch prompt.kind {
                case .invite: try await BookClubService.shared.respondToInvite(clubId: prompt.clubId, accept: true)
                case .publicClub: try await BookClubService.shared.joinPublicClub(clubId: prompt.clubId)
                }
                onJoined(prompt.clubId)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func decline() {
        error = nil
        if ClubsPreview.isActive {
            onDeclined()
            return
        }
        declining = true
        Task {
            defer { declining = false }
            do {
                try await BookClubService.shared.respondToInvite(clubId: prompt.clubId, accept: false)
                onDeclined()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Launch-modal bookkeeping: swiping the invite away snoozes it two days. The
/// invite still waits on the Clubs tab and in the bell meanwhile. Keyed by the
/// invite's createdAt so a fresh invite from the same club shows again.
enum ClubInviteModalStorage {
    private static func key(uid: String, invite: ClubInvite) -> String {
        "clubInviteModal.snoozeUntil.\(uid).\(invite.id).\(Int(invite.createdAt.timeIntervalSince1970))"
    }

    static func isEligible(uid: String, invite: ClubInvite) -> Bool {
        let until = UserDefaults.standard.double(forKey: key(uid: uid, invite: invite))
        return Date().timeIntervalSince1970 >= until
    }

    static func snoozeTwoDays(uid: String, invite: ClubInvite) {
        UserDefaults.standard.set(Date().addingTimeInterval(2 * 86400).timeIntervalSince1970, forKey: key(uid: uid, invite: invite))
    }
}

/// An open invite at the top of the Clubs tab.
struct ClubInviteCard: View {
    let invite: ClubInvite

    var body: some View {
        HStack(spacing: 14) {
            UserAvatarView(urlString: invite.inviter.photoURL, displayName: invite.inviter.displayName, firstName: invite.inviter.firstName, lastName: nil, size: 48)
                .avatarZoomOnHold(urlString: invite.inviter.photoURL, displayName: invite.inviter.displayName, firstName: invite.inviter.firstName)
            VStack(alignment: .leading, spacing: 4) {
                Text(invite.clubName)
                    .font(Theme.title2())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(invite.inviter.firstName) invited you · \(invite.memberCount) \(invite.memberCount == 1 ? "member" : "members")")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Text("View")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.onChrome)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.chrome))
        }
        .padding(Theme.cardPadding)
        .spineCard()
    }
}

/// Browse: every public club, busiest first. Tapping one opens the join screen;
/// clubs you're already in just open.
struct PublicClubsSheet: View {
    /// Joined (or tapped one you're already in): the caller opens the club.
    let onOpenClub: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService

    @State private var clubs: [BookClub]?
    @State private var prompt: ClubJoinPrompt?

    private var uid: String? { authService.firebaseUser?.uid ?? appState.viewerUid }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Clubs anyone on Spine can join.")
                            .font(Theme.callout())
                            .foregroundStyle(Theme.textSecondary)
                        if let clubs {
                            if clubs.isEmpty {
                                Text("No public clubs yet. Start one and set it to Public so readers can find it.")
                                    .font(Theme.callout())
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 20)
                            } else {
                                ForEach(clubs) { club in
                                    Button { tap(club) } label: {
                                        ClubCard(club: club, myUid: uid)
                                    }
                                    .buttonStyle(.springPress)
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                ProgressView().tint(Theme.accent)
                                Text("Finding clubs…")
                                    .font(Theme.callout())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.top, 20)
                        }
                    }
                    .padding(.horizontal, Theme.horizontalPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .refreshable { await load() }
            }
            .navigationTitle("Public clubs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .sheet(item: $prompt) { prompt in
                ClubJoinPromptView(
                    prompt: prompt,
                    onJoined: { clubId in
                        self.prompt = nil
                        dismiss()
                        onOpenClub(clubId)
                    },
                    onClose: { self.prompt = nil }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .task { await load() }
        }
    }

    private func tap(_ club: BookClub) {
        if let uid, club.isMember(uid) {
            dismiss()
            onOpenClub(club.id)
        } else {
            prompt = ClubJoinPrompt(publicClub: club)
        }
    }

    private func load() async {
        if ClubsPreview.isActive {
            clubs = [.uiPreviewDemoPublic]
            return
        }
        clubs = await BookClubService.shared.fetchPublicClubs(viewerUid: uid)
    }
}
