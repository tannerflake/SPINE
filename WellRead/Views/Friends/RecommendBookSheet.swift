//
//  RecommendBookSheet.swift
//  WellRead
//
//  "Recommend this book" — pick members to send a book to (it lands on their
//  queue's Recommended shelf), with an optional note, plus a path to invite a
//  contact who isn't on Spine yet.
//

import SwiftUI

struct RecommendBookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let book: Book

    private struct Reader: Identifiable {
        var id: String { uid }
        let uid: String
        let user: User
    }

    /// Shared roster, cached across presentations (see `UserDirectory`) so the
    /// list is there the moment the sheet opens.
    @ObservedObject private var directory = UserDirectory.shared
    @State private var searchText = ""
    @State private var note = ""
    @State private var sendingTo: Set<String> = []
    @State private var sentTo: Set<String> = []
    @State private var showInviteContacts = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    bookHeader
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            noteField
                            searchField

                            if isLoading {
                                HStack {
                                    ProgressView().tint(Theme.accent)
                                    Text("Loading readers…")
                                        .font(Theme.callout())
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                            } else if filteredReaders.isEmpty {
                                Text(searchText.isEmpty ? "No other readers yet. Invite a friend below." : "No readers match \u{201C}\(searchText)\u{201D}.")
                                    .font(Theme.callout())
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                            }

                            ForEach(filteredReaders) { reader in
                                readerRow(reader)
                            }

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(Theme.caption())
                                    .foregroundStyle(Theme.danger.opacity(0.95))
                            }

                            inviteFooter
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Recommend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .sheet(isPresented: $showInviteContacts) {
            FindFriendsView(inviteBookTitle: book.title)
                .environmentObject(appState)
        }
        // An unsent note survives a deep-link tap.
        .composerDraftGuard(note)
        .task {
            directory.warm(uid: appState.authUserId, following: appState.currentUser?.following ?? [])
        }
    }

    private var bookHeader: some View {
        HStack(spacing: 12) {
            BookCoverView(book: book, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(Theme.headline())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(book.author)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Theme.surface.opacity(0.5))
    }

    private var noteField: some View {
        TextField("Add a note (optional)", text: $note, axis: .vertical)
            .font(Theme.body())
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1...3)
            .padding()
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Search readers", text: $searchText)
                .font(Theme.body())
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
        }
        .padding()
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }

    private func readerRow(_ reader: Reader) -> some View {
        HStack(spacing: 12) {
            avatar(user: reader.user)
            VStack(alignment: .leading, spacing: 2) {
                Text(reader.user.displayName)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textPrimary)
                Text("@\(reader.user.username)")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if sentTo.contains(reader.uid) {
                Text("SENT ✓")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            } else if sendingTo.contains(reader.uid) {
                ProgressView().tint(Theme.accent)
            } else {
                Button {
                    send(to: reader)
                } label: {
                    Text("SEND")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }

    private var inviteFooter: some View {
        VStack(spacing: 8) {
            Text("Friend not on SPINE yet?")
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
            Button {
                showInviteContacts = true
            } label: {
                Text("INVITE FROM CONTACTS")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                            .fill(Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                            .stroke(Theme.chrome.opacity(0.5), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12)
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

    private var readers: [Reader] {
        directory.readers.map { Reader(uid: $0.id, user: $0.user) }
    }

    private var isLoading: Bool { directory.isLoading }

    private var filteredReaders: [Reader] {
        guard !searchText.isEmpty else { return readers }
        return PersonSearch.ranked(readers, query: searchText, user: { $0.user })
    }

    private func send(to reader: Reader) {
        guard let fromUid = appState.authUserId else { return }
        errorMessage = nil
        sendingTo.insert(reader.uid)
        Task {
            do {
                try await RecommendationRepository().send(
                    fromUserId: fromUid,
                    toUserId: reader.uid,
                    book: book,
                    note: note
                )
                await MainActor.run {
                    sendingTo.remove(reader.uid)
                    sentTo.insert(reader.uid)
                    ToastCenter.shared.show(.recommendationSent(to: reader.user.displayName))
                }
            } catch {
                await MainActor.run {
                    sendingTo.remove(reader.uid)
                    errorMessage = "Couldn't send to \(reader.user.displayName). \(error.localizedDescription)"
                }
            }
        }
    }
}
