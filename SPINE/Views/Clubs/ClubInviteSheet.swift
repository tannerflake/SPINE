//
//  ClubInviteSheet.swift
//  SPINE
//
//  Three ways in: share the code/link into the group chat, text a specific
//  contact (who then lands in the club automatically when they sign up with
//  that number), or add readers already on SPINE.
//

import SwiftUI
import UIKit

struct ClubInviteSheet: View {
    let club: BookClub

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService

    @State private var showContacts = false
    @State private var contacts: [SyncedContact] = []
    @State private var contactsLoaded = false
    @State private var contactQuery = ""
    @State private var contactToText: SyncedContact?
    @State private var invitedContactIds: Set<String> = []
    @State private var showMemberPicker = false
    @State private var copied = false

    private var uid: String? { authService.firebaseUser?.uid ?? appState.viewerUid }

    private var inviteText: String {
        "Join my book club \u{201C}\(club.name)\u{201D} on SPINE. Get the app: \(AppLinks.appStore) then open the Clubs tab and enter code \(club.inviteCode). Already have SPINE? Tap \(club.inviteURL.absoluteString)"
    }

    private var filteredContacts: [SyncedContact] {
        let q = contactQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return contacts }
        return contacts.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        codeCard
                        VStack(spacing: 10) {
                            ShareLink(item: inviteText) {
                                Label("Share invite", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.spinePrimary)
                            .simultaneousGesture(TapGesture().onEnded {
                                Analytics.amplitude?.track(eventType: "Shared Club Invite", eventProperties: ["club_id": club.id])
                            })
                            HStack(spacing: 10) {
                                ClubSecondaryButton(title: showContacts ? "Hide contacts" : "Text a contact", icon: "message") {
                                    withAnimation(.snappy) { showContacts.toggle() }
                                    if showContacts { loadContactsIfNeeded() }
                                }
                                ClubSecondaryButton(title: "Add SPINE readers", icon: "person.badge.plus") { showMemberPicker = true }
                            }
                        }
                        if showContacts {
                            contactsSection
                        }
                        Text("Drop the invite in your group chat and everyone lands in the same club. People you text by number are added the moment they sign up with it.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, Theme.horizontalPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Invite to \(club.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .sheet(item: $contactToText) { contact in
                MessageComposeView(
                    recipients: Array(contact.phoneNumbers.prefix(1)),
                    body: inviteText,
                    onFinish: { markInvited(contact) }
                )
            }
            .sheet(isPresented: $showMemberPicker) {
                ClubMemberPickerView(
                    excludedUids: Set(club.memberIds),
                    title: "Add to \(club.name)",
                    confirmLabel: "Add"
                ) { picked in
                    addMembers(picked)
                }
            }
        }
    }

    // MARK: - Code

    private var codeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CLUB CODE")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(Theme.textSecondary)
            HStack {
                Text(club.inviteCode)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .kerning(6)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    UIPasteboard.general.string = club.inviteCode
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { copied = false } }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .bold))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.surfaceElevated))
                    .overlay(Capsule().strokeBorder(Theme.chrome.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.springPress)
            }
            Text("Anyone with this code can join from the Clubs tab.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(18)
        .spineCard()
    }

    // MARK: - Contacts

    private var contactsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search contacts", text: $contactQuery)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surfaceElevated))

            if !contactsLoaded {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.accent)
                    Text("Reading your contacts on this device only.")
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 8)
            } else if contacts.isEmpty {
                Text("No contacts available. Allow Contacts access in Settings to text invites from here, or use Share invite above.")
                    .font(Theme.callout())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(filteredContacts.prefix(200)) { contact in
                        contactRow(contact)
                    }
                }
            }
        }
    }

    private func contactRow(_ contact: SyncedContact) -> some View {
        let invited = invitedContactIds.contains(contact.id)
        return HStack(spacing: 11) {
            UserAvatarView(urlString: nil, displayName: contact.displayName, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if invited {
                    Text("Invited. They'll join automatically with this number.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                } else if let number = contact.phoneNumbers.first {
                    Text(number)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                contactToText = contact
            } label: {
                Text(invited ? "Text again" : "Text")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(invited ? Theme.textSecondary : Theme.onChrome)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(invited ? Color.clear : Theme.textPrimary))
                    .overlay(Capsule().stroke(Theme.textPrimary.opacity(invited ? 0.2 : 0), lineWidth: 1.5))
            }
            .buttonStyle(.springPress)
            .disabled(contact.phoneNumbers.isEmpty)
        }
        .padding(10)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func loadContactsIfNeeded() {
        guard !contactsLoaded else { return }
        Task {
            let fetched = await ContactSyncService.fetchContacts()
            contacts = fetched
                .filter { !$0.phoneNumbers.isEmpty }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            contactsLoaded = true
        }
    }

    /// Registers the number's hash so the person is auto-added when they join
    /// SPINE with it. Only the hash leaves the device.
    private func markInvited(_ contact: SyncedContact) {
        invitedContactIds.insert(contact.id)
        guard !ClubsPreview.isActive else { return }
        Task {
            try? await BookClubService.shared.invitePhones(clubId: club.id, phoneNumbers: contact.phoneNumbers)
        }
    }

    private func addMembers(_ picked: [ClubMemberPickerView.Selection]) {
        guard let uid, !picked.isEmpty else { return }
        if ClubsPreview.isActive {
            ToastCenter.shared.show(Toast(style: .info, status: "ADDED", message: "\(picked.count) added"))
            return
        }
        Task {
            do {
                try await BookClubService.shared.addMembers(clubId: club.id, actorUid: uid, users: picked.map { (uid: $0.uid, user: $0.user) })
                ToastCenter.shared.show(Toast(style: .info, status: "ADDED", message: picked.count == 1 ? "\(picked[0].user.displayName) is in" : "\(picked.count) readers added"))
            } catch {
                ToastCenter.shared.show(Toast(style: .error, status: "ERROR", message: error.localizedDescription))
            }
        }
    }
}
