//
//  GoogleBooksService.swift
//  SPINE
//
//  The app's book-search hub. Despite the name, `search` runs the full lookup
//  chain: shared Firestore cache → ISBNdb (paid, primary) → Google Books
//  (keyed, then keyless long shot) → Open Library. Every book search in the
//  app goes through here.
//

import Foundation

struct GoogleBooksResponse: Codable {
    let items: [GoogleBooksItem]?
    let error: GoogleBooksError?
}

struct GoogleBooksError: Codable {
    let code: Int?
    let message: String?
}

struct GoogleBooksItem: Codable {
    let id: String
    let volumeInfo: VolumeInfo?
}

struct IndustryIdentifier: Codable {
    let type: String?
    let identifier: String?
}

struct VolumeInfo: Codable {
    let title: String?
    let authors: [String]?
    let imageLinks: ImageLinks?
    let pageCount: Int?
    let publishedDate: String?
    let description: String?
    let categories: [String]?
    let industryIdentifiers: [IndustryIdentifier]?
    let averageRating: Double?
    let ratingsCount: Int?
    let language: String?
}

struct ImageLinks: Codable {
    let thumbnail: String?
    let smallThumbnail: String?
    let small: String?
    let medium: String?
    let large: String?
    let extraLarge: String?
}

/// Parses Google Books publishedDate (e.g. "2023", "2023-05", "2023-05-01") to Date.
private func parsePublishedDate(_ raw: String?) -> Date? {
    guard let raw = raw, !raw.isEmpty else { return nil }
    let utc = TimeZone(identifier: "UTC")!
    let formatters: [DateFormatter] = [
        { let f = DateFormatter(); f.dateFormat = "yyyy"; f.timeZone = utc; return f }(),
        { let f = DateFormatter(); f.dateFormat = "yyyy-MM"; f.timeZone = utc; return f }(),
        { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = utc; return f }()
    ]
    for formatter in formatters {
        if let d = formatter.date(from: raw) { return d }
    }
    return nil
}

final class GoogleBooksService {
    static let shared = GoogleBooksService()
    private let baseURL = "https://www.googleapis.com/books/v1/volumes"
    private let session: URLSession
    /// Per-process memo of ranked results by cache key. Sixty queries × 30 books
    /// is a few hundred KB; it makes every re-search this session instant.
    private let cacheMaxQueries = 60
    /// How long the ISBNdb tier waits for Open Library's popularity counts once
    /// its own results are in hand. OL answers in about a second when healthy
    /// but routinely takes 3–15s under load (measured 2026-09-12), and it was
    /// awaited unconditionally — the single biggest cost of an uncached search.
    /// Past the grace, results rank without the counts and the counts finish
    /// the ranking in the caches afterwards (`finishRankingLater`).
    private static let popularitySignalGrace: UInt64 = 700_000_000
    /// Curated searches serve at most this many ranked results — matches what
    /// BookSearchCacheService stores per entry.
    private static let rankedResultCap = 30
    private var searchCache: [String: [Book]] = [:]
    private let cacheQueue = DispatchQueue(label: "com.spine.googlebooks.cache")

    /// Set when Google's shared anonymous (keyless) pool reports its *daily* quota
    /// exhausted — that won't recover for hours, so skip straight to keyed requests
    /// for a while instead of paying a doomed round trip on every search.
    private var keylessQuotaExhaustedUntil: Date?

    private var shouldSkipKeyless: Bool {
        cacheQueue.sync {
            guard let until = keylessQuotaExhaustedUntil else { return false }
            return until > Date()
        }
    }

    private func markKeylessQuotaExhausted() {
        cacheQueue.sync {
            keylessQuotaExhaustedUntil = Date().addingTimeInterval(30 * 60)
        }
    }

    /// Primary API key (project quota, 1,000/day shared across all users). Keyless
    /// requests draw from Google's single *global* anonymous pool, which has been
    /// permanently exhausted since ~2025 (429 on first request), so keyless is only
    /// attempted as a long-shot fallback when the keyed quota is also dry.
    /// Sources: Secrets.plist / Info.plist "GOOGLE_BOOKS_API_KEY", or
    /// GoogleService-Info.plist "API_KEY".
    private var apiKey: String? {
        if let key = keyFromPlist(named: "Secrets", key: "GOOGLE_BOOKS_API_KEY"), !key.isEmpty { return key }
        if let key = keyFromPlist(named: "Info", key: "GOOGLE_BOOKS_API_KEY"), !key.isEmpty { return key }
        if let key = keyFromPlist(named: "GoogleService-Info", key: "API_KEY"), !key.isEmpty { return key }
        return nil
    }

    private func keyFromPlist(named name: String, key: String) -> String? {
        guard let path = Bundle.main.path(forResource: name, ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: path),
              let value = plist[key] as? String else { return nil }
        return value
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config)
    }

    /// A better answer than the literal query got, found after the fact.
    struct CompletedSearch {
        let books: [Book]
        /// The completed query these results came from — "lord of the rings"
        /// for a typed "lord of the rin".
        let query: String
    }

    /// The half-typed-last-word repair, run *after* the literal results are
    /// already on screen. Every catalog API matches whole words, so "lord of
    /// the rin" can only ever return literal-"rin" listings; ranking can't
    /// rescue a result set the book isn't in. `SearchQueryCompletion` finishes
    /// the word (an Open Library wildcard probe), and this re-runs the chain
    /// against the finished query.
    ///
    /// Deliberately a second call rather than part of `search`: the probe can
    /// take a couple of seconds, and nobody should watch a spinner for it. The
    /// caller shows the literal results immediately and swaps them for these if
    /// and when they arrive. Returns nil — cheaply, in the common case — when
    /// the query was already whole or nothing better was found.
    func completedSearch(
        for query: String,
        literalResults: [Book],
        includeAllEditions: Bool = false,
        libraryAuthors: Set<String> = [],
        languageRestriction: String? = nil,
        searchAuthors: Bool = true
    ) async throws -> CompletedSearch? {
        let normalized = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.hasPrefix("isbn:") else { return nil }
        // When a top result's own title or author already is the query, it was
        // whole; skip the probe entirely rather than confirming the obvious.
        guard !BookSearchRanker.anyResultMatchesQuery(literalResults, query: query) else { return nil }
        guard let completed = await SearchQueryCompletion.completedQuery(for: query),
              BookSearchRanker.normalize(completed) != BookSearchRanker.normalize(query),
              // The literal results may already hold the work the completion
              // names, in which case finishing the word would only churn them.
              !BookSearchRanker.anyResultMatchesQuery(literalResults, query: completed) else { return nil }
        try Task.checkCancellation()
        let books = try await search(
            query: completed,
            includeAllEditions: includeAllEditions,
            libraryAuthors: libraryAuthors,
            languageRestriction: languageRestriction,
            searchAuthors: searchAuthors
        )
        // A completion that finds nothing is worse than the literal results.
        guard !books.isEmpty else { return nil }
        return CompletedSearch(books: books, query: completed)
    }

    /// Searches Google Books, then re-ranks and de-duplicates results client-side
    /// (see `BookSearchRanker`). `includeAllEditions` skips the junk-title filter
    /// and edition dedup for the "can't find it?" fallback. `libraryAuthors` are
    /// author names already in the user's library, used as a personalization boost.
    /// Strict `isbn:` queries bypass ranking entirely and keep Google's order.
    /// `languageRestriction` (ISO 639-1, e.g. "en") hard-filters results to that
    /// language via Google's `langRestrict` — used by the Goodreads import, where a
    /// same-title foreign edition is worse than no match. Interactive search leaves
    /// it nil (the ranker's soft device-language preference applies instead).
    /// `searchAuthors` adds a second ISBNdb request against the /author endpoint so
    /// a query naming an author surfaces their books (the default `/books/{query}`
    /// only matches titles; Google and Open Library already match authors). Bulk
    /// title lookups (Goodreads import, Discover, Blend) pass false — they know
    /// the title and shouldn't spend a second paced ISBNdb request per book.
    ///
    /// Searches the query exactly as given. Interactive search calls
    /// `searchDetailed` instead, which also finishes a half-typed last word.
    func search(query: String, includeAllEditions: Bool = false, libraryAuthors: Set<String> = [], languageRestriction: String? = nil, searchAuthors: Bool = true) async throws -> [Book] {
        let normalized = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.isEmpty else { return [] }
        let isISBNQuery = normalized.hasPrefix("isbn:")
        // Author-merged results live in their own cache namespace ("a|"): legacy
        // entries were built from title-only ISBNdb fetches and can be missing an
        // author's books entirely, which read-time filtering can't repair. Title-
        // only consumers keep the legacy keys, so their warm cache stays valid.
        let mergesAuthors = searchAuthors && !isISBNQuery
        let cacheKey = (mergesAuthors ? "a|" : "")
            + (languageRestriction.map { "lang=\($0)|" } ?? "")
            + (includeAllEditions ? "all|" : "")
            + normalized
        if let cached = cacheQueue.sync(execute: { searchCache[cacheKey] }) {
            return cached
        }
        // Works 2+ SPINE members have shelved get a large ranking boost. Cached
        // hourly; kicked off here so a cold fetch overlaps the cache lookup
        // instead of following it, and capped so it never delays results.
        let popularKeysTask: Task<Set<String>, Never>? = isISBNQuery
            ? nil
            : Task { await BookPopularityService.shared.popularKeys() }
        // Shared cross-user Firestore cache: a query any user has run before resolves
        // without touching any API. (Entries keep the ranking of whoever populated
        // them — the libraryAuthors personalization boost isn't re-applied.) Entries
        // written before the junk filter widened still carry collection sets and
        // study guides, so re-filter on read; if that empties the entry, fall
        // through to a fresh API fetch that overwrites it.
        if let shared = await BookSearchCacheService.shared.lookup(cacheKey: cacheKey) {
            let cleaned = (includeAllEditions || isISBNQuery)
                ? shared.books
                : shared.books.filter { !BookSearchRanker.isJunkListing(title: $0.title, query: query, author: $0.author) }
            // Entries ranked before ISBN-implied language joined the scorer can have
            // a foreign edition dedup-merged as the winner — the English sibling is
            // gone from the stored list, so it can't be repaired on read. Treat such
            // an entry as a miss; the fresh fetch overwrites it at the new version.
            let staleForeignTop = shared.schemaVersion < BookSearchCacheService.currentSchemaVersion
                && !includeAllEditions && !isISBNQuery
                && cleaned.first.map { top in
                    let implied = BookSearchRanker.impliedLanguageCode(fromISBN: top.isbn)
                    let device = Locale.current.language.languageCode?.identifier.lowercased()
                    return implied != nil && device != nil && implied != device
                } == true
            if !cleaned.isEmpty, !staleForeignTop {
                // Legacy-entry upgrade in place, no API refetch. Pre-v4: re-rank —
                // older entries were ordered before article-insensitive title
                // matching and companion penalties, so tie-in books can sit above
                // the actual work (stored books carry no API signals, but the
                // ranker's title/author/metadata scoring is what these fixes
                // changed). Pre-v3 entries additionally carry pre-dedup ids, which
                // canonicalization swaps for community canonical docs.
                var served = cleaned
                if shared.schemaVersion < BookSearchCacheService.currentSchemaVersion,
                   !includeAllEditions, !isISBNQuery {
                    let popularKeys = await popularKeysTask?.value ?? []
                    let candidates = cleaned.map {
                        BookSearchRanker.Candidate(
                            book: $0,
                            signals: BookSearchSignals(ratingsCount: nil, averageRating: nil, language: nil)
                        )
                    }
                    // Deduplicate again even though the entry was deduped when stored:
                    // pre-v6 entries were collapsed under the weaker workKey and can
                    // still carry edition duplicates ("…And Other Essays", "…Lib/E").
                    let reranked = BookSearchRanker.rank(
                        candidates,
                        query: query,
                        deduplicate: true,
                        libraryAuthors: libraryAuthors,
                        popularKeys: popularKeys
                    )
                    served = await BookRepository.shared.canonicalizeSearchResults(reranked)
                    BookSearchCacheService.shared.store(cacheKey: cacheKey, books: served, source: shared.source)
                }
                storeInMemory(cacheKey: cacheKey, books: served)
                return served
            }
        }
        let popularKeys = await popularKeysTask?.value ?? []
        // Tier 1: ISBNdb (paid, dedicated quota). Google runs only when ISBNdb
        // errors, is rate-limited, or has nothing for the query.
        if ISBNdbService.shared.isConfigured {
            do {
                let tier = try await searchISBNdb(
                    query: query,
                    isISBNQuery: isISBNQuery,
                    includeAllEditions: includeAllEditions,
                    libraryAuthors: libraryAuthors,
                    languageRestriction: languageRestriction,
                    popularKeys: popularKeys,
                    searchAuthors: searchAuthors
                )
                if !tier.books.isEmpty {
                    let canonical = await canonicalized(tier.books, includeAllEditions: includeAllEditions, isISBNQuery: isISBNQuery)
                    storeInMemory(cacheKey: cacheKey, books: canonical)
                    BookSearchCacheService.shared.store(cacheKey: cacheKey, books: canonical, source: .isbndb)
                    if let late = tier.lateRerank {
                        finishRankingLater(late, cacheKey: cacheKey, includeAllEditions: includeAllEditions, isISBNQuery: isISBNQuery)
                    }
                    return canonical
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // ISBNdb unavailable or throttled — fall through to Google.
            }
        }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: isISBNQuery ? "15" : "30"),
            URLQueryItem(name: "printType", value: "books"),
            URLQueryItem(name: "projection", value: "full")
        ]
        if let lang = languageRestriction, !lang.isEmpty {
            queryItems.append(URLQueryItem(name: "langRestrict", value: lang))
        }
        let data: Data
        do {
            data = try await googleSearchData(queryItems: queryItems)
        } catch let googleError as NSError where Self.isRetryableWithFallback(googleError) {
            // Both Google pools are dry — serve Open Library results instead of an error.
            // Cached with a short TTL so a later search upgrades to Google ranking.
            // Same junk filter and ranker as the other tiers: this path is what every
            // user sees on quota-dry days, and its output lands in the shared cache.
            do {
                let matches = try await OpenLibraryService.shared.searchMatches(query: query)
                let applyJunk = !includeAllEditions && !isISBNQuery
                let candidates: [BookSearchRanker.Candidate] = matches.compactMap { match in
                    if applyJunk, BookSearchRanker.isJunkListing(title: match.book.title, query: query, author: match.book.author) { return nil }
                    return BookSearchRanker.Candidate(
                        book: match.book,
                        signals: BookSearchSignals(ratingsCount: match.popularityCount, averageRating: nil, language: nil)
                    )
                }
                let books = isISBNQuery
                    ? candidates.map(\.book)
                    : BookSearchRanker.rank(
                        candidates,
                        query: query,
                        deduplicate: !includeAllEditions,
                        libraryAuthors: libraryAuthors,
                        popularKeys: popularKeys
                    )
                guard !books.isEmpty else { throw googleError }
                let canonical = await canonicalized(books, includeAllEditions: includeAllEditions, isISBNQuery: isISBNQuery)
                storeInMemory(cacheKey: cacheKey, books: canonical)
                BookSearchCacheService.shared.store(cacheKey: cacheKey, books: canonical, source: .openLibrary)
                return canonical
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw googleError
            }
        }
        let decoded: GoogleBooksResponse
        do {
            decoded = try JSONDecoder().decode(GoogleBooksResponse.self, from: data)
        } catch {
            throw NSError(domain: "GoogleBooks", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from server. Try again."])
        }
        if let apiError = decoded.error, let msg = apiError.message, !msg.isEmpty {
            let hint = (apiError.code == 403) ? " Enable the Books API in Google Cloud Console for your API key." : ""
            throw NSError(domain: "GoogleBooks", code: apiError.code ?? -1, userInfo: [NSLocalizedDescriptionKey: msg + hint])
        }
        let applyJunkFilter = !includeAllEditions && !isISBNQuery
        let candidates: [BookSearchRanker.Candidate] = (decoded.items ?? []).compactMap { item in
            guard let book = mapToBook(item: item) else { return nil }
            if applyJunkFilter, BookSearchRanker.isJunkListing(title: book.title, query: query, author: book.author) { return nil }
            return BookSearchRanker.Candidate(
                book: book,
                signals: BookSearchSignals(
                    ratingsCount: item.volumeInfo?.ratingsCount,
                    averageRating: item.volumeInfo?.averageRating,
                    language: item.volumeInfo?.language
                )
            )
        }
        let books: [Book]
        if isISBNQuery {
            books = candidates.map(\.book)
        } else {
            books = BookSearchRanker.rank(
                candidates,
                query: query,
                deduplicate: !includeAllEditions,
                libraryAuthors: libraryAuthors,
                popularKeys: popularKeys
            )
        }
        let canonical = await canonicalized(books, includeAllEditions: includeAllEditions, isISBNQuery: isISBNQuery)
        storeInMemory(cacheKey: cacheKey, books: canonical)
        BookSearchCacheService.shared.store(cacheKey: cacheKey, books: canonical, source: .google)
        return canonical
    }

    /// Dedup phase 3: swap fresh results for the community's canonical docs
    /// before caching, so search hands out the ids friends' reviews and
    /// discussions already live on (see BookRepository.canonicalizeSearchResults).
    /// Skipped for "all editions" (distinct editions are the point there) and
    /// strict `isbn:` lookups (the user asked for one exact edition).
    private func canonicalized(_ books: [Book], includeAllEditions: Bool, isISBNQuery: Bool) async -> [Book] {
        guard !includeAllEditions, !isISBNQuery, !books.isEmpty else { return books }
        // Ranked lists can run 50–130 books after the title+author merge, but the
        // shared cache stores 30 and nobody scrolls past the top handful, so cap
        // before canonicalization — its Firestore `in` queries scale with count.
        // "Show all results" (includeAllEditions) bypasses via the guard above.
        return await BookRepository.shared.canonicalizeSearchResults(Array(books.prefix(Self.rankedResultCap)))
    }

    /// What the ISBNdb tier hands back: the ranked books, plus — when Open
    /// Library's popularity counts missed the grace window — a task that yields
    /// the fully ranked list once they land (nil result if nothing changed or
    /// OL never answered).
    private struct ISBNdbTierResult {
        let books: [Book]
        let lateRerank: Task<[Book]?, Never>?
    }

    /// The popularity counts arrived after the results were painted: fold them
    /// into this device's memo and the shared cache without touching the
    /// screen. The next search of this query, by anyone, gets the full ranking.
    /// Unstructured on purpose — typing on cancels the search, not this repair.
    private func finishRankingLater(_ late: Task<[Book]?, Never>, cacheKey: String, includeAllEditions: Bool, isISBNQuery: Bool) {
        Task {
            guard let reranked = await late.value else { return }
            let canonical = await canonicalized(reranked, includeAllEditions: includeAllEditions, isISBNQuery: isISBNQuery)
            storeInMemory(cacheKey: cacheKey, books: canonical)
            BookSearchCacheService.shared.store(cacheKey: cacheKey, books: canonical, source: .isbndb)
        }
    }

    /// ISBNdb tier of the search chain, shaped to match the Google path:
    /// same junk-edition filter, same ranker, same language restriction
    /// (applied client-side — ISBNdb has no langRestrict parameter; records
    /// with no language stay in, the import's title gate catches translations).
    private func searchISBNdb(
        query: String,
        isISBNQuery: Bool,
        includeAllEditions: Bool,
        libraryAuthors: Set<String>,
        languageRestriction: String?,
        popularKeys: Set<String>,
        searchAuthors: Bool
    ) async throws -> ISBNdbTierResult {
        if isISBNQuery {
            let digits = query.trimmingCharacters(in: .whitespaces).dropFirst(5).filter(\.isNumber)
            guard let book = try await ISBNdbService.shared.lookupISBN(String(digits)) else {
                return ISBNdbTierResult(books: [], lateRerank: nil)
            }
            return ISBNdbTierResult(books: [book], lateRerank: nil)
        }
        // Author-shaped queries (a few words, no digits — how names look) also
        // hit ISBNdb's /author endpoint, concurrently with the title request
        // (the service's pacer spaces their starts). One request failing must
        // not drop the other's results; both empty/failed falls to Google.
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        let authorShaped = !trimmedQuery.contains(where: \.isNumber)
            && (1...4).contains(trimmedQuery.split(separator: " ").count)
        let authorTask: Task<[ISBNdbService.Match], Never>? = (searchAuthors && authorShaped)
            ? Task { (try? await ISBNdbService.shared.searchByAuthor(name: trimmedQuery)) ?? [] }
            : nil
        // ISBNdb records carry no ratings data, so nothing separates the canonical
        // work from tie-in merch that also matches the query. Open Library's free
        // search API does (readinglog shelvings) — harvest counts concurrently
        // and join them onto ISBNdb records by work identity. Best-effort: an OL
        // failure just means no popularity signal, which is where this path
        // already was. Never awaited past `popularitySignalGrace` (see below).
        let olSignalsTask: Task<[String: Int], Never> = Task {
            guard let olMatches = try? await OpenLibraryService.shared.popularitySignals(query: query, limit: 20) else { return [:] }
            var counts: [String: Int] = [:]
            for olMatch in olMatches {
                let key = BookSearchRanker.collapseKey(title: olMatch.title, author: olMatch.author).full
                if olMatch.popularity > 0 { counts[key] = max(counts[key] ?? 0, olMatch.popularity) }
            }
            return counts
        }
        var matches: [ISBNdbService.Match] = []
        var titleError: Error?
        do {
            matches = try await ISBNdbService.shared.search(query: query)
        } catch is CancellationError {
            authorTask?.cancel()
            olSignalsTask.cancel()
            throw CancellationError()
        } catch {
            titleError = error
        }
        if let authorTask {
            let authorMatches = await authorTask.value
            var seen = Set(matches.map(\.book.id))
            for match in authorMatches where seen.insert(match.book.id).inserted {
                matches.append(match)
            }
        }
        if matches.isEmpty, let titleError {
            olSignalsTask.cancel()
            throw titleError
        }
        if let lang = languageRestriction?.lowercased(), !lang.isEmpty {
            // ISBNdb records often omit language; the ISBN registration group
            // fills the gap (978-602 = Indonesia, etc). Records with neither
            // signal stay in — the import's title gate catches translations.
            matches = matches.filter { match in
                let effective = match.languageCode ?? BookSearchRanker.impliedLanguageCode(fromISBN: match.book.isbn)
                return effective == nil || effective == lang
            }
        }
        let applyJunkFilter = !includeAllEditions
        let kept = matches.filter { match in
            !(applyJunkFilter && BookSearchRanker.isJunkListing(title: match.book.title, query: query, author: match.book.author))
        }
        let rank: ([String: Int]) -> [Book] = { olCounts in
            let candidates = kept.map { match in
                BookSearchRanker.Candidate(
                    book: match.book,
                    signals: BookSearchSignals(
                        ratingsCount: olCounts[BookSearchRanker.collapseKey(title: match.book.title, author: match.book.author).full],
                        averageRating: nil,
                        language: match.languageCode
                    )
                )
            }
            return BookSearchRanker.rank(
                candidates,
                query: query,
                deduplicate: !includeAllEditions,
                libraryAuthors: libraryAuthors,
                popularKeys: popularKeys
            )
        }
        // ISBNdb is back; give Open Library a short grace to land its counts.
        // Title tiers, the junk filter, and community popularity carry the
        // ranking without them — OL mostly breaks ties among same-work editions
        // and orders an author's catalog — so past the grace the results go out
        // as they are and the counts finish the job in the caches.
        let olCounts: [String: Int]? = await withTaskGroup(of: [String: Int]?.self) { group in
            group.addTask { await olSignalsTask.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.popularitySignalGrace)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let olCounts {
            return ISBNdbTierResult(books: rank(olCounts), lateRerank: nil)
        }
        let books = rank([:])
        let late = Task<[Book]?, Never> {
            let counts = await olSignalsTask.value
            guard !counts.isEmpty else { return nil }
            let reranked = rank(counts)
            return reranked.map(\.id) == books.map(\.id) ? nil : reranked
        }
        return ISBNdbTierResult(books: books, lateRerank: late)
    }

    private func storeInMemory(cacheKey: String, books: [Book]) {
        cacheQueue.sync {
            if searchCache.count >= cacheMaxQueries {
                if let first = searchCache.keys.first { searchCache.removeValue(forKey: first) }
            }
            searchCache[cacheKey] = books
        }
    }

    /// Keyed first: the project quota is the only Google pool that reliably works
    /// (the global anonymous pool 429s essentially always). If the keyed request is
    /// throttled or refused even after backoff, try keyless once as a long shot —
    /// unless keyless already reported its daily quota dry recently.
    private func googleSearchData(queryItems: [URLQueryItem]) async throws -> Data {
        guard apiKey != nil else {
            return try await requestData(queryItems: queryItems, usingKey: false)
        }
        do {
            return try await requestData(queryItems: queryItems, usingKey: true)
        } catch let keyedError as NSError where Self.isRetryableWithFallback(keyedError) && !shouldSkipKeyless {
            do {
                return try await requestData(queryItems: queryItems, usingKey: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Surface the keyed error — its message (project quota) is the actionable one.
                throw keyedError
            }
        }
    }

    /// HTTP failures worth retrying on the other quota pool: throttles, server errors,
    /// and refusals. Network errors (offline, timeout, cancelled) surface negative codes
    /// and are excluded — a second request can't help there.
    private static func isRetryableWithFallback(_ error: NSError) -> Bool {
        error.domain == "GoogleBooks" && [403, 429, 500, 502, 503, 504].contains(error.code)
    }

    /// Performs a volumes search request, retrying transient throttles with backoff.
    ///
    /// Searching-as-you-type fires a request every time the debounce window elapses,
    /// so several can reach Google in quick succession and trip its rate limiter
    /// (HTTP 429/503 "Service temporarily unavailable"). Retry those transient throttles
    /// with a short backoff so they resolve themselves instead of forcing the user to
    /// tap "Try Again". Cancellation during the backoff propagates to the caller.
    private func requestData(queryItems: [URLQueryItem], usingKey: Bool) async throws -> Data {
        var items = queryItems
        if usingKey, let key = apiKey {
            items.append(URLQueryItem(name: "key", value: key))
        }
        var comp = URLComponents(string: baseURL)!
        comp.queryItems = items
        guard let url = comp.url else {
            throw NSError(domain: "GoogleBooks", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid search query."])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let transientStatuses: Set<Int> = [429, 500, 502, 503, 504]
        let maxAttempts = 3
        var attempt = 0
        while true {
            let payload: Data
            let response: URLResponse
            do {
                (payload, response) = try await session.data(for: request)
            } catch let urlError as URLError {
                let msg: String
                switch urlError.code {
                case .notConnectedToInternet, .networkConnectionLost:
                    msg = "No internet connection. Check Wi‑Fi or cellular."
                case .timedOut:
                    msg = "Request timed out. Check your connection and try again."
                case .cancelled:
                    msg = "Search was cancelled."
                default:
                    msg = urlError.localizedDescription.isEmpty ? "Can't reach Google Books. Check your connection." : urlError.localizedDescription
                }
                throw NSError(domain: "GoogleBooks", code: urlError.errorCode, userInfo: [NSLocalizedDescriptionKey: msg])
            } catch {
                throw NSError(domain: "GoogleBooks", code: -2, userInfo: [NSLocalizedDescriptionKey: "Can't reach Google Books. Check your internet connection."])
            }
            guard let http = response as? HTTPURLResponse else {
                throw NSError(domain: "GoogleBooks", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from server. Try again."])
            }
            if http.statusCode == 200 {
                return payload
            }
            attempt += 1
            let errorMessage = try? JSONDecoder().decode(GoogleBooksResponse.self, from: payload).error?.message
            // A "Queries per day" 429 is a daily quota that won't recover for hours —
            // backoff can't help, so fail fast (and remember, so later searches skip
            // the keyless attempt entirely).
            let isDailyQuota = http.statusCode == 429 && (errorMessage?.localizedCaseInsensitiveContains("per day") ?? false)
            if isDailyQuota, !usingKey {
                markKeylessQuotaExhausted()
            }
            if transientStatuses.contains(http.statusCode), !isDailyQuota, attempt < maxAttempts {
                // Back off 300ms, then 600ms, before retrying.
                try await Task.sleep(nanoseconds: 300_000_000 * UInt64(attempt))
                continue
            }
            let message = errorMessage ?? "Request failed (HTTP \(http.statusCode))."
            let hint = (usingKey && http.statusCode == 403)
                ? " Enable the Books API in Google Cloud Console (APIs & Services → Library → Books API) and ensure your API key is allowed."
                : ""
            throw NSError(domain: "GoogleBooks", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message + hint])
        }
    }

    /// Fetches a single volume by Google Books volume ID (same `Book.id` from search). Used to fill categories when the stored book has no genres.
    func fetchVolume(id: String) async throws -> Book? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        // Keyed first; one keyless long-shot retry if the project quota is dry.
        var result = try await volumeData(encodedId: encoded, usingKey: apiKey != nil)
        if case .retryable = result, apiKey != nil, !shouldSkipKeyless {
            result = try await volumeData(encodedId: encoded, usingKey: false)
        }
        guard case .success(let data) = result else { return nil }
        let item: GoogleBooksItem
        do {
            item = try JSONDecoder().decode(GoogleBooksItem.self, from: data)
        } catch {
            return nil
        }
        return mapToBook(item: item)
    }

    private enum VolumeFetchResult {
        case success(Data)
        /// Throttle/refusal status where a keyed retry might succeed.
        case retryable
        case failed
    }

    private func volumeData(encodedId: String, usingKey: Bool) async throws -> VolumeFetchResult {
        var comp = URLComponents(string: "\(baseURL)/\(encodedId)")!
        if usingKey, let key = apiKey {
            comp.queryItems = [URLQueryItem(name: "key", value: key)]
        }
        guard let url = comp.url else { return .failed }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NSError(domain: "GoogleBooks", code: -2, userInfo: [NSLocalizedDescriptionKey: "Can't reach Google Books."])
        }
        guard let http = response as? HTTPURLResponse else { return .failed }
        guard http.statusCode == 200 else {
            if !usingKey, http.statusCode == 429,
               let msg = try? JSONDecoder().decode(GoogleBooksResponse.self, from: data).error?.message,
               msg.localizedCaseInsensitiveContains("per day") {
                markKeylessQuotaExhausted()
            }
            return [403, 429, 500, 502, 503, 504].contains(http.statusCode) ? .retryable : .failed
        }
        return .success(data)
    }

    /// Use imageLinks in documented size order (best available first). Books without
    /// covers still map (empty coverURL — UI uses title placeholder / Open Library).
    /// Junk-listing filtering happens at the call sites that have the query in hand
    /// (see `BookSearchRanker.isJunkListing`); `fetchVolume` never filters, since it
    /// resolves a book the user already has.
    private func mapToBook(item: GoogleBooksItem) -> Book? {
        guard let info = item.volumeInfo, let title = info.title, !title.isEmpty else { return nil }
        let links = info.imageLinks
        // Prefer thumbnail → medium before extraLarge: very large assets are sometimes interior scans or preview pages, not the marketing cover.
        let rawOrder: [String?] = [
            links?.thumbnail,
            links?.smallThumbnail,
            links?.small,
            links?.medium,
            links?.large,
            links?.extraLarge
        ]
        var seen = Set<String>()
        let allURLs: [String] = rawOrder
            .compactMap { $0 }
            .map { $0.hasPrefix("http://") ? "https" + $0.dropFirst(4) : $0 }
            .map { Book.sanitizeGoogleBooksCoverURL($0) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let primary = allURLs.first ?? ""
        let fallbacks = Array(allURLs.dropFirst())
        let author = info.authors?.joined(separator: ", ") ?? "Unknown"
        let isbnDigits = Self.normalizedISBNDigits(from: info.industryIdentifiers)
        return Book(
            id: item.id,
            title: title,
            author: author,
            coverURL: primary,
            pageCount: info.pageCount,
            publishedDate: parsePublishedDate(info.publishedDate),
            description: info.description,
            genres: info.categories ?? [],
            isbn: isbnDigits,
            fallbackCoverURLs: fallbacks.isEmpty ? nil : fallbacks
        )
    }

    /// Prefer ISBN-13, then ISBN-10 (digits only).
    private static func normalizedISBNDigits(from identifiers: [IndustryIdentifier]?) -> String? {
        guard let ids = identifiers, !ids.isEmpty else { return nil }
        let upper = ids.map { ($0.type?.uppercased() ?? "", $0.identifier ?? "") }
        let isbn13 = upper.first { $0.0.contains("ISBN_13") || $0.0 == "ISBN13" }?.1
            ?? upper.first { $0.1.filter(\.isNumber).count == 13 }?.1
        let isbn10 = upper.first { $0.0.contains("ISBN_10") || $0.0 == "ISBN10" }?.1
            ?? upper.first { $0.1.filter(\.isNumber).count == 10 }?.1
        let digits = (isbn13 ?? isbn10)?.filter(\.isNumber) ?? ""
        guard digits.count == 10 || digits.count == 13 else { return nil }
        return digits
    }
}
