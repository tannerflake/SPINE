//
//  NotificationsRepository.swift
//  SPINE
//
//  In-app notification feed (`users/{uid}/notifications`): rows are written by
//  Cloud Functions alongside every real push, so the feed mirrors push alerts
//  even for users without push permission. The app only reads, marks read, and
//  deletes — creation is server-only (enforced by Firestore rules).
//

import Foundation
import FirebaseFirestore

/// One row in the notifications feed. `type` matches the push payload types
/// (`new_follower`, `contact_joined`, `review_liked`, `review_commented`,
/// `comment_replied`, `thread_commented`, `friend_review_posted`,
/// `blend_request`, `blend_ready`, `book_recommended`),
/// and the deep-link ids carry the same keys the push data payload uses.
struct UserNotification: Identifiable, Equatable {
    let id: String
    let type: String
    let title: String
    let body: String
    let postId: String?
    /// Set on comment_liked rows: the exact comment the tap scrolls to.
    let commentId: String?
    let blendId: String?
    /// Set on achievement_unlocked rows: which stamp was earned.
    var achievementId: String? = nil
    /// Set on monthly_recap rows: the `YYYY-MM` month the recap covers.
    var recapMonth: String? = nil
    /// The user who triggered the notification (follower, liker, commenter, blend partner).
    let actorId: String?
    let coverURL: String?
    let createdAt: Date
    let read: Bool
}

final class NotificationsRepository {
    private let db = FirestoreDatabase.firestore

    private func collection(uid: String) -> CollectionReference {
        db.collection("users").document(uid).collection("notifications")
    }

    /// Newest-first page of the feed.
    func fetchLatest(uid: String, limit: Int = 100) async -> [UserNotification] {
        do {
            let snap = try await collection(uid: uid)
                .order(by: "createdAt", descending: true)
                .limit(to: limit)
                .getDocuments()
            return snap.documents.compactMap { Self.parse(doc: $0) }
        } catch {
            #if DEBUG
            print("NotificationsRepository.fetchLatest: \(error.localizedDescription)")
            #endif
            return []
        }
    }

    /// Whether anything is unread — drives the bell's badge dot (limit 1: the
    /// dot doesn't need a count).
    func hasUnread(uid: String) async -> Bool {
        do {
            let snap = try await collection(uid: uid)
                .whereField("read", isEqualTo: false)
                .limit(to: 1)
                .getDocuments()
            return !snap.documents.isEmpty
        } catch {
            return false
        }
    }

    /// Marks every unread row read (opening the feed clears the badge).
    func markAllRead(uid: String) async {
        do {
            let snap = try await collection(uid: uid)
                .whereField("read", isEqualTo: false)
                .getDocuments()
            guard !snap.documents.isEmpty else { return }
            let batch = db.batch()
            snap.documents.forEach { batch.updateData(["read": true], forDocument: $0.reference) }
            try await batch.commit()
        } catch {
            #if DEBUG
            print("NotificationsRepository.markAllRead: \(error.localizedDescription)")
            #endif
        }
    }

    private static func parse(doc: QueryDocumentSnapshot) -> UserNotification? {
        let d = doc.data()
        guard let type = d["type"] as? String,
              let title = d["title"] as? String else { return nil }
        // Follows carry the actor as `followerId`, blends as `otherUserId`;
        // `actorId` is the uniform field newer docs always have.
        let actor = (d["actorId"] as? String)
            ?? (d["followerId"] as? String)
            ?? (d["otherUserId"] as? String)
        return UserNotification(
            id: doc.documentID,
            type: type,
            title: title,
            body: (d["body"] as? String) ?? "",
            postId: d["postId"] as? String,
            commentId: d["commentId"] as? String,
            blendId: d["blendId"] as? String,
            achievementId: d["achievementId"] as? String,
            recapMonth: d["recapMonth"] as? String,
            actorId: actor,
            coverURL: d["coverURL"] as? String,
            createdAt: (d["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            read: (d["read"] as? Bool) ?? true
        )
    }
}
