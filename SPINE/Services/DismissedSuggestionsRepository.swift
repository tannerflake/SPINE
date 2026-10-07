//
//  DismissedSuggestionsRepository.swift
//  SPINE
//
//  Persists book IDs the user has marked "not interested" so we never suggest them again.
//

import Foundation
import FirebaseFirestore

final class DismissedSuggestionsRepository {
    private let db = FirestoreDatabase.firestore
    private let collectionName = "dismissedSuggestions"

    /// A passed book. `title` is nil on docs written before titles were stored.
    struct Entry {
        let bookId: String
        let title: String?
        let dismissedAt: Date?
    }

    /// Add a dismissed book for the user. Idempotent (same doc id). The title
    /// is stored so Discover can tell the model what was passed on; ids alone
    /// let it keep re-suggesting the same picks.
    func addDismissed(userId: String, bookId: String, title: String? = nil) async throws {
        let docId = "\(userId)_\(bookId)"
        var data: [String: Any] = [
            "userId": userId,
            "bookId": bookId,
            "dismissedAt": Timestamp(date: Date()),
        ]
        if let title, !title.isEmpty { data["title"] = title }
        try await db.collection(collectionName).document(docId).setData(data)
    }

    /// Remove a dismissed book for the user (e.g. when they tap Back to return to that book).
    func removeDismissed(userId: String, bookId: String) async throws {
        let docId = "\(userId)_\(bookId)"
        try await db.collection(collectionName).document(docId).delete()
    }

    /// Fetch all dismissed books for the user.
    func fetchDismissed(userId: String) async -> [Entry] {
        do {
            let snapshot = try await db.collection(collectionName)
                .whereField("userId", isEqualTo: userId)
                .getDocuments()
            return snapshot.documents.compactMap { doc in
                let data = doc.data()
                guard let bookId = data["bookId"] as? String else { return nil }
                return Entry(
                    bookId: bookId,
                    title: data["title"] as? String,
                    dismissedAt: (data["dismissedAt"] as? Timestamp)?.dateValue()
                )
            }
        } catch {
            return []
        }
    }
}
