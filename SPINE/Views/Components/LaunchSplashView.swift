//
//  LaunchSplashView.swift
//  SPINE
//
//  Cold-start splash shown while Firebase Auth restores the session and the
//  member's Firestore document loads. Its first frame is pixel-matched to the
//  static launch screen (Info.plist `UILaunchScreen`: `LaunchBackground` +
//  `LaunchLogo`, 240pt mark centered in the safe area), so the hand-off from
//  the system launch image is invisible. The wordmark then eases in below
//  the mark, without moving it, and the mark breathes on a slow loop.
//
//  No minimum display time: RootView swaps this out the instant auth resolves,
//  cross-fading (0.25s) into the welcome screen or the tab bar.
//

import SwiftUI

struct LaunchSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var wordmarkRevealed = false
    @State private var logoBreathing = false

    /// Mirrors the welcome screen's mark size so both screens share one logo.
    private let logoSize: CGFloat = 240

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            Image("SpineLogo")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: logoSize, height: logoSize)
                .foregroundStyle(Theme.textPrimary)
                .scaleEffect(logoBreathing ? 1.05 : 1.0)
                .overlay(alignment: .bottom) {
                    // Anchored to the mark's bottom edge and pushed down, so the
                    // mark itself never shifts from where the launch image drew it.
                    Text("SPINE")
                        .font(.system(size: 40, weight: .bold))
                        .tracking(10)
                        .foregroundStyle(Theme.textPrimary)
                        // Optical centering: tracking adds trailing space after the last glyph.
                        .offset(x: 5)
                        .fixedSize()
                        .opacity(wordmarkRevealed ? 1 : 0)
                        .offset(y: wordmarkRevealed ? 0 : 12)
                        .alignmentGuide(.bottom) { d in d[.top] - 28 }
                }
        }
        .onAppear { runEntrance() }
    }

    private func runEntrance() {
        guard !wordmarkRevealed else { return }
        // Delayed so a fast load never flashes a half-faded wordmark.
        withAnimation(.easeOut(duration: 0.8).delay(0.35)) {
            wordmarkRevealed = true
        }
        if !reduceMotion {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true).delay(0.6)) {
                logoBreathing = true
            }
        }
    }
}

#Preview {
    LaunchSplashView()
}
