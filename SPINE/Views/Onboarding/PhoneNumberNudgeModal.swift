//
//  PhoneNumberNudgeModal.swift
//  SPINE
//
//  Launch reminder for signed-in users with no phone number on file: the
//  backfill for accounts that predate the wizard's phone step. Same shape as
//  ProfilePhotoNudgeModal (hugging detent, one primary action, quiet "Later"),
//  and just as skippable. The number is only ever used for contact matching.
//  Shown until saved or dismissed 4 times.
//

import SwiftUI

struct PhoneNumberNudgeModal: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject private var appState: AppState

    /// Number saved successfully. Closes without counting a dismissal.
    let onSaved: () -> Void
    let onNotNow: () -> Void

    @State private var phoneText = ""
    @State private var isSaving = false
    @State private var saveError: String?
    /// Measured content height (plus the bottom safe area) so the sheet detent
    /// hugs the content instead of stretching to a half-screen `.medium`.
    /// Latched to the first measurement: once the keyboard is up,
    /// `safeAreaInsets.bottom` is the keyboard inset, and feeding that back
    /// into the detent broke the presentation (frozen, untappable sheet).
    @State private var contentHeight: CGFloat = 0
    @State private var detentSelection: PresentationDetent = .medium
    @FocusState private var phoneFocused: Bool

    private var digits: String { ContactSyncService.normalizePhoneNumber(phoneText) }

    private var canSave: Bool {
        digits.count == 10 || (digits.count == 11 && digits.hasPrefix("1"))
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Add your number")
                .font(Theme.title2())
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accent)
                Text("It helps us find your friends. We won't show it on your profile, and we won't text you.")
                    .font(Theme.body())
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            phoneField

            if let saveError {
                Text(saveError)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                Button(action: save) {
                    if isSaving {
                        ProgressView()
                            .tint(Theme.onChrome)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.spinePrimary)
                .disabled(!canSave || isSaving)

                Button("Later", action: onNotNow)
                    .buttonStyle(.spineTertiary)
                .disabled(isSaving)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height + proxy.safeAreaInsets.bottom
        } action: { height in
            // First measurement only (pre-keyboard, so the bottom inset is the
            // home indicator, not the keyboard). Re-measuring while the
            // keyboard animated made the detent chase its own tail.
            guard contentHeight == 0 else { return }
            contentHeight = height
            detentSelection = .height(height)
        }
        // The selection binding makes the .medium -> .height swap a legal
        // transition; without it UIKit was left selecting a detent that no
        // longer existed and the sheet stopped accepting input.
        .presentationDetents(
            contentHeight > 0 ? [.height(contentHeight)] : [.medium],
            selection: $detentSelection
        )
        .onAppear {
            if let existing = authService.appUser?.phoneNumber, !existing.isEmpty {
                phoneText = ContactSyncService.formatPhoneNumberForDisplay(existing)
            }
        }
        .onChange(of: phoneText) { old, new in
            var d = ContactSyncService.normalizePhoneNumber(new)
            // A backspace that landed on a separator must eat the digit behind
            // it, or the formatter snaps the character right back.
            if new.count < old.count, d == ContactSyncService.normalizePhoneNumber(old) {
                d = String(d.dropLast())
            }
            let formatted = ContactSyncService.formatPhoneNumberForDisplay(d)
            if formatted != phoneText { phoneText = formatted }
        }
    }

    private var phoneField: some View {
        HStack(spacing: 10) {
            Image(systemName: "phone.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            TextField("(555) 555-0199", text: $phoneText)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                // Puts the user's own number in the QuickType bar: one tap fills it.
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .autocorrectionDisabled()
                .focused($phoneFocused)
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.textPrimary.opacity(phoneFocused ? 0.8 : 0.12), lineWidth: 1.5)
        )
        // No tap gesture here: a container-level onTapGesture swallowed the
        // touch, and the programmatic FocusState fallback silently failed in
        // this sheet — cursor drawn, no first responder, keystrokes dead. The
        // TextField handles its own taps; UIKit focusing always works.
    }

    private func save() {
        guard let uid = authService.firebaseUser?.uid, canSave else { return }
        let toSave = digits
        isSaving = true
        saveError = nil
        Task {
            do {
                try await UserRepository().updatePhoneNumber(uid: uid, phoneNumber: toSave)
                await authService.refreshAppUser()
                await MainActor.run {
                    appState.currentUser = authService.appUser
                    isSaving = false
                    onSaved()
                }
            } catch {
                await MainActor.run {
                    saveError = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }
}
