//
//  WizardBookSteps.swift
//  SPINE
//
//  Book steps of the onboarding wizard: pick a currently-reading book
//  (WizardReadingStep) and the optional Goodreads import handoff
//  (WizardGoodreadsStep, the final step). Search mirrors the debounce +
//  GoogleBooksService pattern from OnboardingCurrentlyReadingView.
//  Copy rule: no em-dashes in user-facing text.
//

import SwiftUI

// MARK: - Reading step

struct WizardReadingStep: View {
    @ObservedObject var model: OnboardingWizardModel
    @EnvironmentObject var appState: AppState

    @FocusState private var isSearchFocused: Bool
    @State private var query = ""
    @State private var results: [Book] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TypewriterText(
                text: "What are you reading right now?",
                font: .system(size: 28, weight: .bold),
                centered: false
            )

            searchField
                .padding(.top, 18)
                .wizardReveal(delay: 0.2)

            resultsList
                .padding(.top, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 10) {
                WizardCTAButton(title: "Shelve it", enabled: model.pickedBook != nil) {
                    model.shelvePickedBook()
                    model.advance()
                }
                WizardGhostButton(title: "Between books at the moment") {
                    model.pickedBook = nil
                    model.markCurrentlyReadingShown()
                    model.advance()
                }
            }
            .wizardReveal(delay: 0.3)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isSearchFocused = true
            }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search by title or author", text: $query)
                .font(.system(size: 16))
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
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding()
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        // The bare TextField only claims its own text line; tapping the box
        // around it has to focus it too, or the field reads as unresponsive.
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .onTapGesture { isSearchFocused = true }
    }

    @ViewBuilder
    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if isSearching {
                    HStack(spacing: 10) {
                        ProgressView().tint(Theme.textSecondary)
                        Text("Searching…")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                }
                if let searchError, !isSearching {
                    Text(searchError)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                }
                if hasSearched, !isSearching, results.isEmpty, searchError == nil {
                    Text("No results. Try different keywords.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                }
                ForEach(results) { book in
                    resultRow(book)
                }
            }
            .padding(.bottom, 12)
        }
        // Interactive, not immediate: the keyboard tracks the drag, so the
        // bottom CTA stack rides down with it instead of snapping when the
        // safe area collapses all at once.
        .scrollDismissesKeyboard(.interactively)
        // Interactive dismissal only engages once the drag reaches the
        // keyboard itself; a downward drag anywhere in the list should
        // start collapsing it right away. Animated so the CTA stack eases
        // down with the safe-area change instead of snapping.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard isSearchFocused, value.translation.height > 12 else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        isSearchFocused = false
                    }
                }
        )
    }

    private func resultRow(_ book: Book) -> some View {
        let isSelected = model.pickedBook == book
        return Button {
            model.pickedBook = isSelected ? nil : book
        } label: {
            HStack(spacing: 12) {
                BookCoverView(book: book, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(book.author)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Theme.surfaceElevated : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Theme.textPrimary : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Search (mirrors OnboardingCurrentlyReadingView)

    /// Debounces keystrokes so results populate as the user types.
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

// MARK: - Goodreads step (the last step)

struct WizardGoodreadsStep: View {
    @ObservedObject var model: OnboardingWizardModel
    @EnvironmentObject var appState: AppState

    @State private var showImport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TypewriterText(
                text: "Bring over your reading past.",
                font: .system(size: 28, weight: .bold),
                centered: false
            )

            Text("It's easy and only takes a couple of minutes.")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 10)
                .wizardReveal(delay: 0.2)

            Text("Trust me, you'll be glad you did it.")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 16)
                .wizardReveal(delay: 0.3)

            Spacer()

            HStack {
                Spacer()
                Image("goodreads-logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 132, height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 29, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 29, style: .continuous)
                            .stroke(Theme.textPrimary.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: Theme.shadowInk.opacity(0.18), radius: 14, x: 0, y: 8)
                Spacer()
            }
            .wizardReveal(delay: 0.3)

            Spacer()

            VStack(spacing: 10) {
                WizardCTAButton(title: "Import from Goodreads") {
                    // -uiPreviewOnboardingWizard runs may sit on a leftover
                    // simulator session; the real import would write to it.
                    if model.previewMode {
                        model.finish()
                    } else {
                        showImport = true
                    }
                }
                WizardGhostButton(title: "Later") {
                    model.finish()
                }
            }
            .wizardReveal(delay: 0.3)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .sheet(isPresented: $showImport, onDismiss: { model.finish() }) {
            GoodreadsImportView(initialRows: nil)
                .environmentObject(appState)
        }
    }
}
