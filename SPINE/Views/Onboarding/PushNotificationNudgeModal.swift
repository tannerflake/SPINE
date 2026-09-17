//
//  PushNotificationNudgeModal.swift
//  SPINE
//
//  Recurring prompt for users who have not granted notification permission.
//

import SwiftUI

struct PushNotificationNudgeModal: View {
    let onEnable: () -> Void
    let onNoThanks: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("SPINE is best with push notifications!")
                .font(Theme.title2())
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Theme.accent, Theme.textSecondary)
                Text("Turn on alerts so you never miss when people you follow post reviews, like yours, or reply in threads.")
                    .font(Theme.body())
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                Button("Enable", action: onEnable)
                    .buttonStyle(.spinePrimary)

                Button("No thanks", action: onNoThanks)
                    .buttonStyle(.spineTertiary)
            }
        }
        .padding(24)
    }
}
