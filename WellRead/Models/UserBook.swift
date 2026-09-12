//
//  UserBook.swift
//  WellRead
//
//  Relationship between User and Book: status, rating, dates, tier.
//

import Foundation

enum ReadingStatus: String, Codable, CaseIterable {
    case wantToRead = "Queue"
    case currentlyReading = "Currently Reading"
    case read = "Read"
    /// Started but abandoned — pulled off the queue's Reading Now shelf, kept
    /// around in its own list instead of being deleted outright.
    case didNotFinish = "Did Not Finish"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "Queue", "Want to Read": self = .wantToRead
        case "Currently Reading": self = .currentlyReading
        case "Read": self = .read
        case "Did Not Finish": self = .didNotFinish
        default: self = .wantToRead
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Sub-queue within "Want to read": **Reading now**, **Up next**, or **Backlog** (default).
/// Existing books with no shelf set are treated as backlog.
enum QueueShelf: String, Codable, CaseIterable {
    case readingNow
    case upNext
    case backlog
}

/// "A long, long time ago" reads: books someone finished years back (school,
/// childhood) with no date they'd stand behind. Rather than leaving the read
/// dateless, we stamp a sentinel finish date so the read still counts, still
/// sorts to the bottom of every timeline, and reads as "Old" wherever a finish
/// date is shown.
enum ReadDate {
    /// The sentinel that lands in Firestore: 1900-01-01, local midnight.
    static let longAgo: Date = {
        var parts = DateComponents()
        parts.year = longAgoYear
        parts.month = 1
        parts.day = 1
        return Calendar.current.date(from: parts) ?? Date(timeIntervalSince1970: -2_208_988_800)
    }()

    static let longAgoYear = 1900

    /// Label shown in place of a formatted date for long-ago reads.
    static let oldLabel = "Old"

    /// Anything in 1900 or earlier counts, so timezone drift on stored rows
    /// (and any legacy placeholder dates) still read as long-ago.
    static func isLongAgo(_ date: Date, calendar: Calendar = .current) -> Bool {
        calendar.component(.year, from: date) <= longAgoYear
    }

    static func isLongAgo(year: Int) -> Bool {
        year <= longAgoYear
    }

    /// "Old" for long-ago reads, otherwise the formatted date.
    static func label(_ date: Date, formatter: DateFormatter) -> String {
        isLongAgo(date) ? oldLabel : formatter.string(from: date)
    }

    /// "Old" instead of "1900" in year sections and year filters.
    static func yearLabel(_ year: Int) -> String {
        isLongAgo(year: year) ? oldLabel : String(year)
    }
}

struct UserBook: Identifiable, Codable, Equatable {
    var id: UUID
    var userId: String  // Firebase Auth uid (for Firestore query)
    var bookId: String
    var book: Book?
    var status: ReadingStatus
    /// User rating out of 10 (e.g. 8.8). Legacy Firestore ints 1–10 are read as 8.0, etc.
    var rating: Double?
    var reviewText: String?
    var dateStarted: Date?
    var dateFinished: Date?
    var createdAt: Date
    var updatedAt: Date
    var recommendedTo: [UUID]
    var tier: String?  // S, A, B, C, D for tier list
    var tierOrder: Int?  // order within tier (0-based); nil = end
    /// Only for `status == .wantToRead`. `nil` means backlog (legacy / default).
    var queueShelf: QueueShelf?
    /// Order within the shelf (0 = first / top-left). `nil` only for legacy backlog rows before migration.
    var queueOrder: Int?
    /// Re-read dates beyond `dateFinished` (which stays the most recent read).
    /// One library/tier entry per book; each date counts toward that year's reading goal.
    var additionalReadDates: [Date]? = nil
    /// Private "note to self" on a queued book — why it's here, who recommended it.
    /// Only meaningful while `status == .wantToRead`; never shown to other readers.
    var queueNote: String? = nil
    /// How far through the book the reader is, 0...1. Set from the Reading now
    /// bookmark scrubber; `nil` until they first touch it. Kept when the book
    /// moves shelves so coming back to it picks up where they left off.
    var readingProgress: Double? = nil

    /// `readingProgress` clamped to 0...1, treating unset as 0.
    var progressFraction: Double {
        min(1, max(0, readingProgress ?? 0))
    }

    /// Whole-number percent for display (0...100).
    var progressPercent: Int {
        Int((progressFraction * 100).rounded())
    }

    /// Page the reader is on, derived from the book's page count. `nil` when the
    /// edition has no page count. Rounds so 100% always lands on the last page.
    var currentPage: Int? {
        guard let pages = book?.pageCount, pages > 0 else { return nil }
        return Self.page(forFraction: progressFraction, pageCount: pages)
    }

    static func page(forFraction fraction: Double, pageCount: Int) -> Int {
        let f = min(1, max(0, fraction))
        return min(pageCount, max(0, Int((f * Double(pageCount)).rounded())))
    }

    /// `queueNote` with whitespace trimmed, `nil` when blank.
    var trimmedQueueNote: String? {
        let t = queueNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    /// Every recorded finished date — primary `dateFinished` plus re-reads, newest first.
    var allReadDates: [Date] {
        var dates = additionalReadDates ?? []
        if let d = dateFinished { dates.append(d) }
        return dates.sorted(by: >)
    }

    /// True when any recorded read date falls in `year` — a book read in 2022 and
    /// 2025 counts toward both years.
    func wasRead(inYear year: Int, calendar: Calendar = .current) -> Bool {
        allReadDates.contains { calendar.component(.year, from: $0) == year }
    }

    /// Tier with legacy empty strings collapsed to nil, so "" never acts as a distinct tier.
    var normalizedTier: String? {
        guard let t = tier, !t.isEmpty else { return nil }
        return t
    }

    static let demoList: [UserBook] = {
        let b1 = Book(id: "1", title: "Atomic Habits", author: "James Clear", coverURL: "https://books.google.com/books/content?id=wRqtDwAAQBAJ&printsec=frontcover&img=1", pageCount: 320, publishedDate: nil, description: nil, genres: ["Self-Help"])
        let b2 = Book(id: "2", title: "Deep Work", author: "Cal Newport", coverURL: "https://books.google.com/books/content?id=6h76CwAAQBAJ&printsec=frontcover&img=1", pageCount: 296, publishedDate: nil, description: nil, genres: ["Productivity"])
        let b3 = Book(id: "3", title: "The Midnight Library", author: "Matt Haig", coverURL: "https://books.google.com/books/content?id=zLk9DwAAQBAJ&printsec=frontcover&img=1", pageCount: 304, publishedDate: nil, description: nil, genres: ["Fiction"])
        let now = Date()
        let demoUserId = "demo-user-id"
        return [
            UserBook(id: UUID(), userId: demoUserId, bookId: b1.id, book: b1, status: .read, rating: 9.0, reviewText: "Life-changing.", dateStarted: now.addingTimeInterval(-86400*30), dateFinished: now.addingTimeInterval(-86400*7), createdAt: now, updatedAt: now, recommendedTo: [], tier: "S", tierOrder: 0, queueShelf: nil, queueOrder: nil),
            UserBook(id: UUID(), userId: demoUserId, bookId: b2.id, book: b2, status: .read, rating: 8.4, reviewText: "Essential for focus.", dateStarted: now.addingTimeInterval(-86400*60), dateFinished: now.addingTimeInterval(-86400*35), createdAt: now, updatedAt: now, recommendedTo: [], tier: "A", tierOrder: 0, queueShelf: nil, queueOrder: nil),
            UserBook(id: UUID(), userId: demoUserId, bookId: b3.id, book: b3, status: .currentlyReading, rating: nil, reviewText: nil, dateStarted: now.addingTimeInterval(-86400*3), dateFinished: nil, createdAt: now, updatedAt: now, recommendedTo: [], tier: nil, tierOrder: nil, queueShelf: nil, queueOrder: nil)
        ]
    }()
}

/// The one ordering for books inside a tier row. `tierOrder` wins; books without one
/// tie-break on createdAt/id instead of falling back to array position — `userBooks`
/// arrives sorted by `updatedAt` desc, so position-based ties reshuffle on every
/// Firestore echo and drop-slot indices stop matching what's on screen.
func spineTierSorted(_ books: [UserBook]) -> [UserBook] {
    books.sorted { a, b in
        let ao = a.tierOrder ?? Int.max
        let bo = b.tierOrder ?? Int.max
        if ao != bo { return ao < bo }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }
}
