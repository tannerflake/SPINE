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
    /// Bump to make the ribbon swing on its top edge, the way a real bookmark
    /// wobbles when you tuck it a few pages further in. Fired by routine
    /// progress commits; the finish moment leaves it alone.
    var sway: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                // Pendulum swing from the tucked-in top edge: a quick kick one
                // way, then a loose spring back through centre.
                .phaseAnimator([0, 1, 2], trigger: sway) { content, phase in
                    content.rotationEffect(
                        .degrees(reduceMotion ? 0 : (phase == 1 ? -10 : (phase == 2 ? 5 : 0))),
                        anchor: .top
                    )
                } animation: { phase in
                    phase == 1 ? .snappy(duration: 0.14) : .spring(response: 0.45, dampingFraction: 0.45)
                }
                // Peeks past the top edge like a real bookmark.
                .offset(x: x, y: -4)
        }
        .frame(width: coverWidth, height: coverHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - Progress tint

/// The one place *routine* progress gets color. Maps a fraction to a sunrise
/// sweep of the confetti hues: teal on the first pages, through blue, violet and
/// plum, to coral and amber on the home stretch. 0% is deliberately no hue at
/// all (chrome): a book you haven't started is a neutral fact, not a warning, so
/// nothing here is red and nothing lights up at zero. Only interaction moments
/// use these colors (the finger is down, or the half-second afterglow after a
/// commit); at rest the scrubber is as monochrome as the rest of the app.
enum ReadingProgressTint {
    private struct Stop { let at: Double; let r: Double; let g: Double; let b: Double }
    /// Same hues as `Theme.confettiPalette` (all verified >= 3:1 on paper and ink),
    /// minus the red, ordered cool to warm.
    private static let stops: [Stop] = [
        Stop(at: 0.00, r: 34, g: 149, b: 151),   // teal
        Stop(at: 0.30, r: 66, g: 118, b: 206),   // blue
        Stop(at: 0.55, r: 138, g: 96, b: 206),   // violet
        Stop(at: 0.75, r: 191, g: 74, b: 131),   // plum pink
        Stop(at: 0.90, r: 217, g: 101, b: 60),   // coral
        Stop(at: 1.00, r: 178, g: 125, b: 43)    // amber
    ]

    /// Hue for a position in the book. Linear RGB blend between neighbouring stops.
    static func color(for fraction: Double) -> Color {
        let f = min(1, max(0, fraction))
        var lo = stops[0]
        var hi = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) where f >= stops[i].at && f <= stops[i + 1].at {
            lo = stops[i]
            hi = stops[i + 1]
            break
        }
        let t = (f - lo.at) / max(0.0001, hi.at - lo.at)
        return Color(
            red: (lo.r + (hi.r - lo.r) * t) / 255,
            green: (lo.g + (hi.g - lo.g) * t) / 255,
            blue: (lo.b + (hi.b - lo.b) * t) / 255
        )
    }

    /// `nil` at 0% so callers fall back to chrome: an unstarted book never glows.
    static func tint(for fraction: Double) -> Color? {
        fraction <= 0.0001 ? nil : color(for: fraction)
    }

    /// 25 / 50 / 75: the quarter marks get a firmer tick and a bigger scrap burst
    /// when a commit carries the bookmark forward across one. 100% is not a
    /// milestone here; that's the finish line and has its own celebration.
    static func crossedMilestone(previous: Double, committed: Double) -> Bool {
        guard committed > previous, committed < 0.999 else { return false }
        for mark in [0.25, 0.5, 0.75] where previous < mark && committed >= mark { return true }
        return false
    }
}

// MARK: - Scrubber effects

/// Transient decoration for one scrubber: the page flutter that trails the thumb
/// while dragging, the ripple and scrap burst on release, and the envelope that
/// fades the fore-edge's color back to chrome once the finger lifts. Pure state;
/// `ReadingProgressScrubber` draws it. Wakes when a drag starts and sleeps on its
/// own ~1.5s after everything has settled so idle cards cost nothing.
@MainActor
final class ScrubberFX: ObservableObject {
    struct Scrap {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var vy: CGFloat
        /// Vertical acceleration: tiny for drifting flutter, heavy for burst pieces.
        var gravity: CGFloat
        var size: CGFloat
        var spin: CGFloat
        var spinRate: CGFloat
        var born: Date
        var life: Double
        /// Position in the book this scrap came from; picks its hue.
        var fraction: Double
        /// 0 page, 1 bookmark tab, 2 dot.
        var shape: Int
    }
    struct Ripple {
        var x: CGFloat
        var born: Date
        var fraction: Double
    }

    /// Drives the timeline. True from the first drag event until ~1.5s after the
    /// last scrap has died.
    @Published private(set) var active = false

    private(set) var dragStartedAt: Date? = nil
    private(set) var dragEndedAt: Date? = nil
    private(set) var scraps: [Scrap] = []
    private(set) var ripples: [Ripple] = []
    private var emitAccumulator: CGFloat = 0
    private var sleepWork: DispatchWorkItem? = nil

    /// 0...1 "how lit is the scrubber": ramps in over the first beat of a drag,
    /// holds while the finger is down, eases out after release.
    func envelope(at now: Date) -> Double {
        if let dragStartedAt {
            return min(1, now.timeIntervalSince(dragStartedAt) / 0.18)
        }
        if let dragEndedAt {
            let d = min(1, max(0, now.timeIntervalSince(dragEndedAt) / 0.75))
            return (1 - d) * (1 - d)
        }
        return 0
    }

    func beginDrag() {
        dragStartedAt = Date()
        dragEndedAt = nil
        emitAccumulator = 0
        wake()
    }

    func endDrag() {
        dragEndedAt = Date()
        dragStartedAt = nil
        scheduleSleep(after: 1.6)
    }

    /// Call per drag event. Sheds one small page scrap for every few points the
    /// thumb travels, trailing behind the direction of motion.
    func flutter(atX x: CGFloat, trackTopY: CGFloat, movedPx: CGFloat, fraction: Double) {
        emitAccumulator += abs(movedPx)
        let forward = movedPx >= 0
        var rng = SystemRandomNumberGenerator()
        var budget = 6
        while emitAccumulator >= 7, budget > 0 {
            emitAccumulator -= 7
            budget -= 1
            scraps.append(Scrap(
                x: x + CGFloat.random(in: -3...3, using: &rng),
                y: trackTopY + CGFloat.random(in: -2...4, using: &rng),
                vx: (forward ? -1 : 1) * CGFloat.random(in: 14...60, using: &rng),
                vy: -CGFloat.random(in: 45...120, using: &rng),
                gravity: 90,
                size: CGFloat.random(in: 3...6, using: &rng),
                spin: CGFloat.random(in: 0...(2 * .pi), using: &rng),
                spinRate: CGFloat.random(in: -10...10, using: &rng),
                born: Date(),
                life: Double.random(in: 0.5...0.85, using: &rng),
                fraction: fraction,
                shape: Int.random(in: 0...4, using: &rng) == 0 ? 2 : 0
            ))
        }
        if scraps.count > 90 { scraps.removeFirst(scraps.count - 90) }
    }

    /// Release ring from the thumb.
    func ripple(atX x: CGFloat, fraction: Double) {
        ripples.append(Ripple(x: x, born: Date(), fraction: fraction))
        wake()
        scheduleSleep(after: 1.6)
    }

    /// A small fan of scraps for a routine forward commit, colored with the
    /// stretch of pages just read (hues sampled between the old and new spot).
    /// Deliberately a fraction of the finish confetti: a dozen tiny pieces that
    /// stay near the track, not a screen-wide burst.
    func burst(atX x: CGFloat, trackTopY: CGFloat, from previous: Double, to committed: Double, count: Int) {
        var rng = SystemRandomNumberGenerator()
        let lo = min(previous, committed)
        let hi = max(previous, committed)
        for i in 0..<count {
            let angle = CGFloat.random(in: (.pi * 0.2)...(.pi * 0.8), using: &rng)
            let speed = CGFloat.random(in: 120...260, using: &rng)
            scraps.append(Scrap(
                x: x,
                y: trackTopY - 2,
                vx: cos(angle) * speed,
                vy: -sin(angle) * speed,
                gravity: 700,
                size: CGFloat.random(in: 4...8, using: &rng),
                spin: CGFloat.random(in: 0...(2 * .pi), using: &rng),
                spinRate: CGFloat.random(in: -12...12, using: &rng),
                born: Date(),
                life: Double.random(in: 0.7...1.05, using: &rng),
                fraction: lo + (hi - lo) * Double.random(in: 0...1, using: &rng),
                shape: i % 4 == 0 ? 1 : (i % 3 == 0 ? 2 : 0)
            ))
        }
        wake()
        scheduleSleep(after: 1.8)
    }

    /// Drop anything past its lifetime. Call once per frame before drawing.
    func prune(at now: Date) {
        scraps.removeAll { now.timeIntervalSince($0.born) >= $0.life }
        ripples.removeAll { now.timeIntervalSince($0.born) >= 0.6 }
    }

    private func wake() {
        sleepWork?.cancel()
        sleepWork = nil
        if !active { active = true }
    }

    private func scheduleSleep(after delay: Double) {
        sleepWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dragStartedAt == nil else { return }
            self.scraps = []
            self.ripples = []
            self.dragEndedAt = nil
            self.active = false
        }
        sleepWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// MARK: - Scrubber

/// Fore-edge track (one hairline per "page" of width) with a bookmark-tab
/// thumb. Only the thumb starts a drag, so the surrounding ScrollView keeps
/// scrolling when a finger lands on the track; a tap on the track jumps.
///
/// Routine moves (anything that doesn't land on 100%) get their own flourish,
/// all of it transient: the pages under the thumb fan up and the read pages
/// take on the progress hue while the finger is down, the thumb leans into the
/// direction of travel and sheds a trail of page scraps, and letting go sends
/// a ripple out from the bookmark plus a small scrap burst sized to how far the
/// reader just got. The 100% commit is left to `FinishCelebration` untouched.
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dragStartFraction: Double? = nil
    @State private var liveFraction: Double = 0
    @State private var lastHapticStep: Int = -1
    /// Degrees the thumb leans toward the direction it's moving.
    @State private var thumbTilt: Double = 0
    @StateObject private var fx = ScrubberFX()

    private var trackHeight: CGFloat { compact ? 14 : 18 }
    private var thumbWidth: CGFloat { compact ? 18 : 22 }
    private var thumbHeight: CGFloat { compact ? 27 : 34 }
    private var hitSize: CGFloat { compact ? 40 : 48 }
    /// Horizontal padding so the thumb never clips at 0% or 100%.
    private var edgePad: CGFloat { thumbWidth / 2 + 2 }
    /// Headroom above the track that the effects canvas may draw into: flutter
    /// rises, burst pieces arc. The canvas is an unclipped overlay so this can
    /// exceed the control's own frame.
    private var fxHeadroom: CGFloat { compact ? 44 : 56 }

    private var shownFraction: Double { dragStartFraction == nil ? fraction : liveFraction }
    private var isDragging: Bool { dragStartFraction != nil }
    /// Thumb color: chrome at rest, the progress hue while the finger is down
    /// (still chrome at 0%, by design).
    private var thumbFill: Color {
        isDragging ? (ReadingProgressTint.tint(for: liveFraction) ?? Theme.chrome) : Theme.chrome
    }

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
            let trackTopY = (hitSize - trackHeight) / 2

            TimelineView(.animation(minimumInterval: 1 / 60, paused: !fx.active)) { timeline in
                let now = timeline.date
                let envelope = fx.envelope(at: now)

                ZStack(alignment: .leading) {
                    // Fore-edge: read pages in ink, unread pages faint. While lit,
                    // the read pages take the progress sweep (teal at the first
                    // page to the current hue under the thumb) and the pages
                    // nearest the thumb fan upward.
                    Canvas { context, size in
                        let stride: CGFloat = 4
                        let lineW: CGFloat = 1.25
                        let y0 = (size.height - trackHeight) / 2
                        var x = edgePad
                        let fillX = edgePad + travel * CGFloat(min(1, max(0, shownFraction)))
                        let fanAmp: CGFloat = reduceMotion ? 0 : CGFloat(envelope) * (compact ? 6 : 8)
                        let glow = shownFraction > 0.0001 ? envelope : 0
                        while x <= size.width - edgePad + 0.5 {
                            let d = (x - fillX) / (compact ? 18 : 24)
                            let lift = fanAmp * exp(-d * d)
                            let h = trackHeight + lift
                            let rect = CGRect(x: x - lineW / 2, y: y0 + trackHeight - h, width: lineW, height: h)
                            let read = x <= fillX + 0.5
                            let path = Path(roundedRect: rect, cornerRadius: 0.6)
                            context.fill(path, with: .color(read ? Theme.chrome : Theme.chrome.opacity(0.18)))
                            if read, glow > 0 {
                                let lineFraction = Double((x - edgePad) / travel)
                                context.fill(path, with: .color(ReadingProgressTint.color(for: lineFraction).opacity(glow)))
                            }
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
                        commit(clamped, previous: fraction, travel: travel, trackTopY: trackTopY)
                    }

                    // Bookmark thumb: sits on the track, notch downward into the pages.
                    BookmarkTabShape(notch: 0.28)
                        .fill(thumbFill)
                        .overlay(
                            BookmarkTabShape(notch: 0.28)
                                .stroke(Theme.onChrome.opacity(0.85), lineWidth: 1)
                        )
                        .frame(width: thumbWidth, height: thumbHeight)
                        .shadow(color: Theme.shadowInk.opacity(isDragging ? 0.32 : 0.18), radius: isDragging ? 5 : 2, x: 0, y: 2)
                        // Colored halo while lit; fades with the tint.
                        .shadow(color: (isDragging ? thumbFill : Color.clear).opacity(0.45), radius: isDragging ? 9 : 0, x: 0, y: 0)
                        .scaleEffect(isDragging ? 1.12 : 1, anchor: .bottom)
                        .rotationEffect(.degrees(reduceMotion ? 0 : thumbTilt), anchor: .bottom)
                        .animation(.easeOut(duration: 0.45), value: isDragging)
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
                                        fx.beginDrag()
                                    }
                                    let start = dragStartFraction ?? fraction
                                    let next = Self.snapped(start + Double(value.translation.width / travel))
                                    let movedPx = CGFloat(next - liveFraction) * travel
                                    liveFraction = next
                                    onLiveChange(next)
                                    // Lean into the motion; the spring smooths the
                                    // per-event jitter into a glide.
                                    let targetTilt = min(14, max(-14, Double(movedPx) * 2.2))
                                    withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.75)) {
                                        thumbTilt = thumbTilt * 0.55 + targetTilt * 0.45
                                    }
                                    if !reduceMotion {
                                        let x = edgePad + travel * CGFloat(next)
                                        fx.flutter(atX: x, trackTopY: trackTopY, movedPx: movedPx, fraction: next)
                                    }
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
                                    let previous = dragStartFraction ?? fraction
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        dragStartFraction = nil
                                    }
                                    // Loose spring back to upright: a little wobble as it settles.
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.42)) {
                                        thumbTilt = 0
                                    }
                                    fx.endDrag()
                                    commit(final, previous: previous, travel: travel, trackTopY: trackTopY)
                                }
                        )
                        .animation(thumbAnimation, value: shownFraction)
                }
                .frame(width: width, height: hitSize)
                // Effects layer: flutter, burst scraps, release ripple. Sits in an
                // oversized overlay so pieces can rise above the control without
                // the control's own frame clipping them.
                .overlay(alignment: .bottom) {
                    if fx.active {
                        Canvas(rendersAsynchronously: false) { context, size in
                            fx.prune(at: now)
                            let top = fxHeadroom
                            let trackCenterY = top + hitSize / 2
                            for ripple in fx.ripples {
                                let p = min(1, now.timeIntervalSince(ripple.born) / 0.55)
                                let eased = 1 - pow(1 - p, 2)
                                let r = 6 + CGFloat(eased) * (compact ? 26 : 34)
                                let rect = CGRect(x: ripple.x - r, y: trackCenterY - r, width: r * 2, height: r * 2)
                                let color = ReadingProgressTint.tint(for: ripple.fraction) ?? Theme.chrome
                                context.stroke(
                                    Path(ellipseIn: rect),
                                    with: .color(color.opacity((1 - p) * 0.9)),
                                    lineWidth: 2.2 * CGFloat(1 - p) + 0.4
                                )
                            }
                            for scrap in fx.scraps {
                                let t = CGFloat(now.timeIntervalSince(scrap.born))
                                let life = Double(t) / scrap.life
                                guard life >= 0, life < 1 else { continue }
                                let x = scrap.x + scrap.vx * t
                                let y = top + scrap.y + scrap.vy * t + 0.5 * scrap.gravity * t * t
                                let alpha = life < 0.55 ? 1 : max(0, 1 - (life - 0.55) / 0.45)
                                let color = ReadingProgressTint.tint(for: scrap.fraction) ?? Theme.chrome
                                var ctx = context
                                ctx.opacity = alpha
                                ctx.translateBy(x: x, y: y)
                                ctx.rotate(by: .radians(scrap.spin + scrap.spinRate * t))
                                let s = scrap.size
                                switch scrap.shape {
                                case 1:
                                    let rect = CGRect(x: -s * 0.28, y: -s * 0.5, width: s * 0.56, height: s)
                                    ctx.fill(BookmarkTabShape(notch: 0.3).path(in: rect), with: .color(color))
                                case 2:
                                    let d = s * 0.5
                                    ctx.fill(Path(ellipseIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d)), with: .color(color))
                                default:
                                    let rect = CGRect(x: -s * 0.35, y: -s * 0.5, width: s * 0.7, height: s)
                                    ctx.fill(Path(roundedRect: rect, cornerRadius: 0.8), with: .color(color))
                                }
                            }
                        }
                        .frame(width: width, height: hitSize + fxHeadroom)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
            }
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

    /// Persist, then decorate. The decoration only runs for routine commits:
    /// anything landing on 100% is the finish line, which the card celebrates
    /// its own way, and a commit that stays at 0% stays quiet.
    private func commit(_ value: Double, previous: Double, travel: CGFloat, trackTopY: CGFloat) {
        onCommit(value)
        guard value < 0.999 else { return }
        let x = edgePad + travel * CGFloat(value)
        let milestone = ReadingProgressTint.crossedMilestone(previous: previous, committed: value)
        if milestone {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 1)
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
        }
        guard value > 0.0001 else { return }
        fx.ripple(atX: x, fraction: value)
        guard !reduceMotion else { return }
        // Scraps scale with how far the bookmark moved forward; tiny nudges get
        // the ripple only, a quarter-mark crossing gets a few extra.
        let delta = value - previous
        guard delta >= 0.03 else { return }
        let count = min(16, 4 + Int(delta * 48)) + (milestone ? 6 : 0)
        fx.burst(atX: x, trackTopY: trackTopY, from: previous, to: value, count: count)
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

// MARK: - Readout motion

private struct ReadingProgressReadoutMotion: ViewModifier {
    let dragging: Bool
    let commitTick: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(dragging && !reduceMotion ? 1.06 : 1, anchor: .leading)
            .animation(.easeOut(duration: 0.45), value: dragging)
            // Settle pop on a routine commit: a quick swell, then a loose spring back.
            .phaseAnimator([false, true], trigger: commitTick) { content, phase in
                content.scaleEffect(phase && !reduceMotion ? 1.12 : 1, anchor: .leading)
            } animation: { phase in
                phase ? .snappy(duration: 0.14) : .spring(response: 0.38, dampingFraction: 0.5)
            }
    }
}

extension View {
    /// Shared by the queue card and the book profile so the percent reacts the
    /// same way in both places: tinted and slightly larger mid-drag, a pop on a
    /// routine commit. Both are no-ops under Reduce Motion (the tint stays).
    func readingProgressReadoutMotion(dragging: Bool, commitTick: Int) -> some View {
        modifier(ReadingProgressReadoutMotion(dragging: dragging, commitTick: commitTick))
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
    /// Bumped on every routine (non-finish) commit: pops the percent and swings
    /// the cover ribbon.
    @State private var routineCommitTick: Int = 0

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
                        CoverProgressRibbon(fraction: shownFraction, coverWidth: coverWidth, coverHeight: coverHeight, sway: routineCommitTick)
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
                        // Persist first, then drop the live value: the optimistic
                        // store update lands synchronously, so the readout never
                        // flashes the old number between release and commit.
                        onCommitProgress?(value)
                        liveFraction = nil
                        if FinishCelebration.crossedFinishLine(previous: previous, committed: value) {
                            celebrateFinish()
                        } else if value < 0.999, value > 0.0001 {
                            routineCommitTick += 1
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

    /// Big percent with the page position beside it; both move together. While
    /// the finger is down the number takes the progress hue and grows a touch;
    /// a routine commit gives it a quick pop as it settles back to ink.
    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(shownPercent)")
                    .font(.system(size: 30, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(liveFraction != nil ? (ReadingProgressTint.tint(for: shownFraction) ?? Theme.textPrimary) : Theme.textPrimary)
                    .contentTransition(.numericText(value: Double(shownPercent)))
                    .readingProgressReadoutMotion(dragging: liveFraction != nil, commitTick: routineCommitTick)
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
