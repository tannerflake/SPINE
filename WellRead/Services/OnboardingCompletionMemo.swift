//
//  OnboardingCompletionMemo.swift
//  WellRead
//
//  Device-local record of which accounts have finished onboarding.
//

import Foundation

/// Remembers, per uid, that this device has seen a fully onboarded Firestore
/// user document. It exists for exactly one decision: when Firestore is
/// unreachable at launch and `AuthService` can only offer a provisional user,
/// this says whether the member is already set up, so the app can go straight
/// to the main tabs instead of stranding them on a spinner.
///
/// It is a cache, never a source of truth. The wizard is still gated on the
/// real document (`User.needsProfileCompletion`); the memo only ever moves a
/// member *past* onboarding, never into it.
enum OnboardingCompletionMemo {
    private static let key = "onboardingCompletedUids"

    static func markComplete(uid: String) {
        var uids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        guard uids.insert(uid).inserted else { return }
        UserDefaults.standard.set(Array(uids), forKey: key)
    }

    static func isComplete(uid: String?) -> Bool {
        guard let uid else { return false }
        return (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(uid)
    }

    /// Account deletion clears the memo so a re-signup on the same device
    /// (a new uid, but also a recycled one in testing) starts clean.
    static func forget(uid: String) {
        var uids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        guard uids.remove(uid) != nil else { return }
        UserDefaults.standard.set(Array(uids), forKey: key)
    }
}
