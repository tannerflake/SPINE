//
//  NotificationService.swift
//  SPINENotificationService
//
//  Notification Service Extension: when a push references a single book, the
//  Cloud Function sets `mutable-content` and ships the cover URL in the payload
//  (`fcm_options.image`, with `coverImageURL` in data as a fallback). This
//  extension downloads the cover and attaches it so the banner shows a
//  book-cover thumbnail. Any failure falls back to the plain notification.
//

import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var downloadTask: URLSessionDownloadTask?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent,
              let imageURL = Self.coverImageURL(from: request.content.userInfo) else {
            contentHandler(request.content)
            return
        }
        bestAttemptContent = content

        let task = URLSession.shared.downloadTask(with: imageURL) { tempURL, response, _ in
            defer { contentHandler(content) }
            guard let tempURL else { return }
            // UNNotificationAttachment needs a recognizable image extension; the temp download has none.
            let ext = Self.fileExtension(forMimeType: (response as? HTTPURLResponse)?.mimeType)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            do {
                try FileManager.default.moveItem(at: tempURL, to: destination)
                let attachment = try UNNotificationAttachment(identifier: "book-cover", url: destination)
                content.attachments = [attachment]
            } catch {
                // Deliver the plain notification.
            }
        }
        downloadTask = task
        task.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        downloadTask?.cancel()
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    private static func coverImageURL(from userInfo: [AnyHashable: Any]) -> URL? {
        var candidates: [String] = []
        if let fcmOptions = userInfo["fcm_options"] as? [String: Any],
           let image = fcmOptions["image"] as? String {
            candidates.append(image)
        }
        if let direct = userInfo["coverImageURL"] as? String {
            candidates.append(direct)
        }
        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // ATS in the extension blocks plain http; the function upgrades covers to https before sending.
            if let url = URL(string: trimmed), url.scheme == "https" {
                return url
            }
        }
        return nil
    }

    private static func fileExtension(forMimeType mimeType: String?) -> String {
        switch mimeType?.lowercased() {
        case "image/png": return "png"
        case "image/gif": return "gif"
        default: return "jpg"
        }
    }
}
