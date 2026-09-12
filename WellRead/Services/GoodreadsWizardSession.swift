//
//  GoodreadsWizardSession.swift
//  WellRead
//
//  Persistable state for the book-by-book Goodreads import wizard, so the user
//  can close the app mid-import and pick up exactly where they left off.
//  Stored per-user in UserDefaults as JSON.
//

import Foundation

/// What the user (or the wizard) decided about one Goodreads row.
enum GoodreadsRowDecision: String, Codable {
    /// Added to the library.
    case imported
    /// User tapped Skip — revisitable from the summary screen.
    case skipped
    /// Already in the library — auto-skipped.
    case duplicate
    /// No catalog match, even after the manual search-to-match card — the user
    /// gave up on it there. Never applied automatically.
    case unmatched
    /// User declined the whole queue phase ("No thanks").
    case declined
}

/// Which stage of the import flow the session is in.
enum GoodreadsWizardPhase: String, Codable {
    /// Walking through read books one by one.
    case readBooks
    /// All read books handled; asking about queue (to-read) books.
    case queuePrompt
    /// Walking through queue books one by one.
    case queueBooks
    /// Everything handled.
    case done
}

struct GoodreadsWizardSession: Codable {
    /// Read-shelf rows, most recently read first.
    var readRows: [GoodreadsRow]
    /// Not-yet-read rows (to-read / currently-reading), handled after read books.
    var queueRows: [GoodreadsRow]
    /// Row id → decision. Rows without an entry are still pending.
    var decisions: [String: GoodreadsRowDecision]
    var phase: GoodreadsWizardPhase
    /// Matched books cached by row id so resuming doesn't refetch.
    var matchedBooks: [String: Book]
    var createdAt: Date

    init(readRows: [GoodreadsRow], queueRows: [GoodreadsRow]) {
        self.readRows = readRows
        self.queueRows = queueRows
        self.decisions = [:]
        self.phase = .readBooks
        self.matchedBooks = [:]
        self.createdAt = Date()
    }

    /// Rows for the phase currently being walked through.
    var activeRows: [GoodreadsRow] {
        switch phase {
        case .readBooks: return readRows
        case .queuePrompt, .queueBooks: return queueRows
        case .done: return []
        }
    }

    /// Next undecided row in the active phase.
    var currentRow: GoodreadsRow? {
        activeRows.first { decisions[$0.id] == nil }
    }

    /// 1-based position of the current book within the active phase (for "Book 3 of 42").
    var currentPosition: Int {
        let decided = activeRows.filter { decisions[$0.id] != nil }.count
        return min(decided + 1, max(activeRows.count, 1))
    }

    var pendingReadCount: Int {
        readRows.filter { decisions[$0.id] == nil }.count
    }

    var pendingQueueCount: Int {
        queueRows.filter { decisions[$0.id] == nil }.count
    }

    var importedCount: Int {
        decisions.values.filter { $0 == .imported }.count
    }

    var skippedCount: Int {
        decisions.values.filter { $0 == .skipped }.count
    }

    var duplicateCount: Int {
        decisions.values.filter { $0 == .duplicate }.count
    }

    var unmatchedCount: Int {
        decisions.values.filter { $0 == .unmatched }.count
    }

    /// True while there's anything left for the user to do.
    var hasRemainingWork: Bool {
        switch phase {
        case .readBooks: return pendingReadCount > 0 || !queueRows.isEmpty
        case .queuePrompt: return true
        case .queueBooks: return pendingQueueCount > 0
        case .done: return false
        }
    }

    /// Books left to act on — shown in the resume callout.
    var remainingCount: Int {
        switch phase {
        case .readBooks: return pendingReadCount
        case .queuePrompt, .queueBooks: return pendingQueueCount
        case .done: return 0
        }
    }

    /// Build a fresh session from parsed CSV rows: read books most-recently-read
    /// first, everything not yet read held back for the queue phase.
    static func fromRows(_ rows: [GoodreadsRow]) -> GoodreadsWizardSession {
        var read: [GoodreadsRow] = []
        var queue: [GoodreadsRow] = []
        for row in dedupedByWork(rows) {
            switch GoodreadsImportService.status(for: row.exclusiveShelf) {
            case .read: read.append(row)
            case .wantToRead, .currentlyReading: queue.append(row)
            case .didNotFinish: break // never produced by this mapping today
            }
        }
        read.sort { sortDate($0) > sortDate($1) }
        return GoodreadsWizardSession(readRows: read, queueRows: queue)
    }

    private static func sortDate(_ row: GoodreadsRow) -> Date {
        row.dateRead ?? row.dateAdded ?? .distantPast
    }

    /// Goodreads lists each shelved *edition* as its own row, so one export can
    /// contain the same book several times. Collapse rows for the same work
    /// before the wizard ever sees them, keeping the most informative row.
    static func dedupedByWork(_ rows: [GoodreadsRow]) -> [GoodreadsRow] {
        var kept: [GoodreadsRow] = []
        var indexByKey: [String: Int] = [:]
        for row in rows {
            guard let key = LibraryDedup.workKey(title: row.title, author: row.author) else {
                kept.append(row)
                continue
            }
            if let i = indexByKey[key] {
                kept[i] = preferredRow(kept[i], row)
            } else {
                indexByKey[key] = kept.count
                kept.append(row)
            }
        }
        return kept
    }

    /// Read shelf beats unread, then rated, reviewed, has-ISBN, most recent.
    private static func preferredRow(_ a: GoodreadsRow, _ b: GoodreadsRow) -> GoodreadsRow {
        func score(_ r: GoodreadsRow) -> Int {
            var s = 0
            if GoodreadsImportService.status(for: r.exclusiveShelf) == .read { s += 8 }
            if (r.myRating ?? 0) > 0 { s += 4 }
            if !(r.myReview ?? "").isEmpty { s += 2 }
            if r.isbn13 != nil || r.isbn != nil { s += 1 }
            return s
        }
        if score(a) != score(b) { return score(a) > score(b) ? a : b }
        return sortDate(a) >= sortDate(b) ? a : b
    }
}

// MARK: - Persistence

enum GoodreadsWizardStore {
    private static func key(uid: String) -> String { "goodreadsWizardSession_\(uid)" }

    static func load(uid: String) -> GoodreadsWizardSession? {
        guard let data = UserDefaults.standard.data(forKey: key(uid: uid)) else { return nil }
        return try? JSONDecoder().decode(GoodreadsWizardSession.self, from: data)
    }

    static func save(_ session: GoodreadsWizardSession, uid: String) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: key(uid: uid))
    }

    static func clear(uid: String) {
        UserDefaults.standard.removeObject(forKey: key(uid: uid))
    }

    /// Count for the "finish your import" callout; 0 when there's nothing to resume.
    static func remainingCount(uid: String) -> Int {
        guard let s = load(uid: uid), s.hasRemainingWork else { return 0 }
        return max(s.remainingCount, 1)
    }
}
