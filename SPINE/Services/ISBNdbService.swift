//
//  ISBNdbService.swift
//  SPINE
//
//  Primary book metadata source (paid). The app-wide lookup chain is
//  ISBNdb → Google Books → Open Library, orchestrated in GoogleBooksService's
//  search hub; this client only talks to ISBNdb.
//
//  The account is the Premium plan, marketed as "3 requests/second" but enforced
//  as 180 requests per rolling 60s window, account-wide (verified 2026-10-05 via
//  GET /key: `ratelimit-policy: "rate";q=180;w=60`), plus 15,000/day resetting
//  00:00 UTC. Each device still paces its own requests through a serial
//  throttle. Other devices share the window, so 429s are possible: those wait
//  the server's advertised `t` and retry. Outages and an exhausted daily quota
//  open a circuit breaker so the chain falls through to Google fast instead of
//  stalling per lookup.
//
//  Documented error contract (isbndb.com/isbndb-api-documentation-v2, v2.8.0):
//  bodies are {"message": …, "errorMessage": …}. 400 invalid request, 401 bad /
//  inactive key, 404 not in catalog (often added within 24h), 429 with
//  "Per minute quota exceeded, please try again later" or "Daily quota
//  exceeded, please try again later", 503 search backend down (Retry-After).
//  Every response carries `ratelimit: "rate";r=<left>;t=<seconds to wait>`
//  (and a "daily" item the same way).
//

import Foundation

/// Paces requests so consecutive starts are at least `minInterval` apart
/// (ISBNdb enforces a per-second cap server-side). A slot is claimed only by
/// a request that actually goes out: a waiter cancelled before its turn (the
/// user typed past that search) leaves no gap behind it. The old version
/// reserved a slot up front, so type-ahead queued fresh searches behind
/// abandoned ones.
private actor ISBNdbRequestPacer {
    private let minInterval: TimeInterval
    private var nextAllowed = Date.distantPast

    init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    func waitTurn() async throws {
        while true {
            try Task.checkCancellation()
            let now = Date()
            if now >= nextAllowed {
                nextAllowed = now.addingTimeInterval(minInterval)
                return
            }
            // Actor reentrancy: other waiters run while this one sleeps, and
            // whoever wakes first after `nextAllowed` takes the slot.
            try await Task.sleep(nanoseconds: UInt64(nextAllowed.timeIntervalSince(now) * 1_000_000_000))
        }
    }

    /// Hold every request from this device back for `seconds` (after a 429).
    func backOff(for seconds: TimeInterval) {
        nextAllowed = max(nextAllowed, Date().addingTimeInterval(seconds))
    }
}

/// One ISBNdb record. Fields decode leniently (`try?` per field) — the API
/// mixes types across records (e.g. `date_published` as "2021-05-04" or 2021)
/// and one odd field must not drop the whole result set.
struct ISBNdbBook {
    let title: String?
    let isbn13: String?
    let isbn10: String?
    let authors: [String]?
    let image: String?
    let synopsis: String?
    let subjects: [String]?
    let pages: Int?
    let datePublished: String?
    let language: String?
}

extension ISBNdbBook: Decodable {
    private enum CodingKeys: String, CodingKey {
        case title, isbn, isbn13, isbn10, authors, image, synopsis, subjects, pages, language
        case titleLong = "title_long"
        case datePublished = "date_published"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title))
            ?? (try? c.decodeIfPresent(String.self, forKey: .titleLong))
        isbn13 = (try? c.decodeIfPresent(String.self, forKey: .isbn13))
            ?? (try? c.decodeIfPresent(String.self, forKey: .isbn))
        isbn10 = try? c.decodeIfPresent(String.self, forKey: .isbn10)
        authors = try? c.decodeIfPresent([String].self, forKey: .authors)
        image = try? c.decodeIfPresent(String.self, forKey: .image)
        synopsis = try? c.decodeIfPresent(String.self, forKey: .synopsis)
        subjects = try? c.decodeIfPresent([String].self, forKey: .subjects)
        pages = (try? c.decodeIfPresent(Int.self, forKey: .pages))
            ?? (try? c.decodeIfPresent(String.self, forKey: .pages)).flatMap { Int($0) }
        datePublished = (try? c.decodeIfPresent(String.self, forKey: .datePublished))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .datePublished)).map { String($0) }
        language = try? c.decodeIfPresent(String.self, forKey: .language)
    }
}

private struct ISBNdbBookResponse: Decodable {
    let book: ISBNdbBook?
}

private struct ISBNdbSearchResponse: Decodable {
    let books: [ISBNdbBook]?
}

/// `POST /books` (bulk ISBN lookup) nests results under "data", not "books".
private struct ISBNdbBulkResponse: Decodable {
    let data: [ISBNdbBook]?
}

final class ISBNdbService {
    static let shared = ISBNdbService()

    /// A mapped book plus the record's language code — `Book` doesn't carry
    /// language, and the search hub needs it for ranking and lang filtering.
    struct Match {
        let book: Book
        let languageCode: String?
    }

    private let baseURL = "https://api2.isbndb.com"
    private let session: URLSession
    // Premium = 3 req/s; 0.35s spacing stays just under it (was 1.05 on Basic).
    private let pacer = ISBNdbRequestPacer(minInterval: 0.35)

    // Circuit breaker: when ISBNdb is genuinely unavailable, fail lookups fast
    // so the Google fallback runs immediately instead of after a timeout per
    // book. Kinds of trip:
    //   - outage (network errors, 5xx): two consecutive failures → 2 minutes.
    //   - daily quota exhausted: first hit → until the 00:00 UTC reset (the
    //     header's `t`), capped at an hour so a mid-day plan upgrade is picked
    //     up; re-probing costs one failed request.
    //   - per-minute window drained with a long wait: pause for that wait.
    // A per-minute 429 with a short wait is NOT a failure: the window is
    // shared by every device, so it backs off `t` seconds and retries
    // (`getData`) instead of pausing ISBNdb on this device.
    private let breakerQueue = DispatchQueue(label: "com.spine.isbndb.breaker")
    private var consecutiveFailures = 0
    private var unavailableUntil: Date?
    private static let outagePause: TimeInterval = 2 * 60
    /// Daily-quota pause when the header doesn't say how long until reset.
    private static let quotaPause: TimeInterval = 30 * 60
    private static let maxQuotaPause: TimeInterval = 60 * 60
    /// 429 retries per request. Each waits the server's `t` (or ~1s when
    /// absent) plus jitter, so colliding devices don't retry in lockstep.
    private static let rateLimitRetries = 3
    /// Longest wait a user should sit through for a drained per-minute window;
    /// beyond this, this request goes to Google and ISBNdb pauses for `t`.
    private static let maxRateLimitWait: TimeInterval = 3

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)
    }

    /// Sources: Secrets.plist / Info.plist "ISBNDB_API_KEY".
    private var apiKey: String? {
        for plist in ["Secrets", "Info"] {
            if let path = Bundle.main.path(forResource: plist, ofType: "plist"),
               let dict = NSDictionary(contentsOfFile: path),
               let key = dict["ISBNDB_API_KEY"] as? String, !key.isEmpty {
                return key
            }
        }
        return nil
    }

    /// False when no API key is bundled — the chain skips straight to Google.
    var isConfigured: Bool { apiKey != nil }

    private var breakerOpen: Bool {
        breakerQueue.sync {
            guard let until = unavailableUntil else { return false }
            return until > Date()
        }
    }

    private func recordFailure(status: Int) {
        let opened: Bool = breakerQueue.sync {
            consecutiveFailures += 1
            guard consecutiveFailures >= 2 else { return false }
            let wasOpen = (unavailableUntil ?? .distantPast) > Date()
            unavailableUntil = Date().addingTimeInterval(Self.outagePause)
            return !wasOpen
        }
        if opened { trackPause(reason: "error", status: status, seconds: Self.outagePause) }
    }

    /// Pause ISBNdb on this device for `seconds` (daily quota, or a long
    /// per-minute wait), tracked once per transition into the paused state.
    private func pause(reason: String, status: Int, seconds: TimeInterval) {
        let opened: Bool = breakerQueue.sync {
            let wasOpen = (unavailableUntil ?? .distantPast) > Date()
            unavailableUntil = max(unavailableUntil ?? .distantPast, Date().addingTimeInterval(seconds))
            return !wasOpen
        }
        if opened { trackPause(reason: reason, status: status, seconds: seconds) }
    }

    /// One event each time this device stops calling ISBNdb — the number to
    /// watch when deciding whether the plan's limits are hurting.
    private func trackPause(reason: String, status: Int, seconds: TimeInterval) {
        Analytics.amplitude?.track(eventType: "ISBNdb Paused", eventProperties: [
            "reason": reason,
            "http_status": status,
            "pause_seconds": Int(seconds)
        ])
    }

    /// Both limits answer 429; only the body tells them apart ("Daily quota
    /// exceeded…" vs "Per minute quota exceeded…"), so match "daily" — a bare
    /// "quota" match would treat every per-minute 429 as a day-long outage.
    private static func isDailyQuotaExhausted(_ data: Data) -> Bool {
        String(decoding: data.prefix(2_000), as: UTF8.self).range(of: "daily quota", options: .caseInsensitive) != nil
    }

    private static func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Seconds to wait for the named limit ("rate" or "daily") from the
    /// `ratelimit` header, e.g. `"rate";r=0;t=12, "daily";r=48999;t=56312`.
    private static func waitSeconds(_ http: HTTPURLResponse, limit: String) -> TimeInterval? {
        guard let header = http.value(forHTTPHeaderField: "ratelimit") else { return nil }
        for item in header.split(separator: ",") {
            let parts = item.trimmingCharacters(in: .whitespaces).split(separator: ";")
            guard parts.first?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == limit else { continue }
            for part in parts.dropFirst() where part.hasPrefix("t=") {
                return TimeInterval(part.dropFirst(2))
            }
        }
        return nil
    }

    private func recordSuccess() {
        breakerQueue.sync {
            consecutiveFailures = 0
            unavailableUntil = nil
        }
    }

    /// Exact ISBN lookup (10 or 13 digits). Returns nil when ISBNdb doesn't
    /// know the ISBN; throws only for service problems (so callers can
    /// distinguish "no match" from "try the fallback source").
    func lookupISBN(_ isbn: String) async throws -> Book? {
        let digits = isbn.filter(\.isNumber)
        guard digits.count == 10 || digits.count == 13 else { return nil }
        guard let data = try await getData(path: "/book/\(digits)") else { return nil }
        guard let record = try? JSONDecoder().decode(ISBNdbBookResponse.self, from: data).book else { return nil }
        return map(record, queriedISBN: digits)?.book
    }

    /// Free-text search. Result order is ISBNdb's relevance — the search hub
    /// re-ranks with `BookSearchRanker`.
    func search(query: String, limit: Int = 30) async throws -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.lowercased().hasPrefix("isbn:") {
            let digits = String(trimmed.dropFirst(5)).filter(\.isNumber)
            guard let book = try await lookupISBN(digits) else { return [] }
            return [Match(book: book, languageCode: nil)]
        }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return [] }
        guard let data = try await getData(path: "/books/\(encoded)", queryItems: [URLQueryItem(name: "pageSize", value: "\(limit)")]) else { return [] }
        let records = (try? JSONDecoder().decode(ISBNdbSearchResponse.self, from: data).books) ?? []
        return records.compactMap { map($0, queriedISBN: nil) }
    }

    /// Bulk ISBN lookup via `POST /books`: one paced request resolves up to
    /// 1,000 ISBNs (the Premium-plan cap; Basic allows 100). Each ISBN in the
    /// body bills one search — same daily quota as single lookups, but N round
    /// trips collapse into one. `books` is keyed by the *requested* digits
    /// (which also become each Book's id, matching `lookupISBN`). ISBNs ISBNdb
    /// doesn't know are absent from `books` and listed in `confirmedMissing` —
    /// but only for chunks that came back as a clean 200, so a rejected request
    /// never reads as "ISBNdb doesn't have these". Throws only for service problems.
    struct BulkLookupResult {
        var books: [String: Book] = [:]
        var confirmedMissing: Set<String> = []
    }

    func lookupISBNs(_ isbns: [String]) async throws -> BulkLookupResult {
        let requested = isbns
            .map { $0.filter(\.isNumber) }
            .filter { $0.count == 10 || $0.count == 13 }
        var result = BulkLookupResult()
        guard !requested.isEmpty else { return result }
        var start = 0
        while start < requested.count {
            let chunk = Array(requested[start..<min(start + Self.bulkChunkSize, requested.count)])
            start += Self.bulkChunkSize
            let body = "isbns=" + chunk.joined(separator: ",")
            guard let data = try await getData(path: "/books", postBody: body),
                  let response = try? JSONDecoder().decode(ISBNdbBulkResponse.self, from: data) else { continue }
            let records = response.data ?? []
            // Index records under both ISBN forms so a requested ISBN-10 finds a
            // record ISBNdb keyed by its ISBN-13 (and vice versa via equivalence).
            var byDigits: [String: ISBNdbBook] = [:]
            for record in records {
                for key in [record.isbn13, record.isbn10].compactMap({ $0?.filter(\.isNumber) }) where !key.isEmpty {
                    byDigits[key] = record
                }
            }
            for digits in chunk where result.books[digits] == nil {
                let record = byDigits[digits]
                    ?? byDigits.first { ISBNMatcher.equivalent($0.key, digits) }?.value
                if let record, let match = map(record, queriedISBN: digits) {
                    result.books[digits] = match.book
                    result.confirmedMissing.remove(digits)
                } else if record == nil {
                    result.confirmedMissing.insert(digits)
                }
            }
        }
        return result
    }

    /// Premium-plan cap on ISBNs per bulk request (Basic: 100).
    private static let bulkChunkSize = 1_000

    /// Books credited to the named author, via the dedicated `/author/{name}`
    /// endpoint. `/books/{query}` only matches titles — for "brandon sanderson"
    /// it returns bundles and books *about* him, never his actual catalog — so
    /// the search hub runs this alongside it and merges. The endpoint needs a
    /// reasonably complete name: partial names mid-typing return nothing (fine,
    /// the title search still answers). The default limit is deliberately large
    /// because the endpoint's order is arbitrary across a big catalog — the
    /// ranker's language/popularity/metadata signals sort the pile.
    func searchByAuthor(name: String, limit: Int = 100) async throws -> [Match] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return [] }
        guard let data = try await getData(path: "/author/\(encoded)", queryItems: [URLQueryItem(name: "pageSize", value: "\(limit)")]) else { return [] }
        // The /author payload nests results under "books" like /books does.
        let records = (try? JSONDecoder().decode(ISBNdbSearchResponse.self, from: data).books) ?? []
        return records.compactMap { map($0, queriedISBN: nil) }
    }

    /// Returns response data, nil for "not found" (400/404 — ISBNdb answers
    /// both for unknown ISBNs/queries), and throws for service failures.
    /// A non-nil `postBody` makes it a form-encoded POST (the bulk endpoint).
    private func getData(path: String, queryItems: [URLQueryItem] = [], postBody: String? = nil) async throws -> Data? {
        guard let key = apiKey else {
            throw NSError(domain: "ISBNdb", code: -3, userInfo: [NSLocalizedDescriptionKey: "ISBNdb API key is not configured."])
        }
        guard !breakerOpen else {
            throw NSError(domain: "ISBNdb", code: 429, userInfo: [NSLocalizedDescriptionKey: "ISBNdb is busy right now."])
        }
        var comp = URLComponents(string: baseURL + path)!
        if !queryItems.isEmpty { comp.queryItems = queryItems }
        guard let url = comp.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "Authorization")
        if let postBody {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(postBody.utf8)
        }

        var rateLimitedRetries = 0
        var retried503 = false
        // One event per request that hit the per-second cap: how often devices
        // collide, and whether backing off was enough.
        func trackRateLimited(recovered: Bool) {
            guard rateLimitedRetries > 0 else { return }
            Analytics.amplitude?.track(eventType: "ISBNdb Rate Limited", eventProperties: [
                "retries": rateLimitedRetries,
                "recovered": recovered
            ])
        }
        while true {
            try await pacer.waitTurn()
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            } catch {
                recordFailure(status: -2)
                throw NSError(domain: "ISBNdb", code: -2, userInfo: [NSLocalizedDescriptionKey: "Can't reach ISBNdb. Check your connection."])
            }
            guard let http = response as? HTTPURLResponse else {
                recordFailure(status: -1)
                throw NSError(domain: "ISBNdb", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from ISBNdb."])
            }
            if http.statusCode == 429, Self.isDailyQuotaExhausted(data) {
                let untilReset = Self.waitSeconds(http, limit: "daily").map { min($0, Self.maxQuotaPause) }
                pause(reason: "daily_quota", status: 429, seconds: untilReset ?? Self.quotaPause)
                throw NSError(domain: "ISBNdb", code: 429, userInfo: [NSLocalizedDescriptionKey: "ISBNdb's daily limit is used up."])
            }
            switch http.statusCode {
            case 200:
                recordSuccess()
                trackRateLimited(recovered: true)
                return data
            case 400, 404:
                // Unknown ISBN / no results — the service itself is healthy.
                recordSuccess()
                trackRateLimited(recovered: true)
                return nil
            case 429:
                // Per-minute window drained (shared by every device on the
                // account). Short wait: back off this device's queue by the
                // server's `t` and retry. Long wait, or retries used up: this
                // request goes to Google; a long wait also pauses ISBNdb here
                // for exactly that long instead of a guessed duration.
                let wait = Self.waitSeconds(http, limit: "rate") ?? 1
                guard wait <= Self.maxRateLimitWait, rateLimitedRetries < Self.rateLimitRetries else {
                    rateLimitedRetries = max(rateLimitedRetries, 1)
                    trackRateLimited(recovered: false)
                    if wait > Self.maxRateLimitWait {
                        pause(reason: "rate_window", status: 429, seconds: wait)
                    }
                    throw NSError(domain: "ISBNdb", code: 429, userInfo: [NSLocalizedDescriptionKey: "ISBNdb is busy right now."])
                }
                rateLimitedRetries += 1
                await pacer.backOff(for: max(wait, 0.5) + Double.random(in: 0...0.5))
                continue
            case 503 where (Self.retryAfter(http) ?? .infinity) <= Self.maxRateLimitWait && !retried503:
                // Search backend briefly down; the docs say retry after Retry-After.
                retried503 = true
                await pacer.backOff(for: Self.retryAfter(http) ?? 1)
                continue
            default:
                recordFailure(status: http.statusCode)
                throw NSError(domain: "ISBNdb", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "ISBNdb request failed (HTTP \(http.statusCode))."])
            }
        }
    }

    // MARK: Mapping

    private func map(_ record: ISBNdbBook, queriedISBN: String?) -> Match? {
        guard let rawTitle = record.title?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty else { return nil }
        let isbn13 = record.isbn13?.filter(\.isNumber)
        let isbn10 = record.isbn10?.filter(\.isNumber)
        let isbn = [queriedISBN, isbn13, isbn10]
            .compactMap { $0 }
            .first { $0.count == 10 || $0.count == 13 }
        // Book.id already sanctions ISBN ids (Open Library lookups use them too);
        // ISBNdb has no other stable identifier.
        guard let id = isbn else { return nil }
        // `image` is the stable CDN URL; `image_original` carries an expiring
        // signed token, so it must never be persisted.
        let cover = record.image ?? ""
        // Synopses arrive as HTML fragments, same as Goodreads reviews.
        let description = GoodreadsCSVParser.plainText(fromReviewHTML: record.synopsis)
        // Subjects mix plain labels with BISAC paths ("FICTION / Thrillers");
        // keep only short plain ones, as the Open Library mapping does.
        let genres = (record.subjects ?? [])
            .filter { $0.count < 30 && !$0.contains("/") && !$0.contains(":") && !$0.contains("=") }
            .prefix(5)
        let joinedAuthors = record.authors?.joined(separator: ", ").trimmingCharacters(in: .whitespaces) ?? ""
        let book = Book(
            id: id,
            title: rawTitle,
            author: joinedAuthors.isEmpty ? "Unknown" : joinedAuthors,
            coverURL: cover,
            pageCount: record.pages,
            publishedDate: Self.parseDate(record.datePublished),
            description: description,
            genres: Array(genres),
            isbn: isbn
        )
        return Match(book: book, languageCode: Self.languageCode(record.language))
    }

    /// "2021-05-04", "2021-05", or "2021".
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let utc = TimeZone(identifier: "UTC")!
        for format in ["yyyy-MM-dd", "yyyy-MM", "yyyy"] {
            let f = DateFormatter()
            f.dateFormat = format
            f.timeZone = utc
            f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    /// ISBNdb is inconsistent: "en" on some records, "English" on others.
    private static func languageCode(_ raw: String?) -> String? {
        guard let l = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !l.isEmpty else { return nil }
        if l.count == 2 { return l }
        let names = [
            "english": "en", "spanish": "es", "french": "fr", "german": "de",
            "italian": "it", "portuguese": "pt", "dutch": "nl", "japanese": "ja",
            "chinese": "zh", "russian": "ru", "korean": "ko", "arabic": "ar"
        ]
        if let code = names[l] { return code }
        // "en_US"-style tags.
        if l.count > 2, l[l.index(l.startIndex, offsetBy: 2)] == "_" || l[l.index(l.startIndex, offsetBy: 2)] == "-" {
            return String(l.prefix(2))
        }
        return nil
    }
}
