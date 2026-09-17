//
//  RateSpineNudgeModal.swift
//  SPINE
//
//  The one-time "Enjoying SPINE?" pre-prompt, shown the first time a viewer
//  looks at their own tier list with a ranked book in it. Tapping through fires
//  Apple's native star prompt (MainTabView owns that, so this sheet is out of
//  the way before the alert lands).
//
//  The stars here are decoration, not an input: the actual rating is only ever
//  collected by the system prompt.
//

import SwiftUI

struct RateSpineNudgeModal: View {
    let onRate: () -> Void
    let onNotNow: () -> Void

    /// Measured content height so the detent hugs the content instead of
    /// stretching to a half-screen `.medium`.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .accessibilityHidden(true)

                Text("Enjoying SPINE? Rate it!")
                    .font(Theme.title2())
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("It takes 3 seconds and it helps a ton \u{1FAF6}\u{1F3FB}")
                .font(Theme.body())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                Button("Rate SPINE", action: onRate)
                    .buttonStyle(.spinePrimary)

                Button("Not now", action: onNotNow)
                    .buttonStyle(.spineTertiary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height + proxy.safeAreaInsets.bottom
        } action: { contentHeight = $0 }
        .presentationDetents(contentHeight > 0 ? [.height(contentHeight)] : [.medium])
    }
}
