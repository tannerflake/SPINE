//
//  TierBadge.swift
//  Spine
//
//  Shared tier color palette, the `S TIER` badge used wherever a review's tier
//  is displayed (book profile), and the colored tier-row pillar shared by the
//  tier list's rows and the feed's posts.
//

import SwiftUI

/// Tier ladder used by the tier list and review badges. S → F.
let spineTierLabels: [String] = ["S", "A", "B", "C", "D", "F"]

/// Fill behind the Unranked pillar. `Theme.surface` sits a hair off the page, so
/// the pillar disappeared into the background of the feed and the tier list.
/// Unranked gets its own neutral gray instead: a clear step darker than paper in
/// light, a clear step lighter than ink in dark.
let spineUntieredFill = Color(UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(red: 74/255, green: 69/255, blue: 84/255, alpha: 1)      // #4A4554
        : UIColor(red: 188/255, green: 189/255, blue: 175/255, alpha: 1)   // #BCBDAF
})

/// Color for a tier letter. `nil` returns the neutral surface color (Unranked).
/// Keep in sync with `TierRowView` swatches.
func spineTierColor(for tier: String?) -> Color {
    guard let tier else { return Theme.surface }
    switch tier {
    case "S": return Color(red: 0.95, green: 0.55, blue: 0.50)   // salmon / light red
    case "A": return Color(red: 0.98, green: 0.72, blue: 0.55)   // light orange / peach
    case "B": return Color(red: 0.98, green: 0.78, blue: 0.45)   // yellow-orange
    case "C": return Color(red: 0.98, green: 0.92, blue: 0.55)   // light yellow
    case "D": return Color(red: 0.65, green: 0.85, blue: 0.60)   // light green
    case "F": return Color(red: 0.55, green: 0.70, blue: 0.92)   // soft blue
    default:  return Theme.surface
    }
}

/// Tap-to-pick tier row (UNRANKED chip + S–F buttons, no drag-and-drop). Used by the
/// Goodreads import wizard and the mark-as-read card. `nil` selection = Unranked.
struct InlineTierPicker: View {
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SpinesGlyphs.caps("Tier"))
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Theme.chrome)

            HStack(spacing: 8) {
                unrankedChip
                ForEach(spineTierLabels, id: \.self) { tier in
                    tierButton(tier)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unrankedChip: some View {
        let isSelected = selection == nil
        return Button {
            selection = nil
        } label: {
            Text("UNRANKED")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(Theme.surface)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? Theme.chrome : Theme.textTertiary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func tierButton(_ tier: String) -> some View {
        let isSelected = selection == tier
        return Button {
            selection = tier
        } label: {
            Text(tier)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.78))
                .frame(width: 34, height: 34)
                .background(spineTierColor(for: tier))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Theme.textPrimary : Color.clear, lineWidth: 2)
                )
                .scaleEffect(isSelected ? 1.08 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

/// Mono badge `S TIER` filled with the tier color, shown wherever a review's tier appears.
struct TierBadge: View {
    let tier: String
    var size: Size = .regular

    enum Size { case mini, small, regular }

    private var fontSize: CGFloat {
        switch size {
        case .mini: return 11
        case .small: return 13
        case .regular: return 16
        }
    }
    private var horizontalPadding: CGFloat {
        switch size {
        case .mini: return 8
        case .small: return 10
        case .regular: return 14
        }
    }
    private var verticalPadding: CGFloat {
        switch size {
        case .mini: return 2
        case .small: return 5
        case .regular: return 8
        }
    }

    var body: some View {
        Text("\(tier) TIER")
            .font(.system(size: fontSize, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(Color.black.opacity(0.78))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(spineTierColor(for: tier))
            .clipShape(Capsule())
    }
}

// MARK: - Tier row pillar

/// Geometry shared by every tier-row pillar (tier list rows and feed posts), so a
/// post in the feed is the same piece of furniture as a row in the tier list.
enum TierPillarMetrics {
    /// Width of the colored label column.
    static let width: CGFloat = 38
    /// Natural height of the "A / Tier" letter block that pins inside the column.
    /// Deliberately much shorter than a tier row's 96pt minimum so even an empty
    /// row has slack to slide the letter down into instead of clipping it.
    static let letterHeight: CGFloat = 34
    /// Where the letter rests in a tier-list row before any scrolling pins it:
    /// centered within the row's 96pt minimum height.
    static let tierRowLetterRestingY: CGFloat = (96 - letterHeight) / 2
    /// Gap the pinned letter keeps above its own row's bottom edge, so it never
    /// slides out through the row's rounded corner clip.
    static let letterBottomGap: CGFloat = 8
}

/// The colored label column on the left edge of a tier row: the tier letter over a
/// small "Tier" caption on the tier's color, or a rotated word (Unranked by default)
/// on `spineUntieredFill` when there's no tier. Fills whatever height its row has.
///
/// Pass `stickyScrollSpace` (the name of the enclosing ScrollView's coordinate
/// space) to pin the letter to the top of the viewport while a tall row scrolls
/// under it, stopping at the row's own bottom edge. Without it the letter simply
/// rests at `letterRestingY`.
struct TierRowPillar: View {
    let tier: String?
    /// Rotated label drawn when `tier` is nil.
    var untieredLabel: String = "Unranked"
    /// Distance from the row's top edge to the letter block at rest.
    var letterRestingY: CGFloat = TierPillarMetrics.tierRowLetterRestingY
    var stickyScrollSpace: String? = nil
    /// Breathing room the pinned letter keeps below the viewport's top edge.
    var stickyTopInset: CGFloat = 0
    /// Park the letter in the middle of the row and leave it there, ignoring
    /// `letterRestingY` and any sticky pinning. The feed uses this: its rows are
    /// short enough that a travelling letter reads as a glitch rather than a cue.
    var centersLetter: Bool = false

    var body: some View {
        ZStack {
            tier == nil ? spineUntieredFill : spineTierColor(for: tier)
            if let tier {
                if centersLetter {
                    letterBlock(tier)
                } else if let space = stickyScrollSpace {
                    GeometryReader { geo in
                        let frame = geo.frame(in: .named(space))
                        // Where the viewport's top edge falls inside this row,
                        // plus the inset the letter holds below it.
                        let wanted = -frame.minY + stickyTopInset
                        // Never past the row's own bottom edge, and never above
                        // the resting position (an unscrolled row is untouched).
                        let lowest = max(
                            letterRestingY,
                            frame.height - TierPillarMetrics.letterHeight - TierPillarMetrics.letterBottomGap
                        )
                        letterBlock(tier)
                            .offset(y: min(max(letterRestingY, wanted), lowest))
                    }
                } else {
                    VStack(spacing: 0) {
                        letterBlock(tier)
                            .padding(.top, letterRestingY)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Text(untieredLabel)
                    .font(Theme.headline())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(Theme.textSecondary)
                    .rotationEffect(.degrees(-90))
                    // Rotation is a drawing effect, not a layout one: without
                    // this the label still measures its full unrotated width and
                    // stretches the ZStack — and the fill with it — a whole word
                    // wide, spilling a gray slab across the post.
                    .frame(width: TierPillarMetrics.width)
            }
        }
        .frame(width: TierPillarMetrics.width)
        .frame(maxHeight: .infinity)
    }

    /// "A" over a tiny "Tier" — dark ink on the tier color in both appearances,
    /// since the tier fills stay saturated in dark mode.
    private func letterBlock(_ tier: String) -> some View {
        VStack(spacing: 0) {
            Text(tier)
                .font(Theme.headline())
                .lineLimit(1)
            Text("Tier")
                .font(.system(size: 8, weight: .medium))
                .opacity(0.7)
        }
        .foregroundStyle(Color.black.opacity(0.75))
        .frame(width: TierPillarMetrics.width, height: TierPillarMetrics.letterHeight)
    }
}
