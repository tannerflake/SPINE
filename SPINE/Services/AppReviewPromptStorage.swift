//
//  AppReviewPromptStorage.swift
//  SPINE
//
//  Decides when to ask for an App Store rating (per uid, UserDefaults only).
//
//  The custom "Enjoying SPINE?" modal is a one-time ask, shown the first time
//  the viewer looks at their own tier list with at least one ranked book in it.
//  Never before they've ranked something: a tier list with nothing in it is no
//  reason to like the app yet.
//
//  What happens next depends on how they answered it:
//   - tapped "Rate SPINE" -> Apple's star prompt fires right then, and the
//     account is done for good. We can't actually tell whether they rated
//     (StoreKit says nothing), so this takes them at their word: the cost is
//     that someone who tapped through and then closed Apple's prompt without
//     rating is never asked again, and that's the deal we chose.
//   - tapped "Not now" -> Apple's star prompt 7 days later, then every 6
//     months. Recurring is fine here because it's passive: no sheet of ours,
//     just Apple's prompt, which iOS is free to suppress. Twice a year also
//     sits inside the display cap with a request to spare (see
//     `systemPromptsPerYear`).
//
//  Nothing is backfilled, so accounts that predate this feature become eligible
//  the next time they land on their tier list.
//

import Foundation

/// What (if anything) the rating flow owes this viewer right now.
enum AppReviewPromptAction: Equatable {
    /// Nothing to do: no window has come due.
    case none
    /// One-time ask: the custom pre-prompt modal.
    case customModal
    /// Apple's own star prompt, with no pre-prompt in front of it.
    case systemPrompt
}

enum AppReviewPromptStorage {
    private static let customShownPrefix = "appReviewCustomPromptShownAt_"
    private static let notNowPrefix = "appReviewNotNowAt_"
    private static let finishedPrefix = "appReviewFinished_"
    /// Rolling log of our own `requestReview` calls. Drives both the 6-month
    /// cadence and the display-cap check.
    private static let systemRequestsPrefix = "appReviewSystemRequestDates_"

    /// Wait after "Not now" before the native prompt gets its first turn.
    static let followUpDelay: TimeInterval = 7 * 24 * 60 * 60

    /// Gap between native prompts once the first one has fired.
    static let recurrenceInterval: TimeInterval = 182 * 24 * 60 * 60

    /// iOS shows the native prompt at most 3 times per app per 365 days. A
    /// 6-month cadence spends 2, so the cap is never the thing that stops us,
    /// but count anyway: a call site that silently no-ops is worse than one that
    /// knows it's out of budget.
    private static let systemPromptsPerYear = 3

    private static func key(_ prefix: String, uid: String) -> String { prefix + uid }

    // MARK: - Decision

    static func pendingAction(uid: String, now: Date = Date()) -> AppReviewPromptAction {
        guard !isFinished(uid: uid) else { return .none }
        guard let shown = customPromptShownAt(uid: uid) else { return .customModal }

        // Once the native prompt has fired at least once, everything after is
        // just the 6-month cadence. Only the "Not now" lineage ever gets here:
        // a tap-through is already `isFinished` above.
        if let last = lastSystemPromptAt(uid: uid) {
            return now.timeIntervalSince(last) >= recurrenceInterval ? .systemPrompt : .none
        }

        // First native prompt, 7 days after the viewer waved the modal off.
        // Normally the clock starts at "Not now"; falling back to when the modal
        // was shown covers the account that got killed with the sheet still up,
        // where `onDismiss` never ran and there's no decision on record. In the
        // ordinary path the two timestamps are seconds apart.
        let clockStart = notNowAt(uid: uid) ?? shown
        return now.timeIntervalSince(clockStart) >= followUpDelay ? .systemPrompt : .none
    }

    // MARK: - Recording

    static func recordCustomPromptShown(uid: String, now: Date = Date()) {
        guard customPromptShownAt(uid: uid) == nil else { return }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: key(customShownPrefix, uid: uid))
    }

    /// "Not now" (or a swipe-down, which we treat the same) starts the 7-day
    /// clock on the first native prompt. Only the first call counts: the
    /// follow-up is a fixed 7 days from the one and only decision.
    static func recordNotNow(uid: String, now: Date = Date()) {
        guard notNowAt(uid: uid) == nil else { return }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: key(notNowPrefix, uid: uid))
    }

    /// The viewer tapped "Rate SPINE". Ends the flow for this account: no
    /// 6-month recurrence, nothing further. Set on the tap itself, not on any
    /// confirmation that a rating was submitted, because no such confirmation
    /// exists.
    static func markFinishedByTapThrough(uid: String) {
        UserDefaults.standard.set(true, forKey: key(finishedPrefix, uid: uid))
    }

    static func isFinished(uid: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(finishedPrefix, uid: uid))
    }

    static func customPromptShownAt(uid: String) -> Date? {
        let t = UserDefaults.standard.double(forKey: key(customShownPrefix, uid: uid))
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static func notNowAt(uid: String) -> Date? {
        let t = UserDefaults.standard.double(forKey: key(notNowPrefix, uid: uid))
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    // MARK: - Native prompt cadence and budget

    /// When we last asked iOS for the native prompt. Note this is when we
    /// *asked*: whether iOS actually displayed it is not something StoreKit
    /// tells us, so the cadence is measured on our own requests.
    static func lastSystemPromptAt(uid: String) -> Date? {
        allSystemRequests(uid: uid).max().map { Date(timeIntervalSince1970: $0) }
    }

    /// `false` once we've asked 3 times inside a year, past which the call is a
    /// guaranteed no-op. A 6-month cadence never gets here on its own.
    static func hasSystemPromptBudget(uid: String, now: Date = Date()) -> Bool {
        recentSystemRequests(uid: uid, now: now).count < systemPromptsPerYear
    }

    static func recordSystemPromptRequested(uid: String, now: Date = Date()) {
        // Only the last year matters for the cap, and the cadence only reads the
        // newest entry, so the log is trimmed as it's written.
        var dates = recentSystemRequests(uid: uid, now: now)
        dates.append(now.timeIntervalSince1970)
        UserDefaults.standard.set(dates, forKey: key(systemRequestsPrefix, uid: uid))
    }

    private static func allSystemRequests(uid: String) -> [Double] {
        UserDefaults.standard.array(forKey: key(systemRequestsPrefix, uid: uid)) as? [Double] ?? []
    }

    private static func recentSystemRequests(uid: String, now: Date) -> [Double] {
        let cutoff = now.addingTimeInterval(-365 * 24 * 60 * 60).timeIntervalSince1970
        return allSystemRequests(uid: uid).filter { $0 >= cutoff }
    }

    #if DEBUG
    /// `-uiPreviewRateApp` and friends run against a clean slate.
    static func resetForPreview(uid: String) {
        for prefix in [customShownPrefix, notNowPrefix, finishedPrefix, systemRequestsPrefix] {
            UserDefaults.standard.removeObject(forKey: key(prefix, uid: uid))
        }
    }

    /// Backdates the "Not now" so the first native prompt is due immediately.
    static func simulateExpiredNotNowForPreview(uid: String) {
        resetForPreview(uid: uid)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key(customShownPrefix, uid: uid))
        UserDefaults.standard.set(
            Date().addingTimeInterval(-(followUpDelay + 60)).timeIntervalSince1970,
            forKey: key(notNowPrefix, uid: uid)
        )
    }

    /// Backdates the last native prompt so the 6-month recurrence is due
    /// immediately. Bear in mind iOS's own 3-per-year cap is per *device* and
    /// can't be reset from here: after a few runs the prompt stops appearing no
    /// matter what this says. Erase the simulator to get more attempts.
    static func simulateDueRecurrenceForPreview(uid: String) {
        resetForPreview(uid: uid)
        let now = Date()
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: key(customShownPrefix, uid: uid))
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: key(notNowPrefix, uid: uid))
        UserDefaults.standard.set(
            [now.addingTimeInterval(-(recurrenceInterval + 60)).timeIntervalSince1970],
            forKey: key(systemRequestsPrefix, uid: uid)
        )
    }
    #endif
}
