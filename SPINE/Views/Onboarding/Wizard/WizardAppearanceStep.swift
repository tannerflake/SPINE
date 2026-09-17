//
//  WizardAppearanceStep.swift
//  SPINE
//
//  Onboarding wizard step: pick Light / Dark / System (auto). Writes straight
//  to @AppStorage(AppearancePreference.storageKey), so the tap re-themes the
//  whole wizard live behind the cards. Each card is a bare page in its own two
//  tones with a single sun or moon on it; the System card is that page split
//  down the middle, sun on cream and moon on ink, so "auto" reads at a glance.
//  Copy rule: no em-dashes in user-facing text.
//

import SwiftUI

struct WizardAppearanceStep: View {
    @ObservedObject var model: OnboardingWizardModel

    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.defaultValue.rawValue

    private var selection: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .defaultValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TypewriterText(
                text: "Light or Dark mode?",
                font: .system(size: 28, weight: .bold),
                centered: false
            )

            Text("You can change this in your settings later.")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .wizardReveal(delay: 0.2)
                .padding(.top, 10)

            // Capped so the row lands near the middle of the screen height
            // rather than the middle of the space left under the headline.
            Spacer(minLength: 12).frame(maxHeight: 145)

            // Bottom aligned so the three cards line up along their labels even
            // though only System carries a "Recommended" tag above it.
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(AppearancePreference.allCases) { option in
                    optionCard(option)
                }
            }
            .frame(maxWidth: .infinity)
            .wizardReveal(delay: 0.3)

            Spacer(minLength: 12)

            WizardCTAButton(title: "Looks good") {
                model.advance()
            }
            .wizardReveal(delay: 0.3)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 24)
    }

    // MARK: - Option card

    private func optionCard(_ option: AppearancePreference) -> some View {
        let isSelected = selection == option
        return Button {
            guard !isSelected else { return }
            WizardHaptics.selection()
            withAnimation(.easeInOut(duration: 0.28)) {
                appearanceRaw = option.rawValue
            }
        } label: {
            VStack(spacing: 9) {
                recommendedTag
                    .opacity(option == .system ? 1 : 0)

                // Bottom trailing: the page glyphs live in the upper area, so a
                // top-corner badge would sit on top of them.
                ZStack(alignment: .bottomTrailing) {
                    MockPage(mode: option)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(Theme.onChrome)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Theme.chrome))
                            .overlay(Circle().strokeBorder(Theme.background, lineWidth: 1.5))
                            .offset(x: 7, y: 7)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(0.72, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            Theme.textPrimary.opacity(isSelected ? 0.9 : 0.25),
                            lineWidth: isSelected ? 2.5 : 1.5
                        )
                )

                Text(option.label)
                    .font(.system(size: 15, weight: isSelected ? .heavy : .semibold))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.springPress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: option))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Kept in the layout (hidden) on the other two cards so all three rows
    /// share one baseline.
    private var recommendedTag: some View {
        Text("Recommended")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func accessibilityLabel(for option: AppearancePreference) -> String {
        switch option {
        case .light: return "Light mode. Always the cream page."
        case .dark: return "Dark mode. Always the ink page."
        case .system: return "System, recommended. Follows your phone's light or dark setting."
        }
    }
}

// MARK: - Mock page

/// A bare miniature page carrying one glyph: sun for light, moon for dark.
/// Drawn with fixed (non trait-aware) tones so each card keeps showing its own
/// mode no matter which appearance the app is currently rendering in. System
/// draws both pages and clips the ink one to the right half, so a single card
/// shows a sunlit cream side and a moonlit ink side of the same page.
private struct MockPage: View {
    let mode: AppearancePreference

    var body: some View {
        ZStack {
            switch mode {
            case .light:
                page(page: Theme.paperFixed, ink: Theme.inkFixed, glyph: "sun.max.fill", glyphFraction: 0.5)
            case .dark:
                page(page: Theme.inkFixed, ink: Theme.paperFixed, glyph: "moon.fill", glyphFraction: 0.5)
            case .system:
                // One glyph per half, each centered in its own side.
                page(page: Theme.paperFixed, ink: Theme.inkFixed, glyph: "sun.max.fill", glyphFraction: 0.25)
                page(page: Theme.inkFixed, ink: Theme.paperFixed, glyph: "moon.fill", glyphFraction: 0.75)
                    .clipShape(TrailingHalf())
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func page(page: Color, ink: Color, glyph: String, glyphFraction: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack {
                page
                Image(systemName: glyph)
                    .font(.system(size: mode == .system ? 22 : 30, weight: .medium))
                    .foregroundStyle(ink)
                    .position(x: geo.size.width * glyphFraction, y: geo.size.height * 0.5)
            }
        }
    }
}

/// Right half of the bounds. Used to split the System card down the middle.
private struct TrailingHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height))
    }
}
