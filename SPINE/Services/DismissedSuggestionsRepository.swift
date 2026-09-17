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

    /// Add a dismissed book for the user. Idempotent (same doc id).
    func addDismissed(userId: String, bookId: String) async throws {
        let docId = "\(userId)_\(bookId)"
        try await db.collection(collectionName).document(docId).setData([
            "userId": userId,
            "bookId": bookId,
            "dismissedAt": Timestamp(date: Date()),
        ])
    }

    /// Remove a dismissed book for the user (e.g. when they tap Back to return to that book).
    func removeDismissed(userId: String, bookId: String) async throws {
        let docId = "\(userId)_\(bookId)"
        try await db.collection(collectionName).document(docId).delete()
    }

    /// Fetch all dismissed book IDs for the user.
    func fetchDismissedBookIds(userId: String) async -> [String] {
        do {
            let snapshot = try await db.collection(collectionName)
                .whereField("userId", isEqualTo: userId)
                .getDocuments()
            return snapshot.documents.compactMap { $0.data()["bookId"] as? String }
        } catch {
            return []
        }
    }
}
