//
//  CommentRepository.swift
//  SPINE
//
//  Firestore comments: create, list by post.
//

import Foundation
import FirebaseFirestore

final class CommentRepository {
    private let db = FirestoreDatabase.firestore
    private let comments = "comments"
    private let userRepo = UserRepository()

    /// Listens to comments for a post.
    func listenComments(postId: String, onUpdate: @escaping ([Comment]) -> Void) -> ListenerRegistration {
        db.collection(comments)
            .whereField("postId", isEqualTo: postId)
            .order(by: "createdAt", descending: false)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self = self else { return }
                if let error = error {
                    #if DEBUG
                    print("CommentRepository.listenComments: \(error.localizedDescription)")
                    #endif
                    onUpdate([])
                    return
                }
                guard let snapshot = snapshot else {
                    onUpdate([])
                    return
                }
                let list = snapshot.documents.compactMap { doc -> Comment? in
                    self.comment(from: doc.data(), docId: doc.documentID)
                }
                onUpdate(list)
            }
    }

    /// Fetches comments for a post (one-shot).
    func fetchComments(postId: String) async -> [Comment] {
        do {
            let snapshot = try await db.collection(comments)
                .whereField("postId", isEqualTo: postId)
                .order(by: "createdAt", descending: false)
                .getDocuments()
            return snapshot.documents.compactMap { doc in
                comment(from: doc.data(), docId: doc.documentID)
            }
        } catch {
            return []
        }
    }

    /// Comments for many posts at once (chunked `in` queries, sorted client-side
    /// so no composite index is needed) — the "Read by" section's inline previews.
    func fetchComments(postIds: [String]) async -> [String: [Comment]] {
        let ids = Array(Set(postIds))
        guard !ids.isEmpty else { return [:] }
        let chunks = stride(from: 0, to: ids.count, by: 30).map { Array(ids[$0..<min($0 + 30, ids.count)]) }
        var all: [Comment] = []
        await withTaskGroup(of: [Comment].self) { group in
            for chunk in chunks {
                group.addTask { [self] in
                    do {
                        let snapshot = try await db.collection(comments)
                            .whereField("postId", in: chunk)
                            .getDocuments()
                        return snapshot.documents.compactMap { doc in
                            comment(from: doc.data(), docId: doc.documentID)
                        }
                    } catch {
                        return []
                    }
                }
            }
            for await list in group { all.append(contentsOf: list) }
        }
        return Dictionary(grouping: all.sorted { $0.createdAt < $1.createdAt }, by: \.postId)
    }

    /// Deletes all comments for a post (e.g. when removing the post). Batched; requires rules allowing post author to delete.
    func deleteAllCommentsForPost(postId: String) async throws {
        let snapshot = try await db.collection(comments)
            .whereField("postId", isEqualTo: postId)
            .getDocuments()
        let docs = snapshot.documents
        var i = 0
        while i < docs.count {
            let end = min(i + 400, docs.count)
            let batch = db.batch()
            for j in i..<end {
                batch.deleteDocument(docs[j].reference)
            }
            try await batch.commit()
            i = end
        }
    }

    /// Deletes the given comment docs (a comment plus whichever replies beneath it
    /// the viewer is allowed to remove) and drops the post's commentCount to match.
    /// Like docs on those comments are cleared first (rules let the comment author do
    /// that) but best-effort: a failure there never blocks the delete itself.
    func deleteComments(ids: [String], postId: String) async throws {
        guard !ids.isEmpty else { return }
        await deleteLikes(forCommentIds: Set(ids), postId: postId)
        var i = 0
        while i < ids.count {
            let end = min(i + 400, ids.count)
            let batch = db.batch()
            for j in i..<end {
                batch.deleteDocument(db.collection(comments).document(ids[j]))
            }
            try await batch.commit()
            i = end
        }
        try await db.collection("posts").document(postId).updateData([
            "commentCount": FieldValue.increment(Int64(-ids.count)),
        ])
    }

    /// Removes every commentLikes doc pointing at the given comments. Best-effort:
    /// orphaned like docs are harmless, so errors are swallowed.
    private func deleteLikes(forCommentIds commentIds: Set<String>, postId: String) async {
        do {
            let snapshot = try await db.collection("commentLikes")
                .whereField("postId", isEqualTo: postId)
                .getDocuments()
            let docs = snapshot.documents.filter {
                guard let cid = $0.data()["commentId"] as? String else { return false }
                return commentIds.contains(cid)
            }
            var i = 0
            while i < docs.count {
                let end = min(i + 400, docs.count)
                let batch = db.batch()
                for j in i..<end {
                    batch.deleteDocument(docs[j].reference)
                }
                try await batch.commit()
                i = end
            }
        } catch {
            #if DEBUG
            print("CommentRepository.deleteLikes: \(error.localizedDescription)")
            #endif
        }
    }

    /// Adds a comment and increments post's commentCount. `parentCommentId` marks a reply
    /// to another comment (triggers the reply push in Cloud Functions).
    func addComment(
        postId: String,
        userId: String,
        text: String,
        displayName: String?,
        profileImageURL: String? = nil,
        parentCommentId: String? = nil
    ) async throws -> Comment {
        let id = UUID()
        let now = Date()
        let ref = db.collection(comments).document(id.uuidString)
        var data: [String: Any] = [
            "postId": postId,
            "userId": userId,
            "text": text,
            "createdAt": Timestamp(date: now),
        ]
        if let name = displayName { data["displayName"] = name }
        if let url = profileImageURL, !url.isEmpty { data["profileImageURL"] = url }
        if let parent = parentCommentId, !parent.isEmpty { data["parentCommentId"] = parent }
        try await ref.setData(data)
        let postRef = db.collection("posts").document(postId)
        try await postRef.updateData([
            "commentCount": FieldValue.increment(Int64(1)),
        ])
        return Comment(
            id: id,
            postId: postId,
            userId: userId,
            text: text,
            createdAt: now,
            displayName: displayName,
            profileImageURL: profileImageURL,
            parentCommentId: parentCommentId
        )
    }

    /// Record that the user liked the comment. Idempotent. Increments comment's likeCount.
    /// Doc id is "{uid}_{commentId}" (same scheme as postLikes).
    func addLike(commentId: String, postId: String, userId: String) async throws {
        let likeRef = db.collection("commentLikes").document("\(userId)_\(commentId)")
        let commentRef = db.collection(comments).document(commentId)
        let snapshot = try await likeRef.getDocument()
        guard !snapshot.exists else { return }
        try await likeRef.setData([
            "userId": userId,
            "commentId": commentId,
            "postId": postId,
            "createdAt": Timestamp(date: Date()),
        ])
        try await commentRef.updateData([
            "likeCount": FieldValue.increment(Int64(1)),
        ])
    }

    /// Remove the user's like. Idempotent. Decrements comment's likeCount.
    func removeLike(commentId: String, userId: String) async throws {
        let likeRef = db.collection("commentLikes").document("\(userId)_\(commentId)")
        let commentRef = db.collection(comments).document(commentId)
        let snapshot = try await likeRef.getDocument()
        guard snapshot.exists else { return }
        try await likeRef.delete()
        try await commentRef.updateData([
            "likeCount": FieldValue.increment(Int64(-1)),
        ])
    }

    /// Comment ids (UUID strings) the user has liked on this post — heart fill state.
    func fetchLikedCommentIds(postId: String, userId: String) async -> Set<String> {
        do {
            let snapshot = try await db.collection("commentLikes")
                .whereField("userId", isEqualTo: userId)
                .whereField("postId", isEqualTo: postId)
                .getDocuments()
            let ids = snapshot.documents.compactMap { $0.data()["commentId"] as? String }
            return Set(ids)
        } catch {
            return []
        }
    }

    private func comment(from data: [String: Any], docId: String) -> Comment? {
        guard let postId = data["postId"] as? String,
              let userId = data["userId"] as? String,
              let text = data["text"] as? String,
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
              let id = UUID(uuidString: docId) else { return nil }
        if HiddenAccounts.isHiddenFromCurrentViewer(uid: userId) { return nil }
        let displayName = data["displayName"] as? String
        let profileImageURL = data["profileImageURL"] as? String
        let parentCommentId = data["parentCommentId"] as? String
        let likeCount = (data["likeCount"] as? Int) ?? 0
        return Comment(
            id: id,
            postId: postId,
            userId: userId,
            text: text,
            createdAt: createdAt,
            displayName: displayName,
            profileImageURL: profileImageURL,
            parentCommentId: parentCommentId,
            likeCount: max(0, likeCount)
        )
    }
}
