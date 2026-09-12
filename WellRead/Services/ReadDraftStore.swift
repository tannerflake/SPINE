//
//  ReadDraftStore.swift
//  Spine
//
//  On-device drafts for the Mark-as-read drawer. Every edit (thoughts, date,
//  tier, feed toggle) is written straight to UserDefaults keyed by uid + bookId,
//  so swiping the drawer away, a deep-link teardown, or a crash never loses a
//  half-written review. Cleared the moment the read is confirmed. Never synced:
//  a draft is private scratch, not part of the library.
//

import Foundation
import FirebaseAuth

struct ReadDraft: Codable, Equatable {
    var thoughts: String = ""
    var dateFinished: Date? = nil
    var tier: String? = nil
    var postToFeed: Bool = true
    var updatedAt: Date = Date()

    /// A draft worth keeping: the user typed something or made a choice that
    /// isn't the default. An untouched drawer leaves nothing behind.
    var hasContent: Bool {
        !thoughts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || dateFinished != nil
            || tier != nil
            || postToFeed == false
    }
}

enum ReadDraftStore {
    private static let keyPrefix = "readDraft_"

    private static func key(bookId: String) -> String? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return keyPrefix + uid + "_" + bookId
    }

    static func load(bookId: String) -> ReadDraft? {
        guard let key = key(bookId: bookId),
              let data = UserDefaults.standard.data(forKey: key),
              let draft = try? JSONDecoder().decode(ReadDraft.self, from: data),
              draft.hasContent
        else { return nil }
        return draft
    }

    /// Writes the draft, or removes the stored one when there's nothing left to keep.
    static func save(_ draft: ReadDraft, bookId: String) {
        guard let key = key(bookId: bookId) else { return }
        guard draft.hasContent else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        var stamped = draft
        stamped.updatedAt = Date()
        if let data = try? JSONEncoder().encode(stamped) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear(bookId: String) {
        guard let key = key(bookId: bookId) else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
