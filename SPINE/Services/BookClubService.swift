//
//  BookClubService.swift
//  SPINE
//
//  Firestore access for private book clubs. Reads are live listeners; writes
//  that touch membership integrity (joining by code, phone invites) go through
//  Cloud Functions so a non-member never needs read access to a club doc.
//

import Foundation
import CryptoKit
import FirebaseFirestore
import FirebaseFunctions

enum BookClubError: LocalizedError {
    case invalidCode
    case notFound
    case clubFull
    case notSignedIn
    case couldNotGenerateCode
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidCode: return "That doesn't look like a club code. Codes are 6 letters and numbers."
        case .notFound: return "No club with that code. Double-check it with whoever invited you."
        case .clubFull: return "That club is full."
        case .notSignedIn: return "Sign in to use clubs."
        case .couldNotGenerateCode: return "Couldn't set up an invite code. Try again."
        case .server(let message): return message
        }
    }
}

final class BookClubService {
    static let shared = BookClubService()

    private let db = FirestoreDatabase.firestore
    private let clubsCollection = "clubs"
    private let codesCollection = "clubInviteCodes"
    private let functions = Functions.functions(region: "us-central1")

    private init() {}

    // MARK: - Reads

    /// Every club the reader belongs to. Sorted client-side (newest activity
    /// first) so the query needs no composite index.
    func listenMyClubs(uid: String, onUpdate: @escaping ([BookClub]) -> Void) -> ListenerRegistration {
        db.collection(clubsCollection)
            .whereField("memberIds", arrayContains: uid)
            .addSnapshotListener { snapshot, _ in
                guard let snapshot else { return }
                let clubs = snapshot.documents
                    .compactMap { BookClub.from(data: $0.data(), docId: $0.documentID) }
                    .sorted { $0.updatedAt > $1.updatedAt }
                DispatchQueue.main.async { onUpdate(clubs) }
            }
    }

    func listenClub(clubId: String, onUpdate: @escaping (BookClub?) -> Void) -> ListenerRegistration {
        db.collection(clubsCollection).document(clubId).addSnapshotListener { snapshot, _ in
            guard let snapshot else { return }
            let club = snapshot.data().flatMap { BookClub.from(data: $0, docId: snapshot.documentID) }
            DispatchQueue.main.async { onUpdate(club) }
        }
    }

    func fetchClub(clubId: String) async -> BookClub? {
        guard let snapshot = try? await db.collection(clubsCollection).document(clubId).getDocument(),
              let data = snapshot.data() else { return nil }
        return BookClub.from(data: data, docId: snapshot.documentID)
    }

    // MARK: - Create

    /// Creates the club and claims its invite code in one transaction. The code
    /// doc is create-only in the rules, so a collision (astronomically unlikely
    /// with 31^6 codes) fails the transaction and we roll a new one.
    func createClub(
        name: String,
        creatorUid: String,
        creator: User?,
        everyoneIsAdmin: Bool,
        initialMembers: [(uid: String, user: User)]
    ) async throws -> BookClub {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(BookClub.maxNameLength))
        let now = Date()
        var members: [String: BookClub.Member] = [:]
        if let creator {
            members[creatorUid] = BookClub.Member(user: creator, joinedAt: now)
        } else {
            members[creatorUid] = BookClub.Member(firstName: "You", displayName: "You", username: "", photoURL: nil, joinedAt: now)
        }
        var memberIds = [creatorUid]
        for entry in initialMembers where entry.uid != creatorUid && !memberIds.contains(entry.uid) {
            guard memberIds.count < BookClub.maxMembers else { break }
            memberIds.append(entry.uid)
            members[entry.uid] = BookClub.Member(user: entry.user, joinedAt: now)
        }

        let clubRef = db.collection(clubsCollection).document()
        for _ in 0..<5 {
            let code = BookClub.generateInviteCode()
            let club = BookClub(
                id: clubRef.documentID,
                name: trimmed,
                createdBy: creatorUid,
                createdAt: now,
                updatedAt: now,
                updatedBy: creatorUid,
                memberIds: memberIds,
                adminIds: [creatorUid],
                everyoneIsAdmin: everyoneIsAdmin,
                members: members,
                inviteCode: code,
                currentPick: nil,
                pastPicks: []
            )
            let codeRef = db.collection(codesCollection).document(code)
            do {
                _ = try await db.runTransaction { transaction, errorPointer in
                    do {
                        let existing = try transaction.getDocument(codeRef)
                        if existing.exists {
                            errorPointer?.pointee = NSError(domain: "BookClubService", code: 409, userInfo: nil)
                            return nil
                        }
                    } catch let error as NSError {
                        errorPointer?.pointee = error
                        return nil
                    }
                    transaction.setData([
                        "clubId": clubRef.documentID,
                        "createdBy": creatorUid,
                        "createdAt": Timestamp(date: now),
                    ], forDocument: codeRef)
                    transaction.setData(club.firestoreData, forDocument: clubRef)
                    return nil
                }
                Analytics.amplitude?.track(eventType: "Created Book Club", eventProperties: [
                    "club_id": club.id,
                    "everyone_is_admin": everyoneIsAdmin,
                    "initial_member_count": memberIds.count,
                ])
                return club
            } catch let error as NSError where error.domain == "BookClubService" && error.code == 409 {
                continue
            }
        }
        throw BookClubError.couldNotGenerateCode
    }

    // MARK: - Membership

    func addMembers(clubId: String, actorUid: String, users: [(uid: String, user: User)]) async throws {
        guard !users.isEmpty else { return }
        var update: [String: Any] = [
            "memberIds": FieldValue.arrayUnion(users.map(\.uid)),
            "updatedAt": FieldValue.serverTimestamp(),
            "updatedBy": actorUid,
        ]
        let now = Date()
        for entry in users {
            update["members.\(entry.uid)"] = BookClub.Member(user: entry.user, joinedAt: now).firestoreData
        }
        try await db.collection(clubsCollection).document(clubId).updateData(update)
        Analytics.amplitude?.track(eventType: "Added Club Members", eventProperties: ["club_id": clubId, "count": users.count])
    }

    func removeMember(clubId: String, actorUid: String, uid: String) async throws {
        try await db.collection(clubsCollection).document(clubId).updateData([
            "memberIds": FieldValue.arrayRemove([uid]),
            "adminIds": FieldValue.arrayRemove([uid]),
            "members.\(uid)": FieldValue.delete(),
            "updatedAt": FieldValue.serverTimestamp(),
            "updatedBy": actorUid,
        ])
    }

    /// Leaving as the last member deletes the club outright.
    func leave(club: BookClub, myUid: String) async throws {
        if club.memberIds == [myUid] {
            try await deleteClub(club)
            return
        }
        try await removeMember(clubId: club.id, actorUid: myUid, uid: myUid)
        Analytics.amplitude?.track(eventType: "Left Book Club", eventProperties: ["club_id": club.id])
    }

    func setAdmin(clubId: String, actorUid: String, uid: String, isAdmin: Bool) async throws {
        try await db.collection(clubsCollection).document(clubId).updateData([
            "adminIds": isAdmin ? FieldValue.arrayUnion([uid]) : FieldValue.arrayRemove([uid]),
            "updatedAt": FieldValue.serverTimestamp(),
            "updatedBy": actorUid,
        ])
    }

    func setEveryoneIsAdmin(clubId: String, actorUid: String, value: Bool) async throws {
        try await db.collection(clubsCollection).document(clubId).updateData([
            "everyoneIsAdmin": value,
            "updatedAt": FieldValue.serverTimestamp(),
            "updatedBy": actorUid,
        ])
    }

    func rename(clubId: String, actorUid: String, name: String) async throws {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(BookClub.maxNameLength))
        guard !trimmed.isEmpty else { return }
        try await db.collection(clubsCollection).document(clubId).updateData([
            "name": trimmed,
            "updatedAt": FieldValue.serverTimestamp(),
            "updatedBy": actorUid,
        ])
    }

    func deleteClub(_ club: BookClub) async throws {
        // The invite-code doc is cleaned up by the onClubWritten function.
        try await db.collection(clubsCollection).document(club.id).delete()
    }

    // MARK: - Picks and meetings

    /// Sets the next book. The outgoing pick (if any) moves to the top of the
    /// history so the club's shelf keeps growing.
    func setCurrentPick(club: BookClub, actorUid: String, book: Book, meetingAt: Date?) async throws {
        let pick = BookClub.Pick(book: book, chosenBy: actorUid, meetingAt: meetingAt)
        var history = club.pastPicks
        if let outgoing = club.currentPick, outgoing.bookId != pick.bookId {
            history.insert(outgoing, at: 0)
        }
        history = Array(history.prefix(60))
        try await db.collection(clubsCollection).document(club.id).updateData([
            "currentPick": pick.firestoreData,
            "pastPicks": history.map { $0.firestoreData },
            "updatedAt": FieldValue.serverTimestamp(),
            "updatedBy": actorUid,
        ])
        Analytics.amplitude?.track(eventType: "Set Club Book", eventProperties: [
            "club_id": club.id,
            "book_id": book.id,
            "has_meeting_date": meetingAt != nil,
        ])
    }

    func setMeeting(club: BookClub, actorUid: String, meetingAt: Date?) async throws {
        guard club.currentPick != nil else { return }
        try await db.collection(clubsCollection).document(club.id).updateData([
            "currentPick.meetingAt": meetingAt.map { Timestamp(date: $0) } ?? NSNull(),
            "currentPick.reminderSentAt": NSNull(),
            "updatedAt": FieldValue.serverTimestamp(),
            "updatedBy": actorUid,
        ])
    }

    /// "We're done with this one": shelves the current pick with no replacement.
    func archiveCurrentPick(club: BookClub, actorUid: String) async throws {
        guard let outgoing = club.currentPick else { return }
        var history = club.pastPicks
        history.insert(outgoing, at: 0)
        try await db.collection(clubsCollection).document(club.id).updateData([
            "currentPick": NSNull(),
            "pastPicks": Array(history.prefix(60)).map { $0.firestoreData },
            "updatedAt": FieldValue.serverTimestamp(),
            "updatedBy": actorUid,
        ])
    }

    // MARK: - Joining

    /// Redeems an invite code via the `joinClubByCode` function and returns the club id.
    func joinClub(code rawCode: String) async throws -> String {
        guard let code = BookClub.normalizeInviteCode(rawCode) else { throw BookClubError.invalidCode }
        do {
            let result = try await functions.httpsCallable("joinClubByCode").call(["code": code])
            guard let payload = result.data as? [String: Any],
                  let clubId = payload["clubId"] as? String else {
                throw BookClubError.server("Unexpected response. Try again.")
            }
            Analytics.amplitude?.track(eventType: "Joined Book Club", eventProperties: [
                "club_id": clubId,
                "already_member": (payload["alreadyMember"] as? Bool) ?? false,
            ])
            return clubId
        } catch let error as NSError where error.domain == FunctionsErrorDomain {
            switch FunctionsErrorCode(rawValue: error.code) {
            case .notFound: throw BookClubError.notFound
            case .resourceExhausted: throw BookClubError.clubFull
            case .invalidArgument: throw BookClubError.invalidCode
            case .unauthenticated: throw BookClubError.notSignedIn
            default: throw BookClubError.server(error.localizedDescription)
            }
        }
    }

    // MARK: - Phone invites

    /// The server only ever sees a hash of the last ten digits, the same key the
    /// on-device contact matcher uses. When someone later joins SPINE with that
    /// number they are dropped straight into the club.
    static func phoneInviteHash(_ rawPhone: String) -> String? {
        let digits = ContactSyncService.normalizePhoneNumber(rawPhone)
        guard digits.count >= 10 else { return nil }
        let key = String(digits.suffix(10))
        let hash = SHA256.hash(data: Data(key.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns how many numbers were registered.
    @discardableResult
    func invitePhones(clubId: String, phoneNumbers: [String]) async throws -> Int {
        let hashes = Array(Set(phoneNumbers.compactMap(Self.phoneInviteHash))).prefix(50)
        guard !hashes.isEmpty else { return 0 }
        let result = try await functions.httpsCallable("inviteClubPhones").call([
            "clubId": clubId,
            "hashes": Array(hashes),
        ])
        let count = ((result.data as? [String: Any])?["count"] as? Int) ?? hashes.count
        Analytics.amplitude?.track(eventType: "Invited Club Phones", eventProperties: ["club_id": clubId, "count": count])
        return count
    }

    // MARK: - Member progress

    /// Live `userBooks` rows for the current pick across the club, keyed by uid.
    /// One listener per 30 members (Firestore's `in` cap).
    func listenMemberProgress(
        memberIds: [String],
        bookId: String,
        onUpdate: @escaping ([String: UserBook]) -> Void
    ) -> [ListenerRegistration] {
        let chunks = stride(from: 0, to: memberIds.count, by: 30).map { Array(memberIds[$0..<min($0 + 30, memberIds.count)]) }
        guard !chunks.isEmpty else { return [] }
        var perChunk: [Int: [String: UserBook]] = [:]
        let lock = NSLock()
        return chunks.enumerated().map { index, chunk in
            db.collection("userBooks")
                .whereField("bookId", isEqualTo: bookId)
                .whereField("userId", in: chunk)
                .addSnapshotListener { snapshot, _ in
                    guard let snapshot else { return }
                    var rows: [String: UserBook] = [:]
                    for doc in snapshot.documents {
                        guard let row = Self.progressRow(from: doc.data(), docId: doc.documentID) else { continue }
                        // A member can hold two rows for one book (a re-read); keep the furthest along.
                        if let existing = rows[row.userId] {
                            let existingRank = Self.progressRank(existing)
                            if Self.progressRank(row) <= existingRank { continue }
                        }
                        rows[row.userId] = row
                    }
                    lock.lock()
                    perChunk[index] = rows
                    let merged = perChunk.values.reduce(into: [String: UserBook]()) { acc, part in acc.merge(part) { a, _ in a } }
                    lock.unlock()
                    DispatchQueue.main.async { onUpdate(merged) }
                }
        }
    }

    private static func progressRank(_ row: UserBook) -> Double {
        switch row.status {
        case .read: return 2
        case .didNotFinish: return -1
        default: return row.progressFraction
        }
    }

    /// Minimal decode: only the fields progress needs. The full mapper lives in
    /// UserBookRepository and pulls the book doc, which this list never shows.
    private static func progressRow(from data: [String: Any], docId: String) -> UserBook? {
        guard let userId = data["userId"] as? String,
              let bookId = data["bookId"] as? String else { return nil }
        let statusRaw = (data["status"] as? String) ?? ""
        let status: ReadingStatus
        switch statusRaw {
        case "Read": status = .read
        case "Currently Reading": status = .currentlyReading
        case "Did Not Finish": status = .didNotFinish
        default: status = .wantToRead
        }
        let shelf = (data["queueShelf"] as? String).flatMap(QueueShelf.init(rawValue:))
        return UserBook(
            id: UUID(uuidString: docId) ?? UUID(),
            userId: userId,
            bookId: bookId,
            book: nil,
            status: status,
            rating: data["rating"] as? Double,
            reviewText: nil,
            dateStarted: (data["dateStarted"] as? Timestamp)?.dateValue(),
            dateFinished: (data["dateFinished"] as? Timestamp)?.dateValue(),
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date(),
            recommendedTo: [],
            tier: data["tier"] as? String,
            tierOrder: nil,
            queueShelf: shelf,
            queueOrder: nil,
            readingProgress: data["readingProgress"] as? Double
        )
    }
}
