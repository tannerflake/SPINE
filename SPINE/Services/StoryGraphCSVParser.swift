//
//  StoryGraphCSVParser.swift
//  SPINE
//
//  Parses a StoryGraph library export ("The StoryGraph Data.csv") into the
//  same `GoodreadsRow` shape the import wizard already walks through, so the
//  book-by-book review, queue prompt, dedup and resume logic are shared
//  verbatim between the two sources.
//
//  StoryGraph columns (2026 export): Title, Authors, Contributors, ISBN/UID,
//  Format, Read Status, Date Added, Last Date Read, Dates Read, Read Count,
//  Moods, Pace, …, Star Rating, Review, Content Warnings, …, Tags, Owned?
//

import Foundation

/// Where a library export came from. Drives copy in the wizard and which
/// export page the embedded browser opens.
enum LibraryImportSource: String, Codable, CaseIterable, Identifiable {
    case goodreads
    case storyGraph

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .goodreads: return "Goodreads"
        case .storyGraph: return "StoryGraph"
        }
    }

    /// The file name users see when they download the export themselves.
    var exportFileName: String {
        switch self {
        case .goodreads: return "goodreads_library_export.csv"
        case .storyGraph: return "The StoryGraph Data.csv"
        }
    }
}

/// A parsed export: which service it came from plus its rows.
struct LibraryExport {
    let source: LibraryImportSource
    let rows: [GoodreadsRow]
}

/// Source-agnostic entry point: sniffs the header row and hands the file to
/// the right parser. Both the embedded export browser and the "already have
/// the file?" picker go through here, so picking the wrong source in the
/// wizard never produces a bogus "no books found".
enum LibraryExportParser {
    static func parse(data: Data) -> LibraryExport? {
        guard let csv = GoodreadsCSVParser.decode(data) else { return nil }
        let header = csv.prefix(2_000).lowercased()
        if header.contains("read status") || header.contains("isbn/uid") {
            let rows = StoryGraphCSVParser.parse(csv: csv)
            return rows.isEmpty ? nil : LibraryExport(source: .storyGraph, rows: rows)
        }
        let rows = GoodreadsCSVParser.parse(csv: csv)
        return rows.isEmpty ? nil : LibraryExport(source: .goodreads, rows: rows)
    }
}

/// StoryGraph CSV column names (export format).
private enum StoryGraphColumn: String {
    case title = "Title"
    case authors = "Authors"
    case isbnOrUID = "ISBN/UID"
    case readStatus = "Read Status"
    case dateAdded = "Date Added"
    case lastDateRead = "Last Date Read"
    case starRating = "Star Rating"
    case review = "Review"
    case tags = "Tags"
}

final class StoryGraphCSVParser {
    static func parse(data: Data) -> [GoodreadsRow] {
        guard let csv = GoodreadsCSVParser.decode(data) else { return [] }
        return parse(csv: csv)
    }

    static func parse(csv: String) -> [GoodreadsRow] {
        let records = GoodreadsCSVParser.parseCSVRecords(csv)
        guard let headers = records.first, !headers.isEmpty else { return [] }
        var columnIndex: [StoryGraphColumn: Int] = [:]
        for (idx, h) in headers.enumerated() {
            if let col = StoryGraphColumn(rawValue: h.trimmingCharacters(in: .whitespacesAndNewlines)) {
                columnIndex[col] = idx
            }
        }
        // Without these two the file isn't a StoryGraph export at all.
        guard columnIndex[.title] != nil, columnIndex[.readStatus] != nil else { return [] }

        var rows: [GoodreadsRow] = []
        for values in records.dropFirst() {
            guard values.count > 1 else { continue }
            func field(_ col: StoryGraphColumn) -> String? {
                guard let idx = columnIndex[col], idx < values.count else { return nil }
                let v = values[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
            guard let title = field(.title) else { continue }
            let author = field(.authors) ?? "Unknown"
            let (isbn, isbn13) = splitISBN(field(.isbnOrUID))
            let stars = field(.starRating).flatMap(Double.init)
            rows.append(GoodreadsRow(
                id: rowId(uid: field(.isbnOrUID), title: title, author: author),
                title: title,
                author: author,
                isbn: isbn,
                isbn13: isbn13,
                myRating: parseRating(field(.starRating)),
                dateRead: GoodreadsCSVParser.parseDate(field(.lastDateRead)),
                dateAdded: GoodreadsCSVParser.parseDate(field(.dateAdded)),
                // Same vocabulary as Goodreads' exclusive shelf (to-read, read,
                // currently-reading) plus StoryGraph's did-not-finish / paused.
                exclusiveShelf: field(.readStatus)?.lowercased(),
                bookshelves: parseTags(field(.tags)),
                // Quarter stars survive here verbatim even though the card rounds them.
                myReview: GoodreadsCSVParser.review(field(.review), appendingStars: stars, source: .storyGraph)
            ))
        }
        return rows
    }

    /// StoryGraph has no book id column. Use the ISBN/UID when present, else
    /// a title+author key, so a re-exported file lines up with a saved wizard
    /// session (the model carries decisions over by row id).
    private static func rowId(uid: String?, title: String, author: String) -> String {
        if let uid, !uid.isEmpty { return "sg:\(uid)" }
        let key = "\(title)|\(author)".lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return "sg:\(key)"
    }

    /// The ISBN/UID column holds an ISBN-13, an ISBN-10, or an opaque
    /// StoryGraph id for books without one. Only digit runs of the right
    /// length are treated as ISBNs.
    private static func splitISBN(_ s: String?) -> (isbn: String?, isbn13: String?) {
        guard let s else { return (nil, nil) }
        let digits = s.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        switch digits.count {
        case 13 where digits.allSatisfy(\.isNumber): return (nil, digits)
        case 10: return (digits.uppercased(), nil)
        default: return (nil, nil)
        }
    }

    /// StoryGraph allows quarter stars ("4.25"). The wizard card is whole
    /// stars, so round to the nearest star; 0 / blank means unrated.
    private static func parseRating(_ s: String?) -> Int? {
        guard let s, let value = Double(s), value > 0 else { return nil }
        return max(1, min(5, Int(value.rounded())))
    }

    private static func parseTags(_ s: String?) -> [String] {
        guard let s else { return [] }
        return s.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
