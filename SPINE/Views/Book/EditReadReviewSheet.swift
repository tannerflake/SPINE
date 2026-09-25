//
//  EditReadReviewSheet.swift
//  SPINE
//
//  Edit date finished, rating, thoughts, feed visibility, or delete the read entry.
//

import SwiftUI

/// Identifies an edit session. `feedCaption` pre-fills Thoughts when `userBook.reviewText` is empty (e.g. legacy feed-only text).
struct EditReadReviewSheetPayload: Identifiable {
    var id: UUID { userBook.id }
    let userBook: UserBook
    /// Feed post caption when opening from the feed; use `nil` from book profile.
    var feedCaption: String?

    init(userBook: UserBook, feedCaption: String? = nil) {
        self.userBook = userBook
        self.feedCaption = feedCaption
    }
}

struct EditReadReviewSheet: View {
    let userBook: UserBook
    /// Optional caption from the feed post when `userBook.reviewText` is empty.
    private let feedCaption: String?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var dateFinished: Date
    @State private var additionalReadDates: [Date]
    @State private var selectedTier: String?
    @State private var thoughts: String
    /// What Thoughts held before the user touched it (see `composerDraftGuard`):
    /// a deep-link tap leaves this sheet standing only if there are real edits.
    @State private var thoughtsBaseline: String
    @State private var postToFeed: Bool
    @State private var loadedFeedToggle: Bool = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @FocusState private var isThoughtsFocused: Bool
    /// Roster for @mention autocomplete in Thoughts.
    @ObservedObject private var mentionCatalog = MentionCatalog.shared

    init(userBook: UserBook, feedCaption: String? = nil) {
        self.userBook = userBook
        self.feedCaption = feedCaption
        _dateFinished = State(initialValue: userBook.dateFinished ?? Date())
        _additionalReadDates = State(initialValue: userBook.additionalReadDates ?? [])
        _selectedTier = State(initialValue: userBook.tier)
        let initialThoughts = Self.initialThoughts(userBook: userBook, feedCaption: feedCaption)
        _thoughts = State(initialValue: initialThoughts)
        _thoughtsBaseline = State(initialValue: initialThoughts)
        _postToFeed = State(initialValue: true)
    }

    private static func initialThoughts(userBook: UserBook, feedCaption: String?) -> String {
        let fromBook = userBook.reviewText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fromBook.isEmpty { return fromBook }
        let fromFeed = feedCaption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fromFeed
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                    if let b = userBook.book {
                        HStack(spacing: 12) {
                            BookCoverView(book: b, size: 56)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(b.title)
                                    .font(Theme.headline())
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(2)
                                Text(b.author)
                                    .font(Theme.callout())
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Text("Book")
                            .font(Theme.headline())
                            .foregroundStyle(Theme.textPrimary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Read dates")
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                        readDateRow($dateFinished, onDelete: additionalReadDates.isEmpty ? nil : { removePrimaryReadDate() })
                        ForEach(additionalReadDates.indices, id: \.self) { i in
                            readDateRow($additionalReadDates[i], onDelete: { additionalReadDates.remove(at: i) })
                        }
                        Button {
                            // Never seed a re-read with the long-ago sentinel: two
                            // "a long, long time ago" rows say nothing.
                            additionalReadDates.append(ReadDate.isLongAgo(dateFinished) ? Date() : dateFinished)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Add another read date")
                                    .font(Theme.caption())
                                    .fontWeight(.medium)
                            }
                            .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                        if !additionalReadDates.isEmpty {
                            Text("Re-reads count toward each year's reading goal.")
                                .font(Theme.caption())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }

                    InlineTierPicker(selection: $selectedTier)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Thoughts")
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                        ZStack(alignment: .topLeading) {
                            if thoughts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("Thoughts on this book…")
                                    .font(Theme.body())
                                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 10)
                            }
                            TextEditor(text: $thoughts)
                                .font(Theme.body())
                                .foregroundStyle(Theme.textPrimary)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 120, maxHeight: 280)
                                .focused($isThoughtsFocused)
                        }
                        .padding(12)
                        .background(Theme.background.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Theme.chrome.opacity(0.3), lineWidth: Theme.chromeHairline)
                        )

                        // Tag readers with "@" — suggestions appear one letter in.
                        if let query = MentionScanner.activeQuery(in: thoughts) {
                            let matches = mentionCatalog.suggestions(matching: query)
                            if !matches.isEmpty {
                                MentionSuggestionBar(suggestions: matches) { user in
                                    thoughts = MentionScanner.insertMention(
                                        handle: user.username.lowercased(),
                                        into: thoughts
                                    )
                                }
                            }
                        }
                    }
                    .id("editReviewThoughts")

                    Toggle(isOn: $postToFeed) {
                        Text("Show on feed")
                            .font(Theme.callout())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .tint(Theme.toggleOn)
                    .disabled(!loadedFeedToggle)
                    .opacity(loadedFeedToggle ? 1 : 0.6)

                    if let saveError {
                        Text(saveError)
                            .font(Theme.caption())
                            .foregroundStyle(Theme.danger)
                    }

                    Button("Save") {
                        Task { await save() }
                    }
                    .buttonStyle(.spinePrimary)
                    .disabled(isSaving || isDeleting)

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Text("Delete review")
                            .foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.spineTertiary)
                    .disabled(isSaving || isDeleting)
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
                /// Scroll once when the field is focused — not on every keystroke (`onChange(thoughts)` caused lag and ScrollView index errors).
                .onChange(of: isThoughtsFocused) { _, focused in
                    if focused {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("editReviewThoughts", anchor: .center)
                            }
                        }
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle("Edit review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .task {
            MentionCatalog.shared.ensureLoadedForCurrentUser()
            let has = await appState.hasFinishedBookPost(forBookId: userBook.bookId)
            await MainActor.run {
                postToFeed = has
                loadedFeedToggle = true
            }
            let trimmed = await MainActor.run { thoughts.trimmingCharacters(in: .whitespacesAndNewlines) }
            if trimmed.isEmpty, let caption = await appState.finishedBookPostCaption(forBookId: userBook.bookId) {
                await MainActor.run {
                    thoughts = caption
                    thoughtsBaseline = caption
                }
            }
        }
        // Unsaved edits survive a deep-link tap: the sheet stays, the link lands
        // once they save or cancel.
        .composerDraftGuard(thoughts, baseline: thoughtsBaseline)
        .confirmationDialog("Delete this review? This removes the book from your finished list and deletes your feed post if any.", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteReview() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// One read date. A long-ago read reads as prose, never as the 1900 sentinel:
    /// "Pick a date" swaps it back to a real calendar, the hourglass swaps it the
    /// other way.
    @ViewBuilder
    private func readDateRow(_ date: Binding<Date>, onDelete: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ReadDate.isLongAgo(date.wrappedValue) ? "hourglass" : "pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            if ReadDate.isLongAgo(date.wrappedValue) {
                Text("A long, long time ago")
                    .font(Theme.callout())
                    .foregroundStyle(Theme.textPrimary)
                Button {
                    date.wrappedValue = Date()
                } label: {
                    Text("Pick a date")
                        .font(Theme.caption())
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            } else {
                ReadDateChip(date: date, compact: true)
                Spacer(minLength: 0)
                Button {
                    date.wrappedValue = ReadDate.longAgo
                } label: {
                    Image(systemName: "hourglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("A long, long time ago")
            }
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// `dateFinished` stays the most recent read, so deleting it promotes the
    /// newest remaining re-read date into the primary slot.
    private func removePrimaryReadDate() {
        guard let newestIndex = additionalReadDates.indices.max(by: { additionalReadDates[$0] < additionalReadDates[$1] }) else { return }
        dateFinished = additionalReadDates.remove(at: newestIndex)
    }

    private func save() async {
        saveError = nil
        isSaving = true
        defer { isSaving = false }
        let err = await appState.updateReadReview(
            userBook: userBook,
            dateFinished: dateFinished,
            rating: userBook.rating,
            thoughts: thoughts,
            postToFeed: postToFeed,
            additionalReadDates: additionalReadDates
        )
        await MainActor.run {
            if let err {
                saveError = err
            } else {
                if selectedTier != userBook.tier {
                    appState.setTier(for: userBook.id, tier: selectedTier)
                }
                dismiss()
            }
        }
    }

    private func deleteReview() async {
        isDeleting = true
        defer { isDeleting = false }
        let err = await appState.deleteReadReview(userBook: userBook)
        await MainActor.run {
            if let err {
                saveError = err
            } else {
                dismiss()
            }
        }
    }
}
