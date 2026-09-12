//
//  BookBlendService.swift
//  Spine
//
//  Book Blend: Firestore repo (request / decline / accept) plus the engine that
//  merges two libraries into a stored result. Generation runs on the requester's
//  device at request time, assuming acceptance, and parks the result on the
//  pending doc, so accepting is a status flip instead of a wait. Scoring is a
//  deterministic weighted blend (shared shelf, rating agreement, genre overlap —
//  MatchScoreService style); Claude writes the archetype, insights, and rec
//  reasons on top. Everything lands on the pair doc so rewatch is a read.
//

import Foundation
import FirebaseFirestore

final class BookBlendService {
    static let shared = BookBlendService()

    private let db = FirestoreDatabase.firestore
    private let collectionName = "bookBlends"
    private let userBookRepo = UserBookRepository()
    private let userRepo = UserRepository()

    private init() {}

    /// Books that should never surface as a Book Blend rec regardless of source
    /// or path (deterministic fallback or AI). Matched by bookId first, then
    /// normalized title+author so an AI-hallucinated rec with no bookId still
    /// gets caught. Currently: "Conscience of a Conservative" (Jeff Flake) and
    /// "The Diversity Delusion" (Heather Mac Donald) — both kept showing up as
    /// recs off @tan's shelf; Tanner asked they never be recommended off his blends.
    private static let excludedRecBookIds: Set<String> = ["9780399592928", "UppLDwAAQBAJ"]
    private static let excludedRecKeys: Set<String> = ["conscienceofaconservative|flake", "thediversitydelusion|donald"]

    private func isExcludedFromRecs(bookId: String?, title: String, author: String) -> Bool {
        if let bookId, Self.excludedRecBookIds.contains(bookId) { return true }
        let probe = Book(id: "", title: title, author: author, coverURL: "", pageCount: nil, publishedDate: nil, description: nil, genres: [])
        if let key = normalizedKey(probe), Self.excludedRecKeys.contains(key) { return true }
        return false
    }

    private func filterExcludedRecs(_ recs: [BookBlend.Rec]) -> [BookBlend.Rec] {
        recs.filter { !isExcludedFromRecs(bookId: $0.bookId, title: $0.title, author: $0.author) }
    }

    // MARK: - Repo

    /// `isFromCache` is true for snapshots served from local persistence — callers
    /// that route UI off blend state should wait for (or correct to) server truth.
    /// Metadata changes are included so the server-confirmed snapshot always
    /// delivers, even when its data matches the cached one.
    func listenBlend(pairId: String, onUpdate: @escaping (BookBlend?, _ isFromCache: Bool) -> Void) -> ListenerRegistration {
        db.collection(collectionName).document(pairId).addSnapshotListener(includeMetadataChanges: true) { snapshot, _ in
            guard let snapshot else { return }
            let blend = snapshot.data().flatMap { BookBlend.from(data: $0, docId: snapshot.documentID) }
            let fromCache = snapshot.metadata.isFromCache
            DispatchQueue.main.async { onUpdate(blend, fromCache) }
        }
    }

    func fetchBlend(pairId: String) async -> BookBlend? {
        guard let snapshot = try? await db.collection(collectionName).document(pairId).getDocument(),
              let data = snapshot.data() else { return nil }
        return BookBlend.from(data: data, docId: snapshot.documentID)
    }

    /// Pending invites aimed at me — drives the launch invite modal. Fetches all my
    /// pair docs (a handful at most; `array-contains` keeps the rules query provable)
    /// and filters to pending ones where I'm the recipient, newest first.
    func fetchIncomingPendingBlends(myUid: String) async -> [BookBlend] {
        guard let snapshot = try? await db.collection(collectionName)
            .whereField("userIds", arrayContains: myUid)
            .getDocuments() else { return [] }
        return snapshot.documents
            .compactMap { BookBlend.from(data: $0.data(), docId: $0.documentID) }
            .filter { $0.status == .pending && $0.recipientId == myUid }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Creates (or re-opens a declined) pair doc as pending. The Cloud Function on
    /// this write pushes the blend invite to the recipient.
    func requestBlend(myUid: String, me: User?, otherUid: String, other: User?) async throws -> BookBlend {
        let pairId = BookBlend.pairId(myUid, otherUid)
        var participants: [String: BookBlend.Participant] = [:]
        participants[myUid] = participant(from: me)
        participants[otherUid] = participant(from: other)
        let blend = BookBlend(
            id: pairId,
            userIds: [myUid, otherUid].sorted(),
            requesterId: myUid,
            recipientId: otherUid,
            status: .pending,
            createdAt: Date(),
            respondedAt: nil,
            participants: participants,
            result: nil
        )
        try await db.collection(collectionName).document(pairId).setData(blend.firestoreData)
        // Build the blend now, on the requester's device, assuming the other
        // reader says yes: the result is parked on the still-pending doc so
        // their "Let's Blend" tap reveals instead of waiting on generation.
        // Fire-and-forget: if it fails or never finishes, the accepter's device
        // generates the way it always did.
        Task { await self.precomputeForPendingRequest(blend, requesterUid: myUid) }
        return blend
    }

    /// Requester withdraws a pending request: deletes the pair doc. The Cloud
    /// Function reacts with a silent push that clears the invite alert from the
    /// recipient's Notification Center. Re-checked against the server first so
    /// a request the recipient already accepted (or declined) is left alone.
    func cancelRequest(_ blend: BookBlend, myUid: String) async throws {
        guard blend.requesterId == myUid else { return }
        if let latest = await fetchBlend(pairId: blend.id), latest.status != .pending { return }
        try await db.collection(collectionName).document(blend.id).delete()
    }

    func decline(_ blend: BookBlend) async throws {
        try await db.collection(collectionName).document(blend.id).updateData([
            "status": BookBlendStatus.declined.rawValue,
            "respondedAt": Timestamp(date: Date()),
        ])
    }

    private func participant(from user: User?) -> BookBlend.Participant {
        let first: String
        if let fn = user?.firstName?.trimmingCharacters(in: .whitespacesAndNewlines), !fn.isEmpty {
            first = fn
        } else {
            first = user?.displayName.split(separator: " ").first.map(String.init) ?? "Reader"
        }
        return BookBlend.Participant(firstName: first, photoURL: user?.profileImageURL, readCount: 0)
    }

    // MARK: - Generate

    /// How long a precomputed result (written by the requester's device at
    /// request time) stays usable. Past this the accepter regenerates so the
    /// blend reflects books either reader shelved since the request.
    private static let precomputedResultTTL: TimeInterval = 3 * 24 * 60 * 60

    /// Accept path. A fresh precomputed result on the pending doc makes this a
    /// single field write — the accepter never waits on generation. Otherwise it
    /// falls back to generating here, as before.
    func generateAndSave(_ blend: BookBlend, accepterUid: String) async throws -> BookBlend {
        if let ready = try await promotePrecomputed(blend) { return ready }
        return try await generate(blend, generatorUid: accepterUid, finalStatus: .ready)
    }

    /// Requester-side precompute, fired right after a request lands. Leaves the
    /// doc `pending` (so the recipient still sees the invite, and the Cloud
    /// Function stays quiet — it ignores writes that don't change status).
    func precomputeForPendingRequest(_ blend: BookBlend, requesterUid: String) async {
        _ = try? await generate(blend, generatorUid: requesterUid, finalStatus: .pending)
    }

    /// Flips a pending doc that already carries a fresh result straight to
    /// `ready`, which fires the "your blend is ready" push to the requester.
    /// Returns nil when there's nothing usable parked and we have to generate.
    private func promotePrecomputed(_ blend: BookBlend) async throws -> BookBlend? {
        guard let latest = await fetchBlend(pairId: blend.id),
              latest.status == .pending,
              let result = latest.result,
              Date().timeIntervalSince(result.generatedAt) < Self.precomputedResultTTL
        else { return nil }
        let respondedAt = Date()
        try await db.collection(collectionName).document(blend.id).updateData([
            "status": BookBlendStatus.ready.rawValue,
            "respondedAt": Timestamp(date: respondedAt),
        ])
        var ready = latest
        ready.status = .ready
        ready.respondedAt = respondedAt
        return ready
    }

    /// Fetches both libraries and computes the blend. `finalStatus` decides the
    /// write: `.ready` saves the whole doc and flips it (the accept path), while
    /// `.pending` parks just the result + participants on the open request.
    private func generate(_ blend: BookBlend, generatorUid: String, finalStatus: BookBlendStatus) async throws -> BookBlend {
        let otherUid = blend.otherUserId(from: generatorUid)

        async let mineTask = userBookRepo.fetchUserBooks(userId: generatorUid)
        async let theirsTask = userBookRepo.fetchUserBooks(userId: otherUid)
        async let meTask = userRepo.getUser(uid: generatorUid)
        async let otherTask = userRepo.getUser(uid: otherUid)
        let (mine, theirs, me, other) = await (mineTask, theirsTask, meTask, otherTask)

        let myReads = mine.filter { $0.status == .read }
        let theirReads = theirs.filter { $0.status == .read }

        var participants = blend.participants
        participants[generatorUid] = {
            var p = participant(from: me)
            p.readCount = myReads.count
            return p
        }()
        participants[otherUid] = {
            var p = participant(from: other)
            p.readCount = theirReads.count
            return p
        }()

        let myName = participants[generatorUid]?.firstName ?? "Reader"
        let otherName = participants[otherUid]?.firstName ?? "Reader"

        let stats = computeStats(
            uidA: generatorUid, readsA: myReads,
            uidB: otherUid, readsB: theirReads
        )

        var result = fallbackResult(
            stats: stats,
            uidA: generatorUid, nameA: myName, readsA: myReads, queueA: mine.filter { $0.status == .wantToRead },
            uidB: otherUid, nameB: otherName, readsB: theirReads,
            generatedBy: generatorUid
        )

        if let ai = await aiLayer(
            stats: stats,
            uidA: generatorUid, nameA: myName, libraryA: mine,
            uidB: otherUid, nameB: otherName, libraryB: theirs
        ) {
            result.archetype = ai.archetype
            result.archetypeEmoji = ai.archetypeEmoji
            result.tagline = ai.tagline
            if !ai.insights.isEmpty { result.insights = ai.insights }
            if let recsA = ai.recs[generatorUid], !recsA.isEmpty { result.recs[generatorUid] = recsA }
            if let recsB = ai.recs[otherUid], !recsB.isEmpty { result.recs[otherUid] = recsB }
            if !ai.freshPicks.isEmpty { result.freshPicks = ai.freshPicks }
        }

        result.recs[generatorUid] = filterExcludedRecs(hydrate(recs: result.recs[generatorUid] ?? [], fromShelfOf: theirReads, sourceUid: otherUid))
        result.recs[otherUid] = filterExcludedRecs(hydrate(recs: result.recs[otherUid] ?? [], fromShelfOf: myReads, sourceUid: generatorUid))
        // "Neither of you has read": drop anything on either shelf (read or in
        // progress) before and after cover resolution — the AI only sees each
        // reader's top 35 titles, so it happily picks a book from further down.
        let shelved = (mine + theirs).filter { $0.status != .wantToRead }
        let freshCandidates = filterAlreadyShelved(filterExcludedRecs(result.freshPicks), shelved: shelved)
        result.freshPicks = Array(filterAlreadyShelved(await hydrateFreshPicks(freshCandidates), shelved: shelved).prefix(2))

        var saved = blend
        saved.participants = participants
        saved.result = result

        if finalStatus == .pending {
            // Precompute: re-check the server first so a request the recipient
            // already accepted or declined keeps its own write, and only touch
            // the two fields we generated.
            guard let latest = await fetchBlend(pairId: blend.id), latest.status == .pending else { return blend }
            let data = saved.firestoreData
            try await db.collection(collectionName).document(blend.id).updateData([
                "participants": data["participants"] ?? [:],
                "result": data["result"] ?? NSNull(),
            ])
            return saved
        }

        saved.status = .ready
        saved.respondedAt = Date()
        try await db.collection(collectionName).document(blend.id).setData(saved.firestoreData)
        return saved
    }

    // MARK: - Deterministic layer

    private struct BlendStats {
        var score: Int
        var verdict: String
        var sharedBooks: [BookBlend.SharedBook]
        var sharedGenres: [String]
        var distinctGenres: [String: [String]]
        /// 0…1 rating agreement across shared rated books; nil when none shared.
        var agreement: Double?
    }

    private func computeStats(uidA: String, readsA: [UserBook], uidB: String, readsB: [UserBook]) -> BlendStats {
        // Shared shelf — match by bookId or normalized title+author (Goodreads
        // imports and Google Books often give the same book different ids).
        var aByBookId: [String: UserBook] = [:]
        var aByKey: [String: UserBook] = [:]
        for entry in readsA {
            aByBookId[entry.bookId] = entry
            if let key = normalizedKey(entry.book) { aByKey[key] = entry }
        }

        var shared: [BookBlend.SharedBook] = []
        var seenA = Set<UUID>()
        for entryB in readsB {
            let match: UserBook?
            if let m = aByBookId[entryB.bookId] {
                match = m
            } else if let key = normalizedKey(entryB.book), let m = aByKey[key] {
                match = m
            } else {
                match = nil
            }
            guard let entryA = match, !seenA.contains(entryA.id) else { continue }
            seenA.insert(entryA.id)
            let book = [entryA.book, entryB.book].compactMap { $0 }.first { !$0.coverURL.isEmpty }
                ?? entryA.book ?? entryB.book
            var ratings: [String: Double] = [:]
            var tiers: [String: String] = [:]
            if let r = entryA.rating { ratings[uidA] = r }
            if let r = entryB.rating { ratings[uidB] = r }
            if let t = entryA.tier { tiers[uidA] = t }
            if let t = entryB.tier { tiers[uidB] = t }
            shared.append(BookBlend.SharedBook(
                bookId: book?.id ?? entryA.bookId,
                title: book?.title ?? "Untitled",
                author: book?.author ?? "",
                coverURL: book?.coverURL ?? "",
                ratings: ratings,
                tiers: tiers
            ))
        }
        // Most-loved first: highest combined affinity leads the story page.
        shared.sort { combinedAffinity($0, uidA: uidA, uidB: uidB) > combinedAffinity($1, uidA: uidA, uidB: uidB) }

        // Rating agreement on the shared shelf.
        var agreements: [Double] = []
        for book in shared {
            guard let a = sharedAffinity(book, uid: uidA), let b = sharedAffinity(book, uid: uidB) else { continue }
            agreements.append(1.0 - abs(a - b) / 2.0)
        }
        let agreement = agreements.isEmpty ? nil : agreements.reduce(0, +) / Double(agreements.count)

        // Genre fingerprints.
        let genresA = genreCounts(readsA)
        let genresB = genreCounts(readsB)
        let setA = Set(genresA.keys), setB = Set(genresB.keys)
        let intersection = setA.intersection(setB)

        let sharedGenres = intersection
            .sorted { (genresA[$0]! + genresB[$0]!) > (genresA[$1]! + genresB[$1]!) }
            .prefix(6).map { $0.capitalized }
        let distinctA = setA.subtracting(setB)
            .sorted { genresA[$0]! > genresA[$1]! }
            .prefix(4).map { $0.capitalized }
        let distinctB = setB.subtracting(setA)
            .sorted { genresB[$0]! > genresB[$1]! }
            .prefix(4).map { $0.capitalized }

        // Score: genre kinship + shared-shelf size + rating agreement → 8…99.
        //
        // Calibrated against the first 72 real blends (2026-09-01), which the
        // previous formula squeezed into 40–87 with a median of 55: set-Jaccard
        // on genre tokens never cleared 0.25, rating agreement lived in 0.6–1.0
        // because readers mostly like what they finish, and full overlap marks
        // needed a quarter of the smaller shelf. Each signal is now measured
        // where real pairs actually differ and stretched so the ends are reachable.
        let minLib = Double(min(readsA.count, readsB.count))

        // Genre kinship: cosine of sqrt-damped genre-count fingerprints. Damping
        // keeps "fiction" from dominating; ~0.3 is a typical pair, 0.65+ twins.
        let genreCosine = Self.dampedCosine(genresA, genresB)
        let genreScore = Self.unit((genreCosine - 0.15) / 0.50)

        // Shared shelf: full marks at 12% of the smaller shelf (floor 3), concave
        // so the first few shared books count for the most.
        let overlapScore = minLib < 1
            ? 0.0
            : Self.unit(Double(shared.count) / max(3.0, minLib * 0.12)).squareRoot()

        // Rating agreement: 0.60…0.95 observed → 0…1, shrunk toward neutral when
        // only a book or two is rated by both.
        let agreementScore: Double
        if let agreement, !agreements.isEmpty {
            let n = Double(agreements.count)
            let confidence = n / (n + 2.0)
            agreementScore = 0.5 + (Self.unit((agreement - 0.60) / 0.35) - 0.5) * confidence
        } else {
            agreementScore = 0.5
        }

        let raw = 0.40 * genreScore + 0.32 * overlapScore + 0.28 * agreementScore
        let stretched = Self.unit((raw - 0.12) / 0.72)
        var score = 8.0 + 91.0 * stretched
        // Tiny shelves carry little signal: pull toward a modest middle.
        let shelfConfidence = Self.unit(minLib / 12.0)
        score = 38.0 + (score - 38.0) * shelfConfidence
        let scoreInt = Int(score.rounded())

        return BlendStats(
            score: scoreInt,
            verdict: Self.verdict(for: scoreInt),
            sharedBooks: Array(shared.prefix(12)),
            sharedGenres: Array(sharedGenres),
            distinctGenres: [uidA: Array(distinctA), uidB: Array(distinctB)],
            agreement: agreement
        )
    }

    static func verdict(for score: Int) -> String {
        switch score {
        case 85...: return "Shelf Soulmates"
        case 70..<85: return "Same Chapter"
        case 55..<70: return "Plot Compatible"
        case 38..<55: return "Cross-Genre Chemistry"
        default: return "Opposite Shelves"
        }
    }

    private static func unit(_ x: Double) -> Double { min(1.0, max(0.0, x)) }

    /// Cosine similarity between two genre-count fingerprints after sqrt-damping
    /// each count, so a shelf that is 80% "fiction" still gets compared on its
    /// subgenres rather than on the one token everybody shares.
    private static func dampedCosine(_ a: [String: Int], _ b: [String: Int]) -> Double {
        var dot = 0.0
        for (token, countA) in a {
            guard let countB = b[token] else { continue }
            dot += Double(countA * countB).squareRoot()
        }
        let normA = Double(a.values.reduce(0, +)).squareRoot()
        let normB = Double(b.values.reduce(0, +)).squareRoot()
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA * normB)
    }

    /// How much a reader liked a book, −1…+1 (rating first, tier fallback) —
    /// same mapping as MatchScoreService.affinity.
    private func affinity(rating: Double?, tier: String?) -> Double? {
        if let rating { return min(1.0, max(-1.0, (rating - 5.5) / 4.5)) }
        switch tier {
        case "S": return 1.0
        case "A": return 0.6
        case "B": return 0.3
        case "C": return 0.0
        case "D": return -0.5
        case "F": return -1.0
        default: return nil
        }
    }

    private func sharedAffinity(_ book: BookBlend.SharedBook, uid: String) -> Double? {
        affinity(rating: book.ratings[uid], tier: book.tiers[uid])
    }

    private func combinedAffinity(_ book: BookBlend.SharedBook, uidA: String, uidB: String) -> Double {
        (sharedAffinity(book, uid: uidA) ?? 0) + (sharedAffinity(book, uid: uidB) ?? 0)
    }

    private func normalizedKey(_ book: Book?) -> String? {
        guard let book else { return nil }
        let title = book.title
            .split(separator: ":").first.map(String.init) ?? book.title
        let cleanTitle = title.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !cleanTitle.isEmpty else { return nil }
        let authorLast = book.author
            .split(separator: ",").first.map(String.init)?
            .split(separator: " ").last.map(String.init)?.lowercased() ?? ""
        return "\(cleanTitle)|\(authorLast)"
    }

    /// Tokens that describe marketing, not taste.
    private static let ignoredGenreTokens: Set<String> = [
        "general", "new york times bestseller", "bestseller", "bestsellers",
    ]

    /// Genre token → occurrence count across a shelf ("Fiction / Thrillers" splits
    /// into comparable tokens, dropping "general" — BookSearchRanker style).
    private func genreCounts(_ reads: [UserBook]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entry in reads {
            guard let genres = entry.book?.genres else { continue }
            var tokens = Set<String>()
            for genre in genres {
                for part in genre.split(separator: "/") {
                    let token = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if !token.isEmpty && !Self.ignoredGenreTokens.contains(token) { tokens.insert(token) }
                }
            }
            for token in tokens { counts[token, default: 0] += 1 }
        }
        return counts
    }

    // MARK: - Fallback content (used whole when Claude is unavailable)

    private func fallbackResult(
        stats: BlendStats,
        uidA: String, nameA: String, readsA: [UserBook], queueA: [UserBook],
        uidB: String, nameB: String, readsB: [UserBook],
        generatedBy: String
    ) -> BookBlend.Result {
        var insights: [BookBlend.Insight] = []
        if let top = stats.sharedBooks.first {
            insights.append(.init(
                title: "Common ground",
                body: "You've both read \(top.title), and \(stats.sharedBooks.count == 1 ? "that's where the overlap starts" : "\(stats.sharedBooks.count - 1) more besides")."
            ))
        }
        if let firstShared = stats.sharedGenres.first {
            insights.append(.init(
                title: "Shared wavelength",
                body: "\(firstShared) is the backbone of this blend. It shows up all over both shelves."
            ))
        }
        if let bringA = stats.distinctGenres[uidA]?.first, let bringB = stats.distinctGenres[uidB]?.first {
            insights.append(.init(
                title: "Trade routes",
                body: "\(nameA) brings the \(bringA.lowercased()), \(nameB) brings the \(bringB.lowercased()). That's the fun part."
            ))
        }
        if insights.isEmpty {
            insights.append(.init(
                title: "Blank page",
                body: "Not much overlap yet, which means everything's a recommendation waiting to happen."
            ))
        }

        return BookBlend.Result(
            score: stats.score,
            verdict: stats.verdict,
            archetype: stats.verdict,
            archetypeEmoji: "📚",
            tagline: "Two shelves, one story.",
            sharedBooks: stats.sharedBooks,
            sharedGenres: stats.sharedGenres,
            distinctGenres: stats.distinctGenres,
            insights: insights,
            recs: [
                uidA: topShelfRecs(for: readsA, from: readsB, otherName: nameB, sourceUid: uidB),
                uidB: topShelfRecs(for: readsB, from: readsA, otherName: nameA, sourceUid: uidA),
            ],
            freshPicks: [],
            generatedAt: Date(),
            generatedBy: generatedBy
        )
    }

    /// The other reader's well-liked books the target hasn't read, ranked by how
    /// well each one fits the *target's* genre profile (not just how much the
    /// source loved it). Sorting on source affinity alone handed every blend
    /// partner the same three books off a big shelf; weighting by the target's
    /// own genre mix makes the fallback picks differ per pair.
    private func topShelfRecs(for target: [UserBook], from source: [UserBook], otherName: String, sourceUid: String) -> [BookBlend.Rec] {
        let targetIds = Set(target.map(\.bookId))
        let targetKeys = Set(target.compactMap { normalizedKey($0.book) })
        let targetGenres = genreCounts(target)
        let targetGenreTotal = Double(max(1, targetGenres.values.reduce(0, +)))

        struct Candidate {
            var entry: UserBook
            var affinity: Double
            var fit: Double
            var bestGenre: String?
        }

        let candidates: [Candidate] = source.compactMap { entry in
            guard let book = entry.book, !targetIds.contains(entry.bookId) else { return nil }
            if let key = normalizedKey(book), targetKeys.contains(key) { return nil }
            if isExcludedFromRecs(bookId: book.id, title: book.title, author: book.author) { return nil }
            guard let affinity = affinity(rating: entry.rating, tier: entry.tier), affinity > 0.4 else { return nil }
            // Share of the target's genre reading covered by this book's tokens,
            // sqrt-damped so one dominant genre doesn't swamp everything else.
            let tokens = genreCounts([entry]).keys
            var covered = 0
            var bestGenre: (token: String, count: Int)?
            for token in tokens {
                let count = targetGenres[token] ?? 0
                covered += count
                if count > (bestGenre?.count ?? 0) { bestGenre = (token, count) }
            }
            let fit = (Double(covered) / targetGenreTotal).squareRoot()
            return Candidate(entry: entry, affinity: affinity, fit: fit, bestGenre: bestGenre?.token)
        }

        return candidates
            .sorted { a, b in
                let sa = a.affinity * (0.35 + a.fit)
                let sb = b.affinity * (0.35 + b.fit)
                if sa != sb { return sa > sb }
                return a.affinity > b.affinity
            }
            .prefix(3)
            .compactMap { candidate in
                guard let book = candidate.entry.book else { return nil }
                let reason: String
                if let genre = candidate.bestGenre, candidate.fit > 0.2 {
                    reason = "\(otherName) loved it, and it sits right in your \(genre) lane."
                } else {
                    reason = "One of \(otherName)'s top-shelf reads."
                }
                return BookBlend.Rec(
                    title: book.title,
                    author: book.author,
                    bookId: book.id,
                    coverURL: book.coverURL,
                    reason: reason,
                    sourceUid: sourceUid,
                    sourceTier: candidate.entry.tier
                )
            }
    }

    // MARK: - AI layer

    private struct AIContent {
        var archetype: String
        var archetypeEmoji: String
        var tagline: String
        var insights: [BookBlend.Insight]
        var recs: [String: [BookBlend.Rec]]
        var freshPicks: [BookBlend.Rec]
    }

    private func aiLayer(
        stats: BlendStats,
        uidA: String, nameA: String, libraryA: [UserBook],
        uidB: String, nameB: String, libraryB: [UserBook]
    ) async -> AIContent? {
        let system = """
        You are the voice of Book Blend inside Spine, a social reading app. Two readers just merged their libraries. \
        Write punchy, specific, warm copy, Spotify-Wrapped energy, never generic, never cheesy. \
        Reference actual titles and tastes from the data. Keep every string under 140 characters. \
        Respond with ONLY a JSON object, no markdown fences, matching exactly:
        {
          "archetype": "fun 2-4 word name for this reader pair, like a duo band name",
          "archetypeEmoji": "one emoji",
          "tagline": "one-line subtitle for the archetype",
          "insights": [{"title": "2-4 word punchy header", "body": "one specific sentence about their combined taste"}, x3],
          "recsForA": [{"title": "...", "author": "...", "reason": "one punchy line on why A should steal this from B's shelf"}, x3, MUST be books from B's list that A has not read],
          "recsForB": [same, from A's shelf, x3],
          "freshPicks": [{"title": "...", "author": "...", "reason": "why this fits both"}, x4, real books NEITHER has read, to read together. Never pick anything from either shelf or the do-not-pick list; the first two that pass are shown]
        }
        """
        let user = """
        Reader A is \(nameA). Reader B is \(nameB).
        Compatibility score (already computed): \(stats.score)%, verdict "\(stats.verdict)".
        Books BOTH have read: \(stats.sharedBooks.prefix(10).map(\.title).joined(separator: "; ")).
        Shared genres: \(stats.sharedGenres.joined(separator: ", ")).
        \(nameA) uniquely reads: \((stats.distinctGenres[uidA] ?? []).joined(separator: ", ")).
        \(nameB) uniquely reads: \((stats.distinctGenres[uidB] ?? []).joined(separator: ", ")).

        \(nameA)'s shelf (best first):
        \(shelfSummary(libraryA))

        \(nameB)'s shelf (best first):
        \(shelfSummary(libraryB))

        Do NOT pick as fresh picks (already on a shelf, beyond the lists above):
        \(doNotPickList(libraryA + libraryB))
        """
        // Time-boxed: the accepter is staring at the "Blending" screen. Past 30s
        // the deterministic fallback content ships instead. A full reply runs
        // ~1,100 tokens, so 2,400 leaves headroom without inviting rambling.
        // If Sonnet's reply won't parse (truncated, prose around it), take one
        // more swing on the fast tier — any real AI copy beats the generic
        // "top-shelf reads" fallback, which recommends the same three books to
        // everyone.
        for tier in [ClaudeService.ModelTier.complex, .simple] {
            do {
                let text = try await ClaudeService.shared.sendMessage(system: system, userMessage: user, maxTokens: 2400, timeout: 30, tier: tier)
                if let content = parseAIContent(text, uidA: uidA, uidB: uidB) { return content }
                #if DEBUG
                print("[BookBlend] AI reply on \(tier) tier did not parse (\(text.count) chars): \(text.prefix(200))")
                #endif
            } catch {
                #if DEBUG
                print("[BookBlend] AI call on \(tier) tier failed: \(error.localizedDescription)")
                #endif
            }
        }
        return nil
    }

    /// Every read / in-progress title across both shelves that the best-35 shelf
    /// summaries leave out — Discover-style avoid list so Claude doesn't burn
    /// fresh picks on books one reader finished years ago.
    private func doNotPickList(_ libraries: [UserBook]) -> String {
        let shown = Set(libraries.filter { $0.status == .read }
            .sorted { (affinity(rating: $0.rating, tier: $0.tier) ?? -2) > (affinity(rating: $1.rating, tier: $1.tier) ?? -2) }
            .prefix(35).map(\.bookId))
        var seen = Set<String>()
        let titles = libraries
            .filter { $0.status != .wantToRead && !shown.contains($0.bookId) }
            .compactMap { $0.book?.title }
            .filter { seen.insert($0.lowercased()).inserted }
        return titles.prefix(200).joined(separator: "; ")
    }

    /// Discover's exclusion rule applied to blend picks: a pick is out if its
    /// resolved bookId is on a shelf, or its title/author names the same work
    /// as any shelved book (editions differ, Google resolves to other volumes).
    private func filterAlreadyShelved(_ picks: [BookBlend.Rec], shelved: [UserBook]) -> [BookBlend.Rec] {
        let shelvedIds = Set(shelved.map(\.bookId))
        let shelvedBooks = shelved.compactMap(\.book)
        return picks.filter { pick in
            if let id = pick.bookId, shelvedIds.contains(id) { return false }
            return !shelvedBooks.contains { LibraryDedup.matches(title: pick.title, author: pick.author, book: $0) }
        }
    }

    private func shelfSummary(_ library: [UserBook]) -> String {
        let reads = library.filter { $0.status == .read }
            .sorted { (affinity(rating: $0.rating, tier: $0.tier) ?? -2) > (affinity(rating: $1.rating, tier: $1.tier) ?? -2) }
            .prefix(35)
            .compactMap { entry -> String? in
                guard let book = entry.book else { return nil }
                var line = "\(book.title) by \(book.author)"
                if let r = entry.rating { line += " (\(Theme.formatRatingOutOfTen(r))/10)" }
                else if let t = entry.tier { line += " (\(t)-tier)" }
                return line
            }
        let queue = library.filter { $0.status == .wantToRead }
            .prefix(8)
            .compactMap { $0.book?.title }
        var summary = reads.joined(separator: "\n")
        if !queue.isEmpty {
            summary += "\nQueued next: \(queue.joined(separator: "; "))"
        }
        return summary
    }

    private func parseAIContent(_ text: String, uidA: String, uidB: String) -> AIContent? {
        // Tolerate fences or prose around the object: slice first "{" to last "}".
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let jsonText = String(text[start...end])
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        func recs(_ key: String, sourceUid: String) -> [BookBlend.Rec] {
            ((obj[key] as? [[String: Any]]) ?? []).compactMap { r in
                guard let title = r["title"] as? String, let author = r["author"] as? String else { return nil }
                return BookBlend.Rec(
                    title: title,
                    author: author,
                    bookId: nil,
                    coverURL: nil,
                    reason: (r["reason"] as? String) ?? "",
                    sourceUid: sourceUid
                )
            }
        }
        let insights: [BookBlend.Insight] = ((obj["insights"] as? [[String: Any]]) ?? []).compactMap { i in
            guard let title = i["title"] as? String, let body = i["body"] as? String else { return nil }
            return BookBlend.Insight(title: title, body: body)
        }
        let freshPicks: [BookBlend.Rec] = ((obj["freshPicks"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let title = r["title"] as? String, let author = r["author"] as? String else { return nil }
            return BookBlend.Rec(title: title, author: author, bookId: nil, coverURL: nil, reason: (r["reason"] as? String) ?? "", sourceUid: nil)
        }
        guard let archetype = obj["archetype"] as? String else { return nil }
        return AIContent(
            archetype: archetype,
            archetypeEmoji: (obj["archetypeEmoji"] as? String) ?? "📚",
            tagline: (obj["tagline"] as? String) ?? "",
            insights: insights,
            recs: [
                uidA: recs("recsForA", sourceUid: uidB),
                uidB: recs("recsForB", sourceUid: uidA),
            ],
            freshPicks: Array(freshPicks.prefix(4))
        )
    }

    // MARK: - Cover hydration

    /// AI recs come back as title+author; match them to the source shelf for real
    /// bookId/cover. Unmatched recs are kept (title-only placeholder covers render fine).
    private func hydrate(recs: [BookBlend.Rec], fromShelfOf source: [UserBook], sourceUid: String) -> [BookBlend.Rec] {
        var byKey: [String: UserBook] = [:]
        for entry in source {
            if let book = entry.book, let key = normalizedKey(book) { byKey[key] = entry }
        }
        return recs.map { rec in
            var rec = rec
            let probe = Book(id: "", title: rec.title, author: rec.author, coverURL: "", pageCount: nil, publishedDate: nil, description: nil, genres: [])
            guard let key = normalizedKey(probe), let entry = byKey[key], let book = entry.book else { return rec }
            // The shelf owner's tier rides along even when the rec already carries a
            // cover — the story slides show whose rank the pick came from.
            rec.sourceTier = rec.sourceTier ?? entry.tier
            rec.sourceUid = sourceUid
            if rec.coverURL == nil || rec.coverURL?.isEmpty == true {
                rec.bookId = book.id
                rec.coverURL = book.coverURL
            }
            return rec
        }
    }

    /// Fresh picks exist nowhere in either library — best-effort Google Books lookup for covers.
    private func hydrateFreshPicks(_ picks: [BookBlend.Rec]) async -> [BookBlend.Rec] {
        var hydrated: [BookBlend.Rec] = []
        for pick in picks.prefix(4) {
            var pick = pick
            if let results = try? await GoogleBooksService.shared.search(query: "\(pick.title) \(pick.author)", searchAuthors: false),
               let match = results.first {
                pick.bookId = match.id
                pick.coverURL = match.coverURL
            }
            hydrated.append(pick)
        }
        return hydrated
    }
}
