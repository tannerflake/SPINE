//
//  UserRepository.swift
//  SPINE
//
//  Firestore user documents: get, ensure (create if missing), used for "account" for Google/Apple sign-in.
//

import Foundation
import CryptoKit
import FirebaseAuth
import FirebaseFirestore

/// Accounts hidden app-wide (people lists, feed posts, comments) from everyone
/// except the uids they're whitelisted for. The hidden account still sees itself.
enum HiddenAccounts {
    /// hidden uid → viewer uids allowed to see the account.
    private static let visibleOnlyTo: [String: Set<String>] = [
        // tanner@tinyhealth.com test account (@tantest) — visible only to Tanner (tannerflake@gmail.com).
        "lWfYPy4fOxdQYFUYEXAGnpvNscw2": [SpineFounder.uid],
    ]

    static func isHidden(uid: String, viewerUid: String?) -> Bool {
        guard let allowed = visibleOnlyTo[uid] else { return false }
        guard let viewer = viewerUid else { return true }
        return viewer != uid && !allowed.contains(viewer)
    }

    /// Convenience for call sites without a viewer uid in scope (feed/comment listeners).
    static func isHiddenFromCurrentViewer(uid: String) -> Bool {
        isHidden(uid: uid, viewerUid: Auth.auth().currentUser?.uid)
    }
}

/// Test/backdoor accounts that should never count as a real reader: Tanner's own
/// test logins, the App Store review account, and Apple's automated review
/// sign-in. Used to (a) flag new docs with `isTestAccount: true` at creation in
/// `ensureUserDocument` and (b) exclude those docs from `memberNumber`'s count
/// (and therefore from OG-stamp eligibility on the library card). Distinct from
/// `HiddenAccounts` (app-wide visibility) and `OtherReadersExclusion` (friends
/// strip only) — some accounts land in more than one of these, and the literal
/// email/name lists are intentionally kept separate rather than shared, so a
/// change to one exclusion's scope can't silently change another's.
enum TestAccountSignatures {
    static let emailsLowercased: Set<String> = [
        "tanner@tinyhealth.com", // @tantest, see HiddenAccounts
        "tanner+onboarding@tinyhealth.com", // onboarding-flow test account, see onboarding-test-account memory
        "review@spynesapp.com",
        "review@spinesapp.com",
    ]

    /// Apple's automated App Review sign-in creates a fresh account (random uid,
    /// privaterelay email) most review cycles, defaulting to this display name
    /// when no real name is shared. Matched by name since the uid changes every time.
    static func isAppleReviewName(_ displayName: String?) -> Bool {
        (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "john apple"
    }

    static func matches(email: String?, displayName: String?) -> Bool {
        if let e = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           emailsLowercased.contains(e) {
            return true
        }
        return isAppleReviewName(displayName)
    }
}

/// Accounts hidden from the Feed “Your friends” strip (Apple review / internal test users).
private enum OtherReadersExclusion {
    /// `displayName` match (trimmed, case-insensitive), e.g. default Apple review accounts.
    static let displayNamesLowercased: Set<String> = ["john apple"]
    /// Firestore `email` field (synced from Firebase Auth on sign-in).
    static let emailsLowercased: Set<String> = ["review@spynesapp.com", "review@spinesapp.com"]

    static func shouldExclude(firestoreData: [String: Any], user: User) -> Bool {
        let dn = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if displayNamesLowercased.contains(dn) { return true }
        if let em = (firestoreData["email"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           emailsLowercased.contains(em) {
            return true
        }
        return false
    }
}

/// The founder's Firebase Auth uid (Tanner Flake, @tan). New accounts follow him by default;
/// a Cloud Function (`onUserCreated`) follows them back and pushes him a new-member alert.
enum SpineFounder {
    static let uid = "jCaSGxcYgHZd6OzXfxmGNn1GZBj2"
}

/// Outcome of a handle availability check (distinguishes "taken" from Firestore permission/network errors).
enum HandleAvailabilityCheck: Sendable {
    case available
    case taken
    /// Rules not deployed, wrong DB, offline, etc. — do not show as "taken".
    case failed(underlying: Error)
}

final class UserRepository {
    private let db = FirestoreDatabase.firestore
    private let users = "users"
    /// Doc ID = lowercase handle; fields: `uid` (Firebase Auth uid). Enables availability checks without querying `users`.
    private let handleClaims = "handleClaims"

    /// Returns the User document for this uid if it exists.
    /// How many accounts existed on or before `date` — the user's "member
    /// number" for the library card (the 50th account to join is member 50).
    /// Excludes docs flagged `isTestAccount` (see `TestAccountSignatures`) so
    /// backdoor/review/duplicate accounts don't inflate real members' numbers
    /// or count toward the OG-stamp cutoff. Server-side count aggregation;
    /// nil on failure so callers can fall back.
    func memberNumber(joinedAt date: Date) async -> Int? {
        let cutoff = Timestamp(date: date)
        do {
            async let totalAgg = db.collection(users)
                .whereField("joinedAt", isLessThanOrEqualTo: cutoff)
                .count.getAggregation(source: .server)
            async let testAgg = db.collection(users)
                .whereField("isTestAccount", isEqualTo: true)
                .whereField("joinedAt", isLessThanOrEqualTo: cutoff)
                .count.getAggregation(source: .server)
            let (total, test) = try await (totalAgg, testAgg)
            return max(0, total.count.intValue - test.count.intValue)
        } catch {
            return nil
        }
    }

    func getUser(uid: String) async -> User? {
        let ref = db.collection(users).document(uid)
        do {
            let snapshot = try await ref.getDocument()
            guard snapshot.exists, let data = snapshot.data() else { return nil }
            return user(from: data, uid: uid)
        } catch {
            return nil
        }
    }

    /// Reads the user document straight from Firestore's on-disk cache, never
    /// the network. `getUser` waits on the server (and can hang indefinitely on
    /// a stalled connection); this is the offline answer for a member whose
    /// document we've already seen on this device.
    func getCachedUser(uid: String) async -> User? {
        let ref = db.collection(users).document(uid)
        do {
            let snapshot = try await ref.getDocument(source: .cache)
            guard snapshot.exists, let data = snapshot.data() else { return nil }
            return user(from: data, uid: uid)
        } catch {
            return nil
        }
    }

    /// Session cache for bulk profile lookups (feed post authors). Profiles
    /// change rarely; a slightly stale name/photo beats re-fetching every
    /// author on each feed update. `getUser` stays uncached for fresh reads.
    private static var bulkUserCache: [String: User] = [:]
    private static let bulkUserCacheLock = NSLock()

    /// Bulk lookup: cache hits return immediately; the rest load through
    /// parallel `in` queries (30 uids each) rather than one round trip per
    /// user. Missing/failed uids are simply absent from the result.
    func getUsers(uids: [String]) async -> [String: User] {
        var result: [String: User] = [:]
        var missing: [String] = []
        Self.bulkUserCacheLock.lock()
        for uid in Set(uids) {
            if let cached = Self.bulkUserCache[uid] {
                result[uid] = cached
            } else {
                missing.append(uid)
            }
        }
        Self.bulkUserCacheLock.unlock()
        guard !missing.isEmpty else { return result }
        let chunks = stride(from: 0, to: missing.count, by: 30).map { Array(missing[$0..<min($0 + 30, missing.count)]) }
        let fetched = await withTaskGroup(of: [(String, User)].self) { group in
            for chunk in chunks {
                group.addTask { [self] in
                    do {
                        let snapshot = try await db.collection(users)
                            .whereField(FieldPath.documentID(), in: chunk)
                            .getDocuments()
                        return snapshot.documents.compactMap { doc in
                            user(from: doc.data(), uid: doc.documentID).map { (doc.documentID, $0) }
                        }
                    } catch {
                        return []
                    }
                }
            }
            var all: [(String, User)] = []
            for await pairs in group { all.append(contentsOf: pairs) }
            return all
        }
        Self.bulkUserCacheLock.lock()
        for (uid, u) in fetched { Self.bulkUserCache[uid] = u }
        Self.bulkUserCacheLock.unlock()
        for (uid, u) in fetched { result[uid] = u }
        return result
    }

    /// All user profiles for the “Your friends” strip (Firebase uid + `User`). Excludes `excludingUid` if set. Sorted by display name.
    func fetchAllReaderProfiles(excludingUid: String?, limit: Int = 300) async -> [(uid: String, user: User)] {
        do {
            let snapshot = try await db.collection(users).limit(to: limit).getDocuments()
            var rows: [(uid: String, user: User)] = []
            for doc in snapshot.documents {
                if let ex = excludingUid, doc.documentID == ex { continue }
                if HiddenAccounts.isHidden(uid: doc.documentID, viewerUid: excludingUid) { continue }
                let data = doc.data()
                guard let u = user(from: data, uid: doc.documentID) else { continue }
                if OtherReadersExclusion.shouldExclude(firestoreData: data, user: u) { continue }
                rows.append((doc.documentID, u))
            }
            rows.sort { $0.user.displayName.localizedCaseInsensitiveCompare($1.user.displayName) == .orderedAscending }
            return rows
        } catch {
            return []
        }
    }

    /// Profiles for a known set of uids (the people you follow), applying the
    /// same hidden/excluded filtering as the roster pages. Uncached, unlike
    /// `getUsers`, so the strip shows current names and photos.
    func fetchReaderProfiles(uids: [String], excludingUid: String?) async -> [(uid: String, user: User)] {
        let wanted = Array(Set(uids)).filter { $0 != excludingUid }
        guard !wanted.isEmpty else { return [] }
        let chunks = stride(from: 0, to: wanted.count, by: 30).map {
            Array(wanted[$0..<min($0 + 30, wanted.count)])
        }
        return await withTaskGroup(of: [(uid: String, user: User)].self) { group in
            for chunk in chunks {
                group.addTask { [self] in
                    do {
                        let snapshot = try await db.collection(users)
                            .whereField(FieldPath.documentID(), in: chunk)
                            .getDocuments()
                        return snapshot.documents.compactMap { doc -> (uid: String, user: User)? in
                            if HiddenAccounts.isHidden(uid: doc.documentID, viewerUid: excludingUid) { return nil }
                            let data = doc.data()
                            guard let u = user(from: data, uid: doc.documentID) else { return nil }
                            if OtherReadersExclusion.shouldExclude(firestoreData: data, user: u) { return nil }
                            return (doc.documentID, u)
                        }
                    } catch {
                        return []
                    }
                }
            }
            var all: [(uid: String, user: User)] = []
            for await rows in group { all.append(contentsOf: rows) }
            return all
        }
    }

    /// Creates a user document in Firestore if one doesn't exist (so first-time Google/Apple sign-in gets an account).
    func ensureUserDocument(uid: String, displayName: String?, email: String?, photoURL: String?) async {
        let ref = db.collection(users).document(uid)
        do {
            let snapshot = try await ref.getDocument()
            if snapshot.exists {
                await migrateHandleClaimIfNeeded(uid: uid, data: snapshot.data())
                var updates: [String: Any] = [:]
                if let e = email?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty {
                    let current = snapshot.data()?["email"] as? String
                    if current != e {
                        updates["email"] = e
                    }
                }
                // Self-heal: catches accounts that predate this flag, or whose
                // matching signature (e.g. a fresh Apple review sign-in) only
                // became known after the doc was first created.
                if snapshot.data()?["isTestAccount"] == nil,
                   TestAccountSignatures.matches(email: email, displayName: displayName) {
                    updates["isTestAccount"] = true
                }
                if !updates.isEmpty {
                    try? await ref.updateData(updates)
                }
                return
            }
            let username = email?.components(separatedBy: "@").first ?? "user_\(String(uid.prefix(8)))"
            let name = displayName?.isEmpty == false ? displayName! : (email ?? "User")
            var newUser: [String: Any] = [
                "username": username,
                "displayName": name,
                "firstName": NSNull(),
                "lastName": NSNull(),
                "profileSetupCompleted": false,
                "bio": NSNull(),
                "profileImageURL": photoURL as Any,
                "joinedAt": Timestamp(date: Date()),
                "totalBooksRead": 0,
                "totalPagesRead": 0,
                // New members start out following the founder; the `onUserCreated` Cloud
                // Function follows them back (rules only allow writing your own doc).
                "following": uid == SpineFounder.uid ? [] : [SpineFounder.uid],
                "hasSeenFounderWelcomeModal": false,
                "hasSeenPushNotificationPrompt": false,
                "readingGoal": NSNull(),
            ]
            if let e = email?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty {
                newUser["email"] = e
            }
            let isTestAccount = TestAccountSignatures.matches(email: email, displayName: displayName)
            if isTestAccount {
                newUser["isTestAccount"] = true
            }
            // OG-stamp eligibility is decided once, right here, and never revisited: accounts
            // that predate this field are grandfathered in (see `User.ogIneligible`), so only
            // brand-new signups get checked against the 250-member cap. `memberNumber` already
            // excludes test accounts, and this doc doesn't exist yet, so its result is exactly
            // "how many real members joined before this one."
            if isTestAccount {
                newUser["ogIneligible"] = true
            } else {
                let realCountBeforeThisSignup = await memberNumber(joinedAt: Date()) ?? Int.max
                if realCountBeforeThisSignup >= LibraryCardDetails.ogCutoff {
                    newUser["ogIneligible"] = true
                }
            }
            try await ref.setData(newUser)
            try await setHandleClaim(handle: username, uid: uid)
        } catch {
            // Log in real app; for now we continue so auth still works
        }
    }

    /// Uses `handleClaims/{handle}` single-doc read (`.server` avoids cache listener quirks in logs).
    func checkUsernameAvailability(_ rawHandle: String, excludingUid: String) async -> HandleAvailabilityCheck {
        let handle = rawHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !handle.isEmpty else { return .taken }
        let ref = db.collection(handleClaims).document(handle)
        #if DEBUG
        print("HANDLE CHECK: path=\(handleClaims)/\(handle) excludingUid=\(excludingUid) source=.server")
        #endif
        do {
            let snap = try await ref.getDocument(source: .server)
            #if DEBUG
            let ownerStr = snap.data()?["uid"] as? String
            print("HANDLE CHECK SUCCESS: exists=\(snap.exists) ownerUid=\(ownerStr ?? "nil")")
            #endif
            if !snap.exists { return .available }
            if let owner = snap.data()?["uid"] as? String, owner == excludingUid {
                return .available
            }
            return .taken
        } catch {
            #if DEBUG
            print("HANDLE CHECK ERROR:", error.localizedDescription)
            print("HANDLE CHECK FULL ERROR:", error)
            #endif
            return .failed(underlying: error)
        }
    }

    /// Backward-compatible wrapper (treats failures as unavailable — prefer `checkUsernameAvailability`).
    func isUsernameAvailable(_ rawHandle: String, excludingUid: String) async -> Bool {
        switch await checkUsernameAvailability(rawHandle, excludingUid: excludingUid) {
        case .available: return true
        case .taken, .failed: return false
        }
    }

    /// First-time profile after SSO (or edit profile): name, handle, yearly book goal, marks onboarding complete.
    /// Pass `readingInterestTags` to set taste tags from `Tags.csv`. When `enforceMinimumReadingInterestTags` is true (default), at least two tags are required—use false when saving from Edit profile so the user can clear or pick fewer.
    func completeProfileSetup(uid: String, firstName: String, lastName: String, handle: String, readingGoal: Int?, readingInterestTags: [String]? = nil, enforceMinimumReadingInterestTags: Bool = true) async throws {
        let trimmedFirst = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLast = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch await checkUsernameAvailability(h, excludingUid: uid) {
        case .available:
            break
        case .taken:
            throw NSError(domain: "UserRepository", code: 409, userInfo: [NSLocalizedDescriptionKey: "That handle is already taken."])
        case .failed(let err):
            throw NSError(
                domain: "UserRepository",
                code: 503,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not verify your handle (Firestore). Deploy rules for the \"wellread\" database, including handleClaims. Error: \(err.localizedDescription)",
                ]
            )
        }
        let display = [trimmedFirst, trimmedLast].filter { !$0.isEmpty }.joined(separator: " ")
        let userRef = db.collection(users).document(uid)
        let userSnap = try await userRef.getDocument()
        guard userSnap.exists else {
            throw NSError(domain: "UserRepository", code: 404, userInfo: [NSLocalizedDescriptionKey: "Account not found. Try signing in again."])
        }
        let oldHandle = (userSnap.data()?["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var profileFields: [String: Any] = [
            "firstName": trimmedFirst,
            "lastName": trimmedLast,
            "username": h,
            "displayName": display.isEmpty ? h : display,
            "profileSetupCompleted": true,
        ]
        if let g = readingGoal {
            profileFields["readingGoal"] = g
        } else {
            profileFields["readingGoal"] = NSNull()
        }

        if let tags = readingInterestTags {
            let canonical = SpineTagCatalog.shared.whitelist(tags)
            if enforceMinimumReadingInterestTags, canonical.count < 2 {
                throw NSError(domain: "UserRepository", code: 400, userInfo: [NSLocalizedDescriptionKey: "Choose at least two reading topics."])
            }
            profileFields["readingInterestTags"] = canonical
        }

        let batch = db.batch()
        batch.updateData(profileFields, forDocument: userRef)

        let newClaimRef = db.collection(handleClaims).document(h)
        batch.setData(["uid": uid], forDocument: newClaimRef, merge: true)

        if let old = oldHandle, old != h {
            let oldClaimRef = db.collection(handleClaims).document(old)
            let oldSnap = try await oldClaimRef.getDocument()
            if oldSnap.exists, oldSnap.data()?["uid"] as? String == uid {
                batch.deleteDocument(oldClaimRef)
            }
        }

        try await batch.commit()
    }

    private func setHandleClaim(handle: String, uid: String) async throws {
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !h.isEmpty else { return }
        try await db.collection(handleClaims).document(h).setData(["uid": uid], merge: true)
    }

    /// Backfill `handleClaims` for accounts created before this collection existed.
    private func migrateHandleClaimIfNeeded(uid: String, data: [String: Any]?) async {
        guard let data, let username = data["username"] as? String else { return }
        let h = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !h.isEmpty else { return }
        let ref = db.collection(handleClaims).document(h)
        do {
            let snap = try await ref.getDocument()
            if !snap.exists {
                try await ref.setData(["uid": uid], merge: true)
                return
            }
            if let owner = snap.data()?["uid"] as? String, owner == uid { return }
            // Another user already owns this handle in claims; leave as-is.
        } catch {
            #if DEBUG
            print("UserRepository.migrateHandleClaimIfNeeded error: \(error)")
            #endif
        }
    }

    /// Update profile fields (only provided non-nil values are updated).
    func updateProfile(uid: String, username: String?, displayName: String?, bio: String?, readingGoal: Int?) async throws {
        let ref = db.collection(users).document(uid)
        var data: [String: Any] = [:]
        if let v = username { data["username"] = v }
        if let v = displayName { data["displayName"] = v }
        if let v = bio { data["bio"] = v }
        if let v = readingGoal { data["readingGoal"] = v }
        guard !data.isEmpty else { return }
        try await ref.updateData(data)
    }

    /// Stores the user's phone number (normalized digits) for contact-sync
    /// matching; pass nil/empty to remove it.
    func updatePhoneNumber(uid: String, phoneNumber: String?) async throws {
        let normalized = ContactSyncService.normalizePhoneNumber(phoneNumber ?? "")
        try await db.collection(users).document(uid).updateData([
            "phoneNumber": normalized.isEmpty ? FieldValue.delete() : normalized,
        ])
    }

    /// Persist Discover tuning criteria as a map field on the user doc.
    func updateDiscoverCriteria(uid: String, criteria: DiscoverCriteria) async throws {
        var sanitized = criteria
        sanitized.tags = SpineTagCatalog.shared.whitelist(sanitized.tags)
        try await db.collection(users).document(uid).updateData([
            "discoverCriteria": sanitized.firestoreMap,
        ])
    }

    /// Update the user's profile image URL in Firestore.
    func updateProfileImageURL(uid: String, url: String) async throws {
        try await db.collection(users).document(uid).updateData([
            "profileImageURL": url,
        ])
    }

    /// Increment totalBooksRead by 1.
    func incrementTotalBooksRead(uid: String) async throws {
        try await db.collection(users).document(uid).updateData([
            "totalBooksRead": FieldValue.increment(Int64(1)),
        ])
    }

    /// Increment totalPagesRead by the given count.
    func incrementTotalPagesRead(uid: String, pages: Int) async throws {
        try await db.collection(users).document(uid).updateData([
            "totalPagesRead": FieldValue.increment(Int64(pages)),
        ])
    }

    // MARK: - Push (FCM)

    /// Stores an FCM registration token under `users/{uid}/fcmTokens/{hash}` for Cloud Messaging.
    func saveFCMToken(uid: String, token: String) async throws {
        let docId = Self.fcmTokenDocumentId(for: token)
        try await db.collection(users).document(uid).collection("fcmTokens").document(docId).setData([
            "token": token,
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true)
    }

    func removeFCMToken(uid: String, token: String) async throws {
        let docId = Self.fcmTokenDocumentId(for: token)
        try await db.collection(users).document(uid).collection("fcmTokens").document(docId).delete()
    }

    /// Confirms `saveFCMToken` wrote the expected doc (same id as SHA256 hash of token).
    func fcmTokenDocumentExists(uid: String, token: String) async throws -> Bool {
        let docId = Self.fcmTokenDocumentId(for: token)
        let snap = try await db.collection(users).document(uid).collection("fcmTokens").document(docId).getDocument()
        return snap.exists
    }

    // MARK: - Follow graph

    /// Number of accounts that follow `uid` (their `following` contains the uid). O(n) query; fine for early scale.
    func countUsersFollowing(uid: String) async -> Int {
        do {
            let snapshot = try await db.collection(users)
                .whereField("following", arrayContains: uid)
                .getDocuments()
            return snapshot.documents.count
        } catch {
            return 0
        }
    }

    /// The accounts that follow `uid`, as profiles (their `following` contains the
    /// uid). Same O(n) query as `countUsersFollowing`; hidden accounts are dropped
    /// for everyone but their viewers. Sorted by display name.
    func usersFollowingProfiles(uid: String, viewerUid: String?) async -> [(uid: String, user: User)] {
        do {
            let snapshot = try await db.collection(users)
                .whereField("following", arrayContains: uid)
                .getDocuments()
            var rows: [(uid: String, user: User)] = []
            for doc in snapshot.documents {
                if HiddenAccounts.isHidden(uid: doc.documentID, viewerUid: viewerUid) { continue }
                guard let u = user(from: doc.data(), uid: doc.documentID) else { continue }
                rows.append((doc.documentID, u))
            }
            rows.sort { $0.user.displayName.localizedCaseInsensitiveCompare($1.user.displayName) == .orderedAscending }
            return rows
        } catch {
            return []
        }
    }

    /// Persists dismissal of the first-time feed welcome modal (`users/{uid}.hasSeenFounderWelcomeModal`).
    func markHasSeenFounderWelcomeModal(uid: String) async throws {
        try await db.collection(users).document(uid).updateData([
            "hasSeenFounderWelcomeModal": true,
        ])
    }

    /// After the one-time push notification onboarding prompt (`users/{uid}.hasSeenPushNotificationPrompt`).
    func markHasSeenPushNotificationPrompt(uid: String) async throws {
        try await db.collection(users).document(uid).updateData([
            "hasSeenPushNotificationPrompt": true,
        ])
    }

    /// Hide `targetUid` from the feed's "Readers to follow" suggestions for good
    /// (`dismissedRecommendedUids` array on the signed-in user's document).
    func addDismissedRecommendedUid(currentUid: String, targetUid: String) async throws {
        guard currentUid != targetUid else { return }
        try await db.collection(users).document(currentUid)
            .updateData(["dismissedRecommendedUids": FieldValue.arrayUnion([targetUid])])
    }

    /// Follow or unfollow `targetUid` from the signed-in user’s document only (`following` array).
    func setFollowing(currentUid: String, targetUid: String, follow: Bool) async throws {
        guard currentUid != targetUid else { return }
        let ref = db.collection(users).document(currentUid)
        if follow {
            try await ref.updateData(["following": FieldValue.arrayUnion([targetUid])])
        } else {
            try await ref.updateData(["following": FieldValue.arrayRemove([targetUid])])
        }
    }

    private static func fcmTokenDocumentId(for token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func user(from data: [String: Any], uid: String) -> User? {
        guard let username = data["username"] as? String,
              let displayName = data["displayName"] as? String,
              let joinedAt = (data["joinedAt"] as? Timestamp)?.dateValue() else { return nil }
        let totalBooksRead = (data["totalBooksRead"] as? Int) ?? 0
        let totalPagesRead = (data["totalPagesRead"] as? Int) ?? 0
        let readingGoal = data["readingGoal"] as? Int
        let firstName = data["firstName"] as? String
        let lastName = data["lastName"] as? String
        // Missing field used to default to true, which hid the profile sheet for legacy/incomplete accounts.
        let profileSetupCompleted: Bool
        if let explicit = data["profileSetupCompleted"] as? Bool {
            profileSetupCompleted = explicit
        } else {
            let f = firstName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let l = lastName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            profileSetupCompleted = !f.isEmpty && !l.isEmpty
        }
        let following = data["following"] as? [String] ?? []
        // Missing field: show once to everyone, including accounts that saw the old community modal.
        let hasSeenFounderWelcomeModal = data["hasSeenFounderWelcomeModal"] as? Bool ?? false
        // Missing field: treat as already seen so existing accounts aren’t prompted after shipping this feature.
        let hasSeenPushNotificationPrompt = data["hasSeenPushNotificationPrompt"] as? Bool ?? true
        return User(
            id: UUID(),
            username: username,
            displayName: displayName,
            firstName: firstName,
            lastName: lastName,
            profileSetupCompleted: profileSetupCompleted,
            bio: data["bio"] as? String,
            phoneNumber: data["phoneNumber"] as? String,
            profileImageURL: data["profileImageURL"] as? String,
            joinedAt: joinedAt,
            following: following,
            hasSeenFounderWelcomeModal: hasSeenFounderWelcomeModal,
            hasSeenPushNotificationPrompt: hasSeenPushNotificationPrompt,
            totalBooksRead: totalBooksRead,
            totalPagesRead: totalPagesRead,
            readingGoal: readingGoal,
            readingInterestTags: data["readingInterestTags"] as? [String] ?? [],
            discoverCriteria: DiscoverCriteria(firestoreMap: data["discoverCriteria"] as? [String: Any]),
            // Missing field: grandfathered in as OG-eligible (see `User.ogIneligible`).
            ogIneligible: data["ogIneligible"] as? Bool ?? false,
            dismissedRecommendedUids: data["dismissedRecommendedUids"] as? [String] ?? []
        )
    }
}
