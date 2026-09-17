//
//  DiscoverSuggestionsService.swift
//  SPINE
//
//  Fetches a batch of book suggestions for Discover (Claude + Google Books). Used by AppState for prefetch.
//  When the user has set custom DiscoverCriteria (seed books, tiers, tags, free text), those replace the
//  default taste signal — the Discover criteria strip shows exactly what goes into the prompt.
//

import Foundation

enum DiscoverSuggestionsService {
    /// Titles Claude suggested earlier this session that turned out to be already read, queued,
    /// or dismissed. Dismissed books are stored as IDs only, so Claude can't be told about them
    /// up front — it keeps re-suggesting the same popular picks, they all get filtered out, and
    /// the batch comes back empty. Feeding the filtered titles back into later prompts breaks
    /// that loop.
    private static var sessionFilteredTitles: [String] = []
    private static let sessionFilteredLock = NSLock()

    private static func rememberFilteredTitles(_ titles: [String]) {
        sessionFilteredLock.lock()
        defer { sessionFilteredLock.unlock() }
        for t in titles where !sessionFilteredTitles.contains(t) {
            sessionFilteredTitles.append(t)
        }
        if sessionFilteredTitles.count > 60 {
            sessionFilteredTitles.removeFirst(sessionFilteredTitles.count - 60)
        }
    }

    private static func filteredTitlesSnapshot() -> [String] {
        sessionFilteredLock.lock()
        defer { sessionFilteredLock.unlock() }
        return sessionFilteredTitles
    }

    /// Fetches up to 5 suggested books, excluding the user's library and dismissed picks. Call from background; updates go to caller via callback/state.
    /// `readingInterestTags` are onboarding picks from `Tags.csv` (same universe as book tags); used only when `criteria.isDefault`.
    /// `unreadLibraryBooks` are queued + currently-reading entries, included in the prompt's avoid list so Claude doesn't waste picks on them.
    static func fetchBatch(readBooks: [UserBook], unreadLibraryBooks: [UserBook], dismissedBookIds: Set<String>, readingInterestTags: [String], criteria: DiscoverCriteria) async -> [Book] {
        let libraryEntries = readBooks + unreadLibraryBooks
        let excludedIds = Set(libraryEntries.map(\.bookId)).union(dismissedBookIds)
        // Google can resolve a suggested title to a different edition (different volume id)
        // than the one on the user's shelf, so an id check alone lets already-read books
        // through — also match at the work level (ISBN equivalence, normalized title+author).
        let libraryBooks = libraryEntries.compactMap(\.book)
        let isExcluded: (Book) -> Bool = { candidate in
            excludedIds.contains(candidate.id) || libraryBooks.contains { LibraryDedup.isSameWork($0, candidate) }
        }
        let excludedTitles = readBooks.compactMap { $0.book?.title }
        let queuedTitles = unreadLibraryBooks.compactMap { $0.book?.title }
        if ApiKeys.claude != nil {
            return await fetchBatchViaClaude(readBooks: readBooks, excludedTitles: excludedTitles, queuedTitles: queuedTitles, libraryBooks: libraryBooks, isExcluded: isExcluded, readingInterestTags: readingInterestTags, criteria: criteria)
        } else {
            return await fetchBatchViaGoogleOnly(readBooks: readBooks, isExcluded: isExcluded, readTitles: excludedTitles, readingInterestTags: readingInterestTags, criteria: criteria)
        }
    }

    private static func fetchBatchViaClaude(readBooks: [UserBook], excludedTitles: [String], queuedTitles: [String], libraryBooks: [Book], isExcluded: (Book) -> Bool, readingInterestTags: [String], criteria: DiscoverCriteria) async -> [Book] {
        // Read titles first so they are never the part that gets cut: with a large
        // imported library, dropping them is exactly what re-surfaces already-read books.
        var avoidTitles: [String] = []
        func addAvoid(_ title: String) {
            if !avoidTitles.contains(title) { avoidTitles.append(title) }
        }
        excludedTitles.prefix(150).forEach(addAvoid)
        queuedTitles.prefix(30).forEach(addAvoid)
        filteredTitlesSnapshot().forEach(addAvoid)

        let criteriaLine: String
        if criteria.isDefault {
            if readingInterestTags.isEmpty {
                criteriaLine = ""
            } else {
                let listed = readingInterestTags.prefix(16).joined(separator: ", ")
                criteriaLine = "The user’s reading interests (prioritize books that match these topics, genres, or vibes, use them as the main guide): \(listed). "
            }
        } else {
            criteriaLine = criteriaPromptSections(criteria: criteria, readBooks: readBooks).joined(separator: " ") + " "
        }

        let system = """
        You are a book recommendation assistant. Reply with exactly 5 book recommendations. Each line must be only the book title (and optionally ' by Author'). No numbering, no bullets, no extra text. One book per line. Do not suggest any book from the user's excluded list. When the user has stated criteria or reading interests, most or all of your picks should clearly fit them.
        """

        // Two attempts: if every pick in the first round maps to a book the user has already
        // read, queued, or dismissed, tell Claude which titles were rejected and ask again.
        for _ in 1...2 {
            let historyLine: String
            if avoidTitles.isEmpty {
                historyLine = "They have not finished logging any books in this app yet."
            } else {
                historyLine = "Do not suggest any of these titles (the user has already read, queued, or passed on them): \(avoidTitles.joined(separator: ", "))."
            }
            let userMessage = "\(criteriaLine)\(historyLine) Suggest 5 books they might enjoy next. Reply with exactly 5 lines, each line one book title (optionally 'Title by Author')."
            do {
                let response = try await ClaudeService.shared.sendMessage(system: system, userMessage: userMessage, tier: .simple)
                let lines = parseClaudeBookLines(response)
                var books: [Book] = []
                var filteredThisRound: [String] = []
                for line in lines.prefix(5) {
                    // Reject a suggestion the moment it names a shelved work — the suggested
                    // line is a cleaner signal than whatever edition Google resolves it to.
                    let (title, author) = parseSuggestionLine(line)
                    if libraryBooks.contains(where: { LibraryDedup.matches(title: title, author: author, book: $0) }) {
                        filteredThisRound.append(line)
                        continue
                    }
                    let query = line.replacingOccurrences(of: " by ", with: " ")
                    let results = (try? await GoogleBooksService.shared.search(query: String(query), searchAuthors: false)) ?? []
                    // Prefer the result that names the suggested work itself — the top
                    // hit can be a related listing (bundle, adaptation) of it instead.
                    guard let first = results.first(where: { LibraryDedup.matches(title: title, author: author, book: $0) }) ?? results.first else { continue }
                    if isExcluded(first) {
                        filteredThisRound.append(line)
                    } else {
                        books.append(first)
                    }
                }
                if !filteredThisRound.isEmpty {
                    rememberFilteredTitles(filteredThisRound)
                    avoidTitles += filteredThisRound
                }
                if !books.isEmpty { return books }
            } catch {
                break
            }
        }
        let q = googleFallbackQuery(readBooks: readBooks, readTitles: excludedTitles, readingInterestTags: readingInterestTags, criteria: criteria)
        let fallback = (try? await GoogleBooksService.shared.search(query: q, searchAuthors: false))?
            .filter { !isExcluded($0) } ?? []
        return Array(fallback.prefix(5))
    }

    /// Prompt fragments for each active criterion; empty criteria sections are skipped.
    private static func criteriaPromptSections(criteria: DiscoverCriteria, readBooks: [UserBook]) -> [String] {
        var sections: [String] = []

        if !criteria.seedBooks.isEmpty {
            let seeds = criteria.seedBooks.prefix(12).map { seed -> String in
                if let ub = readBooks.first(where: { $0.bookId == seed.bookId }), let r = ub.rating {
                    return "\(seed.title) by \(seed.author) (they rated it \(String(format: "%.1f", r))/10)"
                }
                return "\(seed.title) by \(seed.author)"
            }
            sections.append("Base your recommendations primarily on these specific books the user picked as references: \(seeds.joined(separator: "; ")).")
        }

        if !criteria.tiers.isEmpty {
            let tierBooks = readBooks
                .filter { ub in ub.tier.map(criteria.tiers.contains) == true }
                .compactMap { ub -> String? in
                    guard let b = ub.book, let tier = ub.tier else { return nil }
                    let rating = ub.rating.map { String(format: ", rated %.1f/10", $0) } ?? ""
                    return "\(b.title) by \(b.author) (\(tier) tier\(rating))"
                }
                .prefix(20)
            if !tierBooks.isEmpty {
                sections.append("The user wants recommendations informed by their \(criteria.tiers.joined(separator: " and "))-tier favorites: \(tierBooks.joined(separator: "; ")).")
            }
        }

        if !criteria.tags.isEmpty {
            sections.append("Focus on these genres/topics: \(criteria.tags.prefix(16).joined(separator: ", ")).")
        }

        if !criteria.trimmedFreeText.isEmpty {
            sections.append("The user gave this specific instruction, follow it closely: \"\(criteria.trimmedFreeText.prefix(300))\".")
        }

        return sections
    }

    private static func fetchBatchViaGoogleOnly(readBooks: [UserBook], isExcluded: (Book) -> Bool, readTitles: [String], readingInterestTags: [String], criteria: DiscoverCriteria) async -> [Book] {
        try? await Task.sleep(nanoseconds: 800_000_000)
        let query = googleFallbackQuery(readBooks: readBooks, readTitles: readTitles, readingInterestTags: readingInterestTags, criteria: criteria)
        let books = (try? await GoogleBooksService.shared.search(query: query, searchAuthors: false))?
            .filter { !isExcluded($0) } ?? []
        return Array(books.prefix(5))
    }

    /// Search string when Claude is unavailable or errors: prefer the user's criteria (tags, free text, seed/tier books), then interest tags, then recent reads, then generic.
    private static func googleFallbackQuery(readBooks: [UserBook], readTitles: [String], readingInterestTags: [String], criteria: DiscoverCriteria) -> String {
        if !criteria.tags.isEmpty {
            return criteria.tags.prefix(6).joined(separator: " ")
        }
        if !criteria.trimmedFreeText.isEmpty {
            return String(criteria.trimmedFreeText.prefix(120))
        }
        if !criteria.seedBooks.isEmpty {
            return criteria.seedBooks.prefix(2).map(\.title).joined(separator: " ")
        }
        if !criteria.tiers.isEmpty {
            let tierTitles = readBooks
                .filter { ub in ub.tier.map(criteria.tiers.contains) == true }
                .compactMap { $0.book?.title }
            if !tierTitles.isEmpty {
                return tierTitles.prefix(2).joined(separator: " ")
            }
        }
        if !readingInterestTags.isEmpty {
            return readingInterestTags.prefix(6).joined(separator: " ")
        }
        if !readTitles.isEmpty {
            return readTitles.prefix(2).joined(separator: " ")
        }
        return "popular books"
    }

    /// Splits a suggestion line into title and author on its last " by ", since
    /// titles themselves can contain " by " ("Death by Water by …").
    private static func parseSuggestionLine(_ line: String) -> (title: String, author: String?) {
        guard let r = line.range(of: " by ", options: [.backwards, .caseInsensitive]) else {
            return (line, nil)
        }
        return (String(line[..<r.lowerBound]), String(line[r.upperBound...]))
    }

    private static func parseClaudeBookLines(_ response: String) -> [String] {
        response
            .components(separatedBy: .newlines)
            .map { line in
                var t = line.trimmingCharacters(in: .whitespaces)
                if let match = t.range(of: #"^\d+[\.\)]\s*"#, options: .regularExpression) {
                    t = String(t[match.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                if t.hasPrefix("- ") || t.hasPrefix("* ") {
                    t = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                return t
            }
            .filter { !$0.isEmpty }
    }
}
