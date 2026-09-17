//
//  WizardTasteStep.swift
//  SPINE
//
//  Taste steps of the onboarding wizard. First the characteristics step (flat
//  "type of book" chips: pacing, format, reading experience; pick five), then
//  the genre step: two-tier progressive disclosure over the Tags.csv catalog.
//  Genre roots open curated child chips; picks feed the taste meter and end
//  the identity block with the single commitProfile() write before the wizard
//  advances. Both steps write into the same selectedTags set; each gates on
//  its own vocabulary. Copy rule: no em-dashes.
//

import SwiftUI

// MARK: - Characteristics step

struct WizardCharacteristicsStep: View {
    @ObservedObject var model: OnboardingWizardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TypewriterText(
                text: "How do you like your books?",
                font: .system(size: 28, weight: .bold),
                centered: false
            )

            Text("This helps us recommend books you'll love.")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 10)
                .wizardReveal(delay: 0.2)

            ScrollView {
                FlowLayout(spacing: 9) {
                    ForEach(OnboardingWizardModel.characteristicTags, id: \.self) { tag in
                        chip(tag)
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 12)
                .animation(
                    reduceMotion ? nil : Animation.spring(response: 0.38, dampingFraction: 0.8),
                    value: model.selectedTags
                )
            }
            .padding(.top, 18)
            .wizardReveal(delay: 0.3)

            VStack(spacing: 10) {
                Text(counterText)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                meter

                WizardCTAButton(title: "Continue", enabled: model.canSubmitCharacteristics) {
                    model.advance()
                }
            }
            .padding(.top, 12)
            .wizardReveal(delay: 0.3)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 24)
    }

    private func chip(_ tag: String) -> some View {
        let isSelected = model.selectedTags.contains(tag)
        return Button {
            WizardHaptics.selection()
            if isSelected {
                model.selectedTags.remove(tag)
            } else {
                model.selectedTags.insert(tag)
            }
        } label: {
            Text(tag)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.onChrome : Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(isSelected ? Theme.textPrimary : Theme.surfaceElevated)
                )
                .overlay(
                    Capsule().strokeBorder(Theme.textPrimary.opacity(isSelected ? 0 : 0.15), lineWidth: 1.5)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var counterText: String {
        let n = model.characteristicPickCount
        if n == 0 { return "Pick at least five." }
        if n < 5 { return "\(n) picked. \(5 - n) to go." }
        if n < 8 { return "\(n) picked. We're taking notes." }
        return "\(n) picked. Epic."
    }

    private var meter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.textPrimary.opacity(0.12))
                Capsule()
                    .fill(Theme.textPrimary)
                    .frame(width: geo.size.width * min(1, CGFloat(model.characteristicPickCount) / 5))
            }
        }
        .frame(height: 5)
        .animation(
            reduceMotion ? nil : Animation.spring(response: 0.45, dampingFraction: 0.8),
            value: model.characteristicPickCount
        )
        .accessibilityHidden(true)
    }
}

// MARK: - Genre taste step

struct WizardTasteStep: View {
    @ObservedObject var model: OnboardingWizardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Frames of each root section (row plus its expanded children), measured in
    /// the scroll viewport's coordinate space, so a section that sits below the
    /// fold reads maxY greater than the viewport height.
    @State private var sectionFrames: [String: CGRect] = [:]
    @State private var viewportHeight: CGFloat = 0

    private static let scrollSpace = "wizardTasteScroll"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TypewriterText(
                text: "What do you reach for?",
                font: .system(size: 28, weight: .bold),
                centered: false
            )

            Text("These picks help us recommend books you'll love.")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 10)
                .wizardReveal(delay: 0.2)

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(OnboardingWizardModel.tasteTree, id: \.root) { entry in
                            rootSection(root: entry.root, children: entry.children, scrollProxy: scrollProxy)
                        }
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                    .animation(
                        reduceMotion ? nil : Animation.spring(response: 0.38, dampingFraction: 0.8),
                        value: model.selectedTags
                    )
                }
                .coordinateSpace(.named(Self.scrollSpace))
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    viewportHeight = height
                }
            }
            .padding(.top, 18)
            .wizardReveal(delay: 0.3)

            VStack(spacing: 10) {
                Text(counterText)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                tasteMeter

                if let commitError = model.commitError {
                    Text(commitError)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                WizardCTAButton(
                    title: "Continue",
                    enabled: model.canSubmitTaste,
                    showsProgress: model.isCommittingProfile
                ) {
                    Task {
                        if await model.commitProfile() {
                            model.advance()
                        }
                    }
                }
            }
            .padding(.top, 12)
            .wizardReveal(delay: 0.3)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 24)
    }

    // MARK: - Root rows

    @ViewBuilder
    private func rootSection(root: String, children: [String], scrollProxy: ScrollViewProxy) -> some View {
        let isSelected = model.selectedTags.contains(root)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                toggleRoot(root, children: children, scrollProxy: scrollProxy)
            } label: {
                HStack {
                    Text(root)
                        .font(.system(size: 15.5, weight: .semibold))
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                    }
                }
                .foregroundStyle(isSelected ? Theme.onChrome : Theme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isSelected ? Theme.textPrimary : Theme.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Theme.textPrimary.opacity(isSelected ? 0 : 0.15), lineWidth: 1.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            if isSelected {
                childrenBlock(children: children)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .id(root)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.scrollSpace))
        } action: { frame in
            sectionFrames[root] = frame
        }
    }

    // MARK: - Child chips

    private func childrenBlock(children: [String]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(children, id: \.self) { child in
                childChip(child)
            }
        }
        .padding(.leading, 14)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.textPrimary.opacity(0.12))
                .frame(width: 2)
        }
    }

    private func childChip(_ tag: String) -> some View {
        let isSelected = model.selectedTags.contains(tag)
        return Button {
            WizardHaptics.selection()
            if isSelected {
                model.selectedTags.remove(tag)
            } else {
                model.selectedTags.insert(tag)
            }
        } label: {
            Text(tag)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.onChrome : Theme.textPrimary)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isSelected ? Theme.textPrimary : Color.clear)
                )
                .overlay(
                    Capsule().strokeBorder(
                        Theme.textPrimary.opacity(isSelected ? 0 : 0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selection

    private func toggleRoot(_ root: String, children: [String], scrollProxy: ScrollViewProxy) {
        WizardHaptics.selection()
        if model.selectedTags.contains(root) {
            model.selectedTags.remove(root)
            for child in children {
                model.selectedTags.remove(child)
            }
        } else {
            model.selectedTags.insert(root)
            revealChildren(of: root, scrollProxy: scrollProxy)
        }
    }

    /// After a root expands, pull the new subgenre chips into view if any of them
    /// landed below the fold. If the expansion already fits on screen, leave the
    /// scroll position exactly where the user put it.
    private func revealChildren(of root: String, scrollProxy: ScrollViewProxy) {
        let settleDelay = reduceMotion ? 0.05 : 0.42
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
            guard viewportHeight > 0,
                  model.selectedTags.contains(root),
                  let frame = sectionFrames[root] else { return }

            let slack: CGFloat = 8
            let fits = frame.height <= viewportHeight - slack
            let anchor: UnitPoint
            if frame.maxY > viewportHeight - slack {
                // Chips ran off the bottom. Sections shorter than the viewport can sit
                // flush with its bottom edge; taller ones put their header at the top
                // so the chips fill the screen.
                anchor = fits ? .bottom : .top
            } else if frame.minY < slack {
                // Expanding pushed the row (and its first chip row) off the top.
                anchor = .top
            } else {
                // The chips already landed on screen: leave the scroll position alone.
                return
            }
            withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9)) {
                scrollProxy.scrollTo(root, anchor: anchor)
            }
        }
    }

    // MARK: - Counter + meter

    private var counterText: String {
        let n = model.tastePickCount
        if n == 0 { return "Pick at least two." }
        if n == 1 { return "One more…" }
        if n < 5 { return "\(n) picked. Keep going for sharper picks." }
        if n < 8 { return "\(n) picked. Dialing it in." }
        return "\(n) picked. We'll have great recs for you."
    }

    private var tasteMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.textPrimary.opacity(0.12))
                Capsule()
                    .fill(Theme.textPrimary)
                    .frame(width: geo.size.width * meterFraction)
            }
        }
        .frame(height: 5)
        .animation(
            reduceMotion ? nil : Animation.spring(response: 0.45, dampingFraction: 0.8),
            value: model.tastePickCount
        )
        .accessibilityHidden(true)
    }

    private var meterFraction: CGFloat {
        min(1, CGFloat(model.tastePickCount) / 8)
    }
}
