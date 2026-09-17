//
//  CoverResolutionStore.swift
//  SPINE
//
//  Remembers, per book, which cover URL actually worked so we never re-run the
//  Open Library → Google Books → iTunes fallback chain once a cover is found.
//  Also remembers definitive failures so the generated placeholder paints
//  immediately instead of re-probing the network on every scroll.
//
//  Persisted as a small JSON file in Application Support. Entries carry a
//  signature of the book's cover inputs (coverURL + ISBN) so editing a book or
//  a metadata refresh invalidates the stale resolution automatically.
//

import Foundation

final class CoverResolutionStore {
    static let shared = CoverResolutionStore()

    /// Persisted failures are retried after this long (network may have been flaky, or a cover was added upstream).
    private static let failureRetryInterval: TimeInterval = 6 * 60 * 60
    /// Transient failures (timeouts, rate-limit backoff windows) retry much sooner —
    /// a scroll burst that trips Open Library's limit shouldn't pin placeholders for
    /// the whole session once the limit resets.
    private static let transientRetryInterval: TimeInterval = 90

    struct Entry: Codable {
        var url: String?
        var failedAt: Date?
        var sig: String
    }

    private let queue = DispatchQueue(label: "com.spine.coverresolution")
    private var entries: [String: Entry]
    /// Books whose chain recently failed, mapped to when they may be retried.
    /// Definitive misses wait hours; transient ones (network, rate limits) only ~90s.
    private var sessionRetryAfter: [String: Date] = [:]
    private var saveScheduled = false

    private init() {
        entries = Self.loadFromDisk()
    }

    /// Signature of everything that feeds cover URL construction. If the book's
    /// cover inputs change, old resolutions/failures no longer apply.
    static func signature(coverURL: String, isbn: String?) -> String {
        "\(coverURL)|\(isbn ?? "")"
    }

    /// The URL that previously loaded successfully for this book, if inputs are unchanged.
    func resolvedURL(bookId: String, signature: String) -> URL? {
        queue.sync {
            guard let e = entries[bookId], e.sig == signature, let s = e.url else { return nil }
            return URL(string: s)
        }
    }

    func lock(bookId: String, signature: String, url: URL) {
        queue.sync {
            entries[bookId] = Entry(url: url.absoluteString, failedAt: nil, sig: signature)
            sessionRetryAfter.removeValue(forKey: bookId + "|" + signature)
            scheduleSave()
        }
    }

    /// Record that the full chain came up empty. `definitive` failures persist across
    /// launches and wait hours to retry; budget/network/rate-limit aborts retry in ~90s.
    func markFailed(bookId: String, signature: String, definitive: Bool) {
        queue.sync {
            let interval = definitive ? Self.failureRetryInterval : Self.transientRetryInterval
            sessionRetryAfter[bookId + "|" + signature] = Date().addingTimeInterval(interval)
            if definitive {
                entries[bookId] = Entry(url: nil, failedAt: Date(), sig: signature)
                scheduleSave()
            }
        }
    }

    /// True when we should show the generated cover without touching the network.
    func hasRecentFailure(bookId: String, signature: String) -> Bool {
        queue.sync {
            if let retryAt = sessionRetryAfter[bookId + "|" + signature], retryAt > Date() { return true }
            guard let e = entries[bookId], e.sig == signature, let failedAt = e.failedAt else { return false }
            return Date().timeIntervalSince(failedAt) < Self.failureRetryInterval
        }
    }

    /// Wipe a recorded failure (persistent and session retry-after) so an explicit
    /// user retry — "Bad cover?" on a title-placeholder book — re-probes immediately.
    func clearFailure(bookId: String, signature: String) {
        queue.sync {
            sessionRetryAfter.removeValue(forKey: bookId + "|" + signature)
            if let e = entries[bookId], e.failedAt != nil {
                entries.removeValue(forKey: bookId)
                scheduleSave()
            }
        }
    }

    /// Drop a resolution that stopped working (e.g. remote image deleted) so the chain re-runs.
    func clear(bookId: String) {
        queue.sync {
            entries.removeValue(forKey: bookId)
            scheduleSave()
        }
    }

    // MARK: - Persistence

    private static func fileURL() -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        // On-disk path: keeps the pre-rename "WellRead" name so existing data is found.
        let folder = dir.appendingPathComponent("WellRead", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("cover-resolutions.json")
    }

    private static func loadFromDisk() -> [String: Entry] {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return decoded
    }

    /// Debounced write — burst of locks during a first library scroll becomes one file write.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self else { return }
            self.saveScheduled = false
            guard let url = Self.fileURL(),
                  let data = try? JSONEncoder().encode(self.entries) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
