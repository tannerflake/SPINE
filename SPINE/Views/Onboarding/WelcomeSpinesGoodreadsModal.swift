//
//  WelcomeSpinesGoodreadsModal.swift
//  SPINE
//
//  Shown once after the user completes name + handle onboarding.
//

import SwiftUI

enum WelcomeSpinesGoodreadsPromptStorage {
    private static let keyPrefix = "welcomeSpinesGoodreadsPromptShown_"
    /// Prior branding key — still honored so existing users are not re-prompted.
    private static let legacyKeyPrefix = "welcomeSpynesGoodreadsPromptShown_"

    static func hasShown(for uid: String) -> Bool {
        if UserDefaults.standard.bool(forKey: keyPrefix + uid) { return true }
        return UserDefaults.standard.bool(forKey: legacyKeyPrefix + uid)
    }

    static func markShown(for uid: String) {
        UserDefaults.standard.set(true, forKey: keyPrefix + uid)
        UserDefaults.standard.removeObject(forKey: legacyKeyPrefix + uid)
    }
}

struct WelcomeSpinesGoodreadsModal: View {
    let onLetsGo: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("Welcome to SPINE")
                .font(Theme.largeTitle())
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)

            Text("Let's import your Goodreads data. It only takes a couple of minutes.")
                .font(Theme.body())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Button("Let's go!", action: onLetsGo)
                    .buttonStyle(.spinePrimary)

                Button("I don't use Goodreads", action: onLater)
                    .buttonStyle(.spineSecondary)
            }
            .padding(.top, 8)
        }
        .padding(Theme.horizontalPadding)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }
}
