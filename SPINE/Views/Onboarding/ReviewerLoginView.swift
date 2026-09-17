//
//  ReviewerLoginView.swift
//  SPINE
//
//  Hidden email/password login for App Review. Trigger: long-press app logo on sign-in screen.
//  Supports signing in to an existing account or creating a new one, so reviewers can
//  demo the full account lifecycle (signup → onboarding → deletion).
//

import SwiftUI

struct ReviewerLoginView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign In"
        case createAccount = "Create Account"
        var id: String { rawValue }
    }

    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 24) {
                    Text("Reviewer Login")
                        .font(Theme.title())
                        .foregroundStyle(Theme.textPrimary)
                    Text("For App Review only")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textTertiary)

                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Email", text: $email)
                            .textFieldStyle(.plain)
                            .font(Theme.body())
                            .padding()
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)

                        SecureField("Password", text: $password)
                            .textFieldStyle(.plain)
                            .font(Theme.body())
                            .padding()
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                            .textContentType(mode == .createAccount ? .newPassword : .password)

                        if mode == .createAccount {
                            SecureField("Repeat password", text: $confirmPassword)
                                .textFieldStyle(.plain)
                                .font(Theme.body())
                                .padding()
                                .background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                                .textContentType(.newPassword)

                            if !confirmPassword.isEmpty && password != confirmPassword {
                                Text("Passwords don't match.")
                                    .font(Theme.caption())
                                    .foregroundStyle(Theme.danger)
                            }
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.caption())
                            .foregroundStyle(Theme.danger)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Button {
                        submit()
                    } label: {
                        Text(buttonTitle)
                            .font(Theme.headline())
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(canSubmit && !isLoading ? Theme.accent : Theme.textTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                    }
                    .disabled(isLoading || !canSubmit)
                }
                .padding(Theme.horizontalPadding)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
            .onChange(of: mode) { _, _ in
                errorMessage = nil
            }
        }
    }

    private var buttonTitle: String {
        if isLoading {
            return mode == .signIn ? "Signing In…" : "Creating Account…"
        }
        return mode.rawValue
    }

    private var canSubmit: Bool {
        guard !email.isEmpty, !password.isEmpty else { return false }
        if mode == .createAccount {
            // Firebase enforces a 6-character minimum; check here for a clearer button state.
            guard password.count >= 6, password == confirmPassword else { return false }
        }
        return true
    }

    private func submit() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                if mode == .signIn {
                    try await authService.signInWithEmail(email, password: password)
                } else {
                    try await authService.createAccountWithEmail(email, password: password)
                }
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
            await MainActor.run { isLoading = false }
        }
    }
}
