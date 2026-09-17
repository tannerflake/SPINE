//
//  GoodreadsShareHelper.swift
//  SPINE
//
//  Reads CSV written by the Share Extension (app group). Main app only.
//

import Foundation
import Security
import UIKit

/// Returns a URL if the string looks like a Goodreads export CSV link (e.g. from Share → Copy in the Goodreads app). Adds https if missing.
func goodreadsExportURL(from string: String?) -> URL? {
    guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    let lower = s.lowercased()
    guard lower.contains("goodreads.com") && (lower.contains("review_porter/export") || lower.contains("goodreads_export") || lower.contains(".csv")),
          let url = URL(string: s.hasPrefix("http") ? s : "https://\(s)") else { return nil }
    return url
}

/// Copy for Goodreads import (share URL flow and errors).
enum GoodreadsImportCopy {
    /// Shown when we received a URL from Share but couldn't download CSV (auth, expired link, or not CSV).
    static let couldNotFetchExportMessage = """
    We couldn't download your Goodreads export from that link. Goodreads export links usually only work when you're logged in, our app can't use your Goodreads login, so the link often returns a sign-in page instead of the file.

    Reliable way to import:
    1) On Goodreads (in the app or at goodreads.com/review/import), download your library CSV and save it to Files.
    2) In the Files app, tap the CSV file → Share → SPINE.

    Or open the Goodreads export page in Safari, download the CSV, then share the file to SPINE.
    """
}

enum GoodreadsShareHelper {
    // App Group identifier. Pre-rename value, kept forever: changing it would cut
    // the app off from the widget/share-extension container on every device.
    static let appGroupId = "group.com.wellread.app"
    private static let sharedFileName = "incoming_goodreads.csv"
    private static let pendingImportKey = "PendingGoodreadsImport"
    private static let pendingImportErrorKey = "PendingGoodreadsImportError"
    private static let pendingImportURLKey = "PendingGoodreadsImportURL"
    private static let pendingImportURLFileName = "pending_import_url.txt"
    // Keychain item shared with the share extension. Pre-rename name; changing it
    // would strand an import already handed off from the share sheet.
    private static let keychainService = "WellReadGoodreadsImport"
    private static let keychainAccount = "PendingURL"
    private static let keychainAccountCSVPasteboard = "PendingCSVFromPasteboard"
    private static let keychainAccountError = "PendingError"
    private static let pasteboardTypeCSV = "com.wellread.goodreads-csv"

    /// If the Share Extension saved a shared URL, returns it and clears it. Tries Keychain first (works when App Group container is null), then UserDefaults, then app group file.
    static func consumePendingImportURL() -> URL? {
        if let s = consumePendingImportURLFromKeychain() { return URL(string: s) }
        let defaults = UserDefaults(suiteName: appGroupId)
        var urlString = defaults?.string(forKey: pendingImportURLKey)
        if urlString == nil, let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let fileURL = container.appendingPathComponent(pendingImportURLFileName)
            urlString = try? String(contentsOf: fileURL, encoding: .utf8)
            try? FileManager.default.removeItem(at: fileURL)
        }
        if let s = urlString {
            defaults?.removeObject(forKey: pendingImportURLKey)
            return URL(string: s)
        }
        return nil
    }

    private static func consumePendingImportURLFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let urlString = String(data: data, encoding: .utf8) else { return nil }
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        return urlString
    }

    /// If the Share Extension saved a CSV, returns its data and clears the pending flag. Tries app group file first, then pasteboard (when app group container was null).
    static func consumePendingImport() -> Data? {
        if let data = consumePendingImportFromAppGroup() { return data }
        if let data = consumePendingImportFromPasteboard() { return data }
        return nil
    }

    private static func consumePendingImportFromAppGroup() -> Data? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        let defaults = UserDefaults(suiteName: appGroupId)
        guard defaults?.bool(forKey: pendingImportKey) == true else { return nil }
        let fileURL = container.appendingPathComponent(sharedFileName)
        defer {
            defaults?.set(false, forKey: pendingImportKey)
            try? FileManager.default.removeItem(at: fileURL)
        }
        return try? Data(contentsOf: fileURL)
    }

    private static func consumePendingImportFromPasteboard() -> Data? {
        guard consumeKeychainCSVPasteboardFlag() else { return nil }
        let pb = UIPasteboard.general
        guard let data = pb.data(forPasteboardType: pasteboardTypeCSV), !data.isEmpty else { return nil }
        pb.setData(Data(), forPasteboardType: pasteboardTypeCSV)
        return data
    }

    private static func consumeKeychainCSVPasteboardFlag() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccountCSVPasteboard,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, result != nil else { return false }
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccountCSVPasteboard
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        return true
    }

    /// If the Share Extension set an error, returns the message and clears it. Tries keychain first (works when App Group is broken).
    static func consumePendingImportError() -> String? {
        if let message = consumePendingImportErrorFromKeychain() { return message }
        let defaults = UserDefaults(suiteName: appGroupId)
        guard let message = defaults?.string(forKey: pendingImportErrorKey) else { return nil }
        defaults?.removeObject(forKey: pendingImportErrorKey)
        return message
    }

    private static func consumePendingImportErrorFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccountError,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let message = String(data: data, encoding: .utf8) else { return nil }
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccountError
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        return message
    }
}
