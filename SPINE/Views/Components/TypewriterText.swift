//
//  TypewriterText.swift
//  SPINE
//
//  Word-by-word text reveal for the onboarding wizard (and anywhere else a line
//  should land like it's being said, not dumped). Words fade in, rise, and
//  unblur on a cadence, with longer beats after sentence enders. Respects
//  Reduce Motion (instant reveal) and supports tap-to-fast-forward via a
//  trigger counter.
//

import SwiftUI

/// Wrapping layout for the per-word Text views. Rows wrap greedily; each row
/// can be centered (interstitial headlines) or leading-aligned (form headers).
struct WizardWrapLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    var centered: Bool = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + lineSpacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: maxWidth.isFinite ? maxWidth : totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var rows: [[(index: Int, size: CGSize)]] = []
        var row: [(Int, CGSize)] = []
        var rowWidth: CGFloat = 0
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                rows.append(row)
                row = [(i, size)]
                rowWidth = size.width
            } else {
                row.append((i, size))
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            }
        }
        if !row.isEmpty { rows.append(row) }

        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map(\.size.height).max() ?? 0
            let rowWidth = row.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1))
            var x = centered ? bounds.minX + max(0, (maxWidth - rowWidth) / 2) : bounds.minX
            for (index, size) in row {
                // A single word longer than the line (a 24-char name in the
                // greeting) is clamped instead of running off-screen.
                let width = min(size.width, maxWidth)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                    proposal: ProposedViewSize(width: width, height: size.height)
                )
                x += width + spacing
            }
            y += rowHeight + lineSpacing
        }
    }
}

struct TypewriterText: View {
    let text: String
    var font: Font = .system(size: 30, weight: .bold)
    var textColor: Color = Theme.textPrimary
    var centered: Bool = true
    /// Base seconds between words; sentence enders add ~0.35, clause marks ~0.15.
    var wordInterval: Double = 0.10
    var startDelay: Double = 0
    /// Typing begins only once true (lets a parent sequence multiple lines).
    var isActive: Bool = true
    /// Increment to reveal everything immediately (tap-to-skip).
    var fastForwardTrigger: Int = 0
    var onFinished: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealedCount = 0
    @State private var didFinish = false

    private var words: [String] {
        text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    var body: some View {
        WizardWrapLayout(spacing: 7, lineSpacing: 6, centered: centered) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(font)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .opacity(index < revealedCount ? 1 : 0)
                    .blur(radius: reduceMotion || index < revealedCount ? 0 : 4)
                    .offset(y: reduceMotion || index < revealedCount ? 0 : 7)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: revealedCount)
            }
        }
        .multilineTextAlignment(centered ? .center : .leading)
        // One sentence for VoiceOver, not a fragment per word.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .task(id: isActive) {
            guard isActive else { return }
            await type()
        }
        .onChange(of: fastForwardTrigger) { _, _ in
            finishNow()
        }
    }

    private func delay(after word: String) -> Double {
        var d = wordInterval
        if let last = word.last {
            if ".!?…".contains(last) { d += 0.35 }
            else if ",;:".contains(last) { d += 0.15 }
        }
        return d
    }

    private func type() async {
        if reduceMotion {
            revealedCount = words.count
            fireFinished()
            return
        }
        if startDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
        }
        while revealedCount < words.count {
            guard !Task.isCancelled else { return }
            let word = words[revealedCount]
            revealedCount += 1
            try? await Task.sleep(nanoseconds: UInt64(delay(after: word) * 1_000_000_000))
        }
        fireFinished()
    }

    private func finishNow() {
        revealedCount = words.count
        fireFinished()
    }

    private func fireFinished() {
        guard !didFinish else { return }
        didFinish = true
        onFinished?()
    }
}

/// Staged entrance for non-typed elements: fade in and rise after a delay.
/// The wizard uses this for form fields and buttons beneath a typed headline.
///
/// Interactivity is deliberately NOT tied to the visual stagger. Gating hit
/// testing on the full reveal delay made every step feel broken: a CTA staged
/// at 0.45s silently ate the first tap, and the user learned to tap everything
/// twice. `interactiveGuard` is the only dead window, and it is short enough
/// (well under the ~300ms it takes a person to notice and re-tap) that the
/// first tap always lands. It exists purely so a CTA that has not started
/// fading in yet cannot be triggered completely blind.
struct WizardRevealModifier: ViewModifier {
    let delay: Double

    /// Longest the element may stay untappable, whatever its visual delay.
    private static let interactiveGuard: Double = 0.15

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var hittable = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .allowsHitTesting(hittable)
            .onAppear {
                withAnimation(.easeOut(duration: 0.35).delay(reduceMotion ? 0 : delay)) {
                    shown = true
                }
                let guardDelay = reduceMotion ? 0 : min(delay, Self.interactiveGuard)
                if guardDelay <= 0 {
                    hittable = true
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + guardDelay) {
                        hittable = true
                    }
                }
            }
    }
}

extension View {
    func wizardReveal(delay: Double) -> some View {
        modifier(WizardRevealModifier(delay: delay))
    }
}
