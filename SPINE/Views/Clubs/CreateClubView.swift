//
//  CreateClubView.swift
//  SPINE
//
//  Start a club: name it, decide who runs it, pull in readers already on
//  SPINE. Texting people who aren't on SPINE yet happens right after, from
//  the invite sheet the new club opens with.
//

import SwiftUI

struct CreateClubView: View {
    let onCreated: (BookClub) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService

    @State private var name = ""
    @State private var everyoneIsAdmin = false
    @State private var pickMode: BookClub.PickMode = .groupVote
    @State private var selected: [ClubMemberPickerView.Selection] = []
    @State private var showPicker = false
    @State private var creating = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var uid: String? { authService.firebaseUser?.uid ?? appState.viewerUid }
    private var canCreate: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !creating }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        VStack(alignment: .leading, spacing: 8) {
                            ClubFieldLabel(text: "Club name")
                            ClubTextField(placeholder: "Thursday Night Book Club", text: $name)
                                .focused($nameFocused)
                                .onChange(of: name) { _, v in
                                    if v.count > BookClub.maxNameLength { name = String(v.prefix(BookClub.maxNameLength)) }
                                }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            ClubFieldLabel(text: "Who runs it?")
                            VStack(spacing: 8) {
                                governanceOption(
                                    selected: !everyoneIsAdmin,
                                    title: "I'm the admin",
                                    body: "You pick the books, set meetings, and manage members. You can add more admins later."
                                ) { everyoneIsAdmin = false }
                                governanceOption(
                                    selected: everyoneIsAdmin,
                                    title: "Everyone's an admin",
                                    body: "Anyone in the club can pick the next book, move the meeting, or invite people."
                                ) { everyoneIsAdmin = true }
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            ClubFieldLabel(text: "How are books picked?")
                            VStack(spacing: 8) {
                                ForEach(BookClub.PickMode.allCases, id: \.self) { mode in
                                    governanceOption(selected: pickMode == mode, title: mode.title, body: mode.blurb) { pickMode = mode }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            ClubFieldLabel(text: "Members")
                            if selected.isEmpty {
                                Text("Add readers who are already on SPINE. You can text everyone else an invite next.")
                                    .font(Theme.callout())
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                FlowLayout(spacing: 8) {
                                    ForEach(selected) { s in
                                        HStack(spacing: 6) {
                                            UserAvatarView(urlString: s.user.profileImageURL, displayName: s.user.displayName, firstName: s.user.firstName, lastName: s.user.lastName, size: 22)
                                            Text(s.user.firstName?.isEmpty == false ? s.user.firstName! : s.user.displayName)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(Theme.textPrimary)
                                            Button {
                                                selected.removeAll { $0.id == s.id }
                                            } label: {
                                                Image(systemName: "xmark")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundStyle(Theme.textSecondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.leading, 4)
                                        .padding(.trailing, 10)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Theme.surfaceElevated))
                                        .overlay(Capsule().strokeBorder(Theme.chrome.opacity(0.2), lineWidth: 1))
                                    }
                                }
                            }
                            ClubSecondaryButton(title: selected.isEmpty ? "Add SPINE readers" : "Add more", icon: "person.badge.plus") {
                                nameFocused = false
                                showPicker = true
                            }
                        }

                        if let error {
                            Text(error)
                                .font(Theme.callout())
                                .foregroundStyle(Theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        ClubPrimaryButton(title: "Create club", icon: "checkmark", isLoading: creating, isEnabled: canCreate) {
                            create()
                        }
                    }
                    .padding(.horizontal, Theme.horizontalPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("New club")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .sheet(isPresented: $showPicker) {
                ClubMemberPickerView(
                    excludedUids: Set([uid].compactMap { $0 }),
                    initialSelection: selected,
                    title: "Add members"
                ) { picked in
                    selected = picked
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { nameFocused = true }
            }
        }
    }

    private func governanceOption(selected isOn: Bool, title: String, body: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isOn ? Theme.chrome : Theme.textTertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(body)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Theme.cardCornerRadius).fill(Theme.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardCornerRadius).strokeBorder(isOn ? Theme.chrome.opacity(0.6) : Theme.chrome.opacity(0.18), lineWidth: isOn ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        }
        .buttonStyle(.springPress)
    }

    private func create() {
        guard let uid else {
            error = BookClubError.notSignedIn.errorDescription
            return
        }
        if ClubsPreview.isActive {
            onCreated(.uiPreviewDemo)
            dismiss()
            return
        }
        creating = true
        error = nil
        Task {
            do {
                let club = try await BookClubService.shared.createClub(
                    name: name,
                    creatorUid: uid,
                    creator: appState.currentUser,
                    everyoneIsAdmin: everyoneIsAdmin,
                    pickMode: pickMode,
                    initialMembers: selected.map { (uid: $0.uid, user: $0.user) }
                )
                creating = false
                onCreated(club)
                dismiss()
            } catch {
                creating = false
                self.error = error.localizedDescription
            }
        }
    }
}
