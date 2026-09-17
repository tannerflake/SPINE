//
//  OnboardingWizard.swift
//  SPINE
//
//  Full-screen new-user onboarding wizard ("your library card"). Replaces the
//  old MainTabView sheet chain for accounts that still need profile completion.
//  RootView shows this (latched) until `finish()` runs; every completion flag
//  the old sheet chain consults is written here too, so MainTabView never
//  re-prompts a wizard graduate. Copy rule: no em-dashes in user-facing text.
//
//  DEBUG: launch with -uiPreviewOnboardingWizard to walk the wizard without a
//  signed-in session (no Firestore writes; canned roster).
//

import SwiftUI
import UIKit

// MARK: - Model

@MainActor
final class OnboardingWizardModel: ObservableObject {

    enum WizardStep: Int, CaseIterable {
        case intro, name, greet, handle, photo, goal, characteristics, taste,
             reading, phone, contacts, roster, mutuals, invite, notifications, appearance,
             stamping, card, tiers, tierPractice, founderNote, goodreads

        /// Book spines filled on the shelf meter while this step is showing.
        var spineCount: Int {
            switch self {
            case .intro: return 0
            case .name, .greet: return 1
            case .handle: return 2
            case .photo: return 3
            case .goal: return 4
            case .characteristics: return 5
            case .taste: return 6
            case .reading: return 7
            case .phone: return 8
            case .contacts, .roster, .mutuals: return 9
            case .invite: return 10
            case .notifications: return 11
            case .appearance: return 12
            case .stamping, .card, .tiers, .tierPractice, .founderNote, .goodreads: return 13
            }
        }

        /// Every step can walk back except the very first and the stamping
        /// interstitial (it auto-advances, so back would just bounce forward).
        var showsBack: Bool {
            switch self {
            case .intro, .stamping: return false
            default: return true
            }
        }
    }

    enum HandleCheckState: Equatable {
        case idle          // nothing entered yet
        case tooShort
        case checking
        case available
        case taken
        case failed        // network/permissions problem, distinct from taken
    }

    /// Roster row: a reader already on SPINE.
    struct RosterEntry: Identifiable, Equatable {
        let uid: String
        let user: User
        var id: String { uid }
    }

    /// Mutuals-step row: a reader followed by someone the user just followed
    /// on the roster step, with the names of those followers for the
    /// "Followed by Katie and Sam" line.
    struct MutualCandidate: Identifiable, Equatable {
        let entry: RosterEntry
        let followedBy: [String]
        let score: Int
        var id: String { entry.uid }
    }

    // Suppresses MainTabView's launch nudges right after the wizard hands off
    // (the photo nudge would otherwise fire 1.2s after "Skip for now").
    static var justCompletedThisLaunch = false

    let previewMode: Bool
    private let onFinished: () -> Void

    private(set) weak var authService: AuthService?
    private(set) weak var appState: AppState?
    private let userRepo = UserRepository()

    // MARK: Published state

    @Published var step: WizardStep = .intro

    // Identity
    @Published var firstName = ""
    @Published var lastName = ""
    @Published var handle = ""
    @Published var handleState: HandleCheckState = .idle
    @Published var localProfileImage: UIImage?
    @Published var isUploadingPhoto = false
    @Published var photoUploadError: String?
    /// 0 means "no reading goal".
    @Published var readingGoal = 12
    @Published var selectedTags: Set<String> = []
    @Published var isCommittingProfile = false
    @Published var commitError: String?

    // Books
    @Published var pickedBook: Book?

    // Social
    @Published var roster: [RosterEntry] = []
    @Published var isLoadingRoster = false
    @Published var followedUids: Set<String> = []
    @Published var followInFlight: Set<String> = []
    /// Frozen when the roster step is left (see `finishRosterStep`), so the
    /// mutuals list never reshuffles under a finger as follows land on it.
    @Published var mutualCandidates: [MutualCandidate] = []
    @Published var inviteCandidates: [SyncedContact] = []
    @Published var isLoadingContacts = false
    @Published var contactsGranted = false
    @Published var invitedContactIds: Set<String> = []
    /// People from the user's address book who are already on SPINE, matched
    /// on device by phone number. These outrank taste-similar strangers on the
    /// roster step: someone you actually know is the better first follow.
    @Published var contactMatches: [MatchedMember] = []
    @Published var isMatchingContacts = false
    /// True once a contact match has been attempted on the roster step, so the
    /// prompt card stops asking after the user has answered either way.
    @Published var didAttemptContactMatch = false
    /// Access was refused: say so quietly instead of re-prompting (a second
    /// requestAccess call is a no-op once the user has denied).
    @Published var contactAccessDenied = false
    /// Phone number as typed/formatted. Optional and skippable: it exists only
    /// so friends who already have the user in their contacts can find them.
    @Published var phoneNumber = ""

    private var handleCheckTask: Task<Void, Never>?
    private var didFollowSomeone = false
    /// One announcement per wizard run, even if the user walks back onto the
    /// roster step and continues again.
    private var didAnnounceJoinToContacts = false
    /// Navigation debounce: catches a same-gesture double-fire (two taps landing
    /// in the same frame) so one press can't skip a step. Scoped to the step it
    /// fired from, not to wall-clock alone: a plain time window also swallowed
    /// the user's first real tap on the step that had just appeared, which read
    /// as "every button needs two taps". A second tap from a *different* step is
    /// always a new intent and is never rejected.
    private var lastNavigationAt = Date.distantPast
    private var lastNavigationFrom: WizardStep?
    /// True once completeProfileSetup has been requested (set before the await
    /// so the appUser refresh it triggers can't be mistaken for a stale gate).
    @Published private(set) var hasCommittedProfile = false
    /// Photo upload/removal ordering: bumped on every user intent so a slow
    /// upload can't resurrect a photo the user already removed.
    private var photoGeneration = 0
    private var didUploadPhotoThisSession = false

    init(previewMode: Bool = false, onFinished: @escaping () -> Void) {
        self.previewMode = previewMode
        self.onFinished = onFinished
        // -uiPreviewWizardCard (alongside -uiPreviewOnboardingWizard) jumps
        // straight to the card payoff with demo data, for choreography work.
        if previewMode, ProcessInfo.processInfo.arguments.contains("-uiPreviewWizardCard") {
            firstName = "Tanner"
            lastName = "Flake"
            handle = "tanner"
            readingGoal = 27
            step = .card
        }
        // -uiPreviewWizardAppearance jumps to the light/dark/system step.
        if previewMode, ProcessInfo.processInfo.arguments.contains("-uiPreviewWizardAppearance") {
            step = .appearance
        }
        // -uiPreviewWizardPhone jumps to the phone-number step.
        if previewMode, ProcessInfo.processInfo.arguments.contains("-uiPreviewWizardPhone") {
            step = .phone
        }
        // -uiPreviewWizardTaste jumps to the genre taste step.
        if previewMode, ProcessInfo.processInfo.arguments.contains("-uiPreviewWizardTaste") {
            step = .taste
        }
        // -uiPreviewWizardContacts jumps to the contacts sync step.
        if previewMode, ProcessInfo.processInfo.arguments.contains("-uiPreviewWizardContacts") {
            step = .contacts
        }
        // -uiPreviewWizardTiers jumps to the "how tiers work" explainer.
        if previewMode, ProcessInfo.processInfo.arguments.contains("-uiPreviewWizardTiers") {
            step = .tiers
        }
        // -uiPreviewWizardTierPractice jumps to the hands-on tier step that
        // follows the explainer.
        if previewMode, ProcessInfo.processInfo.arguments.contains("-uiPreviewWizardTierPractice") {
            step = .tierPractice
        }
        // -uiPreviewWizardRoster jumps to the find-a-buddy roster step (and
        // from there the mutuals step, once a demo reader is followed).
        if previewMode, ProcessInfo.processInfo.arguments.contains("-uiPreviewWizardRoster") {
            step = .roster
        }
    }

    // MARK: Configuration

    func configure(authService: AuthService, appState: AppState) {
        guard self.authService == nil else { return }
        self.authService = authService
        self.appState = appState
        prefillFromAccount()
        // Fetched now so the card step's count-up has the real number by the
        // time it runs (the card is ~10 steps away).
        loadMemberNumberIfNeeded()
    }

    /// First/last from the auth display name (Apple/Google), same split the old
    /// ProfileCompletionView used. Never overwrites what the user typed.
    private func prefillFromAccount() {
        guard firstName.isEmpty, lastName.isEmpty,
              let displayName = authService?.appUser?.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty, displayName.contains(" ") else { return }
        let parts = displayName.split(separator: " ", maxSplits: 1)
        firstName = String(parts[0])
        if parts.count > 1 { lastName = String(parts[1]) }
    }

    var uid: String? { authService?.firebaseUser?.uid }

    var displayFirstName: String {
        let f = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        return f.isEmpty ? "Reader" : f
    }

    /// First choice: just the first name. Falls back to first+last when the
    /// first name alone is too short to be a valid handle.
    var suggestedHandle: String {
        let first = ProfileHandleRules.sanitizeHandleInput(firstName)
        if first.count >= 3 { return first }
        return ProfileHandleRules.sanitizeHandleInput(firstName + lastName)
    }

    var canSubmitName: Bool {
        !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Picks made on the characteristics step (selectedTags is shared with the
    /// taste step; each step gates on its own vocabulary).
    var characteristicPickCount: Int {
        selectedTags.intersection(Self.characteristicTagSet).count
    }

    var canSubmitCharacteristics: Bool {
        characteristicPickCount >= 5
    }

    var tastePickCount: Int {
        selectedTags.intersection(Self.tasteTreeTagSet).count
    }

    var canSubmitTaste: Bool {
        tastePickCount >= 2
    }

    // MARK: Navigation

    private func navigationDebounced() -> Bool {
        // Reject only a repeat fire from the step we just left: that is the
        // same-gesture double-fire. Once `step` has moved on, any tap is a
        // fresh intent from a screen the user is actually looking at, so it
        // must go through no matter how fast it arrived.
        if lastNavigationFrom == step, Date().timeIntervalSince(lastNavigationAt) < 0.3 {
            return false
        }
        lastNavigationFrom = step
        lastNavigationAt = Date()
        return true
    }

    /// Returns true when navigation actually happened (callers like the
    /// interstitial one-shot latch must not consume a rejected tap).
    @discardableResult
    func advance() -> Bool {
        guard navigationDebounced(),
              var next = WizardStep(rawValue: step.rawValue + 1) else { return false }
        // Conditional steps are skipped in both directions (see `isSkipped`).
        while isSkipped(next) {
            guard let after = WizardStep(rawValue: next.rawValue + 1) else { return false }
            next = after
        }
        WizardHaptics.step()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
            step = next
        }
        return true
    }

    /// Advances only when the wizard is still on `expected`. Callers that
    /// advance after an `await` (a permission dialog, a contact scan) use this:
    /// the step debounce is time-scoped and can't catch a second tap that lands
    /// while the await is outstanding, and two advances would skip a step.
    /// Unlike latching the buttons, this can never strand the user on a screen
    /// whose await failed to return.
    func advanceIfCurrent(_ expected: WizardStep) {
        guard step == expected else { return }
        advance()
    }

    /// Steps that only exist when there is something to show. The mutuals
    /// step needs at least one friend-of-a-friend; with none it would be a
    /// blank screen between the roster and the invite step.
    private func isSkipped(_ candidate: WizardStep) -> Bool {
        candidate == .mutuals && mutualCandidates.isEmpty
    }

    func goBack() {
        guard step.showsBack, !isCommittingProfile,
              navigationDebounced(),
              var previous = WizardStep(rawValue: step.rawValue - 1) else { return }
        // Stepping back onto the stamping interstitial would auto-advance
        // straight back here; land on the step before it instead.
        if previous == .stamping {
            guard let beforeStamping = WizardStep(rawValue: previous.rawValue - 1) else { return }
            previous = beforeStamping
        }
        while isSkipped(previous) {
            guard let before = WizardStep(rawValue: previous.rawValue - 1) else { return }
            previous = before
        }
        WizardHaptics.step()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
            step = previous
        }
    }

    // MARK: Handle availability (debounced, mirrors ProfileCompletionView)

    var normalizedHandle: String {
        handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func handleInputChanged() {
        let sanitized = ProfileHandleRules.sanitizeHandleInput(handle)
        if sanitized != handle { handle = sanitized }
        scheduleHandleCheck()
    }

    func scheduleHandleCheck() {
        handleCheckTask?.cancel()
        let candidate = normalizedHandle
        if candidate.isEmpty {
            handleState = .idle
            return
        }
        guard ProfileHandleRules.isValidHandle(candidate),
              !ProfileHandleRules.reservedHandles.contains(candidate) else {
            handleState = candidate.count < 3 ? .tooShort : .taken
            return
        }
        handleState = .checking
        if previewMode {
            handleCheckTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.normalizedHandle == candidate else { return }
                    self.handleState = ["tanner", "spine", "books"].contains(candidate) ? .taken : .available
                }
            }
            return
        }
        handleCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled, let authService = self?.authService else { return }
            let outcome = await authService.checkUsernameAvailability(candidate)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.normalizedHandle == candidate else { return }
                switch outcome {
                case .available: self.handleState = .available
                case .taken: self.handleState = .taken
                case .failed: self.handleState = .failed
                }
            }
        }
    }

    // MARK: Photo

    func uploadPhoto(_ cropped: UIImage) async {
        photoGeneration += 1
        let generation = photoGeneration
        localProfileImage = cropped
        photoUploadError = nil
        guard !previewMode, let uid, let authService, let appState else { return }
        isUploadingPhoto = true
        do {
            let urlString = try await ProfilePhotoService.uploadProfilePhoto(uid: uid, image: cropped)
            // The user tapped "Actually, remove it" while this upload was in
            // flight: drop the result instead of resurrecting the photo.
            guard generation == photoGeneration else {
                isUploadingPhoto = false
                return
            }
            let cacheBust = "\(urlString.contains("?") ? "&" : "?")t=\(Int(Date().timeIntervalSince1970))"
            let fullURLString = urlString + cacheBust
            if let profileURL = URL(string: fullURLString) {
                ProfileImageCache.shared.store(cropped, for: profileURL)
            }
            try await userRepo.updateProfileImageURL(uid: uid, url: fullURLString)
            didUploadPhotoThisSession = true
            await authService.refreshAppUser()
            appState.currentUser = authService.appUser
            isUploadingPhoto = false
        } catch {
            guard generation == photoGeneration else { return }
            // Keep the local image so the card still shows it; retry is silent
            // via the photo-nudge system later.
            photoUploadError = error.localizedDescription
            isUploadingPhoto = false
        }
    }

    func removePhoto() {
        photoGeneration += 1
        localProfileImage = nil
        photoUploadError = nil
        isUploadingPhoto = false
        // Undo the server write too, but only if this wizard session made it;
        // an auth-provider photo the user never saw here is not ours to clear.
        guard didUploadPhotoThisSession, !previewMode, let uid, let authService else { return }
        didUploadPhotoThisSession = false
        Task {
            try? await userRepo.updateProfileImageURL(uid: uid, url: "")
            await authService.refreshAppUser()
        }
    }

    // MARK: Profile commit (end of taste step)

    /// One write for the whole identity block, exactly like the old flow's
    /// finish button: name + handle + goal + tags -> completeProfileSetup.
    /// Returns true when the wizard may advance.
    func commitProfile() async -> Bool {
        guard !isCommittingProfile else { return false }
        commitError = nil
        if previewMode { return true }
        guard let authService else { return false }
        isCommittingProfile = true
        hasCommittedProfile = true
        defer { isCommittingProfile = false }
        do {
            try await authService.completeProfileSetup(
                firstName: firstName.trimmingCharacters(in: .whitespacesAndNewlines),
                lastName: lastName.trimmingCharacters(in: .whitespacesAndNewlines),
                handle: normalizedHandle,
                readingGoal: readingGoal > 0 ? readingGoal : nil,
                readingInterestTags: Array(selectedTags)
            )
            return true
        } catch {
            hasCommittedProfile = false
            let nsError = error as NSError
            if nsError.code == 409 {
                // Someone claimed the handle between the check and the commit.
                // The taste screen has no handle field, so send the user back
                // to it; its onAppear re-runs the availability check.
                commitError = nil
                handleState = .taken
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    step = .handle
                }
            } else {
                commitError = error.localizedDescription
            }
            return false
        }
    }

    // MARK: Currently reading

    func shelvePickedBook() {
        if let book = pickedBook, !previewMode {
            appState?.addToQueue(book: book, shelf: .readingNow)
        }
        // Consume the pick so a second tap on "Shelve it" (during the advance
        // animation) can't add the book twice.
        pickedBook = nil
        markCurrentlyReadingShown()
    }

    func markCurrentlyReadingShown() {
        guard !previewMode, let uid else { return }
        OnboardingCurrentlyReadingPromptStorage.markShown(for: uid)
    }

    // MARK: Phone (contact matching)

    /// Digits only, ignoring display formatting.
    var phoneDigits: String { ContactSyncService.normalizePhoneNumber(phoneNumber) }

    /// A real number is 10 digits, or 11 with a leading country "1". Below that
    /// the field is blank or half typed, and "That's me" stays dim.
    var canSubmitPhone: Bool {
        let digits = phoneDigits
        return digits.count == 10 || (digits.count == 11 && digits.hasPrefix("1"))
    }

    /// Reformats while typing. `old` is what lets a backspace that landed on a
    /// separator eat the digit behind it: without that, deleting ")" leaves the
    /// digits unchanged and the formatter snaps the character straight back,
    /// which reads as a field that refuses to be edited.
    func phoneInputChanged(old: String, new: String) {
        var digits = ContactSyncService.normalizePhoneNumber(new)
        if new.count < old.count, digits == ContactSyncService.normalizePhoneNumber(old) {
            digits = String(digits.dropLast())
        }
        let formatted = ContactSyncService.formatPhoneNumberForDisplay(digits)
        if formatted != phoneNumber { phoneNumber = formatted }
    }

    /// Prefills from the account when we already have one on file (re-running
    /// the wizard, or a number added from Edit profile).
    func prefillPhoneIfNeeded() {
        guard phoneNumber.isEmpty,
              let existing = authService?.appUser?.phoneNumber, !existing.isEmpty else { return }
        phoneNumber = ContactSyncService.formatPhoneNumberForDisplay(existing)
    }

    /// Saves the number and moves on. Best effort, exactly like the old
    /// ProfileCompletionView write: a failure here must never block onboarding,
    /// so the step never waits on it and never surfaces an error.
    func finishPhoneStep() {
        let digits = phoneDigits
        if !digits.isEmpty, !previewMode, let uid {
            let repo = userRepo
            Task { try? await repo.updatePhoneNumber(uid: uid, phoneNumber: digits) }
        }
        advance()
    }

    // MARK: Roster + follows

    /// Roster entries most similar to this user: overlap between their stored
    /// readingInterestTags and the tags just picked in this wizard. Two
    /// minimum (padded with the best available when overlap is thin), eight
    /// maximum; shared tags come back in the wizard's own pick order.
    var similarReaders: [(entry: RosterEntry, sharedTags: [String])] {
        // Anyone already shown under "FROM YOUR CONTACTS" is out: a duplicate
        // row with a second Follow button reads as a bug.
        let contactUids = Set(contactMatches.map(\.uid))
        let scored = roster.filter { !contactUids.contains($0.uid) }.map { entry -> (entry: RosterEntry, sharedTags: [String]) in
            let theirs = Set(entry.user.readingInterestTags)
            let shared = Self.characteristicTags.filter { selectedTags.contains($0) && theirs.contains($0) }
                + Self.tasteTree.flatMap { [$0.root] + $0.children }.filter { selectedTags.contains($0) && theirs.contains($0) }
            return (entry, shared)
        }
        let ranked = scored.sorted {
            if $0.sharedTags.count != $1.sharedTags.count { return $0.sharedTags.count > $1.sharedTags.count }
            return $0.entry.user.displayName.localizedCaseInsensitiveCompare($1.entry.user.displayName) == .orderedAscending
        }
        let overlapping = ranked.filter { !$0.sharedTags.isEmpty }
        if overlapping.count >= 2 { return Array(overlapping.prefix(8)) }
        return Array(ranked.prefix(2))
    }

    /// Roster fetch cap, well above the current member count (~600 as of
    /// September 2026). The old 300 cap silently dropped half the members
    /// from the step, and from the mutuals math, without any sign in the UI.
    /// Matches or exceeds PeopleStrip's cap so the two rosters agree.
    private static let rosterLimit = 1000

    func loadRosterIfNeeded() async {
        guard roster.isEmpty, !isLoadingRoster else { return }
        isLoadingRoster = true
        defer { isLoadingRoster = false }
        if previewMode {
            roster = Self.previewRoster
            return
        }
        guard let uid else { return }
        let readers = await userRepo.fetchAllReaderProfiles(excludingUid: uid, limit: Self.rosterLimit)
        roster = readers.map { RosterEntry(uid: $0.uid, user: $0.user) }
        followedUids = Set(authService?.appUser?.following ?? [])
    }

    func toggleFollow(targetUid: String) async {
        guard !followInFlight.contains(targetUid) else { return }
        let willFollow = !followedUids.contains(targetUid)
        followInFlight.insert(targetUid)
        defer { followInFlight.remove(targetUid) }
        if previewMode {
            if willFollow { followedUids.insert(targetUid) } else { followedUids.remove(targetUid) }
            return
        }
        guard let uid else { return }
        do {
            try await userRepo.setFollowing(currentUid: uid, targetUid: targetUid, follow: willFollow)
            if willFollow { followedUids.insert(targetUid) } else { followedUids.remove(targetUid) }
            didFollowSomeone = true
        } catch {
            // Leave state unchanged; the row stays tappable.
        }
    }

    /// Called when leaving the roster step. Freezes the mutuals list from the
    /// follows made here, then advances (straight past the mutuals step when
    /// that list is empty).
    func finishRosterStep() {
        announceJoinToMatchedContacts()
        refreshFollowGraphIfNeeded()
        mutualCandidates = computeMutualCandidates()
        advance()
    }

    func finishMutualsStep() {
        refreshFollowGraphIfNeeded()
        advance()
    }

    /// One appUser refresh per social step covers every follow made on it
    /// (per-tap refreshes would restart feed listeners each time).
    private func refreshFollowGraphIfNeeded() {
        guard didFollowSomeone, !previewMode else { return }
        let service = authService
        let state = appState
        Task {
            await service?.refreshAppUser()
            if let state {
                WidgetDataService.shared.scheduleRefresh(appState: state, delay: 1.0, forceFriendRefresh: true)
            }
        }
    }

    /// Readers followed by the people the user followed on the roster step,
    /// ranked with `PeopleSimilarity` (the same scorer as the People strip and
    /// Search) so overlap between two friends' circles floats to the top. The
    /// roster already carries everyone's `following`, so this costs no reads.
    /// Capped: one heavy follower can pull in hundreds and recreate the very
    /// scroll problem this step exists to solve.
    private static let mutualsCap = 24

    private func computeMutualCandidates() -> [MutualCandidate] {
        let byUid = Dictionary(roster.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        // The founder is a default follow for every new account and follows
        // nobody, so he is neither a peer nor a candidate.
        let peers = roster.filter { followedUids.contains($0.uid) && $0.uid != SpineFounder.uid }
        guard !peers.isEmpty else { return [] }
        let peerFollowing = peers.map { (uid: $0.uid, following: $0.user.following) }
        var candidateUids = Set(peers.flatMap(\.user.following))
        candidateUids.subtract(followedUids)
        candidateUids.remove(SpineFounder.uid)
        if let uid { candidateUids.remove(uid) }
        let scored = candidateUids.compactMap { candidateUid -> MutualCandidate? in
            guard let entry = byUid[candidateUid] else { return nil }
            let followedBy = peers
                .filter { $0.user.following.contains(candidateUid) }
                .map(\.user.displayName)
            return MutualCandidate(
                entry: entry,
                followedBy: followedBy,
                score: PeopleSimilarity.score(
                    candidateUid: candidateUid,
                    candidateFollowing: entry.user.following,
                    following: followedUids,
                    peers: peerFollowing,
                    currentUid: uid
                )
            )
        }
        let ranked = scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.followedBy.count != $1.followedBy.count { return $0.followedBy.count > $1.followedBy.count }
            return $0.entry.user.displayName.localizedCaseInsensitiveCompare($1.entry.user.displayName) == .orderedAscending
        }
        return Array(ranked.prefix(Self.mutualsCap))
    }

    // MARK: Contacts on SPINE (roster step)

    /// True when the address book can be read without showing a dialog.
    private static var contactsAlreadyAuthorized: Bool {
        switch ContactSyncService.authorizationStatus {
        case .authorized, .limited: return true
        default: return false
        }
    }

    /// Contacts access is already granted, so the roster step can put people
    /// the user knows first without asking for anything.
    var canMatchContactsSilently: Bool {
        previewMode ? false : Self.contactsAlreadyAuthorized
    }

    /// Matches the address book against SPINE members for the roster step.
    /// `requestingPermission` is true only when the user tapped the prompt, so
    /// the OS dialog never appears unprompted (App Store guideline 5.1.1(v)).
    /// Contacts never leave the device; matching runs locally.
    ///
    /// Also fills `inviteCandidates`, so granting here means the invite step
    /// two screens later is already loaded and asks for nothing.
    func matchContactsForRoster(requestingPermission: Bool) async {
        guard !isMatchingContacts else { return }
        if previewMode {
            isMatchingContacts = true
            try? await Task.sleep(nanoseconds: 500_000_000)
            contactsGranted = true
            didAttemptContactMatch = true
            inviteCandidates = Self.previewContacts
            contactMatches = Self.previewContactMatches
            isMatchingContacts = false
            return
        }
        if !Self.contactsAlreadyAuthorized {
            guard requestingPermission else { return }
            let granted = await ContactSyncService.requestAccess()
            guard granted else {
                contactAccessDenied = true
                didAttemptContactMatch = true
                return
            }
        }
        contactsGranted = true
        isMatchingContacts = true
        defer {
            isMatchingContacts = false
            didAttemptContactMatch = true
        }
        let contacts = await ContactSyncService.fetchContacts()
        // 500, matching the invite step: a contact match found beyond the
        // roster's 300-reader display window still deserves to surface, and
        // MatchedMember carries its own User so it renders on its own.
        let readers = await userRepo.fetchAllReaderProfiles(excludingUid: uid, limit: 500)
        let result = ContactSyncService.match(contacts: contacts, readers: readers)
        contactMatches = result.onSpine.sorted {
            $0.user.displayName.localizedCaseInsensitiveCompare($1.user.displayName) == .orderedAscending
        }
        inviteCandidates = result.toInvite
    }

    /// Tells the people this user matched from their address book that someone
    /// they know just joined. Fires once, on leaving the roster step, so the
    /// user has already had their chance to follow (the server skips anyone
    /// they followed here). Best effort and fire-and-forget: this must never
    /// hold up the wizard.
    ///
    /// Only the matched SPINE uids are sent. The address book stays on device.
    private func announceJoinToMatchedContacts() {
        guard !previewMode, !contactMatches.isEmpty, !didAnnounceJoinToContacts else { return }
        didAnnounceJoinToContacts = true
        ContactSyncService.announceJoinToMatchedContacts(contactMatches)
    }

    // MARK: Contacts / invites

    /// Requests contacts access (OS dialog fires here and only here), then
    /// loads invite candidates. Contacts never leave the device; matching
    /// runs locally per ContactSyncService.
    func requestContactsAndLoadInvites() async -> Bool {
        if previewMode {
            contactsGranted = true
            inviteCandidates = Self.previewContacts
            return true
        }
        // The roster step already synced and matched: reuse that result rather
        // than re-scanning the address book two screens later.
        if contactsGranted, !inviteCandidates.isEmpty { return true }
        let granted = await ContactSyncService.requestAccess()
        guard granted else { return false }
        contactsGranted = true
        isLoadingContacts = true
        defer { isLoadingContacts = false }
        let contacts = await ContactSyncService.fetchContacts()
        let readers = await userRepo.fetchAllReaderProfiles(excludingUid: uid, limit: 500)
        let result = ContactSyncService.match(contacts: contacts, readers: readers)
        inviteCandidates = result.toInvite
        return true
    }

    // MARK: Notifications

    func finishNotificationsStep(enable: Bool) {
        if !previewMode {
            if enable {
                PushNotificationService.requestPermissionAndRegister()
            } else if let uid {
                PushNotificationNudgeStorage.snoozeOneMonth(uid: uid)
            }
            Task { try? await authService?.markPushNotificationPromptSeen() }
        }
        advance()
    }

    // MARK: Founder note / finish

    func markFounderNoteSeen() {
        guard !previewMode, let uid, let authService else { return }
        Task {
            try? await userRepo.markHasSeenFounderWelcomeModal(uid: uid)
            await authService.refreshAppUser()
        }
    }

    /// Ends the wizard. Both Goodreads buttons land here; the flags below stop
    /// MainTabView's legacy sheet chain from replaying any step.
    func finish() {
        if previewMode {
            // -uiPreviewOnboardingWizard runs loop back to the top for another pass.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                step = .intro
            }
            return
        }
        // Safety net: if the profile somehow never committed, releasing the
        // RootView latch would remount a fresh wizard (needsProfileCompletion
        // is still true) and lose everything typed. Recover at the commit step.
        if authService?.appUser?.needsProfileCompletion == true {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                step = .taste
            }
            return
        }
        if let uid {
            WelcomeSpinesGoodreadsPromptStorage.markShown(for: uid)
            OnboardingCurrentlyReadingPromptStorage.markShown(for: uid)
        }
        Self.justCompletedThisLaunch = true
        onFinished()
    }

    /// RootView's gate misdetected an existing, complete account (offline
    /// fallback user) and the real doc has now arrived: hand back to the app
    /// without writing anything. Only valid before any commit.
    func releaseForStaleGate() {
        guard !previewMode, !hasCommittedProfile else { return }
        onFinished()
    }

    // MARK: Card details

    /// The user's member number: how many accounts existed when they joined
    /// (the 50th account = card № 50). Fetched once at configure time.
    @Published private(set) var memberNumber: Int?

    func loadMemberNumberIfNeeded() {
        guard memberNumber == nil else { return }
        if previewMode {
            memberNumber = 47
            return
        }
        guard let joined = authService?.appUser?.joinedAt else { return }
        let repo = userRepo
        Task { [weak self] in
            let number = await repo.memberNumber(joinedAt: joined)
            await MainActor.run {
                guard let self, self.memberNumber == nil else { return }
                self.memberNumber = number
            }
        }
    }

    /// No zero padding: card № 50 reads "50". Falls back to the roster count
    /// when the aggregation hasn't landed (or failed).
    var cardNumber: Int {
        memberNumber ?? max(1, roster.count + 1)
    }

    /// Whether the account being stamped right now gets the OG badge. Reads the
    /// flag `ensureUserDocument` already wrote at account creation (before the
    /// wizard runs), NOT a live `cardNumber` comparison, so it can never
    /// disagree with what the card looks like later in Settings. Defaults to
    /// eligible in preview mode and before `appUser` loads.
    var isOGEligible: Bool {
        !(authService?.appUser?.ogIneligible ?? false)
    }

    var memberSinceText: String {
        let date = authService?.appUser?.joinedAt ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date).uppercased()
    }

    var goalYearText: String {
        let year = Calendar.current.component(.year, from: Date())
        guard readingGoal > 0 else { return "\(year): READING FREELY" }
        return "\(year) GOAL: \(readingGoal) BOOKS"
    }

    // MARK: Book characteristics

    /// "Type of book" chips for the characteristics step. Every entry is a real
    /// Tags.csv tag (Format / Pacing / Reading Experience / Tone), so picks feed
    /// the same taste profile as everything else, app-wide. Kept disjoint from
    /// the taste tree below so the two steps never re-offer the same chip.
    static let characteristicTags: [String] = [
        "Fiction", "Non-Fiction",
        "Fast-Paced", "Page Turner", "Binge-Worthy",
        "Easy Read", "Challenging Read", "Dense / Complex",
        "Thought-Provoking", "Mind-Bending",
        "Character-Driven", "Plot-Driven",
        "Comfort Read", "Relaxing Read", "Cozy", "Wholesome",
        "Emotional Rollercoaster", "Tearjerker",
        "Funny", "Lighthearted", "Hopeful", "Dark",
    ]

    static let characteristicTagSet = Set(characteristicTags)

    // MARK: Taste tree

    /// Two-tier progressive disclosure over the real Tags.csv catalog: roots are
    /// the Genre section; children are curated, whitelisted tags from the other
    /// sections that sharpen Discover the most for that genre.
    static let tasteTree: [(root: String, children: [String])] = [
        ("Mystery & Thriller", ["Psychological Thriller", "Cozy Mystery", "Crime & Detective", "Spy & Espionage", "Legal Thriller", "True Crime", "Mystery / Investigation", "Suspenseful", "Political", "Heist", "Revenge", "Intense"]),
        ("Sci-Fi & Fantasy", ["Epic Fantasy", "Urban Fantasy", "Cozy Fantasy", "Romantasy", "Space Opera", "Time Travel", "Mythology & Retellings", "Magical World", "Space", "Dystopian", "Post-Apocalyptic", "Alternate History", "Quest / Journey"]),
        ("Romance", ["Romantasy", "Contemporary Romance", "Historical Romance", "Dark Romance", "Romantic Comedy", "Sports Romance", "Paranormal Romance", "Small Town Romance", "Enemies to Lovers", "Friends to Lovers", "Fake Dating", "Grumpy / Sunshine", "Forced Proximity", "Second Chance", "Forbidden Love", "Love Triangle", "Slow Burn", "Love Story", "Emotional"]),
        ("Horror", ["Psychological Horror", "Gothic", "Ghost Story", "Supernatural", "Suspenseful", "Gritty", "Intense", "Post-Apocalyptic"]),
        ("Historical", ["World War II", "Regency Era", "Ancient World", "Wild West", "War Story", "Medieval", "Political", "Alternate History", "Survival", "Tragedy"]),
        ("Literary Fiction", ["Coming of Age", "Identity", "Morality", "Society", "Contemporary", "Tragedy", "Redemption"]),
        ("Young Adult", ["School / Academy", "Coming of Age", "Found Family", "Strong Female Lead", "Love Triangle", "Dystopian", "Magical World"]),
        ("Classics", ["Tragedy", "Ancient World", "Medieval", "Regency Era", "Morality", "Society", "War Story"]),
        ("Graphic Novels & Comics", ["Manga", "Superhero", "Coming of Age", "Supernatural", "Dystopian"]),
        ("Poetry", ["Love", "Death", "Identity", "Freedom", "Emotional", "Grief"]),
        ("Humor", ["Satire", "Romantic Comedy", "Ensemble Cast", "Small Town", "Contemporary"]),
        ("Biography & Memoir", ["Inspiring", "History", "Leadership", "Philosophy", "Creativity", "Survival"]),
        ("Self-Improvement", ["Habits", "Productivity", "Health & Fitness", "Relationships", "Mental Health", "Spirituality"]),
        ("Business", ["Startups", "Leadership", "Finance", "Productivity", "Creativity"]),
        ("Psychology", ["Neuroscience", "Mental Health", "Human Nature", "Relationships", "Philosophy"]),
        ("Science", ["Neuroscience", "Technology", "Space", "History", "Informative"]),
        ("Politics & Society", ["Political", "Justice", "Power", "Freedom", "Society", "War Story", "Dystopian"]),
        ("Technology & Future", ["Technology", "Futuristic", "Space", "Startups", "Dystopian"]),
        ("Travel & Adventure", ["Survival", "Quest / Journey", "Wild West", "Ancient World", "Solo Protagonist"]),
        ("Sports", ["Sports Romance", "Rivalry", "Inspiring", "Mentor / Student", "Solo Protagonist"]),
    ]

    static let tasteTreeTagSet: Set<String> =
        Set(tasteTree.map(\.root) + tasteTree.flatMap(\.children))

    // MARK: Preview fixtures

    static let previewRoster: [RosterEntry] = {
        func entry(_ uid: String, _ first: String, _ last: String, _ handle: String, _ books: Int, _ tags: [String], following: [String] = []) -> RosterEntry {
            var user = User.demo
            user.firstName = first
            user.lastName = last
            user.displayName = "\(first) \(last)"
            user.username = handle
            user.totalBooksRead = books
            user.profileImageURL = nil
            user.readingInterestTags = tags
            user.following = following
            return RosterEntry(uid: uid, user: user)
        }
        // A small follow graph so the mutuals step has something to show in
        // -uiPreviewOnboardingWizard: follow Maya or Sam on the roster step.
        return [
            entry("preview-1", "Maya", "Chen", "maya", 23,
                  ["Fiction", "Fast-Paced", "Page Turner", "Mystery & Thriller", "Suspenseful", "Thought-Provoking"],
                  following: ["preview-4", "preview-5", "preview-6"]),
            entry("preview-2", "Sam", "Rivera", "samreads", 11,
                  ["Non-Fiction", "Thought-Provoking", "Psychology", "Neuroscience"],
                  following: ["preview-3", "preview-5"]),
            entry("preview-3", "Priya", "Patel", "priya", 4,
                  ["Romance", "Cozy", "Wholesome", "Comfort Read"]),
            entry("preview-4", "Jordan", "Lee", "jlee", 17,
                  ["Fiction", "Funny", "Sci-Fi & Fantasy", "Magical World"]),
            entry("preview-5", "Emma", "Walsh", "emmareads", 44,
                  ["Fiction", "Page Turner", "Historical", "War Story", "Emotional Rollercoaster"],
                  following: ["preview-1"]),
            entry("preview-6", "Cole", "Bennett", "cole", 8, []),
        ]
    }()

    static let previewContacts: [SyncedContact] = [
        SyncedContact(id: "c1", displayName: "Alex Morgan", phoneNumbers: ["5125550141"], matchKeys: []),
        SyncedContact(id: "c2", displayName: "Katie B.", phoneNumbers: ["7375550188"], matchKeys: []),
        SyncedContact(id: "c3", displayName: "Dad", phoneNumbers: ["2145550107"], matchKeys: []),
    ]

    /// Demo "already on SPINE" contact matches for -uiPreviewOnboardingWizard.
    /// The second one keeps a different address-book name on purpose, so the
    /// "In your contacts as ..." line has something to render.
    static let previewContactMatches: [MatchedMember] = {
        let entries = previewRoster.prefix(2)
        let contacts = [
            SyncedContact(id: "m1", displayName: entries.first?.user.displayName ?? "Maya Chen",
                          phoneNumbers: ["5125550141"], matchKeys: []),
            SyncedContact(id: "m2", displayName: "Katie B.",
                          phoneNumbers: ["7375550188"], matchKeys: []),
        ]
        return zip(entries, contacts).map { entry, contact in
            MatchedMember(uid: entry.uid, user: entry.user, contact: contact)
        }
    }()
}

// MARK: - Haptics

/// Subtle, consistent haptics for the wizard. Selection ticks for picking
/// things, a light tap for step changes, success for milestone moments.
enum WizardHaptics {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func step() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.75)
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - Container

struct OnboardingWizardView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appState: AppState
    @StateObject private var model: OnboardingWizardModel

    init(previewMode: Bool = false, onFinished: @escaping () -> Void) {
        _model = StateObject(wrappedValue: OnboardingWizardModel(previewMode: previewMode, onFinished: onFinished))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.configure(authService: authService, appState: appState) }
        .onChange(of: authService.appUser) { _, newUser in
            // Offline cold starts can gate an existing, complete account into
            // the wizard via AuthService's 10s fallback user. When the real
            // doc lands (needsProfileCompletion == false) before anything was
            // committed, hand straight back to the app.
            guard let user = newUser, !user.needsProfileCompletion else { return }
            model.releaseForStaleGate()
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(model.step.showsBack ? 1 : 0)
            .disabled(!model.step.showsBack || model.isCommittingProfile)
            .accessibilityLabel("Back")

            Spacer()
            ShelfProgressMeter(filled: model.step.spineCount)
            Spacer()

            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 12)
        .animation(.easeInOut(duration: 0.25), value: model.step.showsBack)
    }

    @ViewBuilder
    private var stepContent: some View {
        Group {
            switch model.step {
            case .intro:
                WizardInterstitialView(
                    headline: "Let's fill out your library card.",
                    onContinue: { model.advance() }
                )
            case .name:
                WizardNameStep(model: model)
            case .greet:
                WizardInterstitialView(
                    headline: "Pleasure to meet you, \(model.displayFirstName).",
                    subline: "Now let's make it official.",
                    onContinue: { model.advance() }
                )
            case .handle:
                WizardHandleStep(model: model)
            case .photo:
                WizardPhotoStep(model: model)
            case .goal:
                WizardGoalStep(model: model)
            case .characteristics:
                WizardCharacteristicsStep(model: model)
            case .taste:
                WizardTasteStep(model: model)
            case .reading:
                WizardReadingStep(model: model)
            case .phone:
                WizardPhoneStep(model: model)
            case .contacts:
                WizardContactsSyncStep(model: model)
            case .roster:
                WizardRosterStep(model: model)
            case .mutuals:
                WizardMutualsStep(model: model)
            case .invite:
                WizardInviteStep(model: model)
            case .notifications:
                WizardNotificationsStep(model: model)
            case .appearance:
                WizardAppearanceStep(model: model)
            case .stamping:
                WizardInterstitialView(
                    headline: "Hold still. We're stamping your card…",
                    autoAdvanceAfter: 0.9,
                    onContinue: { model.advance() }
                )
            case .card:
                WizardCardStep(model: model)
            case .founderNote:
                WizardFounderNoteStep(model: model)
            case .tiers:
                WizardTierListStep(model: model)
            case .tierPractice:
                WizardTierPracticeStep(model: model)
            case .goodreads:
                WizardGoodreadsStep(model: model)
            }
        }
        .id(model.step)
        .transition(.wizardStep)
    }
}

extension AnyTransition {
    /// Incoming step rises and fades in; outgoing fades away in place.
    /// The outgoing view must stop hit testing the moment removal starts:
    /// it lingers on top for the full spring settle (~1.2s) and would
    /// otherwise swallow every tap aimed at the incoming step.
    static var wizardStep: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: WizardStepTransitionModifier(offset: 26, opacity: 0),
                identity: WizardStepTransitionModifier(offset: 0, opacity: 1)
            ),
            removal: .modifier(
                active: WizardStepRemovalModifier(opacity: 0),
                identity: WizardStepRemovalModifier(opacity: 1)
            )
        )
    }
}

private struct WizardStepTransitionModifier: ViewModifier {
    let offset: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.offset(y: offset).opacity(opacity)
    }
}

private struct WizardStepRemovalModifier: ViewModifier {
    let opacity: Double
    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .allowsHitTesting(opacity >= 1)
    }
}

// MARK: - Shelf progress meter

struct ShelfProgressMeter: View {
    let filled: Int
    static let totalSlots = 13

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<Self.totalSlots, id: \.self) { index in
                    UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                        .fill(index < filled ? Theme.textPrimary : Theme.textPrimary.opacity(0.14))
                        .frame(width: index.isMultiple(of: 3) ? 5.5 : 7, height: spineHeight(index))
                        .offset(y: 0)
                        .transaction { txn in
                            if reduceMotion { txn.animation = nil }
                        }
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: filled)
            Rectangle()
                .fill(Theme.textPrimary)
                .frame(width: 130, height: 2)
                .clipShape(Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(min(filled + 1, Self.totalSlots)) of \(Self.totalSlots)")
    }

    private func spineHeight(_ index: Int) -> CGFloat {
        switch index % 3 {
        case 0: return 17
        case 1: return 13
        default: return 19
        }
    }
}

// MARK: - Interstitial (typed headline + optional subline, tap to continue)

struct WizardInterstitialView: View {
    let headline: String
    var subline: String? = nil
    /// When set, continues automatically this long after typing finishes
    /// (the "stamping" beat). Tap still works.
    var autoAdvanceAfter: Double? = nil
    /// Must report whether navigation actually happened; a rejected attempt
    /// (model debounce) must not consume the one-shot latch below.
    let onContinue: () -> Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var headlineDone = false
    @State private var sublineDone = false
    @State private var fastForward = 0
    @State private var hintPulsing = false
    /// One-shot: a transitioning-out interstitial is still hit-testable, and the
    /// stamping timer can race a tap. Each instance may only continue once.
    @State private var continued = false

    private var allDone: Bool { headlineDone && (subline == nil || sublineDone) }

    private func continueOnce() {
        guard !continued else { return }
        continued = onContinue()
    }

    var body: some View {
        ZStack {
            VStack(spacing: 14) {
                TypewriterText(
                    text: headline,
                    font: .system(size: 32, weight: .bold),
                    centered: true,
                    fastForwardTrigger: fastForward,
                    onFinished: { headlineDone = true }
                )
                if let subline {
                    TypewriterText(
                        text: subline,
                        font: .system(size: 16, weight: .regular),
                        textColor: Theme.textSecondary,
                        centered: true,
                        wordInterval: 0.09,
                        startDelay: 0.25,
                        isActive: headlineDone,
                        fastForwardTrigger: fastForward,
                        onFinished: { sublineDone = true }
                    )
                }
            }
            .padding(.horizontal, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if autoAdvanceAfter == nil {
                VStack {
                    Spacer()
                    Text("tap to continue")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(2.4)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.textTertiary)
                        .opacity(allDone ? (hintPulsing && !reduceMotion ? 0.4 : 0.9) : 0)
                        .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true), value: hintPulsing)
                        .padding(.bottom, 28)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if allDone {
                continueOnce()
            } else {
                fastForward += 1
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headline + (subline.map { " " + $0 } ?? ""))
        .accessibilityHint(autoAdvanceAfter == nil ? "Double tap to continue" : "")
        .accessibilityAddTraits(.isButton)
        .onChange(of: allDone) { _, done in
            guard done else { return }
            hintPulsing = true
            if let delay = autoAdvanceAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.2 : delay)) {
                    continueOnce()
                }
            }
        }
    }
}

// MARK: - Shared buttons

/// Primary CTA: the app's full-width ink capsule (`SpineButtonStyle`).
struct WizardCTAButton: View {
    let title: String
    var enabled: Bool = true
    var showsProgress: Bool = false
    /// Optional SF Symbol shown ahead of the title (hidden while progressing).
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if showsProgress {
                    ProgressView().tint(Theme.onChrome)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
        }
        .buttonStyle(.spinePrimary)
        .disabled(!enabled || showsProgress)
    }
}

/// Secondary choice with equal visual weight to the CTA (used where the App
/// Store guidelines require the skip to be a real button, e.g. contacts).
struct WizardSecondaryButton: View {
    let title: String
    /// Optional SF Symbol shown ahead of the title.
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
        }
        .buttonStyle(.spineSecondary)
    }
}

/// Quiet text-only skip.
struct WizardGhostButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                // Every wizard skip is deliberately quiet: it has to be present
                // (App Store 5.1.1(v) for the phone and contacts steps) but must
                // not compete with the real CTA above it. Dimming the label only,
                // never the tap target, keeps the 44pt hit area intact.
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
        .buttonStyle(.spine(.tertiary, size: .regular))
    }
}

/// Ink stamp entrance: oversized and tilted, thunks down into place.
struct WizardStampModifier: ViewModifier {
    var restRotation: Double = -3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false

    func body(content: Content) -> some View {
        content
            // 1.45 (not bigger): the entrance must not overrun a clipping
            // ScrollView edge, which visibly sliced the AVAILABLE badge at 1.8.
            .scaleEffect(landed || reduceMotion ? 1 : 1.45)
            .rotationEffect(.degrees(landed || reduceMotion ? restRotation : restRotation - 7))
            .opacity(landed || reduceMotion ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) {
                    landed = true
                }
            }
    }
}

extension View {
    func wizardStamp(restRotation: Double = -3) -> some View {
        modifier(WizardStampModifier(restRotation: restRotation))
    }
}
