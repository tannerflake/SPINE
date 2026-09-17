//
//  BookPopularityService.swift
//  SPINE
//
//  Community popularity signal for search ranking: which works have 2+ SPINE
//  members shelved them. Reads `bookStats/` (maintained by the Cloud Functions
//  `onUserBookWritten` trigger; docs keyed by a hash of
//  `BookSearchRanker.popularityKey`), caches the key set in memory for an hour,
//  and never blocks search — a slow or failed fetch just means no boost.
//

import FirebaseFirestore
import Foundation

final class BookPopularityService {
    static let shared = BookPopularityService()

    private let db = FirestoreDatabase.firestore
    private let collection = "bookStats"
    private let minUsers = 2
    /// Backfill (2026-08) found ~1.5k works with 2+ members; leave headroom, and
    /// the count-descending order keeps the most popular if the cap ever binds.
    private let maxKeys = 3000
    private let refreshInterval: TimeInterval = 3600
    /// Search fires this on every query; past this, serve whatever we have.
    private let fetchTimeout: UInt64 = 1_200_000_000

    private let lock = NSLock()
    private var cachedKeys: Set<String> = []
    private var lastFetch: Date?
    private var inflight: Task<Set<String>, Never>?

    private init() {}

    /// Popularity keys of works 2+ members have logged. Serves the cached set
    /// when fresh; otherwise refreshes with a hard timeout, falling back to the
    /// stale/empty set so search latency never depends on this.
    func popularKeys() async -> Set<String> {
        let (fresh, existing, task): (Bool, Set<String>, Task<Set<String>, Never>) = {
            lock.lock()
            defer { lock.unlock() }
            let isFresh = lastFetch.map { Date().timeIntervalSince($0) < refreshInterval } ?? false
            if isFresh || inflight != nil {
                return (isFresh, cachedKeys, inflight ?? Task { [cachedKeys] in cachedKeys })
            }
            let refresh = Task { await self.fetchKeys() }
            inflight = refresh
            return (false, cachedKeys, refresh)
        }()
        if fresh { return existing }
        // Wait for the refresh, but only up to the timeout — a cold start with
        // slow Firestore shouldn't delay results; the next search gets the set.
        let timedOut = await withTaskGroup(of: Set<String>?.self) { group in
            group.addTask { await task.value }
            group.addTask { [fetchTimeout] in
                try? await Task.sleep(nanoseconds: fetchTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return timedOut ?? existing
    }

    private func fetchKeys() async -> Set<String> {
        defer {
            lock.lock()
            inflight = nil
            lock.unlock()
        }
        do {
            let snapshot = try await db.collection(collection)
                .whereField("count", isGreaterThanOrEqualTo: minUsers)
                .order(by: "count", descending: true)
                .limit(to: maxKeys)
                .getDocuments()
            let keys = Set(snapshot.documents.compactMap { $0.data()["key"] as? String }.filter { !$0.isEmpty })
            lock.lock()
            cachedKeys = keys
            lastFetch = Date()
            lock.unlock()
            return keys
        } catch {
            // Keep whatever we had; retry after the normal interval elapses.
            lock.lock()
            let existing = cachedKeys
            lastFetch = Date()
            lock.unlock()
            return existing
        }
    }
}
