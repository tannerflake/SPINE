//
//  ReadingNowProgressCard.swift
//  SPINE
//
//  Queue → Reading now cell. A larger cover with a bookmark ribbon tucked into
//  the top edge at the reader's position, the percent + page readout, and a
//  "bookmark scrubber": a fore-edge of page hairlines with a draggable bookmark
//  tab. Dragging the tab moves the ribbon on the cover, the percent, and the
//  page number together so print and audiobook readers each see the number
//  that means something to them.
//

import SwiftUI
import UIKit

// MARK: - Shared bookmark shape

/// Classic bookmark silhouette: straight top, V-notch at the bottom.
struct BookmarkTabShape: Shape {
    /// Notch depth as a fraction of height.
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

// MARK: - Cover ribbon

/// Ink ribbon hanging over the top edge of a cover. Horizontal position tracks
/// progress: flush left at 0%, flush right at 100%. Fixed ink/paper (not chrome
/// tokens) because covers stay saturated in both appearances.
struct CoverProgressRibbon: View {
    let fraction: Double
    let coverWidth: CGFloat
    let coverHeight: CGFloat

    private var ribbonWidth: CGFloat { min(16, max(7, coverWidth * 0.085)) }
    private var ribbonHeight: CGFloat { min(44, max(18, coverHeight * 0.16)) }
    private var inset: CGFloat { max(5, coverWidth * 0.07) }

    var body: some View {
        let travel = coverWidth - inset * 2 - ribbonWidth
        let x = inset + travel * CGFloat(min(1, max(0, fraction)))
        ZStack(alignment: .topLeading) {
            Color.clear
            BookmarkTabShape()
                .fill(Theme.inkFixed)
                .overlay(
                    BookmarkTabShape()
                        .stroke(Theme.paperFixed.opacity(0.9), lineWidth: 1)
                )
                .frame(width: ribbonWidth, height: ribbonHeight)
                .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
                // Peeks past the top edge like a real bookmark.
                .offset(x: x, y: -4)
        }
        .frame(width: coverWidth, height: coverHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - Scrubber

/// Fore-edge track (one hairline per "page" of width) with a bookmark-tab
/// thumb. Only the thumb starts a drag, so the surrounding ScrollView keeps
/// scrolling when a finger lands on the track; a tap on the track jumps.
struct ReadingProgressScrubber: View {
    /// Committed value from the model, 0...1.
    let fraction: Double
    /// Live value while the finger is down (drives the readout + cover ribbon).
    let onLiveChange: (Double) -> Void
    /// Finger lifted or track tapped: persist this.
    let onCommit: (Double) -> Void

    /// Shorter track + thumb for dense rows (the queue card). Default is the
    /// roomier profile-page size.
    var compact: Bool = false

    @State private var dragStartFraction: Double? = nil
    @State private var liveFraction: Double = 0
    @State private var lastHapticStep: Int = -1

    private var trackHeight: CGFloat { compact ? 14 : 18 }
    private var thumbWidth: CGFloat { compact ? 18 : 22 }
    private var thumbHeight: CGFloat { compact ? 27 : 34 }
    private var hitSize: CGFloat { compact ? 40 : 48 }
    /// Horizontal padding so the thumb never clips at 0% or 100%.
    private var edgePad: CGFloat { thumbWidth / 2 + 2 }

    private var shownFraction: Double { dragStartFraction == nil ? fraction : liveFraction }

    /// The last few percent snap to the covers so "done" and "not started" are
    /// reachable without pixel-perfect aim.
    private static func snapped(_ f: Double) -> Double {
        if f >= 0.975 { return 1 }
        if f <= 0.015 { return 0 }
        return min(1, max(0, f))
    }
    /// Springs on taps / model changes; tracks the finger directly while dragging.
    private var thumbAnimation: Animation? {
        dragStartFraction == nil ? .spring(response: 0.32, dampingFraction: 0.82) : nil
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let travel = max(1, width - edgePad * 2)
            let thumbX = edgePad + travel * CGFloat(min(1, max(0, shownFraction)))

            ZStack(alignment: .leading) {
                // Fore-edge: read pages in ink, unread pages faint.
                Canvas { context, size in
                    let stride: CGFloat = 4
                    let lineW: CGFloat = 1.25
                    let y0 = (size.height - trackHeight) / 2
                    var x = edgePad
                    let fillX = edgePad + travel * CGFloat(min(1, max(0, shownFraction)))
                    while x <= size.width - edgePad + 0.5 {
                        let rect = CGRect(x: x - lineW / 2, y: y0, width: lineW, height: trackHeight)
                        let read = x <= fillX + 0.5
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 0.6),
                            with: .color(read ? Theme.chrome : Theme.chrome.opacity(0.18))
                        )
                        x += stride
                    }
                    // Baseline: the book's bottom board.
                    let base = CGRect(x: edgePad - 1, y: y0 + trackHeight + 3, width: size.width - edgePad * 2 + 2, height: 1.5)
                    context.fill(Path(roundedRect: base, cornerRadius: 0.75), with: .color(Theme.chrome.opacity(0.55)))
                }
                .frame(height: hitSize)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let f = Double((location.x - edgePad) / travel)
                    let clamped = Self.snapped(f)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        onLiveChange(clamped)
                    }
                    onCommit(clamped)
                }

                // Bookmark thumb: sits on the track, notch downward into the pages.
                BookmarkTabShape(notch: 0.28)
                    .fill(Theme.chrome)
                    .overlay(
                        BookmarkTabShape(notch: 0.28)
                            .stroke(Theme.onChrome.opacity(0.85), lineWidth: 1)
                    )
                    .frame(width: thumbWidth, height: thumbHeight)
                    .shadow(color: Theme.shadowInk.opacity(dragStartFraction == nil ? 0.18 : 0.32), radius: dragStartFraction == nil ? 2 : 5, x: 0, y: 2)
                    .scaleEffect(dragStartFraction == nil ? 1 : 1.12, anchor: .bottom)
                    .frame(width: hitSize, height: hitSize)
                    .contentShape(Rectangle())
                    // Centered on the track; the tab's top rises above the pages.
                    .offset(x: thumbX - hitSize / 2, y: -(thumbHeight - trackHeight) / 2 + 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                if dragStartFraction == nil {
                                    dragStartFraction = fraction
                                    liveFraction = fraction
                                    lastHapticStep = Int(fraction * 20)
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
                                }
                                let start = dragStartFraction ?? fraction
                                let next = Self.snapped(start + Double(value.translation.width / travel))
                                liveFraction = next
                                onLiveChange(next)
                                // A soft tick every 5%, a firmer one on the last page.
                                let step = Int(next * 20)
                                if step != lastHapticStep {
                                    lastHapticStep = step
                                    if next >= 1 {
                                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 1)
                                    } else {
                                        UISelectionFeedbackGenerator().selectionChanged()
                                    }
                                }
                            }
                            .onEnded { _ in
                                let final = liveFraction
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    dragStartFraction = nil
                                }
                                onCommit(final)
                            }
                    )
                    .animation(thumbAnimation, value: shownFraction)
            }
            .frame(width: width, height: hitSize)
        }
        .frame(height: hitSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading progress")
        .accessibilityValue("\(Int((shownFraction * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.05 : -0.05
            let next = min(1, max(0, fraction + delta))
            onLiveChange(next)
            onCommit(next)
        }
    }
}

// MARK: - Finish celebration

/// Paper-scrap confetti burst fired when a reader lands the bookmark on the last
/// page. The pieces are little pages, bookmark tabs, and dots that fan up from
/// `origin`, tumble, and fall away. Most scraps take a hue from
/// `Theme.confettiPalette`; roughly one in six stays a paper scrap with an ink
/// outline so the burst still reads as torn book pages rather than generic
/// party confetti. This is the one place the monochrome rule is relaxed: it is a
/// momentary celebration, not chrome. Purely decorative: never hit-testable,
/// self-clears after the fall. Bump `trigger` to fire another burst.
///
/// Don't mount this inside the card that's celebrating: pieces fly well past any
/// card's bounds, and an ancestor's clip (a scroll view, a rounded card) cuts them
/// off mid-flight. Fire through `FinishConfettiCenter` instead, which draws the
/// burst in one full-screen, unclipped host so the scraps stay visible for their
/// whole travel.
struct FinishConfettiBurst: View {
    let trigger: Int
    /// Launch point in *this view's own* coordinate space. The full-screen host
    /// ignores safe areas, so a point captured with `.frame(in: .global)` from
    /// anywhere in the app lands here unchanged.
    var origin: CGPoint
    var pieceCount: Int = 46

    private struct Piece {
        var vx: CGFloat
        var vy: CGFloat
        var size: CGFloat
        var spin: CGFloat
        var spinRate: CGFloat
        var shape: Int      // 0 page, 1 bookmark, 2 dot
        /// -1 = paper scrap (outlined in ink); otherwise an index into
        /// `Theme.confettiPalette`.
        var colorIndex: Int
        var delay: Double
        var drift: CGFloat
    }

    private static let duration: Double = 2.1

    @State private var pieces: [Piece] = []
    @State private var startedAt: Date? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: startedAt == nil)) { timeline in
            Canvas(rendersAsynchronously: false) { context, size in
                guard let startedAt else { return }
                let t = timeline.date.timeIntervalSince(startedAt)
                guard t >= 0, t <= Self.duration else { return }
                _ = size
                let ox = origin.x
                let oy = origin.y
                let gravity: CGFloat = 1500
                for piece in pieces {
                    let pt = t - piece.delay
                    guard pt > 0 else { continue }
                    let life = pt / (Self.duration - piece.delay)
                    guard life < 1 else { continue }
                    let ct = CGFloat(pt)
                    let x = ox + piece.vx * ct + piece.drift * sin(ct * 6 + piece.spin)
                    let y = oy + piece.vy * ct + 0.5 * gravity * ct * ct
                    // Hold full opacity for the arc, fade over the last third.
                    let alpha = life < 0.66 ? 1 : max(0, 1 - (life - 0.66) / 0.34)
                    let isPaper = piece.colorIndex < 0
                    let color: Color = isPaper
                        ? Theme.onChrome
                        : Theme.confettiPalette[piece.colorIndex % Theme.confettiPalette.count]
                    var ctx = context
                    ctx.opacity = alpha
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: .radians(piece.spin + piece.spinRate * ct))
                    let s = piece.size
                    switch piece.shape {
                    case 0:
                        // A torn page: tall thin rectangle.
                        let rect = CGRect(x: -s * 0.35, y: -s * 0.5, width: s * 0.7, height: s)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                        if isPaper {
                            ctx.stroke(Path(roundedRect: rect, cornerRadius: 1), with: .color(Theme.chrome.opacity(0.6)), lineWidth: 0.8)
                        }
                    case 1:
                        let rect = CGRect(x: -s * 0.28, y: -s * 0.5, width: s * 0.56, height: s)
                        ctx.fill(BookmarkTabShape(notch: 0.3).path(in: rect), with: .color(color))
                        if isPaper {
                            ctx.stroke(BookmarkTabShape(notch: 0.3).path(in: rect), with: .color(Theme.chrome.opacity(0.6)), lineWidth: 0.8)
                        }
                    default:
                        let d = s * 0.42
                        ctx.fill(Path(ellipseIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d)), with: .color(color))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, _ in fire() }
    }

    private func fire() {
        var rng = SystemRandomNumberGenerator()
        pieces = (0..<pieceCount).map { i in
            // Fan mostly up and toward the card's centre, a few straight up.
            let angle = CGFloat.random(in: (.pi * 0.55)...(.pi * 1.05), using: &rng)
            let speed = CGFloat.random(in: 420...820, using: &rng)
            return Piece(
                vx: cos(angle) * speed,
                vy: sin(angle) * -speed,
                size: CGFloat.random(in: 6...13, using: &rng),
                spin: CGFloat.random(in: 0...(2 * .pi), using: &rng),
                spinRate: CGFloat.random(in: -9...9, using: &rng),
                shape: i % 5 == 0 ? 1 : (i % 3 == 0 ? 2 : 0),
                // Mostly colored scraps, with about one paper scrap in six so the
                // burst keeps its torn-page character. Hues are random per piece
                // (not cycled) so no two bursts land in the same order.
                colorIndex: i % 6 == 0
                    ? -1
                    : Int.random(in: 0..<Theme.confettiPalette.count, using: &rng),
                delay: Double.random(in: 0...0.12, using: &rng),
                drift: CGFloat.random(in: 4...14, using: &rng)
            )
        }
        startedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration + 0.1) {
            if let startedAt, Date().timeIntervalSince(startedAt) >= Self.duration {
                self.startedAt = nil
                pieces = []
            }
        }
    }
}

/// Routes finish-line confetti to one full-screen host so the scraps are never
/// clipped by the card that fired them.
///
/// Why this exists: the burst used to be an `.overlay` on the celebrating card
/// with a fixed bleed. Pieces fly farther than any bleed, and every ancestor clip
/// between the card and the window (the scroll view, the card's own rounded
/// background) cut them off the moment they left the card, so confetti appeared
/// *inside* the card and vanished at its edge. Firing through here instead draws
/// them once, above everything, in window coordinates.
@MainActor
final class FinishConfettiCenter: ObservableObject {
    static let shared = FinishConfettiCenter()

    /// Launch point in window coordinates. Bumped `trigger` refires the burst.
    @Published private(set) var origin: CGPoint = .zero
    @Published private(set) var trigger: Int = 0

    private init() {}

    /// Fire a burst from `point`, given in window space — capture it with
    /// `.frame(in: .global)` on whatever view should throw the confetti.
    func fire(from point: CGPoint) {
        origin = point
        trigger += 1
    }
}

private struct FinishConfettiHostModifier: ViewModifier {
    @ObservedObject private var center = FinishConfettiCenter.shared
    @State private var previewTimer: Timer? = nil

    func body(content: Content) -> some View {
        content
            .overlay {
                FinishConfettiBurst(trigger: center.trigger, origin: center.origin)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .onAppear {
                // `-uiPreviewFinishConfetti`: refire from a fixed spot every 3s so
                // the celebration (and its full travel across the screen) can be
                // checked in the simulator without scrubbing a book to its last
                // page. Lives on the host, not the card, because the host is a
                // single instance that stays alive for the whole session.
                guard ProcessInfo.processInfo.arguments.contains("-uiPreviewFinishConfetti"),
                      previewTimer == nil else { return }
                @MainActor func burst() {
                    FinishConfettiCenter.shared.fire(from: CGPoint(x: 340, y: 700))
                }
                previewTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                    Task { @MainActor in burst() }
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    burst()
                }
            }
    }
}

extension View {
    /// Attach exactly once, near the root and above the tab bar, so bursts render
    /// over all app content. A second host would draw a second, differently
    /// randomized burst on top of the first.
    func finishConfettiHost() -> some View {
        modifier(FinishConfettiHostModifier())
    }
}

/// Everything the finish moment does besides confetti: the success haptic and
/// a shared "did we just cross the line" test so the queue card and the book
/// profile celebrate the same way.
enum FinishCelebration {
    /// True when a commit lands on 100% from anywhere below it. Live scrubbing
    /// across 100% doesn't count; only the value the reader let go on.
    static func crossedFinishLine(previous: Double, committed: Double) -> Bool {
        committed >= 0.999 && previous < 0.999
    }

    static func haptic() {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.success)
    }
}

// MARK: - Card

/// One Reading now book: cover, title, live percent + page readout, and the
/// scrubber. In the queue the whole card is wrapped in `QueueReadingNowDragCard`
/// so a long press anywhere above the scrubber lifts it for reordering.
/// `readOnly` (another reader's library) shows the cover and readout only.
struct ReadingNowProgressCard: View {
    let userBook: UserBook
    let book: Book
    let coverWidth: CGFloat
    var readOnly: Bool = false
    var onBookTap: ((Book) -> Void)? = nil
    /// Persist a new fraction (finger lifted / track tapped).
    var onCommitProgress: ((Double) -> Void)? = nil
    /// Reader slid to 100% and tapped the finish button.
    var onMarkFinished: (() -> Void)? = nil
    /// Cover view (drag-enabled in the queue; plain elsewhere).
    let cover: () -> AnyView

    /// Fraction shown while the finger is down; nil = show the model value.
    @State private var liveFraction: Double? = nil
    @State private var finishPop: Bool = false
    /// This card's frame in window space, used to aim the confetti burst.
    @State private var cardFrame: CGRect = .zero

    private var shownFraction: Double { liveFraction ?? userBook.progressFraction }
    private var shownPercent: Int { Int((shownFraction * 100).rounded()) }
    private var coverHeight: CGFloat { coverWidth * 1.5 }
    private var isFinished: Bool { shownFraction >= 0.999 }
    private var hasProgress: Bool { userBook.readingProgress != nil || liveFraction != nil }
    private var ribbonAnimation: Animation? {
        liveFraction == nil ? .spring(response: 0.32, dampingFraction: 0.82) : nil
    }

    private var pageLine: String? {
        guard let pages = book.pageCount, pages > 0 else { return nil }
        let page = isFinished ? pages : UserBook.page(forFraction: shownFraction, pageCount: pages)
        return "Page \(page) of \(pages)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    cover()
                        .frame(width: coverWidth, height: coverHeight)
                    if hasProgress || !readOnly {
                        CoverProgressRibbon(fraction: shownFraction, coverWidth: coverWidth, coverHeight: coverHeight)
                            .animation(ribbonAnimation, value: shownFraction)
                    }
                }
                .frame(width: coverWidth, height: coverHeight)

                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(Theme.headline())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(book.author)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if readOnly && !hasProgress {
                        // Another reader's book with no page logged. Say so
                        // rather than echoing the shelf title, so the empty
                        // right side reads as "nothing recorded" instead of a
                        // readout that failed to load.
                        Text("No progress logged")
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        readout
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: coverHeight, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture { onBookTap?(book) }
            }

            if !readOnly {
                ReadingProgressScrubber(
                    fraction: userBook.progressFraction,
                    onLiveChange: { liveFraction = $0 },
                    onCommit: { value in
                        let previous = userBook.progressFraction
                        liveFraction = nil
                        onCommitProgress?(value)
                        if FinishCelebration.crossedFinishLine(previous: previous, committed: value) {
                            celebrateFinish()
                        }
                    },
                    compact: true
                )

                if isFinished, liveFraction == nil, let onMarkFinished {
                    Button(action: onMarkFinished) {
                        Text("MARK AS FINISHED")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(0.5)
                    }
                    .buttonStyle(.spine(.primary, size: .small))
                    .padding(.top, 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(Theme.chrome.opacity(finishPop ? 0.9 : 0.35), lineWidth: finishPop ? 1.5 : Theme.chromeHairline)
        )
        .scaleEffect(finishPop ? 1.025 : 1)
        // Where the card sits in the window, so the confetti host can launch the
        // burst from the bookmark's resting spot without living inside this card
        // (and getting clipped at its edge).
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { cardFrame = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isFinished && liveFraction == nil)
    }

    /// Throw confetti from the bookmark's resting spot (right end of the track,
    /// since finishing puts it at 100%), in window coordinates so the burst's
    /// full-screen host can draw it unclipped.
    private func fireConfetti() {
        guard cardFrame != .zero else { return }
        FinishConfettiCenter.shared.fire(
            from: CGPoint(
                x: cardFrame.minX + cardFrame.width * 0.93,
                y: cardFrame.minY + cardFrame.height * 0.8
            )
        )
    }

    /// Success haptic, a quick card pop, and a paper confetti burst from the
    /// bookmark's resting spot. Only called once the finger has lifted.
    private func celebrateFinish() {
        FinishCelebration.haptic()
        fireConfetti()
        withAnimation(.snappy(duration: 0.28, extraBounce: 0.25)) { finishPop = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { finishPop = false }
        }
    }

    /// Big percent with the page position beside it; both move together.
    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(shownPercent)")
                    .font(.system(size: 30, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText(value: Double(shownPercent)))
                Text("%")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            if let pageLine {
                Text(pageLine)
                    .font(Theme.caption())
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            } else if !readOnly, userBook.readingProgress == nil {
                Text("Slide the bookmark to track your progress")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
