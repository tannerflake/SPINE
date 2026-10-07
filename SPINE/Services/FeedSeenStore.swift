//
//  FeedSeenStore.swift
//  SPINE
//
//  Which feed posts this member has already had on screen, per account, kept
//  on disk. Backs the unified feed's "new for you" run: a followed author's
//  post counts as new until it has scrolled into view once, and a day-group
//  carousel counts as seen the moment its first slide does. Local only (a
//  reinstall starts fresh) so no Firestore write lands per post viewed.
//
//  Entries older than `retention` are dropped on load and the map is capped,
//  so a heavy reader's file never grows without bound.
//
//  Each account's file also carries a `baseline`: the moment the store was
//  first created for it. Everything posted before then counts as seen, so
//  the first launch after this feature (or after a reinstall) starts caught
//  up instead of marching a 800-follow member's entire history to the top.
//

import Foundation

final class FeedSeenStore {
    static let shared = FeedSeenStore()

    /// How long a seen mark is kept. Nothing older than this is eligible for
    /// the "new for you" run anyway (see `FeedItem.freshWindow`).
    static let retention: TimeInterval = 90 * 86400
    static let maxEntries = 4000

    private struct Payload: Codable {
        var baseline: Date
        var seenAt: [String: Date]
    }

    private var uid: String?
    private var seenAt: [String: Date] = [:]
    /// Posts created before this are seen by definition (see the header).
    private(set) var baseline: Date = .distantPast
    private var saveWork: DispatchWorkItem?
    private let diskQueue = DispatchQueue(label: "spine.feedSeenStore", qos: .utility)
    /// `-uiPreview` runs keep marks in memory only, so every preview launch
    /// starts from the same clean state.
    private var inMemoryOnly: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-uiPreview")
        #else
        return false
        #endif
    }

    private init() {}

    /// Switches to `uid`'s file (no-op when already loaded for that account).
    func load(uid: String) {
        guard uid != self.uid else { return }
        flushPendingSave()
        self.uid = uid
        seenAt = [:]
        // Preview runs: the demo feed's posts are all "new" unless a flag
        // seeds them seen.
        baseline = inMemoryOnly ? .distantPast : Date()
        guard !inMemoryOnly, let url = Self.fileURL(uid: uid),
              let data = try? Data(contentsOf: url) else {
            // First time for this account: write the baseline down now so
            // it doesn't move to a later launch.
            if !inMemoryOnly { scheduleSave() }
            return
        }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            baseline = payload.baseline
            seenAt = payload.seenAt.filter { $0.value > cutoff }
        } else if let legacy = try? JSONDecoder().decode([String: Date].self, from: data) {
            // Pre-baseline file (2026-09-26 builds): treat its creation as now.
            seenAt = legacy.filter { $0.value > cutoff }
            scheduleSave()
        }
    }

    func unload() {
        flushPendingSave()
        uid = nil
        seenAt = [:]
        baseline = .distantPast
    }

    func isSeen(_ postId: String) -> Bool {
        seenAt[postId] != nil
    }

    /// Everything seen so far — the feed snapshots this once per session and
    /// lays itself out against the snapshot, so marks landing mid-scroll never
    /// reshuffle posts under the reader.
    func seenIds() -> Set<String> {
        Set(seenAt.keys)
    }

    func markSeen(_ postIds: [String], at date: Date = Date()) {
        guard uid != nil else { return }
        var changed = false
        for id in postIds where seenAt[id] == nil {
            seenAt[id] = date
            changed = true
        }
        guard changed else { return }
        if seenAt.count > Self.maxEntries {
            let keep = seenAt.sorted { $0.value > $1.value }.prefix(Self.maxEntries)
            seenAt = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        scheduleSave()
    }

    #if DEBUG
    /// Preview seeding: pretend these were seen in an earlier session.
    func seedSeen(_ postIds: [String]) {
        for id in postIds { seenAt[id] = Date().addingTimeInterval(-3600) }
    }
    #endif

    // MARK: - Disk

    /// Marks arrive in bursts while scrolling; one write a second is plenty.
    private func scheduleSave() {
        guard !inMemoryOnly else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func flushPendingSave() {
        guard let work = saveWork, !work.isCancelled else { return }
        work.cancel()
        save()
    }

    private func save() {
        guard !inMemoryOnly, let uid, let url = Self.fileURL(uid: uid) else { return }
        let payload = Payload(baseline: baseline, seenAt: seenAt)
        diskQueue.async {
            guard let data = try? JSONEncoder().encode(payload) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func fileURL(uid: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("FeedSeen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = uid.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).json")
    }
}
