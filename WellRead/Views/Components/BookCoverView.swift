//
//  BookCoverView.swift
//  WellRead
//
//  Loads cover from primary URL; on failure tries fallback URLs. Uses in-memory + disk cache so covers persist across app launches and re-renders show instantly.
//

import SwiftUI
import UIKit
import CoreGraphics
import CryptoKit

extension Notification.Name {
    /// Posted (object = bookId) when a cover regeneration/undo changes a book's
    /// locked cover. Live `FallbackCoverImage` instances re-hydrate on it — views
    /// sitting behind the navigation stack (tier list, queue, feed) keep their
    /// @State image otherwise and would show the old cover on pop.
    static let bookCoverResolutionDidChange = Notification.Name("bookCoverResolutionDidChange")
}

/// Outcome of one cover URL attempt — lets the loader distinguish "this book has no
/// cover here" (move on, maybe record a definitive failure) from "the network hiccuped"
/// (don't poison the persistent store) and "Open Library is rate-limiting us" (back off).
enum CoverFetchResult {
    case success(UIImage)
    /// Definitive: 404, non-cover placeholder image, or unparseable data. Never retried this session.
    case missing
    /// Open Library 403 — rate limit tripped; skip OL for a cooldown window and keep going.
    case rateLimited
    /// Timeout / connectivity / 5xx. Worth retrying later; not recorded as a hard failure.
    case transient
}

// Memory + disk cache for cover images. Disk cache persists across app launches so covers don't re-download every time.
final class CoverImageCache {
    static let shared = CoverImageCache()

    /// Max seconds of *inactivity* on a cover request. `FallbackCoverImage` also enforces a **total** budget per cover.
    static let loadTimeoutSeconds: TimeInterval = 4

    /// Max seconds for an entire cover transfer. Deliberately far above
    /// `loadTimeoutSeconds`: on a weak connection a 150KB cover makes steady
    /// progress but takes well over 4s, and capping the transfer there killed
    /// downloads that were working fine. This is only an upper bound — every
    /// attempt is still raced against the caller's remaining budget.
    static let resourceTimeoutSeconds: TimeInterval = 15

    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let fileManager = FileManager.default
    private let diskQueue = DispatchQueue(label: "com.wellread.covercache.disk")

    /// Open Library rate limit (100 req / 5 min per IP for ISBN-keyed lookups): after a
    /// 403, skip OL URLs until this date so the chain falls through to Google instantly.
    private var openLibraryBackoffUntil: Date?
    /// URLs that definitively 404'd / returned placeholders this session — skip instantly on re-scroll.
    private var knownBadURLs = Set<String>()
    private let stateLock = NSLock()

    private init() {
        // Large libraries: avoid evicting hot covers when scrolling / tab switching.
        cache.countLimit = 800
        cache.totalCostLimit = 100 * 1024 * 1024 // ~100 MB decoded bitmap budget
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.loadTimeoutSeconds
        config.timeoutIntervalForResource = Self.resourceTimeoutSeconds
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    var isOpenLibraryBackedOff: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let until = openLibraryBackoffUntil else { return false }
        return until > Date()
    }

    private func noteOpenLibraryRateLimited() {
        stateLock.lock(); defer { stateLock.unlock() }
        openLibraryBackoffUntil = Date().addingTimeInterval(5 * 60)
    }

    private func isKnownBad(_ url: URL) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return knownBadURLs.contains(url.absoluteString)
    }

    private func markKnownBad(_ url: URL) {
        stateLock.lock(); defer { stateLock.unlock() }
        knownBadURLs.insert(url.absoluteString)
    }

    private func diskCacheDirectory() -> URL? {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("WellRead", isDirectory: true).appendingPathComponent("CoverCache", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func diskFileURL(for url: URL) -> URL? {
        let key = url.absoluteString
        let hash = SHA256.hash(data: Data(key.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return diskCacheDirectory()?.appendingPathComponent(hex + ".dat")
    }

    /// Reject Google Books "image not available" placeholder so we try the next URL or show title pseudo-cover. Real covers are typically ~11KB+ and 400px+.
    private func isGoogleBooksPlaceholder(data: Data, image: UIImage, url: URL) -> Bool {
        guard url.absoluteString.contains("books.google.com") else { return false }
        if data.count < 12000 { return true }
        let w = image.size.width * (image.scale > 0 ? image.scale : 1)
        let h = image.size.height * (image.scale > 0 ? image.scale : 1)
        return w <= 400 && h <= 400
    }

    /// Open Library returns a tiny default image when no cover exists.
    private func isOpenLibraryMissingCover(data: Data, image: UIImage, url: URL) -> Bool {
        guard url.host?.contains("covers.openlibrary.org") == true else { return false }
        if data.count < 2500 { return true }
        return isOpenLibraryMissingCover(image: image, url: url)
    }

    private func isOpenLibraryMissingCover(image: UIImage, url: URL) -> Bool {
        guard url.host?.contains("covers.openlibrary.org") == true else { return false }
        let w = image.size.width * (image.scale > 0 ? image.scale : 1)
        let h = image.size.height * (image.scale > 0 ? image.scale : 1)
        return w < 90 || h < 120
    }

    /// Same check using image only (e.g. when returning from cache). Used to reject stale placeholders from memory cache.
    private func isGoogleBooksPlaceholder(image: UIImage, url: URL) -> Bool {
        guard url.absoluteString.contains("books.google.com") else { return false }
        let data = image.pngData() ?? Data()
        return isGoogleBooksPlaceholder(data: data, image: image, url: url)
    }

    /// Rejects mostly-flat bright images (e.g. publisher title page / interior scan) so we try the next URL (Open Library, another zoom, etc.).
    private func isGoogleBooksLikelyInteriorPageScan(image: UIImage, url: URL) -> Bool {
        guard url.absoluteString.contains("books.google.com") else { return false }
        let w = 48
        let h = 64
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
        let sampled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: CGSize(width: w, height: h)))
        }
        guard let cgImage = sampled.cgImage else { return false }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &pixels,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum: Double = 0
        var sumSq: Double = 0
        let n = Double(w * h)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let r = Double(pixels[i])
            let g = Double(pixels[i + 1])
            let b = Double(pixels[i + 2])
            let lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            sum += lum
            sumSq += lum * lum
        }
        let mean = sum / n
        let variance = max(0, sumSq / n - mean * mean)
        return mean > 0.91 && variance < 0.022
    }

    // MARK: ISBNdb quality checks

    /// ISBNdb serves a generic grey “BOOK COVER NOT AVAILABLE” card for records it
    /// has no art for — from ordinary covers/….jpg URLs, so only the pixels give it
    /// away. The CDN returns the same file byte-for-byte (52 of 52 sampled records);
    /// this is its SHA-256. The grid check below catches re-encoded copies (the disk
    /// cache stores PNG) and rescaled variants.
    private static let isbndbNoCoverSHA256 = "3e6a3c1e989a8368161e8baaa04b4c347cfc0057d878240dd2760b139b5c3488"

    /// 8×10 luminance grid of that placeholder. Against a 166-cover corpus the
    /// closest real cover measures 0.078 mean absolute difference while re-encodes
    /// and rescales of the placeholder stay ≤ 0.005, so the 0.03 gate has >2.5×
    /// margin each way; the placeholder is also fully achromatic (chroma ≤ 0.002).
    private static let isbndbNoCoverGrid: [Double] = [
        0.91, 0.91, 0.86, 0.87, 0.87, 0.85, 0.90, 0.91,
        0.92, 0.90, 0.84, 0.85, 0.84, 0.83, 0.89, 0.92,
        0.92, 0.93, 0.94, 0.94, 0.94, 0.94, 0.94, 0.92,
        0.92, 0.99, 1.00, 1.00, 0.97, 0.99, 1.00, 0.92,
        0.92, 0.99, 0.96, 0.87, 0.91, 0.97, 1.00, 0.92,
        0.90, 0.99, 0.95, 0.81, 0.81, 0.96, 1.00, 0.90,
        0.85, 0.99, 0.95, 0.81, 0.81, 0.97, 1.00, 0.86,
        0.80, 0.99, 0.98, 0.88, 0.83, 0.98, 1.00, 0.81,
        0.74, 0.95, 0.97, 0.97, 0.97, 0.97, 0.96, 0.75,
        0.69, 0.69, 0.69, 0.69, 0.69, 0.69, 0.69, 0.69
    ]

    private func isISBNdbHost(_ url: URL) -> Bool {
        url.host?.contains("images.isbndb.com") == true
    }

    /// Downsamples to w×h and returns RGBA bytes (nil when Core Graphics balks).
    private func sampledPixels(image: UIImage, w: Int, h: Int) -> [UInt8]? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
        let sampled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: CGSize(width: w, height: h)))
        }
        guard let cgImage = sampled.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &pixels,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pixels
    }

    /// Whether two covers are the same artwork (rescales/re-encodes included) —
    /// used by cover regeneration so "try another" never lands on a visually
    /// identical image from a different source. 8×10 luminance grid comparison;
    /// real distinct covers measure ≥0.078 MAD in the placeholder corpus, so
    /// 0.03 keeps clear margin.
    func visuallyIdentical(_ a: UIImage, _ b: UIImage) -> Bool {
        let w = 8, h = 10
        guard let pa = sampledPixels(image: a, w: w, h: h),
              let pb = sampledPixels(image: b, w: w, h: h) else { return false }
        var mad = 0.0
        for i in 0..<(w * h) {
            let la = (0.299 * Double(pa[i * 4]) + 0.587 * Double(pa[i * 4 + 1]) + 0.114 * Double(pa[i * 4 + 2])) / 255.0
            let lb = (0.299 * Double(pb[i * 4]) + 0.587 * Double(pb[i * 4 + 1]) + 0.114 * Double(pb[i * 4 + 2])) / 255.0
            mad += abs(la - lb)
        }
        return mad / Double(w * h) < 0.03
    }

    /// ISBNdb's “BOOK COVER NOT AVAILABLE” card. Exact byte hash first (network
    /// fetches), luminance-grid match as the re-encode/rescale-proof fallback.
    private func isISBNdbNoCoverPlaceholder(data: Data?, image: UIImage, url: URL) -> Bool {
        guard isISBNdbHost(url) else { return false }
        if let data = data {
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if hex == Self.isbndbNoCoverSHA256 { return true }
        }
        let w = 8, h = 10
        guard let pixels = sampledPixels(image: image, w: w, h: h) else { return false }
        var mad = 0.0
        var sumChroma = 0.0
        for i in 0..<(w * h) {
            let r = Double(pixels[i * 4])
            let g = Double(pixels[i * 4 + 1])
            let b = Double(pixels[i * 4 + 2])
            let lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            mad += abs(lum - Self.isbndbNoCoverGrid[i])
            sumChroma += (max(r, max(g, b)) - min(r, min(g, b))) / 255.0
        }
        let n = Double(w * h)
        return mad / n < 0.03 && sumChroma / n < 0.02
    }

    /// ISBNdb mirrors Internet Archive library scans, and some arrive as a
    /// cover-plus-interior-page **spread** (e.g. 529×500 with the right ~40% a blank
    /// white page) or as a photo of the physical book lying on a table. Real front
    /// covers are portrait, so: wider than 5:4 can never display in the app's 2:3
    /// frame without absurd crops — reject outright; near-square-or-wider with a
    /// bright achromatic right quarter that's ≥0.15 lum above the left half is a
    /// spread (no false positives across the 166-cover corpus — square audiobook
    /// art fails the white-right-band test).
    private func isISBNdbLikelySpreadScan(image: UIImage, url: URL) -> Bool {
        guard isISBNdbHost(url) else { return false }
        let scale = image.scale > 0 ? image.scale : 1
        let width = image.size.width * scale
        let height = image.size.height * scale
        guard height > 0 else { return false }
        let aspect = width / height
        guard aspect > 0.95 else { return false }
        if aspect > 1.25 { return true }
        let w = 32, h = 24
        guard let pixels = sampledPixels(image: image, w: w, h: h) else { return false }
        var rightLum = 0.0, rightChroma = 0.0, leftLum = 0.0
        var rightN = 0, leftN = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(pixels[i])
                let g = Double(pixels[i + 1])
                let b = Double(pixels[i + 2])
                let lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                if x >= (w * 3) / 4 {
                    rightLum += lum
                    rightChroma += (max(r, max(g, b)) - min(r, min(g, b))) / 255.0
                    rightN += 1
                } else if x < w / 2 {
                    leftLum += lum
                    leftN += 1
                }
            }
        }
        guard rightN > 0, leftN > 0 else { return false }
        let rl = rightLum / Double(rightN)
        let rc = rightChroma / Double(rightN)
        let ll = leftLum / Double(leftN)
        return rl > 0.88 && rc < 0.08 && rl - ll > 0.15
    }

    /// Rejects Google Books' large **grey “synthetic” placeholder** (fake title bars, subtle texture, tiny logo) that isn’t a real cover. Those images are usually high-res so they pass byte/size checks.
    private func isGoogleBooksLikelyGreySyntheticPlaceholder(image: UIImage, url: URL) -> Bool {
        guard url.absoluteString.contains("books.google.com") else { return false }
        let w = 64
        let h = 96
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
        let sampled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: CGSize(width: w, height: h)))
        }
        guard let cgImage = sampled.cgImage else { return false }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &pixels,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var sumLum: Double = 0
        var sumLumSq: Double = 0
        var sumChroma: Double = 0
        var lowChromaCount = 0
        var minLum: Double = 1
        var maxLum: Double = 0
        let n = Double(w * h)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let r = Double(pixels[i])
            let g = Double(pixels[i + 1])
            let b = Double(pixels[i + 2])
            let lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            let mx = max(r, max(g, b))
            let mn = min(r, min(g, b))
            let chroma = (mx - mn) / 255.0
            sumLum += lum
            sumLumSq += lum * lum
            sumChroma += chroma
            if chroma < 0.06 { lowChromaCount += 1 }
            minLum = min(minLum, lum)
            maxLum = max(maxLum, lum)
        }
        let meanLum = sumLum / n
        let lumVar = max(0, sumLumSq / n - meanLum * meanLum)
        let stdLum = sqrt(lumVar)
        let meanChroma = sumChroma / n
        let lowChromaFrac = Double(lowChromaCount) / n
        let lumRange = maxLum - minLum

        // Mostly achromatic, mid-grey overall, low contrast — matches Google’s generic template, not typical printed covers.
        let greyBand = (0.34...0.82).contains(meanLum)
        let flatContrast = stdLum < 0.13 && lumRange < 0.42
        let veryGrey = meanChroma < 0.048 && lowChromaFrac > 0.86
        if greyBand && flatContrast && veryGrey { return true }
        // Tinted colorways of the same template (slate-blue, beige, …) carry too much
        // chroma for the check above; catch them structurally instead. (This replaces an
        // older row-stripe detector that also fired on real black-and-white text covers.)
        return isSyntheticTemplateCoverFromSample(pixels: pixels, width: w, height: h)
    }

    /// Google's tinted "null cover" template: a flat low-chroma jacket with faint hatched
    /// bars where the title would be, a thin rule, a small corner glyph, and (with
    /// `edge=curl` URLs) a page-curl shadow along the bottom. Detected structurally so any
    /// colorway matches: after cropping the curl/glyph margins, the image is one
    /// near-uniform background with ≤3 quantized colors, almost no luminance spread, and —
    /// unlike every real cover, which needs readable title text — no strong edges at all.
    /// Thresholds measured against a captured slate sample (std 0.024, range 0.10,
    /// edges 0, top-3 colors 99.9%) vs. a 30-cover real corpus (min std 0.078, min range
    /// 0.21, min edges 0.015, max top-3 93.5%) — every gate has ≥1.6× margin both ways.
    private func isSyntheticTemplateCoverFromSample(pixels: [UInt8], width w: Int, height h: Int) -> Bool {
        let x0 = Int(Double(w) * 0.08), x1 = w - x0
        let y0 = Int(Double(h) * 0.08)
        let y1 = h - Int(Double(h) * 0.15)
        guard x1 > x0 + 8, y1 > y0 + 8 else { return false }
        var lums = [Double]()
        lums.reserveCapacity((x1 - x0) * (y1 - y0))
        var sumLum = 0.0
        var sumLumSq = 0.0
        var sumChroma = 0.0
        var colorHistogram: [Int: Int] = [:]
        var strongEdges = 0
        var edgePairs = 0
        for y in y0..<y1 {
            var prevLum: Double? = nil
            for x in x0..<x1 {
                let i = (y * w + x) * 4
                let r = Double(pixels[i])
                let g = Double(pixels[i + 1])
                let b = Double(pixels[i + 2])
                let lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                let chroma = (max(r, max(g, b)) - min(r, min(g, b))) / 255.0
                sumLum += lum
                sumLumSq += lum * lum
                sumChroma += chroma
                lums.append(lum)
                // 8 levels per channel — bar/background/rule collapse to a couple of bins.
                let key = (Int(r) >> 5) << 10 | (Int(g) >> 5) << 5 | (Int(b) >> 5)
                colorHistogram[key, default: 0] += 1
                if let p = prevLum {
                    edgePairs += 1
                    if abs(lum - p) > 0.20 { strongEdges += 1 }
                }
                prevLum = lum
            }
        }
        let n = Double(lums.count)
        guard n > 0 else { return false }
        let meanLum = sumLum / n
        let stdLum = max(0, sumLumSq / n - meanLum * meanLum).squareRoot()
        let meanChroma = sumChroma / n
        lums.sort()
        let lumRange = lums[Int(0.95 * Double(lums.count - 1))] - lums[Int(0.05 * Double(lums.count - 1))]
        let top3ColorFrac = Double(colorHistogram.values.sorted(by: >).prefix(3).reduce(0, +)) / n
        let strongEdgeFrac = Double(strongEdges) / Double(max(1, edgePairs))
        return (0.30...0.95).contains(meanLum)
            && meanChroma < 0.12
            && stdLum < 0.06
            && lumRange < 0.16
            && strongEdgeFrac < 0.010
            && top3ColorFrac > 0.95
    }

    private func loadFromDisk(url: URL) -> UIImage? {
        guard let fileURL = diskFileURL(for: url),
              fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let img = UIImage(data: data) else { return nil }
        if isGoogleBooksPlaceholder(data: data, image: img, url: url) {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        if isOpenLibraryMissingCover(data: data, image: img, url: url) {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        if isGoogleBooksLikelyInteriorPageScan(image: img, url: url) {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        if isGoogleBooksLikelyGreySyntheticPlaceholder(image: img, url: url) {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        if isISBNdbNoCoverPlaceholder(data: data, image: img, url: url)
            || isISBNdbLikelySpreadScan(image: img, url: url) {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        return img
    }

    private func saveToDisk(image: UIImage, url: URL) {
        guard let fileURL = diskFileURL(for: url),
              let data = image.pngData() else { return }
        try? data.write(to: fileURL)
    }

    /// Rough byte size for NSCache cost (avoids expensive `pngData()` on every disk→memory promotion).
    private func approximateImageCost(_ image: UIImage) -> Int {
        let w = image.size.width * (image.scale > 0 ? image.scale : 1)
        let h = image.size.height * (image.scale > 0 ? image.scale : 1)
        return max(1, Int(w * h * 4))
    }

    /// In-memory cache only — cheap and safe to call on the main thread (e.g. from a
    /// `View.init`) to paint a cached cover on the first frame with no shimmer. Images
    /// only enter the memory cache after passing the placeholder checks, so no need to
    /// re-run the (expensive, CoreGraphics-sampling) heuristics on every hit.
    func memoryImage(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    /// First in-memory hit across a book's candidate URLs (for synchronous hydration).
    func firstMemoryImage(forURLs urls: [URL]) -> UIImage? {
        firstMemoryHit(forURLs: urls)?.image
    }

    /// Same scan, but says *which* URL served the image — the caller needs it to
    /// record a resolution lock (see `ensureResolutionLock`), so a cover painted
    /// straight from the memory cache is still a known winner.
    func firstMemoryHit(forURLs urls: [URL]) -> (url: URL, image: UIImage)? {
        for url in urls {
            if let img = memoryImage(for: url) { return (url, img) }
        }
        return nil
    }

    /// Memory + on-disk cache only (no network). Use so list reorder / tier moves can paint immediately without flashing `ProgressView`.
    func imageSyncFromCache(for url: URL) -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) {
            if isGoogleBooksPlaceholder(image: cached, url: url) {
                cache.removeObject(forKey: key)
            } else if isOpenLibraryMissingCover(image: cached, url: url) {
                cache.removeObject(forKey: key)
            } else if isGoogleBooksLikelyInteriorPageScan(image: cached, url: url) {
                cache.removeObject(forKey: key)
            } else if isGoogleBooksLikelyGreySyntheticPlaceholder(image: cached, url: url) {
                cache.removeObject(forKey: key)
            } else if isISBNdbNoCoverPlaceholder(data: nil, image: cached, url: url)
                        || isISBNdbLikelySpreadScan(image: cached, url: url) {
                cache.removeObject(forKey: key)
            } else {
                return cached
            }
        }
        if let diskImage = loadFromDisk(url: url) {
            cache.setObject(diskImage, forKey: key, cost: approximateImageCost(diskImage))
            return diskImage
        }
        return nil
    }

    func fetch(for url: URL) async -> CoverFetchResult {
        if let sync = imageSyncFromCache(for: url) { return .success(sync) }
        if isKnownBad(url) { return .missing }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            return .transient
        }
        guard let http = response as? HTTPURLResponse else { return .transient }
        let isOpenLibrary = url.host?.contains("covers.openlibrary.org") == true
        switch http.statusCode {
        case 200:
            break
        case 403 where isOpenLibrary:
            noteOpenLibraryRateLimited()
            return .rateLimited
        case 500...:
            return .transient
        default:
            // 404 (incl. Open Library `default=false` misses) and other 4xx — no cover here.
            markKnownBad(url)
            return .missing
        }
        guard let img = UIImage(data: data) else {
            markKnownBad(url)
            return .missing
        }
        if isGoogleBooksPlaceholder(data: data, image: img, url: url)
            || isOpenLibraryMissingCover(data: data, image: img, url: url)
            || isGoogleBooksLikelyInteriorPageScan(image: img, url: url)
            || isGoogleBooksLikelyGreySyntheticPlaceholder(image: img, url: url)
            || isISBNdbNoCoverPlaceholder(data: data, image: img, url: url)
            || isISBNdbLikelySpreadScan(image: img, url: url) {
            markKnownBad(url)
            return .missing
        }

        let key = url.absoluteString as NSString
        cache.setObject(img, forKey: key, cost: data.count)
        diskQueue.async { self.saveToDisk(image: img, url: url) }
        return .success(img)
    }
}

struct BookCoverView: View {
    let book: Book
    var size: CGFloat = 80
    /// When set, tapping the cover calls this (e.g. to open book profile).
    var onTap: (() -> Void)? = nil

    /// Scales with cover size so tiny covers (e.g. the reading-now fan) keep
    /// crisp corners instead of going oval; capped at the standard 6pt.
    private var cornerRadius: CGFloat { min(6, size * 0.12) }

    var body: some View {
        Group {
            if book.coverImageURLsToTry.isEmpty {
                TitleOnlyBookCover(title: book.title, author: book.author, size: size)
            } else {
                FallbackCoverImage(
                    bookId: book.id,
                    urls: book.coverImageURLsToTry,
                    size: size,
                    isbn: book.isbn,
                    placeholderTitle: book.title,
                    placeholderAuthor: book.author,
                    hasCommunityOverride: book.coverOverrideURL?.isEmpty == false
                )
            }
        }
        .frame(width: size, height: size * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Theme.chrome.opacity(0.35), lineWidth: 0.75)
        )
        .shadow(color: Theme.shadowInk.opacity(0.12), radius: 3, x: 0, y: 2)
        .modifier(CoverTapModifier(onTap: onTap))
    }
}

private struct CoverTapModifier: ViewModifier {
    let onTap: (() -> Void)?
    func body(content: Content) -> some View {
        if let onTap = onTap {
            content.contentShape(Rectangle()).onTapGesture(perform: onTap)
        } else {
            content
        }
    }
}

/// Book-cover-style placeholder when no image is available: title centered, author along the bottom in a smaller type.
struct TitleOnlyBookCover: View {
    let title: String
    var author: String? = nil
    let size: CGFloat

    private var trimmedAuthor: String? {
        guard let a = author?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else { return nil }
        return a
    }

    /// Stable per-book jacket color from the 12-color accessible palette — hashing
    /// title+author keeps it identical across renders, launches, and devices, and
    /// spreads neighboring coverless books across different hues.
    private var fillColor: Color {
        Theme.coverPaletteColor(for: "\(title)|\(trimmedAuthor ?? "")")
    }

    var body: some View {
        ZStack {
            fillColor
            // Slight darkening toward the base reads like a printed jacket and only
            // increases text contrast (palette is validated against the flat color).
            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.22)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: fontSize, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.phosphorWhite)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .padding(.horizontal, padding)
                Spacer(minLength: 0)
                if let author = trimmedAuthor {
                    Text(author)
                        .font(.system(size: authorFontSize, weight: .medium, design: .serif))
                        .foregroundStyle(Theme.phosphorWhite.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, padding)
                        .padding(.bottom, bottomPadding)
                }
            }
        }
    }

    private var fontSize: CGFloat { max(10, size * 0.14) }
    /// Smaller than title so hierarchy reads clearly on the “spine” area.
    private var authorFontSize: CGFloat { max(8, size * 0.092) }
    private var padding: CGFloat { max(4, size * 0.08) }
    private var bottomPadding: CGFloat { max(6, size * 0.07) }
}

/// Total seconds to keep *trying* for a cover image. Decoupled from what the user
/// sees: the shimmer gives up at `coverShimmerDeadlineSeconds` and paints the
/// generated cover while the chain runs on underneath, so a generous budget here
/// costs patience, not a spinner.
private let coverLoadTotalBudgetSeconds: TimeInterval = 10

/// How long a cover may shimmer before we paint `TitleOnlyBookCover` instead.
/// The fetch is *not* cancelled — a cover that lands after this swaps in (see
/// `succeed`). The placeholder is the resting state, not a terminal one.
private let coverShimmerDeadlineSeconds: TimeInterval = 2.5

/// Runs `work`, giving up after `seconds`. Used for chain steps that do their own
/// multi-request networking and would otherwise ignore the total budget.
private func withCoverTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
    let ns = UInt64(max(0.05, seconds) * 1_000_000_000)
    return await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(nanoseconds: ns)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Tries each URL in order within a single total time budget; uses memory + disk cached images when available.
/// Once a URL succeeds it's locked in `CoverResolutionStore`, so subsequent renders (and
/// launches) go straight to that URL's cache entry — no re-probing, no shimmer, no network.
private struct FallbackCoverImage: View {
    /// Stable identity for `.task` — tier/queue reorder recreates cells; sync cache hydrate avoids spinner when URLs unchanged.
    let bookId: String
    let urls: [URL]
    let size: CGFloat
    var isbn: String? = nil
    var placeholderTitle: String? = nil
    var placeholderAuthor: String? = nil
    /// A member fixed this book's cover (`coverOverrideURL`): skip the legacy
    /// disk-cache heal, which is cache-only and runs before the chain — it could
    /// resurrect and lock the very artwork the community rejected.
    var hasCommunityOverride: Bool = false
    @State private var loadedImage: UIImage?
    /// The `taskIdentity` the `loadedImage` belongs to, so a slot reused for a different
    /// book (positional ForEach ids) reloads instead of showing a stale cover.
    @State private var loadedIdentity: String?
    @State private var useTitlePlaceholder = false

    init(bookId: String, urls: [URL], size: CGFloat, isbn: String? = nil, placeholderTitle: String? = nil, placeholderAuthor: String? = nil, hasCommunityOverride: Bool = false) {
        self.bookId = bookId
        self.urls = urls
        self.size = size
        self.isbn = isbn
        self.placeholderTitle = placeholderTitle
        self.placeholderAuthor = placeholderAuthor
        self.hasCommunityOverride = hasCommunityOverride
        // Paint the right thing on the very first frame. In a LazyVStack/LazyVGrid,
        // scrolling a cell offscreen tears down its @State; without this, scrolling back
        // would flash the shimmer (or re-generate the placeholder) even though the
        // outcome is already known.
        let identity = Self.identity(bookId: bookId, urls: urls)
        let signature = Self.signature(urls: urls, isbn: isbn)
        // Locked winner first — after a cover regeneration the OLD image is still in
        // the memory cache under an earlier candidate URL, so a generic first-hit
        // scan would resurrect it. The locked winner may also be an iTunes artwork
        // URL that isn't in `urls`; the disk read here is one small file — cheaper
        // than a shimmer flash on every scroll.
        var cached: UIImage? = nil
        if let locked = CoverResolutionStore.shared.resolvedURL(bookId: bookId, signature: signature) {
            cached = CoverImageCache.shared.imageSyncFromCache(for: locked)
        }
        if cached == nil {
            cached = CoverImageCache.shared.firstMemoryImage(forURLs: urls)
        }
        _loadedImage = State(initialValue: cached)
        _loadedIdentity = State(initialValue: cached != nil ? identity : nil)
        if cached == nil, CoverResolutionStore.shared.hasRecentFailure(bookId: bookId, signature: signature) {
            _useTitlePlaceholder = State(initialValue: true)
        }
    }

    private static func identity(bookId: String, urls: [URL]) -> String {
        "\(bookId)-\(urls.map(\.absoluteString).joined(separator: "|"))"
    }

    private var taskIdentity: String {
        Self.identity(bookId: bookId, urls: urls)
    }

    /// Resolution-store signature: invalidates locks/failures when cover inputs change.
    private static func signature(urls: [URL], isbn: String?) -> String {
        CoverResolutionStore.signature(coverURL: urls.first?.absoluteString ?? "", isbn: isbn)
    }

    /// A cover hydrated straight from the memory cache (init, or the early return
    /// on a recreated cell) skips the chain, so nothing records which URL won.
    /// Anything reading the resolution store then believes the cover never
    /// resolved — that's what left "Bad cover?" tapping into the retry path and
    /// appearing to do nothing. Memory-cache only: no disk, no network.
    private func ensureResolutionLock() {
        let signature = Self.signature(urls: urls, isbn: isbn)
        let store = CoverResolutionStore.shared
        guard store.resolvedURL(bookId: bookId, signature: signature) == nil else { return }
        guard let hit = CoverImageCache.shared.firstMemoryHit(forURLs: urls) else { return }
        store.lock(bookId: bookId, signature: signature, url: hit.url)
    }

    /// URLs the *previous* cover pipeline downloaded under, so covers already sitting in
    /// the disk cache keep working instead of re-downloading: Google zoom=0/4/5 variants
    /// (the old chain tried zoom=0 first, so most legacy cache entries live there) and
    /// Open Library URLs without `?default=false` (including the old -S size).
    /// Checked cache-only — these are never fetched from the network.
    private static func legacyCacheURLs(from urls: [URL]) -> [URL] {
        var out: [String] = []
        let current = Set(urls.map(\.absoluteString))
        for url in urls {
            let s = url.absoluteString
            if url.host?.contains("books.google.com") == true,
               var comp = URLComponents(string: s) {
                for zoom in [0, 4, 5] {
                    var q = comp.queryItems ?? []
                    q.removeAll { $0.name.lowercased() == "zoom" }
                    q.append(URLQueryItem(name: "zoom", value: "\(zoom)"))
                    comp.queryItems = q
                    if let v = comp.string, !current.contains(v), !out.contains(v) { out.append(v) }
                }
            } else if url.host?.contains("covers.openlibrary.org") == true,
                      var comp = URLComponents(string: s) {
                comp.query = nil
                if let bare = comp.string, !current.contains(bare), !out.contains(bare) {
                    out.append(bare)
                    if bare.hasSuffix("-L.jpg") {
                        let small = bare.replacingOccurrences(of: "-L.jpg", with: "-S.jpg")
                        if !out.contains(small) { out.append(small) }
                    }
                }
            }
        }
        return out.compactMap { URL(string: $0) }
    }

    /// Fetches within `timeout`; running out of time counts as a transient failure.
    private func loadCover(url: URL, timeout: TimeInterval) async -> CoverFetchResult {
        let ns = UInt64(max(0.05, timeout) * 1_000_000_000)
        return await withTaskGroup(of: CoverFetchResult.self) { group in
            group.addTask {
                await CoverImageCache.shared.fetch(for: url)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: ns)
                return .transient
            }
            let first = await group.next()
            group.cancelAll()
            return first ?? .transient
        }
    }

    var body: some View {
        ZStack {
            // Image first: once we have real artwork it wins outright, so a cover
            // arriving after the shimmer deadline can't be masked by a placeholder
            // flag someone forgot to clear.
            if let img = loadedImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size * 1.5)
                    .clipped()
            } else if useTitlePlaceholder {
                if let title = placeholderTitle, !title.isEmpty {
                    TitleOnlyBookCover(title: title, author: placeholderAuthor, size: size)
                } else {
                    genericPlaceholder
                }
            } else {
                CoverShimmer()
            }
        }
        .frame(width: size, height: size * 1.5)
        .clipped()
        .task(id: taskIdentity) {
            let identity = taskIdentity
            // Already showing the right cover (synchronous memory-cache hydrate from init) —
            // never blank it back to a shimmer just because the cell was recreated on scroll.
            if loadedImage != nil, loadedIdentity == identity {
                ensureResolutionLock()
                return
            }
            let signature = Self.signature(urls: urls, isbn: isbn)
            let store = CoverResolutionStore.shared
            // Cheap re-check: cover may have landed in the cache since init (a sibling cell
            // finished downloading it), or this slot was reused for a different book.
            // Locked winner first — see the matching ordering note in init.
            if let locked = store.resolvedURL(bookId: bookId, signature: signature),
               let img = CoverImageCache.shared.imageSyncFromCache(for: locked) {
                loadedImage = img
                loadedIdentity = identity
                return
            }
            if let mem = CoverImageCache.shared.firstMemoryHit(forURLs: urls) {
                // Record the winner: a cover painted from the memory cache never
                // ran the chain, and without a lock everything keyed off the
                // resolution store (notably "Bad cover?") thinks nothing resolved.
                store.lock(bookId: bookId, signature: signature, url: mem.url)
                loadedImage = mem.image
                loadedIdentity = identity
                return
            }
            // Holdover covers downloaded before resolution locking existed live in the
            // disk cache under old-scheme URLs. Reuse and lock them — cache-only, no
            // network — and let them heal books that were wrongly marked failed.
            // Skipped when a member fixed this cover: the heal would beat the
            // override to the lock with possibly the rejected artwork.
            if !hasCommunityOverride, store.resolvedURL(bookId: bookId, signature: signature) == nil {
                for legacy in Self.legacyCacheURLs(from: urls) {
                    if let img = CoverImageCache.shared.imageSyncFromCache(for: legacy) {
                        store.lock(bookId: bookId, signature: signature, url: legacy)
                        loadedImage = img
                        loadedIdentity = identity
                        return
                    }
                }
            }
            // Known dead end (this session, or persisted recently) — show the generated
            // cover immediately and stay off the network entirely.
            if store.hasRecentFailure(bookId: bookId, signature: signature) {
                loadedImage = nil
                loadedIdentity = nil
                useTitlePlaceholder = true
                return
            }
            loadedImage = nil
            loadedIdentity = nil
            useTitlePlaceholder = false
            let start = Date()
            let budget = coverLoadTotalBudgetSeconds
            func remaining() -> TimeInterval { budget - Date().timeIntervalSince(start) }

            func succeed(_ img: UIImage, url: URL) {
                store.lock(bookId: bookId, signature: signature, url: url)
                loadedImage = img
                loadedIdentity = identity
                // Chain outran the shimmer deadline: replace the generated cover.
                useTitlePlaceholder = false
            }

            // Stop the shimmer well before the budget expires and let the generated
            // cover stand in while the chain keeps working. Cancelled on every exit
            // path (including `.task` teardown when the cell scrolls away).
            let shimmerDeadline = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(coverShimmerDeadlineSeconds * 1_000_000_000))
                guard !Task.isCancelled, loadedImage == nil else { return }
                useTitlePlaceholder = true
            }
            defer { shimmerDeadline.cancel() }

            var sawTransient = false

            // 1. A previously locked winner: go straight to it (usually a disk-cache hit).
            if let locked = store.resolvedURL(bookId: bookId, signature: signature) {
                switch await loadCover(url: locked, timeout: remaining()) {
                case .success(let img):
                    succeed(img, url: locked)
                    return
                case .missing:
                    // Remote image really is gone — drop the lock so the chain re-resolves.
                    store.clear(bookId: bookId)
                case .rateLimited, .transient:
                    // Just a slow or flaky link. Keeping the lock matters: clearing it
                    // here meant one bad-wifi session threw away the known-good URL for
                    // every book, forcing a full chain re-run on the next launch.
                    sawTransient = true
                }
            }

            // 2. Fallback chain: Open Library → Google Books (ordering built in Book.coverImageURLsToTry).
            for url in urls {
                if remaining() <= 0 { sawTransient = true; break }
                if url.host?.contains("covers.openlibrary.org") == true,
                   CoverImageCache.shared.isOpenLibraryBackedOff {
                    sawTransient = true // OL might have had it; don't record a hard failure
                    continue
                }
                switch await loadCover(url: url, timeout: remaining()) {
                case .success(let img):
                    succeed(img, url: url)
                    return
                case .missing:
                    continue
                case .rateLimited, .transient:
                    sawTransient = true
                    continue
                }
            }

            // 3. Last resort: iTunes/Apple Books artwork lookup.
            if remaining() > 0, let title = placeholderTitle, !title.isEmpty {
                // Two sequential requests on its own 8s-per-request session, so left
                // unbounded this alone could hold a cover past the total budget.
                let author = placeholderAuthor
                let bookISBN = isbn
                let artworkLookup = await withCoverTimeout(remaining()) {
                    await ITunesCoverService.shared.artworkURLs(
                        isbn: bookISBN, title: title, author: author
                    )
                }
                // nil = we ran out of budget; an empty array = iTunes genuinely has
                // nothing, which is a definitive miss and must stay recordable.
                if artworkLookup == nil { sawTransient = true }
                let artworkURLs = artworkLookup ?? []
                for url in artworkURLs {
                    if remaining() <= 0 { sawTransient = true; break }
                    if case .success(let img) = await loadCover(url: url, timeout: remaining()) {
                        succeed(img, url: url)
                        return
                    }
                }
            }

            // 4. Nothing anywhere. Persist the failure only when every source definitively
            // said "no cover" — timeouts/rate limits just skip probing for this session.
            store.markFailed(bookId: bookId, signature: signature, definitive: !sawTransient)
            useTitlePlaceholder = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookCoverResolutionDidChange)) { note in
            guard note.object as? String == bookId else { return }
            let signature = Self.signature(urls: urls, isbn: isbn)
            // The regenerating device always has the new winner in cache, so this
            // is a synchronous repaint — no shimmer, no network.
            if let locked = CoverResolutionStore.shared.resolvedURL(bookId: bookId, signature: signature),
               let img = CoverImageCache.shared.imageSyncFromCache(for: locked) {
                loadedImage = img
                loadedIdentity = taskIdentity
                useTitlePlaceholder = false
            }
        }
    }

    private var genericPlaceholder: some View {
        ZStack {
            Theme.surface
            Image(systemName: "book.closed")
                .font(.system(size: size * 0.4))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Loading-state shimmer for book covers — a teal band sweeps across a paper surface
/// and repeats while we wait for the image. Replaces ProgressView spinners on covers.
private struct CoverShimmer: View {
    @State private var animate = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // Band is ~60% of cover width; travels from fully off-left to fully off-right.
            let bandWidth = width * 0.6
            let startX = -bandWidth
            let endX = width + bandWidth
            ZStack {
                Theme.surface
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: Theme.chrome.opacity(0.32), location: 0.5),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: bandWidth)
                .offset(x: animate ? endX - bandWidth / 2 : startX - bandWidth / 2)
                .animation(
                    .linear(duration: 1.4).repeatForever(autoreverses: false),
                    value: animate
                )
            }
            .frame(width: width, height: geo.size.height)
            .clipped()
        }
        .onAppear { animate = true }
    }
}
