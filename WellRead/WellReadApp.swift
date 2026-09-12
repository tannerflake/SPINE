//
//  WellReadApp.swift
//  WellRead
//
//  Book tracking platform — modern, minimal, paper-light.
//

import SwiftUI
import AmplitudeSwift
import AmplitudeSwiftSessionReplayPlugin
import FirebaseCore
import GoogleSignIn
import FirebaseFirestore
import FirebaseMessaging
import UserNotifications

/// Product analytics (Amplitude). Initialized exactly once, at app launch.
/// `nil` when no key is configured — call sites use optional chaining, so
/// analytics silently no-op instead of crashing.
enum Analytics {
    /// Persisted opt-out for internal accounts. Auth state resolves a beat after
    /// launch, so without a remembered answer the founder's session-start and
    /// screen-view autocaptures would land before `updateOptOut` could run. The
    /// flag is written once he signs in and honored from the next launch onward.
    private static let optOutDefaultsKey = "analyticsOptedOut"

    static let amplitude: Amplitude? = {
        guard let key = ApiKeys.amplitude else {
            print("Amplitude API key missing, analytics disabled")
            return nil
        }
        let client = Amplitude(configuration: Configuration(
            apiKey: key,
            autocapture: [.sessions, .appLifecycles, .screenViews]
        ))
        // Session Replay. `.medium` masking blanks every editable field, so
        // sign-in email/password and search text never reach a recording;
        // titles, reviews, and member names stay visible. Replays count against
        // the plan's monthly quota, so lower `sampleRate` to record only a
        // fraction of sessions.
        //
        // `enableRemoteConfig: false` keeps these values authoritative. The
        // Amplitude project's server-side config caps iOS capture at 3% (it is
        // tuned for the web app sharing this project) and would otherwise
        // silently override both settings.
        client.add(plugin: AmplitudeSwiftSessionReplayPlugin(
            sampleRate: 1.0,
            maskLevel: .medium,
            enableRemoteConfig: false
        ))
        client.optOut = UserDefaults.standard.bool(forKey: optOutDefaultsKey)
        return client
    }()

    /// Called whenever Firebase Auth state resolves. Internal accounts (the
    /// founder's own logins, test/App Review logins) are opted out of analytics
    /// entirely: no events and, since the replay plugin observes `optOut`, no
    /// session recordings either. Their traffic would otherwise skew every
    /// product metric on a base of a few hundred real members.
    ///
    /// Signed out we keep the last answer rather than resetting: a device that
    /// was opted out stays opted out until a non-internal account signs in.
    static func updateOptOut(uid: String?, email: String?, displayName: String?) {
        guard let uid else { return }
        let optOut = uid == SpineFounder.uid
            || TestAccountSignatures.matches(email: email, displayName: displayName)
        UserDefaults.standard.set(optOut, forKey: optOutDefaultsKey)
        amplitude?.optOut = optOut
    }
}

/// Use the same Firestore database everywhere.
/// - `Info.plist` key `FirestoreDatabaseID`: **empty** or omit → `(default)` database (Firebase Console “default” rules apply).
/// - Non-empty (e.g. `wellread`) → named database; you **must** publish `firestore.rules` to that exact database in Console.
enum FirestoreDatabase {
    static let databaseID: String? = {
        #if DEBUG
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "FirestoreDatabaseID") as? String else {
            print("FirestoreDatabaseID raw value: nil (key missing)")
            return nil
        }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        print("FirestoreDatabaseID raw value: [\(raw)]")
        print("FirestoreDatabaseID trimmed value: [\(t)]")
        return t.isEmpty ? nil : t
        #else
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "FirestoreDatabaseID") as? String else {
            return nil
        }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
        #endif
    }()

    static var firestore: Firestore {
        if let id = databaseID {
            #if DEBUG
            print("Firestore: using named database [\(id)]")
            #endif
            return Firestore.firestore(database: id)
        }
        #if DEBUG
        print("Firestore: using (default) database")
        #endif
        return Firestore.firestore()
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FirebaseApp.configure()
        _ = Analytics.amplitude
        let db = FirestoreDatabase.firestore
        db.settings.cacheSettings = PersistentCacheSettings(sizeBytes: 50 * 1024 * 1024 as NSNumber)
        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        // `-uiPreviewPushTap <type>[:<id>[:<commentId>]]` simulates a push tap at
        // launch (before the UI mounts — the cold-start path) for simulator
        // verification, e.g. `-uiPreviewPushTap new_follower:<uid>`,
        // `-uiPreviewPushTap review_liked:<postId>`, or
        // `-uiPreviewPushTap comment_replied:<postId>:<commentId>`.
        if let raw = UserDefaults.standard.string(forKey: "uiPreviewPushTap") {
            let parts = raw.split(separator: ":", maxSplits: 2).map(String.init)
            var userInfo: [AnyHashable: Any] = ["type": parts[0]]
            if parts.count > 1 {
                let profileTypes = ["new_follower", "contact_joined"]
                userInfo[profileTypes.contains(parts[0]) ? "followerId" : "postId"] = parts[1]
            }
            if parts.count > 2 {
                userInfo["commentId"] = parts[2]
            }
            PushNotificationService.handleRemoteNotificationTap(userInfo: userInfo)
        }
        #endif
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
        PushRegistrationDiagnostics.setAPNsDeviceToken(deviceToken)
        Task { @MainActor in
            PushRegistrationDiagnostics.shared.apnsRegistrationError = nil
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushRegistrationDiagnostics.setAPNsRegistrationFailed(error)
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        PushRegistrationDiagnostics.setFCMToken(token)
        PushNotificationService.persistFCMTokenToFirestore(token)
    }

    /// Silent (content-available) pushes land here. `blend_request_withdrawn`
    /// means the requester undid a Book Blend request — remove the now-stale
    /// invite alert from Notification Center.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if WellreadDeepLink.pushNotificationType(from: userInfo) == "blend_request_withdrawn",
           let blendId = userInfo[AnyHashable("blendId")] as? String, !blendId.isEmpty {
            PushNotificationService.removeDeliveredBlendRequestNotifications(blendId: blendId) {
                completionHandler(.newData)
            }
            return
        }
        completionHandler(.noData)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        PushNotificationService.handleRemoteNotificationTap(userInfo: userInfo)
        completionHandler()
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        if url.scheme == "wellread", url.host == "goodreads-import" {
            NotificationCenter.default.post(name: .openGoodreadsImport, object: nil)
            return true
        }
        if url.scheme == "wellread", url.host == "link-import" {
            NotificationCenter.default.post(name: .openLinkImport, object: nil)
            return true
        }
        if let postId = WellreadDeepLink.postId(from: url) {
            // Same rule as a push tap: an open sheet/drawer gets torn down first so
            // the thread opens now, not whenever the user closes it.
            PushNotificationService.routeAfterClearingPresentedModals {
                NotificationCenter.default.post(name: .wellreadOpenFeedPost, object: nil, userInfo: ["postId": postId])
            }
            return true
        }
        // Widget taps.
        if WellreadDeepLink.isQueueLink(url) {
            PushNotificationService.routeToQueue()
            return true
        }
        if let link = WellreadDeepLink.bookLink(from: url) {
            PushNotificationService.routeToBookProfile(bookId: link.bookId, readerUid: link.readerUid)
            return true
        }
        if GIDSignIn.sharedInstance.handle(url) {
            return true
        }
        return false
    }
}

extension Notification.Name {
    static let openGoodreadsImport = Notification.Name("openGoodreadsImport")
    /// A non-Goodreads link/text was shared to SPINE: open the link → queue wizard.
    static let openLinkImport = Notification.Name("openLinkImport")
}

@main
struct WellReadApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var authService = AuthService()
    @StateObject private var appState = AppState()
    @StateObject private var queueDragCoordinator = QueueBookDragCoordinator()
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.defaultValue.rawValue

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .defaultValue
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(appState)
                .environmentObject(queueDragCoordinator)
                // Theme palette is fully dynamic (light paper / dark CRT); this
                // drives system materials, nav bars, keyboards, and sheets too.
                // `nil` (System) follows the device setting.
                .preferredColorScheme(appearance.colorScheme)
                .onOpenURL { url in
                    if url.scheme == "wellread", url.host == "goodreads-import" {
                        handleGoodreadsImportFromShare()
                    } else if url.scheme == "wellread", url.host == "link-import" {
                        handleLinkImportFromShare()
                    } else if WellreadDeepLink.isQueueLink(url) {
                        // Widget: tapped one of your own reading-now covers.
                        PushNotificationService.routeToQueue()
                    } else if let link = WellreadDeepLink.bookLink(from: url) {
                        // Widget: tapped a cover on someone else's shelf.
                        PushNotificationService.routeToBookProfile(bookId: link.bookId, readerUid: link.readerUid)
                    } else if let postId = WellreadDeepLink.postId(from: url) {
                        // Same rule as a push tap: an open sheet/drawer is torn down
                        // first so the thread opens now, not whenever the user
                        // happens to close it.
                        PushNotificationService.routeAfterClearingPresentedModals {
                            NotificationCenter.default.post(name: .wellreadOpenFeedPost, object: nil, userInfo: ["postId": postId])
                        }
                    } else if url.isFileURL {
                        handleFileURLFromShare(url)
                    } else {
                        GIDSignIn.sharedInstance.handle(url)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .openGoodreadsImport)) { _ in
                    handleGoodreadsImportFromShare()
                }
                .onReceive(NotificationCenter.default.publisher(for: .openLinkImport)) { _ in
                    handleLinkImportFromShare()
                }
                .onChange(of: scenePhase) { _, newValue in
                    // Share extensions cannot open the containing app; when user manually switches to Spines after sharing, we process the pending URL here.
                    if newValue == .active {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s so UI is ready
                            handleGoodreadsImportFromShare()
                            handleLinkImportFromShare()
                        }
                        WidgetDataService.shared.scheduleRefresh(appState: appState, delay: 3.0)
                    }
                }
        }
    }

    private func handleGoodreadsImportFromShare() {
        if let data = GoodreadsShareHelper.consumePendingImport(), !data.isEmpty {
            let parsed = GoodreadsCSVParser.parse(data: data)
            if !parsed.isEmpty {
                appState.pendingGoodreadsImportRows = parsed
            }
        }
        if let message = GoodreadsShareHelper.consumePendingImportError() {
            appState.pendingGoodreadsImportError = message
        }
        if let sharedURL = GoodreadsShareHelper.consumePendingImportURL() {
            appState.pendingGoodreadsImportURL = sharedURL
            Task { await appState.fetchGoodreadsImportFromURL(sharedURL) }
        }
    }

    /// A link or text shared to SPINE (anything that isn't a Goodreads export):
    /// hand it to the link → queue wizard. Any sheet the user left open is torn
    /// down first, same as a push deep link, so the wizard actually presents.
    private func handleLinkImportFromShare() {
        guard let payload = LinkImportShareHelper.consumePending() else { return }
        PushNotificationService.routeAfterClearingPresentedModals {
            appState.pendingLinkImport = payload
        }
    }

    /// When the app is opened with a file URL (e.g. user tapped Spines in share sheet and system opened app with the file).
    private func handleFileURLFromShare(_ url: URL) {
        guard url.isFileURL else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let head = String(data: data.prefix(1024), encoding: .utf8) ?? ""
        guard head.contains("Book Id") || head.contains("Title,") else { return }
        let parsed = GoodreadsCSVParser.parse(data: data)
        if !parsed.isEmpty {
            appState.pendingGoodreadsImportRows = parsed
        }
    }
}
