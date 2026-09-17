//
//  LocalLibraryCache.swift
//  SPINE
//
//  On-disk cache of the user's library (userBooks with embedded books) for instant load on launch.
//

import Foundation

final class LocalLibraryCache {
    static let shared = LocalLibraryCache()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    /// Directory for cache files (Application Support / WellRead / LibraryCache).
    private func cacheDirectory() throws -> URL {
        let appSupport = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        // On-disk path: keeps the pre-rename "WellRead" name so existing caches load.
        let dir = appSupport.appendingPathComponent("WellRead", isDirectory: true).appendingPathComponent("LibraryCache", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fileURL(userId: String) throws -> URL {
        let sanitized = userId.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return try cacheDirectory().appendingPathComponent("library_\(sanitized).json")
    }

    /// Load cached library for the given user. Returns nil if no cache or decode error.
    func loadLibrary(userId: String) -> [UserBook]? {
        guard let url = try? fileURL(userId: userId),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let list = try? decoder.decode([UserBook].self, from: data) else { return nil }
        return list
    }

    /// Save library to disk. Call on main or background queue; file I/O is small.
    func saveLibrary(_ userBooks: [UserBook], userId: String) {
        guard let url = try? fileURL(userId: userId),
              let data = try? encoder.encode(userBooks) else { return }
        try? data.write(to: url)
    }

    /// Remove cached library for the given user (e.g. on sign-out if desired).
    func clearCache(userId: String) {
        guard let url = try? fileURL(userId: userId), fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }
}
