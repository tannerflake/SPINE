//
//  UserDirectory.swift
//  WellRead
//
//  Member search is a plain directory lookup, and nothing like book search:
//  no providers, no per-query network calls, no ranking service. The roster is
//  one Firestore read that is then filtered and ranked locally, so this type
//  deliberately shares no machinery with `GoogleBooksService` /
//  `BookSearchCacheService`.
//
//  Retrieval is stale-while-revalidate: the roster is held in memory for the
//  whole app session (the Search tab's view is thrown away every time the user
//  leaves the tab) and on disk between launches, so the list paints instantly
//  and any refresh happens behind it. On a genuinely cold start the people you
//  follow are fetched first — a handful of docs against the roster's hundreds —
//  because those are the rows that sit at the top of the list anyway.
//

import Foundation

@MainActor
final class UserDirectory: ObservableObject {
    static let shared = UserDirectory()

    struct Reader: Identifiable, Equatable {
        let id: String
        let user: User
    }

    /// Everyone we know about, sorted by display name.
    @Published private(set) var readers: [Reader] = []
    /// Readers with something on their Reading Now shelf. A ranking input only
    /// (see `PeopleSimilarity`) — no covers are resolved for it.
    @Published private(set) var readingNowUids: Set<String> = []
    /// True only while there is nothing at all to show. A refresh behind an
    /// already-painted list never puts the spinner back up.
    @Published private(set) var isLoading = false

    /// How long a loaded roster is served before a visit refreshes it.
    private static let refreshInterval: TimeInterval = 5 * 60
    /// Saved rosters older than this are ignored rather than shown.
    private static let maxCacheAge: TimeInterval = 7 * 24 * 60 * 60
    private static let rosterLimit = 1000

    private let repository = UserRepository()
    private let userBookRepository = UserBookRepository()
    private var uid: String?
    private var lastRefreshed: Date?
    private var refreshTask: Task<Void, Never>?

    /// Loads or refreshes the roster for the signed-in user. Cheap enough to
    /// call on every appear: within `refreshInterval` it does nothing at all.
    func warm(uid: String?, following: [String]) {
        if self.uid != uid {
            self.uid = uid
            refreshTask?.cancel()
            refreshTask = nil
            lastRefreshed = nil
            let cached = DirectoryCache.load(uid: uid, maxAge: Self.maxCacheAge)
            readers = cached.readers
            readingNowUids = cached.readingNowUids
        }
        if let last = lastRefreshed, Date().timeIntervalSince(last) < Self.refreshInterval { return }
        guard refreshTask == nil else { return }
        isLoading = readers.isEmpty
        let currentUid = uid
        refreshTask = Task { [weak self] in
            await self?.refresh(uid: currentUid, following: following)
        }
    }

    private func refresh(uid: String?, following: [String]) async {
        // Cold start only: the follow graph is a short `in` query and lands well
        // before the full roster, so the section the user cares about most is
        // already on screen while the rest arrives.
        if readers.isEmpty, !following.isEmpty {
            let followed = await repository.fetchReaderProfiles(uids: following, excludingUid: uid)
            if readers.isEmpty, !followed.isEmpty {
                readers = Self.sorted(followed)
                isLoading = false
            }
        }

        async let rosterFetch = repository.fetchAllReaderProfiles(excludingUid: uid, limit: Self.rosterLimit)
        async let readingNowFetch = userBookRepository.fetchUidsReadingNow()
        let (all, readingNow) = await (rosterFetch, readingNowFetch)
        if !all.isEmpty {
            readers = Self.sorted(all)
            readingNowUids = readingNow
            lastRefreshed = Date()
            DirectoryCache.save(readers, readingNowUids: readingNow, uid: uid)
        }
        isLoading = false
        refreshTask = nil
    }

    private static func sorted(_ rows: [(uid: String, user: User)]) -> [Reader] {
        rows.map { Reader(id: $0.uid, user: $0.user) }
            .sorted { $0.user.displayName.localizedCaseInsensitiveCompare($1.user.displayName) == .orderedAscending }
    }
}

/// The roster on disk, so the first visit after a launch paints without a round
/// trip. Kept in Caches (the app can always rebuild it from Firestore) and out
/// of UserDefaults, which this is far too big for.
private enum DirectoryCache {
    private struct Row: Codable {
        let uid: String
        let user: User
    }

    private struct Payload: Codable {
        let savedAt: Date
        let rows: [Row]
        /// Optional so a payload written before this field existed still decodes.
        var readingNowUids: [String]?
    }

    private static func url(uid: String?) -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("userDirectory-\(uid ?? "anon").json")
    }

    static func load(uid: String?, maxAge: TimeInterval) -> (readers: [UserDirectory.Reader], readingNowUids: Set<String>) {
        guard let url = url(uid: uid),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              Date().timeIntervalSince(payload.savedAt) < maxAge else { return ([], []) }
        return (
            payload.rows.map { UserDirectory.Reader(id: $0.uid, user: $0.user) },
            Set(payload.readingNowUids ?? [])
        )
    }

    static func save(_ readers: [UserDirectory.Reader], readingNowUids: Set<String>, uid: String?) {
        guard let url = url(uid: uid) else { return }
        // Only the fields the roster draws and ranks on are worth persisting.
        // `following` stays: it's what the "people you might know" ordering is
        // computed from (see `PeopleSimilarity`).
        let rows = readers.map { reader -> Row in
            var trimmed = reader.user
            trimmed.readingInterestTags = []
            trimmed.bio = nil
            return Row(uid: reader.id, user: trimmed)
        }
        let payload = Payload(savedAt: Date(), rows: rows, readingNowUids: Array(readingNowUids))
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
