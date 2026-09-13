//
//  JoinClubSheet.swift
//  SPINE
//
//  Redeem a six-character club code. Also the landing spot for
//  `wellread://club/join/{CODE}` links, which arrive prefilled.
//

import SwiftUI

struct JoinClubSheet: View {
    var prefilledCode: String? = nil
    let onJoined: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var joining = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var normalized: String? { BookClub.normalizeInviteCode(code) }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Got a club code?")
                            .font(Theme.title())
                            .foregroundStyle(Theme.textPrimary)
                        Text("Whoever runs the club can share it from the club page. Six letters and numbers.")
                            .font(Theme.callout())
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    TextField("ABC123", text: $code)
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .kerning(6)
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textContentType(.oneTimeCode)
                        .foregroundStyle(Theme.textPrimary)
                        .focused($focused)
                        .submitLabel(.join)
                        .onSubmit { join() }
                        .onChange(of: code) { _, v in
                            let cleaned = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(BookClub.inviteCodeLength))
                            if cleaned != v { code = cleaned }
                            error = nil
                        }
                        .frame(height: 64)
                        .background(RoundedRectangle(cornerRadius: Theme.cardCornerRadius).fill(Theme.surfaceElevated))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cardCornerRadius).strokeBorder(Theme.chrome.opacity(0.25), lineWidth: 1))

                    if let error {
                        Text(error)
                            .font(Theme.callout())
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ClubPrimaryButton(title: "Join club", icon: "arrow.right", isLoading: joining, isEnabled: normalized != nil) { join() }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.top, 16)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .onAppear {
                if let prefilledCode, code.isEmpty { code = prefilledCode }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func join() {
        guard let normalized, !joining else { return }
        if ClubsPreview.isActive {
            onJoined(BookClub.uiPreviewDemo.id)
            dismiss()
            return
        }
        joining = true
        error = nil
        focused = false
        Task {
            do {
                let clubId = try await BookClubService.shared.joinClub(code: normalized)
                joining = false
                ToastCenter.shared.show(Toast(style: .info, status: "JOINED", message: "You're in"))
                onJoined(clubId)
                dismiss()
            } catch {
                joining = false
                self.error = error.localizedDescription
            }
        }
    }
}
