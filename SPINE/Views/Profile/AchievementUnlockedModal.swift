//
//  AchievementUnlockedModal.swift
//  SPINE
//
//  The celebration when a stamp is earned: the stamp slams onto the page,
//  then "Stamp my card" hands it to the stamping screen. "Not now" leaves it
//  waiting in the bank on the card page. Copy rule: no em-dashes in
//  user-facing text.
//

import SwiftUI

struct AchievementUnlockedModal: View {
    let kind: AchievementKind
    let onStamp: () -> Void
    let onNotNow: () -> Void

    @State private var landed = false
    @State private var showCopy = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Text("NEW STAMP")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(4)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 26)
                    .opacity(showCopy ? 1 : 0)

                ZStack {
                    // Paper the stamp lands on, so the art reads like it is
                    // pressed onto the card rather than floating.
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Theme.surfaceElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Theme.textPrimary, lineWidth: 2)
                        )
                        .frame(width: 220, height: 220)
                    StampImage(kind: kind)
                        .frame(width: 170, height: 170)
                        .rotationEffect(.degrees(landed ? -8 : -30))
                        .scaleEffect(landed ? 1 : 2.4)
                        .opacity(landed ? 1 : 0)
                }
                .padding(.bottom, 30)

                Text(kind.unlockTitle)
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 10)
                    .opacity(showCopy ? 1 : 0)
                    .offset(y: showCopy ? 0 : 8)

                Text(kind.unlockBody)
                    .font(Theme.callout())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 36)
                    .opacity(showCopy ? 1 : 0)
                    .offset(y: showCopy ? 0 : 8)

                Spacer()

                VStack(spacing: 8) {
                    Button(action: onStamp) {
                        Label("Stamp my card", systemImage: "seal")
                    }
                    .buttonStyle(.spinePrimary)

                    Button("Not now", action: onNotNow)
                        .buttonStyle(.spineTertiary)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
                .opacity(showCopy ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.snappy(duration: 0.45, extraBounce: 0.2).delay(0.25)) {
                landed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WizardHaptics.success()
            }
            withAnimation(.easeOut(duration: 0.35).delay(0.6)) {
                showCopy = true
            }
        }
    }
}
