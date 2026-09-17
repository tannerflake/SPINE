Goal: Implement real Firebase Auth using Google SSO + Apple SSO in the SPINE iOS app. Console config is done. Xcode config is done (Google URL scheme added, Sign in with Apple capability added). Now implement app code.

Context:
- Firebase already integrated and GoogleService-Info.plist updated (has CLIENT_ID + REVERSED_CLIENT_ID).
- Xcode URL Types includes REVERSED_CLIENT_ID scheme.
- Firebase Auth providers enabled: Google and Apple.
- Apple provider configured in Firebase with Services ID com.wellread.app.service, Team ID T32N9X64JM, Key ID GQM5BPUS7M, private key uploaded.

Deliverables:
1) Add/verify dependencies
- Swift Package Manager: FirebaseAuth, FirebaseCore, FirebaseFirestore (for later user doc), GoogleSignIn (GoogleSignIn or GoogleSignInSwift), AuthenticationServices is system framework.
- Ensure FirebaseApp.configure() runs once at app launch (App struct init or AppDelegate adaptor).

2) Create AuthService (ObservableObject)
- Owns Firebase Auth state listener (addStateDidChangeListener).
- Publishes firebaseUser (FirebaseAuth.User?) and isLoading.
- Exposes methods:
  - signInWithApple(result from ASAuthorization)
  - signInWithGoogle(presentingViewController)
  - signOut()
- On successful sign in, call userRepo.ensureUserDocument(uid:) (stub if Phase 4 not implemented yet).

AuthService skeleton behavior:
- init: set isLoading = true, addStateDidChangeListener -> update firebaseUser and isLoading.
- signOut: Auth.auth().signOut(); clear any cached user model.

3) Implement Apple sign in with nonce (required)
- Add nonce helpers (randomNonceString + sha256).
- When user taps Apple button:
  - Build ASAuthorizationAppleIDRequest with requestedScopes [.fullName, .email]
  - Generate nonce, store currentNonce, set request.nonce = sha256(nonce)
- On completion:
  - Extract identityToken and nonce, create Firebase credential:
    OAuthProvider.appleCredential(withIDToken: idTokenString, rawNonce: nonce, fullName: appleIDCredential.fullName)
  - Sign in: try await Auth.auth().signIn(with: credential)
- Apple note: display name only available first sign in; passing fullName is important.

4) Implement Google sign in (modern iOS)
- Use GoogleSignIn SDK.
- Get clientID from Firebase config:
  let clientID = FirebaseApp.app()?.options.clientID
- Configure:
  let config = GIDConfiguration(clientID: clientID)
- Present sign in:
  let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingVC, hint: nil, additionalScopes: nil)
  let idToken = result.user.idToken?.tokenString
  let accessToken = result.user.accessToken.tokenString
  Create Firebase credential:
    let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
  Sign in:
    try await Auth.auth().signIn(with: credential)

Also ensure the app can present a UIViewController from SwiftUI:
- Provide a helper to fetch topmost UIViewController or use UIApplication.shared.connectedScenes to get keyWindow.rootViewController.

5) Wire RootView
- Replace any demo isAuthenticated flag.
- Use @StateObject AuthService in RootView or App container.
- UI routing:
  - if auth.isLoading: show ProgressView
  - else if auth.firebaseUser == nil: show Onboarding/Login
  - else: show MainTabView
- Sign out button calls auth.signOut() and the listener should route back to onboarding automatically.

6) Wire Onboarding UI
- Provide two buttons:
  - Sign in with Apple: SignInWithAppleButton that calls auth.makeAppleRequest and auth.handleAppleCompletion
  - Continue with Google: a button that calls auth.signInWithGoogle(presentingVC)
- Show auth error message if present.

7) AppDelegate / URL handling
- For Google Sign In, with the new SDK and URL scheme in Info, most cases work automatically, but add URL handling if needed:
  - If app uses UIApplicationDelegateAdaptor, implement application(_:open:options:) and return GIDSignIn.sharedInstance.handle(url) when appropriate.
  - If purely SwiftUI, use .onOpenURL { url in GIDSignIn.sharedInstance.handle(url) }.
- Make sure this does not break other deep links.

8) Testing checklist
- Google sign in returns to app and Auth.auth().currentUser is non-nil.
- Apple sign in works and updates Auth state.
- Sign out returns to onboarding.
- Re-launch app restores signed-in session (listener sees existing user).

Implementation notes:
- Keep exactly one auth state listener, owned by AuthService, not per-view.
- Use async/await variants where available.
- Do not require email/password anywhere.