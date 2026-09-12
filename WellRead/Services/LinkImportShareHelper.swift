//
//  LinkImportShareHelper.swift
//  WellRead
//
//  Reads the "link → queue" payload written by the Share Extension (App Group).
//  Main app only. The extension side lives in ShareViewController.swift; the
//  key/file names must stay identical.
//

import Foundation

/// What arrived from the share sheet: a URL and/or the page text Safari captured
/// (see LinkShare.js). Either can be missing — a TikTok share is URL-only, a
/// highlighted paragraph is text-only.
struct LinkImportPayload: Identifiable, Equatable, Codable {
    var id = UUID()
    var url: URL?
    /// Page title as Safari saw it (or nil when only a URL was shared).
    var title: String?
    /// og:description / meta description, when Safari captured one.
    var description: String?
    /// Visible page text captured in Safari, or the shared text itself.
    var text: String?
    var receivedAt: Date = Date()

    /// Host without "www." — for "From nytimes.com" style captions.
    var displayHost: String? {
        guard let host = url?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var hasContent: Bool {
        url != nil || !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum LinkImportShareHelper {
    static let appGroupId = "group.com.wellread.app"
    private static let pendingKey = "PendingLinkImport"
    private static let fileName = "pending_link_import.json"
    private static let payloadDefaultsKey = "PendingLinkImportPayload"

    /// Returns the payload the Share Extension saved (and clears it), or nil.
    static func consumePending() -> LinkImportPayload? {
        let defaults = UserDefaults(suiteName: appGroupId)
        guard defaults?.bool(forKey: pendingKey) == true else { return nil }
        defaults?.set(false, forKey: pendingKey)

        var raw: Data?
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let fileURL = container.appendingPathComponent(fileName)
            raw = try? Data(contentsOf: fileURL)
            try? FileManager.default.removeItem(at: fileURL)
        }
        if raw == nil, let json = defaults?.string(forKey: payloadDefaultsKey) {
            raw = json.data(using: .utf8)
        }
        defaults?.removeObject(forKey: payloadDefaultsKey)
        guard let raw, let dict = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return nil }

        var payload = LinkImportPayload()
        payload.url = (dict["url"] as? String).flatMap { URL(string: $0) }
        payload.title = (dict["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        payload.description = (dict["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        payload.text = (dict["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let ts = dict["receivedAt"] as? TimeInterval { payload.receivedAt = Date(timeIntervalSince1970: ts) }
        return payload.hasContent ? payload : nil
    }
}
