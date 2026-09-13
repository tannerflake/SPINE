//
//  ClubBookPickerSheet.swift
//  SPINE
//
//  Admin picks the club's next book: search the catalog (or grab one off your
//  own queue), then set the meeting date it's due for.
//

import SwiftUI

struct ClubBookPickerSheet: View {
    let club: BookClub
    let onPick: (Book, Date?) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    @State private var query = ""
    @State private var results: [Book] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var chosen: Book?
    @State private var meetingAt: Date = ClubMeetingSheet.defaultMeeting()
    @State private var hasMeeting = true
    @FocusState private var searchFocused: Bool

    private var queueBooks: [Book] {
        appState.userBooks
            .filter { $0.status == .wantToRead && $0.bookId != club.currentPick?.bookId }
            .compactMap(\.book)
            .prefix(12)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if let chosen {
                    confirmStep(chosen)
                } else {
                    searchStep
                }
            }
            .navigationTitle(chosen == nil ? "Next book" : "Set the meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if chosen != nil {
                        Button {
                            withAnimation(.snappy) { chosen = nil }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    } else {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Step 1: find the book

    private var searchStep: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search title or author", text: $query)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { runSearch(immediate: true) }
                    .onChange(of: query) { _, _ in runSearch(immediate: false) }
                if searching {
                    ProgressView().tint(Theme.accent).scaleEffect(0.8)
                } else if !query.isEmpty {
                    Button { query = ""; results = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.chrome.opacity(0.2), lineWidth: 1))
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        if !queueBooks.isEmpty {
                            ClubFieldLabel(text: "From your queue")
                                .padding(.top, 14)
                            ForEach(queueBooks) { book in
                                BookSearchRow(book: book) { choose(book) }
                            }
                        } else {
                            Text("Search for the book the club is reading next.")
                                .font(Theme.callout())
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.top, 24)
                        }
                    } else if results.isEmpty && !searching {
                        Text("No results for \u{201C}\(query)\u{201D}. Try the author's name.")
                            .font(Theme.callout())
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 24)
                    } else {
                        ForEach(results) { book in
                            BookSearchRow(book: book) { choose(book) }
                        }
                    }
                }
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { searchFocused = true }
        }
    }

    private func runSearch(immediate: Bool) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            results = []
            searching = false
            return
        }
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
            }
            searching = true
            defer { searching = false }
            do {
                let books = try await GoogleBooksService.shared.search(query: trimmed)
                if Task.isCancelled { return }
                results = books
            } catch {
                if Task.isCancelled { return }
                results = []
            }
        }
    }

    private func choose(_ book: Book) {
        searchFocused = false
        withAnimation(.snappy) { chosen = book }
    }

    // MARK: - Step 2: meeting date

    private func confirmStep(_ book: Book) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    BookCoverView(book: book, size: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(3)
                        Text(book.author)
                            .font(Theme.callout())
                            .foregroundStyle(Theme.textSecondary)
                        if let pages = book.pageCount, pages > 0 {
                            Text("\(pages) pages")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .wellReadCard()

                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $hasMeeting.animation(.snappy)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Set a meeting date")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Everyone reads toward it and gets a reminder the day before.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .tint(Theme.toggleOn)
                    if hasMeeting {
                        DatePicker("Meeting", selection: $meetingAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical)
                            .tint(Theme.accent)
                    }
                }
                .padding(16)
                .wellReadCard()

                ClubPrimaryButton(title: club.currentPick == nil ? "Set as the club's book" : "Set as next book", icon: "checkmark") {
                    onPick(book, hasMeeting ? meetingAt : nil)
                    dismiss()
                }
                if club.currentPick != nil {
                    Text("The current book moves to Past reads.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }
}
