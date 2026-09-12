//
//  PushNotificationPromptView.swift
//  WellRead
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
                Button {
                    onEnable()
                } label: {
                    Text("Turn on notifications")
                        .font(Theme.headline())
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.accentGloss)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                }
                .buttonStyle(.plain)

                Button {
                    onNotNow()
                } label: {
                    Text("Not now")
                        .font(Theme.headline())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
    }
}
