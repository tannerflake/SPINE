//
//  UserBookRepository.swift
//  SPINE
//
//  Firestore userBooks: CRUD, query by userId/status, tier updates.
//

import Foundation
import FirebaseFirestore

final class UserBookRepository {
    private let db = FirestoreDatabase.firestore
    private let userBooks = "userBooks"
    private let bookRepo: BookRepository

    init(bookRepository: BookRepository = BookRepository.shared) {
        self.bookRepo = bookRepository
    }

    /// Serializes snapshot delivery: each event resolves books in its own async task,
    /// so an older event finishing late must not overwrite a newer one.
    private final class SnapshotSequencer: @unchecked Sendable {
        private let lock = NSLock()
        private var scheduled = 0
        private var delivered = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            scheduled += 1
            return scheduled
        }
        func shouldDeliver(_ generation: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard generation > delivered else { return false }
            delivered = generation
            return true
        }
    }

    /// Listens to all userBooks for a user (for real-time Library updates).
    func listenUserBooks(userId: String, onUpdate: @escaping ([UserBook]) -> Void) -> ListenerRegistration {
        let sequencer = SnapshotSequencer()
        return db.collection(userBooks)
            .whereField("userId", isEqualTo: userId)
            .order(by: "updatedAt", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self = self, let snapshot = snapshot else { return }
                let generation = sequencer.next()
                let list = snapshot.documents.compactMap { doc -> UserBook? in
                    self.userBook(from: doc.data(), docId: doc.documentID)
                }
                Task {
                    let books = await self.bookRepo.getBooks(ids: list.map(\.bookId))
                    let withBooks = list.map { ub -> UserBook in
                        var ub = ub
                        ub.book = books[ub.bookId]
                        return ub
                    }
                    await MainActor.run {
                        guard sequencer.shouldDeliver(generation) else { return }
                        onUpdate(withBooks)
                    }
                }
            }
    }

    /// Fetches userBooks for a user (one-shot).
    func fetchUserBooks(userId: String) async -> [UserBook] {
        do {
            let snapshot = try await db.collection(userBooks)
                .whereField("userId", isEqualTo: userId)
                .order(by: "updatedAt", descending: true)
                .getDocuments()
            let list = snapshot.documents.compactMap { userBook(from: $0.data(), docId: $0.documentID) }
            let books = await bookRepo.getBooks(ids: list.map(\.bookId))
            return list.map { ub -> UserBook in
                var ub = ub
                ub.book = books[ub.bookId]
                return ub
            }
        } catch {
            return []
        }
    }

    /// Fetches userBooks for a user filtered by status.
    func fetchUserBooks(userId: String, status: ReadingStatus) async -> [UserBook] {
        do {
            let snapshot = try await db.collection(userBooks)
                .whereField("userId", isEqualTo: userId)
                .whereField("status", isEqualTo: status.rawValue)
                .order(by: "updatedAt", descending: true)
                .getDocuments()
            let list = snapshot.documents.compactMap { userBook(from: $0.data(), docId: $0.documentID) }
            let books = await bookRepo.getBooks(ids: list.map(\.bookId))
            return list.map { ub -> UserBook in
                var ub = ub
                ub.book = books[ub.bookId]
                return ub
            }
        } catch {
            return []
        }
    }

    /// All members' read rows for one book ("Read by" on the book profile).
    /// No orderBy so the two equality filters run on merged single-field indexes;
    /// callers filter to followed uids and sort client-side. Book left unhydrated.
    func fetchReadEntries(bookId: String) async -> [UserBook] {
        do {
            let snapshot = try await db.collection(userBooks)
                .whereField("bookId", isEqualTo: bookId)
                .whereField("status", isEqualTo: ReadingStatus.read.rawValue)
                .getDocuments()
            return snapshot.documents.compactMap { doc in
                userBook(from: doc.data(), docId: doc.documentID)
            }
        } catch {
            return []
        }
    }

    /// One member's read rows without book hydration — bookId/rating/tier are all
    /// the match scorer needs for trust weighting. Same index-friendly shape as
    /// `fetchReadEntries(bookId:)` (two equality filters, no orderBy).
    func fetchReadEntriesLite(userId: String) async -> [UserBook] {
        do {
            let snapshot = try await db.collection(userBooks)
                .whereField("userId", isEqualTo: userId)
                .whereField("status", isEqualTo: ReadingStatus.read.rawValue)
                .getDocuments()
            return snapshot.documents.compactMap { doc in
                userBook(from: doc.data(), docId: doc.documentID)
            }
        } catch {
            return []
        }
    }

    /// Distinct bookIds finished by any of the given readers ("Read by people
    /// you follow" on the search page). Books left unhydrated so the caller can
    /// shuffle the pool and hydrate covers a few at a time.
    func fetchReadBookIds(forUserIds uids: [String]) async -> [String] {
        let wanted = Array(Set(uids))
        guard !wanted.isEmpty else { return [] }
        let chunks = stride(from: 0, to: wanted.count, by: 30).map {
            Array(wanted[$0..<min($0 + 30, wanted.count)])
        }
        let rows = await withTaskGroup(of: [String].self) { group in
            for chunk in chunks {
                group.addTask { [self] in
                    do {
                        let snapshot = try await db.collection(userBooks)
                            .whereField("userId", in: chunk)
                            .whereField("status", isEqualTo: ReadingStatus.read.rawValue)
                            .getDocuments()
                        return snapshot.documents.compactMap { $0.data()["bookId"] as? String }
                    } catch {
                        return []
                    }
                }
            }
            var all: [String] = []
            for await chunkIds in group { all.append(contentsOf: chunkIds) }
            return all
        }
        var seen = Set<String>()
        return rows.filter { seen.insert($0).inserted }
    }

    /// "Reading now" covers for a specific set of readers: uid → books in shelf
    /// order. Scoped version of `fetchAllReadingNowBooks` for surfaces that only
    /// need the people currently on screen (the feed people strip loads these a
    /// page at a time; the feed loads them for post authors).
    func fetchReadingNowBooks(forUserIds uids: [String]) async -> [String: [Book]] {
        let wanted = Set(uids)
        guard !wanted.isEmpty else { return [:] }
        return await ReadingNowSummary.shared.byUid().filter { wanted.contains($0.key) }
    }

    /// Every member's "Reading now" covers: uid → books in shelf order.
    ///
    /// Served from the server-maintained `summaries/readingNow` document (one
    /// read) rather than scanning every reading-now row in the database plus a
    /// book doc per cover, which is what this cost per cold launch, per device,
    /// before 2026-10-05. The Cloud Functions userBooks trigger keeps the doc
    /// current and a nightly job rebuilds it from scratch.
    func fetchAllReadingNowBooks() async -> [String: [Book]] {
        await ReadingNowSummary.shared.byUid()
    }

    /// Just the readers with something on their Reading Now shelf (the
    /// roster-wide ranking in `UserDirectory` only needs to know who).
    func fetchUidsReadingNow() async -> Set<String> {
        Set(await ReadingNowSummary.shared.byUid().keys)
    }

    /// Adds a userBook (and ensures the book exists). Returns the created UserBook with its id.
    /// `targetShelf`/`targetOrder` (wantToRead only) place the book directly on a specific queue
    /// shelf at a sparse position (see `SparseOrder`); callers compute the position from the
    /// library they already hold (`AppState.topBacklogOrder()` / shelf end), so a queue add is
    /// exactly one document write. Without them a queue book lands on the backlog at order 0.
    func addUserBook(userId: String, book: Book, status: ReadingStatus, rating: Double?, reviewText: String?, dateStarted: Date?, dateFinished: Date?, targetShelf: QueueShelf? = nil, targetOrder: Int? = nil) async throws -> UserBook {
        // Resolve to the community's canonical book doc — the id actually shelved
        // can differ from the tapped search result's id (same work under another
        // source's id). See BookRepository.ensureCanonicalBook.
        let resolved = try await bookRepo.ensureCanonicalBook(book)
        if resolved.id != book.id,
           let existingDoc = try? await db.collection(userBooks)
               .whereField("userId", isEqualTo: userId)
               .whereField("bookId", isEqualTo: resolved.id)
               .whereField("status", isEqualTo: status.rawValue)
               .limit(to: 1)
               .getDocuments().documents.first,
           var existing = userBook(from: existingDoc.data(), docId: existingDoc.documentID) {
            // The user already shelved this work under the canonical id — the UI's
            // in-library check compares raw ids and couldn't see it. Reuse the row.
            existing.book = resolved
            return existing
        }
        let book = resolved
        let id = UUID()
        let now = Date()
        let ref = db.collection(userBooks).document(id.uuidString)
        var data: [String: Any] = [
            "userId": userId,
            "bookId": book.id,
            "status": status.rawValue,
            "rating": rating.map { Theme.normalizeRatingOutOfTen($0) } as Any,
            "reviewText": reviewText as Any,
            "dateStarted": dateStarted.map { Timestamp(date: $0) } as Any,
            "dateFinished": dateFinished.map { Timestamp(date: $0) } as Any,
            "createdAt": Timestamp(date: now),
            "updatedAt": Timestamp(date: now),
            "recommendedTo": [] as [String],
            "tier": NSNull(),
            "tierOrder": NSNull(),
        ]
        var queueShelf: QueueShelf?
        var queueOrder: Int?
        if status == .wantToRead {
            // Sparse placement: the new row takes its own slot and no other
            // document is touched. (The old path re-read and renumbered every
            // backlog row per add — quadratic across an import.)
            let shelf = targetShelf ?? .backlog
            queueShelf = shelf
            queueOrder = targetOrder ?? 0
            data["queueShelf"] = shelf.rawValue
            data["queueOrder"] = queueOrder ?? 0
            try await ref.setData(data)
        } else {
            data["queueShelf"] = NSNull()
            data["queueOrder"] = NSNull()
            try await ref.setData(data)
        }
        return UserBook(
            id: id,
            userId: userId,
            bookId: book.id,
            book: book,
            status: status,
            rating: rating,
            reviewText: reviewText,
            dateStarted: dateStarted,
            dateFinished: dateFinished,
            createdAt: now,
            updatedAt: now,
            recommendedTo: [],
            tier: nil,
            tierOrder: nil,
            queueShelf: queueShelf,
            queueOrder: queueOrder
        )
    }

    /// Updates status, rating, review, dates, tier, tierOrder.
    func updateUserBook(_ userBook: UserBook) async throws {
        let ref = db.collection(userBooks).document(userBook.id.uuidString)
        try await ref.updateData(Self.updateFields(for: userBook))
    }

    /// Persists many placement changes atomically (chunked to stay under Firestore's 500-op batch limit).
    /// Drag-reorders renumber whole tiers/shelves; committing them as one batch means the snapshot
    /// listener sees a single consistent state instead of one partial state per document.
    /// Writes ONLY tier, tierOrder, queueShelf, queueOrder and updatedAt: a reorder must never
    /// re-send read dates, ratings or reviews from the in-memory copy, which can be stale
    /// (edited on another device, or before the listener echoed) and would resurrect old values.
    func batchUpdatePlacement(_ books: [UserBook]) async throws {
        guard !books.isEmpty else { return }
        let chunkSize = 450
        for start in stride(from: 0, to: books.count, by: chunkSize) {
            let chunk = books[start..<min(start + chunkSize, books.count)]
            let batch = db.batch()
            for ub in chunk {
                let ref = db.collection(userBooks).document(ub.id.uuidString)
                batch.updateData(Self.placementFields(for: ub), forDocument: ref)
            }
            try await batch.commit()
        }
    }

    private static func placementFields(for userBook: UserBook) -> [String: Any] {
        [
            "tier": userBook.tier as Any,
            "tierOrder": userBook.tierOrder as Any,
            "queueShelf": userBook.queueShelf.map { $0.rawValue as Any } ?? NSNull(),
            "queueOrder": userBook.queueOrder.map { $0 as Any } ?? NSNull(),
            "updatedAt": Timestamp(date: userBook.updatedAt),
        ]
    }

    private static func updateFields(for userBook: UserBook) -> [String: Any] {
        var fields: [String: Any] = [
            "status": userBook.status.rawValue,
            "rating": userBook.rating.map { Theme.normalizeRatingOutOfTen($0) } as Any,
            "reviewText": userBook.reviewText as Any,
            "dateStarted": userBook.dateStarted.map { Timestamp(date: $0) } as Any,
            "dateFinished": userBook.dateFinished.map { Timestamp(date: $0) } as Any,
            "updatedAt": Timestamp(date: userBook.updatedAt),
            "tier": userBook.tier as Any,
            "tierOrder": userBook.tierOrder as Any,
        ]
        if let qs = userBook.queueShelf {
            fields["queueShelf"] = qs.rawValue
        } else {
            fields["queueShelf"] = NSNull()
        }
        if let qo = userBook.queueOrder {
            fields["queueOrder"] = qo
        } else {
            fields["queueOrder"] = NSNull()
        }
        if let extra = userBook.additionalReadDates, !extra.isEmpty {
            fields["additionalReadDates"] = extra.map { Timestamp(date: $0) }
        } else {
            fields["additionalReadDates"] = NSNull()
        }
        fields["queueNote"] = userBook.trimmedQueueNote.map { $0 as Any } ?? NSNull()
        fields["readingProgress"] = userBook.readingProgress.map { min(1, max(0, $0)) as Any } ?? NSNull()
        return fields
    }

    /// Sets how far through a book the reader is (0...1) from the Reading now scrubber.
    /// `dateStarted` is written only when given (first nudge off 0% stamps the start date).
    func setReadingProgress(userBookId: UUID, progress: Double, dateStarted: Date? = nil) async throws {
        let ref = db.collection(userBooks).document(userBookId.uuidString)
        var fields: [String: Any] = [
            "readingProgress": min(1, max(0, progress)),
            "updatedAt": Timestamp(date: Date()),
        ]
        if let started = dateStarted {
            fields["dateStarted"] = Timestamp(date: started)
        }
        try await ref.updateData(fields)
    }

    /// Sets (or clears, with `nil`) the private note-to-self on a queued book.
    func setQueueNote(userBookId: UUID, note: String?) async throws {
        let ref = db.collection(userBooks).document(userBookId.uuidString)
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try await ref.updateData([
            "queueNote": trimmed.isEmpty ? NSNull() : trimmed as Any,
            "updatedAt": Timestamp(date: Date()),
        ])
    }

    /// Updates tier for a userBook.
    func setTier(userBookId: UUID, tier: String?, tierOrder: Int? = nil) async throws {
        let ref = db.collection(userBooks).document(userBookId.uuidString)
        try await ref.updateData([
            "tier": tier as Any,
            "tierOrder": tierOrder.map { $0 as Any } ?? NSNull(),
            "updatedAt": Timestamp(date: Date()),
        ])
    }

    /// Deletes a userBook (e.g. remove from queue). Firestore listener will update userBooks.
    func deleteUserBook(userId: String, userBookId: UUID) async throws {
        let ref = db.collection(userBooks).document(userBookId.uuidString)
        try await ref.delete()
    }

    private func userBook(from data: [String: Any], docId: String) -> UserBook? {
        guard let userId = data["userId"] as? String,
              let bookId = data["bookId"] as? String,
              let statusRaw = data["status"] as? String,
              let status = ReadingStatus(rawValue: statusRaw),
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
              let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue(),
              let id = UUID(uuidString: docId) else { return nil }
        let rating = Self.decodeRatingOutOfTen(from: data["rating"])
        let reviewText = data["reviewText"] as? String
        let dateStarted = (data["dateStarted"] as? Timestamp)?.dateValue()
        let dateFinished = (data["dateFinished"] as? Timestamp)?.dateValue()
        let tier = data["tier"] as? String
        let tierOrder = data["tierOrder"] as? Int
        let queueShelfRaw = data["queueShelf"] as? String
        let queueShelf = queueShelfRaw.flatMap { QueueShelf(rawValue: $0) }
        let queueOrder = data["queueOrder"] as? Int
        let additionalReadDates = (data["additionalReadDates"] as? [Timestamp]).map { $0.map { $0.dateValue() } }
        let queueNote = data["queueNote"] as? String
        let readingProgress = (data["readingProgress"] as? NSNumber).map { Double(truncating: $0) }
        return UserBook(
            id: id,
            userId: userId,
            bookId: bookId,
            book: nil,
            status: status,
            rating: rating,
            reviewText: reviewText,
            dateStarted: dateStarted,
            dateFinished: dateFinished,
            createdAt: createdAt,
            updatedAt: updatedAt,
            recommendedTo: [],
            tier: tier,
            tierOrder: tierOrder,
            queueShelf: queueShelf,
            queueOrder: queueOrder,
            additionalReadDates: additionalReadDates,
            queueNote: queueNote,
            readingProgress: readingProgress
        )
    }

    /// Firestore may store `rating` as Double or legacy Int / Int64 (1–10).
    private static func decodeRatingOutOfTen(from value: Any?) -> Double? {
        switch value {
        case nil:
            return nil
        case let d as Double:
            return Theme.normalizeRatingOutOfTen(d)
        case let i as Int:
            return Theme.normalizeRatingOutOfTen(Double(i))
        case let i64 as Int64:
            return Theme.normalizeRatingOutOfTen(Double(i64))
        case let n as NSNumber:
            return Theme.normalizeRatingOutOfTen(Double(truncating: n))
        default:
            return nil
        }
    }
}
