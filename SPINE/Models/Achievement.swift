//
//  Achievement.swift
//  SPINE
//
//  Achievements are rubber stamps for the library card. Cloud Functions award
//  them (`users/{uid}.achievements.{id}.unlockedAt`) and send the push; the app
//  shows the unlock modal, then lets the reader press the stamp anywhere on
//  the front or back of their card. Where it landed is the only thing the
//  client writes. The OG mark is NOT an achievement: it is printed on the card
//  at signup and never moves. Copy rule: no em-dashes in user-facing text.
//

import Foundation
import FirebaseFirestore

/// Every stamp the app knows how to draw. The raw value is the Firestore key
/// under `achievements` and the id the push carries as `achievementId`.
enum AchievementKind: String, CaseIterable, Identifiable, Codable {
    case ranked25 = "ranked25"

    var id: String { rawValue }

    /// Short name for the stamp bank and the bell feed.
    var title: String {
        switch self {
        case .ranked25: return "25 Books Ranked"
        }
    }

    /// Headline on the unlock modal.
    var unlockTitle: String {
        switch self {
        case .ranked25: return "25 books ranked!"
        }
    }

    /// Body copy on the unlock modal.
    var unlockBody: String {
        switch self {
        case .ranked25:
            return "You have sorted 25 books into tiers. That earns a stamp for your library card."
        }
    }

    /// One line under the stamp in the bank.
    var caption: String {
        switch self {
        case .ranked25: return "Rank 25 books"
        }
    }

    /// What a locked stamp asks for, shown when it is tapped in the bank.
    var howToUnlock: String {
        switch self {
        case .ranked25:
            return "Sort 25 of the books you have read into your tier list. Every ranked book counts, whatever the tier."
        }
    }

    /// Asset catalog image: a PNG with transparency, so it prints over the
    /// card's paper without a box around it.
    var assetName: String {
        switch self {
        case .ranked25: return "stamp-ranked-25"
        }
    }

    /// How many ranked books the stamp takes. Mirrors the threshold in
    /// `onUserBookRankedForAchievements` (functions/src/index.ts).
    var rankedBooksThreshold: Int? {
        switch self {
        case .ranked25: return 25
        }
    }
}

/// Where a stamp sits on the card. `x`/`y` are the stamp's center as a
/// fraction of the face's width and height, so the same placement renders
/// identically on the profile card, the share export, and any future size.
struct StampPlacement: Equatable, Codable {
    enum Side: String, Codable {
        case front
        case back
    }

    var side: Side
    var x: Double
    var y: Double
    /// Degrees. A little tilt at stamping time makes it read as hand-pressed.
    var rotation: Double

    var firestoreMap: [String: Any] {
        ["side": side.rawValue, "x": x, "y": y, "rotation": rotation]
    }

    init(side: Side, x: Double, y: Double, rotation: Double) {
        self.side = side
        self.x = x
        self.y = y
        self.rotation = rotation
    }

    init?(firestoreMap raw: [String: Any]?) {
        guard let raw,
              let sideRaw = raw["side"] as? String,
              let side = Side(rawValue: sideRaw),
              let x = Self.number(raw["x"]),
              let y = Self.number(raw["y"]) else { return nil }
        self.side = side
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.rotation = Self.number(raw["rotation"]) ?? 0
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}

/// One earned stamp: when it was awarded, whether the reader has been shown
/// the unlock, and where (if anywhere) it is pressed on the card.
struct AchievementStamp: Identifiable, Equatable, Codable {
    let kind: AchievementKind
    let unlockedAt: Date
    /// Set when the unlock modal was presented (or the push tapped), so the
    /// celebration happens once. Nil means the modal is still owed.
    var seenAt: Date?
    var placement: StampPlacement?

    var id: String { kind.rawValue }
    var isPlaced: Bool { placement != nil }

    /// Parses the `achievements` map on a user doc. Unknown ids (a stamp this
    /// build does not have art for) are dropped rather than drawn blank.
    static func parse(firestoreMap raw: [String: Any]?) -> [AchievementStamp] {
        guard let raw else { return [] }
        var out: [AchievementStamp] = []
        for (key, value) in raw {
            guard let kind = AchievementKind(rawValue: key),
                  let entry = value as? [String: Any] else { continue }
            let unlockedAt = (entry["unlockedAt"] as? Timestamp)?.dateValue() ?? Date()
            out.append(AchievementStamp(
                kind: kind,
                unlockedAt: unlockedAt,
                seenAt: (entry["seenAt"] as? Timestamp)?.dateValue(),
                placement: StampPlacement(firestoreMap: entry["placement"] as? [String: Any])
            ))
        }
        return out.sorted { $0.unlockedAt < $1.unlockedAt }
    }
}

extension User {
    func achievement(_ kind: AchievementKind) -> AchievementStamp? {
        achievements.first { $0.kind == kind }
    }

    /// Stamps earned but never celebrated: the unlock modal is owed for these.
    var unseenAchievements: [AchievementStamp] {
        achievements.filter { $0.seenAt == nil }
    }

    /// Earned stamps not yet pressed onto the card.
    var unplacedAchievements: [AchievementStamp] {
        achievements.filter { !$0.isPlaced }
    }
}
