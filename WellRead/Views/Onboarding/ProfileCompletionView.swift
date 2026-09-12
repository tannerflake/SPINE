//
//  ProfileCompletionView.swift
//  WellRead
//
//  Post–sign-in onboarding (two steps: profile + reading interests) or Edit profile from Library.
//  Main-tab onboarding sheet is not swipe-dismissible until requirements are met.
//

import PhotosUI
import SwiftUI
import UIKit

// MARK: - Handle validation (shared with User.needsProfileCompletion)

enum ProfileHandleRules {
    static let reservedHandles: Set<String> = [
        "admin", "support", "help", "spynes", "spines", "wellread", "root", "system", "api", "staff", "moderator"
    ]

    /// Lowercase ASCII handle only (a–z, 0–9, _).
    static func sanitizeHandleInput(_ raw: String) -> String {
        String(raw.lowercased().filter { c in
            ("a"..."z").contains(c) || ("0"..."9").contains(c) || c == "_"
        })
    }

    static func isValidHandle(_ s: String) -> Bool {
        guard (3...24).contains(s.count) else { return false }
        for ch in s {
            guard ch.isASCII, ch.isLetter || ch.isNumber || ch == "_" else { return false }
        }
        return true
    }
}

extension User {
    /// True until first & last name, a valid non-reserved handle, and onboarding flag are set in Firestore.
    var needsProfileCompletion: Bool {
        let f = firstName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let l = lastName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let h = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if f.isEmpty || l.isEmpty { return true }
        guard ProfileHandleRules.isValidHandle(h) else { return true }
        guard !ProfileHandleRules.reservedHandles.contains(h) else { return true }
        if !profileSetupCompleted { return true }
        return false
    }
}

// MARK: - View

enum ProfileEditorMode {
    /// First-time name, handle, and yearly book goal after sign-in.
    case onboarding
    /// Opened from Library → Edit profile.
    case edit
}

/// Identifiable wrapper so a freshly picked photo can drive a `fullScreenCover(item:)` crop step.
private struct PendingCropPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ProfileCompletionView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject private var appState: AppState
    @FocusState private var focusedField: Field?

    let mode: ProfileEditorMode
    let title: String
    let subtitle: String?
    /// Scroll to the yearly book-goal field and put the cursor in it when the view appears
    /// (e.g. opened by tapping the goal progress strip in the Library).
    let focusBookGoalOnAppear: Bool
    /// Called after successful save (e.g. to dismiss the sheet). Swipe-down still dismisses the sheet.
    var onDismiss: (() -> Void)?

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var handle = ""
    /// Plain digits; validated as 1…1000 for the calendar year goal (no default — user must enter).
    @State private var readingGoalText = ""
    /// Optional; stored normalized so friends who sync contacts can find this user.
    @State private var phoneText = ""
    /// Onboarding only: step 2 is reading-interest tags.
    @State private var onboardingWizardStep = 1
    @State private var selectedInterestTags: Set<String> = []
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var handleAvailable: Bool?
    /// When set, we couldn’t verify (e.g. Firestore rules) — don’t show “taken”.
    @State private var handleCheckError: String?
    @State private var handleCheckTask: Task<Void, Never>?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoPendingCrop: PendingCropPhoto?
    @State private var showPhotoPicker = false
    @State private var isUploadingPhoto = false
    @State private var photoUploadError: String?

    private enum Field: Hashable {
        case first, last, handle, goal, phone
    }

    private var calendarYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    private var bookGoalFieldTitle: String {
        "\(calendarYear) book goal:"
    }

    init(
        mode: ProfileEditorMode = .onboarding,
        title: String,
        subtitle: String? = nil,
        focusBookGoalOnAppear: Bool = false,
        onDismiss: (() -> Void)? = nil
    ) {
        self.mode = mode
        self.title = title
        self.subtitle = subtitle
        self.focusBookGoalOnAppear = focusBookGoalOnAppear
        self.onDismiss = onDismiss
    }

    /// Scroll anchor for the yearly book-goal field.
    private static let bookGoalFieldID = "bookGoalField"

    private var profileBasicsScroll: some View {
        ScrollViewReader { proxy in
            profileBasicsScrollContent(proxy: proxy)
        }
    }

    private func profileBasicsScrollContent(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(Theme.largeTitle())
                        .foregroundStyle(Theme.textPrimary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.body())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.top, 8)

                profilePhotoSection

                VStack(alignment: .leading, spacing: 16) {
                    labeledField(title: "First name") {
                        TextField("First name", text: $firstName)
                            .textContentType(.givenName)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .first)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .last }
                    }
                    labeledField(title: "Last name") {
                        TextField("Last name", text: $lastName)
                            .textContentType(.familyName)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .last)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .handle }
                    }
                    labeledField(title: "Handle") {
                        HStack(spacing: 4) {
                            Text("@")
                                .font(Theme.body())
                                .foregroundStyle(Theme.textTertiary)
                            TextField("your_handle", text: $handle)
                                .textFieldStyle(.plain)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .handle)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .goal }
                                .onChange(of: handle) { _, new in
                                    let sanitized = ProfileHandleRules.sanitizeHandleInput(new)
                                    if sanitized != new { handle = sanitized }
                                    scheduleHandleAvailabilityCheck()
                                }
                        }
                        .padding()
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))

                        handleHintRow
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        labeledField(title: bookGoalFieldTitle) {
                            TextField("e.g. 24", text: $readingGoalText)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.plain)
                                .focused($focusedField, equals: .goal)
                                .submitLabel(.done)
                        }
                        if mode == .edit {
                            Text("Leave blank if you don’t want a yearly goal.")
                                .font(Theme.caption())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .id(Self.bookGoalFieldID)
                    // This legacy onboarding fallback doesn't ask for a phone number;
                    // the wizard's own phone step does, with a full-size skip. Either
                    // way the ask must never look required (App Store guideline
                    // 5.1.1(v)). Here it's offered only in Edit profile.
                    if mode == .edit {
                        VStack(alignment: .leading, spacing: 4) {
                            labeledField(title: "Phone number (optional)") {
                                TextField("(555) 555-0199", text: $phoneText)
                                    .textContentType(.telephoneNumber)
                                    .keyboardType(.phonePad)
                                    .textFieldStyle(.plain)
                                    .focused($focusedField, equals: .phone)
                            }
                            Text("Only used so friends who sync their contacts can find you on SPINE. You can leave this blank.")
                                .font(Theme.caption())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }

                if mode == .edit {
                    editReadingTastesSection
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.danger.opacity(0.95))
                }

                Button(action: primaryBasicsAction) {
                    HStack {
                        if isSubmitting {
                            ProgressView()
                                .tint(Theme.background)
                        } else {
                            Text(mode == .onboarding ? "Continue" : "Save")
                                .font(Theme.headline())
                        }
                    }
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(canSubmitBasics && !isSubmitting ? Theme.accent : Theme.accent.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                }
                .disabled(!canSubmitBasics || isSubmitting)
                .padding(.top, 8)
            }
            .padding(Theme.horizontalPadding)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.immediately)
        .onAppear {
            guard focusBookGoalOnAppear else { return }
            // Let the sheet finish presenting before scrolling/raising the keyboard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bookGoalFieldID, anchor: .center)
                }
                focusedField = .goal
            }
        }
    }

    private var interestsStepContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button {
                    onboardingWizardStep = 1
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(Theme.callout().weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 8) {
                    Text("What do you love to read?")
                        .font(Theme.largeTitle())
                        .foregroundStyle(Theme.textPrimary)
                    Text("Pick at least two topics. We use them to personalize your experience.\nYou'll be able to change these later in your settings.")
                        .font(Theme.body())
                        .foregroundStyle(Theme.textSecondary)
                }

                tasteTagsCatalogGrid

                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.danger.opacity(0.95))
                }

                Button(action: submitOnboardingWithInterests) {
                    HStack {
                        if isSubmitting {
                            ProgressView()
                                .tint(Theme.background)
                        } else {
                            Text("Continue")
                                .font(Theme.headline())
                        }
                    }
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(canFinishOnboarding && !isSubmitting ? Theme.accent : Theme.accent.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                }
                .disabled(!canFinishOnboarding || isSubmitting)
                .padding(.top, 8)
            }
            .padding(Theme.horizontalPadding)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    /// Shared grid of catalog tags (onboarding step 2 + Edit profile).
    private var tasteTagsCatalogGrid: some View {
        TagCatalogPicker(selected: $selectedInterestTags)
    }

    private var editReadingTastesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Reading tastes")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
                Text("Tap to select or remove topics. We use them to personalize Discover.")
                    .font(Theme.body())
                    .foregroundStyle(Theme.textSecondary)
            }
            tasteTagsCatalogGrid
        }
    }

    var body: some View {
        Group {
            if mode == .onboarding && onboardingWizardStep == 2 {
                interestsStepContent
            } else {
                profileBasicsScroll
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            prefillFromExistingUser()
            prefillNameFromProviderIfNeeded()
        }
        .onDisappear { handleCheckTask?.cancel() }
        .onChange(of: selectedPhotoItem) { _, newItem in
            showPhotoPicker = false
            guard let item = newItem else { return }
            Task {
                let image = await Self.loadUIImage(from: item)
                await MainActor.run {
                    selectedPhotoItem = nil
                }
                guard let image else {
                    await MainActor.run { photoUploadError = "Could not load image. Try another photo." }
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
                Task { await uploadProfileImage(cropped) }
            }
        }
        .alert("Photo", isPresented: Binding(
            get: { photoUploadError != nil },
            set: { if !$0 { photoUploadError = nil } }
        )) {
            Button("OK", role: .cancel) { photoUploadError = nil }
        } message: {
            Text(photoUploadError ?? "")
        }
    }

    private var profileUserForAvatar: User? {
        appState.currentUser ?? authService.appUser
    }

    private var profilePhotoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Profile photo")
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    if let user = profileUserForAvatar {
                        UserAvatarView(
                            urlString: user.profileImageURL,
                            displayName: user.displayName,
                            firstName: user.firstName,
                            lastName: user.lastName,
                            size: 80
                        )
                    } else {
                        InitialsAvatarView(displayName: nil, size: 80)
                    }
                    if isUploadingPhoto {
                        Color.black.opacity(0.4)
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(Circle())

                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Change profile picture", systemImage: "photo")
                        .font(Theme.callout().weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(isUploadingPhoto)
            }
        }
    }

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

    private func uploadProfileImage(_ image: UIImage) async {
        guard let uid = authService.firebaseUser?.uid else { return }
        await MainActor.run {
            isUploadingPhoto = true
            photoUploadError = nil
        }
        do {
            let urlString = try await ProfilePhotoService.uploadProfilePhoto(uid: uid, image: image)
            let cacheBust = "\(urlString.contains("?") ? "&" : "?")t=\(Int(Date().timeIntervalSince1970))"
            let fullURLString = urlString + cacheBust
            if let profileURL = URL(string: fullURLString) {
                ProfileImageCache.shared.store(image, for: profileURL)
            }
            try await UserRepository().updateProfileImageURL(uid: uid, url: fullURLString)
            await authService.refreshAppUser()
            await MainActor.run {
                appState.currentUser = authService.appUser
                isUploadingPhoto = false
                photoUploadError = nil
            }
        } catch {
            await MainActor.run {
                photoUploadError = error.localizedDescription
                isUploadingPhoto = false
            }
        }
    }

    private func prefillFromExistingUser() {
        guard let u = authService.appUser else { return }
        if firstName.isEmpty, let f = u.firstName?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty {
            firstName = f
        }
        if lastName.isEmpty, let l = u.lastName?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty {
            lastName = l
        }
        if handle.isEmpty, !u.username.isEmpty {
            handle = ProfileHandleRules.sanitizeHandleInput(u.username)
        }
        if let g = u.readingGoal {
            readingGoalText = "\(g)"
        }
        if phoneText.isEmpty, let p = u.phoneNumber, !p.isEmpty {
            phoneText = p
        }
        selectedInterestTags = Set(u.readingInterestTags)
    }

    /// Apple / Google sometimes provide a display name before our form runs.
    private func prefillNameFromProviderIfNeeded() {
        guard firstName.isEmpty, lastName.isEmpty,
              let dn = authService.firebaseUser?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dn.isEmpty else { return }
        let parts = dn.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 2 {
            firstName = parts[0]
            lastName = parts[1]
        } else {
            firstName = parts[0]
        }
    }

    @ViewBuilder
    private func labeledField(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
            content()
                .font(Theme.body())
                .foregroundStyle(Theme.textPrimary)
                .padding()
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        }
    }

    @ViewBuilder
    private var handleHintRow: some View {
        HStack(alignment: .top, spacing: 6) {
            if let handleCheckError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger.opacity(0.9))
                Text(handleCheckError)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let handleAvailable {
                Image(systemName: handleAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(handleAvailable ? Theme.accent : Theme.danger.opacity(0.85))
                Text(handleAvailable ? "That handle is available." : "That handle is taken.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
            } else if normalizedHandle.count >= 3 {
                ProgressView()
                    .scaleEffect(0.75)
                Text("Checking…")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text("3–24 characters: letters, numbers, underscores.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.top, 4)
    }

    private var normalizedHandle: String {
        handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Valid range for “books to read this year.”
    private var parsedReadingGoal: Int? {
        let t = readingGoalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Int(t), (1...1000).contains(n) else { return nil }
        return n
    }

    /// Onboarding requires a goal; editing allows a blank field, which removes the goal
    /// (the Library progress bar hides when there's no goal).
    private var goalEntryIsValid: Bool {
        if parsedReadingGoal != nil { return true }
        let t = readingGoalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return mode == .edit && t.isEmpty
    }

    private var canSubmitBasics: Bool {
        let f = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !l.isEmpty else { return false }
        guard ProfileHandleRules.isValidHandle(normalizedHandle) else { return false }
        guard !ProfileHandleRules.reservedHandles.contains(normalizedHandle) else { return false }
        guard handleAvailable == true else { return false }
        guard goalEntryIsValid else { return false }
        // Profile photo is encouraged but never required (guideline 5.1.1(v)).
        return true
    }

    private var canFinishOnboarding: Bool {
        WellReadTagCatalog.shared.whitelist(Array(selectedInterestTags)).count >= 2
    }

    private func primaryBasicsAction() {
        if mode == .onboarding {
            guard canSubmitBasics else { return }
            errorMessage = nil
            focusedField = nil
            onboardingWizardStep = 2
        } else {
            submitEditProfile()
        }
    }

    private func submitEditProfile() {
        guard canSubmitBasics else { return }
        // Blank field = no goal: saved as nil, which clears it in Firestore.
        let goal = parsedReadingGoal
        errorMessage = nil
        isSubmitting = true
        Task {
            do {
                let tags = WellReadTagCatalog.shared.whitelist(Array(selectedInterestTags))
                await savePhoneNumberIfNeeded()
                try await authService.completeProfileSetup(
                    firstName: firstName.trimmingCharacters(in: .whitespacesAndNewlines),
                    lastName: lastName.trimmingCharacters(in: .whitespacesAndNewlines),
                    handle: normalizedHandle,
                    readingGoal: goal,
                    readingInterestTags: tags,
                    enforceMinimumReadingInterestTags: false
                )
                await MainActor.run {
                    isSubmitting = false
                    onDismiss?()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }

    private func submitOnboardingWithInterests() {
        guard canFinishOnboarding, let goal = parsedReadingGoal else { return }
        let tags = WellReadTagCatalog.shared.whitelist(Array(selectedInterestTags))
        guard tags.count >= 2 else { return }
        errorMessage = nil
        isSubmitting = true
        Task {
            do {
                // No phone here: onboarding doesn't collect it (guideline 5.1.1(v)).
                try await authService.completeProfileSetup(
                    firstName: firstName.trimmingCharacters(in: .whitespacesAndNewlines),
                    lastName: lastName.trimmingCharacters(in: .whitespacesAndNewlines),
                    handle: normalizedHandle,
                    readingGoal: goal,
                    readingInterestTags: tags,
                    enforceMinimumReadingInterestTags: true
                )
                await MainActor.run {
                    isSubmitting = false
                    onDismiss?()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }

    /// Saves the phone field when it changed. Best-effort: a failure here must
    /// not block finishing onboarding or profile edits.
    private func savePhoneNumberIfNeeded() async {
        guard let uid = authService.firebaseUser?.uid else { return }
        let normalized = ContactSyncService.normalizePhoneNumber(phoneText)
        let existing = authService.appUser?.phoneNumber ?? ""
        guard normalized != existing else { return }
        try? await UserRepository().updatePhoneNumber(uid: uid, phoneNumber: normalized)
    }

    private func scheduleHandleAvailabilityCheck() {
        handleCheckTask?.cancel()
        let candidate = normalizedHandle
        guard ProfileHandleRules.isValidHandle(candidate), !ProfileHandleRules.reservedHandles.contains(candidate) else {
            handleAvailable = nil
            handleCheckError = nil
            return
        }
        // Debounce off the main thread — don’t clear handle state on every keystroke (avoids re-render/tap lag).
        handleCheckTask = Task {
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard normalizedHandle == candidate else { return }
                handleAvailable = nil
                handleCheckError = nil
            }
            guard !Task.isCancelled else { return }
            let outcome = await authService.checkUsernameAvailability(candidate)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard normalizedHandle == candidate else { return }
                switch outcome {
                case .available:
                    handleAvailable = true
                    handleCheckError = nil
                case .taken:
                    handleAvailable = false
                    handleCheckError = nil
                case .failed:
                    handleAvailable = nil
                    handleCheckError = "Couldn’t verify this handle (Firestore permissions). In Firebase Console: Firestore → choose the database “wellread” (not default) → Rules → paste the repo’s firestore.rules → Publish."
                }
            }
        }
    }
}
