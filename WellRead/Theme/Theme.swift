//
//  Theme.swift
//  Spine
//
//  Design system: SPINE mark language — warm cream paper, near-black ink,
//  strictly monochrome chrome. Contrast and weight carry the hierarchy;
//  book covers and the universal tier colors (TierListView.swift) are the
//  only sustained color in the app. Keeps rounded corners, gradients, and
//  soft shadows; dark mode is the inverted mark (ink page, paper text).
//

import SwiftUI

enum Theme {
    // MARK: - Dark-mode plumbing
    //
    // Every palette color is a UIKit dynamic color: it resolves per trait
    // collection, so the whole `Theme.*` API adapts to light/dark automatically
    // (driven by `preferredColorScheme` at the app root — see AppearancePreference).
    // Dark mode inverts the mark: paper becomes the ink, ink becomes the page.

    /// Trait-aware color pair — light appearance / dark appearance.
    private static func dynamic(light: Color, dark: Color) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    // MARK: - Colors — The mark (fixed, appearance-independent)

    /// SPINE paper — the exact cream of the logo field. #EDEEE3.
    static let paperFixed = Color(red: 237/255, green: 238/255, blue: 227/255)
    /// SPINE ink — the exact near-black of the logo mark (violet-cast). #141018.
    static let inkFixed = Color(red: 20/255, green: 16/255, blue: 24/255)

    // MARK: - Colors — Foundation

    /// Paper — primary background. Light #EDEEE3 / dark #141018 (inverted mark).
    static let background = dynamic(light: paperFixed, dark: inkFixed)
    /// Ink — primary text. Flips to paper in dark. #141018 / #EDEEE3.
    static let textPrimary = dynamic(light: inkFixed, dark: paperFixed)
    /// Pure white — ONLY for text/icons on saturated content fills (book-cover
    /// palette, tier colors), which stay saturated in both modes. For text on
    /// `chrome`/`accent` fills use `onChrome` instead — those fills invert in dark.
    static let phosphorWhite = Color.white

    // Surfaces stay close to background; differentiation comes from borders and
    // type, not big fill jumps. In dark they step *lighter* than the background.
    /// Cards / sheets. Light #E2E3D6 / dark #1D1924.
    static let surface = dynamic(
        light: Color(red: 226/255, green: 227/255, blue: 214/255),
        dark: Color(red: 29/255, green: 25/255, blue: 36/255)
    )
    /// Elevated cards. Light #F6F7EE (paper-on-paper) / dark #272231.
    static let surfaceElevated = dynamic(
        light: Color(red: 246/255, green: 247/255, blue: 238/255),
        dark: Color(red: 39/255, green: 34/255, blue: 49/255)
    )

    // Text hierarchy — fades of the ink toward the page.
    static let textSecondary = dynamic(
        light: Color(red: 69/255, green: 66/255, blue: 75/255),
        dark: Color(red: 181/255, green: 182/255, blue: 171/255)
    )
    static let textTertiary = dynamic(
        light: Color(red: 129/255, green: 126/255, blue: 134/255),
        dark: Color(red: 138/255, green: 139/255, blue: 128/255)
    )

    /// Shadow ink — always dark in both modes (never use `textPrimary` for
    /// shadows: it flips light in dark mode and shadows become white glows).
    static let shadowInk = dynamic(light: inkFixed, dark: Color.black)

    // MARK: - Colors — Chrome (load-bearing UI frames)
    //
    // One chrome: the ink itself. Frames, dividers, badges, and title bars are
    // solid ink on paper (paper on ink in dark) — exactly the logo's two tones.

    /// Primary chrome — borders, dividers, badges, filled title bars.
    /// Light: ink. Dark: paper.
    static let chrome = dynamic(light: inkFixed, dark: paperFixed)
    /// Emphatic chrome — kept as a separate token for hierarchy flexibility,
    /// currently identical to `chrome`.
    static let chromeStrong = chrome
    /// Text/icons sitting ON a `chrome`/`accent`/`punch` fill. Light: paper. Dark: ink.
    static let onChrome = dynamic(light: paperFixed, dark: inkFixed)
    /// Quiet neutral for retro button surfaces / disabled fills.
    /// Light #C8C9BC / dark #353140.
    static let chromeGray = dynamic(
        light: Color(red: 200/255, green: 201/255, blue: 188/255),
        dark: Color(red: 53/255, green: 49/255, blue: 64/255)
    )

    // MARK: - Colors — Accents (monochrome: emphasis is weight, not hue)

    /// One-shot punch — was magenta; now full-strength ink. Reserve for truly
    /// singular moments (liked hearts, READING NOW).
    static let punch = chrome
    /// Primary CTA fill (Read button, rating pills). Solid ink; paper in dark.
    /// Pair with `onChrome` text.
    static let accent = chrome

    /// Functional danger/error — the one hue allowed to break monochrome,
    /// because errors and destructive actions must not be mistakable.
    /// Muted brick, not brand. Light #B0352C / dark #E2685F.
    static let danger = dynamic(
        light: Color(red: 176/255, green: 53/255, blue: 44/255),
        dark: Color(red: 226/255, green: 104/255, blue: 95/255)
    )

    /// Functional on-state for toggles — like `danger`, allowed to break
    /// monochrome because an ink/paper switch is unreadable against dark
    /// chrome fills. Muted green. Light #2B7A4A / dark #58B27D.
    static let toggleOn = dynamic(
        light: Color(red: 43/255, green: 122/255, blue: 74/255),
        dark: Color(red: 88/255, green: 178/255, blue: 125/255)
    )

    // MARK: - Colors — Semantic aliases (stable API for existing views)

    /// Brand chrome.
    static let primary = chrome

    /// Queue button background — quiet paper tint. Light #E0E1D2 / dark #241F2E.
    static let queueTint = dynamic(
        light: Color(red: 224/255, green: 225/255, blue: 210/255),
        dark: Color(red: 36/255, green: 31/255, blue: 46/255)
    )
    /// Text on `queueTint` — strong ink fade. Light #45424B / dark #C6C7BC.
    static let queueTintLabel = dynamic(
        light: Color(red: 69/255, green: 66/255, blue: 75/255),
        dark: Color(red: 198/255, green: 199/255, blue: 188/255)
    )

    /// Fallback "spine" color for books with no cover image — deep indigo plum.
    /// Covers are content, not chrome: they keep their color. Use phosphorWhite for text on it.
    static let defaultCoverFill = Color(red: 0.290, green: 0.240, blue: 0.550)

    /// Generated-cover palette: 12 deep book-jacket hues, each verified ≥ 7:1 contrast
    /// with `phosphorWhite` text (WCAG AA needs 4.5:1). A book picks one deterministically
    /// (stable hash of title+author) so its color never changes between renders/launches,
    /// and neighboring coverless books don't collapse into a wall of one color.
    static let coverPalette: [Color] = [
        Color(red: 74/255, green: 61/255, blue: 140/255),   // deep purple
        Color(red: 49/255, green: 46/255, blue: 129/255),   // indigo
        Color(red: 30/255, green: 58/255, blue: 110/255),   // navy
        Color(red: 37/255, green: 78/255, blue: 112/255),   // steel blue
        Color(red: 13/255, green: 92/255, blue: 99/255),    // petrol teal
        Color(red: 28/255, green: 92/255, blue: 58/255),    // forest green
        Color(red: 82/255, green: 78/255, blue: 26/255),    // dark olive
        Color(red: 146/255, green: 60/255, blue: 18/255),   // rust
        Color(red: 121/255, green: 68/255, blue: 34/255),   // sienna brown
        Color(red: 146/255, green: 34/255, blue: 30/255),   // deep red
        Color(red: 122/255, green: 28/255, blue: 56/255),   // burgundy
        Color(red: 108/255, green: 40/255, blue: 96/255)    // plum
    ]

    /// Stable palette pick — uses an FNV-1a hash (not `hashValue`, which is
    /// randomized per launch) so the same book always gets the same color.
    static func coverPaletteColor(for seed: String) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return coverPalette[Int(hash % UInt64(coverPalette.count))]
    }

    // Tier list colors (S/A/B/C/D) are universal and live in TierListView.swift.
    // They are intentionally *not* re-themed here.

    // MARK: - Typography
    //
    // One voice: SF Pro everywhere — weight and tracking carry the hierarchy,
    // covers and tier colors carry the personality. The only exceptions live
    // outside the theme (serif on generated book-cover placeholders, where it
    // imitates a printed jacket, and mono in debug diagnostics for raw tokens).

    private static func sans(_ size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight)
    }

    static func largeTitle() -> Font { sans(28, weight: .bold) }
    static func title() -> Font { sans(22, weight: .bold) }
    static func title2() -> Font { sans(18, weight: .semibold) }
    /// Feed section label ("Your friends", etc.).
    static func feedSectionHeader() -> Font { sans(17, weight: .semibold) }
    /// "Feed" title above the post list.
    static func feedBlockTitle() -> Font { sans(22, weight: .semibold) }
    static func headline() -> Font { sans(16, weight: .semibold) }
    /// Book profile section titles (Summary, Notable quote) — ~2× headline.
    static func profileSectionHeader() -> Font { sans(32, weight: .bold) }
    /// Long-form prose (book summaries, quotes, review captions, comments).
    static func body() -> Font { sans(17, weight: .regular) }
    static func callout() -> Font { sans(14, weight: .regular) }
    static func caption() -> Font { sans(12, weight: .regular) }

    /// Tracking applied to display type (wordmark headers, overline labels).
    static let displayTracking: CGFloat = 0.5
    /// Line spacing for body prose.
    static let bodyLineSpacing: CGFloat = 3

    /// Feed post and comment timestamps are always relative — never an exact date:
    /// seconds under a minute, minutes until 1 hr, hours until 24 hr, days until
    /// 1 week, then weeks, then months.
    static func feedRelativeTimestamp(_ date: Date, now: Date = Date()) -> String {
        commentRelativeTimestamp(date, now: now)
    }

    static func commentRelativeTimestamp(_ date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 {
            let s = Int(max(0, interval))
            if s < 1 { return "just now" }
            return "\(s) sec"
        }
        if interval < 3600 {
            let m = Int(interval / 60)
            return m == 1 ? "1 min" : "\(m) min"
        }
        if interval < 86400 {
            let h = Int(interval / 3600)
            return h == 1 ? "1 hr" : "\(h) hr"
        }
        let days = Int(interval / 86400)
        if days < 7 {
            return days == 1 ? "1 day" : "\(days) days"
        }
        if days < 60 {
            let w = max(1, days / 7)
            return w == 1 ? "1 week" : "\(w) weeks"
        }
        let months = max(2, days / 30)
        return "\(months) months"
    }

    // MARK: - Ratings (out of 10, one decimal — e.g. 8.8)
    static func formatRatingOutOfTen(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// Slider / form input → stored value (1.0…10.0, one decimal).
    static func normalizeRatingOutOfTen(_ value: Double) -> Double {
        let clamped = min(10, max(0, value))
        return (clamped * 10).rounded() / 10
    }

    /// "Jordan's Library" / "James' Library" from a person's display name.
    static func possessiveLibraryTitle(displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Library" }
        if trimmed.lowercased().hasSuffix("s") {
            return "\(trimmed)' Library"
        }
        return "\(trimmed)'s Library"
    }

    /// Same possessive rules, but uses first name only (`User.firstName`, else first word of `displayName`).
    static func possessiveLibraryTitleFirstNameOnly(user: User) -> String {
        let first: String
        if let fn = user.firstName?.trimmingCharacters(in: .whitespacesAndNewlines), !fn.isEmpty {
            first = fn
        } else {
            let trimmed = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(separator: " ").map(String.init)
            first = parts.first ?? trimmed
        }
        guard !first.isEmpty else { return "Library" }
        return possessiveLibraryTitle(displayName: first)
    }

    // MARK: - Gloss (liquid-glass depth — Apple TV icon treatment for filled controls)

    /// Mixes `color` toward `mix` by `fraction` (0–1). Resolves per trait
    /// collection so dynamic (light/dark) inputs blend correctly in both modes.
    static func blend(_ color: Color, toward mix: Color, by fraction: CGFloat) -> Color {
        blend(color, toward: mix, light: fraction, dark: fraction)
    }

    /// Trait-aware blend with separate light/dark fractions — used for surface
    /// sheens, where a white blend that reads as subtle on paper would blow out
    /// a dark surface.
    static func blend(_ color: Color, toward mix: Color, light lightFraction: CGFloat, dark darkFraction: CGFloat) -> Color {
        Color(UIColor { traits in
            let f = min(1, max(0, traits.userInterfaceStyle == .dark ? darkFraction : lightFraction))
            let c1 = UIColor(color).resolvedColor(with: traits)
            let c2 = UIColor(mix).resolvedColor(with: traits)
            var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
            var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
            c1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            c2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            return UIColor(
                red: r1 + (r2 - r1) * f,
                green: g1 + (g2 - g1) * f,
                blue: b1 + (b2 - b1) * f,
                alpha: a1 + (a2 - a1) * f
            )
        })
    }

    /// Top-lit gradient over a tint — drop-in wherever a flat `fill(tint)` used to be.
    static func gloss(_ tint: Color) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: blend(tint, toward: .white, by: 0.18), location: 0.0),
                .init(color: tint, location: 0.55),
                .init(color: blend(tint, toward: .black, by: 0.12), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Glossy accent — drop-in replacement for flat `Theme.accent` fills.
    static var accentGloss: LinearGradient { gloss(accent) }

    // MARK: - Layout
    static let cardCornerRadius: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let gridSpacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 20
    /// Approximate height of `MainTabView`'s custom tab bar (icons, labels, padding). Used to inset pushed views that don't inherit the parent's safe area.
    static let mainTabBarChromeHeight: CGFloat = 50
    /// Stroke width for ink "window" frames around hero surfaces.
    static let windowBorderWidth: CGFloat = 2
    /// Hairline width for inline chrome (dividers, list separators, card outlines).
    static let chromeHairline: CGFloat = 1
}

// MARK: - Appearance preference (Light / Dark / System)

/// User-selected appearance, persisted via `@AppStorage(AppearancePreference.storageKey)`
/// and applied at the app root with `.preferredColorScheme`. Defaults to
/// `.system`: new accounts pick explicitly on the onboarding wizard's appearance
/// step, and anyone who never picked follows their phone.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    static let storageKey = "appearancePreference"
    static let defaultValue: AppearancePreference = .system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    var iconName: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        case .system: return "circle.lefthalf.filled"
        }
    }

    /// `nil` means "follow the system setting".
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

// MARK: - Glyph helpers

enum SpinesGlyphs {
    /// Solid square — window close-button glyph (windowed-card chrome only).
    static let closeBox = "■"

    /// Uppercases a short status/overline label, e.g. `STATUS`.
    static func caps(_ s: String) -> String { s.uppercased() }
}

/// Short brand accent rule under wordmark headers.
struct BrandRule: View {
    var width: CGFloat = 44
    var color: Color = Theme.chrome

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: 3)
    }
}

// MARK: - Gloss modifiers & press feedback

/// Full liquid-gloss treatment for hero CTAs: top-lit gradient fill, inner top
/// highlight, and a soft drop shadow — Apple TV icon depth.
struct GlossyProminentStyle: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Theme.gloss(tint), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Theme.shadowInk.opacity(0.30), radius: 9, x: 0, y: 4)
            // The gloss fill lands outside the Button, so it can't make the capsule
            // tappable on its own — claim the frame so the whole CTA answers taps
            // even when the button doesn't use `.springPress`.
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

extension View {
    /// Hero-CTA gloss: gradient fill + inner highlight + soft ink shadow.
    func glossyProminent(_ tint: Color = Theme.accent, cornerRadius: CGFloat = Theme.cardCornerRadius) -> some View {
        modifier(GlossyProminentStyle(tint: tint, cornerRadius: cornerRadius))
    }
}

/// Press feedback for tappable chrome: quick scale-down on a soft spring — the
/// "buttons feel physical" half of the liquid-glass direction.
struct SpringPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // A custom ButtonStyle hit tests the label's *drawn* content, not its
            // layout frame: a `Text` sized with `.frame(maxWidth: .infinity)` and
            // `.padding()` only answers taps that land on the glyphs, and any fill
            // applied outside the Button (`.glossyProminent`, a `.background` on the
            // Button rather than the label) doesn't count. That leaves a wide CTA
            // dead everywhere but its words, which reads as "the button needs two
            // taps". Claiming the whole label frame here fixes every springPress
            // button at once.
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SpringPressButtonStyle {
    static var springPress: SpringPressButtonStyle { SpringPressButtonStyle() }
}

// MARK: - Card & window styles

/// Default card surface — paper background with a faint top sheen, subtle ink
/// hairline, soft shadow.
struct ThemeCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [Theme.blend(Theme.surface, toward: .white, light: 0.25, dark: 0.06), Theme.surface],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .stroke(Theme.chrome.opacity(0.22), lineWidth: Theme.chromeHairline)
            )
            .shadow(color: Theme.shadowInk.opacity(0.10), radius: 10, x: 0, y: 4)
    }
}

/// Spine "window" — solid-ink title bar with optional title text and a
/// close-box glyph; framed body. Use on hero surfaces (book profile sections,
/// modals) — too many on one screen reads as costume.
struct WindowedCardStyle<TitleAccessory: View>: ViewModifier {
    let title: String?
    let chromeColor: Color
    /// Optional trailing view in the title bar (e.g. a tier badge), before the close box.
    let titleAccessory: TitleAccessory
    /// When set, the close box becomes a tappable X that fires this action.
    var onClose: (() -> Void)? = nil

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if let title {
                HStack(spacing: 8) {
                    Text(title.uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(Theme.onChrome)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 10)
                    titleAccessory
                    if let onClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.onChrome)
                                // Keep the visual size of the old glyph but give the tap a 44pt-ish target.
                                .padding(.vertical, 6)
                                .padding(.leading, 12)
                                .padding(.trailing, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(SpinesGlyphs.closeBox)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.onChrome)
                            .padding(.trailing, 10)
                    }
                }
                .padding(.vertical, 6)
                .background(chromeColor)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceElevated)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(chromeColor, lineWidth: Theme.windowBorderWidth)
        )
        .shadow(color: Theme.shadowInk.opacity(0.10), radius: 8, x: 0, y: 3)
    }
}

/// Hinge-style profile section: airy rounded card with a small overline label
/// inside the card (no title bar), generous padding, and a soft shadow. Used for
/// book-profile sections; modals keep the `windowedCard` treatment.
struct HingeSectionCardStyle<TitleLeadingAccessory: View, TitleAccessory: View>: ViewModifier {
    let title: String?
    let accentColor: Color
    /// Optional view tucked right after the overline label (e.g. an edit pencil).
    let titleLeadingAccessory: TitleLeadingAccessory
    /// Optional trailing view beside the overline label (e.g. a tier badge).
    let titleAccessory: TitleAccessory

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 8) {
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.8)
                        .foregroundStyle(accentColor)
                    titleLeadingAccessory
                    Spacer(minLength: 0)
                    titleAccessory
                }
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [Theme.blend(Theme.surfaceElevated, toward: .white, light: 0.5, dark: 0.07), Theme.surfaceElevated],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(accentColor.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Theme.shadowInk.opacity(0.10), radius: 14, x: 0, y: 6)
    }
}

extension View {
    /// Plain Spine card (paper surface, hairline ink border).
    func wellReadCard() -> some View {
        modifier(ThemeCardStyle())
    }

    /// Hinge-style profile section card with an overline label.
    func hingeSectionCard(title: String?, accent: Color = Theme.chrome) -> some View {
        modifier(HingeSectionCardStyle(title: title, accentColor: accent, titleLeadingAccessory: EmptyView(), titleAccessory: EmptyView()))
    }

    /// Hinge-style section card with a trailing view beside the label (e.g. a tier badge).
    func hingeSectionCard<Accessory: View>(
        title: String?,
        accent: Color = Theme.chrome,
        @ViewBuilder titleAccessory: () -> Accessory
    ) -> some View {
        modifier(HingeSectionCardStyle(title: title, accentColor: accent, titleLeadingAccessory: EmptyView(), titleAccessory: titleAccessory()))
    }

    /// Hinge-style section card with a view tucked after the label (e.g. an edit
    /// pencil) plus the trailing accessory.
    func hingeSectionCard<Leading: View, Accessory: View>(
        title: String?,
        accent: Color = Theme.chrome,
        @ViewBuilder titleLeading: () -> Leading,
        @ViewBuilder titleAccessory: () -> Accessory
    ) -> some View {
        modifier(HingeSectionCardStyle(title: title, accentColor: accent, titleLeadingAccessory: titleLeading(), titleAccessory: titleAccessory()))
    }

    /// Spine card framed as a "window" with an optional solid-ink title bar.
    /// - Parameters:
    ///   - title: Title-bar text. Pass `nil` to render just an ink-bordered frame.
    ///   - chrome: Title-bar color. Defaults to ink chrome.
    ///   - onClose: When set, the title-bar close box becomes a tappable X.
    func windowedCard(title: String? = nil, chrome: Color = Theme.chrome, onClose: (() -> Void)? = nil) -> some View {
        modifier(WindowedCardStyle(title: title, chromeColor: chrome, titleAccessory: EmptyView(), onClose: onClose))
    }

    /// Windowed card with a trailing view in the title bar (e.g. a tier badge on the review card).
    func windowedCard<Accessory: View>(
        title: String?,
        chrome: Color = Theme.chrome,
        onClose: (() -> Void)? = nil,
        @ViewBuilder titleAccessory: () -> Accessory
    ) -> some View {
        modifier(WindowedCardStyle(title: title, chromeColor: chrome, titleAccessory: titleAccessory(), onClose: onClose))
    }
}

// MARK: - Main tab bar (custom)

private struct MainTabBarOverlapKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Extra bottom padding for views (e.g. book profile) when the tab bar doesn't inset them. With `.safeAreaInset(tabBar)` on `MainTabView`, use `0`—otherwise you double the gap.
    var mainTabBarOverlapExtraHeight: CGFloat {
        get { self[MainTabBarOverlapKey.self] }
        set { self[MainTabBarOverlapKey.self] = newValue }
    }
}

// MARK: - Shimmer loading placeholders

/// Skeleton placeholder: a paper surface with an ink band sweeping across,
/// masked to the given shape. Same visual language as the cover shimmer in
/// BookCoverView. Size skeletons to the content they stand in for so the
/// layout doesn't jump when the real content lands.
///
/// The repeatForever animation is scoped to `animate` (not applied via
/// `withAnimation` in onAppear) so it can't hijack sheet drag-dismiss tracking.
struct ShimmerShape<S: Shape>: View {
    let shape: S
    @State private var animate = false

    var body: some View {
        shape
            .fill(Theme.surface)
            .overlay(
                GeometryReader { geo in
                    let width = geo.size.width
                    let bandWidth = max(width * 0.6, 44)
                    let startX = -bandWidth
                    let endX = width + bandWidth
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: Theme.chrome.opacity(0.22), location: 0.5),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: bandWidth, height: geo.size.height)
                    .offset(x: animate ? endX - bandWidth / 2 : startX - bandWidth / 2)
                    .animation(
                        .linear(duration: 1.4).repeatForever(autoreverses: false),
                        value: animate
                    )
                }
            )
            .clipShape(shape)
            .onAppear { animate = true }
            .accessibilityHidden(true)
    }
}

/// One text-line-shaped shimmer bar. Width comes from the caller's frame.
struct ShimmerBar: View {
    var height: CGFloat = 13
    var cornerRadius: CGFloat = 5

    var body: some View {
        ShimmerShape(shape: RoundedRectangle(cornerRadius: cornerRadius))
            .frame(height: height)
    }
}

/// Circle shimmer for avatar placeholders.
struct ShimmerCircle: View {
    let size: CGFloat

    var body: some View {
        ShimmerShape(shape: Circle())
            .frame(width: size, height: size)
    }
}

/// Paragraph-shaped skeleton: full-width lines with a short last line, with
/// bar height + gaps matching Theme.body() line pitch (~25pt) so the block
/// occupies the same vertical space as the text it stands in for. Pick `lines`
/// from the content's known character budget (~43 chars per line at body size
/// on a section card).
struct ShimmerTextBlock: View {
    let lines: Int
    /// Points trimmed off the last line so the block ends mid-line like real text.
    var lastLineTrailingCut: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<lines, id: \.self) { index in
                ShimmerBar()
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, index == lines - 1 && lines > 1 ? lastLineTrailingCut : 0)
            }
        }
        .padding(.vertical, 4)
    }
}
