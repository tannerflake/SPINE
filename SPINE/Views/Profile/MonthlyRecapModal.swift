//
//  MonthlyRecapModal.swift
//  SPINE
//
//  "We made something for you": the in-app twin of the monthly recap push,
//  so a reader without notifications still hears that last month's reading
//  is ready to share. "Your {Month} Reading" over a fan of the month's covers,
//  and one button into the share hub (floating shelf, that month).
//  No secondary button: sliding the sheet down is the "not now". Shown once
//  per recap; the function only ever holds the latest month, so nobody comes
//  back from a long break to a stack of these. Copy rule: no em-dashes in
//  user-facing text.
//

import SwiftUI

struct MonthlyRecapModal: View {
    let recap: MonthlyRecap
    /// Books finished that month, from the local library (newest first).
    let books: [UserBook]
    let onShare: () -> Void

    @State private var fanned = false
    @State private var showCopy = false

    private var headline: String {
        "Your \(recap.monthName) Reading"
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Text(headline)
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 30)
                    .opacity(showCopy ? 1 : 0)
                    .offset(y: showCopy ? 0 : 8)

                coverFan

                Spacer()

                Button("View your month wrapped", action: onShare)
                    .buttonStyle(.spinePrimary)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
                    .opacity(showCopy ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.snappy(duration: 0.55, extraBounce: 0.15).delay(0.2)) {
                fanned = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                WizardHaptics.success()
            }
            withAnimation(.easeOut(duration: 0.35).delay(0.55)) {
                showCopy = true
            }
        }
    }

    /// Up to five of the month's covers, dealt out like a hand of cards from
    /// a single stack. Books without cover art still get a tile (the cover
    /// view draws its title fallback), so the fan is never empty.
    private var coverFan: some View {
        let shown = Array(books.prefix(5))
        let n = shown.count
        return ZStack {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, ub in
                if let book = ub.book {
                    let offset = CGFloat(index) - CGFloat(n - 1) / 2
                    BookCoverView(book: book, size: 78)
                        .frame(width: 78, height: 117)
                        .shadow(color: Theme.shadowInk.opacity(0.22), radius: 10, y: 6)
                        .rotationEffect(.degrees(fanned ? Double(offset) * 9 : 0))
                        .offset(
                            x: fanned ? offset * 46 : 0,
                            y: fanned ? abs(offset) * 10 : 0
                        )
                        .zIndex(Double(index))
                }
            }
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .opacity(fanned ? 1 : 0)
        .scaleEffect(fanned ? 1 : 0.85)
        .accessibilityHidden(true)
    }
}

/// Marks the recap seen locally at once and in Firestore behind it, the
/// same optimistic shape as `AchievementStore`. The preview runs never write.
enum MonthlyRecapStore {
    private static let userRepo = UserRepository()

    private static var isPreviewRun: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-uiPreview")
        #else
        return false
        #endif
    }

    static func markSeen(appState: AppState, uid: String?) {
        guard var user = appState.currentUser, var recap = user.monthlyRecap, recap.seenAt == nil else { return }
        recap.seenAt = Date()
        user.monthlyRecap = recap
        appState.currentUser = user
        guard !isPreviewRun, let uid else { return }
        Task {
            do {
                try await userRepo.markMonthlyRecapSeen(uid: uid)
            } catch {
                print("⚠️ MonthlyRecapStore: seen write failed: \(error.localizedDescription)")
            }
        }
    }
}
