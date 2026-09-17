//
//  PushNotificationNudgeStorage.swift
//  SPINE
//
//  Persists when the user may see the recurring “enable push” modal again (after “No thanks”).
//

import Foundation

enum PushNotificationNudgeStorage {
    private static let snoozeKeyPrefix = "pushNotificationNudgeSnoozedUntil_"

    private static func key(uid: String) -> String {
        snoozeKeyPrefix + uid
    }

    /// Next date after which the nudge may appear (exclusive of that instant until passed).
    static func snoozedUntil(uid: String) -> Date? {
        let t = UserDefaults.standard.double(forKey: key(uid: uid))
        guard t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    static func snoozeOneMonth(from date: Date = Date(), uid: String) {
        let next = Calendar.current.date(byAdding: .month, value: 1, to: date) ?? date.addingTimeInterval(30 * 24 * 60 * 60)
        UserDefaults.standard.set(next.timeIntervalSince1970, forKey: key(uid: uid))
    }

    /// `true` if we may show the nudge (snooze expired or never snoozed).
    static func isEligibleForNudge(uid: String, now: Date = Date()) -> Bool {
        guard let until = snoozedUntil(uid: uid) else { return true }
        return now >= until
    }
}
