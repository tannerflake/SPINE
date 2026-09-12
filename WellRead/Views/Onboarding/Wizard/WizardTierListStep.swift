//
//  WizardTierListStep.swift
//  WellRead
//
//  "How tiers work" explainer, shown between the founder note and the
//  Goodreads import. It answers the single most common new-member question
//  ("what does S mean?") with a live tier list instead of a paragraph.
//  Three scenes, one tap each: the empty list assembles, S steps forward
//  with its origin story, then the ladder walks down the alphabet with
//  books (each wearing the face you'd make reading it) dropping onto every
//  shelf. Copy rule: no em-dashes.
//
//  DEBUG: -uiPreviewOnboardingWizard -uiPreviewWizardTiers jumps straight here.
//

import SwiftUI

struct WizardTierListStep: View {
    @ObservedObject var model: OnboardingWizardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Scene: Int { case assemble, meetS, ladder }

    @State private var scene: Scene = .assemble
    /// Rows that have thunked into place (assemble scene).
    @State private var landedRows = 0
    /// Demo books shown in S (meet-S scene).
    @State private var sBooksShown = 0
    /// Highest ladder index lit so far; 0 = S only (ladder scene).
    @State private var litLadderIndex = 0
    /// True once the current scene's choreography has finished (a tap then
    /// continues; before that a tap fast-forwards).
    @State private var sceneSettled = false
    @State private var hintPulsing = false
    /// Bumped on every scene change or fast-forward so stale timers from the
    /// previous choreography can't fire into the new scene.
    @State private var generation = 0

    private let tiers = spineTierLabels
    private static let copyHeight: CGFloat = 150
    private static let footerHeight: CGFloat = 52
    private static let rowSpacing: CGFloat = 6
    private static let letterWidth: CGFloat = 38
    /// Cover proportions relative to the height of the row it sits in, so
    /// books grow with the S shelf when it steps forward.
    private static func bookHeight(rowHeight: CGFloat) -> CGFloat { (rowHeight * 0.72).rounded() }
    private static func bookWidth(rowHeight: CGFloat) -> CGFloat { (rowHeight * 0.5).rounded() }
    /// The face you'd make reading a book on each shelf. Palette-hued
    /// jackets, no titles: a real title on the F shelf would be a dunk.
    private static let demoFaces: [String: [String]] = [
        "S": ["🤩", "🤯", "😍"],
        "A": ["😁", "😮", "😊"],
        "B": ["🙂", "😌"],
        "C": ["😐", "🥱"],
        "D": ["😒", "🙄"],
        "F": ["😡", "🤢", "😖"],
    ]

    var body: some View {
        GeometryReader { geo in
            let rowBase = Self.rowBase(forHeight: geo.size.height)
            VStack(alignment: .leading, spacing: 0) {
                copyBlock
                    .frame(height: Self.copyHeight, alignment: .topLeading)
                    .clipped()

                tierList(rowBase: rowBase)

                Spacer(minLength: 12)

                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 24)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: handleTap)
        .onAppear { enter(.assemble) }
    }

    /// Rows stretch to fill the phone (the list is the whole show) but stay
    /// small enough that the CTA never leaves a small screen.
    private static func rowBase(forHeight height: CGFloat) -> CGFloat {
        let fixed = copyHeight + footerHeight + 12 + 10 + 24
        let perRow = (height - fixed) / CGFloat(spineTierLabels.count) - rowSpacing
        return min(68, max(44, perRow))
    }

    // MARK: Copy

    private var headline: String {
        switch scene {
        case .assemble: return "Your profile is a tier list."
        case .meetS: return "S is the top."
        case .ladder: return "Then it walks down the alphabet."
        }
    }

    /// nil = headline only.
    private var subline: String? {
        switch scene {
        case .assemble:
            return "Every time you finish a book, you'll rank it on one of these tiers."
        case .meetS:
            return "S stands for Superior.\nYour all-time favorites go here."
        case .ladder:
            return "The lower the tier, the less you liked it."
        }
    }

    private var copyBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            TypewriterText(
                text: headline,
                font: .system(size: 28, weight: .bold),
                centered: false
            )
            if let subline {
                Text(subline)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .wizardReveal(delay: 0.45)
            }
        }
        .id(scene)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)),
            removal: .opacity
        ))
    }

    // MARK: Tier list

    private func tierList(rowBase: CGFloat) -> some View {
        VStack(spacing: Self.rowSpacing) {
            ForEach(Array(tiers.enumerated()), id: \.element) { index, tier in
                tierRow(tier, index: index, rowBase: rowBase)
            }
        }
    }

    private func rowHeight(_ tier: String, rowBase: CGFloat) -> CGFloat {
        guard scene == .meetS else { return rowBase }
        return tier == "S" ? (rowBase * 1.7).rounded() : (rowBase * 0.76).rounded()
    }

    private func rowOpacity(_ tier: String, index: Int) -> Double {
        switch scene {
        case .assemble: return index < landedRows ? 1 : 0
        case .meetS: return tier == "S" ? 1 : 0.4
        case .ladder: return index <= litLadderIndex ? 1 : 0.4
        }
    }

    private func visibleBooks(_ tier: String) -> Int {
        let full = Self.demoFaces[tier]?.count ?? 0
        switch scene {
        case .assemble: return 0
        case .meetS: return tier == "S" ? min(sBooksShown, full) : 0
        case .ladder:
            guard let idx = tiers.firstIndex(of: tier) else { return 0 }
            return idx <= litLadderIndex ? full : 0
        }
    }

    private func isSpotlit(_ tier: String, index: Int) -> Bool {
        switch scene {
        case .meetS: return tier == "S"
        case .ladder: return index == litLadderIndex && index > 0 && !sceneSettled
        default: return false
        }
    }

    private func tierRow(_ tier: String, index: Int, rowBase: CGFloat) -> some View {
        let height = rowHeight(tier, rowBase: rowBase)
        let landed = scene != .assemble || index < landedRows
        let spotlit = isSpotlit(tier, index: index)
        let faces = Self.demoFaces[tier] ?? []
        return HStack(spacing: 0) {
            ZStack {
                spineTierColor(for: tier)
                VStack(spacing: 0) {
                    Text(tier)
                        .font(.system(size: tier == "S" && scene == .meetS ? 30 : 16, weight: .semibold))
                        .lineLimit(1)
                    Text("Tier")
                        .font(.system(size: 8, weight: .medium))
                        .opacity(0.7)
                }
                .foregroundStyle(Color.black.opacity(0.75))
            }
            .frame(width: Self.letterWidth)
            .scaleEffect(spotlit && scene == .ladder ? 1.1 : 1)

            HStack(spacing: 7) {
                ForEach(0..<visibleBooks(tier), id: \.self) { i in
                    demoCover(tier: tier, index: i, face: faces[i], rowHeight: height)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.5).combined(with: .offset(y: -34)).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(Theme.surface.opacity(0.6))
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .stroke(Theme.textPrimary.opacity(spotlit ? 0.5 : 0), lineWidth: 1.5)
        )
        .shadow(color: Theme.shadowInk.opacity(spotlit ? 0.16 : 0), radius: 10, x: 0, y: 6)
        .opacity(rowOpacity(tier, index: index))
        .scaleEffect(landed ? 1 : 1.06)
        .offset(y: landed ? 0 : -18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tier) tier")
    }

    /// Faceless jacket in one of the 12 cover hues (seeded so a shelf gets the
    /// same colors every run) wearing the reaction it earned.
    private func demoCover(tier: String, index: Int, face: String, rowHeight: CGFloat) -> some View {
        let width = Self.bookWidth(rowHeight: rowHeight)
        let height = Self.bookHeight(rowHeight: rowHeight)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.coverPaletteColor(for: "wizard-tier-\(tier)-\(index)"))
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.22)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 2)
                .padding(.leading, 3)
            Text(face)
                .font(.system(size: width * 0.62))
                .frame(maxWidth: .infinity)
                .padding(.leading, 3)
        }
        .frame(width: width, height: height)
        .shadow(color: Theme.shadowInk.opacity(0.18), radius: 3, x: 0, y: 2)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        ZStack {
            if scene == .ladder {
                WizardCTAButton(title: "Got it") {
                    model.advance()
                }
                .opacity(sceneSettled ? 1 : 0)
                .offset(y: sceneSettled ? 0 : 12)
                .allowsHitTesting(sceneSettled)
                .accessibilityHidden(!sceneSettled)
            } else {
                Text("tap to continue")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(2.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .opacity(sceneSettled ? (hintPulsing && !reduceMotion ? 0.4 : 0.9) : 0)
                    .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true), value: hintPulsing)
            }
        }
        .frame(height: Self.footerHeight)
    }

    // MARK: Choreography

    private func handleTap() {
        guard sceneSettled else {
            fastForward()
            return
        }
        // The last scene continues with its CTA, not a background tap.
        guard let next = Scene(rawValue: scene.rawValue + 1) else { return }
        WizardHaptics.step()
        enter(next)
    }

    /// Runs `body` after `delay` unless the scene has moved on since.
    private func after(_ delay: Double, _ gen: Int, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.02 : delay)) {
            guard generation == gen else { return }
            body()
        }
    }

    private func animate(_ animation: Animation, _ body: () -> Void) {
        withAnimation(reduceMotion ? nil : animation, body)
    }

    private func settle(_ gen: Int) {
        guard generation == gen else { return }
        animate(.spring(response: 0.4, dampingFraction: 0.8)) {
            sceneSettled = true
        }
        hintPulsing = true
    }

    private func enter(_ next: Scene) {
        generation += 1
        let gen = generation
        sceneSettled = false
        hintPulsing = false
        animate(.spring(response: 0.45, dampingFraction: 0.82)) {
            scene = next
        }
        switch next {
        case .assemble:
            for i in 0..<tiers.count {
                after(0.5 + Double(i) * 0.14, gen) {
                    animate(.spring(response: 0.38, dampingFraction: 0.66)) { landedRows = i + 1 }
                    WizardHaptics.selection()
                }
            }
            after(0.5 + Double(tiers.count) * 0.14 + 0.35, gen) { settle(gen) }

        case .meetS:
            let full = Self.demoFaces["S"]?.count ?? 0
            for i in 0..<full {
                after(1.1 + Double(i) * 0.24, gen) {
                    animate(.spring(response: 0.42, dampingFraction: 0.62)) { sBooksShown = i + 1 }
                    WizardHaptics.selection()
                }
            }
            after(1.1 + Double(full) * 0.24 + 0.25, gen) {
                WizardHaptics.success()
                settle(gen)
            }

        case .ladder:
            // S is already lit; A through F light in turn, books landing on each.
            for idx in 1..<tiers.count {
                after(0.7 + Double(idx - 1) * 0.55, gen) {
                    animate(.spring(response: 0.42, dampingFraction: 0.66)) { litLadderIndex = idx }
                    WizardHaptics.selection()
                }
            }
            after(0.7 + Double(tiers.count - 1) * 0.55 + 0.4, gen) { settle(gen) }
        }
    }

    /// A tap mid-choreography jumps to the scene's finished state.
    private func fastForward() {
        generation += 1
        animate(.spring(response: 0.3, dampingFraction: 0.8)) {
            landedRows = tiers.count
            if scene.rawValue >= Scene.meetS.rawValue { sBooksShown = Self.demoFaces["S"]?.count ?? 0 }
            if scene.rawValue >= Scene.ladder.rawValue { litLadderIndex = tiers.count - 1 }
        }
        settle(generation)
    }
}
