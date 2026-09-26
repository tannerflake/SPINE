//
//  OnboardingFlowView.swift
//  SPINE
//
//  Signed-out welcome: Sign in with Apple / Google. Everything after auth is
//  the OnboardingWizardView (gated in RootView). Keep the hidden gestures:
//  5-tap = configured test account, 2s long-press = reviewer login. App Review
//  depends on both.
//

import SwiftUI
import AuthenticationServices

struct OnboardingFlowView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showReviewerLogin = false

    // Welcome entrance choreography. The mark and wordmark start exactly where
    // the cold-start splash left them (safe-area center, lifted by
    // `LaunchSplashView.logoLift`) and rise to their resting spot; then the
    // buttons ease in; once landed the mark breathes on a slow loop. Starting
    // from the splash position keeps the hand-off seamless: one lockup, no
    // cross-fade.
    @State private var logoLifted = false
    @State private var buttonsRevealed = false
    @State private var logoBreathing = false
    @State private var entranceStarted = false

    /// Global midY of the safe area (where the splash centers the mark).
    @State private var safeAreaMidY: CGFloat?
    /// Global midY of the mark's resting slot in the welcome layout.
    @State private var logoRestingMidY: CGFloat?

    /// Vertical distance the mark travels during the entrance; nil until both
    /// frames have been measured (the mark stays hidden for that first frame).
    private var logoStartOffset: CGFloat? {
        guard let safeAreaMidY, let logoRestingMidY else { return nil }
        // The splash has already lifted the lockup above safe-area center.
        return safeAreaMidY - LaunchSplashView.logoLift - logoRestingMidY
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            welcomeStep
                .padding(Theme.horizontalPadding)
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { safeAreaMidY = $0 }
        .onChange(of: logoStartOffset != nil) { _, measured in
            if measured { runWelcomeEntrance() }
        }
        .sheet(isPresented: $showReviewerLogin) {
            ReviewerLoginView()
                .environmentObject(authService)
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                // Never offset: measures the mark's resting slot so the entrance
                // can start it at the splash position and lift it here.
                Color.clear
                    .frame(width: 240, height: 240)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { logoRestingMidY = $0 }

                Image("SpineLogo")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .foregroundStyle(Theme.textPrimary)
                    .scaleEffect(logoBreathing ? 1.05 : 1.0)
                    .opacity(logoStartOffset == nil ? 0 : 1)
                    .offset(y: logoLifted ? 0 : (logoStartOffset ?? 0))
                    .onTapGesture(count: 5) {
                        Task {
                            await authService.signInWithConfiguredTestAccount()
                        }
                    }
                    .onLongPressGesture(minimumDuration: 2.0) {
                        showReviewerLogin = true
                    }
            }
            .frame(width: 240, height: 240)

            Text("SPINE")
                .font(.system(size: 40, weight: .bold))
                .tracking(10)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 28)
                // Optical centering: tracking adds trailing space after the last glyph.
                .offset(x: 5)
                // Hidden with the mark until measured, then travels with it:
                // the splash hands off a finished lockup, nothing re-fades.
                .opacity(logoStartOffset == nil ? 0 : 1)
                .offset(y: logoLifted ? 0 : (logoStartOffset ?? 0))

            Spacer()
            Spacer()

            VStack(spacing: 14) {
                if let error = authService.authError {
                    Text(error)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                SignInWithAppleButton(.signIn) { request in
                    authService.makeAppleRequest(request)
                } onCompletion: { result in
                    Task {
                        await authService.handleAppleCompletion(result)
                    }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))

                Button {
                    guard let vc = RootViewController.topMost() else { return }
                    Task {
                        await authService.signInWithGoogle(presentingViewController: vc)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image("GoogleLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                        Text("Sign in with Google")
                    }
                    .font(Theme.headline())
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                            .stroke(Theme.chrome.opacity(0.22), lineWidth: Theme.chromeHairline)
                    )
                }
                .buttonStyle(.springPress)
            }
            .opacity(buttonsRevealed ? 1 : 0)
            .offset(y: buttonsRevealed ? 0 : 16)
            .padding(.bottom, 24)
        }
    }

    /// Staged entrance: the mark lifts from the splash position → wordmark →
    /// buttons, then the slow breathing loop. Runs once the frames are measured.
    private func runWelcomeEntrance() {
        guard !entranceStarted else { return }
        entranceStarted = true
        if reduceMotion {
            logoLifted = true
        } else {
            withAnimation(.easeInOut(duration: 0.9)) {
                logoLifted = true
            }
        }
        withAnimation(.easeOut(duration: 0.8).delay(1.0)) {
            buttonsRevealed = true
        }
        if !reduceMotion {
            withAnimation(.easeInOut(duration: 2.6).delay(1.6).repeatForever(autoreverses: true)) {
                logoBreathing = true
            }
        }
    }
}
