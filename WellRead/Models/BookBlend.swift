//
//  BookBlend.swift
//  Spine
//
//  Two readers merge libraries into a shared taste profile — Spotify-Blend-style.
//  One Firestore doc per pair (`bookBlends/{uidLow_uidHigh}`), so either member
//  can find their blend with a person from that person's profile. The generated
//  result is stored on the doc; rewatching never recomputes.
//

import Foundation
import FirebaseFirestore

enum BookBlendStatus: String, Codable {
    /// Requested; waiting on the recipient. The requester's device precomputes
    /// the result onto this pending doc, so accepting is usually just the flip
    /// to `ready`. A pending doc carrying a `result` has not been accepted yet.
    case pending
    case declined
    case ready
}

struct BookBlend: Identifiable, Equatable {
    /// Deterministic pair id: the two uids sorted and joined with `_`.
    let id: String
    var userIds: [String]
    var requesterId: String
    var recipientId: String
    var status: BookBlendStatus
    var createdAt: Date
    var respondedAt: Date?
    /// uid → display snapshot taken at request/generate time (avoids N user fetches on rewatch).
    var participants: [String: Participant]
    var result: Result?

    static func pairId(_ a: String, _ b: String) -> String {
        a < b ? "\(a)_\(b)" : "\(b)_\(a)"
    }

    func otherUserId(from uid: String) -> String {
        userIds.first { $0 != uid } ?? uid
    }

    struct Participant: Codable, Equatable {
        var firstName: String
        var photoURL: String?
        /// Books marked Read at generate time — shown as "shelves merged".
        var readCount: Int
    }

    // MARK: - Generated result

    struct Result: Codable, Equatable {
        /// 8–99 compatibility percentage (see BookBlendService.computeStats).
        var score: Int
        /// Score-band verdict, e.g. "Shelf Soulmates".
        var verdict: String
        /// Reader-pair archetype from the AI pass, e.g. "The Plot Twisters".
        var archetype: String
        var archetypeEmoji: String
        var tagline: String
        var sharedBooks: [SharedBook]
        var sharedGenres: [String]
        /// uid → genres that reader uniquely brings to the blend.
        var distinctGenres: [String: [String]]
        var insights: [Insight]
        /// uid → picks *for* that reader (mostly from the other's shelf).
        var recs: [String: [Rec]]
        /// Fresh books neither has read — "read together next".
        var freshPicks: [Rec]
        var generatedAt: Date
        var generatedBy: String
    }

    struct SharedBook: Codable, Equatable {
        var bookId: String
        var title: String
        var author: String
        var coverURL: String
        /// uid → that reader's 0–10 rating of the book.
        var ratings: [String: Double]
        /// uid → tier letter (S/A/B/C/D/F).
        var tiers: [String: String]
    }

    struct Insight: Codable, Equatable {
        var title: String
        var body: String
    }

    struct Rec: Codable, Equatable {
        var title: String
        var author: String
        var bookId: String?
        var coverURL: String?
        var reason: String
        /// Set when the pick came off the other reader's shelf.
        var sourceUid: String?
        /// `sourceUid`'s tier letter for the book (S/A/B/C/D/F) when they ranked it.
        /// Absent on older blends and on fresh picks nobody has read.
        var sourceTier: String?
    }

    // MARK: - Firestore mapping
    //
    // `result` round-trips through JSONEncoder/JSONSerialization (epoch-seconds
    // dates) instead of hand-keyed maps — it's deep-nested and write-once.

    private static func jsonEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private static func jsonDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    var firestoreData: [String: Any] {
        var data: [String: Any] = [
            "userIds": userIds,
            "requesterId": requesterId,
            "recipientId": recipientId,
            "status": status.rawValue,
            "createdAt": Timestamp(date: createdAt),
        ]
        data["respondedAt"] = respondedAt.map { Timestamp(date: $0) } ?? NSNull()
        if let encoded = try? Self.jsonEncoder().encode(participants),
           let map = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
            data["participants"] = map
        }
        if let result,
           let encoded = try? Self.jsonEncoder().encode(result),
           let map = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
            data["result"] = map
        } else if result == nil {
            data["result"] = NSNull()
        }
        return data
    }

    static func from(data: [String: Any], docId: String) -> BookBlend? {
        guard let userIds = data["userIds"] as? [String], userIds.count == 2,
              let requesterId = data["requesterId"] as? String,
              let recipientId = data["recipientId"] as? String,
              let statusRaw = data["status"] as? String,
              let status = BookBlendStatus(rawValue: statusRaw),
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() else { return nil }

        var participants: [String: Participant] = [:]
        if let map = data["participants"] as? [String: Any],
           let json = try? JSONSerialization.data(withJSONObject: map),
           let decoded = try? jsonDecoder().decode([String: Participant].self, from: json) {
            participants = decoded
        }

        var result: Result?
        if let map = data["result"] as? [String: Any],
           let json = try? JSONSerialization.data(withJSONObject: map),
           // Blends generated before the no-dash house rule still hold em dashes
           // in their AI copy; clean them on read rather than regenerating.
           let decoded = try? jsonDecoder().decode(
               Result.self,
               from: Data(ClaudeService.stripDashes(String(decoding: json, as: UTF8.self)).utf8)
           ) {
            result = decoded
        }

        return BookBlend(
            id: docId,
            userIds: userIds,
            requesterId: requesterId,
            recipientId: recipientId,
            status: status,
            createdAt: createdAt,
            respondedAt: (data["respondedAt"] as? Timestamp)?.dateValue(),
            participants: participants,
            result: result
        )
    }
}
