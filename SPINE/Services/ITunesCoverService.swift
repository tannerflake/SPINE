//
//  ITunesCoverService.swift
//  SPINE
//
//  Last-resort cover source: Apple's iTunes Search API (no key required).
//  Looks up by ISBN first, then falls back to a title+author search with a
//  loose title match so we don't show the wrong book's cover.
//  artworkUrl100 is rewritten to 600x600 — sharp enough for the largest
//  cover in the app (220pt) without pulling multi-megabyte originals.
//

import Foundation

final class ITunesCoverService {
    static let shared = ITunesCoverService()

    private let session: URLSession
    private let cacheQueue = DispatchQueue(label: "com.spine.itunescovers.cache")
    /// Lookup results (including empty = "iTunes has nothing") cached per key for the session.
    private var resultCache: [String: [URL]] = [:]

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        session = URLSession(configuration: config)
    }

    private struct SearchResponse: Codable {
        let results: [Item]?
    }

    private struct Item: Codable {
        let artworkUrl100: String?
        let trackName: String?
        let collectionName: String?
    }

    /// Candidate artwork URLs for this book (usually 0 or 1). Never throws — a
    /// failed lookup just returns [] and the caller moves on to the placeholder.
    func artworkURLs(isbn: String?, title: String, author: String?) async -> [URL] {
        let cacheKey = "\(isbn ?? "")|\(title)|\(author ?? "")"
        if let cached = cacheQueue.sync(execute: { resultCache[cacheKey] }) { return cached }

        var urls: [URL] = []
        if let isbn = isbn?.filter(\.isNumber), isbn.count == 10 || isbn.count == 13 {
            urls = await lookup(queryItems: [
                URLQueryItem(name: "isbn", value: isbn),
                URLQueryItem(name: "entity", value: "ebook")
            ], matchTitle: nil)
        }
        if urls.isEmpty {
            let term = [title, author ?? ""].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            urls = await lookup(queryItems: [
                URLQueryItem(name: "term", value: term),
                URLQueryItem(name: "media", value: "ebook"),
                URLQueryItem(name: "limit", value: "5")
            ], endpoint: "search", matchTitle: title)
        }
        cacheQueue.async { [weak self] in self?.resultCache[cacheKey] = urls }
        return urls
    }

    private func lookup(queryItems: [URLQueryItem], endpoint: String = "lookup", matchTitle: String?) async -> [URL] {
        var comp = URLComponents(string: "https://itunes.apple.com/\(endpoint)")!
        comp.queryItems = queryItems
        guard let url = comp.url else { return [] }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return [] }
        let items = decoded.results ?? []
        let matched: [Item]
        if let wanted = matchTitle {
            matched = items.filter { titlesRoughlyMatch($0.trackName ?? $0.collectionName ?? "", wanted) }
        } else {
            matched = items
        }
        return matched
            .compactMap { $0.artworkUrl100 }
            .map { $0.replacingOccurrences(of: "100x100", with: "600x600") }
            .compactMap { URL(string: $0) }
    }

    /// Guards the title+author search path against unrelated results: one title
    /// must contain the other after stripping punctuation/subtitles.
    private func titlesRoughlyMatch(_ a: String, _ b: String) -> Bool {
        func normalize(_ s: String) -> String {
            let base = s.split(separator: ":").first.map(String.init) ?? s
            return base.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
                .trimmingCharacters(in: .whitespaces)
        }
        let na = normalize(a)
        let nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na.contains(nb) || nb.contains(na)
    }
}
