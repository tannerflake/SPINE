//
//  MatchScoreService.swift
//  Spine
//
//  Netflix-style "% match" for a book, computed on-device from the user's
//  library (ratings + tiers → nearest-neighbour taste + author affinity), their
//  interest tags, and followed readers' ratings of the book — each friend
//  weighted by how closely their taste has agreed with the user's on books
//  they've both rated. Deterministic weighted-points scorer in the
//  BookSearchRanker style.
//
//  Rebalanced 2026-09-06 against a leave-one-out pass over 16k real rated
//  reads (score each book as if unread, compare to how the reader actually
//  rated it). The original averaged affinity across every genre token the
//  candidate carried, so a loved fantasy novel was dragged toward the reader's
//  lukewarm mean for "fiction", and everything landed in 58–74. Now the
//  library books most *like* the candidate carry the genre signal, a rated
//  book by the same author moves the score a lot, and the range is 10–99.
//

import Foundation

final class MatchScoreService {
    static let shared = MatchScoreService()

    /// Trust weight per followed reader (uid → 0.25…2.0), session-scoped.
    private var trustCache: [String: Double] = [:]
    private let queue = DispatchQueue(label: "com.spine.matchscore.cache")

    private init() {}

    // MARK: - Public API

    /// Percentage match (10–99) for `book`, or `nil` when there's no taste
    /// signal to score against (cold start: no rated/tiered reads, no interest
    /// tags, no followed readers of this book).
    ///
    /// - Parameters:
    ///   - profileTags: AI profile tags for the book (canonical Tags.csv strings); may be empty.
    ///   - library: the current user's full library (`AppState.userBooks`).
    ///   - friendEntries: followed readers' read rows for this book (deduped, self excluded).
    func matchScore(
        for book: Book,
        profileTags: [String],
        library: [UserBook],
        user: User?,
        friendEntries: [UserBook]
    ) async -> Int? {
        let history = library.filter { $0.bookId != book.id && $0.status == .read }
        let ratedHistory = history.filter { affinity(of: $0) != nil }
        let interestTags = Set(
            ((user?.readingInterestTags ?? []) + (user?.discoverCriteria.tags ?? []))
                .map { $0.lowercased() }
        )

        guard ratedHistory.count >= 3 || !interestTags.isEmpty || !friendEntries.isEmpty else {
            return nil
        }

        var points = 50.0
        var hasSignal = false

        // Interest-tag overlap: two or more shared tags is a full-marks match.
        // Secondary to what they've actually read, so it tops out at +10.
        if !interestTags.isEmpty && !profileTags.isEmpty {
            let matches = profileTags.filter { interestTags.contains($0.lowercased()) }.count
            if matches > 0 { hasSignal = true }
            points += min(1.0, Double(matches) / 2.0) * 10.0
        }

        // Taste neighbourhood: how the reader rated the shelf books most like this
        // one. Up to ±34 — an S-tier near-twin alone lifts a book into the 80s.
        if let neighbourhood = tasteNeighbourhood(candidate: book, history: ratedHistory) {
            hasSignal = true
            points += neighbourhood.signal * 34.0 * neighbourhood.confidence
        }

        // Author affinity: the reader has rated this author before. One book is
        // already strong evidence (confidence 0.74), so a lone S-tier adds ~+28.
        let candidateAuthors = authorTokens(book.author)
        var authorValues: [Double] = []
        for entry in ratedHistory {
            guard let entryBook = entry.book, let a = affinity(of: entry) else { continue }
            if !authorTokens(entryBook.author).isDisjoint(with: candidateAuthors) {
                authorValues.append(a)
            }
        }
        if !authorValues.isEmpty {
            hasSignal = true
            let mean = authorValues.reduce(0, +) / Double(authorValues.count)
            let n = Double(authorValues.count)
            let confidence = n / (n + 0.35)
            points += mean * 38.0 * confidence
        }

        // Followed readers' verdicts, trust-weighted by taste agreement.
        let friends = Array(friendEntries.prefix(8))
        var trustSum = 0.0
        var verdictSum = 0.0
        for entry in friends {
            guard let a = affinity(of: entry) else { continue }
            let trust = await trustWeight(friendUid: entry.userId, myHistory: ratedHistory)
            verdictSum += a * trust
            trustSum += trust
        }
        if trustSum > 0 {
            hasSignal = true
            let n = Double(friends.count)
            points += (verdictSum / trustSum) * 15.0 * (n / (n + 2.0))
        }

        #if DEBUG
        let withBook = ratedHistory.filter { $0.book != nil }.count
        let withGenres = ratedHistory.filter { !($0.book?.genres.isEmpty ?? true) }.count
        print("[MatchScoreDiag] \(book.title) | lib=\(library.count) read=\(history.count) rated=\(ratedHistory.count) withBook=\(withBook) withGenres=\(withGenres) | candGenres=\(book.genres) author=\(book.author) | profileTags=\(profileTags) interestTags=\(interestTags.count) | neigh=\(String(describing: tasteNeighbourhood(candidate: book, history: ratedHistory))) authorVals=\(authorValues) friends=\(friends.count) trustSum=\(trustSum) | points=\(points) hasSignal=\(hasSignal)")
        #endif
        guard hasSignal else { return nil }
        return Int(min(99.0, max(10.0, points)).rounded())
    }

    // MARK: - Taste neighbourhood

    /// Genre signal from the shelf books most similar to the candidate, −1…+1,
    /// with a 0…1 confidence.
    ///
    /// Similarity is the share of the candidate's genre tokens a shelf book also
    /// carries, each token weighted by how *rare* it is on this reader's shelf
    /// (log inverse frequency) — so "fiction" on a fiction-heavy shelf counts
    /// for nothing and "epic fantasy" counts for a lot. The signal blends the
    /// reader's broad verdict across everything nearby (40%), their verdict on
    /// the five nearest books (30%), and the single best sim×affinity peak (30%)
    /// so one S-tier near-twin can carry a book on its own.
    private func tasteNeighbourhood(candidate: Book, history: [UserBook]) -> (signal: Double, confidence: Double)? {
        let candidateTokens = genreTokens(candidate.genres)
        guard !candidateTokens.isEmpty else { return nil }

        var frequency: [String: Int] = [:]
        var shelf: [(tokens: Set<String>, affinity: Double)] = []
        for entry in history {
            guard let entryBook = entry.book, let a = affinity(of: entry) else { continue }
            let tokens = genreTokens(entryBook.genres)
            guard !tokens.isEmpty else { continue }
            shelf.append((tokens, a))
            for token in tokens { frequency[token, default: 0] += 1 }
        }
        guard !shelf.isEmpty else { return nil }

        let shelfCount = Double(shelf.count)
        func weight(_ token: String) -> Double {
            log((shelfCount + 1.0) / (Double(frequency[token] ?? 0) + 1.0))
        }
        let denominator = candidateTokens.reduce(0.0) { $0 + weight($1) }
        guard denominator > 0 else { return nil }

        var neighbours: [(similarity: Double, affinity: Double)] = []
        for entry in shelf {
            let shared = candidateTokens.intersection(entry.tokens)
            guard !shared.isEmpty else { continue }
            let similarity = shared.reduce(0.0) { $0 + weight($1) } / denominator
            neighbours.append((similarity, entry.affinity))
        }
        guard !neighbours.isEmpty else { return nil }

        let broadWeight = neighbours.reduce(0.0) { $0 + $1.similarity }
        guard broadWeight > 0 else { return nil }
        let broad = neighbours.reduce(0.0) { $0 + $1.similarity * $1.affinity } / broadWeight

        neighbours.sort { $0.similarity > $1.similarity }
        let nearest = Array(neighbours.prefix(5))
        let nearWeight = nearest.reduce(0.0) { $0 + $1.similarity * $1.similarity }
        guard nearWeight > 0 else { return nil }
        let near = nearest.reduce(0.0) { $0 + $1.similarity * $1.similarity * $1.affinity } / nearWeight
        let peak = max(0.0, nearest.map { $0.similarity * $0.affinity }.max() ?? 0.0)

        let signal = 0.4 * broad + 0.3 * near + 0.3 * peak
        return (signal, min(1.0, nearWeight))
    }

    // MARK: - Trust (taste similarity with a followed reader)

    /// 0.25…2.0 multiplier for a friend's verdict: 1.0 = neutral (no shared
    /// rated books), >1 = their past ratings agreed with the user's, <1 = clashed.
    private func trustWeight(friendUid: String, myHistory: [UserBook]) async -> Double {
        if let cached = queue.sync(execute: { trustCache[friendUid] }) { return cached }

        let friendRows = await UserBookRepository().fetchReadEntriesLite(userId: friendUid)
        var mineByBook: [String: Double] = [:]
        for entry in myHistory {
            if let a = affinity(of: entry) { mineByBook[entry.bookId] = a }
        }

        var agreements: [Double] = []
        for row in friendRows {
            guard let mine = mineByBook[row.bookId], let theirs = affinity(of: row) else { continue }
            agreements.append(1.0 - abs(mine - theirs) / 2.0)
        }

        let trust: Double
        if agreements.isEmpty {
            trust = 1.0
        } else {
            let n = Double(agreements.count)
            let similarity = ((agreements.reduce(0, +) / n) - 0.5) * 2.0 * (n / (n + 2.0))
            trust = min(2.0, max(0.25, 1.0 + similarity))
        }
        queue.sync { trustCache[friendUid] = trust }
        return trust
    }

    // MARK: - Signals

    /// How much the reader liked a book, in −1…+1. Rating (0–10) wins; tier is
    /// the fallback for rated-by-vibe rows. `nil` when the row carries neither.
    private func affinity(of entry: UserBook) -> Double? {
        if let rating = entry.rating {
            return min(1.0, max(-1.0, (rating - 5.5) / 4.5))
        }
        switch entry.tier {
        case "S": return 1.0
        case "A": return 0.6
        case "B": return 0.3
        case "C": return 0.0
        case "D": return -0.5
        case "F": return -1.0
        default: return nil
        }
    }

    /// Tokens that describe marketing, not taste.
    private static let ignoredGenreTokens: Set<String> = [
        "general", "new york times bestseller", "bestseller", "bestsellers",
    ]

    /// Google/publisher categories arrive as "Fiction / Thrillers / Suspense" —
    /// split into comparable lowercase tokens, dropping the meaningless "general".
    private func genreTokens(_ genres: [String]) -> Set<String> {
        var tokens = Set<String>()
        for genre in genres {
            for part in genre.split(separator: "/") {
                let token = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !token.isEmpty && !Self.ignoredGenreTokens.contains(token) { tokens.insert(token) }
            }
        }
        return tokens
    }

    private func authorTokens(_ author: String) -> Set<String> {
        Set(
            author.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }
}
