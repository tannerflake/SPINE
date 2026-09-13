//
//  ClubSettingsView.swift
//  SPINE
//
//  Rename, governance, admins, member management, leave, delete.
//

import SwiftUI

struct ClubSettingsView: View {
    let club: BookClub
    var onLeft: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService

    @State private var name: String
    @State private var everyoneIsAdmin: Bool
    @State private var confirmLeave = false
    @State private var confirmDelete = false
    @State private var memberToRemove: String?
    @State private var busy = false

    init(club: BookClub, onLeft: @escaping () -> Void = {}) {
        self.club = club
        self.onLeft = onLeft
        _name = State(initialValue: club.name)
        _everyoneIsAdmin = State(initialValue: club.everyoneIsAdmin)
    }

    private var uid: String? { authService.firebaseUser?.uid ?? appState.viewerUid }
    private var isAdmin: Bool { uid.map(club.isAdmin) ?? false }
    private var isSoleAdmin: Bool {
        guard let uid, !club.everyoneIsAdmin else { return false }
        return club.adminIds == [uid] && club.memberIds.count > 1
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if isAdmin {
                        TextField("Club name", text: $name)
                            .font(.system(size: 16, weight: .semibold))
                            .submitLabel(.done)
                            .onSubmit(saveName)
                            .onChange(of: name) { _, v in
                                if v.count > BookClub.maxNameLength { name = String(v.prefix(BookClub.maxNameLength)) }
                            }
                    } else {
                        Text(club.name).font(.system(size: 16, weight: .semibold))
                    }
                    HStack {
                        Text("Club code")
                        Spacer()
                        Text(club.inviteCode)
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .kerning(2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                } header: {
                    Text("Club")
                } footer: {
                    if isAdmin && name.trimmingCharacters(in: .whitespaces) != club.name {
                        Button("Save name", action: saveName)
                            .font(.system(size: 13, weight: .semibold))
                    }
                }

                if isAdmin {
                    Section {
                        Toggle(isOn: $everyoneIsAdmin) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Everyone's an admin")
                                Text("Any member can pick books, move the meeting, and manage members.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .tint(Theme.toggleOn)
                        .onChange(of: everyoneIsAdmin) { _, v in
                            guard v != club.everyoneIsAdmin, let uid else { return }
                            run { try await BookClubService.shared.setEveryoneIsAdmin(clubId: club.id, actorUid: uid, value: v) }
                        }
                    } header: {
                        Text("Who runs it")
                    }
                }

                Section {
                    ForEach(club.orderedMemberIds, id: \.self) { memberUid in
                        if let m = club.members[memberUid] {
                            memberRow(uid: memberUid, member: m)
                        }
                    }
                } header: {
                    Text("Members · \(club.memberIds.count)")
                } footer: {
                    if isAdmin && !club.everyoneIsAdmin {
                        Text("Swipe a member to remove them. Tap the shield to make someone an admin.")
                    } else if isAdmin {
                        Text("Swipe a member to remove them.")
                    }
                }

                Section {
                    Button(role: .destructive) { confirmLeave = true } label: {
                        Label("Leave club", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    if isAdmin {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete club", systemImage: "trash")
                        }
                    }
                } footer: {
                    if isSoleAdmin {
                        Text("You're the only admin. If you leave, the longest-standing member becomes admin.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .confirmationDialog("Leave \(club.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave club", role: .destructive) { leave() }
            } message: {
                Text(club.memberIds.count == 1 ? "You're the last member, so the club will be deleted." : "You can rejoin later with the club code.")
            }
            .confirmationDialog("Delete \(club.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete for everyone", role: .destructive) { deleteClub() }
            } message: {
                Text("Removes the club for all \(club.memberIds.count) members. Nobody's personal library changes.")
            }
            .confirmationDialog(
                "Remove \(memberToRemove.flatMap { club.members[$0]?.displayName } ?? "member")?",
                isPresented: Binding(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove from club", role: .destructive) {
                    if let target = memberToRemove { remove(target) }
                    memberToRemove = nil
                }
            }
            .disabled(busy)
        }
    }

    private func memberRow(uid memberUid: String, member: BookClub.Member) -> some View {
        let memberIsAdmin = !club.everyoneIsAdmin && club.adminIds.contains(memberUid)
        return HStack(spacing: 12) {
            UserAvatarView(urlString: member.photoURL, displayName: member.displayName, firstName: member.firstName, lastName: nil, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(memberUid == uid ? "You" : member.displayName)
                    .font(.system(size: 15, weight: .semibold))
                if !member.username.isEmpty {
                    Text("@\(member.username)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
            if !club.everyoneIsAdmin {
                if isAdmin && memberUid != uid {
                    Button {
                        guard let actor = uid else { return }
                        run { try await BookClubService.shared.setAdmin(clubId: club.id, actorUid: actor, uid: memberUid, isAdmin: !memberIsAdmin) }
                    } label: {
                        Image(systemName: memberIsAdmin ? "shield.fill" : "shield")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(memberIsAdmin ? Theme.chrome : Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(memberIsAdmin ? "Remove admin" : "Make admin")
                } else if memberIsAdmin {
                    Text("ADMIN")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isAdmin && memberUid != uid {
                Button(role: .destructive) { memberToRemove = memberUid } label: {
                    Label("Remove", systemImage: "person.badge.minus")
                }
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        if ClubsPreview.isActive { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await work() } catch {
                ToastCenter.shared.show(Toast(style: .error, status: "ERROR", message: error.localizedDescription))
            }
        }
    }

    private func saveName() {
        guard let uid else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != club.name else { return }
        run { try await BookClubService.shared.rename(clubId: club.id, actorUid: uid, name: trimmed) }
    }

    private func remove(_ target: String) {
        guard let uid else { return }
        run { try await BookClubService.shared.removeMember(clubId: club.id, actorUid: uid, uid: target) }
    }

    private func leave() {
        guard let uid else { return }
        if ClubsPreview.isActive { dismiss(); onLeft(); return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await BookClubService.shared.leave(club: club, myUid: uid)
                dismiss()
                onLeft()
            } catch {
                ToastCenter.shared.show(Toast(style: .error, status: "ERROR", message: error.localizedDescription))
            }
        }
    }

    private func deleteClub() {
        if ClubsPreview.isActive { dismiss(); onLeft(); return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await BookClubService.shared.deleteClub(club)
                Analytics.amplitude?.track(eventType: "Deleted Book Club", eventProperties: ["club_id": club.id])
                dismiss()
                onLeft()
            } catch {
                ToastCenter.shared.show(Toast(style: .error, status: "ERROR", message: error.localizedDescription))
            }
        }
    }
}
