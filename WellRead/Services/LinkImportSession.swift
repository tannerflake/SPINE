//
//  LinkImportSession.swift
//  WellRead
//
//  Persistable state for the "add books from a shared link" wizard, so a user
//  who closes SPINE halfway through a ten-book list picks up where they left
//  off. Same shape as GoodreadsWizardSession; stored per user in UserDefaults.
//

import Foundation

/// One book the model pulled out of the shared page, before catalog matching.
struct LinkBookCandidate: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    /// Empty when the page didn't name one.
    let author: String
    /// Suggested private note-to-self ("From Mark Cuban's top 10. He says it
    /// taught him to sell."). Editable on the card before queuing.
    let note: String

    init(title: String, author: String, note: String) {
        self.id = UUID().uuidString
        self.title = title
        self.author = author
        self.note = note
    }

    var displayLine: String {
        author.isEmpty ? title : "\(title) · \(author)"
    }
}

/// What happened to one candidate.
enum LinkImportDecision: String, Codable {
    /// Added to the queue.
    case queued
    /// User tapped Skip.
    case skipped
    /// Already in the library (any status) — auto-skipped.
    case duplicate
    /// No catalog match, even after manual search.
    case unmatched
}

struct LinkImportSession: Codable {
    /// Where the books came from, for the header and the notes.
    var sourceURL: URL?
    /// Short human label: "Mark Cuban's top 10 books", "@bookishbecca on TikTok".
    var sourceLabel: String
    var candidates: [LinkBookCandidate]
    /// Candidate id → decision. Missing means still pending.
    var decisions: [String: LinkImportDecision]
    /// Matched books cached by candidate id so resuming doesn't refetch.
    var matchedBooks: [String: Book]
    /// Notes the user edited on a card before deciding (candidate id → note).
    var editedNotes: [String: String]
    var createdAt: Date

    init(sourceURL: URL?, sourceLabel: String, candidates: [LinkBookCandidate]) {
        self.sourceURL = sourceURL
        self.sourceLabel = sourceLabel
        self.candidates = candidates
        self.decisions = [:]
        self.matchedBooks = [:]
        self.editedNotes = [:]
        self.createdAt = Date()
    }

    var isSingleBook: Bool { candidates.count == 1 }

    var currentCandidate: LinkBookCandidate? {
        candidates.first { decisions[$0.id] == nil }
    }

    /// 1-based position for "BOOK 3 OF 10".
    var currentPosition: Int {
        let decided = candidates.filter { decisions[$0.id] != nil }.count
        return min(decided + 1, max(candidates.count, 1))
    }

    var pendingCount: Int { candidates.filter { decisions[$0.id] == nil }.count }
    var hasRemainingWork: Bool { pendingCount > 0 }

    func count(_ decision: LinkImportDecision) -> Int {
        decisions.values.filter { $0 == decision }.count
    }

    func candidates(with decision: LinkImportDecision) -> [LinkBookCandidate] {
        candidates.filter { decisions[$0.id] == decision }
    }

    /// The note that will be saved with a candidate: the user's edit if any,
    /// else the model's suggestion.
    func note(for candidate: LinkBookCandidate) -> String {
        editedNotes[candidate.id] ?? candidate.note
    }
}

// MARK: - Persistence

enum LinkImportStore {
    private static func key(uid: String) -> String { "linkImportSession_\(uid)" }

    static func load(uid: String) -> LinkImportSession? {
        guard let data = UserDefaults.standard.data(forKey: key(uid: uid)) else { return nil }
        return try? JSONDecoder().decode(LinkImportSession.self, from: data)
    }

    static func save(_ session: LinkImportSession, uid: String) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: key(uid: uid))
    }

    static func clear(uid: String) {
        UserDefaults.standard.removeObject(forKey: key(uid: uid))
    }

    /// Books left in a paused session — 0 when there's nothing to resume.
    static func remainingCount(uid: String) -> Int {
        guard let s = load(uid: uid), s.hasRemainingWork else { return 0 }
        return s.pendingCount
    }
}
