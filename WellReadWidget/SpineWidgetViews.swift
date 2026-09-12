//
//  SpineWidgetViews.swift
//  WellReadWidget
//
//  Layout rules for both families:
//   • Small  — every book on your Reading now shelf, laid out as a grid of
//     covers sized to whatever fits (1 across, 2, 3, or 2×2). Each cover wears
//     the app's bookmark ribbon at its reading position plus a hairline bar on
//     its bottom edge, and prints its percent underneath when it is wide enough
//     to read. No rotation: the whole shelf is on screen at once.
//   • Medium — the same shelf on the left, a rotating page of what people you
//     follow are reading on the right, split by a hairline.
//
//  Taps: your covers open the Queue, a friend's cover opens that book's
//  profile. `Link` only works from systemMedium up, so the small family sends
//  the whole widget to the Queue via `widgetURL`.
//

import SwiftUI
import WidgetKit

/// Local echo of the app's Theme palette (SPINE paper #EDEEE3 / ink #141018,
/// inverted in dark). The widget target doesn't compile app sources, so these
/// are duplicated on purpose.
enum SpinePalette {
    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    static let paper = dynamic(
        light: UIColor(red: 237/255, green: 238/255, blue: 227/255, alpha: 1),
        dark: UIColor(red: 20/255, green: 16/255, blue: 24/255, alpha: 1)
    )
    static let surface = dynamic(
        light: UIColor(red: 226/255, green: 227/255, blue: 214/255, alpha: 1),
        dark: UIColor(red: 29/255, green: 25/255, blue: 36/255, alpha: 1)
    )
    static let textPrimary = dynamic(
        light: UIColor(red: 20/255, green: 16/255, blue: 24/255, alpha: 1),
        dark: UIColor(red: 237/255, green: 238/255, blue: 227/255, alpha: 1)
    )
    static let textSecondary = dynamic(
        light: UIColor(red: 69/255, green: 66/255, blue: 75/255, alpha: 1),
        dark: UIColor(red: 181/255, green: 182/255, blue: 171/255, alpha: 1)
    )
    /// Chrome — solid ink (paper in dark); replaces the retired teal.
    static let chrome = dynamic(
        light: UIColor(red: 20/255, green: 16/255, blue: 24/255, alpha: 1),
        dark: UIColor(red: 237/255, green: 238/255, blue: 227/255, alpha: 1)
    )
    /// Text on a `chrome` fill.
    static let onChrome = dynamic(
        light: UIColor(red: 237/255, green: 238/255, blue: 227/255, alpha: 1),
        dark: UIColor(red: 20/255, green: 16/255, blue: 24/255, alpha: 1)
    )
    /// Anything drawn *on a cover* stays fixed in both appearances — covers keep
    /// their own saturation, so a dynamic token would invert against them.
    static let inkFixed = Color(red: 20/255, green: 16/255, blue: 24/255)
    static let paperFixed = Color(red: 237/255, green: 238/255, blue: 227/255)

    /// Echo of the app's `Theme.coverPalette` + `coverPaletteColor(for:)` (see
    /// UserAvatarView.swift): 12 deep hues, white text, FNV-1a seeded by the
    /// normalized display name so a friend's fallback avatar color matches the app.
    static let avatarPalette: [Color] = [
        Color(red: 74/255, green: 61/255, blue: 140/255),
        Color(red: 49/255, green: 46/255, blue: 129/255),
        Color(red: 30/255, green: 58/255, blue: 110/255),
        Color(red: 37/255, green: 78/255, blue: 112/255),
        Color(red: 13/255, green: 92/255, blue: 99/255),
        Color(red: 28/255, green: 92/255, blue: 58/255),
        Color(red: 82/255, green: 78/255, blue: 26/255),
        Color(red: 146/255, green: 60/255, blue: 18/255),
        Color(red: 121/255, green: 68/255, blue: 34/255),
        Color(red: 146/255, green: 34/255, blue: 30/255),
        Color(red: 122/255, green: 28/255, blue: 56/255),
        Color(red: 108/255, green: 40/255, blue: 96/255)
    ]

    static func avatarColor(for name: String) -> Color {
        let seed = name.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return avatarPalette[Int(hash % UInt64(avatarPalette.count))]
    }

    static func avatarInitials(for name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        guard let first = words.first?.first else { return "?" }
        if words.count >= 2, let last = words.last?.first {
            return String(first).uppercased() + String(last).uppercased()
        }
        return String(first).uppercased()
    }
}

// MARK: - Deep links

/// The two destinations a widget tap can produce. Handled in the app by
/// `WellreadDeepLink` (see PushNotificationService.swift).
enum SpineWidgetLink {
    static let queue = URL(string: "wellread://queue")!

    /// `wellread://book/{bookId}?reader={uid}` — the reader is the friend whose
    /// cover was tapped, so the book profile can show their read in context.
    static func book(_ bookId: String, readerUid: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "wellread"
        components.host = "book"
        components.path = "/" + bookId
        if let readerUid, !readerUid.isEmpty {
            components.queryItems = [URLQueryItem(name: "reader", value: readerUid)]
        }
        return components.url ?? queue
    }
}

enum WidgetImageLoader {
    static func image(_ filename: String?) -> UIImage? {
        guard let url = WidgetSharedStore.imageURL(for: filename) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

extension WidgetSnapshot {
    /// Every (friend, book) pairing flattened in snapshot order — a friend
    /// reading two books occupies two rotation slots.
    struct FriendBookItem {
        let friend: FriendEntry
        let book: BookEntry
    }

    var friendBookItems: [FriendBookItem] {
        friends.flatMap { friend in
            friend.books.map { FriendBookItem(friend: friend, book: $0) }
        }
    }
}

extension WidgetSnapshot.BookEntry {
    /// Clamped progress, or nil when the reader has never set one (no bookmark,
    /// no percent — an unread-looking cover is the honest rendering).
    var clampedProgress: Double? {
        guard let progress else { return nil }
        return min(1, max(0, progress))
    }

    var percentText: String? {
        guard let clampedProgress else { return nil }
        return "\(Int((clampedProgress * 100).rounded()))%"
    }
}

// MARK: - Entry view

struct SpineWidgetEntryView: View {
    var entry: SpineEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium:
            MediumWidgetView(snapshot: entry.snapshot, tick: entry.tick)
        default:
            SmallWidgetView(snapshot: entry.snapshot)
        }
    }
}

// MARK: - Small: your whole Reading now shelf

struct SmallWidgetView: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        Group {
            if let snapshot, snapshot.isSignedIn {
                if snapshot.myBooks.isEmpty {
                    MessageCard(title: "Nothing on deck", subtitle: "Start a book in SPINE")
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        // The label costs ~11pt of cover height; a shelf of three
                        // or four needs that space more than it needs a caption.
                        if snapshot.myBooks.count <= 2 {
                            SectionLabel("READING NOW")
                        }
                        ReadingCoverGrid(books: snapshot.myBooks)
                    }
                }
            } else {
                MessageCard(title: "SPINE", subtitle: "Open the app to sign in")
            }
        }
        .containerBackground(SpinePalette.paper, for: .widget)
        .widgetURL(SpineWidgetLink.queue)
    }
}

// MARK: - Medium: your shelf + who you follow

struct MediumWidgetView: View {
    let snapshot: WidgetSnapshot?
    let tick: Int

    /// Friend books shown per rotation page. WidgetKit refreshes pre-rendered
    /// entries at a one-minute floor, so the page is deliberately wide: more
    /// friends per frame is the only way to raise throughput.
    static let friendsPerPage = 4

    var body: some View {
        Group {
            if let snapshot, snapshot.isSignedIn {
                HStack(spacing: 11) {
                    myPane(snapshot)
                        .frame(width: 118)
                    Rectangle()
                        .fill(SpinePalette.textSecondary.opacity(0.22))
                        .frame(width: 1)
                    friendsPane(snapshot)
                        .frame(maxWidth: .infinity)
                }
            } else {
                MessageCard(title: "SPINE", subtitle: "Open the app to sign in")
            }
        }
        .containerBackground(SpinePalette.paper, for: .widget)
        .widgetURL(SpineWidgetLink.queue)
    }

    @ViewBuilder
    private func myPane(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("READING NOW")
            if snapshot.myBooks.isEmpty {
                Text("Nothing on deck")
                    .font(.system(size: 11))
                    .foregroundStyle(SpinePalette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                // Whole pane is one target: any of your covers means "my queue".
                Link(destination: SpineWidgetLink.queue) {
                    ReadingCoverGrid(books: snapshot.myBooks)
                }
            }
        }
    }

    private func friendsPane(_ snapshot: WidgetSnapshot) -> some View {
        let items = snapshot.friendBookItems
        let pageCount = max(1, Int(ceil(Double(items.count) / Double(Self.friendsPerPage))))
        let pageStart = (tick % pageCount) * Self.friendsPerPage
        let page = Array(items.dropFirst(pageStart).prefix(Self.friendsPerPage))

        return VStack(alignment: .leading, spacing: 4) {
            SectionLabel("FRIENDS READING")

            if items.isEmpty {
                Text("No one you follow is reading yet")
                    .font(.system(size: 11))
                    .foregroundStyle(SpinePalette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                GeometryReader { geo in
                    let spacing: CGFloat = 6
                    let cellWidth = (geo.size.width - spacing * CGFloat(Self.friendsPerPage - 1))
                        / CGFloat(Self.friendsPerPage)
                    // Name line is 9pt of the cell; the cover takes the rest,
                    // capped by its own 2:3 ratio so it never stretches.
                    let coverHeight = min(geo.size.height - 11, cellWidth * 1.5)

                    HStack(alignment: .top, spacing: spacing) {
                        // Fixed slot count keeps covers the same size on a short
                        // final page instead of letting three covers grow.
                        ForEach(0..<Self.friendsPerPage, id: \.self) { slot in
                            if slot < page.count {
                                let item = page[slot]
                                Link(destination: SpineWidgetLink.book(item.book.bookId, readerUid: item.friend.uid)) {
                                    FriendCoverCell(item: item, coverWidth: coverHeight * 2 / 3, coverHeight: coverHeight)
                                        .frame(width: cellWidth, alignment: .center)
                                }
                            } else {
                                Color.clear.frame(width: cellWidth, height: 1)
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
            }
        }
    }
}

// MARK: - Cover grid

/// Your Reading now shelf, every cover visible. The arrangement is picked from
/// the count (the app caps the shelf the widget receives at four), then the
/// cover size is solved against whatever space the family gave us. The percent
/// caption is dropped when covers get too narrow to carry it, and the bottom
/// hairline bar keeps progress readable at any size.
struct ReadingCoverGrid: View {
    let books: [WidgetSnapshot.BookEntry]

    private var rows: [[WidgetSnapshot.BookEntry]] {
        switch books.count {
        case 0: return []
        case 4...: return [Array(books.prefix(2)), Array(books.dropFirst(2).prefix(2))]
        default: return [books]
        }
    }

    var body: some View {
        GeometryReader { geo in
            let rows = rows
            let rowCount = max(1, rows.count)
            let columnCount = max(1, rows.map(\.count).max() ?? 1)
            let hSpacing: CGFloat = columnCount > 2 ? 5 : 7
            let vSpacing: CGFloat = 5
            let cellWidth = (geo.size.width - hSpacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
            let rowHeight = (geo.size.height - vSpacing * CGFloat(rowCount - 1)) / CGFloat(rowCount)
            let captionHeight: CGFloat = 11
            let heightWithCaption = min(rowHeight - captionHeight, cellWidth * 1.5)
            let showsCaption = heightWithCaption * 2 / 3 >= 44
            let coverHeight = max(12, showsCaption ? heightWithCaption : min(rowHeight, cellWidth * 1.5))

            VStack(spacing: vSpacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: hSpacing) {
                        ForEach(row, id: \.bookId) { book in
                            VStack(spacing: 2) {
                                ProgressCoverTile(
                                    book: book,
                                    width: coverHeight * 2 / 3,
                                    height: coverHeight
                                )
                                if showsCaption {
                                    Text(book.percentText ?? "—")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(
                                            book.percentText == nil
                                                ? SpinePalette.textSecondary
                                                : SpinePalette.textPrimary
                                        )
                                }
                            }
                            .frame(width: cellWidth, alignment: .center)
                        }
                        if row.count < columnCount {
                            Color.clear.frame(width: cellWidth, height: 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}

// MARK: - Cells

/// Book cover at 2:3 with rounded corners; title tile when no image landed.
struct CoverTile: View {
    let book: WidgetSnapshot.BookEntry
    var cornerRadius: CGFloat = 7
    /// Extra top padding for the title-card fallback, so the bookmark drawn over
    /// the cover doesn't land on the first line of the title.
    var textTopInset: CGFloat = 0

    var body: some View {
        Group {
            if let cover = WidgetImageLoader.image(book.coverFilename) {
                Color.clear
                    .overlay {
                        Image(uiImage: cover)
                            .resizable()
                            .scaledToFill()
                    }
            } else {
                SpinePalette.surface
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(SpinePalette.textPrimary)
                                .lineLimit(4)
                                .minimumScaleFactor(0.8)
                            Text(book.author)
                                .font(.system(size: 7.5))
                                .foregroundStyle(SpinePalette.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(5)
                        .padding(.top, textTopInset)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// A cover at an explicit size wearing its reading position: the app's bookmark
/// tab tucked into the top edge at the progress point, and a hairline fill along
/// the bottom edge. Both are drawn in fixed ink/paper so they read against any
/// cover art in either appearance.
struct ProgressCoverTile: View {
    let book: WidgetSnapshot.BookEntry
    let width: CGFloat
    let height: CGFloat

    private var cornerRadius: CGFloat { max(3, min(8, width * 0.11)) }
    private var bookmarkHeight: CGFloat { max(12, height * 0.17) }

    var body: some View {
        CoverTile(
            book: book,
            cornerRadius: cornerRadius,
            textTopInset: book.clampedProgress == nil ? 0 : bookmarkHeight - 3
        )
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) {
                if let fraction = book.clampedProgress {
                    bookmark(fraction: fraction)
                }
            }
            .overlay(alignment: .bottom) {
                if let fraction = book.clampedProgress {
                    progressBar(fraction: fraction)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Echo of the app's `CoverProgressRibbon`: flush left at 0%, flush right at
    /// 100%. Kept inside the cover (the app's version peeks past the top edge,
    /// which a widget would clip).
    private func bookmark(fraction: Double) -> some View {
        let ribbonWidth = max(5, width * 0.085)
        let ribbonHeight = bookmarkHeight
        let inset = max(4, width * 0.07)
        let travel = max(0, width - inset * 2 - ribbonWidth)
        return WidgetBookmarkShape()
            .fill(SpinePalette.inkFixed)
            .overlay(
                WidgetBookmarkShape()
                    .stroke(SpinePalette.paperFixed.opacity(0.9), lineWidth: 0.8)
            )
            .frame(width: ribbonWidth, height: ribbonHeight)
            .offset(x: inset + travel * CGFloat(fraction))
    }

    /// Two opaque halves rather than a tinted track: whichever way the cover art
    /// goes, both the read part (ink) and the rest (paper) stay visible, and the
    /// filled side is the dark one — the way a progress bar is normally read.
    private func progressBar(fraction: Double) -> some View {
        let barHeight = max(3, height * 0.05)
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(SpinePalette.paperFixed)
            Rectangle()
                .fill(SpinePalette.inkFixed)
                .frame(width: width * CGFloat(fraction))
        }
        .frame(width: width, height: barHeight)
    }
}

/// Classic bookmark silhouette: straight top, V-notch at the bottom. Mirrors
/// `BookmarkTabShape` in the app so the two surfaces read as one language.
struct WidgetBookmarkShape: Shape {
    var notch: CGFloat = 0.3

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let depth = rect.height * notch
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - depth))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// One friend-book pairing: cover, avatar badge, first name.
struct FriendCoverCell: View {
    let item: WidgetSnapshot.FriendBookItem
    let coverWidth: CGFloat
    let coverHeight: CGFloat

    private var badgeSize: CGFloat { max(14, min(21, coverWidth * 0.46)) }

    private var firstName: String {
        item.friend.displayName.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
            ?? item.friend.displayName
    }

    var body: some View {
        VStack(spacing: 2) {
            CoverTile(book: item.book, cornerRadius: max(3, min(6, coverWidth * 0.11)))
                .frame(width: coverWidth, height: coverHeight)
                .overlay(alignment: .bottomLeading) {
                    avatarBadge
                        .offset(x: -4, y: 4)
                }
            Text(firstName)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(SpinePalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var avatarBadge: some View {
        Group {
            if let avatar = WidgetImageLoader.image(item.friend.avatarFilename) {
                Image(uiImage: avatar)
                    .resizable()
                    .scaledToFill()
            } else {
                SpinePalette.avatarColor(for: item.friend.displayName)
                    .overlay {
                        Text(SpinePalette.avatarInitials(for: item.friend.displayName))
                            .font(.system(size: badgeSize * 0.4, weight: .bold))
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.7)
                    }
            }
        }
        .frame(width: badgeSize, height: badgeSize)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(SpinePalette.paper, lineWidth: 1.5))
    }
}

// MARK: - Chrome

struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(SpinePalette.textSecondary)
    }
}

struct MessageCard: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SpinePalette.textPrimary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(SpinePalette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
