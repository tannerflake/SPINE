//
//  ProfilePhotoNudgeStorage.swift
//  SPINE
//
//  Counts dismissals of the “add a profile photo” launch reminder (per uid).
//  After enough dismissals the reminder never shows again.
//

import Foundation

enum ProfilePhotoNudgeStorage {
    private static let dismissCountKeyPrefix = "profilePhotoNudgeDismissCount_"
    /// Dismissals allowed before the reminder goes quiet for good.
    static let maxDismissals = 4

    private static func key(uid: String) -> String {
        dismissCountKeyPrefix + uid
    }

    static func dismissCount(uid: String) -> Int {
        UserDefaults.standard.integer(forKey: key(uid: uid))
    }

    static func recordDismissal(uid: String) {
        UserDefaults.standard.set(dismissCount(uid: uid) + 1, forKey: key(uid: uid))
    }

    /// `true` while the user hasn’t waved the reminder off `maxDismissals` times.
    static func isEligible(uid: String) -> Bool {
        dismissCount(uid: uid) < maxDismissals
    }
}
