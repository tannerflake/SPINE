//
//  ProfileImageCache.swift
//  SPINE
//
//  In-memory + on-disk cache for profile avatars (current user + friends) to avoid repeated downloads.
//

import CryptoKit
import Foundation
import UIKit

/// Rewrites avatar URLs that arrive at a thumbnail size into a display-worthy one.
///
/// Google SSO hands Firebase Auth a `lh3.googleusercontent.com/...=s96-c` photo URL —
/// 96 pixels, fine for a 22pt row avatar and mush the moment it's blown up by the
/// long-press zoom. Google's CDN serves any size off the same path, so the size
/// directive is swapped at load time. This is display-side on purpose: it fixes every
/// account that already stored a `=s96-c` URL, with no migration.
enum AvatarURLResolver {
    /// Longest edge to request from resizable CDNs. Matches the cap
    /// `ProfilePhotoService` uploads at, so an SSO avatar and an uploaded one
    /// carry the same resolution — enough for the full-screen zoom overlay.
    static let preferredPixelDimension = 1024

    static func displayURL(for url: URL?) -> URL? {
        guard let url, let host = url.host?.lowercased() else { return url }
        guard host == "googleusercontent.com" || host.hasSuffix(".googleusercontent.com") else { return url }
        // Size directives live at the end of the path after "=" (e.g. "/a/ACg8oc…=s96-c").
        let path = url.path
        guard let eq = path.lastIndex(of: "=") else {
            return upgraded(url, path: path + "=s\(preferredPixelDimension)-c") ?? url
        }
        let directives = path[path.index(after: eq)...].split(separator: "-").map(String.init)
        // Only touch URLs whose directives are the expected size/flag form.
        guard directives.contains(where: { $0.first == "s" && Int($0.dropFirst()) != nil }) else { return url }
        let rewritten = directives.map { d -> String in
            guard d.first == "s", let value = Int(d.dropFirst()) else { return d }
            return value >= preferredPixelDimension ? d : "s\(preferredPixelDimension)"
        }
        let newPath = path[..<eq] + "=" + rewritten.joined(separator: "-")
        return upgraded(url, path: String(newPath)) ?? url
    }

    private static func upgraded(_ url: URL, path: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = path
        return components.url
    }
}

final class ProfileImageCache {
    static let shared = ProfileImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let diskDirectory: URL
    private let ioQueue = DispatchQueue(label: "com.spine.profileImageCache.io", qos: .utility)
    private let fileManager = FileManager.default

    private init() {
        memory.countLimit = 200
        let base = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base?
            .appendingPathComponent("WellRead", isDirectory: true)
            .appendingPathComponent("ProfileImages", isDirectory: true)
        diskDirectory = dir ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WellReadProfileImages", isDirectory: true)
        try? fileManager.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    private func diskURL(for url: URL) -> URL {
        diskDirectory.appendingPathComponent(Self.filename(for: url.absoluteString))
    }

    private static func filename(for urlString: String) -> String {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".dat"
    }

    /// In-memory cache only — cheap and main-thread safe, for synchronous hydration in a
    /// `View.init` so a cached avatar paints on the first frame (no placeholder flash on scroll).
    func memoryImage(for url: URL?) -> UIImage? {
        guard let url = AvatarURLResolver.displayURL(for: url) else { return nil }
        return memory.object(forKey: url.absoluteString as NSString)
    }

    /// Loads from memory, then disk, then network; writes disk after a successful download.
    func image(for requestedURL: URL) async -> UIImage? {
        let url = AvatarURLResolver.displayURL(for: requestedURL) ?? requestedURL
        let key = url.absoluteString as NSString
        if let cached = memory.object(forKey: key) {
            return cached
        }

        let diskURL = diskURL(for: url)
        if fileManager.fileExists(atPath: diskURL.path) {
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: diskURL)
            }.value
            if let data, let img = UIImage(data: data) {
                memory.setObject(img, forKey: key)
                return img
            }
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let img = UIImage(data: data) else { return nil }
            memory.setObject(img, forKey: key)
            ioQueue.async { [diskURL] in
                try? data.write(to: diskURL, options: [.atomic])
            }
            return img
        } catch {
            return nil
        }
    }

    /// Call after uploading a new photo so the next display hits memory/disk immediately.
    func store(_ image: UIImage, for requestedURL: URL) {
        let url = AvatarURLResolver.displayURL(for: requestedURL) ?? requestedURL
        let key = url.absoluteString as NSString
        memory.setObject(image, forKey: key)
        let diskURL = diskURL(for: url)
        ioQueue.async {
            guard let data = image.jpegData(compressionQuality: 0.88) else { return }
            try? data.write(to: diskURL, options: [.atomic])
        }
    }
}
