//
//  LaunchSplashView.swift
//  SPINE
//
//  Cold-start splash shown while Firebase Auth restores the session and the
//  member's Firestore document loads. Its first frame is pixel-matched to the
//  static launch screen (Info.plist `UILaunchScreen`: `LaunchBackground` +
//  `LaunchLogo`, 240pt mark centered in the safe area), so the hand-off from
//  the system launch image is invisible. The wordmark then eases in below the
//  mark while the pair rises by half the wordmark's height, so the finished
//  lockup sits centered instead of hanging low. The mark breathes on a slow
//  loop once landed.
//
//  RootView keeps one instance mounted for the whole load and holds it for at
//  least `minimumDisplayTime`, so a fast load never cuts the entrance off.
//

import SwiftUI

struct LaunchSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var entered = false
    @State private var logoBreathing = false

    /// Mirrors the welcome screen's mark size so both screens share one logo.
    static let logoSize: CGFloat = 240
    static let wordmarkSpacing: CGFloat = 28
    static let wordmarkFont = UIFont.systemFont(ofSize: 40, weight: .bold)

    /// How far the mark rises from the launch-image position as the wordmark
    /// joins it: half the wordmark block, so the lockup ends up centered.
    /// The welcome screen starts its mark from this lifted position.
    static var logoLift: CGFloat { (wordmarkSpacing + wordmarkFont.lineHeight) / 2 }

    /// Entrance runs `entranceDelay` + `entranceDuration`; RootView holds the
    /// splash at least this long so the lockup always finishes forming.
    static let entranceDelay: TimeInterval = 0.1
    static let entranceDuration: TimeInterval = 0.7
    static var minimumDisplayTime: TimeInterval { entranceDelay + entranceDuration + 0.1 }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Image("SpineLogo")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: Self.logoSize, height: Self.logoSize)
                    .foregroundStyle(Theme.textPrimary)
                    .scaleEffect(logoBreathing ? 1.05 : 1.0)

                Text("SPINE")
                    .font(.system(size: 40, weight: .bold))
                    .tracking(10)
                    .foregroundStyle(Theme.textPrimary)
                    // Optical centering: tracking adds trailing space after the last glyph.
                    .offset(x: 5)
                    .fixedSize()
                    .padding(.top, Self.wordmarkSpacing)
                    .opacity(entered ? 1 : 0)
                    .offset(y: entered ? 0 : 10)
            }
            // The lockup is laid out centered. On the first frame it is pushed
            // down so the mark sits exactly where the launch image drew it, then
            // rises to center as the wordmark appears.
            .offset(y: entered ? 0 : Self.logoLift)
        }
        .onAppear { runEntrance() }
    }

    private func runEntrance() {
        guard !entered else { return }
        let entrance: Animation = reduceMotion
            ? .easeOut(duration: 0.4)
            : .easeInOut(duration: Self.entranceDuration).delay(Self.entranceDelay)
        withAnimation(entrance) {
            entered = true
        }
        if !reduceMotion {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true).delay(1.0)) {
                logoBreathing = true
            }
        }
    }
}

#Preview {
    LaunchSplashView()
}
