//
//  OnboardingCurrentlyReadingView.swift
//  SPINE
//
//  Onboarding step (after profile completion, before the Goodreads welcome):
//  “What are you reading right now?” One tap on a search result puts the book
//  on the Reading Now shelf. Skippable with “Nothing right now.”
//

import SwiftUI

enum OnboardingCurrentlyReadingPromptStorage {
    private static let keyPrefix = "onboardingCurrentlyReadingPromptShown_"

    static func hasShown(for uid: String) -> Bool {
        UserDefaults.standard.bool(forKey: keyPrefix + uid)
    }

    static func markShown(for uid: String) {
        UserDefaults.standard.set(true, forKey: keyPrefix + uid)
    }
}

struct OnboardingCurrentlyReadingView: View {
    @EnvironmentObject var appState: AppState

    /// Called after a book is added or the user opts out — the parent closes the sheet.
    let onDone: () -> Void

    @FocusState private var isSearchFocused: Bool
    @State private var query = ""
    @State private var results: [Book] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var didAddBook = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What are you reading right now?")
                        .font(Theme.largeTitle())
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Find your current book and we'll put it on your Reading Now shelf.")
                        .font(Theme.body())
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal)
                .padding(.top, 28)

                searchField
                    .padding(.horizontal)

                if isSearching {
                    HStack {
                        ProgressView().tint(Theme.accent)
                        Text("Searching…").font(Theme.callout()).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }

                if let err = searchError {
                    VStack(spacing: 12) {
                        Text(err)
                            .font(Theme.callout())
                            .foregroundStyle(Theme.danger)
                            .multilineTextAlignment(.center)
                        Button("Try Again") { runSearch() }
                            .font(Theme.callout())
                            .foregroundStyle(Theme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else if hasSearched && !isSearching && results.isEmpty {
                    Text("No results. Try different keywords.")
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                }

                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(results) { book in
                            resultRow(book)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.immediately)

                Button(action: onDone) {
                    Text("Nothing right now")
                        .font(Theme.headline())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
        }
        .onAppear { isSearchFocused = true }
        .onDisappear { searchTask?.cancel() }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Search by title or author", text: $query)
                .font(Theme.body())
                .foregroundStyle(Theme.textPrimary)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($isSearchFocused)
                .submitLabel(.search)
                .onSubmit { runSearch() }
                .onChange(of: query) { _, newValue in
                    scheduleSearch(for: newValue)
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding()
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }

    /// One tap adds the book straight onto Reading Now and finishes the step.
    private func resultRow(_ book: Book) -> some View {
        Button {
            // One-shot: a second tap before the sheet closes must not add again.
            guard !didAddBook else { return }
            didAddBook = true
            appState.addToQueue(book: book, shelf: .readingNow)
            onDone()
        } label: {
            HStack(spacing: 14) {
                BookCoverView(book: book, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(Theme.headline())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text(book.author)
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .spineCard()
        }
        .buttonStyle(.plain)
    }

    /// Debounces keystrokes so results populate as the user types (mirrors SearchView).
    private func scheduleSearch(for value: String) {
        searchTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            hasSearched = false
            searchError = nil
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(trimmed)
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask = Task { await performSearch(trimmed) }
    }

    private func performSearch(_ trimmed: String) async {
        let libraryAuthors = Set(appState.userBooks.compactMap { $0.book?.author })
        await MainActor.run {
            isSearching = true
            searchError = nil
        }
        do {
            let books = try await GoogleBooksService.shared.search(
                query: trimmed,
                includeAllEditions: false,
                libraryAuthors: libraryAuthors
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                results = books
                hasSearched = true
                isSearching = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                hasSearched = true
                isSearching = false
                searchError = error.localizedDescription.isEmpty ? "Search failed. Check your connection and try again." : error.localizedDescription
            }
        }
    }
}
