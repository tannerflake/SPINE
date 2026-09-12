//
//  WidgetSnapshot.swift
//  WellRead
//
//  Shared between the app target (writer) and WellReadWidget (reader).
//  Foundation-only: the widget target compiles this file without the app's
//  models, so it must never reference Book/User/Theme.
//

import Foundation

/// Compact "reading now" payload the app writes into the App Group for the widget.
struct WidgetSnapshot: Codable {
    struct BookEntry: Codable {
        let bookId: String
        let title: String
        let author: String
        /// Filename inside `WidgetSharedStore.imagesDirectory`; nil renders a title-card fallback.
        let coverFilename: String?
        /// Reading progress 0...1 for the owner's own books (`userBooks.readingProgress`).
        /// nil means never set — the widget draws no bookmark and no percent.
        /// Always nil for friends' books: the friends query returns `Book`s, not
        /// their `UserBook` rows, so their progress isn't available to the app.
        var progress: Double? = nil
    }

    struct FriendEntry: Codable {
        let uid: String
        let displayName: String
        let avatarFilename: String?
        let books: [BookEntry]
    }

    let schemaVersion: Int
    let isSignedIn: Bool
    /// Own reading-now shelf in queue order. Both families show every cover;
    /// which one sits on top of the stack rotates with the timeline tick.
    let myBooks: [BookEntry]
    /// Friends with at least one reading-now book, at most 8; the medium
    /// widget rotates through their books in pages.
    let friends: [FriendEntry]
    let generatedAt: Date
}

/// App Group paths + JSON coding used identically by app and widget.
/// Encoder and decoder live side by side so the date strategy can't drift.
enum WidgetSharedStore {
    static let appGroupId = "group.com.wellread.app"
    static let currentSchemaVersion = 2

    static var containerURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
            .appendingPathComponent("WidgetData", isDirectory: true)
    }

    static var snapshotURL: URL? {
        containerURL?.appendingPathComponent("snapshot.json")
    }

    static var imagesDirectory: URL? {
        containerURL?.appendingPathComponent("images", isDirectory: true)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// nil on missing file, decode failure, or schema version mismatch.
    static func loadSnapshot() -> WidgetSnapshot? {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? makeDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.schemaVersion == currentSchemaVersion else { return nil }
        return snapshot
    }

    static func imageURL(for filename: String?) -> URL? {
        guard let filename, !filename.isEmpty, let dir = imagesDirectory else { return nil }
        return dir.appendingPathComponent(filename)
    }
}
