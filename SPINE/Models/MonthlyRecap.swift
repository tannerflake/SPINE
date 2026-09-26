//
//  MonthlyRecap.swift
//  SPINE
//
//  "See your September reading": on the first of each month a Cloud Function
//  writes `users/{uid}.monthlyRecap` for every member who finished a book the
//  month before, and sends the matching push. The field is a single slot, not
//  a list: each month overwrites the last, so a reader who has been away for
//  a while comes back to one recap (the latest), never a stack. The app owns
//  only `seenAt`, set the moment the recap modal presents or its push is
//  tapped. Copy rule: no em-dashes in user-facing text.
//

import Foundation
import FirebaseFirestore

struct MonthlyRecap: Equatable, Codable, Identifiable {
    /// Calendar year of the month recapped.
    let year: Int
    /// 1...12.
    let month: Int
    /// Books finished that month as counted by the function (the share hub
    /// recounts from the local library, so this is only for copy).
    let bookCount: Int
    let createdAt: Date
    /// Set once the reader has been shown the recap (modal or push tap).
    var seenAt: Date?

    /// The `YYYY-MM` key the function writes and the push carries as `recapMonth`.
    var monthKey: String { Self.monthKey(year: year, month: month) }
    var id: String { monthKey }

    var period: SharePeriod { .month(year: year, month: month) }

    /// "September", for the modal headline and the push title.
    var monthName: String {
        let symbols = DateFormatter().standaloneMonthSymbols ?? []
        guard month >= 1, month <= symbols.count else { return "" }
        return symbols[month - 1]
    }

    static func monthKey(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    /// Parses `YYYY-MM` into (year, month); nil for anything else.
    static func parseMonthKey(_ key: String) -> (year: Int, month: Int)? {
        let parts = key.split(separator: "-")
        guard parts.count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]),
              (1...12).contains(m), y > 1900 else { return nil }
        return (y, m)
    }

    /// Parses the `monthlyRecap` map on a user doc.
    init?(firestoreMap raw: [String: Any]?) {
        guard let raw,
              let key = raw["month"] as? String,
              let ym = Self.parseMonthKey(key) else { return nil }
        year = ym.year
        month = ym.month
        bookCount = (raw["bookCount"] as? Int) ?? ((raw["bookCount"] as? NSNumber)?.intValue ?? 0)
        createdAt = (raw["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        seenAt = (raw["seenAt"] as? Timestamp)?.dateValue()
    }

    init(year: Int, month: Int, bookCount: Int, createdAt: Date, seenAt: Date?) {
        self.year = year
        self.month = month
        self.bookCount = bookCount
        self.createdAt = createdAt
        self.seenAt = seenAt
    }
}

extension User {
    /// A recap written by the function that the reader has not been shown yet.
    var unseenMonthlyRecap: MonthlyRecap? {
        guard let recap = monthlyRecap, recap.seenAt == nil else { return nil }
        return recap
    }
}
