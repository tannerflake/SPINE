//
//  ShareStoryCanvases.swift
//  WellRead
//
//  The shareable story graphics beyond the library card: a sneak peek at the
//  top of your tier list, and two takes on a period of reading (a floating
//  collage and a tier list for that period). Every canvas is 360x640 points
//  (1080x1920 at 3x) and prints in fixed light tones, so a graphic made in
//  dark mode is still ink on paper, or white type on the reader's own photo.
//  Copy rule: no em-dashes in user-facing text.
//

import SwiftUI
import UIKit

// MARK: - Period

/// What a "month of reading" graphic covers: one calendar month, or the
/// current year so far.
enum SharePeriod: Hashable, Identifiable {
    case month(year: Int, month: Int)
    case yearToDate(year: Int)

    var id: String {
        switch self {
        case .month(let y, let m): return "m-\(y)-\(m)"
        case .yearToDate(let y): return "ytd-\(y)"
        }
    }

    private static let monthNames = DateFormatter().standaloneMonthSymbols ?? []

    private static func monthName(_ month: Int) -> String {
        guard month >= 1, month <= monthNames.count else { return "" }
        return monthNames[month - 1]
    }

    /// Big line on the canvas: "AUGUST" or "2026".
    var headline: String {
        switch self {
        case .month(_, let m): return Self.monthName(m).uppercased()
        case .yearToDate(let y): return String(y)
        }
    }

    /// Small line under the headline: "2026" or "SO FAR".
    var subline: String {
        switch self {
        case .month(let y, _): return String(y)
        case .yearToDate: return "SO FAR"
        }
    }

    /// Chip label in the composer: "Aug 2026" or "2026 so far".
    var chipTitle: String {
        switch self {
        case .month(let y, let m): return "\(Self.monthName(m).prefix(3)) \(y)"
        case .yearToDate(let y): return "\(y) so far"
        }
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .month(let y, let m):
            let c = calendar.dateComponents([.year, .month], from: date)
            return c.year == y && c.month == m
        case .yearToDate(let y):
            return calendar.component(.year, from: date) == y
        }
    }

    /// Books finished in this period, newest first. A book re-read in the
    /// period counts once.
    func books(in userBooks: [UserBook], calendar: Calendar = .current) -> [UserBook] {
        userBooks
            .filter { $0.status == .read && $0.book != nil }
            .compactMap { ub -> (UserBook, Date)? in
                guard let date = ub.allReadDates.first(where: { contains($0, calendar: calendar) }) else { return nil }
                return (ub, date)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Every month with at least one finished book (newest first), then the
    /// current year so far when it has any. Empty when nothing has been read.
    static func available(in userBooks: [UserBook], now: Date = Date(), calendar: Calendar = .current) -> [SharePeriod] {
        var months: Set<SharePeriod> = []
        for ub in userBooks where ub.status == .read && ub.book != nil {
            for date in ub.allReadDates {
                let c = calendar.dateComponents([.year, .month], from: date)
                if let y = c.year, let m = c.month { months.insert(.month(year: y, month: m)) }
            }
        }
        var list = months.sorted { a, b in
            guard case .month(let ay, let am) = a, case .month(let by, let bm) = b else { return false }
            return ay != by ? ay > by : am > bm
        }
        let thisYear = calendar.component(.year, from: now)
        if list.contains(where: { if case .month(let y, _) = $0 { return y == thisYear } else { return false } }) {
            list.append(.yearToDate(year: thisYear))
        }
        return list
    }

    /// The current month when it has reads, otherwise the most recent month
    /// that does.
    static func defaultPeriod(in userBooks: [UserBook], now: Date = Date(), calendar: Calendar = .current) -> SharePeriod? {
        let list = available(in: userBooks, now: now, calendar: calendar)
        let c = calendar.dateComponents([.year, .month], from: now)
        if let y = c.year, let m = c.month, list.contains(.month(year: y, month: m)) {
            return .month(year: y, month: m)
        }
        return list.first
    }
}

// MARK: - Shared canvas furniture

/// Print tones for a canvas: ink on paper, or white on the reader's photo.
struct StoryPalette {
    let hasPhoto: Bool

    var ink: Color { hasPhoto ? .white : Theme.inkFixed }
    var secondary: Color { hasPhoto ? Color.white.opacity(0.85) : Color(red: 69/255, green: 66/255, blue: 75/255) }
    var tertiary: Color { hasPhoto ? Color.white.opacity(0.7) : Color(red: 129/255, green: 126/255, blue: 134/255) }
    /// Fill behind a tier row's covers.
    var rowSurface: Color { hasPhoto ? Color.white.opacity(0.16) : Color(red: 226/255, green: 227/255, blue: 214/255) }
    /// Text shadow so white type survives a busy photo.
    var textShadow: Color { hasPhoto ? Color.black.opacity(0.45) : .clear }
}

/// Photo behind the canvas with a scrim, or nothing: without a photo every
/// graphic is transparent (previewed over a checkerboard, exported as a PNG
/// with alpha) so it drops onto any story background. `paper` forces the
/// paper tone, for the zero-state placeholders that never export.
struct StoryBackgroundLayer: View {
    var photo: UIImage?
    /// Heavier than the card canvas's scrim: these graphics put type directly on the photo.
    var scrim: Double = 0.32
    var paper: Bool = false

    var body: some View {
        if let photo {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: StoryExporter.canvasSize.width, height: StoryExporter.canvasSize.height)
                .clipped()
                .overlay(Color.black.opacity(scrim))
        } else if paper {
            Theme.paperFixed
        } else {
            Color.clear
        }
    }
}

/// "Track your reading with SPINE" plus the App Store badge, sitting just off
/// the bottom edge (19pt, 57px at 3x) so it clears the rounded preview
/// corners and Instagram's reply bar.
struct StoryCTABlock: View {
    let palette: StoryPalette
    /// The reader's handle: "Follow me @handle". Empty falls back to the
    /// app pitch.
    var handle: String = ""

    private var color: Color { palette.hasPhoto ? Color.white.opacity(0.95) : Theme.inkFixed.opacity(0.8) }

    var body: some View {
        Text(handle.isEmpty ? "Follow me on SPINE" : "Follow me @\(handle)")
            .font(.system(size: 13, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: 306)
            .shadow(color: palette.hasPhoto ? Color.black.opacity(0.45) : .clear, radius: 5, y: 1)
    }
}

/// The brand moment: the SPINE reader glyph, big and faint, peeking in from
/// the right edge behind the wordmark, the way the watermark does on the
/// card face. The canvas clips whatever hangs past the edge.
struct StoryBrandCorner: View {
    let palette: StoryPalette

    var body: some View {
        Image("SpineLogo")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 130)
            .foregroundStyle(palette.hasPhoto ? Color.white.opacity(0.3) : Theme.inkFixed.opacity(0.14))
            .rotationEffect(.degrees(-10))
            // Centered on the wordmark's line (header starts 56pt down).
            .offset(x: 34, y: -13)
            .frame(
                width: StoryExporter.canvasSize.width,
                height: StoryExporter.canvasSize.height,
                alignment: .topTrailing
            )
            .allowsHitTesting(false)
    }
}

/// The SPINE wordmark, the same heavy tracked setting as the card header.
struct StoryWordmark: View {
    let palette: StoryPalette
    var size: CGFloat = 15

    var body: some View {
        Text("SPINE")
            .font(.system(size: size, weight: .heavy))
            .tracking(size * 0.27)
            .foregroundStyle(palette.ink)
            .shadow(color: palette.textShadow, radius: 3, y: 1)
    }
}

/// Tier letter column on the left of a tier row, tier-colored like the app's list.
private struct StoryTierLabel: View {
    let tier: String?

    var body: some View {
        ZStack {
            tier == nil ? Color(red: 200/255, green: 201/255, blue: 188/255) : spineTierColor(for: tier)
            if let tier {
                VStack(spacing: 0) {
                    Text(tier)
                        .font(.system(size: 16, weight: .semibold))
                    Text("Tier")
                        .font(.system(size: 8, weight: .medium))
                        .opacity(0.7)
                }
                .foregroundStyle(Color.black.opacity(0.75))
            } else {
                Text("Unranked")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.6))
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 38)
        .frame(maxHeight: .infinity)
    }
}

/// One tier row: label column plus covers wrapped `perRow` at a time.
private struct StoryTierRow: View {
    let tier: String?
    let books: [UserBook]
    let covers: [String: UIImage]
    let coverWidth: CGFloat
    let perRow: Int
    let palette: StoryPalette
    var gap: CGFloat = 8
    var inset: CGFloat = 8

    private var lines: [[UserBook]] {
        guard !books.isEmpty else { return [] }
        return stride(from: 0, to: books.count, by: perRow).map { start in
            Array(books[start..<min(start + perRow, books.count)])
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            StoryTierLabel(tier: tier)
            VStack(alignment: .leading, spacing: gap * 0.75) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: gap) {
                        ForEach(line) { ub in
                            if let book = ub.book {
                                StoryBookCover(book: book, image: covers[book.id], width: coverWidth)
                            }
                        }
                    }
                }
            }
            .padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.rowSurface)
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }
}

/// Small tier chip pinned to a cover's corner in the floating collage.
private struct StoryCoverTierTag: View {
    let tier: String
    let coverWidth: CGFloat

    var body: some View {
        Text("\(tier)-tier")
            .font(.system(size: max(8, coverWidth * 0.145), weight: .heavy))
            .foregroundStyle(Color.black.opacity(0.78))
            .fixedSize()
            .padding(.horizontal, max(4, coverWidth * 0.08))
            .padding(.vertical, max(2, coverWidth * 0.045))
            .background(spineTierColor(for: tier))
            .clipShape(RoundedRectangle(cornerRadius: max(4, coverWidth * 0.08)))
            .shadow(color: Color.black.opacity(0.25), radius: 2, y: 1)
    }
}

// MARK: - Tier list peek

/// A sneak peek at the tier list: one row of covers for each of the top two
/// populated tiers, half of the third fading out under a blur, and the library
/// card small underneath so the story still says whose list it is.
struct TierPeekStoryCanvas: View {
    struct Row: Identifiable {
        let tier: String
        let books: [UserBook]
        var id: String { tier }
    }

    let rows: [Row]
    let covers: [String: UIImage]
    let details: LibraryCardDetails
    var background: UIImage?

    /// Covers per tier row and how many tiers the peek shows.
    static let booksPerRow = 4
    static let maxRows = 3

    /// First row of each populated tier, ladder order, at most three tiers.
    static func rows(from userBooks: [UserBook]) -> [Row] {
        let all: [Row] = spineTierLabels.compactMap { tier in
            let books = spineTierSorted(userBooks.filter { $0.normalizedTier == tier && $0.book != nil })
            return books.isEmpty ? nil : Row(tier: tier, books: Array(books.prefix(booksPerRow)))
        }
        return Array(all.prefix(maxRows))
    }

    private var palette: StoryPalette { StoryPalette(hasPhoto: background != nil) }

    private static let contentWidth: CGFloat = 306
    private static let coverGap: CGFloat = 8
    private static let rowInset: CGFloat = 8
    private static var coverWidth: CGFloat {
        (contentWidth - 38 - rowInset * 2 - coverGap * CGFloat(booksPerRow - 1)) / CGFloat(booksPerRow)
    }
    private static var rowHeight: CGFloat { coverWidth * 1.5 + rowInset * 2 }

    private var rankedCount: Int { rows.reduce(0) { $0 + $1.books.count } }

    var body: some View {
        ZStack {
            StoryBackgroundLayer(photo: background)
            StoryBrandCorner(palette: palette)

            VStack(spacing: 0) {
                header
                Spacer(minLength: 16)
                tierStack
                Color.clear.frame(height: 22)
                smallCard
                Spacer(minLength: 16)
            }
            .padding(.horizontal, (StoryExporter.canvasSize.width - Self.contentWidth) / 2)
            // A small gap under Instagram's "Your story" row. No bottom padding: the
            // body centers between the header and the bottom edge of the image.
            .padding(.top, 56)
        }
        .frame(width: StoryExporter.canvasSize.width, height: StoryExporter.canvasSize.height)
        .clipped()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("MY TIER LIST")
                    .font(.system(size: 21, weight: .heavy))
                    .tracking(2.2)
                    .foregroundStyle(palette.ink)
                Text("@\(details.handle)")
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 0)
            StoryWordmark(palette: palette)
        }
        .shadow(color: palette.textShadow, radius: 3, y: 1)
    }

    private var tierStack: some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let isPeek = index == Self.maxRows - 1 && rows.count == Self.maxRows
                if isPeek {
                    // The third tier is the tease: half a row, blurred and fading
                    // into the paper so the story asks to be opened in the app.
                    tierRow(row)
                        .blur(radius: 2.2)
                        .frame(height: Self.rowHeight * 0.55, alignment: .top)
                        .clipped()
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black.opacity(0.55), location: 0.55),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                } else {
                    tierRow(row)
                }
            }
        }
    }

    private func tierRow(_ row: Row) -> some View {
        StoryTierRow(
            tier: row.tier,
            books: row.books,
            covers: covers,
            coverWidth: Self.coverWidth,
            perRow: Self.booksPerRow,
            palette: palette,
            gap: Self.coverGap,
            inset: Self.rowInset
        )
        .frame(height: Self.rowHeight)
    }

    /// The card printed small: laid out at full width so its type wraps exactly
    /// as it does on the card page, then scaled as one piece.
    private var smallCard: some View {
        let scale: CGFloat = 0.6
        return LibraryCardFace(details: details, palette: .fixedLight)
            .frame(width: Self.contentWidth)
            .fixedSize(horizontal: false, vertical: true)
            .scaleEffect(scale)
            .frame(width: Self.contentWidth * scale, height: 208 * scale)
            .rotationEffect(.degrees(-2))
            .shadow(color: Color.black.opacity(background == nil ? 0.16 : 0.38), radius: 12, y: 8)
    }
}

// MARK: - Floating month collage

/// A period of reading as covers floating loose on the page, each tilted a
/// little, sized by the reader, with optional tier tags.
struct MonthFloatingStoryCanvas: View {
    let period: SharePeriod
    let books: [UserBook]
    let covers: [String: UIImage]
    let coverWidth: CGFloat
    let showsTiers: Bool
    let handle: String
    var background: UIImage?

    static let minCoverWidth: CGFloat = 56
    static let maxCoverWidth: CGFloat = 160

    private var palette: StoryPalette { StoryPalette(hasPhoto: background != nil) }

    private static let contentWidth: CGFloat = 306
    /// Height the collage may take before it scales down to fit.
    private static let collageBudget: CGFloat = 420

    var body: some View {
        ZStack {
            StoryBackgroundLayer(photo: background)
            StoryBrandCorner(palette: palette)

            VStack(spacing: 0) {
                header
                Spacer(minLength: 16)
                collage
                Spacer(minLength: 16)
            }
            .padding(.horizontal, (StoryExporter.canvasSize.width - Self.contentWidth) / 2)
            // A small gap under Instagram's "Your story" row. No bottom padding: the
            // body centers between the header and the bottom edge of the image.
            .padding(.top, 56)
        }
        .frame(width: StoryExporter.canvasSize.width, height: StoryExporter.canvasSize.height)
        .clipped()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(period.headline)
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(2.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(palette.ink)
                Text("\(period.subline)  ·  @\(handle)")
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 0)
            StoryWordmark(palette: palette)
        }
        .shadow(color: palette.textShadow, radius: 3, y: 1)
    }

    /// Deterministic per-slot tilt so the same books float the same way on
    /// every render (preview and export must match).
    private static func tilt(for index: Int) -> Double {
        let raw = sin(Double(index) * 12.9898 + 4.1414) * 43758.5453
        let unit = raw - floor(raw)
        return (unit * 2 - 1) * 7
    }

    private static func lift(for index: Int, gap: CGFloat) -> CGFloat {
        let raw = cos(Double(index) * 7.233 + 1.7) * 12345.678
        let unit = raw - floor(raw)
        return CGFloat(unit * 2 - 1) * gap * 0.35
    }

    private var collage: some View {
        let w = coverWidth
        let h = w * 1.5
        let gap = max(8, w * 0.2)
        let perRow = max(1, Int(floor((Self.contentWidth + gap) / (w + gap))))
        let rowCount = books.isEmpty ? 0 : Int(ceil(Double(books.count) / Double(perRow)))
        let rowHeight = h + gap
        let naturalHeight = max(h, CGFloat(rowCount) * rowHeight - gap)
        let scale = min(1, Self.collageBudget / naturalHeight)
        // Tilted covers poke past the grid a little; leave room so they aren't clipped.
        let bleed = w * 0.15

        return ZStack {
            ForEach(Array(books.enumerated()), id: \.element.id) { index, ub in
                if let book = ub.book {
                    let row = index / perRow
                    let col = index % perRow
                    let countInRow = min(perRow, books.count - row * perRow)
                    let rowWidth = CGFloat(countInRow) * w + CGFloat(countInRow - 1) * gap
                    let x0 = (Self.contentWidth - rowWidth) / 2
                    StoryBookCover(book: book, image: covers[book.id], width: w)
                        .overlay(alignment: .bottomLeading) {
                            if showsTiers, let tier = ub.normalizedTier {
                                StoryCoverTierTag(tier: tier, coverWidth: w)
                                    .offset(x: -w * 0.08, y: w * 0.08)
                            }
                        }
                        .rotationEffect(.degrees(Self.tilt(for: index)))
                        .position(
                            x: x0 + CGFloat(col) * (w + gap) + w / 2,
                            y: bleed + CGFloat(row) * rowHeight + h / 2 + Self.lift(for: index, gap: gap)
                        )
                }
            }
        }
        .frame(width: Self.contentWidth, height: naturalHeight + bleed * 2)
        .scaleEffect(scale)
        .frame(width: Self.contentWidth, height: (naturalHeight + bleed * 2) * scale)
    }
}

// MARK: - Month tier list

/// A period of reading laid out as a tier list: only the tiers that got a
/// book that period, covers shrinking as the list grows so it always fits.
struct MonthTierStoryCanvas: View {
    let period: SharePeriod
    let books: [UserBook]
    let covers: [String: UIImage]
    let handle: String
    var background: UIImage?

    private var palette: StoryPalette { StoryPalette(hasPhoto: background != nil) }

    private static let contentWidth: CGFloat = 306
    private static let rowGap: CGFloat = 8
    private static let coverGap: CGFloat = 6
    private static let rowInset: CGFloat = 7
    /// Height the tier stack may take before covers shrink, then the stack scales.
    private static let stackBudget: CGFloat = 440

    private struct Row: Identifiable {
        let tier: String?
        let books: [UserBook]
        var id: String { tier ?? "unranked" }
    }

    private var rows: [Row] {
        let ladder: [String?] = spineTierLabels.map { Optional($0) } + [nil]
        return ladder.compactMap { tier in
            let matching = spineTierSorted(books.filter { $0.normalizedTier == tier })
            return matching.isEmpty ? nil : Row(tier: tier, books: matching)
        }
    }

    private static func coverWidth(perRow: Int) -> CGFloat {
        (contentWidth - 38 - rowInset * 2 - coverGap * CGFloat(perRow - 1)) / CGFloat(perRow)
    }

    private static func stackHeight(rows: [Row], perRow: Int) -> CGFloat {
        let w = coverWidth(perRow: perRow)
        let lineGap = coverGap * 0.75
        let total = rows.reduce(CGFloat(0)) { acc, row in
            let lines = CGFloat(Int(ceil(Double(row.books.count) / Double(perRow))))
            return acc + lines * (w * 1.5) + (lines - 1) * lineGap + rowInset * 2
        }
        return total + CGFloat(max(0, rows.count - 1)) * rowGap
    }

    /// Fewest covers per row that keeps the stack inside its budget; past eight
    /// per row the whole stack scales down instead of shrinking covers further.
    private var layout: (perRow: Int, scale: CGFloat) {
        let rows = self.rows
        for perRow in 4...8 where Self.stackHeight(rows: rows, perRow: perRow) <= Self.stackBudget {
            return (perRow, 1)
        }
        let height = Self.stackHeight(rows: rows, perRow: 8)
        return (8, min(1, Self.stackBudget / height))
    }

    var body: some View {
        ZStack {
            StoryBackgroundLayer(photo: background)
            StoryBrandCorner(palette: palette)

            VStack(spacing: 0) {
                header
                Spacer(minLength: 16)
                tierStack
                Spacer(minLength: 16)
            }
            .padding(.horizontal, (StoryExporter.canvasSize.width - Self.contentWidth) / 2)
            // A small gap under Instagram's "Your story" row. No bottom padding: the
            // body centers between the header and the bottom edge of the image.
            .padding(.top, 56)
        }
        .frame(width: StoryExporter.canvasSize.width, height: StoryExporter.canvasSize.height)
        .clipped()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(period.headline)
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(2.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(palette.ink)
                Text("\(period.subline)  ·  @\(handle)")
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 0)
            StoryWordmark(palette: palette)
        }
        .shadow(color: palette.textShadow, radius: 3, y: 1)
    }

    private var tierStack: some View {
        let rows = self.rows
        let (perRow, scale) = layout
        let w = Self.coverWidth(perRow: perRow)
        let height = Self.stackHeight(rows: rows, perRow: perRow)
        return VStack(spacing: Self.rowGap) {
            ForEach(rows) { row in
                StoryTierRow(
                    tier: row.tier,
                    books: row.books,
                    covers: covers,
                    coverWidth: w,
                    perRow: perRow,
                    palette: palette,
                    gap: Self.coverGap,
                    inset: Self.rowInset
                )
            }
        }
        .frame(width: Self.contentWidth)
        .scaleEffect(scale, anchor: .top)
        .frame(width: Self.contentWidth, height: height * scale, alignment: .top)
    }
}

// MARK: - Zero state

/// A graphic before the reading exists to fill it: the same header and paper,
/// ghost cover slots where the books will go, and one line saying what fills
/// it in. Preview only, it never exports.
struct StoryEmptyCanvas: View {
    let page: SharePage
    let handle: String

    private let palette = StoryPalette(hasPhoto: false)
    private static let contentWidth: CGFloat = 306
    private static let slotsPerRow = 4
    private static var slotWidth: CGFloat {
        (contentWidth - 38 - 16 - 8 * CGFloat(slotsPerRow - 1)) / CGFloat(slotsPerRow)
    }
    /// Ghost ink: faint enough to read as "not yet".
    private static let ghost = Theme.inkFixed.opacity(0.18)
    private static let ghostFill = Theme.inkFixed.opacity(0.05)

    private var period: SharePeriod {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return .month(year: c.year ?? 2026, month: c.month ?? 1)
    }

    private var caption: String {
        switch page {
        case .tiers: return "Rank a book to unlock!"
        case .card: return ""
        case .monthFloating, .monthTiers: return "Finish a book to unlock!"
        }
    }

    var body: some View {
        ZStack {
            StoryBackgroundLayer(photo: nil, paper: true)
            StoryBrandCorner(palette: palette)

            VStack(spacing: 0) {
                header
                Spacer(minLength: 16)
                ghosts
                    .overlay(captionPill)
                Spacer(minLength: 16)
            }
            .padding(.horizontal, (StoryExporter.canvasSize.width - Self.contentWidth) / 2)
            // A small gap under Instagram's "Your story" row. No bottom padding: the
            // body centers between the header and the bottom edge of the image.
            .padding(.top, 56)
        }
        .frame(width: StoryExporter.canvasSize.width, height: StoryExporter.canvasSize.height)
        .clipped()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if page == .tiers {
                    Text("MY TIER LIST")
                        .font(.system(size: 21, weight: .heavy))
                        .tracking(2.2)
                        .foregroundStyle(palette.ink)
                    Text("@\(handle)")
                        .font(.system(size: 11.5, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(palette.secondary)
                } else {
                    Text(period.headline)
                        .font(.system(size: 30, weight: .heavy))
                        .tracking(2.5)
                        .foregroundStyle(palette.ink)
                    Text("\(period.subline)  ·  @\(handle)")
                        .font(.system(size: 11.5, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(palette.secondary)
                }
            }
            Spacer(minLength: 0)
            StoryWordmark(palette: palette)
        }
    }

    @ViewBuilder
    private var ghosts: some View {
        if page == .monthFloating {
            floatingGhosts
        } else {
            VStack(spacing: 8) {
                ForEach(Array(spineTierLabels.prefix(3)), id: \.self) { tier in
                    ghostRow(tier: tier)
                }
            }
        }
    }

    private func ghostRow(tier: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack {
                Self.ghostFill
                VStack(spacing: 0) {
                    Text(tier)
                        .font(.system(size: 16, weight: .semibold))
                    Text("Tier")
                        .font(.system(size: 8, weight: .medium))
                        .opacity(0.7)
                }
                .foregroundStyle(Self.ghost)
            }
            .frame(width: 38)
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                ForEach(0..<Self.slotsPerRow, id: \.self) { _ in
                    ghostSlot(width: Self.slotWidth)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.rowSurface.opacity(0.55))
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }

    private var floatingGhosts: some View {
        let w: CGFloat = 88
        let gap: CGFloat = 18
        return VStack(spacing: gap) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { col in
                        ghostSlot(width: w)
                            .rotationEffect(.degrees(Double((row * 3 + col) % 2 == 0 ? -4 : 4)))
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func ghostSlot(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(Self.ghost, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .background(RoundedRectangle(cornerRadius: 3).fill(Self.ghostFill))
            .frame(width: width, height: width * 1.5)
    }

    private var captionPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .bold))
            Text(caption)
                .font(.system(size: 13, weight: .semibold))
        }
            .foregroundStyle(Theme.inkFixed)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(Theme.paperFixed))
            .overlay(Capsule().strokeBorder(Theme.inkFixed.opacity(0.2), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
    }
}
