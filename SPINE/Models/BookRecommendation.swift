//
//  BookRecommendation.swift
//  SPINE
//
//  A book one member sent to another ("you should read this"). Lives in the
//  Firestore `recommendations` collection; the recipient sees pending ones on
//  the Recommended shelf of their queue and can add the book or dismiss it.
//

import Foundation

struct BookRecommendation: Identifiable, Equatable {
    enum Status: String, Codable {
        case pending
        case accepted
        case dismissed
    }

    var id: UUID
    /// Firebase Auth UID of the sender.
    var fromUserId: String
    /// Firebase Auth UID of the recipient.
    var toUserId: String
    var bookId: String
    /// Resolved from the `books` collection after fetch; nil until loaded.
    var book: Book?
    /// Optional message from the sender ("you'd love this one").
    var note: String?
    var status: Status
    var createdAt: Date
}
