//
//  DiscoverCriteriaEditorSheet.swift
//  Spine
//
//  Edit the criteria driving Discover suggestions: seed books (picked from the
//  library), tags, and a free-text instruction. Saving applies once: one
//  Firestore write, one queue flush + refetch.
//

import SwiftUI

struct DiscoverCriteriaEditorSheet: View {
    private static let freeTextLimit = 300

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var draft: DiscoverCriteria
    @State private var selectedTags: Set<String>
    @FocusState private var isFreeTextFocused: Bool

    init(initial: DiscoverCriteria) {
        _draft = State(initialValue: initial)
        _selectedTags = State(initialValue: Set(initial.tags))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("What are you in the mood for?")
                        .font(Theme.title())
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.top, 4)

                    freeTextSection
                    seedBooksSection
                    tagsSection

                    if !isDraftDefault {
                        Button {
                            draft = .default
                            selectedTags = []
                        } label: {
                            VStack(spacing: 4) {
                                Text("Reset to default")
                                    .font(Theme.headline())
                                    .foregroundStyle(Theme.danger)
                                Text("Back to recommendations from your whole library and interests.")
                                    .font(Theme.caption())
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private var isDraftDefault: Bool {
        var d = draft
        d.tags = Array(selectedTags)
        return d.isDefault
    }

    private func save() {
        var final = draft
        // Keep catalog order + canonical strings; whitelist also dedupes.
        final.tags = SpineTagCatalog.shared.whitelist(
            SpineTagCatalog.shared.allTags.filter { selectedTags.contains($0) }
        )
        final.freeText = String(final.trimmedFreeText.prefix(Self.freeTextLimit))
        appState.setDiscoverCriteria(final)
        dismiss()
    }

    // MARK: - Books

    private var seedBooksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.readBooks.isEmpty {
                Text("Finish and rank some books first to use them as seeds.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
            } else if draft.seedBooks.isEmpty {
                NavigationLink {
                    DiscoverBookPickerView(readBooks: appState.readBooks, selectedSeeds: $draft.seedBooks)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Choose books from your library")
                            .font(Theme.callout())
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Theme.accent.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Theme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    )
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(draft.seedBooks, id: \.bookId) { seed in
                            seedTile(seed)
                        }
                        addSeedTile
                    }
                }
            }
        }
        .hingeSectionCard(title: "Give me a book like...")
    }

    /// Cover-shaped dashed "add" tile shown after the chosen seeds.
    private var addSeedTile: some View {
        NavigationLink {
            DiscoverBookPickerView(readBooks: appState.readBooks, selectedSeeds: $draft.seedBooks)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.accent.opacity(0.06))
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 56, height: 84)
                Text("Add")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 68)
        }
        .buttonStyle(.plain)
    }

    private func seedTile(_ seed: DiscoverSeedBook) -> some View {
        VStack(spacing: 6) {
            if let book = appState.readBooks.first(where: { $0.bookId == seed.bookId })?.book {
                BookCoverView(book: book, size: 56)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.surface)
                    .frame(width: 56, height: 84)
                    .overlay(
                        Text(seed.title)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(4)
                    )
            }
            Button {
                draft.seedBooks.removeAll { $0.bookId == seed.bookId }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 68)
    }

    // MARK: - Tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Focus suggestions on topics, genres, or vibes.")
                .font(Theme.callout())
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 18) {
                TagCatalogPicker(selected: $selectedTags, filterByFormat: true, separated: true)
            }
        }
        .hingeSectionCard(title: "Tags & genres")
    }

    // MARK: - Free text

    private var freeTextSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if draft.freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("ex. \u{201C}give me a dystopian novel, but not one written for tweens\u{201D}")
                        .font(Theme.body())
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 10)
                }
                TextEditor(text: $draft.freeText)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80, maxHeight: 160)
                    .focused($isFreeTextFocused)
                    .onChange(of: draft.freeText) { _, newValue in
                        if newValue.count > Self.freeTextLimit {
                            draft.freeText = String(newValue.prefix(Self.freeTextLimit))
                        }
                    }
            }
            .padding(12)
            .background(Theme.background.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.textTertiary.opacity(0.3), lineWidth: 1)
            )
        }
        .hingeSectionCard(title: "Describe it")
    }
}
