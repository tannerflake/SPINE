//
//  PushRegistrationDiagnostics.swift
//  WellRead
//
//  Runtime evidence for push setup: permission, APNs token, FCM token, Firestore save + optional read-back.
//

import Foundation
import Combine
import UserNotifications
import FirebaseAuth
import FirebaseFunctions
import FirebaseMessaging

@MainActor
final class PushRegistrationDiagnostics: ObservableObject {
    static let shared = PushRegistrationDiagnostics()

    @Published var authorizationSummary: String = "-"
    @Published var apnsDeviceTokenHex: String?
    @Published var apnsRegistrationError: String?
    @Published var fcmRegistrationToken: String?
    @Published var lastFirestoreWriteSummary: String = "-"
    @Published var lastFirestoreWriteAt: Date?
    @Published var lastFirestoreReadSummary: String = "Tap “Verify Firestore read-back”"
    @Published var isVerifyingFirestore: Bool = false
    @Published var lastTestPushMessage: String = "-"
    @Published var sendingTestPushKind: PushTestNotificationKind? = nil

    private let userRepo = UserRepository()
    /// Must match `sendTestPushNotification` in `functions/src/index.ts`.
    private static let testPushFunctions = Functions.functions(region: "us-central1")

    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.applyAuthorizationSettings(settings)
            }
        }
    }

    private func applyAuthorizationSettings(_ settings: UNNotificationSettings) {
        let a = settings.authorizationStatus
        let name: String
        switch a {
        case .notDetermined: name = "notDetermined"
        case .denied: name = "denied"
        case .authorized: name = "authorized"
        case .provisional: name = "provisional"
        case .ephemeral: name = "ephemeral"
        @unknown default: name = "unknown(\(a.rawValue))"
        }
        let alert = settings.alertSetting == .enabled ? "alerts on" : "alerts off"
        authorizationSummary = "\(name), \(alert)"
    }

    func refreshFCMTokenFromMessaging() async {
        do {
            let token = try await Messaging.messaging().token()
            fcmRegistrationToken = token
        } catch {
            fcmRegistrationToken = nil
        }
    }

    nonisolated static func setAPNsDeviceToken(_ data: Data?) {
        guard let data, !data.isEmpty else {
            Task { @MainActor in PushRegistrationDiagnostics.shared.apnsDeviceTokenHex = nil }
            return
        }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushRegistrationDiagnostics.shared.apnsDeviceTokenHex = hex }
    }

    nonisolated static func setAPNsRegistrationFailed(_ error: Error) {
        Task { @MainActor in
            PushRegistrationDiagnostics.shared.apnsRegistrationError = error.localizedDescription
            PushRegistrationDiagnostics.shared.apnsDeviceTokenHex = nil
        }
    }

    nonisolated static func setFCMToken(_ token: String?) {
        Task { @MainActor in PushRegistrationDiagnostics.shared.fcmRegistrationToken = token }
    }

    nonisolated static func recordFirestoreWriteSuccess(at date: Date) {
        Task { @MainActor in
            PushRegistrationDiagnostics.shared.lastFirestoreWriteSummary = "Saved OK"
            PushRegistrationDiagnostics.shared.lastFirestoreWriteAt = date
        }
    }

    nonisolated static func recordFirestoreWriteFailed(_ error: Error) {
        Task { @MainActor in
            PushRegistrationDiagnostics.shared.lastFirestoreWriteSummary = "Save failed: \(error.localizedDescription)"
            PushRegistrationDiagnostics.shared.lastFirestoreWriteAt = nil
        }
    }

    nonisolated static func recordFirestoreSkippedNotSignedIn() {
        Task { @MainActor in
            PushRegistrationDiagnostics.shared.lastFirestoreWriteSummary = "Skipped (not signed in)"
        }
    }

    func verifyFirestoreReadBack() async {
        guard let uid = Auth.auth().currentUser?.uid else {
            lastFirestoreReadSummary = "Not signed in"
            return
        }
        guard let token = fcmRegistrationToken, !token.isEmpty else {
            lastFirestoreReadSummary = "No FCM token yet. Wait for registration or tap Refresh"
            return
        }
        isVerifyingFirestore = true
        defer { isVerifyingFirestore = false }
        do {
            let exists = try await userRepo.fcmTokenDocumentExists(uid: uid, token: token)
            lastFirestoreReadSummary = exists
                ? "Read-back OK: users/\(uid.prefix(6))…/fcmTokens/{hash} exists"
                : "Document missing (path may differ or write not committed yet)"
        } catch {
            lastFirestoreReadSummary = "Read failed: \(error.localizedDescription)"
        }
    }

    /// Sends a sample push via the `sendTestPushNotification` callable (uses FCM tokens already stored in Firestore).
    func sendTestPush(kind: PushTestNotificationKind) async {
        guard Auth.auth().currentUser != nil else {
            lastTestPushMessage = "Not signed in"
            return
        }
        sendingTestPushKind = kind
        defer { sendingTestPushKind = nil }
        do {
            let callable = Self.testPushFunctions.httpsCallable("sendTestPushNotification")
            let result = try await callable.call(["type": kind.rawValue])
            if let dict = result.data as? [String: Any],
               let sent = dict["sent"] as? Int {
                lastTestPushMessage = "Sent to \(sent) token\(sent == 1 ? "" : "s")"
            } else {
                lastTestPushMessage = "Sent"
            }
        } catch {
            lastTestPushMessage = (error as NSError).localizedDescription
        }
    }
}

/// Payload `data.type` values for `sendTestPushNotification` (mirrors production Cloud Functions).
enum PushTestNotificationKind: String, CaseIterable, Identifiable {
    case friendReviewPosted = "friend_review_posted"
    case reviewLiked = "review_liked"
    case reviewCommented = "review_commented"
    case threadCommented = "thread_commented"

    var id: String { rawValue }

    var buttonLabel: String {
        switch self {
        case .friendReviewPosted: return "Followed reader posted review"
        case .reviewLiked: return "Like on your review"
        case .reviewCommented: return "Comment on your review"
        case .threadCommented: return "Thread you joined"
        }
    }
}
