//
//  RecommendationRepository.swift
//  SPINE
//
//  Firestore `recommendations`: send a book to another member, listen to the
//  recipient's pending pile, accept/dismiss. Books are stored by id (the doc
//  carries `bookId`; the Book itself lives in `books` via BookRepository).
//

import Foundation
import FirebaseFirestore

final class RecommendationRepository {
    private let db = FirestoreDatabase.firestore
    private let collection = "recommendations"
    private let bookRepo: BookRepository

    init(bookRepository: BookRepository = BookRepository.shared) {
        self.bookRepo = bookRepository
    }

    /// Creates a recommendation. If the sender already has a pending
    /// recommendation of this book to this person, this is a no-op (returns
    /// the existing one) so repeat taps don't pile up on the recipient.
    @discardableResult
    func send(fromUserId: String, toUserId: String, book: Book, note: String?) async throws -> BookRecommendation {
        // Recommend the community's canonical doc so the recipient's add lands on
        // the same book their friends shelved (see BookRepository.ensureCanonicalBook).
        let book = try await bookRepo.ensureCanonicalBook(book)
        if let existing = try? await db.collection(collection)
            .whereField("fromUserId", isEqualTo: fromUserId)
            .whereField("toUserId", isEqualTo: toUserId)
            .whereField("bookId", isEqualTo: book.id)
            .whereField("status", isEqualTo: BookRecommendation.Status.pending.rawValue)
            .limit(to: 1)
            .getDocuments()
            .documents.first,
           let rec = recommendation(from: existing.data(), docId: existing.documentID) {
            var withBook = rec
            withBook.book = book
            return withBook
        }
        let id = UUID()
        let now = Date()
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let data: [String: Any] = [
            "fromUserId": fromUserId,
            "toUserId": toUserId,
            "bookId": book.id,
            "note": (trimmedNote?.isEmpty == false ? trimmedNote! : NSNull()) as Any,
            "status": BookRecommendation.Status.pending.rawValue,
            "createdAt": Timestamp(date: now)
        ]
        try await db.collection(collection).document(id.uuidString).setData(data)
        return BookRecommendation(
            id: id,
            fromUserId: fromUserId,
            toUserId: toUserId,
            bookId: book.id,
            book: book,
            note: trimmedNote?.isEmpty == false ? trimmedNote : nil,
            status: .pending,
            createdAt: now
        )
    }

    /// Listens to the user's pending incoming recommendations (Recommended
    /// shelf), resolving each book. Late-finishing older snapshots must not
    /// overwrite newer ones, hence the generation guard.
    func listenIncoming(userId: String, onUpdate: @escaping ([BookRecommendation]) -> Void) -> ListenerRegistration {
        let generationCounter = GenerationCounter()
        return db.collection(collection)
            .whereField("toUserId", isEqualTo: userId)
            .whereField("status", isEqualTo: BookRecommendation.Status.pending.rawValue)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self = self, let snapshot = snapshot else { return }
                let generation = generationCounter.next()
                let list = snapshot.documents.compactMap { self.recommendation(from: $0.data(), docId: $0.documentID) }
                Task {
                    var resolved: [BookRecommendation] = []
                    for var rec in list {
                        rec.book = await self.bookRepo.getBook(id: rec.bookId)
                        resolved.append(rec)
                    }
                    resolved.sort { $0.createdAt > $1.createdAt }
                    await MainActor.run {
                        guard generationCounter.shouldDeliver(generation) else { return }
                        onUpdate(resolved)
                    }
                }
            }
    }

    /// Recipient accepts (book was added to their queue) or dismisses.
    func updateStatus(id: UUID, status: BookRecommendation.Status) async throws {
        try await db.collection(collection).document(id.uuidString).updateData([
            "status": status.rawValue
        ])
    }

    private func recommendation(from data: [String: Any], docId: String) -> BookRecommendation? {
        guard let id = UUID(uuidString: docId),
              let fromUserId = data["fromUserId"] as? String,
              let toUserId = data["toUserId"] as? String,
              let bookId = data["bookId"] as? String,
              let statusRaw = data["status"] as? String,
              let status = BookRecommendation.Status(rawValue: statusRaw) else { return nil }
        return BookRecommendation(
            id: id,
            fromUserId: fromUserId,
            toUserId: toUserId,
            bookId: bookId,
            book: nil,
            note: data["note"] as? String,
            status: status,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        )
    }

    /// Same role as UserBookRepository.SnapshotSequencer: snapshot events
    /// resolve books asynchronously, so an older event finishing late must
    /// not overwrite a newer one.
    private final class GenerationCounter: @unchecked Sendable {
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
}
