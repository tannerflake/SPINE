//
//  StoryExporter.swift
//  WellRead
//
//  One export path for every shareable story graphic (library card, tier
//  peek, month collages): render a 360x640 SwiftUI canvas at 3x for exactly
//  1080x1920 pixels (Instagram's story size), then either save it to Photos
//  or hand it to Instagram's story editor through Meta's pasteboard
//  integration, the same one Strava uses. Copy rule: no em-dashes in
//  user-facing text.
//

import SwiftUI
import Photos
import UIKit

enum StoryExporter {

    /// Every story canvas is this size in points; 3x makes it 1080x1920.
    static let canvasSize = CGSize(width: 360, height: 640)

    enum SaveOutcome: Equatable {
        case saved
        case permissionDenied
        case failed
    }

    @MainActor
    static func render<Content: View>(_ content: Content) -> UIImage? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(canvasSize)
        return renderer.uiImage
    }

    /// Saves to the photo library, asking for add-only access first.
    static func saveToPhotos(_ image: UIImage) async -> SaveOutcome {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized || status == .limited else { return .permissionDenied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return .saved
        } catch {
            return .failed
        }
    }

    // MARK: Instagram story share

    /// Whether Instagram is installed (its story scheme is declared in our
    /// Info.plist, so canOpenURL is allowed to answer). `-uiPreviewInstagramShare`
    /// forces the CTA in the simulator, where Instagram can't be installed.
    @MainActor
    static var canShareToInstagramStories: Bool {
        if ProcessInfo.processInfo.arguments.contains("-uiPreviewInstagramShare") { return true }
        guard let url = URL(string: "instagram-stories://share") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// The composed canvas rides the pasteboard under Instagram's documented
    /// keys and the instagram-stories:// scheme drops the reader straight into
    /// the story editor with the image preloaded as the background.
    /// `hasPhoto` picks JPEG (photo backgrounds compress far better) over PNG
    /// (flat paper tones and thin rules stay crisp).
    @MainActor
    @discardableResult
    static func shareToInstagramStories(_ image: UIImage, hasPhoto: Bool) -> Bool {
        let imageData: Data? = hasPhoto
            ? image.jpegData(compressionQuality: 0.92)
            : image.pngData()
        guard let imageData else { return false }

        let appID = ApiKeys.metaAppID ?? Bundle.main.bundleIdentifier ?? "com.wellread.app"
        guard let url = URL(string: "instagram-stories://share?source_application=\(appID)"),
              UIApplication.shared.canOpenURL(url) else { return false }

        UIPasteboard.general.setItems(
            [[
                "com.instagram.sharedSticker.backgroundImage": imageData,
                "com.instagram.sharedSticker.appID": appID
            ]],
            options: [.expirationDate: Date().addingTimeInterval(60 * 5)]
        )
        UIApplication.shared.open(url)
        return true
    }
}
