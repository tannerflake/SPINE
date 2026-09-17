//
//  WizardIdentitySteps.swift
//  SPINE
//
//  Identity steps of the onboarding wizard: name, handle, profile photo, and
//  reading goal. Each step writes into OnboardingWizardModel only; the whole
//  identity block is committed to Firestore later, at the end of the taste
//  step. Copy rule: no em-dashes in user-facing text.
//

import SwiftUI
import PhotosUI
import UIKit

// MARK: - Name

struct WizardNameStep: View {
    @ObservedObject var model: OnboardingWizardModel

    private enum Field { case first, last }
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TypewriterText(
                text: "What's your name?",
                font: .system(size: 28, weight: .bold),
                centered: false
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameField(label: "FIRST NAME", text: $model.firstName, field: .first)
                    nameField(label: "LAST NAME", text: $model.lastName, field: .last)
                }
                .padding(.top, 26)
            }
            .scrollDismissesKeyboard(.immediately)
            .wizardReveal(delay: 0.15)

            Spacer(minLength: 12)

            VStack(spacing: 10) {
                WizardCTAButton(title: "Next", enabled: model.canSubmitName) {
                    model.advance()
                }
            }
            .wizardReveal(delay: 0.3)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .onAppear {
            // Deferred so the keyboard doesn't race the step transition, but it
            // must never overwrite a field the user already tapped: landing on
            // Last Name and being yanked back to First Name reads as the tap
            // having been ignored.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard focusedField == nil else { return }
                focusedField = .first
            }
        }
    }

    private func nameField(label: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.2)
                // textSecondary, not textTertiary: 12pt labels need AA contrast.
                .foregroundStyle(Theme.textSecondary)
            TextField("", text: text)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .submitLabel(field == .first ? .next : .done)
                .onSubmit {
                    focusedField = field == .first ? .last : nil
                }
                .onChange(of: text.wrappedValue) { _, newValue in
                    // Keeps the greeting headline and the library card sane.
                    if newValue.count > 25 {
                        text.wrappedValue = String(newValue.prefix(25))
                    }
                }
                .wizardFieldChrome(focused: focusedField == field) {
                    focusedField = field
                }
        }
    }
}

// MARK: - Handle

struct WizardHandleStep: View {
    @ObservedObject var model: OnboardingWizardModel

    @FocusState private var handleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TypewriterText(
                text: "Claim your handle.",
                font: .system(size: 28, weight: .bold),
                centered: false
            )

            VStack(alignment: .leading, spacing: 12) {
                Text("Most handles are still free.")
                Text("Your first name, a nickname, etc.")
                Text("Claim a rare one while you can.")
            }
            .font(.system(size: 16))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .wizardReveal(delay: 0.2)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    handleField
                    statusRow
                }
                .padding(.top, 26)
            }
            .scrollDismissesKeyboard(.immediately)
            .wizardReveal(delay: 0.3)

            Spacer(minLength: 12)

            VStack(spacing: 10) {
                WizardCTAButton(title: "Claim it", enabled: model.handleState == .available) {
                    model.advance()
                }
            }
            .wizardReveal(delay: 0.3)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .onAppear {
            if model.handle.isEmpty {
                model.handle = model.suggestedHandle
            }
            model.scheduleHandleCheck()
        }
        .onChange(of: model.handle) { _, _ in
            model.handleInputChanged()
        }
    }

    private var handleField: some View {
        HStack(spacing: 6) {
            Text("@")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
            TextField("", text: $model.handle)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .focused($handleFocused)
        }
        .wizardFieldChrome(focused: handleFocused) {
            handleFocused = true
        }
    }

    private var statusRow: some View {
        HStack(spacing: 0) {
            switch model.handleState {
            case .idle:
                EmptyView()
            case .tooShort:
                Text("Keep going. 3 characters minimum")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            case .checking:
                HStack(spacing: 8) {
                    PulsingDot()
                    Text("Checking the card catalog…")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            case .available:
                availableBadge
            case .taken:
                Text("@\(model.normalizedHandle) is taken. Try another")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.danger)
            case .failed:
                Text("Couldn't check right now. Try again in a moment.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 30, alignment: .leading)
    }

    private var availableBadge: some View {
        HStack(spacing: 0) {
            Text("✓ AVAILABLE")
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        // strokeBorder, not stroke: a centered stroke hangs half outside the
        // bounds and the ScrollView clips it at the leading edge.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.textPrimary, lineWidth: 2)
        )
        .wizardStamp()
        .onAppear {
            let g = UIImpactFeedbackGenerator(style: .medium)
            g.prepare()
            g.impactOccurred(intensity: 1.0)
        }
    }

    /// Small dot that breathes while the availability check is in flight.
    private struct PulsingDot: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var pulsing = false

        var body: some View {
            Circle()
                .fill(Theme.textTertiary)
                .frame(width: 7, height: 7)
                .opacity(pulsing && !reduceMotion ? 0.25 : 0.9)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                    value: pulsing
                )
                .onAppear { pulsing = true }
        }
    }
}

// MARK: - Photo

struct WizardPhotoStep: View {
    @ObservedObject var model: OnboardingWizardModel

    private struct PendingCropPhoto: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoPendingCrop: PendingCropPhoto?
    @State private var showPhotoPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TypewriterText(
                text: "Put a face to the reader.",
                font: .system(size: 28, weight: .bold),
                centered: false
            )

            Spacer(minLength: 12)

            VStack(spacing: 14) {
                photoCircle
                if let error = model.photoUploadError {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .wizardReveal(delay: 0.3)

            Spacer(minLength: 12)

            VStack(spacing: 10) {
                WizardCTAButton(title: model.localProfileImage == nil ? "Add a photo" : "Looks good") {
                    if model.localProfileImage == nil {
                        showPhotoPicker = true
                    } else {
                        model.advance()
                    }
                }
                WizardGhostButton(title: model.localProfileImage == nil ? "Skip for now" : "Change photo") {
                    if model.localProfileImage == nil {
                        model.advance()
                    } else {
                        showPhotoPicker = true
                    }
                }
            }
            .wizardReveal(delay: 0.3)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .onChange(of: selectedPhotoItem) { _, newItem in
            showPhotoPicker = false
            guard let item = newItem else { return }
            Task {
                let image = await Self.loadUIImage(from: item)
                await MainActor.run {
                    selectedPhotoItem = nil
                }
                guard let image else {
                    await MainActor.run { model.photoUploadError = "Could not load image. Try another photo." }
                    return
                }
                await MainActor.run { photoPendingCrop = PendingCropPhoto(image: image) }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared())
        .fullScreenCover(item: $photoPendingCrop) { pending in
            CircularPhotoCropView(image: pending.image) {
                photoPendingCrop = nil
            } onCrop: { cropped in
                photoPendingCrop = nil
                WizardHaptics.success()
                Task { await model.uploadPhoto(cropped) }
            }
        }
    }

    private var photoCircle: some View {
        ZStack {
            if let image = model.localProfileImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 150, height: 150)
                    .clipped()
            } else {
                InitialsAvatarView(
                    displayName: nil,
                    firstName: model.displayFirstName,
                    lastName: model.lastName,
                    size: 150
                )
            }
            if model.isUploadingPhoto {
                Color.black.opacity(0.4)
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(width: 150, height: 150)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.textPrimary, lineWidth: 2))
        .shadow(color: Theme.shadowInk.opacity(0.14), radius: 12, y: 8)
    }

    /// Same loader chain as ProfileCompletionView: Data first, then a
    /// security-scoped URL, then a straight file read.
    private static func loadUIImage(from item: PhotosPickerItem) async -> UIImage? {
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            return image
        }
        guard let url = try? await item.loadTransferable(type: URL.self) else { return nil }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            return image
        }
        if FileManager.default.fileExists(atPath: url.path) {
            return UIImage(contentsOfFile: url.path)
        }
        return nil
    }
}

// MARK: - Goal

struct WizardGoalStep: View {
    @ObservedObject var model: OnboardingWizardModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var numberPop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TypewriterText(
                text: "What's your reading goal this year?",
                font: .system(size: 28, weight: .bold),
                centered: false
            )

            Text("You can change it any time.")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .wizardReveal(delay: 0.2)
                .padding(.top, 10)

            Spacer(minLength: 12)

            VStack(spacing: 20) {
                counterRow
                    .wizardReveal(delay: 0.3)
                quipLine
                    .wizardReveal(delay: 0.3)
                presetPills
                    .wizardReveal(delay: 0.3)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 12)

            VStack(spacing: 10) {
                WizardCTAButton(title: "Set my goal") {
                    model.advance()
                }
            }
            .wizardReveal(delay: 0.3)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 24)
    }

    private var counterRow: some View {
        HStack(spacing: 12) {
            stepperButton(systemName: "minus", accessibilityLabel: "Decrease goal") {
                setGoal(model.readingGoal - 1)
            }
            Text(String(model.readingGoal))
                .font(.system(size: 96, weight: .heavy))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .foregroundStyle(Theme.textPrimary)
                .scaleEffect(numberPop ? 1.07 : 1)
                .frame(maxWidth: .infinity)
            stepperButton(systemName: "plus", accessibilityLabel: "Increase goal") {
                setGoal(model.readingGoal + 1)
            }
        }
    }

    private var quipLine: some View {
        Text(quip)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .frame(minHeight: 22)
    }

    private var quip: String {
        let goal = model.readingGoal
        if goal <= 0 { return "No commitments!" }
        if goal <= 2 { return "Testing out the waters. Good luck sailor!" }
        if goal < 12 { return "The median American reads 2 books a year. You have them beat!" }
        if goal == 12 { return "A book a month. The classic." }
        if goal < 26 { return "Solid goal!" }
        if goal <= 52 { return "Ambitious! I like it." }
        if goal < 100 { return "Goated with the sauce." }
        return "Legendary. Genuinely."
    }

    private var presetPills: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                presetPill(6, label: "6 books")
                presetPill(12, label: "12 books")
                presetPill(24, label: "24 books")
            }
            noGoalPill
        }
    }

    /// Deliberately quieter than the numbered presets: an escape hatch, not a
    /// recommendation. Selecting it (or stepping down to zero) means no goal.
    private var noGoalPill: some View {
        let selected = model.readingGoal == 0
        return Button {
            setGoal(0)
        } label: {
            Text("No reading goal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Theme.onChrome : Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(selected ? Theme.textSecondary : Color.clear)
                )
                .overlay(
                    Capsule().strokeBorder(Theme.textPrimary.opacity(selected ? 0 : 0.12), lineWidth: 1.5)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.springPress)
        .opacity(selected ? 1 : 0.65)
    }

    private func presetPill(_ value: Int, label: String) -> some View {
        let selected = model.readingGoal == value
        return Button {
            setGoal(value)
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(selected ? Theme.onChrome : Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(selected ? Theme.textPrimary : Color.clear)
                )
                .overlay(
                    Capsule().stroke(Theme.textPrimary.opacity(selected ? 0 : 0.15), lineWidth: 1.5)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.springPress)
    }

    private func stepperButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Theme.surfaceElevated))
                .overlay(Circle().stroke(Theme.textPrimary.opacity(0.2), lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.springPress)
        .accessibilityLabel(accessibilityLabel)
    }

    private func setGoal(_ value: Int) {
        // 0 is a real state: no reading goal (auto-selects the no-goal pill).
        let clamped = min(1000, max(0, value))
        guard clamped != model.readingGoal else { return }
        model.readingGoal = clamped
        WizardHaptics.selection()
        popNumber()
    }

    private func popNumber() {
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) {
            numberPop = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) {
                numberPop = false
            }
        }
    }
}

// MARK: - Shared field chrome

// Not private: the phone step in WizardSocialSteps.swift uses the same chrome.
extension View {
    /// Elevated text-field chrome whose hairline sharpens while focused.
    /// The whole chrome (padding, box, prefix glyphs) focuses the field on
    /// tap; the bare TextField's hit area is only its own text line, which
    /// made the fields feel dead unless the tap landed exactly on the text.
    func wizardFieldChrome(focused: Bool, onTap: @escaping () -> Void = {}) -> some View {
        self
            .padding(15)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.surfaceElevated)
            )
            // strokeBorder keeps the full line width inside the bounds; the
            // enclosing ScrollView was clipping the outer half at the sides.
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.textPrimary.opacity(focused ? 0.8 : 0.12), lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture(perform: onTap)
    }
}
