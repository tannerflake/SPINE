//
//  ClubMemberPickerView.swift
//  SPINE
//
//  Multi-select over the reader roster (people you follow first), used when
//  starting a club and when adding members later.
//

import SwiftUI

struct ClubMemberPickerView: View {
    struct Selection: Identifiable, Equatable {
        let uid: String
        let user: User
        var id: String { uid }
        static func == (a: Selection, b: Selection) -> Bool { a.uid == b.uid }
    }

    let excludedUids: Set<String>
    var initialSelection: [Selection] = []
    var title = "Add members"
    var confirmLabel = "Done"
    let onDone: ([Selection]) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService
    @ObservedObject private var directory = UserDirectory.shared

    @State private var query = ""
    @State private var selected: [Selection] = []

    private var myUid: String? { authService.firebaseUser?.uid ?? appState.viewerUid }

    private var candidates: [UserDirectory.Reader] {
        let following = Set(appState.currentUser?.following ?? [])
        let pool = directory.readers.filter { !excludedUids.contains($0.id) && $0.id != myUid }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let ranked: [UserDirectory.Reader]
        if trimmed.isEmpty {
            ranked = pool.sorted { a, b in
                let fa = following.contains(a.id), fb = following.contains(b.id)
                if fa != fb { return fa }
                return a.user.displayName.localizedCaseInsensitiveCompare(b.user.displayName) == .orderedAscending
            }
        } else {
            ranked = PersonSearch.ranked(pool, query: trimmed, user: \.user)
        }
        return Array(ranked.prefix(80))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    searchField
                        .padding(.horizontal, Theme.horizontalPadding)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                    if !selected.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(selected) { s in
                                    VStack(spacing: 4) {
                                        UserAvatarView(urlString: s.user.profileImageURL, displayName: s.user.displayName, firstName: s.user.firstName, lastName: s.user.lastName, size: 40)
                                            .overlay(alignment: .topTrailing) {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.system(size: 14))
                                                    .foregroundStyle(Theme.chrome)
                                                    .background(Circle().fill(Theme.background))
                                                    .offset(x: 4, y: -4)
                                            }
                                        Text(s.user.firstName?.isEmpty == false ? s.user.firstName! : s.user.displayName)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(Theme.textSecondary)
                                            .lineLimit(1)
                                            .frame(width: 52)
                                    }
                                    .onTapGesture { toggle(uid: s.uid, user: s.user) }
                                }
                            }
                            .padding(.horizontal, Theme.horizontalPadding)
                            .padding(.vertical, 6)
                        }
                    }
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if directory.readers.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView().tint(Theme.accent)
                                    Text("Loading readers…")
                                        .font(Theme.callout())
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .padding(.top, 30)
                            } else if candidates.isEmpty {
                                Text(query.isEmpty ? "Nobody left to add." : "No readers match \u{201C}\(query)\u{201D}.")
                                    .font(Theme.callout())
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.top, 30)
                            } else {
                                ForEach(candidates) { reader in
                                    row(reader)
                                }
                            }
                        }
                        .padding(.horizontal, Theme.horizontalPadding)
                        .padding(.bottom, 90)
                    }
                }
                VStack {
                    Spacer()
                    ClubPrimaryButton(title: selected.isEmpty ? confirmLabel : "\(confirmLabel) · \(selected.count)", icon: "checkmark") {
                        onDone(selected)
                        dismiss()
                    }
                    .padding(.horizontal, Theme.horizontalPadding)
                    .padding(.bottom, 12)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .onAppear {
                selected = initialSelection
                directory.warm(uid: myUid, following: appState.currentUser?.following ?? [])
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search by name or @handle", text: $query)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.chrome.opacity(0.18), lineWidth: 1))
    }

    private func row(_ reader: UserDirectory.Reader) -> some View {
        let isOn = selected.contains { $0.uid == reader.id }
        let follows = appState.currentUser?.following.contains(reader.id) ?? false
        return Button {
            toggle(uid: reader.id, user: reader.user)
        } label: {
            HStack(spacing: 11) {
                UserAvatarView(urlString: reader.user.profileImageURL, displayName: reader.user.displayName, firstName: reader.user.firstName, lastName: reader.user.lastName, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reader.user.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(follows ? "@\(reader.user.username) · Following" : "@\(reader.user.username)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isOn ? Theme.chrome : Theme.textTertiary.opacity(0.6))
            }
            .padding(11)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isOn ? Theme.chrome.opacity(0.5) : Theme.textPrimary.opacity(0.12), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.springPress)
    }

    private func toggle(uid: String, user: User) {
        if let i = selected.firstIndex(where: { $0.uid == uid }) {
            selected.remove(at: i)
        } else {
            selected.append(Selection(uid: uid, user: user))
        }
    }
}
