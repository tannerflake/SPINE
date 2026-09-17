//
//  FindFriendsView.swift
//  SPINE
//
//  Contact sync: matches the address book against Spine members by phone
//  number ("On SPINE" — tap through to their library) and offers one-tap SMS
//  invites for everyone else. Presented as a sheet from the Library profile
//  menu and from the recommend-a-book flow.
//

import SwiftUI
import Contacts

struct FindFriendsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    /// When the flow starts from "recommend this book", the invite text names the book.
    var inviteBookTitle: String? = nil

    @State private var authorization = ContactSyncService.authorizationStatus
    @State private var isLoading = false
    @State private var matched: [MatchedMember] = []
    @State private var inviteCandidates: [SyncedContact] = []
    @State private var searchText = ""
    @State private var contactToInvite: SyncedContact?
    @State private var invitedContactIds: Set<String> = []
    @State private var cantSendTextAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Find friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
            .navigationDestination(for: String.self) { uid in
                UserLibraryDetailView(userId: uid)
            }
        }
        .sheet(item: $contactToInvite) { contact in
            MessageComposeView(
                recipients: Array(contact.phoneNumbers.prefix(1)),
                body: AppLinks.inviteMessage(bookTitle: inviteBookTitle),
                onFinish: { invitedContactIds.insert(contact.id) }
            )
            .ignoresSafeArea()
        }
        .alert("Can't send texts", isPresented: $cantSendTextAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device can't send text messages. You can still share SPINE from the App Store: \(AppLinks.appStore)")
        }
        .task { await syncIfAuthorized() }
    }

    /// `.limited` (iOS 18+) also counts as authorized — partial access still lets us match/invite.
    private var isAuthorizedForContacts: Bool {
        if authorization == .authorized { return true }
        if #available(iOS 18.0, *), authorization == .limited { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch authorization {
        case _ where isAuthorizedForContacts:
            contactList
        case .denied, .restricted:
            explainer(
                title: "Contacts access is off",
                message: "To find friends already on SPINE and invite the rest, allow contact access in Settings.",
                buttonTitle: "Open Settings",
                action: openSettings
            )
        default:
            explainer(
                title: "Find friends from your contacts",
                message: "SPINE checks which of your contacts are already members, matched by phone number, and lets you text an invite to anyone who isn't yet. Contacts stay on your device.",
                buttonTitle: "Sync Contacts",
                action: { Task { await requestAndSync() } }
            )
        }
    }

    private func explainer(title: String, message: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.2.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(Theme.headline())
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.callout())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(buttonTitle, action: action)
                .buttonStyle(.spine(.primary, fullWidth: false))
            Spacer()
            Spacer()
        }
    }

    private var contactList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                searchField

                if isLoading {
                    HStack {
                        ProgressView().tint(Theme.accent)
                        Text("Syncing contacts…")
                            .font(Theme.callout())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }

                if !filteredMatched.isEmpty {
                    sectionHeader("On SPINE")
                    ForEach(filteredMatched) { member in
                        NavigationLink(value: member.uid) {
                            memberRow(member)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !filteredInvites.isEmpty {
                    sectionHeader("Invite to SPINE")
                    ForEach(filteredInvites) { contact in
                        inviteRow(contact)
                    }
                }

                if !isLoading && filteredMatched.isEmpty && filteredInvites.isEmpty {
                    Text(searchText.isEmpty ? "No contacts with phone numbers found." : "No contacts match \u{201C}\(searchText)\u{201D}.")
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .padding()
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Search contacts", text: $searchText)
                .font(Theme.body())
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
        }
        .padding()
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.headline())
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 8)
    }

    private func memberRow(_ member: MatchedMember) -> some View {
        HStack(spacing: 12) {
            avatar(user: member.user)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.user.displayName)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textPrimary)
                Text("@\(member.user.username) · \(member.contact.displayName) in your contacts")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding()
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }

    private func inviteRow(_ contact: SyncedContact) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Theme.surface)
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(contact.displayName.prefix(1)).uppercased())
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                )
                .overlay(Circle().strokeBorder(Theme.chrome.opacity(0.35), lineWidth: 1))
            Text(contact.displayName)
                .font(Theme.body())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer()
            if invitedContactIds.contains(contact.id) {
                Text("INVITED ✓")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Button {
                    if MessageComposeView.canSendText {
                        contactToInvite = contact
                    } else {
                        cantSendTextAlert = true
                    }
                } label: {
                    Text("INVITE")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Theme.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }

    private func avatar(user: User) -> some View {
        UserAvatarView(
            urlString: user.profileImageURL,
            displayName: user.displayName,
            firstName: user.firstName,
            lastName: user.lastName,
            size: 40
        )
    }

    private var filteredMatched: [MatchedMember] {
        guard !searchText.isEmpty else { return matched }
        // Name-first ranking on the SPINE profile, plus contact-name hits for
        // people saved in Contacts under a different name than their profile.
        let ranked = PersonSearch.ranked(matched, query: searchText, user: { $0.user })
        let rankedIds = Set(ranked.map(\.id))
        let contactOnly = matched.filter {
            !rankedIds.contains($0.id) && $0.contact.displayName.localizedCaseInsensitiveContains(searchText)
        }
        return ranked + contactOnly
    }

    private var filteredInvites: [SyncedContact] {
        guard !searchText.isEmpty else { return inviteCandidates }
        return inviteCandidates.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    private func requestAndSync() async {
        let granted = await ContactSyncService.requestAccess()
        authorization = ContactSyncService.authorizationStatus
        guard granted else { return }
        await sync()
    }

    private func syncIfAuthorized() async {
        if isAuthorizedForContacts {
            await sync()
        }
    }

    private func sync() async {
        isLoading = true
        let contacts = await ContactSyncService.fetchContacts()
        let readers = await UserRepository().fetchAllReaderProfiles(excludingUid: appState.authUserId, limit: 500)
        let result = ContactSyncService.match(contacts: contacts, readers: readers)
        matched = result.onSpine
        inviteCandidates = result.toInvite
        isLoading = false
        // Covers members who skipped contacts during onboarding and sync here
        // instead: the server still only announces a genuinely new account.
        ContactSyncService.announceJoinToMatchedContacts(result.onSpine)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
