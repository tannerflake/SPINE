//
//  WizardFinaleSteps.swift
//  SPINE
//
//  Final beats of the onboarding wizard: the finished library card dealt onto
//  the table (WizardCardStep) and the founder's typed welcome letter
//  (WizardFounderNoteStep). Copy rule: no em-dashes in user-facing text.
//

import SwiftUI
import UIKit

// MARK: - Card step (the payoff)

struct WizardCardStep: View {
    @ObservedObject var model: OnboardingWizardModel
    @EnvironmentObject var authService: AuthService

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dealt = false
    @State private var appearedStamps: Set<Int> = []
    @State private var hasChoreographed = false
    @State private var isLive = true
    /// Camera-flash overlay opacity (spikes right after the card thunks down).
    @State private var flashOpacity: Double = 0
    /// Card № ticker; counts up to the real member number. Kept as a Double so
    /// SwiftUI interpolates it every frame (CardNumberLabel rounds for display).
    /// Stepping it with a chain of asyncAfter timers instead capped the tick
    /// rate at the step count and jittered on dispatch, which read as choppy.
    @State private var countUpValue: Double = 1

    /// Number ticker is mid-count; the card № gets visual emphasis while live.
    @State private var isCounting = false
    /// Avatar resolved to a UIImage for the downloadable card: ImageRenderer
    /// cannot wait on an async loader, so an unresolved URL would export as the
    /// monogram even though the card on screen shows the photo.
    @State private var resolvedPhoto: UIImage?

    // Stamp order: photo, name, handle, goal stamp, then the OG badge.
    private let photoStampIndex = 0
    private let nameStampIndex = 1
    private let handleStampIndex = 2
    private let goalStampIndex = 3
    private let ogStampIndex = 4

    // Choreography beats. The count-up is its own sequence after the goal
    // stamp so the member number gets a moment of its own, and the OG stamp
    // lands on the photo right after the number settles.
    private let goalBeat: Double = 3.3
    private var countUpBeat: Double { goalBeat + 0.7 }
    private let countUpDuration: Double = 2.0
    private var ogBeat: Double { countUpBeat + countUpDuration + 0.5 }
    private var captionBeat: Double { ogBeat + 0.7 }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                card
                    .offset(y: dealt ? 0 : 140)
                    .rotationEffect(.degrees(dealt ? -1 : 5))
                    .opacity(dealt ? 1 : 0)

                Text("Keep it safe. You might need it.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 26)
                    .wizardReveal(delay: captionBeat)

                // Secondary here: Next is the way forward, downloading is the
                // optional keepsake.
                LibraryCardDownloadButton(details: exportDetails, prominent: false, title: "Save my card", pulses: true)
                    .padding(.top, 18)
                    .wizardReveal(delay: captionBeat + 0.15)

                Spacer()

                WizardCTAButton(title: "Next") {
                    model.advance()
                }
                .wizardReveal(delay: captionBeat + 0.3)
            }
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 24)

            // The photo-booth flash. Never intercepts touches.
            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .onAppear(perform: runChoreography)
        .onDisappear { isLive = false }
        .task {
            guard model.localProfileImage == nil else { return }
            resolvedPhoto = await LibraryCardExporter.loadPhoto(urlString: authService.appUser?.profileImageURL)
        }
    }

    /// What the downloaded image prints. Mirrors the stamped card above.
    private var exportDetails: LibraryCardDetails {
        let name = "\(model.firstName) \(model.lastName)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LibraryCardDetails(
            name: name.isEmpty ? model.displayFirstName : name,
            handle: model.normalizedHandle,
            cardNumber: model.cardNumber,
            memberSinceText: model.memberSinceText,
            goalText: model.goalYearText,
            photo: model.localProfileImage ?? resolvedPhoto,
            monogramInitial: String(model.displayFirstName.prefix(1)),
            isOGEligible: model.isOGEligible
        )
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Rectangle()
                .fill(Theme.textPrimary)
                .frame(height: 2)
            identityRow
            goalStampRow
            Rectangle()
                .fill(Theme.textPrimary.opacity(0.18))
                .frame(height: 1)
            footer
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Theme.surfaceElevated)
                .overlay(cardWatermark)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Theme.textPrimary, lineWidth: 2)
        )
        .shadow(color: Theme.shadowInk.opacity(0.22), radius: 20, y: 12)
    }

    /// The soft SPINE seal behind everything, like an embossed watermark on a
    /// real library card. Faint enough that the stamps stay legible over it.
    private var cardWatermark: some View {
        Image("SpineLogo")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 220)
            .foregroundStyle(Theme.textPrimary.opacity(0.05))
            .rotationEffect(.degrees(-10))
            .offset(x: 60, y: 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("SPINE")
                .font(.system(size: 15, weight: .heavy))
                .tracking(4)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            CardNumberLabel(value: countUpValue)
                .foregroundStyle(isCounting ? Theme.textPrimary : Theme.textTertiary)
                .scaleEffect(isCounting ? 1.35 : 1, anchor: .trailing)
        }
    }

    /// Rounds a continuously animated Double for display. Conforming to
    /// Animatable is what makes the count-up run at the display refresh rate:
    /// SwiftUI drives animatableData every frame, so the digits advance
    /// smoothly instead of in however many discrete jumps a timer managed.
    /// monospacedDigit keeps the glyphs from reflowing as the value climbs.
    private struct CardNumberLabel: View, Animatable {
        var value: Double

        var animatableData: Double {
            get { value }
            set { value = newValue }
        }

        var body: some View {
            Text("CARD № \(max(1, Int(value.rounded())))")
                .font(.system(size: 10.5, weight: .bold))
                .monospacedDigit()
                .tracking(1.4)
        }
    }

    /// Red is reserved for danger everywhere else in the app; here it's ink
    /// from a real rubber stamp, which is the one place it belongs.
    private var ogStamp: some View {
        Text("OG")
            .font(.system(size: 13, weight: .heavy))
            .tracking(1.8)
            .foregroundStyle(Theme.danger)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.danger, lineWidth: 1.8)
            )
            .accessibilityLabel("Original member")
    }

    private var identityRow: some View {
        HStack(spacing: 16) {
            ZStack {
                Color.clear.frame(width: 66, height: 66)
                if appearedStamps.contains(photoStampIndex) {
                    photoCircle
                        .wizardStamp(restRotation: -2)
                }
            }
            // The OG stamp presses onto the corner of the photo itself,
            // overhanging like it was inked on after the picture was taken.
            .overlay(alignment: .topLeading) {
                if appearedStamps.contains(ogStampIndex) {
                    ogStamp
                        .wizardStamp(restRotation: -14)
                        .offset(x: -12, y: -9)
                }
            }
            .zIndex(1)
            VStack(alignment: .leading, spacing: 3) {
                stamped(nameText, index: nameStampIndex, restRotation: 1.2)
                stamped(handleText, index: handleStampIndex, restRotation: -1.4)
            }
            Spacer(minLength: 0)
        }
    }

    private var nameText: some View {
        Text("\(model.firstName) \(model.lastName)".trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.system(size: 21, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
    }

    private var handleText: some View {
        Text("@\(model.normalizedHandle)")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
    }

    /// Reserves the final layout with an invisible copy so the card doesn't
    /// resize as each stamp lands.
    private func stamped(_ content: some View, index: Int, restRotation: Double) -> some View {
        ZStack(alignment: .leading) {
            content.opacity(0)
            if appearedStamps.contains(index) {
                content.wizardStamp(restRotation: restRotation)
            }
        }
    }

    private var photoCircle: some View {
        Group {
            if let image = model.localProfileImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                CachedProfileImage(
                    url: URL(string: authService.appUser?.profileImageURL ?? ""),
                    contentMode: .fill
                ) {
                    monogram
                }
            }
        }
        .frame(width: 66, height: 66)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Theme.textPrimary, lineWidth: 2)
        )
    }

    private var monogram: some View {
        InitialsAvatarView(
            displayName: nil,
            firstName: model.displayFirstName,
            lastName: model.lastName,
            size: 66
        )
    }

    /// The reading goal is the card's one stamp: pressed on slightly tilted,
    /// like the librarian inked it after filling in the identity fields.
    private var goalStampRow: some View {
        HStack {
            if appearedStamps.contains(goalStampIndex) {
                goalStamp
                    .wizardStamp(restRotation: -1.8)
            }
        }
        .frame(minHeight: 30, alignment: .leading)
    }

    private var goalStamp: some View {
        Text(model.goalYearText)
            .font(.system(size: 12, weight: .heavy))
            .tracking(1.4)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Theme.textPrimary, lineWidth: 1.5)
            )
    }

    private var footer: some View {
        HStack {
            Text("MEMBER SINCE \(model.memberSinceText)")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
        }
        .frame(minHeight: 16)
    }

    // MARK: Choreography

    /// Deal the card in, thunk it down, fire the photo-booth flash, then press
    /// each stamp on in sequence while the card № ticks up.
    private func runChoreography() {
        guard !hasChoreographed else { return }
        hasChoreographed = true

        let isOGEligible = model.isOGEligible

        if reduceMotion {
            dealt = true
            appearedStamps = isOGEligible ? Set(0...ogStampIndex) : Set(0..<ogStampIndex)
            countUpValue = Double(model.cardNumber)
            return
        }

        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
            dealt = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard isLive else { return }
            let g = UIImpactFeedbackGenerator(style: .medium)
            g.prepare()
            g.impactOccurred(intensity: 1.0)
            // Flash pops instantly, decays like a real bulb.
            flashOpacity = 0.85
            withAnimation(.easeOut(duration: 0.45)) {
                flashOpacity = 0
            }
        }

        stampIn(photoStampIndex, at: 1.5)
        stampIn(nameStampIndex, at: 2.1)
        stampIn(handleStampIndex, at: 2.5)
        stampIn(goalStampIndex, at: goalBeat)
        runCountUp(after: countUpBeat, duration: countUpDuration)
        if isOGEligible {
            stampIn(ogStampIndex, at: ogBeat, heavy: true)
        }
    }

    private func stampIn(_ index: Int, at delay: Double, heavy: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // The step can be torn down mid-choreography; no ghost haptics.
            guard isLive else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                _ = appearedStamps.insert(index)
            }
            let g = UIImpactFeedbackGenerator(style: heavy ? .medium : .light)
            g.prepare()
            g.impactOccurred(intensity: 1.0)
        }
    }

    /// The member number's own beat: the card № swells, ease-out ticks from 1
    /// up to the real number, then settles back down right before the OG
    /// stamp lands.
    private func runCountUp(after delay: Double, duration: Double) {
        let target = max(1, model.cardNumber)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard isLive else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                isCounting = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard isLive else { return }
            // Cubic ease-out, matching the old hand-rolled curve: quick out of
            // the gate, long settle onto the final number.
            withAnimation(.timingCurve(0.215, 0.61, 0.355, 1, duration: duration)) {
                countUpValue = Double(target)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + duration + 0.25) {
            guard isLive else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                isCounting = false
            }
            let g = UIImpactFeedbackGenerator(style: .light)
            g.prepare()
            g.impactOccurred(intensity: 1.0)
        }
    }
}

// MARK: - Founder note step

struct WizardFounderNoteStep: View {
    @ObservedObject var model: OnboardingWizardModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// teaser ("Pssssst...") → folded note slides in → tap → unfolded letter.
    private enum Phase { case teaser, folded, unfolded }
    @State private var phase: Phase = .teaser
    @State private var teaserHeadlineDone = false
    @State private var noteUnfolded = false
    @State private var typingDone = false
    @State private var fastForward = 0

    private static let noteText = """
Thanks for being here early!

I'm adding new features weekly.

I love feedback. Tell me what you love, what you hate, and what features you'd like me to build.

Sharing ideas, learning, and reading are the core of my passion for life. This project means a lot to me.

I hope SPINE helps you share what inspires you.

I'm glad you're here.

-Tanner
"""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            ZStack {
                switch phase {
                case .teaser:
                    teaser
                        .transition(.opacity)
                case .folded:
                    foldedNote
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                case .unfolded:
                    letter
                        .overlay(alignment: .topTrailing) {
                            polaroid
                                .offset(x: 18, y: -64)
                        }
                        .scaleEffect(x: 1, y: noteUnfolded || reduceMotion ? 1 : 0.16, anchor: .top)
                        .opacity(noteUnfolded || reduceMotion ? 1 : 0.9)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 40)

            Spacer()

            WizardCTAButton(title: "I'm glad to be here!") {
                model.markFounderNoteSeen()
                model.advance()
            }
            .opacity(typingDone ? 1 : 0)
            .allowsHitTesting(typingDone)
            .animation(.easeOut(duration: 0.4), value: typingDone)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .contentShape(Rectangle())
        .onTapGesture(perform: handleTap)
    }

    private func handleTap() {
        switch phase {
        case .teaser:
            fastForward += 1
        case .folded:
            openNote()
        case .unfolded:
            fastForward += 1
        }
    }

    // MARK: Teaser

    private var teaser: some View {
        VStack(spacing: 14) {
            TypewriterText(
                text: "Pssssst...",
                font: .system(size: 32, weight: .bold),
                centered: true,
                fastForwardTrigger: fastForward,
                onFinished: { teaserHeadlineDone = true }
            )
            TypewriterText(
                text: "There's a note for you.",
                font: .system(size: 16),
                textColor: Theme.textSecondary,
                centered: true,
                startDelay: 0.7,
                isActive: teaserHeadlineDone,
                fastForwardTrigger: fastForward,
                onFinished: slideNoteIn
            )
        }
        .padding(.horizontal, 6)
    }

    /// The teaser needs to breathe: the note slides in only after the line
    /// has sat on screen for a beat, not the instant the typing finishes.
    private func slideNoteIn() {
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.2 : 1.5)) {
            guard phase == .teaser else { return }
            WizardHaptics.step()
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                phase = .folded
            }
        }
    }

    // MARK: Folded note

    private var foldedNote: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surfaceElevated)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.textPrimary.opacity(0.16), lineWidth: 1)
                // The fold line across the middle.
                Rectangle()
                    .fill(Theme.textPrimary.opacity(0.12))
                    .frame(height: 1.5)
                Text("for \(model.displayFirstName)")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 14)
                    .offset(y: -26)
            }
            .frame(width: 210, height: 132)
            .shadow(color: Theme.shadowInk.opacity(0.2), radius: 12, y: 8)
            .rotationEffect(.degrees(-2.5))

            Text("tap to open")
                .font(.system(size: 12, weight: .semibold))
                .tracking(2.4)
                .textCase(.uppercase)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func openNote() {
        WizardHaptics.step()
        withAnimation(.easeOut(duration: 0.18)) {
            phase = .unfolded
        }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.05)) {
            noteUnfolded = true
        }
    }

    // MARK: Letter

    private var letter: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A NOTE FROM THE FOUNDER")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(Theme.textTertiary)

            TypewrittenNote(
                text: Self.noteText,
                isActive: noteUnfolded || reduceMotion,
                fastForwardTrigger: fastForward,
                onFinished: { typingDone = true }
            )
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.surfaceElevated)
        )
        // Creases where the note was folded in thirds.
        .overlay(
            VStack(spacing: 0) {
                Spacer()
                creaseLine
                Spacer()
                creaseLine
                Spacer()
            }
            .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.textPrimary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Theme.shadowInk.opacity(0.16), radius: 16, y: 10)
    }

    private var creaseLine: some View {
        Rectangle()
            .fill(Theme.textPrimary.opacity(0.07))
            .frame(height: 1)
    }

    /// Small photo accent tucked over the letter's corner, not a hero image.
    private var polaroid: some View {
        Image("founder-note-photo")
            .resizable()
            .scaledToFill()
            .frame(width: 58, height: 67)
            .clipped()
            .padding(.top, 4)
            .padding(.horizontal, 4)
            .padding(.bottom, 14)
            .background(Color.white)
            .shadow(color: Theme.shadowInk.opacity(0.3), radius: 10, y: 6)
            .rotationEffect(.degrees(6))
    }
}

/// Character-by-character reveal in a monospaced face, like the note is being
/// typed while you watch. Deliberately slower than the word-reveal used
/// elsewhere in the wizard.
///
/// The whole note is always laid out; only the not-yet-typed characters are
/// drawn clear. That keeps the letter from growing line by line AND fixes the
/// line breaks up front: revealing a prefix of a real string made a word type
/// itself out on one row and then hop to the next the moment it no longer fit.
private struct TypewrittenNote: View {
    let text: String
    var isActive: Bool
    var fastForwardTrigger: Int
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownCount = 0
    @State private var didFinish = false

    var body: some View {
        noteText(revealed)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .task(id: isActive) {
                guard isActive else { return }
                await type()
            }
            .onChange(of: fastForwardTrigger) { _, _ in
                guard isActive else { return }
                shownCount = text.count
                fireFinished()
            }
    }

    /// Full note, with everything past `shownCount` painted clear.
    private var revealed: AttributedString {
        var string = AttributedString(text)
        string.foregroundColor = Theme.textPrimary
        let cutoff = string.characters.index(
            string.startIndex,
            offsetBy: min(shownCount, text.count)
        )
        if cutoff < string.endIndex {
            string[cutoff...].foregroundColor = .clear
        }
        return string
    }

    private func noteText(_ string: AttributedString) -> some View {
        Text(string)
            .font(.system(size: 14.5, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func type() async {
        if reduceMotion {
            shownCount = text.count
            fireFinished()
            return
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        let characters = Array(text)
        while shownCount < characters.count {
            guard !Task.isCancelled else { return }
            let character = characters[shownCount]
            shownCount += 1
            var delay = 0.024
            if ".!?".contains(character) { delay += 0.22 }
            else if character == "\n" { delay += 0.10 }
            else if ",".contains(character) { delay += 0.08 }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        fireFinished()
    }

    private func fireFinished() {
        guard !didFinish else { return }
        didFinish = true
        onFinished()
    }
}
