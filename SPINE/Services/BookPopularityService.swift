//
//  BookPopularityService.swift
//  SPINE
//
//  Community popularity signal for search ranking: which works have 2+ SPINE
//  members shelved them. Reads the one-document `summaries/popularKeys`
//  (maintained by the Cloud Functions `onUserBookWritten` trigger from
//  `bookStats/`, rebuilt nightly; keys are `BookSearchRanker.popularityKey`
//  strings), caches the key set in memory for an hour, and never blocks
//  search — a slow or failed fetch just means no boost. Before 2026-10-05
//  this read up to 3,000 bookStats docs per device per hour.
//

import FirebaseFirestore
import Foundation

final class BookPopularityService {
    static let shared = BookPopularityService()

    private let summaryRef = FirestoreDatabase.firestore.collection("summaries").document("popularKeys")
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
            lock.withLock { inflight = nil }
        }
        do {
            let snapshot = try await summaryRef.getDocument()
            let keys = Set(((snapshot.data()?["keys"] as? [String]) ?? []).filter { !$0.isEmpty })
            lock.withLock {
                cachedKeys = keys
                lastFetch = Date()
            }
            return keys
        } catch {
            // Keep whatever we had; retry after the normal interval elapses.
            let existing = lock.withLock {
                lastFetch = Date()
                return cachedKeys
            }
            return existing
        }
    }
}
