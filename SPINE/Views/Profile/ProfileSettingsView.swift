//
//  ProfileSettingsView.swift
//  SPINE
//
//  Settings screen pushed from the gear on your own profile card page. Holds
//  everything the old avatar menu offered: edit profile, find friends,
//  Goodreads import, appearance, sign out, and the full delete-account flow
//  (which moved here from LibraryView). Copy rule: no em-dashes in
//  user-facing text.
//

import SwiftUI

struct ProfileSettingsView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var appState: AppState

    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.defaultValue.rawValue

    @State private var showEditProfile = false
    @State private var showFindFriends = false
    @State private var showGoodreadsImport = false
    @State private var showDeleteAccountConfirm = false
    /// Second confirmation step: the user must type DELETE before the account is removed.
    @State private var showDeleteAccountTypeConfirm = false
    @State private var deleteAccountConfirmText = ""
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    section(header: "Profile") {
                        settingsRow(title: "Edit profile", icon: "person.crop.circle") {
                            showEditProfile = true
                        }
                        rowDivider
                        settingsRow(title: "Find friends", icon: "person.2.badge.plus") {
                            showFindFriends = true
                        }
                        rowDivider
                        settingsRow(title: "Import your books", icon: "square.and.arrow.down") {
                            showGoodreadsImport = true
                        }
                    }

                    section(header: "App") {
                        appearanceRow
                    }

                    section(header: "Account") {
                        settingsRow(title: "Sign out", icon: "rectangle.portrait.and.arrow.right", showsChevron: false) {
                            authService.signOut()
                        }
                        rowDivider
                        settingsRow(title: "Delete account", icon: "trash", tint: Theme.danger, showsChevron: false) {
                            showDeleteAccountConfirm = true
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .sheet(isPresented: $showEditProfile) {
            ProfileCompletionView(
                mode: .edit,
                title: "Edit profile",
                subtitle: "Update your name, handle, yearly reading goal, and reading tastes.",
                onDismiss: { showEditProfile = false }
            )
            .environmentObject(authService)
            .environmentObject(appState)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showFindFriends) {
            FindFriendsView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showGoodreadsImport, onDismiss: {
            appState.refreshGoodreadsWizardResumeState()
        }) {
            GoodreadsImportView(initialRows: nil)
                .environmentObject(appState)
        }
        .alert("Delete your account?", isPresented: $showDeleteAccountConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete account", role: .destructive) {
                deleteAccountConfirmText = ""
                showDeleteAccountTypeConfirm = true
            }
        } message: {
            Text("This permanently deletes your account and all of your data: library, reviews, comments, likes, and follows. This can't be undone.")
        }
        .alert("Are you sure?", isPresented: $showDeleteAccountTypeConfirm) {
            TextField("Type DELETE to confirm", text: $deleteAccountConfirmText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { deleteAccountConfirmText = "" }
            Button("Delete forever", role: .destructive) {
                guard deleteAccountTextMatches else { return }
                Task { await performAccountDeletion() }
            }
            .disabled(!deleteAccountTextMatches)
        } message: {
            Text("This cannot be undone. Type DELETE to permanently delete your account.")
        }
        .alert("Couldn't delete account", isPresented: Binding(
            get: { deleteAccountError != nil },
            set: { if !$0 { deleteAccountError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteAccountError = nil }
        } message: {
            Text(deleteAccountError ?? "")
        }
        .overlay {
            if isDeletingAccount {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text("Deleting account…")
                            .font(Theme.callout())
                            .foregroundStyle(.white)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    // MARK: - Sections and rows

    private func section<Content: View>(header: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.textTertiary.opacity(0.14))
            .frame(height: 1)
            .padding(.leading, 52)
    }

    private func settingsRow(
        title: String,
        icon: String,
        tint: Color = Theme.textPrimary,
        showsChevron: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 28)
                Text(title)
                    .font(Theme.body())
                    .foregroundStyle(tint)
                Spacer(minLength: 8)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Light / Dark / System, persisted app-wide via `AppearancePreference` and
    /// applied at the root `preferredColorScheme`.
    private var appearanceRow: some View {
        HStack(spacing: 12) {
            let current = AppearancePreference(rawValue: appearanceRaw) ?? .defaultValue
            Image(systemName: current.iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 28)
            Text("Appearance")
                .font(Theme.body())
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Menu {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppearancePreference.allCases) { option in
                        Label(option.label, systemImage: option.iconName)
                            .tag(option.rawValue)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(current.label)
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surfaceElevated)
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Delete account

    /// True when the type-to-confirm field contains DELETE (case-insensitive,
    /// whitespace-trimmed) — the destructive button stays disabled until then.
    private var deleteAccountTextMatches: Bool {
        deleteAccountConfirmText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("DELETE") == .orderedSame
    }

    /// Runs the full deletion (Firestore data + Auth user via the `deleteAccount`
    /// callable); on success the auth listener returns the app to the welcome screen.
    private func performAccountDeletion() async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        do {
            try await authService.deleteAccount()
        } catch {
            deleteAccountError = error.localizedDescription
        }
    }
}
