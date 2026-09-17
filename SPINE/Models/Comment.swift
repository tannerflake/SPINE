//
//  Comment.swift
//  SPINE
//

import Foundation

struct Comment: Identifiable, Codable {
    var id: UUID
    var postId: String   // Firestore post document id (UUID string)
    var userId: String   // Firebase Auth uid
    var text: String
    var createdAt: Date
    var displayName: String?  // Optional; set when writing so we can show without lookup
    /// Denormalized from the user profile at post time (optional for legacy comments).
    var profileImageURL: String?
    /// Comment doc id (UUID string) this comment replies to. `nil` = top-level comment.
    var parentCommentId: String?
    /// Maintained by like/unlike increments (legacy comments have no field = 0).
    var likeCount: Int = 0
}
