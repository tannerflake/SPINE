//
//  GoodreadsImportService.swift
//  SPINE
//
//  Matches Goodreads rows to catalog books and maps Goodreads fields to app values.
//
//  Matching order (confident-only — a row that can't be matched confidently is
//  reported unmatched, never guessed):
//    1. ISBN-13, then ISBN-10 — through the search hub's ISBNdb → Google chain,
//       verified against the returned volume's identifiers, with Open Library as
//       a final coverage fallback. The resolved book must also pass the
//       title/author confidence gate — catalog records for an ISBN sometimes
//       carry a translation's title, and a wrong guess is worse than no match.
//    2. Title + author search, accepted only when the normalized main title and
//       the author's last name both agree with the export row. This recovers the
//       large share of Goodreads rows with no ISBN (Kindle/audio editions) and
//       ISBNs Google hasn't indexed — the two failure modes that made the old
//       ISBN-only pass drop most of a library.
//

import Foundation

/// Result of trying to resolve one Goodreads row against the catalog.
/// `failed` (network/API error) is kept distinct from `noMatch` so a transient
/// outage is never recorded as a permanent "couldn't match" skip.
enum GoodreadsMatchOutcome {
    case matched(Book)
    /// Every lookup completed cleanly and nothing met the confidence bar.
    case noMatch
    /// A lookup errored (offline, rate limit, timeout) — retryable.
    case failed
}

final class GoodreadsImportService {
    private let googleBooks = GoogleBooksService.shared

    /// ISBNs already warmed this session, so re-entering a phase (or the bulk
    /// "import all") doesn't redo the cache check for rows prefetched earlier.
    private var prefetchedDigits = Set<String>()

    /// Warm the shared search cache for every row ISBN in one pass, so the
    /// per-row `matchRow` lookups that follow are cache hits instead of one
    /// paced API request each:
    ///   1. Batched Firestore check of which `isbn:` cache entries are already
    ///      fresh (30 keys per read — any ISBN any user has resolved recently).
    ///   2. One bulk ISBNdb `POST /books` request per 1,000 remaining ISBNs.
    ///   3. Write each hit through to the shared cache under the exact key
    ///      `matchRow`'s `search(query: "isbn:…")` will look up.
    /// Best-effort by design: any failure just leaves those rows to the
    /// unchanged per-row chain. Rows with no ISBN (Kindle/audio editions) are
    /// untouched — they always take the title+author path.
    func prefetchISBNs(for rows: [GoodreadsRow]) async {
        guard ISBNdbService.shared.isConfigured else { return }
        // Same preference order as matchRow: the row's ISBN-13, else ISBN-10.
        // (The 10 is only fetched here when it's the row's best ISBN; matchRow's
        // rare 13-failed-confidence → try-10 fallback stays a per-row lookup.)
        var digitsList: [String] = []
        for row in rows {
            guard let digits = [row.isbn13, row.isbn]
                .compactMap({ $0?.filter(\.isNumber) })
                .first(where: { $0.count == 10 || $0.count == 13 }),
                prefetchedDigits.insert(digits).inserted else { continue }
            digitsList.append(digits)
        }
        guard !digitsList.isEmpty else { return }
        // Must mirror GoogleBooksService.search's cacheKey for "isbn:" queries:
        // lowercased normalized query, no prefixes (author merge and language
        // restriction don't apply to ISBN lookups).
        func cacheKey(_ digits: String) -> String { "isbn:\(digits)" }
        let fresh = await BookSearchCacheService.shared.freshKeys(cacheKeys: digitsList.map(cacheKey))
        let missing = digitsList.filter { !fresh.contains(cacheKey($0)) }
        guard !missing.isEmpty,
              let resolved = try? await ISBNdbService.shared.lookupISBNs(missing) else { return }
        for (digits, book) in resolved {
            BookSearchCacheService.shared.store(cacheKey: cacheKey(digits), books: [book], source: .isbndb)
        }
    }

    /// Resolve one Goodreads row to a catalog book. Errors from the search API
    /// surface as `.failed`, never as `.noMatch`.
    func matchRow(_ row: GoodreadsRow) async -> GoodreadsMatchOutcome {
        var sawError = false
        var book: Book?
        for isbn in [row.isbn13, row.isbn].compactMap({ $0 }) where !isbn.isEmpty {
            do {
                // An ISBN is edition-exact, but the catalogs' records for one
                // aren't always titled like the edition the user shelved — Open
                // Library work records and mis-merged Google volumes can carry a
                // translation's title ("Más allá de las creencias" for an English
                // "Beyond Belief" row). Confident-only applies here too: the
                // resolved book must still look like the row, otherwise fall
                // through to the verified title+author search.
                if let b = try await lookupByISBN(isbn),
                   GoodreadsTitleMatcher.isConfidentMatch(rowTitle: row.title, rowAuthor: row.author, candidate: b) {
                    book = b
                    break
                }
            } catch {
                sawError = true
            }
        }
        if book == nil {
            do {
                book = try await lookupByTitleAuthor(row)
            } catch {
                sawError = true
            }
        }
        guard var merged = book else { return sawError ? .failed : .noMatch }
        // Goodreads ISBN (for Open Library covers); prefer export row over API when present.
        let fromRow = [row.isbn13, row.isbn]
            .compactMap { $0 }
            .map { $0.filter(\.isNumber) }
            .first { $0.count == 10 || $0.count == 13 }
        if let d = fromRow {
            merged.isbn = d
        }
        return .matched(merged)
    }

    /// Resolve an ISBN through the search hub (ISBNdb → Google, cached in the
    /// shared Firestore cache), then Open Library as a final coverage fallback
    /// for ISBNs neither paid source has indexed.
    private func lookupByISBN(_ isbn: String) async throws -> Book? {
        let digits = isbn.filter(\.isNumber)
        guard digits.count == 10 || digits.count == 13 else { return nil }
        let results = try await googleBooks.search(query: "isbn:\(digits)")
        for book in results {
            if let bid = book.isbn, ISBNMatcher.equivalent(digits, bid) {
                return book
            }
        }
        // Rare: API omits identifiers; if exactly one volume returned for the isbn: query, trust it.
        if results.count == 1, let only = results.first {
            return only
        }
        if results.isEmpty {
            do {
                return try await OpenLibraryService.shared.lookupISBN(digits)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Open Library unreachable — the chain already exhausted both paid sources.
                return nil
            }
        }
        return nil
    }

    /// Title + author search, verified strictly against the export row.
    private func lookupByTitleAuthor(_ row: GoodreadsRow) async throws -> Book? {
        let mainTitle = GoodreadsTitleMatcher.mainTitle(row.title)
        let primaryAuthor = GoodreadsTitleMatcher.primaryAuthor(row.author)
        guard !mainTitle.isEmpty else { return nil }

        var query = "intitle:\"\(mainTitle)\""
        if let lastName = GoodreadsTitleMatcher.authorLastName(primaryAuthor) {
            query += " inauthor:\"\(lastName)\""
        }
        // Restrict to the device language (English fallback): translations often
        // keep the identical title ("Dune", "Circe"), so they pass the title/author
        // confidence gate below and a well-populated Spanish/French edition can win.
        // A foreign-only result dropped by the filter becomes .noMatch — consistent
        // with the confident-only rule that a wrong guess is worse than no match.
        let language = Locale.current.language.languageCode?.identifier.lowercased() ?? "en"
        let results = try await googleBooks.search(query: query, languageRestriction: language, searchAuthors: false)
        let rowISBNs = [row.isbn13, row.isbn].compactMap { $0 }.map { $0.filter(\.isNumber) }

        var confident: [Book] = []
        for candidate in results {
            // An ISBN agreement is the strongest possible signal — accept immediately.
            if let cid = candidate.isbn, rowISBNs.contains(where: { ISBNMatcher.equivalent($0, cid) }) {
                return candidate
            }
            if GoodreadsTitleMatcher.isConfidentMatch(rowTitle: row.title, rowAuthor: row.author, candidate: candidate) {
                confident.append(candidate)
            }
        }
        // Prefer a verified candidate that has a cover and an ISBN (a real edition, not a stub).
        return confident.first { !$0.coverURL.isEmpty && $0.isbn != nil }
            ?? confident.first { !$0.coverURL.isEmpty }
            ?? confident.first
    }

    /// Map Goodreads exclusive shelf to ReadingStatus.
    static func status(for exclusiveShelf: String?) -> ReadingStatus {
        guard let s = exclusiveShelf?.lowercased() else { return .wantToRead }
        switch s {
        case "read": return .read
        case "currently-reading", "currently reading": return .currentlyReading
        case "to-read", "to read", "want to read": return .wantToRead
        default: return .wantToRead
        }
    }

    /// Goodreads 1–5 stars → SPINE out of 10 (whole numbers: 2, 4, … 10).
    static func ratingOutOfTen(from goodreadsRating: Int?) -> Double? {
        guard let r = goodreadsRating, (1...5).contains(r) else { return nil }
        return Theme.normalizeRatingOutOfTen(Double(max(1, min(10, r * 2))))
    }
}

// MARK: - Title / author verification

enum GoodreadsTitleMatcher {
    /// "Harry Potter and the Sorcerer's Stone (Harry Potter, #1)" → "Harry Potter and the Sorcerer's Stone";
    /// "The Hobbit: or There and Back Again" → "The Hobbit".
    static func mainTitle(_ raw: String) -> String {
        var t = raw
        if let idx = t.firstIndex(of: "(") { t = String(t[..<idx]) }
        if let idx = t.firstIndex(of: ":") { t = String(t[..<idx]) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Goodreads joins multiple authors with commas; the first entry is the primary author.
    static func primaryAuthor(_ raw: String) -> String {
        raw.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? raw
    }

    static func authorLastName(_ author: String) -> String? {
        let words = normalize(author).components(separatedBy: " ").filter { $0.count > 1 }
        return words.last
    }

    /// Lowercased, diacritics folded, punctuation removed, whitespace collapsed.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(scalars).components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// True when the candidate's normalized main title equals (or extends) the row's,
    /// and the row's primary-author last name appears in the candidate's authors.
    static func isConfidentMatch(rowTitle: String, rowAuthor: String, candidate: Book) -> Bool {
        let rowNorm = normalize(mainTitle(rowTitle))
        let candNorm = normalize(mainTitle(candidate.title))
        guard !rowNorm.isEmpty, !candNorm.isEmpty else { return false }
        let titlesAgree = rowNorm == candNorm
            || candNorm.hasPrefix(rowNorm + " ")
            || rowNorm.hasPrefix(candNorm + " ")
        guard titlesAgree else { return false }
        guard let lastName = authorLastName(primaryAuthor(rowAuthor)) else { return false }
        return normalize(candidate.author).components(separatedBy: " ").contains(lastName)
    }
}

// MARK: - Work-level duplicate detection

/// Duplicate detection that treats different *editions* of a book as the same
/// work. Volume-id equality alone misses most import duplicates: a Goodreads
/// export lists each shelved edition as its own row (its own Book Id), and each
/// row can resolve to a different Google Books volume — so the same book arrives
/// twice with two different `Book.id`s.
enum LibraryDedup {
    /// Stable content key: normalized main title + primary author's last name.
    /// `nil` when the title normalizes to nothing — never treat those as equal.
    static func workKey(title: String, author: String) -> String? {
        let t = GoodreadsTitleMatcher.normalize(GoodreadsTitleMatcher.mainTitle(title))
        guard !t.isEmpty else { return nil }
        let a = GoodreadsTitleMatcher.authorLastName(GoodreadsTitleMatcher.primaryAuthor(author)) ?? ""
        return t + "|" + a
    }

    static func workKey(for book: Book) -> String? {
        workKey(title: book.title, author: book.author)
    }

    /// Full-title variant of `workKey`: no subtitle stripping, so
    /// "Sapiens : a Graphic History" and "Sapiens A Graphic History" agree
    /// even though their colon placement gives them different main titles.
    static func fullTitleKey(for book: Book) -> String? {
        let t = GoodreadsTitleMatcher.normalize(book.title)
        guard !t.isEmpty else { return nil }
        let a = GoodreadsTitleMatcher.authorLastName(GoodreadsTitleMatcher.primaryAuthor(book.author)) ?? ""
        return t + "|" + a
    }

    /// Order-insensitive title words: articles and bare numbers dropped. Catches
    /// series editions whose title and series name swap positions — "The Final
    /// Empire (Mistborn, #1)" vs "Mistborn: The Final Empire" — which the
    /// positional keys above miss. Set *equality* (not subset) keeps sequels
    /// apart: {dune} ≠ {dune, messiah}.
    static func titleContentWords(_ title: String) -> Set<String> {
        let articles: Set<String> = ["the", "a", "an"]
        let words = GoodreadsTitleMatcher.normalize(title).components(separatedBy: " ")
        return Set(words.filter { !articles.contains($0) && Int($0) == nil })
    }

    private static func authorLastName(_ author: String) -> String? {
        GoodreadsTitleMatcher.authorLastName(GoodreadsTitleMatcher.primaryAuthor(author))
    }

    /// Same volume id, equivalent ISBNs, same work key, or same title words by the same author.
    static func isSameWork(_ a: Book, _ b: Book) -> Bool {
        if a.id == b.id { return true }
        if let ia = a.isbn, let ib = b.isbn, ISBNMatcher.equivalent(ia, ib) { return true }
        if let fa = fullTitleKey(for: a), let fb = fullTitleKey(for: b), fa == fb { return true }
        if let ka = workKey(for: a), let kb = workKey(for: b), ka == kb { return true }
        let wa = titleContentWords(a.title)
        if !wa.isEmpty, wa == titleContentWords(b.title),
           let la = authorLastName(a.author), let lb = authorLastName(b.author), la == lb {
            return true
        }
        return false
    }

    /// True when a plain "Title" (+ optional author) names the same work as `book`.
    /// Used by Discover to reject an LLM suggestion *before* it's resolved to an
    /// edition, since resolution can land on a volume whose metadata no longer
    /// matches the shelved copy. With no author, matches on title alone — for
    /// suggestion filtering a rare same-title false positive just skips one pick.
    static func matches(title: String, author: String?, book: Book) -> Bool {
        if let author, !author.isEmpty {
            if let k = workKey(title: title, author: author), k == workKey(for: book) { return true }
            let la = authorLastName(author)
            guard la == nil || la == authorLastName(book.author) else { return false }
        }
        let t = GoodreadsTitleMatcher.normalize(GoodreadsTitleMatcher.mainTitle(title))
        let bt = GoodreadsTitleMatcher.normalize(GoodreadsTitleMatcher.mainTitle(book.title))
        if !t.isEmpty, t == bt { return true }
        let w = titleContentWords(title)
        return !w.isEmpty && w == titleContentWords(book.title)
    }
}

// MARK: - ISBN comparison (10 vs 13)

enum ISBNMatcher {
    static func digitsOnly(_ s: String) -> String { s.filter(\.isNumber) }

    static func equivalent(_ a: String, _ b: String) -> Bool {
        let da = digitsOnly(a)
        let db = digitsOnly(b)
        if da == db { return true }
        if da.count == 10 && db.count == 13 { return isbn10MatchesIsbn13Body(da, db) }
        if da.count == 13 && db.count == 10 { return isbn10MatchesIsbn13Body(db, da) }
        return false
    }

    private static func isbn10MatchesIsbn13Body(_ isbn10: String, _ isbn13: String) -> Bool {
        guard isbn10.count == 10, isbn13.count == 13 else { return false }
        let p = String(isbn13.prefix(3))
        guard p == "978" || p == "979" else { return false }
        let nineFrom10 = String(isbn10.prefix(9))
        let nineFrom13 = String(isbn13.dropFirst(3).prefix(9))
        return nineFrom10 == nineFrom13
    }
}
