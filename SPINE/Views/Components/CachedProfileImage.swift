//
//  CachedProfileImage.swift
//  SPINE
//
//  Profile avatar loader that uses ProfileImageCache (memory + disk) instead of uncached AsyncImage.
//

import SwiftUI
import UIKit

struct CachedProfileImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?
    /// The url the `uiImage` belongs to, so a recycled cell reloads instead of showing a stale avatar.
    @State private var loadedURLString: String?
    @State private var loadTask: Task<Void, Never>?

    init(url: URL?, contentMode: ContentMode = .fill, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder
        // Paint a cached avatar on the first frame so scrolling back to it doesn't flash the placeholder.
        let cached = ProfileImageCache.shared.memoryImage(for: url)
        _uiImage = State(initialValue: cached)
        _loadedURLString = State(initialValue: cached != nil ? url?.absoluteString : nil)
    }

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .onAppear(perform: loadIfNeeded)
        .onChange(of: url?.absoluteString) { _, newValue in
            // Only reset when the avatar actually changed identity (not on every cell recreation).
            if loadedURLString != newValue {
                uiImage = nil
                loadedURLString = nil
            }
            loadIfNeeded()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private func loadIfNeeded() {
        // Already showing the right avatar (synchronous hydrate) — don't reload or flash.
        if uiImage != nil, loadedURLString == url?.absoluteString { return }
        loadTask?.cancel()
        guard let url else {
            uiImage = nil
            loadedURLString = nil
            return
        }
        // Cheap memory re-check for cells recreated on scroll before the async hop.
        if let mem = ProfileImageCache.shared.memoryImage(for: url) {
            uiImage = mem
            loadedURLString = url.absoluteString
            return
        }
        loadTask = Task {
            let img = await ProfileImageCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                uiImage = img
                loadedURLString = img != nil ? url.absoluteString : nil
            }
        }
    }
}
