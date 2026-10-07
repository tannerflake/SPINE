//
//  AchievementUnlockedModal.swift
//  SPINE
//
//  The celebration when a stamp is earned. The stamp hovers over the paper
//  and wiggles like it is being lined up, then slams down: the paper squashes,
//  an ink shockwave rings out, paper confetti bursts from the impact, and a
//  red NEW STAMP badge thunks onto the corner. "Stamp my card" hands it to
//  the stamping screen; swiping the sheet away leaves it waiting in the bank
//  on the card page. Reduce Motion gets a plain fade. Copy rule: no em-dashes in
//  user-facing text.
//

import SwiftUI

struct AchievementUnlockedModal: View {
    let kind: AchievementKind
    let onStamp: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum StampPhase { case hidden, hovering, slammed }

    @State private var phase: StampPhase = .hidden
    /// Extra tilt layered on the hover, stepped for the lining-up wiggle.
    @State private var wiggle: Double = 0
    /// Bumps on impact: drives the paper squash.
    @State private var impacts = 0
    @State private var ringProgress: CGFloat = 0
    @State private var badgeIn = false
    @State private var showCopy = false
    @State private var confettiStart: Date?
    @State private var confetti: [ConfettiPiece] = []
    /// Paper center in the modal's space: where the confetti bursts from.
    @State private var paperCenter: CGPoint = .zero

    private static let space = "achievementModal"
    private static let paperSide: CGFloat = 220

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            // Under the content, so the burst shoots out from beneath the
            // paper instead of scribbling over the stamp.
            if let confettiStart {
                StampConfettiBurst(start: confettiStart, origin: paperCenter, pieces: confetti)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                Spacer()

                stampStage
                    .padding(.bottom, 40)

                Text(kind.unlockTitle)
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 10)
                    .opacity(showCopy ? 1 : 0)
                    .offset(y: showCopy ? 0 : 10)

                Text(kind.unlockBody)
                    .font(Theme.callout())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 36)
                    .opacity(showCopy ? 1 : 0)
                    .offset(y: showCopy ? 0 : 10)

                Spacer()

                Button(action: onStamp) {
                    Label("Stamp my card", systemImage: "person.text.rectangle")
                }
                .buttonStyle(.spinePrimary)
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
                .opacity(showCopy ? 1 : 0)
            }
        }
        .coordinateSpace(name: Self.space)
        .onAppear(perform: run)
    }

    // MARK: Stage

    private var stampStage: some View {
        ZStack {
            // Ink shockwave, behind the paper so it rings out from its edges.
            ForEach(0..<2, id: \.self) { i in
                let p = max(0, min(1, ringProgress * 1.15 - CGFloat(i) * 0.15))
                Circle()
                    .stroke(i == 0 ? Theme.danger : Theme.textPrimary, lineWidth: 5 * (1 - p) + 0.5)
                    .frame(width: Self.paperSide, height: Self.paperSide)
                    .scaleEffect(0.8 + p * 1.2)
                    .opacity(ringProgress == 0 ? 0 : Double(1 - p) * 0.9)
            }

            paper
                .keyframeAnimator(initialValue: Squash(), trigger: impacts) { content, s in
                    content
                        .scaleEffect(x: s.scaleX, y: s.scaleY, anchor: .bottom)
                        .rotationEffect(.degrees(s.tilt))
                        .offset(y: s.drop)
                } keyframes: { _ in
                    KeyframeTrack(\.scaleY) {
                        CubicKeyframe(0.9, duration: 0.07)
                        SpringKeyframe(1.04, duration: 0.14, spring: .snappy)
                        SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                    }
                    KeyframeTrack(\.scaleX) {
                        CubicKeyframe(1.07, duration: 0.07)
                        SpringKeyframe(0.98, duration: 0.14, spring: .snappy)
                        SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                    }
                    KeyframeTrack(\.tilt) {
                        CubicKeyframe(-2.2, duration: 0.07)
                        SpringKeyframe(1.2, duration: 0.16, spring: .snappy)
                        SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                    }
                    KeyframeTrack(\.drop) {
                        CubicKeyframe(8, duration: 0.07)
                        SpringKeyframe(-3, duration: 0.14, spring: .snappy)
                        SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                    }
                }
                .onGeometryChange(for: CGPoint.self) { proxy in
                    let f = proxy.frame(in: .named(Self.space))
                    return CGPoint(x: f.midX, y: f.midY)
                } action: { paperCenter = $0 }
        }
        .frame(width: Self.paperSide, height: Self.paperSide)
    }

    private var paper: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Theme.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Theme.textPrimary, lineWidth: 2)
                )
            stamp
        }
        .frame(width: Self.paperSide, height: Self.paperSide)
        .overlay(alignment: .topLeading) {
            newStampBadge
                .rotationEffect(.degrees(-12))
                .scaleEffect(badgeIn ? 1 : 2.6)
                .opacity(badgeIn ? 1 : 0)
                .offset(x: -30, y: -18)
        }
    }

    private var stamp: some View {
        let hovering = phase == .hovering
        let slammed = phase == .slammed
        return StampImage(kind: kind)
            .frame(width: 170, height: 170)
            .rotationEffect(.degrees((slammed ? -8 : hovering ? -16 : -34) + wiggle))
            .scaleEffect(slammed ? 1 : hovering ? 1.32 : 2.2)
            .offset(y: slammed ? 0 : hovering ? -34 : -80)
            // Lifted off the paper while hovering; flat once pressed.
            .shadow(color: Theme.shadowInk.opacity(hovering ? 0.28 : 0), radius: 18, y: 26)
            .opacity(phase == .hidden ? 0 : 1)
    }

    /// Same language as the card's OG mark: ink from a real rubber stamp, the
    /// one place red belongs.
    private var newStampBadge: some View {
        Text("NEW STAMP!")
            .font(.system(size: 15, weight: .heavy))
            .tracking(1.8)
            .foregroundStyle(Theme.danger)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Theme.danger, lineWidth: 2.2)
            )
    }

    // MARK: Choreography

    private func run() {
        guard phase == .hidden else { return }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) {
                phase = .slammed
                badgeIn = true
                showCopy = true
            }
            WizardHaptics.success()
            return
        }
        confetti = ConfettiPiece.burst(count: 90)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.2))
            // Rise into view above the paper.
            withAnimation(.easeOut(duration: 0.35)) { phase = .hovering }
            try? await Task.sleep(for: .seconds(0.35))
            // Line it up: a few quick tilts.
            for tilt in [7.0, -6, 5, -3, 0] {
                withAnimation(.easeInOut(duration: 0.08)) { wiggle = tilt }
                WizardHaptics.selection()
                try? await Task.sleep(for: .seconds(0.08))
            }
            try? await Task.sleep(for: .seconds(0.12))
            // Slam.
            withAnimation(.interpolatingSpring(stiffness: 700, damping: 22)) { phase = .slammed }
            try? await Task.sleep(for: .seconds(0.07))
            impact()
            try? await Task.sleep(for: .seconds(0.4))
            withAnimation(.snappy(duration: 0.28, extraBounce: 0.25)) { badgeIn = true }
            try? await Task.sleep(for: .seconds(0.1))
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 1)
            try? await Task.sleep(for: .seconds(0.2))
            withAnimation(.easeOut(duration: 0.4)) { showCopy = true }
            WizardHaptics.success()
            // The burst is done: stop its timeline.
            try? await Task.sleep(for: .seconds(2.4))
            confettiStart = nil
        }
    }

    private func impact() {
        impacts += 1
        confettiStart = Date()
        let heavy = UIImpactFeedbackGenerator(style: .heavy)
        heavy.impactOccurred(intensity: 1)
        withAnimation(.easeOut(duration: 0.75)) { ringProgress = 1 }
    }
}

// MARK: - Squash

private struct Squash {
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var tilt: Double = 0
    var drop: CGFloat = 0
}

// MARK: - Confetti

/// One scrap of paper confetti. Motion is closed-form (linear drag plus
/// gravity), so the burst is a pure function of time since impact.
struct ConfettiPiece {
    enum Shape { case scrap, dot, streamer }
    enum Ink { case ink, red, gray }

    let angle: Double
    let speed: Double
    let size: CGSize
    let shape: Shape
    let ink: Ink
    let spin: Double
    let flutter: Double
    let drag: Double

    static func burst(count: Int) -> [ConfettiPiece] {
        (0..<count).map { _ in
            // Mostly up and out, a few straight sideways.
            let angle = Double.random(in: -Double.pi * 0.95 ... -Double.pi * 0.05)
            let shape: Shape = [.scrap, .scrap, .scrap, .dot, .streamer].randomElement()!
            let size: CGSize = switch shape {
            case .scrap: CGSize(width: .random(in: 6...10), height: .random(in: 9...14))
            case .dot: CGSize(width: 6, height: 6)
            case .streamer: CGSize(width: 3, height: .random(in: 16...24))
            }
            return ConfettiPiece(
                angle: angle,
                speed: .random(in: 380...980),
                size: size,
                shape: shape,
                ink: [.red, .red, .ink, .ink, .gray].randomElement()!,
                spin: .random(in: -9...9),
                flutter: .random(in: 6...14),
                drag: .random(in: 1.8...2.8)
            )
        }
    }

    func position(at t: Double, from origin: CGPoint) -> CGPoint {
        let gravity = 1300.0
        let k = drag
        let decay = (1 - exp(-k * t)) / k
        let vx = cos(angle) * speed
        let vy = sin(angle) * speed
        let x = origin.x + vx * decay
        let y = origin.y + vy * decay + gravity * (t / k - decay / k)
        return CGPoint(x: x, y: y)
    }
}

/// Draws a confetti burst from `origin`, starting at `start`. Pauses its own
/// timeline once every piece has faded.
struct StampConfettiBurst: View {
    let start: Date
    let origin: CGPoint
    let pieces: [ConfettiPiece]

    private static let lifetime = 2.6

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { context, _ in
                guard t >= 0, t < Self.lifetime else { return }
                let fade = t < 1.5 ? 1 : max(0, 1 - (t - 1.5) / (Self.lifetime - 1.5))
                for piece in pieces {
                    let p = piece.position(at: t, from: origin)
                    var layer = context
                    layer.opacity = fade
                    layer.translateBy(x: p.x, y: p.y)
                    layer.rotate(by: .radians(piece.spin * t))
                    // Paper flipping as it falls.
                    layer.scaleBy(x: cos(piece.flutter * t), y: 1)
                    let rect = CGRect(
                        x: -piece.size.width / 2, y: -piece.size.height / 2,
                        width: piece.size.width, height: piece.size.height
                    )
                    let path: Path = switch piece.shape {
                    case .dot: Path(ellipseIn: rect)
                    case .scrap: Path(roundedRect: rect, cornerRadius: 1.5)
                    case .streamer: Path(roundedRect: rect, cornerRadius: 1.5)
                    }
                    layer.fill(path, with: .color(color(piece.ink)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func color(_ ink: ConfettiPiece.Ink) -> Color {
        switch ink {
        case .ink: Theme.textPrimary
        case .red: Theme.danger
        case .gray: Theme.textTertiary
        }
    }
}
