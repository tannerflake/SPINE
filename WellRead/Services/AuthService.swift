//
//  AuthService.swift
//  WellRead
//
//  Firebase Auth: state listener, Apple/Google sign-in, sign-out.
//

import Foundation
import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseFunctions
import FirebaseMessaging
import AuthenticationServices
import CryptoKit
import GoogleSignIn

@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var firebaseUser: FirebaseAuth.User?
    @Published private(set) var appUser: User?
    @Published private(set) var isLoading = true
    @Published var authError: String?

    private var authStateListener: AuthStateDidChangeListenerHandle?
    private var currentNonce: String?
    private var googleSignInAttempt = 0
    private let userRepo: UserRepository

    init(userRepository: UserRepository = UserRepository()) {
        self.userRepo = userRepository
        self.firebaseUser = Auth.auth().currentUser
        isLoading = true
        authStateListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.firebaseUser = user
                self?.isLoading = false
                Analytics.updateOptOut(
                    uid: user?.uid,
                    email: user?.email,
                    displayName: user?.displayName
                )
                if let user = user {
                    await self?.loadOrCreateAppUser(firebaseUser: user)
                } else {
                    self?.appUser = nil
                }
            }
        }
    }

    deinit {
        if let handle = authStateListener {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    /// Loads the Firestore user document, or builds a minimal User from Firebase Auth so the app never sticks on loading (e.g. offline or slow network).
    private func loadOrCreateAppUser(firebaseUser user: FirebaseAuth.User) async {
        let uid = user.uid
        let fallbackUser = User(
            id: UUID(),
            username: user.email?.components(separatedBy: "@").first ?? "user_\(String(uid.prefix(8)))",
            displayName: user.displayName?.isEmpty == false ? user.displayName! : (user.email ?? "User"),
            firstName: nil,
            lastName: nil,
            profileSetupCompleted: false,
            bio: nil,
            profileImageURL: user.photoURL?.absoluteString,
            joinedAt: Date(),
            following: [],
            hasSeenFounderWelcomeModal: false,
            hasSeenPushNotificationPrompt: true,
            totalBooksRead: 0,
            totalPagesRead: 0,
            readingGoal: nil,
            readingInterestTags: []
        )
        let fromFirestore: User? = await withTaskGroup(of: User?.self) { group in
            group.addTask {
                await self.userRepo.ensureUserDocument(
                    uid: uid,
                    displayName: user.displayName,
                    email: user.email,
                    photoURL: user.photoURL?.absoluteString
                )
                return await self.userRepo.getUser(uid: uid)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s timeout
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
        self.appUser = fromFirestore ?? fallbackUser
        /// FCM may have delivered a registration token before `Auth` had a uid; `persistFCMTokenToFirestore` skipped. Re-fetch and save now.
        PushNotificationService.syncFCMTokenToFirestoreIfSignedIn()
    }

    /// Refreshes appUser from Firestore (e.g. after profile photo upload). Call from MainActor.
    func refreshAppUser() async {
        guard let uid = firebaseUser?.uid else { return }
        if let user = await userRepo.getUser(uid: uid) {
            self.appUser = user
        }
    }

    /// Whether a handle is free for the current account (excluding their own doc).
    func isUsernameAvailable(_ handle: String) async -> Bool {
        guard let uid = firebaseUser?.uid else { return false }
        return await userRepo.isUsernameAvailable(handle, excludingUid: uid)
    }

    /// Detailed outcome for UI (don’t show “taken” on permission errors).
    func checkUsernameAvailability(_ handle: String) async -> HandleAvailabilityCheck {
        guard let uid = firebaseUser?.uid else {
            return .failed(underlying: NSError(domain: "AuthService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not signed in."]))
        }
        return await userRepo.checkUsernameAvailability(handle, excludingUid: uid)
    }

    /// Saves first name, last name, handle, and optional yearly book count after SSO (or from Edit profile); marks profile setup complete.
    func completeProfileSetup(firstName: String, lastName: String, handle: String, readingGoal: Int?, readingInterestTags: [String]? = nil, enforceMinimumReadingInterestTags: Bool = true) async throws {
        guard let uid = firebaseUser?.uid else {
            throw NSError(domain: "AuthService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not signed in."])
        }
        try await userRepo.completeProfileSetup(uid: uid, firstName: firstName, lastName: lastName, handle: handle, readingGoal: readingGoal, readingInterestTags: readingInterestTags, enforceMinimumReadingInterestTags: enforceMinimumReadingInterestTags)
        await refreshAppUser()
    }

    /// Marks the post-onboarding push prompt as completed (`hasSeenPushNotificationPrompt` in Firestore).
    func markPushNotificationPromptSeen() async throws {
        guard let uid = firebaseUser?.uid else { return }
        try await userRepo.markHasSeenPushNotificationPrompt(uid: uid)
        await refreshAppUser()
    }

    // MARK: - Apple Sign-In (nonce required)

    /// Call from SignInWithAppleButton onRequest: configures nonce and scopes on the request.
    func makeAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
    }

    func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) async {
        authError = nil
        switch result {
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let idTokenData = appleIDCredential.identityToken,
                  let idTokenString = String(data: idTokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                authError = "Apple sign-in: missing token or nonce."
                return
            }
            currentNonce = nil
            let credential = OAuthProvider.appleCredential(
                withIDToken: idTokenString,
                rawNonce: nonce,
                fullName: appleIDCredential.fullName
            )
            do {
                _ = try await Auth.auth().signIn(with: credential)
                if let u = Auth.auth().currentUser {
                    await loadOrCreateAppUser(firebaseUser: u)
                }
            } catch {
                authError = error.localizedDescription
            }
        case .failure(let error):
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                authError = error.localizedDescription
            }
        }
    }

    // MARK: - Google Sign-In

    func signInWithGoogle(presentingViewController: UIViewController) async {
        authError = nil
        let clientID = FirebaseApp.app()?.options.clientID
            ?? Self.clientIDFromGoogleServicePlist()
        guard let clientID else {
            authError = "Google Sign-In needs CLIENT_ID. In Firebase Console, re-download GoogleService-Info.plist for your iOS app (with Google Sign-In enabled)."
            return
        }
        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config
        // The SDK can lose a session's callback (google/GoogleSignIn-iOS#378); a
        // retry replaces the hung flow inside GIDSignIn, which then fails the old
        // one with a spurious "user canceled" while the new sheet is on screen.
        // Tag attempts so a superseded flow can't touch UI state.
        googleSignInAttempt += 1
        let attempt = googleSignInAttempt
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController, hint: nil, additionalScopes: nil)
            guard attempt == googleSignInAttempt else { return }
            guard let idToken = result.user.idToken?.tokenString else {
                authError = "Google sign-in: no ID token."
                return
            }
            let accessToken = result.user.accessToken.tokenString
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
            _ = try await Auth.auth().signIn(with: credential)
            if let u = Auth.auth().currentUser {
                await loadOrCreateAppUser(firebaseUser: u)
            }
        } catch {
            guard attempt == googleSignInAttempt else { return }
            let nsError = error as NSError
            // Cancel is a user action, not an error (same treatment as the Apple path).
            if nsError.domain == kGIDSignInErrorDomain, nsError.code == GIDSignInError.canceled.rawValue {
                return
            }
            authError = error.localizedDescription
        }
    }

    // MARK: - Reviewer (Email/Password) Sign-In
    /// Hidden path for App Review. Loads Firestore user immediately so profile completion runs (same as Apple/Google).

    func signInWithEmail(_ email: String, password: String) async throws {
        authError = nil
        _ = try await Auth.auth().signIn(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        if let u = Auth.auth().currentUser {
            await loadOrCreateAppUser(firebaseUser: u)
        }
    }

    /// Creates a fresh email/password account (reviewer flow) and signs it in.
    /// The new user then lands in the normal profile-completion onboarding.
    func createAccountWithEmail(_ email: String, password: String) async throws {
        authError = nil
        _ = try await Auth.auth().createUser(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        if let u = Auth.auth().currentUser {
            await loadOrCreateAppUser(firebaseUser: u)
        }
    }

    /// Hidden welcome-screen login: tap book icon 5×. Uses `TEST_ACCOUNT_EMAIL` / `TEST_ACCOUNT_PASSWORD` from Secrets.plist.
    func signInWithConfiguredTestAccount() async {
        authError = nil
        guard let creds = ApiKeys.testAccountCredentials else {
            authError = "Test account not configured. Add TEST_ACCOUNT_EMAIL and TEST_ACCOUNT_PASSWORD to Secrets.plist (see Secrets.example.plist)."
            return
        }
        do {
            try await signInWithEmail(creds.email, password: creds.password)
        } catch {
            authError = error.localizedDescription
        }
    }

    // MARK: - Account Deletion (App Store guideline 5.1.1(v))

    /// Permanently deletes the signed-in account. Server-side (`deleteAccount`
    /// callable) removes all Firestore data and the Auth user — the Admin SDK
    /// path avoids Firebase's requires-recent-login error on `user.delete()`.
    /// Throws so the UI can show the failure and let the user retry.
    func deleteAccount() async throws {
        guard let user = firebaseUser else {
            throw NSError(domain: "AuthService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not signed in."])
        }

        // Sign in with Apple accounts: revoke the Apple token so SPINE stops
        // appearing under the user's Apple ID sign-ins (required by Apple when
        // deleting SIWA accounts). Needs a fresh Apple authorization; if the
        // user cancels that sheet, deletion still proceeds.
        if user.providerData.contains(where: { $0.providerID == "apple.com" }) {
            if let code = await AppleReauthorizationController.requestAuthorizationCode() {
                try? await Auth.auth().revokeToken(withAuthorizationCode: code)
            }
        }

        _ = try await Functions.functions(region: "us-central1")
            .httpsCallable("deleteAccount")
            .call([:])

        // The Auth user is gone server-side; clear the local session so the
        // auth listener flips the app back to the welcome screen.
        authError = nil
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
        try? await Messaging.messaging().deleteToken()
    }

    // MARK: - Sign Out

    func signOut() {
        authError = nil
        let uid = firebaseUser?.uid
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
        } catch {
            authError = error.localizedDescription
        }
        Task {
            if let uid {
                if let token = try? await Messaging.messaging().token() {
                    try? await userRepo.removeFCMToken(uid: uid, token: token)
                }
            }
            try? await Messaging.messaging().deleteToken()
        }
    }

    // MARK: - Nonce Helpers

    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if errorCode != errSecSuccess {
            fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
        }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return randomBytes.map { byte in String(charset[Int(byte) % charset.count]) }.joined()
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Reads CLIENT_ID from Firebase config plist in the app bundle (for Google Sign-In).
    /// Checks GoogleService-Info.plist first, then WellRead Firebase Service Info.plist.
    private static func clientIDFromGoogleServicePlist() -> String? {
        let names = ["GoogleService-Info", "WellRead Firebase Service Info"]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "plist"),
                  let plist = NSDictionary(contentsOf: url) as? [String: Any],
                  let clientID = plist["CLIENT_ID"] as? String else { continue }
            return clientID
        }
        return nil
    }
}

/// Runs a bare Sign in with Apple request during account deletion to obtain a
/// fresh authorization code for `Auth.revokeToken(withAuthorizationCode:)`.
/// Resolves to nil on cancel or error — callers treat revocation as best-effort.
@MainActor
private final class AppleReauthorizationController: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    /// Keeps the delegate alive for the duration of the authorization flow.
    private static var active: AppleReauthorizationController?
    private var continuation: CheckedContinuation<String?, Never>?

    static func requestAuthorizationCode() async -> String? {
        await withCheckedContinuation { continuation in
            let helper = AppleReauthorizationController()
            helper.continuation = continuation
            active = helper
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = []
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = helper
            controller.presentationContextProvider = helper
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let code = (authorization.credential as? ASAuthorizationAppleIDCredential)
            .flatMap(\.authorizationCode)
            .flatMap { String(data: $0, encoding: .utf8) }
        finish(code)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(nil)
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private func finish(_ code: String?) {
        continuation?.resume(returning: code)
        continuation = nil
        Self.active = nil
    }
}
