//
//  BookRepository.swift
//  SPINE
//
//  Firestore books collection: get or create by Google Books ID. In-memory cache for fast repeat lookups.
//

import Foundation
import FirebaseFirestore

final class BookRepository {
    static let shared = BookRepository()

    private let db = FirestoreDatabase.firestore
    private let books = "books"
    private var memoryCache: [String: Book] = [:]
    private let cacheQueue = DispatchQueue(label: "com.spine.bookrepo.cache")

    /// Prewarm cache with books (e.g. from disk-loaded library) so getBook returns immediately for these ids.
    func prewarmCache(with books: [Book]) {
        cacheQueue.sync {
            for b in books {
                memoryCache[b.id] = b
            }
        }
    }

    /// Clear in-memory cache (e.g. on sign-out). Optional.
    func clearCache() {
        cacheQueue.sync { memoryCache.removeAll() }
    }

    /// Gets a book by id. Checks in-memory cache first, then Firestore (aborts after **2s** and returns a title-only placeholder so lists don’t spin forever).
    func getBook(id: String) async -> Book? {
        if let cached = cacheQueue.sync(execute: { memoryCache[id] }) {
            return cached
        }
        let ref = db.collection(books).document(id)
        enum Race: Sendable {
            case loaded(Book?)
            case timedOut
        }
        return await withTaskGroup(of: Race.self) { group in
            group.addTask { [self] in
                do {
                    let snapshot = try await ref.getDocument()
                    guard snapshot.exists, let data = snapshot.data() else {
                        return .loaded(nil)
                    }
                    // Dedup tombstone: render the canonical doc it was merged into.
                    if data["mergedInto"] is String, let canonical = await resolveMergePointer(in: data) {
                        return .loaded(canonical)
                    }
                    return .loaded(book(from: data, id: id))
                } catch {
                    return .loaded(nil)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return .timedOut
            }
            guard let first = await group.next() else {
                group.cancelAll()
                return nil
            }
            switch first {
            case .timedOut:
                group.cancelAll()
                return Book.metadataLoadTimeoutPlaceholder(id: id)
            case .loaded(let b):
                group.cancelAll()
                if let b {
                    cacheQueue.sync {
                        memoryCache[id] = b
                        memoryCache[b.id] = b
                    }
                    return b
                }
                return nil
            }
        }
    }

    /// Bulk lookup: cache hits return immediately; the rest load through
    /// parallel `in` queries (30 ids each) instead of one round trip per book,
    /// so hydrating a large library costs a couple of queries, not hundreds.
    /// Missing/failed ids are simply absent from the result.
    func getBooks(ids: [String]) async -> [String: Book] {
        var result: [String: Book] = [:]
        var missing: [String] = []
        cacheQueue.sync {
            for id in Set(ids) {
                if let cached = memoryCache[id] {
                    result[id] = cached
                } else {
                    missing.append(id)
                }
            }
        }
        guard !missing.isEmpty else { return result }
        let fetched = await fetchBooksFromFirestore(ids: missing)
        cacheQueue.sync {
            for (requestedId, b) in fetched {
                memoryCache[requestedId] = b
                memoryCache[b.id] = b
            }
        }
        for (requestedId, b) in fetched { result[requestedId] = b }
        return result
    }

    /// Fresh Firestore read for these ids, overwriting the memory cache — the
    /// launch path prewarms the cache from disk and `getBooks` serves it forever,
    /// so book-doc changes (cover overrides, dedup merges, metadata fixes) need
    /// this bypass to ever reach a user who already holds the book locally.
    func refreshBooks(ids: [String]) async -> [String: Book] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }
        let fetched = await fetchBooksFromFirestore(ids: unique)
        cacheQueue.sync {
            for (requestedId, b) in fetched {
                memoryCache[requestedId] = b
                memoryCache[b.id] = b
            }
        }
        var result: [String: Book] = [:]
        for (requestedId, b) in fetched { result[requestedId] = b }
        return result
    }

    /// Batched `in`-query fetch (30 ids per query, in parallel). Pairs of
    /// (requested id, resolved book): a dedup tombstone resolves to the canonical
    /// doc it was merged into, but stays keyed by the id the caller asked for so
    /// old references keep rendering.
    private func fetchBooksFromFirestore(ids missing: [String]) async -> [(String, Book)] {
        let chunks = stride(from: 0, to: missing.count, by: 30).map { Array(missing[$0..<min($0 + 30, missing.count)]) }
        return await withTaskGroup(of: [(String, Book)].self) { group in
            for chunk in chunks {
                group.addTask { [self] in
                    do {
                        let snapshot = try await db.collection(books)
                            .whereField(FieldPath.documentID(), in: chunk)
                            .getDocuments()
                        var pairs: [(String, Book)] = []
                        for doc in snapshot.documents {
                            let data = doc.data()
                            if data["mergedInto"] is String {
                                if let canonical = await resolveMergePointer(in: data) {
                                    pairs.append((doc.documentID, canonical))
                                }
                            } else if let b = book(from: data, id: doc.documentID) {
                                pairs.append((doc.documentID, b))
                            }
                        }
                        return pairs
                    } catch {
                        return []
                    }
                }
            }
            var all: [(String, Book)] = []
            for await pairs in group { all.append(contentsOf: pairs) }
            return all
        }
    }

    /// Resolves `book` to the community's canonical document, creating one only
    /// when no existing doc represents the same work. Book ids are namespaced by
    /// whichever search source produced them (ISBNdb → ISBN, Google → volume id,
    /// Open Library → ISBN/work key), so the same work arrives under different
    /// ids at different times; blind creation is how the catalog grew duplicates.
    /// Resolution order: exact id (following `mergedInto` tombstone pointers left
    /// by dedup merges) → same `isbn13` (same edition, different id namespace) →
    /// same `workKey` (another edition of the same work). Callers must shelve the
    /// returned book's id, not `book.id` — they can differ.
    func ensureCanonicalBook(_ book: Book) async throws -> Book {
        let ref = db.collection(books).document(book.id)
        let snapshot = try await ref.getDocument()
        if snapshot.exists, let data = snapshot.data() {
            if data["mergedInto"] is String, let canonical = await resolveMergePointer(in: data) {
                return canonical
            }
            // Doc predates identity stamping (old client / pre-backfill) — self-heal
            // so future workKey/isbn13 lookups can find it.
            if data["workKey"] == nil {
                let fields = Self.identityFields(for: book)
                if !fields.isEmpty { try? await ref.updateData(fields) }
            }
            return self.book(from: data, id: book.id) ?? book
        }
        if let existing = await findExisting(matching: book) {
            return existing
        }
        var data: [String: Any] = [
            "title": book.title,
            "author": book.author,
            "coverURL": book.coverURL,
            "pageCount": book.pageCount as Any,
            "publishedDate": book.publishedDate.map { Timestamp(date: $0) } as Any,
            "description": book.description as Any,
            "genres": book.genres,
        ]
        if let isbn = book.isbn { data["isbn"] = isbn }
        data.merge(Self.identityFields(for: book)) { _, new in new }
        try await ref.setData(data)
        return book
    }

    // MARK: - Canonical identity

    /// Identity fields stamped on every book doc so `ensureCanonicalBook` can
    /// find it later regardless of which source a future add comes from.
    private static func identityFields(for book: Book) -> [String: Any] {
        var fields: [String: Any] = [:]
        let key = BookSearchRanker.workKey(title: book.title, author: book.author)
        if !key.isEmpty { fields["workKey"] = key }
        if let isbn13 = Book.canonicalISBN13(from: book.isbn) { fields["isbn13"] = isbn13 }
        return fields
    }

    /// Follows a tombstone's `mergedInto` chain (bounded) to the canonical book.
    /// Nil when the chain dead-ends — the caller falls back to the doc it has.
    /// Community docs whose `field` is one of `values`, keyed by that value —
    /// the metadata-richest doc per value, id as the deterministic tie-break
    /// among pre-backfill duplicates. One `in` query per 30 values; merge
    /// pointers (each its own document read) resolve concurrently.
    private func canonicalDocs(field: String, values: [String]) async -> [String: Book] {
        let unique = Array(Set(values))
        guard !unique.isEmpty else { return [:] }
        var hits: [(value: String, data: [String: Any], id: String)] = []
        for start in stride(from: 0, to: unique.count, by: 30) {
            let chunk = Array(unique[start..<min(start + 30, unique.count)])
            guard let snapshot = try? await db.collection(books)
                .whereField(field, in: chunk)
                .getDocuments() else { continue }
            for doc in snapshot.documents {
                let data = doc.data()
                guard let value = data[field] as? String else { continue }
                hits.append((value, data, doc.documentID))
            }
        }
        let resolved: [(value: String, book: Book)] = await withTaskGroup(of: (String, Book)?.self) { group in
            for hit in hits {
                group.addTask {
                    let book: Book? = hit.data["mergedInto"] is String
                        ? await self.resolveMergePointer(in: hit.data)
                        : self.book(from: hit.data, id: hit.id)
                    return book.map { (hit.value, $0) }
                }
            }
            var out: [(String, Book)] = []
            for await item in group {
                if let item { out.append(item) }
            }
            return out
        }
        var best: [String: (book: Book, score: Int)] = [:]
        for (value, b) in resolved {
            let score = Self.metadataScore(b)
            if let current = best[value] {
                if score > current.score || (score == current.score && b.id < current.book.id) {
                    best[value] = (b, score)
                }
            } else {
                best[value] = (b, score)
            }
        }
        return best.mapValues(\.book)
    }

    private func resolveMergePointer(in data: [String: Any]) async -> Book? {
        var target = data["mergedInto"] as? String
        var hops = 0
        while let id = target, hops < 3 {
            guard let snap = try? await db.collection(books).document(id).getDocument(),
                  snap.exists, let d = snap.data() else { return nil }
            if let next = d["mergedInto"] as? String {
                target = next
                hops += 1
                continue
            }
            return book(from: d, id: id)
        }
        return nil
    }

    /// Looks for an existing doc already representing this book: same edition
    /// (`isbn13`) first, then any edition of the same work (`workKey`).
    /// Among several hits (duplicates that predate the backfill) the
    /// metadata-richest wins, with id as the deterministic tie-break, so
    /// concurrent adders converge on the same doc.
    private func findExisting(matching book: Book) async -> Book? {
        var candidates: [Book] = []
        if let isbn13 = Book.canonicalISBN13(from: book.isbn) {
            candidates = await identityQuery(field: "isbn13", value: isbn13)
        }
        if candidates.isEmpty {
            let key = BookSearchRanker.workKey(title: book.title, author: book.author)
            if !key.isEmpty {
                candidates = await identityQuery(field: "workKey", value: key)
            }
        }
        return candidates.min { a, b in
            let (sa, sb) = (Self.metadataScore(a), Self.metadataScore(b))
            return sa != sb ? sa > sb : a.id < b.id
        }
    }

    private func identityQuery(field: String, value: String) async -> [Book] {
        guard let snapshot = try? await db.collection(books)
            .whereField(field, isEqualTo: value)
            .limit(to: 5)
            .getDocuments() else { return [] }
        var out: [Book] = []
        for doc in snapshot.documents {
            let data = doc.data()
            let resolved: Book?
            if data["mergedInto"] is String {
                resolved = await resolveMergePointer(in: data)
            } else {
                resolved = book(from: data, id: doc.documentID)
            }
            if let b = resolved, !out.contains(where: { $0.id == b.id }) {
                out.append(b)
            }
        }
        return out
    }

    private static func metadataScore(_ b: Book) -> Int {
        var s = 0
        if !b.coverURL.isEmpty { s += 4 }
        if b.isbn != nil { s += 2 }
        if !(b.description ?? "").isEmpty { s += 2 }
        if b.pageCount != nil { s += 1 }
        if !b.genres.isEmpty { s += 1 }
        return s
    }

    /// Swaps search results for the community's canonical docs, so the book a
    /// user opens from search already carries the id their friends' reviews and
    /// discussions live on (instead of only converging at add time). Batched:
    /// one `in` query per 30 isbn13s plus one per 30 workKeys of the rest —
    /// never a query per result. Results with no community doc pass through
    /// unchanged; two results collapsing onto one canonical doc keep only the
    /// first (higher-ranked) occurrence.
    func canonicalizeSearchResults(_ results: [Book]) async -> [Book] {
        guard !results.isEmpty else { return results }

        let isbn13s = results.compactMap { Book.canonicalISBN13(from: $0.isbn) }
        let workKeys = results
            .map { BookSearchRanker.workKey(title: $0.title, author: $0.author) }
            .filter { !$0.isEmpty }
        // Both identity lookups at once. They used to run in sequence (workKeys
        // only for the ISBN misses), which put two Firestore round trips between
        // the ranker finishing and the first paint; asking workKeys for every
        // result costs a handful of extra document reads and halves the wait.
        async let byISBN = canonicalDocs(field: "isbn13", values: isbn13s)
        async let byKey = canonicalDocs(field: "workKey", values: workKeys)
        let (canonicalByISBN, canonicalByKey) = await (byISBN, byKey)
        guard !canonicalByISBN.isEmpty || !canonicalByKey.isEmpty else { return results }

        var seenIds = Set<String>()
        var out: [Book] = []
        for result in results {
            let canonical = Book.canonicalISBN13(from: result.isbn).flatMap { canonicalByISBN[$0] }
                ?? canonicalByKey[BookSearchRanker.workKey(title: result.title, author: result.author)]
            let chosen = canonical ?? result
            if seenIds.insert(chosen.id).inserted {
                out.append(chosen)
            }
        }
        return out
    }
}

extension BookRepository {
    fileprivate func book(from data: [String: Any], id: String) -> Book? {
        guard let title = data["title"] as? String,
              let author = data["author"] as? String,
              let coverURL = data["coverURL"] as? String else { return nil }
        let pageCount = data["pageCount"] as? Int
        var publishedDate: Date?
        if let ts = data["publishedDate"] as? Timestamp {
            publishedDate = ts.dateValue()
        }
        var b = Book(
            id: id,
            title: title,
            author: author,
            coverURL: coverURL,
            pageCount: pageCount,
            publishedDate: publishedDate,
            description: data["description"] as? String,
            genres: data["genres"] as? [String] ?? [],
            isbn: data["isbn"] as? String
        )
        b.coverOverrideURL = data["coverOverrideURL"] as? String
        b.coverRejectedURLs = data["coverRejectedURLs"] as? [String]
        return b
    }
}
