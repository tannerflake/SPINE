//
//  Post.swift
//  SPINE
//

import Foundation

enum PostType: String, Codable {
    case finishedBook
    case review
    case recommendation
    case tierListUpdate
    /// Hidden discussion carrier for a read that was never posted to the feed —
    /// created lazily (deterministic id) when someone first likes or comments on
    /// a read from the book profile's "Read by" section. Never shown in feeds;
    /// a feed post demoted via "Show on feed" off becomes one of these so its
    /// comments and likes survive.
    case readRecord
}

struct Post: Identifiable, Codable {
    var id: UUID
    var userId: String  // Firebase Auth uid
    var type: PostType
    var bookId: String?
    var book: Book?
    var caption: String?
    var createdAt: Date
    var likeCount: Int
    var commentCount: Int
    var user: User?
    /// Legacy decimal rating (e.g. 8.8). Hidden in the UI now that ratings are tier-only, but kept on disk for back-compat.
    var rating: Double?
    /// Date the user finished the book (shown in feed with minimal weight).
    var dateFinished: Date?
    /// Tier letter (S/A/B/C/D/F) the author has assigned to this book. `nil` until they tier it; updates as they re-tier.
    var tier: String?

    static let demoFeed: [Post] = {
        let b = Book(id: "1", title: "Atomic Habits", author: "James Clear", coverURL: "https://books.google.com/books/content?id=wRqtDwAAQBAJ&printsec=frontcover&img=1", pageCount: 320, publishedDate: nil, description: nil, genres: [])
        return [
            Post(id: UUID(), userId: "demo-user-id", type: .finishedBook, bookId: b.id, book: b, caption: "Just finished. Highly recommend.", createdAt: Date(), likeCount: 4, commentCount: 1, user: .demo, rating: 8.5, dateFinished: Date(), tier: "S")
        ]
    }()
}
