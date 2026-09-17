//
//  Book.swift
//  SPINE
//

import Foundation

struct Book: Identifiable, Equatable, Hashable {
    var id: String  // Google Books ID or ISBN
    var title: String
    var author: String
    var coverURL: String
    var pageCount: Int?
    var publishedDate: Date?
    var description: String?
    var genres: [String]
    /// Normalized ISBN-10 or ISBN-13 (digits only). Used for Open Library cover URLs; optional for older Firestore docs.
    var isbn: String? = nil
    /// Alternate cover URLs to try if the primary fails (e.g. from Google Books search). Not persisted to Firestore.
    var fallbackCoverURLs: [String]? = nil
    /// When true, `coverImageURLsToTry` is empty (e.g. Firestore metadata timed out — show title-only placeholder only).
    var suppressCoverImageFetch: Bool = false
    /// Community-chosen cover (a member regenerated a bad cover and kept the result).
    /// Tried before everything else so all users converge on it.
    var coverOverrideURL: String? = nil
    /// Cover URLs a member rejected via regeneration — skipped by the chain.
    var coverRejectedURLs: [String]? = nil

    /// Canonical ISBN-13 (digits only) for identity matching: an ISBN-13 passes
    /// through, an ISBN-10 converts (978 prefix + recomputed EAN-13 check digit),
    /// so the same edition arriving from different sources as ISBN-10 vs ISBN-13
    /// resolves to one key. Nil for anything that isn't a valid-length ISBN.
    static func canonicalISBN13(from isbn: String?) -> String? {
        guard let isbn else { return nil }
        let chars = isbn.uppercased().filter { $0.isNumber || $0 == "X" }
        if chars.count == 13, chars.allSatisfy(\.isNumber) { return chars }
        guard chars.count == 10 else { return nil }
        let body = "978" + chars.prefix(9)
        guard body.allSatisfy(\.isNumber) else { return nil }
        let sum = body.enumerated().reduce(0) { acc, pair in
            acc + (pair.element.wholeNumberValue ?? 0) * (pair.offset % 2 == 0 ? 1 : 3)
        }
        return body + String((10 - sum % 10) % 10)
    }

    /// Open Library cover API: large then medium. `default=false` makes a missing
    /// cover a fast 404 instead of a blank image we'd have to download and sniff.
    /// L (~500px) is sharp for every cover size in the app without over-fetching.
    /// See https://openlibrary.org/dev/docs/api/covers
    static func openLibraryCoverURLs(isbnDigits: String) -> [String] {
        let d = isbnDigits.filter(\.isNumber)
        guard d.count == 10 || d.count == 13 else { return [] }
        return ["L", "M"].map { "https://covers.openlibrary.org/b/isbn/\(d)-\($0).jpg?default=false" }
    }

    /// URL used for loading the cover image. Uses high-res variant for Google Books URLs when possible.
    var coverURLRequest: URL? {
        let urlString = Self.highResCoverURLString(coverURL)
        return URL(string: urlString)
    }

    /// Forces `books/content` URLs to use the marketing **front cover** (`printsec=frontcover`, `img=1`). Without this, Google sometimes serves an interior/title page.
    static func sanitizeGoogleBooksCoverURL(_ urlString: String) -> String {
        guard urlString.contains("books.google.com"),
              urlString.contains("/books/content"),
              var components = URLComponents(string: urlString) else { return urlString }
        var q = components.queryItems ?? []
        q.removeAll { $0.name.lowercased() == "printsec" }
        q.removeAll { $0.name.lowercased() == "img" }
        q.append(URLQueryItem(name: "printsec", value: "frontcover"))
        q.append(URLQueryItem(name: "img", value: "1"))
        components.queryItems = q
        return components.string ?? urlString
    }

    /// Rewrites Google Books image URLs to request highest resolution (zoom=0). Other URLs unchanged.
    static func highResCoverURLString(_ urlString: String) -> String {
        let base = sanitizeGoogleBooksCoverURL(urlString)
        guard base.contains("books.google.com"),
              var components = URLComponents(string: base) else { return base }
        var query = components.queryItems ?? []
        func setZoom(_ value: Int) {
            query.removeAll { $0.name.lowercased() == "zoom" }
            query.append(URLQueryItem(name: "zoom", value: "\(value)"))
        }
        setZoom(0)
        components.queryItems = query
        return components.string ?? base
    }

    /// Google zoom levels to try, best-fit first: zoom=2 (~300px) covers most display
    /// sizes, zoom=3 (~575px) for the profile header, zoom=1 (~128px thumbnail) as a
    /// last resort. zoom=0/4/5 are skipped — huge originals that are often interior scans.
    static let googleZoomsToTry = [2, 3, 1]

    /// For Google Books URLs, returns URL variants across `googleZoomsToTry` so we can try other resolutions if one fails. Non-Google URLs return a single-element array.
    static func coverURLsToTry(from urlString: String) -> [String] {
        let sanitized = sanitizeGoogleBooksCoverURL(urlString)
        guard sanitized.contains("books.google.com"),
              var components = URLComponents(string: sanitized) else {
            return sanitized.isEmpty ? [] : [sanitized]
        }
        var result: [String] = []
        let query = components.queryItems ?? []
        for zoom in googleZoomsToTry {
            var q = query
            q.removeAll { $0.name.lowercased() == "zoom" }
            q.append(URLQueryItem(name: "zoom", value: "\(zoom)"))
            components.queryItems = q
            if let s = components.string, !result.contains(s) {
                result.append(s)
            }
        }
        return result.isEmpty ? [sanitized] : result
    }

    /// Builds standard Google Books cover URLs from a volume ID (e.g. from API). Use as last-resort fallbacks when API image links fail or return placeholders.
    /// Returns none for UUID-shaped ids (custom / manually added books) — those are not Google volume ids; synthesizing URLs would only waste timeouts.
    static func coverURLsFromBookId(_ bookId: String) -> [String] {
        let id = bookId.trimmingCharacters(in: .whitespaces)
        if UUID(uuidString: id) != nil { return [] }
        guard id.count >= 5, id.count <= 50, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return [] }
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        return googleZoomsToTry.map { "https://books.google.com/books/content?id=\(encoded)&printsec=frontcover&img=1&zoom=\($0)" }
    }

    /// Whether to append Google `books/content?id=<bookId>` zoom fallbacks. Skip when we already have a non-Google cover URL (e.g. Firebase/custom) or a non–Google-Books id.
    private static func shouldAppendGoogleIdCoverFallbacks(coverURL: String, bookId: String) -> Bool {
        if UUID(uuidString: bookId.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            return false
        }
        let trimmed = coverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.contains("books.google.com") {
            return false
        }
        return true
    }

    /// Ordered URLs for loading cover art (same pipeline as `BookCoverView`).
    var coverImageURLsToTry: [URL] {
        if suppressCoverImageFetch { return [] }
        var list: [String] = []
        // Community override wins outright — first in the chain, exempt from the
        // rejected filter (a stale rejection must never suppress the chosen cover).
        // Used verbatim, no zoom-variant expansion: it's the exact URL whose image
        // a member accepted, and variants could resurrect a rejected sibling.
        var overrideVariants: [String] = []
        if let override = coverOverrideURL?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            overrideVariants = [override]
            list.append(override)
        }
        let trimmedCover = coverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        /// Custom / CDN / Firebase covers — try these before Open Library so we don’t re-hit OL on every navigation.
        let tryNonGooglePrimaryFirst = !trimmedCover.isEmpty && !trimmedCover.contains("books.google.com")

        let primaryVariants = Book.coverURLsToTry(from: coverURL)
        if tryNonGooglePrimaryFirst {
            for v in primaryVariants where !list.contains(v) { list.append(v) }
        }

        if let isbn = isbn {
            for u in Book.openLibraryCoverURLs(isbnDigits: isbn) where !list.contains(u) { list.append(u) }
        }

        if !tryNonGooglePrimaryFirst {
            for v in primaryVariants where !list.contains(v) { list.append(v) }
        }

        for s in fallbackCoverURLs ?? [] {
            let variants = Book.coverURLsToTry(from: s)
            for v in variants where !list.contains(v) { list.append(v) }
        }
        if Self.shouldAppendGoogleIdCoverFallbacks(coverURL: coverURL, bookId: id) {
            let idBased = Book.coverURLsFromBookId(id)
            for v in idBased where !list.contains(v) { list.append(v) }
        }
        if let rejected = coverRejectedURLs, !rejected.isEmpty {
            let banned = Set(rejected)
            list.removeAll { banned.contains($0) && !overrideVariants.contains($0) }
        }
        return list.compactMap { URL(string: $0) }.filter { !$0.absoluteString.isEmpty }
    }

    /// Minimal book used when Firestore is slower than the client budget — UI shows `TitleOnlyBookCover` only (no network covers).
    static func metadataLoadTimeoutPlaceholder(id: String) -> Book {
        var b = Book(
            id: id,
            title: "Book",
            author: "Unknown",
            coverURL: "",
            pageCount: nil,
            publishedDate: nil,
            description: nil,
            genres: []
        )
        b.suppressCoverImageFetch = true
        return b
    }
}

extension Book: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, author, coverURL, pageCount, publishedDate, description, genres, isbn
        case coverOverrideURL, coverRejectedURLs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        author = try c.decode(String.self, forKey: .author)
        coverURL = try c.decode(String.self, forKey: .coverURL)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
        publishedDate = try c.decodeIfPresent(Date.self, forKey: .publishedDate)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        genres = try c.decode([String].self, forKey: .genres)
        isbn = try c.decodeIfPresent(String.self, forKey: .isbn)
        coverOverrideURL = try c.decodeIfPresent(String.self, forKey: .coverOverrideURL)
        coverRejectedURLs = try c.decodeIfPresent([String].self, forKey: .coverRejectedURLs)
        fallbackCoverURLs = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(author, forKey: .author)
        try c.encode(coverURL, forKey: .coverURL)
        try c.encode(pageCount, forKey: .pageCount)
        try c.encode(publishedDate, forKey: .publishedDate)
        try c.encode(description, forKey: .description)
        try c.encode(genres, forKey: .genres)
        try c.encodeIfPresent(isbn, forKey: .isbn)
        try c.encodeIfPresent(coverOverrideURL, forKey: .coverOverrideURL)
        try c.encodeIfPresent(coverRejectedURLs, forKey: .coverRejectedURLs)
    }
}

typealias BookID = String
