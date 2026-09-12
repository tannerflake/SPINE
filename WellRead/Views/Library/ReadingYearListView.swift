//
//  ReadingYearListView.swift
//  WellRead
//
//  "List View": every read book grouped under each year it was read. On your
//  own library, multi-select moves books into a different year (including a
//  year you haven't logged anything in yet); on someone else's it's read-only
//  browsing. Books with no recorded read date collect in a "No year" section.
//

import SwiftUI

struct ReadingYearListView: View {
    @Environment(\.mainTabBarOverlapExtraHeight) private var mainTabBarOverlapExtraHeight
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appState: AppState

    /// The read shelf to group — your own library, or the profile owner's.
    let readBooks: [UserBook]
    /// Someone else's library: browsing only, no Select or year moves.
    var isEditable: Bool = true
    /// Non-nil when viewing another member's library — book profiles then show
    /// their review pinned in "Read by" instead of a top review card, matching
    /// UserLibraryDetailView.
    var sourceReaderUid: String? = nil

    @State private var isSelecting = false
    @State private var selection: Set<YearBookRef> = []
    @State private var showMoveSheet = false
    @State private var isSearching = false
    @State private var searchText = ""
    @FocusState private var searchFieldFocused: Bool
    /// Owned here rather than by the parent library page: a destination declared on
    /// the parent would push from the stack root, popping this list on the way back.
    @State private var selectedBook: Book?

    private static let topAnchorID = "readingYearListTop"

    /// One row = one (book, year) pair; a book re-read across years appears
    /// under each year and moves independently per year.
    struct YearBookRef: Hashable {
        let userBookId: UUID
        let year: Int?  // nil = the "No year" section
    }

    private struct YearSection: Identifiable {
        let year: Int?
        let books: [UserBook]
        var id: Int { year ?? Int.min }
    }

    /// Read books narrowed by the search field (title or author, case-insensitive).
    private var matchingReadBooks: [UserBook] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return readBooks }
        return readBooks.filter { ub in
            guard let book = ub.book else { return false }
            return book.title.localizedCaseInsensitiveContains(q)
                || book.author.localizedCaseInsensitiveContains(q)
        }
    }

    private var sections: [YearSection] {
        let cal = Calendar.current
        var byYear: [Int: [UserBook]] = [:]
        var dateless: [UserBook] = []
        for ub in matchingReadBooks {
            let years = Set(ub.allReadDates.map { cal.component(.year, from: $0) })
            if years.isEmpty {
                dateless.append(ub)
            }
            for y in years {
                byYear[y, default: []].append(ub)
            }
        }
        func latestDate(_ ub: UserBook, inYear year: Int) -> Date {
            ub.allReadDates.filter { cal.component(.year, from: $0) == year }.max() ?? .distantPast
        }
        var result: [YearSection] = byYear.keys.sorted(by: >).map { year in
            YearSection(
                year: year,
                books: byYear[year]!.sorted { latestDate($0, inYear: year) > latestDate($1, inYear: year) }
            )
        }
        if !dateless.isEmpty {
            result.append(YearSection(year: nil, books: dateless.sorted { $0.createdAt > $1.createdAt }))
        }
        return result
    }

    private var existingYears: [Int] {
        sections.compactMap(\.year)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                if isSearching {
                    searchField
                }
                if sections.isEmpty {
                    noMatchesState
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                                // Anchor for jumping back to the top when search opens.
                                Color.clear
                                    .frame(height: 0)
                                    .id(Self.topAnchorID)
                                ForEach(sections) { section in
                                    Section {
                                        sectionBody(section)
                                    } header: {
                                        sectionHeader(section)
                                    }
                                }
                            }
                            .padding(.horizontal, Theme.horizontalPadding)
                            .padding(.bottom, mainTabBarOverlapExtraHeight + 40)
                        }
                        // Opening search from deep in a long list would otherwise leave
                        // you looking at unrelated rows while the results sit above.
                        .onChange(of: isSearching) { _, nowSearching in
                            guard nowSearching else { return }
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(Self.topAnchorID, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        // The bar is a safe-area inset, not an overlay: it stacks on top of the tab
        // bar's own bottom inset, so it can never render behind the floating pill.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                moveActionBar
            }
        }
        .navigationTitle("List View")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbar {
            // Two independent toolbar items: sharing one HStack made them read as a
            // single smashed-together control, and the text button swallowed taps
            // meant for the glass.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSearching.toggle()
                        if !isSearching { searchText = "" }
                    }
                    searchFieldFocused = isSearching
                } label: {
                    Image(systemName: isSearching ? "xmark" : "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSearching ? "Close search" : "Search books")
            }

            if isEditable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSelecting.toggle()
                            if !isSelecting { selection.removeAll() }
                        }
                    } label: {
                        Text(isSelecting ? "Done" : "Select")
                            .font(Theme.callout().weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelecting ? "Done selecting" : "Select books")
                }
            }
        }
        .navigationDestination(item: $selectedBook) { book in
            BookProfileView(
                book: book,
                readBooksForSimilar: appState.readBooks,
                onNotInterested: nil,
                onWantToRead: { appState.addToWantToRead(book: book); selectedBook = nil },
                onStartReading: { appState.addToQueue(book: book, shelf: .readingNow); selectedBook = nil },
                onConfirmRead: { date, rating, post, caption, tier in
                    appState.addAsRead(book: book, dateFinished: date, rating: rating, postToFeed: post, caption: caption, tier: tier)
                    selectedBook = nil
                },
                isOnReadList: appState.isBookOnReadList(bookId: book.id),
                isInQueue: appState.isBookInQueue(bookId: book.id),
                onRemoveFromQueue: { appState.removeFromQueue(book: book); selectedBook = nil },
                onMarkAsDNF: { appState.markAsDNF(book: book); selectedBook = nil },
                // Their library: the owner's review shows pinned in "Read by"
                // rather than as a top card you could edit.
                readEntryForReview: sourceReaderUid == nil ? appState.userReadBook(forBookId: book.id) : nil,
                reviewSectionHeading: sourceReaderUid == nil ? "My review" : "Review",
                canEditReadReview: sourceReaderUid == nil,
                sourceReaderUid: sourceReaderUid
            )
            .environmentObject(authService)
            .environmentObject(appState)
        }
        .sheet(isPresented: $showMoveSheet) {
            MoveToYearSheet(
                existingYears: existingYears,
                yearCounts: Dictionary(uniqueKeysWithValues: sections.compactMap { s in
                    s.year.map { ($0, s.books.count) }
                }),
                onMove: { targetYear in
                    performMove(to: targetYear)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func performMove(to targetYear: Int) {
        for ref in selection {
            appState.moveReadYear(userBookId: ref.userBookId, fromYear: ref.year, toYear: targetYear)
        }
        showMoveSheet = false
        withAnimation(.easeInOut(duration: 0.2)) {
            selection.removeAll()
            isSelecting = false
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search title or author", text: $searchText)
                .font(Theme.callout())
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($searchFieldFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.bottom, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Text("No matches")
                .font(Theme.headline())
                .foregroundStyle(Theme.textPrimary)
            Text("No read books match \"\(searchText)\".")
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 48)
    }

    // MARK: - Sections

    /// Pinned while its section scrolls: the year and count stay visible so a long
    /// list never loses its sense of place. Opaque background so rows slide under it.
    private func sectionHeader(_ section: YearSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.year.map(ReadDate.yearLabel) ?? "No year")
                .font(Theme.title())
                .foregroundStyle(Theme.textPrimary)
            Text("\(section.books.count)")
                .font(Theme.caption())
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            if isSelecting {
                selectAllButton(for: section)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Theme.background)
    }

    @ViewBuilder
    private func sectionBody(_ section: YearSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if section.year == nil {
                Text(isEditable
                     ? "These books have no read date yet. Select them to file them under a year."
                     : "These books have no read date yet.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(section.books) { ub in
                if let book = ub.book {
                    bookRow(ub: ub, book: book, year: section.year)
                }
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 24)
    }

    /// Toggles the whole section: all selected → deselect all, otherwise select all.
    private func selectAllButton(for section: YearSection) -> some View {
        let refs = section.books.map { YearBookRef(userBookId: $0.id, year: section.year) }
        let allSelected = !refs.isEmpty && refs.allSatisfy { selection.contains($0) }
        return Button(allSelected ? "Deselect all" : "Select all") {
            if allSelected {
                for r in refs { selection.remove(r) }
            } else {
                selection.formUnion(refs)
            }
        }
        .font(Theme.caption().weight(.semibold))
        .foregroundStyle(Theme.textSecondary)
        .buttonStyle(.plain)
    }

    // MARK: - Rows

    /// The read date shown on a row: the most recent read within that row's year
    /// section, so re-reads show the date that put the book in this section.
    private func readDate(for ub: UserBook, inYear year: Int?) -> Date? {
        guard let year else { return nil }
        let cal = Calendar.current
        return ub.allReadDates.filter { cal.component(.year, from: $0) == year }.max()
    }

    private static let readDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private func bookRow(ub: UserBook, book: Book, year: Int?) -> some View {
        let ref = YearBookRef(userBookId: ub.id, year: year)
        let isSelected = selection.contains(ref)
        let dateText = readDate(for: ub, inYear: year).map { ReadDate.label($0, formatter: Self.readDateFormatter) }
        return Button {
            if isSelecting {
                if isSelected { selection.remove(ref) } else { selection.insert(ref) }
            } else {
                selectedBook = book
            }
        } label: {
            HStack(spacing: 12) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary.opacity(0.6))
                }
                BookCoverView(book: book, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(Theme.callout().weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(book.author)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let dateText {
                    // Its own trailing column, so the title and author can never run
                    // under the date or the corner tier tag. The Spacer pins the date
                    // to the bottom of the row; `fixedSize` must come before the
                    // stretching frame or it clamps the height back and re-centers it.
                    VStack(spacing: 0) {
                        Spacer(minLength: 12)
                        Text(dateText)
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize()
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .padding(10)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            .overlay(alignment: .topTrailing) {
                if let tier = ub.normalizedTier {
                    cornerTierTag(tier)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .strokeBorder(
                        isSelected ? Theme.accent.opacity(0.9) : Theme.chrome.opacity(0.25),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelecting ? "\(book.title), \(isSelected ? "selected" : "not selected")" : book.title)
    }

    /// Tier tag baked flush into the card's top-right corner: its outer corner
    /// matches the card radius, with a soft inner corner where it meets the card.
    private func cornerTierTag(_ tier: String) -> some View {
        Text("\(tier) TIER")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(Color.black.opacity(0.78))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(spineTierColor(for: tier))
            .clipShape(UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 0,
                bottomLeading: 10,
                bottomTrailing: 0,
                topTrailing: Theme.cardCornerRadius
            )))
    }

    // MARK: - Move action bar

    private var moveActionBar: some View {
        HStack(spacing: 12) {
            Text(selection.count == 1 ? "1 book" : "\(selection.count) books")
                .font(Theme.callout())
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
            Spacer(minLength: 0)
            Button {
                showMoveSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Move to year")
                        .font(Theme.callout().weight(.semibold))
                }
                .foregroundStyle(Theme.onChrome)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Theme.accentGloss)
                .clipShape(Capsule())
                .opacity(selection.isEmpty ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .strokeBorder(Theme.chrome.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Theme.shadowInk.opacity(0.2), radius: 10, y: 4)
        .padding(.horizontal, Theme.horizontalPadding)
        // Pushed destinations don't inherit the tab bar's safeAreaInset (that's what
        // mainTabBarOverlapExtraHeight exists for), so lift the bar clear of the pill
        // the same way BookProfileView's action bar does.
        .padding(.bottom, mainTabBarOverlapExtraHeight + 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Target year picker

/// Pick where the selected books go: tap a year you've already read in, or dial
/// in any other year. Any year is valid, which covers "add a year" for free.
/// Shared with the tier list's multi-select date action.
struct MoveToYearSheet: View {
    let existingYears: [Int]
    let yearCounts: [Int: Int]
    let onMove: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var customYear: Int = Calendar.current.component(.year, from: Date())

    private var customYearRange: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((1900...current).reversed())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !existingYears.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(SpinesGlyphs.caps("Your years"))
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(Theme.chrome)
                            VStack(spacing: 8) {
                                ForEach(existingYears, id: \.self) { year in
                                    existingYearRow(year)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(SpinesGlyphs.caps("A different year"))
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(Theme.chrome)
                        HStack(spacing: 12) {
                            Picker("Year", selection: $customYear) {
                                ForEach(customYearRange, id: \.self) { year in
                                    Text(ReadDate.yearLabel(year)).tag(year)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(height: 110)
                            .clipped()
                            Button {
                                onMove(customYear)
                            } label: {
                                Text("Move here")
                                    .font(Theme.callout().weight(.semibold))
                                    .foregroundStyle(Theme.onChrome)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(Theme.accentGloss)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Move to year")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func existingYearRow(_ year: Int) -> some View {
        Button {
            onMove(year)
        } label: {
            HStack {
                Text(ReadDate.yearLabel(year))
                    .font(Theme.headline())
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                if let count = yearCounts[year] {
                    Text(count == 1 ? "1 book" : "\(count) books")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textTertiary)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .strokeBorder(Theme.chrome.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
