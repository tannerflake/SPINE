//
//  PushNotificationPromptView.swift
//  SPINE
//
//  One-time sheet after profile onboarding: explain value of push, then system permission on opt-in.
//

import SwiftUI

struct PushNotificationPromptView: View {
    let onEnable: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 52))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.accent, Theme.textSecondary)
                .accessibilityHidden(true)

            Text("SPINE works best with push notifications enabled")
                .font(Theme.title2())
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Get notified when people you follow post reviews, react to yours, and reply in threads, so you never miss the conversation.")
                .font(Theme.body())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Button("Turn on notifications") {
                    onEnable()
                }
                .buttonStyle(.spinePrimary)

                Button("Not now") {
                    onNotNow()
                }
                .buttonStyle(.spineTertiary)
            }
        }
        .padding(24)
    }
}
