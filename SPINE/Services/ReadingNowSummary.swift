//
//  ReadingNowSummary.swift
//  Spine
//
//  The `summaries/readingNow` document: every member's "Reading now" covers,
//  written by the Cloud Functions userBooks trigger (and rebuilt nightly by
//  `rebuildSummaries`). One document read answers what the people strip, the
//  feed's author covers, member search and the widget each used to answer by
//  scanning every reading-now row in the database — the single largest
//  Firestore read cost in the app before 2026-10-05.
//
//  Shape: `byUid.{uid} = [{ bookId, title, author, coverURL }]` in shelf order,
//  capped at a few covers per reader (mirrors `readingNowEntries` in
//  functions/src/index.ts). The books are built as lightweight `Book` values;
//  anything that needs the full document (a book profile) fetches it by id.
//

import FirebaseFirestore
import Foundation

final class ReadingNowSummary {
    static let shared = ReadingNowSummary()

    private let db = FirestoreDatabase.firestore
    /// Several surfaces ask at launch within the same second; serve one fetch.
    private let memoTTL: TimeInterval = 60

    private let lock = NSLock()
    private var memo: [String: [Book]] = [:]
    private var memoAt: Date?
    private var inflight: Task<[String: [Book]], Never>?

    private init() {}

    /// uid → reading-now books in shelf order. Readers with nothing on the
    /// shelf are absent. Empty on failure (callers treat that as "no covers").
    func byUid(maxAge: TimeInterval? = nil) async -> [String: [Book]] {
        let ttl = maxAge ?? memoTTL
        let task: Task<[String: [Book]], Never> = lock.withLock {
            if let at = memoAt, Date().timeIntervalSince(at) < ttl {
                let cached = memo
                return Task { cached }
            }
            if let inflight { return inflight }
            let t = Task { await self.fetch() }
            inflight = t
            return t
        }
        return await task.value
    }

    /// Drops the memo so the next call refetches (pull to refresh).
    func invalidate() {
        lock.withLock { memoAt = nil }
    }

    private func fetch() async -> [String: [Book]] {
        defer { lock.withLock { inflight = nil } }
        do {
            let snapshot = try await db.collection("summaries").document("readingNow").getDocument()
            let byUidRaw = snapshot.data()?["byUid"] as? [String: Any] ?? [:]
            var result: [String: [Book]] = [:]
            for (uid, value) in byUidRaw {
                guard let entries = value as? [[String: Any]] else { continue }
                let books = entries.compactMap { entry -> Book? in
                    guard let id = entry["bookId"] as? String, !id.isEmpty else { return nil }
                    return Book(
                        id: id,
                        title: (entry["title"] as? String) ?? "",
                        author: (entry["author"] as? String) ?? "",
                        coverURL: (entry["coverURL"] as? String) ?? "",
                        pageCount: nil,
                        publishedDate: nil,
                        description: nil,
                        genres: []
                    )
                }
                if !books.isEmpty { result[uid] = books }
            }
            lock.withLock {
                memo = result
                memoAt = Date()
            }
            return result
        } catch {
            // Keep the previous answer if there was one; never block the UI on this.
            return lock.withLock { memo }
        }
    }
}
