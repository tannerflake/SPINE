//
//  BookSearchCacheService.swift
//  WellRead
//
//  Shared, cross-user Firestore cache for book search results. Book metadata is
//  effectively immutable, so once any user's search resolves a query, every other
//  user gets the result without spending Google Books quota (a hard 1,000/day
//  project-wide) or an Open Library round trip.
//

import CryptoKit
import FirebaseFirestore
import Foundation

final class BookSearchCacheService {
    static let shared = BookSearchCacheService()
    // FirestoreDatabase (not Firestore.firestore()): the app's data — and the
    // deployed rules — live on the named "wellread" database; the default
    // database has no rules, so requests there fail silently.
    private var db: Firestore { FirestoreDatabase.firestore }
    private let collection = "bookSearchCache"

    /// ISBNdb/Google-sourced entries carry full metadata and ranking — serve for
    /// a month. Open Library entries (written during API outages) expire fast so
    /// a later search can upgrade the entry.
    private let primaryTTL: TimeInterval = 30 * 24 * 3600
    private let openLibraryTTL: TimeInterval = 24 * 3600

    /// Don't let a slow Firestore round trip delay live search — past this, treat as a miss.
    private let lookupTimeout: UInt64 = 1_200_000_000

    enum Source: String {
        case isbndb
        case google
        case openLibrary = "openlibrary"
    }

    /// Bumped when ranking/filtering changes enough that old entries can be
    /// wrong in ways read-time filtering can't repair (v2: ISBN-implied language
    /// joined the ranking, so a legacy entry may have dedup-merged a foreign
    /// edition over the English one; v3: results are canonicalized against the
    /// community catalog — older entries carry pre-dedup ids and get upgraded
    /// in place on first read; v4: leading-article-insensitive title matching
    /// and companion/merch penalties; v5: bundle/excerpt junk widened and
    /// blank-book merch penalized; v6: edition collapse widened to non-colon
    /// subtitles, audio-format suffixes, and authorless records — pre-current
    /// entries get re-ranked and re-deduped in place on first read). Entries
    /// written before the field exists read as version 1.
    static let currentSchemaVersion = 6

    struct CachedEntry {
        let books: [Book]
        let schemaVersion: Int
        let source: Source
    }

    private init() {}

    /// Doc id is a hash: queries contain slashes/case/length Firestore ids can't take.
    private func docId(for cacheKey: String) -> String {
        SHA256.hash(data: Data(cacheKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Cached books for the key, or nil on miss/expiry/timeout/error. Never throws —
    /// a cache problem must never break search.
    func lookup(cacheKey: String) async -> CachedEntry? {
        await withTaskGroup(of: CachedEntry?.self) { group in
            group.addTask { await self.fetchEntry(cacheKey: cacheKey) }
            group.addTask { [lookupTimeout] in
                try? await Task.sleep(nanoseconds: lookupTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func fetchEntry(cacheKey: String) async -> CachedEntry? {
        let ref = db.collection(collection).document(docId(for: cacheKey))
        // Firestore's persistent cache already holds every entry this device has
        // read or written, but the default read is server-first: a ~200ms round
        // trip even for a doc sitting on disk. Ask the local cache first (a few
        // ms); only a miss or an expired copy pays the network read.
        if let local = try? await ref.getDocument(source: .cache), let entry = entry(from: local) {
            return entry
        }
        guard let snapshot = try? await ref.getDocument() else { return nil }
        return entry(from: snapshot)
    }

    private func entry(from snapshot: DocumentSnapshot) -> CachedEntry? {
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        guard let updated = (data["updatedAt"] as? Timestamp)?.dateValue() else { return nil }
        let source = Source(rawValue: data["source"] as? String ?? "") ?? .openLibrary
        let ttl = source == .openLibrary ? openLibraryTTL : primaryTTL
        guard Date().timeIntervalSince(updated) < ttl else { return nil }
        guard let raw = data["books"] as? [[String: Any]] else { return nil }
        let books = raw.compactMap(book(from:))
        guard !books.isEmpty else { return nil }
        return CachedEntry(books: books, schemaVersion: data["schemaVersion"] as? Int ?? 1, source: source)
    }

    /// Which of `cacheKeys` already have fresh, non-empty entries — one batched
    /// documentID `in` query per 30 keys instead of a read per key. Used by the
    /// Goodreads import to decide which ISBNs actually need the bulk API fetch.
    /// Best-effort: a failed batch just reports its keys as missing (worst case
    /// a redundant API fetch, whose write-through then repairs the entry).
    func freshKeys(cacheKeys: [String]) async -> Set<String> {
        guard !cacheKeys.isEmpty else { return [] }
        var keyByDocId: [String: String] = [:]
        for key in cacheKeys { keyByDocId[docId(for: key)] = key }
        let ids = Array(keyByDocId.keys)
        var fresh: Set<String> = []
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 30, ids.count)])
            start += 30
            guard let snapshot = try? await db.collection(collection)
                .whereField(FieldPath.documentID(), in: chunk)
                .getDocuments() else { continue }
            for doc in snapshot.documents {
                let data = doc.data()
                guard let updated = (data["updatedAt"] as? Timestamp)?.dateValue() else { continue }
                let source = Source(rawValue: data["source"] as? String ?? "") ?? .openLibrary
                let ttl = source == .openLibrary ? openLibraryTTL : primaryTTL
                guard Date().timeIntervalSince(updated) < ttl,
                      let books = data["books"] as? [[String: Any]], !books.isEmpty,
                      let key = keyByDocId[doc.documentID] else { continue }
                fresh.insert(key)
            }
        }
        return fresh
    }

    /// Fire-and-forget write-through after a successful API fetch.
    func store(cacheKey: String, books: [Book], source: Source) {
        guard !books.isEmpty else { return }
        let payload: [String: Any] = [
            "query": String(cacheKey.prefix(200)),
            "source": source.rawValue,
            "schemaVersion": Self.currentSchemaVersion,
            "updatedAt": FieldValue.serverTimestamp(),
            "books": books.prefix(30).map(data(from:))
        ]
        db.collection(collection).document(docId(for: cacheKey)).setData(payload)
    }

    private func data(from book: Book) -> [String: Any] {
        var d: [String: Any] = [
            "id": book.id,
            "title": book.title,
            "author": book.author,
            "coverURL": book.coverURL,
            "genres": book.genres
        ]
        if let v = book.pageCount { d["pageCount"] = v }
        if let v = book.publishedDate { d["publishedDate"] = Timestamp(date: v) }
        if let v = book.description { d["description"] = v }
        if let v = book.isbn { d["isbn"] = v }
        if let v = book.fallbackCoverURLs, !v.isEmpty { d["fallbackCoverURLs"] = v }
        return d
    }

    private func book(from data: [String: Any]) -> Book? {
        guard let id = data["id"] as? String, !id.isEmpty,
              let title = data["title"] as? String, !title.isEmpty else { return nil }
        return Book(
            id: id,
            title: title,
            author: data["author"] as? String ?? "Unknown",
            coverURL: data["coverURL"] as? String ?? "",
            pageCount: data["pageCount"] as? Int,
            publishedDate: (data["publishedDate"] as? Timestamp)?.dateValue(),
            description: data["description"] as? String,
            genres: data["genres"] as? [String] ?? [],
            isbn: data["isbn"] as? String,
            fallbackCoverURLs: data["fallbackCoverURLs"] as? [String]
        )
    }
}
