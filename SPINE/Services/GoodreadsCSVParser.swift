//
//  GoodreadsCSVParser.swift
//  SPINE
//
//  Parses Goodreads library export CSV. Deterministic parse; normalizes messy fields.
//

import Foundation

/// One row from a Goodreads export (relevant fields only).
/// Codable so an in-progress import wizard session can be persisted and resumed.
struct GoodreadsRow: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let author: String
    let isbn: String?
    let isbn13: String?
    let myRating: Int?
    let dateRead: Date?
    let dateAdded: Date?
    let exclusiveShelf: String?
    let bookshelves: [String]
    let myReview: String?
}

extension GoodreadsRow {
    /// Goodreads exports reviews as HTML fragments — line breaks arrive as
    /// `<br/>`, emphasis as `<b>`/`<i>`, and special characters as entities
    /// (`&amp;`, `&#39;`). `myReview` keeps the raw value (persisted wizard
    /// sessions already store it); read this wherever the review is shown
    /// or saved so the markup never reaches the user.
    var plainTextReview: String? {
        GoodreadsCSVParser.plainText(fromReviewHTML: myReview)
    }
}

/// Goodreads CSV column names (export format).
private enum GoodreadsColumn: String, CaseIterable {
    case bookId = "Book Id"
    case title = "Title"
    case author = "Author"
    case isbn = "ISBN"
    case isbn13 = "ISBN13"
    case myRating = "My Rating"
    case dateRead = "Date Read"
    case dateAdded = "Date Added"
    case exclusiveShelf = "Exclusive Shelf"
    case bookshelves = "Bookshelves"
    case myReview = "My Review"
}

final class GoodreadsCSVParser {
    private static let utf8 = String.Encoding.utf8
    private static let isoLatin1 = String.Encoding.isoLatin1

    /// Parses Goodreads CSV data into rows. Tries UTF-8 then ISO-Latin-1. Returns empty array on parse failure.
    static func parse(data: Data) -> [GoodreadsRow] {
        let raw: String
        if let s = String(data: data, encoding: .utf8) {
            raw = s
        } else if let s = String(data: data, encoding: .isoLatin1) {
            raw = s
        } else {
            return []
        }
        return parse(csv: raw)
    }

    static func parse(csv: String) -> [GoodreadsRow] {
        var rows: [GoodreadsRow] = []
        // Goodreads export is often tab-separated when copied (e.g. from file preview or Sheets).
        let firstLine = csv.prefix(while: { $0 != "\n" && $0 != "\r" && $0 != "\r\n" })
        let isTSV = firstLine.contains("\t")
        let records: [[String]]
        if isTSV {
            records = csv.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { $0.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) } }
        } else {
            records = parseCSVRecords(csv)
        }
        guard let headers = records.first, !headers.isEmpty else { return [] }
        let columnIndex: [GoodreadsColumn: Int] = {
            var map: [GoodreadsColumn: Int] = [:]
            for (idx, h) in headers.enumerated() {
                if let col = GoodreadsColumn(rawValue: h.trimmingCharacters(in: .whitespaces)) {
                    map[col] = idx
                }
            }
            return map
        }()
        for values in records.dropFirst() {
            guard values.count > 1 else { continue }
            let bookId = value(at: .bookId, from: values, map: columnIndex) ?? ""
            let title = normalizeTitle(value(at: .title, from: values, map: columnIndex))
            let author = normalizeAuthor(value(at: .author, from: values, map: columnIndex))
            guard !title.isEmpty else { continue }
            let isbn = normalizeISBN(value(at: .isbn, from: values, map: columnIndex))
            let isbn13 = normalizeISBN(value(at: .isbn13, from: values, map: columnIndex))
            let rating = parseRating(value(at: .myRating, from: values, map: columnIndex))
            let dateRead = parseDate(value(at: .dateRead, from: values, map: columnIndex))
            let dateAdded = parseDate(value(at: .dateAdded, from: values, map: columnIndex))
            let exclusiveShelf = value(at: .exclusiveShelf, from: values, map: columnIndex)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            let shelves = parseBookshelves(value(at: .bookshelves, from: values, map: columnIndex))
            let myReview = value(at: .myReview, from: values, map: columnIndex)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            rows.append(GoodreadsRow(
                id: bookId.isEmpty ? UUID().uuidString : bookId,
                title: title,
                author: author,
                isbn: isbn,
                isbn13: isbn13,
                myRating: rating,
                dateRead: dateRead,
                dateAdded: dateAdded,
                exclusiveShelf: exclusiveShelf,
                bookshelves: shelves,
                myReview: myReview
            ))
        }
        return rows
    }

    private static func value(at column: GoodreadsColumn, from values: [String], map: [GoodreadsColumn: Int]) -> String? {
        guard let idx = map[column], idx < values.count else { return nil }
        return values[idx].trimmingCharacters(in: .whitespaces)
    }

    /// RFC-4180 record scanner: quoted fields may contain commas, escaped quotes
    /// (""), and — critically — newlines. Goodreads reviews are frequently
    /// multi-line; splitting the file by lines first truncated those rows and
    /// spawned junk fragment rows that ended up "unmatched" in the import wizard.
    private static func parseCSVRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if inQuotes {
                if ch == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"":
                    inQuotes = true
                case ",":
                    record.append(field)
                    field = ""
                case "\r":
                    break
                // "\r\n" is a single Character (grapheme cluster) in Swift, so a
                // CRLF file never hits the "\n" case without it listed explicitly.
                case "\n", "\r\n":
                    record.append(field)
                    field = ""
                    if !record.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        records.append(record)
                    }
                    record = []
                default:
                    field.append(ch)
                }
            }
            i = text.index(after: i)
        }
        record.append(field)
        if !record.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            records.append(record)
        }
        return records
    }

    private static func normalizeTitle(_ s: String?) -> String {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return "" }
        return s
    }

    private static func normalizeAuthor(_ s: String?) -> String {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return "Unknown" }
        return s
    }

    /// Goodreads sometimes exports ISBN as ="0060590297". Strip equals and quotes.
    private static func normalizeISBN(_ s: String?) -> String? {
        guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t.hasPrefix("=\"") && t.hasSuffix("\"") { t = String(t.dropFirst(2).dropLast(1)) }
        if t.hasPrefix("=") { t = String(t.dropFirst(1)) }
        t = t.replacingOccurrences(of: "\"", with: "")
        let digits = t.filter(\.isNumber)
        return digits.isEmpty ? nil : digits
    }

    private static func parseRating(_ s: String?) -> Int? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let i = Int(s), (1...5).contains(i) { return i }
        return nil
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        // Goodreads allows partial read dates, so the export can contain
        // "2016/04/12", "2016/04", or just "2016" — all must parse.
        let formatters: [DateFormatter] = [
            { let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }(),
            { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }(),
            { let f = DateFormatter(); f.dateFormat = "MM/dd/yyyy"; f.locale = Locale(identifier: "en_US_POSIX"); return f }(),
            { let f = DateFormatter(); f.dateFormat = "yyyy/MM"; f.locale = Locale(identifier: "en_US_POSIX"); return f }(),
            { let f = DateFormatter(); f.dateFormat = "yyyy-MM"; f.locale = Locale(identifier: "en_US_POSIX"); return f }(),
            { let f = DateFormatter(); f.dateFormat = "yyyy"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
        ]
        for f in formatters {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// Reduces a Goodreads review HTML fragment to plain text: break-like
    /// tags become newlines, every other tag is dropped, and HTML entities
    /// are decoded. Plain-text reviews pass through untouched.
    static func plainText(fromReviewHTML html: String?) -> String? {
        guard var t = html?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        guard t.contains("<") || t.contains("&") else { return t }
        t = t.replacingOccurrences(of: "<br\\s*/?\\s*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "</(p|div|blockquote)>", with: "\n\n", options: [.regularExpression, .caseInsensitive])
        // Only strip runs that look like actual tags (letter after the angle
        // bracket) so prose like "4 < 5 but > 3" survives.
        t = t.replacingOccurrences(of: "</?[a-zA-Z][^<>]*>", with: "", options: .regularExpression)
        t = decodeHTMLEntities(t)
        t = t.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        var t = s
        // Numeric entities: &#8217; and &#x2019;
        while let range = t.range(of: "&#(?:x[0-9a-fA-F]+|[0-9]+);", options: [.regularExpression, .caseInsensitive]) {
            let body = t[range].dropFirst(2).dropLast()
            let value = body.lowercased().hasPrefix("x")
                ? UInt32(body.dropFirst(), radix: 16)
                : UInt32(body)
            if let v = value, let scalar = Unicode.Scalar(v) {
                t.replaceSubrange(range, with: String(Character(scalar)))
            } else {
                t.replaceSubrange(range, with: "")
            }
        }
        // &amp; must decode last so double-escaped text ("&amp;lt;") stays literal.
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&quot;", "\""), ("&apos;", "'"),
            ("&lsquo;", "\u{2018}"), ("&rsquo;", "\u{2019}"),
            ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
            ("&mdash;", "\u{2014}"), ("&ndash;", "\u{2013}"), ("&hellip;", "\u{2026}"),
            ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")
        ]
        for (entity, char) in named {
            t = t.replacingOccurrences(of: entity, with: char)
        }
        return t
    }

    private static func parseBookshelves(_ s: String?) -> [String] {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return [] }
        return s.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
