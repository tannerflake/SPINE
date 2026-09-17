//
//  ShareCoverResolver.swift
//  SPINE
//
//  ImageRenderer cannot wait on the async cover pipeline, so a story canvas
//  has to be handed finished UIImages. This resolves covers up front (locked
//  winner first, then the book's candidate chain through the shared cover
//  cache) and publishes them as they land, so the on-screen preview fills in
//  live and the export waits for the stragglers. Copy rule: no em-dashes in
//  user-facing text.
//

import SwiftUI
import UIKit

@MainActor
final class ShareCoverResolver: ObservableObject {
    /// Resolved covers by `Book.id`. Books that never resolve stay absent and
    /// render as their title-only jacket.
    @Published private(set) var images: [String: UIImage] = [:]

    private var requested: Set<String> = []
    private var inFlight: Set<String> = []

    /// At most this long per candidate URL, so a dead host can't stall the export.
    private static let perURLTimeout: TimeInterval = 4

    var isResolving: Bool { !inFlight.isEmpty }

    /// Kicks off resolution for any book not already requested. Safe to call
    /// repeatedly as the selected period changes.
    func resolve(_ books: [Book]) {
        for book in books where !requested.contains(book.id) {
            requested.insert(book.id)
            let urls = book.coverImageURLsToTry
            guard !urls.isEmpty else { continue }
            // Memory/disk hits paint on the very first frame.
            if let hit = Self.syncHit(book: book, urls: urls) {
                images[book.id] = hit
                continue
            }
            inFlight.insert(book.id)
            Task { [weak self] in
                let image = await Self.fetch(book: book, urls: urls)
                guard let self else { return }
                if let image { self.images[book.id] = image }
                self.inFlight.remove(book.id)
            }
        }
    }

    /// Lets the export give in-flight covers a moment to land instead of
    /// printing placeholders for books that are one network hop away.
    func waitUntilSettled(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isResolving, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Lookup

    private static func lockedURL(book: Book, urls: [URL]) -> URL? {
        let signature = CoverResolutionStore.signature(coverURL: urls.first?.absoluteString ?? "", isbn: book.isbn)
        return CoverResolutionStore.shared.resolvedURL(bookId: book.id, signature: signature)
    }

    private static func syncHit(book: Book, urls: [URL]) -> UIImage? {
        if let locked = lockedURL(book: book, urls: urls),
           let image = CoverImageCache.shared.imageSyncFromCache(for: locked) {
            return image
        }
        return CoverImageCache.shared.firstMemoryImage(forURLs: urls)
    }

    private static func fetch(book: Book, urls: [URL]) async -> UIImage? {
        var chain = urls
        if let locked = lockedURL(book: book, urls: urls) {
            chain.removeAll { $0 == locked }
            chain.insert(locked, at: 0)
        }
        for url in chain {
            if Task.isCancelled { return nil }
            if case .success(let image) = await fetchWithTimeout(url) { return image }
        }
        return nil
    }

    private static func fetchWithTimeout(_ url: URL) async -> CoverFetchResult {
        let ns = UInt64(perURLTimeout * 1_000_000_000)
        return await withTaskGroup(of: CoverFetchResult.self) { group in
            group.addTask { await CoverImageCache.shared.fetch(for: url) }
            group.addTask {
                try? await Task.sleep(nanoseconds: ns)
                return .transient
            }
            let first = await group.next()
            group.cancelAll()
            return first ?? .transient
        }
    }
}

// MARK: - Cover for a story canvas

/// A book cover for export: the resolved image, or the same title-only jacket
/// the library draws when a book has no artwork. Fixed tones on purpose; the
/// canvas is always the printed light card regardless of app appearance.
struct StoryBookCover: View {
    let book: Book
    let image: UIImage?
    let width: CGFloat

    private var cornerRadius: CGFloat { min(6, width * 0.12) }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                TitleOnlyBookCover(title: book.title, author: book.author, size: width)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Theme.inkFixed.opacity(0.28), lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.22), radius: max(2, width * 0.06), x: 0, y: max(1, width * 0.03))
    }
}
