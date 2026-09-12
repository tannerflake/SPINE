//
//  User.swift
//  WellRead
//

import Foundation

struct User: Identifiable, Codable, Equatable {
    var id: UUID
    var username: String
    var displayName: String
    /// Set during post–sign-in onboarding; optional for legacy accounts.
    var firstName: String?
    var lastName: String?
    /// When `false`, user must complete name + handle onboarding before the main app.
    var profileSetupCompleted: Bool
    var bio: String?
    /// Normalized digits (see ContactSyncService.normalizePhoneNumber); used to match
    /// synced contacts to existing members. Optional — captured at onboarding or in Edit Profile.
    var phoneNumber: String?
    var profileImageURL: String?
    var joinedAt: Date
    /// Firebase Auth UIDs this user follows (`users/{id}/following` in Firestore). Used for push eligibility and profile.
    var following: [String]
    /// Firestore `hasSeenFounderWelcomeModal`; one-time feed modal with the founder's welcome note (syncs across devices).
    var hasSeenFounderWelcomeModal: Bool
    /// One-time prompt to enable push after profile onboarding (`hasSeenPushNotificationPrompt` in Firestore).
    var hasSeenPushNotificationPrompt: Bool
    var totalBooksRead: Int
    var totalPagesRead: Int
    var readingGoal: Int?
    /// Tags the reader chose during onboarding (`Tags.csv` strings); empty for legacy accounts.
    var readingInterestTags: [String]
    /// Discover tuning criteria (`discoverCriteria` map in Firestore); default = overall taste.
    var discoverCriteria: DiscoverCriteria = .default
    /// Decided once, at account creation, and never revisited: whether this account missed the
    /// library card's OG stamp (the first 250 real members). Missing/false means eligible, so every
    /// account that existed before this field shipped is grandfathered in rather than losing a stamp
    /// it already showed them. See `UserRepository.ensureUserDocument` and `TestAccountSignatures`.
    var ogIneligible: Bool = false
    /// Readers the user X'd out of a "Readers to follow" feed suggestion
    /// (`dismissedRecommendedUids` in Firestore). Never suggested again; still
    /// visible in the roster strip and search, since that's not a recommendation.
    var dismissedRecommendedUids: [String] = []

    static let demo = User(
        id: UUID(),
        username: "tanner",
        displayName: "Tanner",
        firstName: "Tanner",
        lastName: nil,
        profileSetupCompleted: true,
        bio: "Building SPINE.",
        phoneNumber: nil,
        profileImageURL: nil,
        joinedAt: Date(),
        following: [],
        hasSeenFounderWelcomeModal: true,
        hasSeenPushNotificationPrompt: true,
        totalBooksRead: 12,
        totalPagesRead: 3840,
        readingGoal: 24,
        readingInterestTags: []
    )
}

typealias UserID = UUID
