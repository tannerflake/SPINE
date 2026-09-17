//
//  DiscoverCriteria.swift
//  Spine
//
//  User-editable criteria driving Discover suggestions. Empty everything == default
//  behavior (overall taste: read books + readingInterestTags). Persisted as the
//  `discoverCriteria` map on the Firestore user doc.
//

import Foundation

/// One library book chosen as a recommendation seed. Snapshots title/author so
/// chips and prompt-building work even if the Book isn't loaded or the review was deleted.
struct DiscoverSeedBook: Codable, Equatable, Hashable {
    let bookId: String  // Book.id (Google Books id)
    let title: String
    let author: String
}

struct DiscoverCriteria: Codable, Equatable {
    var seedBooks: [DiscoverSeedBook] = []
    var tiers: [String] = []  // subset of spineTierLabels ("S"..."F")
    var tags: [String] = []   // canonical Tags.csv strings
    var freeText: String = "" // natural-language instruction

    var trimmedFreeText: String { freeText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isDefault: Bool {
        seedBooks.isEmpty && tiers.isEmpty && tags.isEmpty && trimmedFreeText.isEmpty
    }

    static let `default` = DiscoverCriteria()
}

// MARK: - Firestore map (manual serialization, matching UserRepository style)

extension DiscoverCriteria {
    var firestoreMap: [String: Any] {
        [
            "seedBooks": seedBooks.map { ["bookId": $0.bookId, "title": $0.title, "author": $0.author] },
            "tiers": tiers,
            "tags": tags,
            "freeText": trimmedFreeText,
        ]
    }

    /// Missing/partial map (legacy accounts) decodes to default values.
    init(firestoreMap map: [String: Any]?) {
        let seeds = (map?["seedBooks"] as? [[String: Any]]) ?? []
        self.seedBooks = seeds.compactMap { d in
            guard let id = d["bookId"] as? String, let title = d["title"] as? String else { return nil }
            return DiscoverSeedBook(bookId: id, title: title, author: d["author"] as? String ?? "")
        }
        self.tiers = ((map?["tiers"] as? [String]) ?? []).filter { spineTierLabels.contains($0) }
        self.tags = map?["tags"] as? [String] ?? []
        self.freeText = map?["freeText"] as? String ?? ""
    }
}
