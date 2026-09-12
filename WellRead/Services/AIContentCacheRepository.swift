//
//  AIContentCacheRepository.swift
//  WellRead
//
//  Cross-user Firestore cache for user-independent AI content (summary, tags,
//  quote, about page, refresher), one doc per book in aiBookContent/. Fields
//  fill lazily as each surface is first viewed, so the whole user base pays for
//  generation roughly once per book. See docs/ai-content-caching-strategy.md.
//

import Foundation
import FirebaseFirestore

/// Cached AI fields for one book. Outer `nil` = not generated yet (cache miss).
/// `quote` is doubly optional so a cached "this book has no notable quote"
/// (.some(nil)) is distinct from a miss — otherwise every profile view would
/// retry the LLM forever for books without famous quotes.
struct AIBookContent {
    var summary: String?
    var tags: [String]?
    var quote: String??
    var about: String?
    var refresher: BookRefresher?
}

actor AIContentCacheRepository {
    static let shared = AIContentCacheRepository()

    /// Bump when a cached-content prompt changes materially. Docs written under
    /// an older version read as misses and regenerate lazily; old content keeps
    /// serving until overwritten, so there is no thundering-herd regeneration.
    static let promptVersion = 1

    private let collectionName = "aiBookContent"
    /// Docs fetched this session — the summary/tags/quote calls on one profile
    /// view share a single Firestore read.
    private var docCache: [String: AIBookContent] = [:]
    private var inflight: [String: Task<AIBookContent, Never>] = [:]
    /// Books whose Firestore doc carried an older promptVersion: the first
    /// write replaces the whole doc so stale fields don't masquerade as current.
    private var staleDocs: Set<String> = []

    private init() {}

    private var db: Firestore { FirestoreDatabase.firestore }

    /// Firestore doc ids can't contain "/" (Open Library ids like "OL123M/x" could).
    private func docId(for bookId: String) -> String {
        bookId.replacingOccurrences(of: "/", with: "_")
    }

    /// The cached content for a book. Never throws — a cache problem must never
    /// break content rendering; errors just read as a full miss.
    func content(for bookId: String) async -> AIBookContent {
        if let cached = docCache[bookId] { return cached }
        if let task = inflight[bookId] { return await task.value }
        let task = Task { await self.fetchContent(bookId: bookId) }
        inflight[bookId] = task
        let result = await task.value
        docCache[bookId] = result
        inflight[bookId] = nil
        return result
    }

    private func fetchContent(bookId: String) async -> AIBookContent {
        var content = AIBookContent()
        do {
            let snapshot = try await db.collection(collectionName).document(docId(for: bookId)).getDocument()
            guard snapshot.exists, let data = snapshot.data() else { return content }
            guard (data["promptVersion"] as? Int) == Self.promptVersion else {
                staleDocs.insert(bookId)
                return content
            }
            content.summary = Self.nonEmptyString(data["summary"])
            if let tags = data["tags"] as? [String], !tags.isEmpty { content.tags = tags }
            if data.keys.contains("quote") {
                if data["quote"] is NSNull {
                    content.quote = .some(nil)
                } else if let quote = Self.nonEmptyString(data["quote"]) {
                    content.quote = .some(quote)
                }
            }
            content.about = Self.nonEmptyString(data["about"])
            if let map = data["refresher"] as? [String: Any] {
                content.refresher = Self.decodeRefresher(map)
            }
            return content
        } catch {
            return content
        }
    }

    // MARK: - Writes (fire-and-forget; failures are non-fatal — content still renders this session)

    func storeSummary(_ summary: String, bookId: String, model: String) {
        updateLocal(bookId) { $0.summary = summary }
        write(["summary": summary], bookId: bookId, model: model)
    }

    func storeTags(_ tags: [String], bookId: String, model: String) {
        updateLocal(bookId) { $0.tags = tags }
        write(["tags": tags], bookId: bookId, model: model)
    }

    /// Pass nil to cache "no notable quote" so the miss isn't retried forever.
    func storeQuote(_ quote: String?, bookId: String, model: String) {
        updateLocal(bookId) { $0.quote = .some(quote) }
        write(["quote": quote ?? NSNull()], bookId: bookId, model: model)
    }

    func storeAbout(_ about: String, bookId: String, model: String) {
        updateLocal(bookId) { $0.about = about }
        write(["about": about], bookId: bookId, model: model)
    }

    func storeRefresher(_ refresher: BookRefresher, bookId: String, model: String) {
        guard let map = Self.encodeRefresher(refresher) else { return }
        updateLocal(bookId) { $0.refresher = refresher }
        write(["refresher": map], bookId: bookId, model: model)
    }

    private func updateLocal(_ bookId: String, _ mutate: (inout AIBookContent) -> Void) {
        var entry = docCache[bookId] ?? AIBookContent()
        mutate(&entry)
        docCache[bookId] = entry
    }

    private func write(_ fields: [String: Any], bookId: String, model: String) {
        var payload = fields
        payload["promptVersion"] = Self.promptVersion
        payload["model"] = model
        payload["updatedAt"] = FieldValue.serverTimestamp()
        let replaceWholeDoc = staleDocs.remove(bookId) != nil
        let ref = db.collection(collectionName).document(docId(for: bookId))
        Task {
            do {
                if replaceWholeDoc {
                    try await ref.setData(payload)
                } else {
                    try await ref.setData(payload, merge: true)
                }
            } catch {
                print("AIContentCacheRepository: write for \(bookId) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Refresher <-> Firestore map

    private static func encodeRefresher(_ refresher: BookRefresher) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(refresher),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func decodeRefresher(_ map: [String: Any]) -> BookRefresher? {
        guard JSONSerialization.isValidJSONObject(map),
              var data = try? JSONSerialization.data(withJSONObject: map) else { return nil }
        // Docs cached before the no-dash house rule still hold em dashes; clean
        // them on the way out so old cache entries don't leak one into the UI.
        if let json = String(data: data, encoding: .utf8) {
            data = Data(ClaudeService.stripDashes(json).utf8)
        }
        guard let refresher = try? JSONDecoder().decode(BookRefresher.self, from: data) else { return nil }
        return refresher.plot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : refresher
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        // stripDashes: pre-house-rule cache entries can still carry em dashes.
        let trimmed = ClaudeService.stripDashes(s).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
