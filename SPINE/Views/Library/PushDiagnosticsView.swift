//
//  PushDiagnosticsView.swift
//  SPINE
//
//  Shows live push pipeline state (permission, APNs, FCM, Firestore write + read-back).
//

import SwiftUI

struct PushDiagnosticsView: View {
    @ObservedObject private var diag = PushRegistrationDiagnostics.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text("Use this screen to confirm push is wired end-to-end on a device (not Simulator for APNs).")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
            }

            Section("1. Permission") {
                Text(diag.authorizationSummary)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textPrimary)
            }

            Section("2. APNs device token") {
                if let err = diag.apnsRegistrationError {
                    Text(err)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.danger)
                }
                Text(diag.apnsDeviceTokenHex ?? "Not received (needs real device + permission + registerForRemoteNotifications)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
            }

            Section("3. FCM registration token") {
                Text(diag.fcmRegistrationToken ?? "Not received yet")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
            }

            Section("4. Firestore write (users/{uid}/fcmTokens/{hash})") {
                Text(diag.lastFirestoreWriteSummary)
                    .foregroundStyle(Theme.textPrimary)
                if let t = diag.lastFirestoreWriteAt {
                    Text(t.formatted(date: .abbreviated, time: .standard))
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Section("5. Firestore read-back") {
                Text(diag.lastFirestoreReadSummary)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
                Button {
                    Task { await diag.verifyFirestoreReadBack() }
                } label: {
                    if diag.isVerifyingFirestore {
                        ProgressView()
                    } else {
                        Text("Verify Firestore read-back")
                    }
                }
                .disabled(diag.isVerifyingFirestore)
            }

            Section {
                Text("Uses the `sendTestPushNotification` callable (same FCM path as production). Deploy functions after pulling.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
                Text(diag.lastTestPushMessage)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textPrimary)
                ForEach(PushTestNotificationKind.allCases) { kind in
                    Button {
                        Task { await diag.sendTestPush(kind: kind) }
                    } label: {
                        HStack {
                            Text(kind.buttonLabel)
                            Spacer(minLength: 0)
                            if diag.sendingTestPushKind == kind {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(diag.sendingTestPushKind != nil)
                }
            } header: {
                Text("6. Send test push")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Push diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") {
                    diag.refreshAuthorizationStatus()
                    Task { await diag.refreshFCMTokenFromMessaging() }
                }
            }
        }
        .onAppear {
            diag.refreshAuthorizationStatus()
            Task { await diag.refreshFCMTokenFromMessaging() }
        }
    }
}
