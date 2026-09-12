//
//  TierBadge.swift
//  Spine
//
//  Shared tier color palette + the `S TIER` badge used wherever a
//  review's tier is displayed (book profile, feed posts).
//

import SwiftUI

/// Tier ladder used by the tier list and review badges. S → F.
let spineTierLabels: [String] = ["S", "A", "B", "C", "D", "F"]

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
