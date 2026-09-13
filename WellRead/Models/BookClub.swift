//
//  BookClub.swift
//  SPINE
//
//  A private book club: a handful of readers, one book at a time, one meeting
//  date everybody is reading toward. One Firestore doc per club (`clubs/{id}`);
//  membership lives on the doc (`memberIds`) so a single array-contains query
//  lists a reader's clubs and the security rules can gate on it.
//
//  Chat stays in iMessage/WhatsApp on purpose. SPINE owns the parts a group
//  chat is bad at: who is in, who has read how far, what is next, and when.
//

import Foundation
import FirebaseFirestore

struct BookClub: Identifiable, Equatable {
    /// Firestore doc id (random).
    let id: String
    var name: String
    var createdBy: String
    var createdAt: Date
    var updatedAt: Date
    /// Written on every client write so the notification function can tell who
    /// acted (and skip pushing the actor about their own change).
    var updatedBy: String?
    /// Firebase uids. Capped at `maxMembers`.
    var memberIds: [String]
    /// Uids allowed to change the book, meeting, and membership. Ignored when
    /// `everyoneIsAdmin` is on.
    var adminIds: [String]
    var everyoneIsAdmin: Bool
    /// uid → display snapshot taken when they joined (avoids N user fetches per render).
    var members: [String: Member]
    /// Six-character join code, also the last path segment of the invite link.
    var inviteCode: String
    var currentPick: Pick?
    /// Most recent first.
    var pastPicks: [Pick]

    static let maxMembers = 50
    static let maxNameLength = 40

    struct Member: Codable, Equatable {
        var firstName: String
        var displayName: String
        var username: String
        var photoURL: String?
        var joinedAt: Date

        init(firstName: String, displayName: String, username: String, photoURL: String?, joinedAt: Date) {
            self.firstName = firstName
            self.displayName = displayName
            self.username = username
            self.photoURL = photoURL
            self.joinedAt = joinedAt
        }

        init(user: User, joinedAt: Date = Date()) {
            let first = user.firstName?.trimmingCharacters(in: .whitespaces) ?? ""
            self.firstName = first.isEmpty ? (user.displayName.split(separator: " ").first.map(String.init) ?? user.displayName) : first
            self.displayName = user.displayName
            self.username = user.username
            self.photoURL = user.profileImageURL
            self.joinedAt = joinedAt
        }

        /// A `User` shaped from the snapshot, for avatar/profile components.
        var asUser: User {
            User(
                id: UUID(),
                username: username,
                displayName: displayName,
                firstName: firstName,
                lastName: nil,
                profileSetupCompleted: true,
                bio: nil,
                phoneNumber: nil,
                profileImageURL: photoURL,
                joinedAt: joinedAt,
                following: [],
                hasSeenFounderWelcomeModal: true,
                hasSeenPushNotificationPrompt: true,
                totalBooksRead: 0,
                totalPagesRead: 0,
                readingGoal: nil,
                readingInterestTags: []
            )
        }
    }

    /// One book the club read (or is reading). `bookId` matches `userBooks.bookId`,
    /// which is how member progress is joined.
    struct Pick: Codable, Equatable, Identifiable {
        var id: String
        var bookId: String
        var title: String
        var author: String
        var coverURL: String
        var pageCount: Int?
        var chosenAt: Date
        var chosenBy: String?
        /// The next meeting: the date everybody is reading toward.
        var meetingAt: Date?
        /// Set once the day-before reminder went out, so the hourly sweep never repeats it.
        var reminderSentAt: Date?

        init(id: String = UUID().uuidString, book: Book, chosenBy: String?, meetingAt: Date?, chosenAt: Date = Date()) {
            self.id = id
            self.bookId = book.id
            self.title = book.title
            self.author = book.author
            self.coverURL = book.coverOverrideURL ?? book.coverURL
            self.pageCount = book.pageCount
            self.chosenAt = chosenAt
            self.chosenBy = chosenBy
            self.meetingAt = meetingAt
            self.reminderSentAt = nil
        }

        init(id: String, bookId: String, title: String, author: String, coverURL: String, pageCount: Int?, chosenAt: Date, chosenBy: String?, meetingAt: Date?, reminderSentAt: Date? = nil) {
            self.id = id
            self.bookId = bookId
            self.title = title
            self.author = author
            self.coverURL = coverURL
            self.pageCount = pageCount
            self.chosenAt = chosenAt
            self.chosenBy = chosenBy
            self.meetingAt = meetingAt
            self.reminderSentAt = reminderSentAt
        }

        /// A `Book` for cover rendering and the profile page. Sparse: the profile
        /// fills the rest from the catalog.
        var asBook: Book {
            Book(id: bookId, title: title, author: author, coverURL: coverURL, pageCount: pageCount, publishedDate: nil, description: nil, genres: [])
        }

        var meetingIsPast: Bool {
            guard let meetingAt else { return false }
            return meetingAt < Date()
        }
    }

    // MARK: - Membership helpers

    func isMember(_ uid: String) -> Bool { memberIds.contains(uid) }

    func isAdmin(_ uid: String) -> Bool {
        everyoneIsAdmin || adminIds.contains(uid)
    }

    /// Members in join order (creator first).
    var orderedMemberIds: [String] {
        memberIds.sorted { a, b in
            let ja = members[a]?.joinedAt ?? .distantFuture
            let jb = members[b]?.joinedAt ?? .distantFuture
            if ja != jb { return ja < jb }
            return a < b
        }
    }

    func member(_ uid: String) -> Member? { members[uid] }

    func firstName(of uid: String) -> String {
        members[uid]?.firstName ?? "Someone"
    }

    var isFull: Bool { memberIds.count >= Self.maxMembers }

    /// The people who can pick the next book, for "Waiting on Alexis" copy.
    var adminNames: [String] {
        if everyoneIsAdmin { return orderedMemberIds.map { firstName(of: $0) } }
        return adminIds.compactMap { members[$0]?.firstName }
    }

    // MARK: - Invite codes

    /// Unambiguous alphabet: no 0/O, 1/I/L so a code survives being read aloud.
    private static let codeAlphabet: [Character] = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let inviteCodeLength = 6

    static func generateInviteCode() -> String {
        String((0..<inviteCodeLength).map { _ in codeAlphabet.randomElement()! })
    }

    /// Uppercases and strips separators; nil unless it is exactly one code long.
    /// Lookalike glyphs are left alone: the server lookup simply misses, and the
    /// alphabet never produces them in the first place.
    static func normalizeInviteCode(_ raw: String) -> String? {
        let cleaned = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard cleaned.count == inviteCodeLength else { return nil }
        return String(cleaned)
    }

    /// Deep link a member shares: opens the app straight into the join flow.
    var inviteURL: URL {
        URL(string: "wellread://club/join/\(inviteCode)")!
    }

    // MARK: - Firestore mapping

    var firestoreData: [String: Any] {
        var data: [String: Any] = [
            "name": name,
            "createdBy": createdBy,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt),
            "memberIds": memberIds,
            "adminIds": adminIds,
            "everyoneIsAdmin": everyoneIsAdmin,
            "inviteCode": inviteCode,
            "members": members.mapValues { $0.firestoreData },
            "pastPicks": pastPicks.map { $0.firestoreData },
        ]
        data["updatedBy"] = updatedBy ?? NSNull()
        data["currentPick"] = currentPick?.firestoreData ?? NSNull()
        return data
    }

    static func from(data: [String: Any], docId: String) -> BookClub? {
        guard let name = data["name"] as? String,
              let createdBy = data["createdBy"] as? String,
              let memberIds = data["memberIds"] as? [String] else { return nil }
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        var members: [String: Member] = [:]
        if let map = data["members"] as? [String: Any] {
            for (uid, raw) in map {
                if let m = raw as? [String: Any], let member = Member.from(data: m) {
                    members[uid] = member
                }
            }
        }
        let pastPicks = ((data["pastPicks"] as? [[String: Any]]) ?? []).compactMap { Pick.from(data: $0) }
        return BookClub(
            id: docId,
            name: name,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue() ?? createdAt,
            updatedBy: data["updatedBy"] as? String,
            memberIds: memberIds,
            adminIds: (data["adminIds"] as? [String]) ?? [createdBy],
            everyoneIsAdmin: (data["everyoneIsAdmin"] as? Bool) ?? false,
            members: members,
            inviteCode: (data["inviteCode"] as? String) ?? "",
            currentPick: (data["currentPick"] as? [String: Any]).flatMap { Pick.from(data: $0) },
            pastPicks: pastPicks
        )
    }
}

extension BookClub.Member {
    var firestoreData: [String: Any] {
        var d: [String: Any] = [
            "firstName": firstName,
            "displayName": displayName,
            "username": username,
            "joinedAt": Timestamp(date: joinedAt),
        ]
        d["photoURL"] = photoURL ?? NSNull()
        return d
    }

    static func from(data: [String: Any]) -> BookClub.Member? {
        guard let displayName = data["displayName"] as? String else { return nil }
        return BookClub.Member(
            firstName: (data["firstName"] as? String) ?? displayName,
            displayName: displayName,
            username: (data["username"] as? String) ?? "",
            photoURL: data["photoURL"] as? String,
            joinedAt: (data["joinedAt"] as? Timestamp)?.dateValue() ?? Date()
        )
    }
}

extension BookClub.Pick {
    var firestoreData: [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "bookId": bookId,
            "title": title,
            "author": author,
            "coverURL": coverURL,
            "chosenAt": Timestamp(date: chosenAt),
        ]
        d["pageCount"] = pageCount ?? NSNull()
        d["chosenBy"] = chosenBy ?? NSNull()
        d["meetingAt"] = meetingAt.map { Timestamp(date: $0) } ?? NSNull()
        d["reminderSentAt"] = reminderSentAt.map { Timestamp(date: $0) } ?? NSNull()
        return d
    }

    static func from(data: [String: Any]) -> BookClub.Pick? {
        guard let bookId = data["bookId"] as? String,
              let title = data["title"] as? String else { return nil }
        return BookClub.Pick(
            id: (data["id"] as? String) ?? bookId,
            bookId: bookId,
            title: title,
            author: (data["author"] as? String) ?? "",
            coverURL: (data["coverURL"] as? String) ?? "",
            pageCount: data["pageCount"] as? Int,
            chosenAt: (data["chosenAt"] as? Timestamp)?.dateValue() ?? Date(),
            chosenBy: data["chosenBy"] as? String,
            meetingAt: (data["meetingAt"] as? Timestamp)?.dateValue(),
            reminderSentAt: (data["reminderSentAt"] as? Timestamp)?.dateValue()
        )
    }
}

// MARK: - Member progress on the current pick

/// Where one member is on the club's current book, joined from their `userBooks` row.
struct ClubMemberProgress: Identifiable, Equatable {
    enum State: Equatable {
        case notStarted
        case reading(fraction: Double)
        case finished(Date?)
        case didNotFinish
    }

    let uid: String
    let member: BookClub.Member
    let state: State

    var id: String { uid }

    var fraction: Double {
        switch state {
        case .notStarted: return 0
        case .reading(let f): return min(1, max(0, f))
        case .finished: return 1
        case .didNotFinish: return 0
        }
    }

    var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }

    static func state(for userBook: UserBook?) -> State {
        guard let userBook else { return .notStarted }
        switch userBook.status {
        case .read: return .finished(userBook.dateFinished)
        case .didNotFinish: return .didNotFinish
        case .currentlyReading: return .reading(fraction: userBook.progressFraction)
        case .wantToRead:
            if userBook.queueShelf == .readingNow || (userBook.readingProgress ?? 0) > 0 {
                return .reading(fraction: userBook.progressFraction)
            }
            return .notStarted
        }
    }

    /// Sorted for the members list: finished first, then furthest along, then not started.
    static func sorted(_ rows: [ClubMemberProgress]) -> [ClubMemberProgress] {
        rows.sorted { a, b in
            if a.isFinished != b.isFinished { return a.isFinished }
            if a.fraction != b.fraction { return a.fraction > b.fraction }
            return a.member.joinedAt < b.member.joinedAt
        }
    }
}

// MARK: - Demo fixture

extension BookClub {
    /// `-uiPreviewClubs` fixture. Uids are fake; nothing here touches Firestore.
    static let uiPreviewDemo: BookClub = {
        let now = Date()
        func member(_ first: String, _ last: String, handle: String, daysAgo: Double) -> Member {
            Member(firstName: first, displayName: "\(first) \(last)", username: handle, photoURL: nil, joinedAt: now.addingTimeInterval(-86400 * daysAgo))
        }
        let pick = Pick(
            id: "pick-demo-1",
            bookId: "rn1",
            title: "Endurance",
            author: "Alfred Lansing",
            coverURL: "",
            pageCount: 357,
            chosenAt: now.addingTimeInterval(-86400 * 9),
            chosenBy: "ui-preview",
            meetingAt: Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: now.addingTimeInterval(86400 * 12)) ?? now.addingTimeInterval(86400 * 12)
        )
        let past = [
            Pick(id: "pick-demo-0", bookId: "r6", title: "Shoe Dog", author: "Phil Knight", coverURL: "", pageCount: 400, chosenAt: now.addingTimeInterval(-86400 * 45), chosenBy: "ui-preview", meetingAt: now.addingTimeInterval(-86400 * 14)),
            Pick(id: "pick-demo-00", bookId: "r1", title: "Build", author: "Tony Fadell", coverURL: "", pageCount: 416, chosenAt: now.addingTimeInterval(-86400 * 80), chosenBy: "demo-alexis", meetingAt: now.addingTimeInterval(-86400 * 48)),
        ]
        return BookClub(
            id: "club-demo",
            name: "Emma Lion Book Club",
            createdBy: "ui-preview",
            createdAt: now.addingTimeInterval(-86400 * 90),
            updatedAt: now,
            updatedBy: "ui-preview",
            memberIds: ["ui-preview", "demo-alexis", "demo-hannah", "demo-marcus", "demo-priya"],
            adminIds: ["ui-preview"],
            everyoneIsAdmin: false,
            members: [
                "ui-preview": member("Tanner", "Flake", handle: "tanner", daysAgo: 90),
                "demo-alexis": member("Alexis", "Arias", handle: "alexisreads", daysAgo: 89),
                "demo-hannah": member("Hannah", "Cole", handle: "hannahc", daysAgo: 70),
                "demo-marcus": member("Marcus", "Bell", handle: "mbell", daysAgo: 40),
                "demo-priya": member("Priya", "Natarajan", handle: "priya.n", daysAgo: 12),
            ],
            inviteCode: "K7PMQ4",
            currentPick: pick,
            pastPicks: past
        )
    }()

    /// Fake per-member rows for the demo club, so the progress list has every state.
    static let uiPreviewDemoProgress: [String: ClubMemberProgress.State] = [
        "ui-preview": .reading(fraction: 0.42),
        "demo-alexis": .finished(Date().addingTimeInterval(-86400 * 2)),
        "demo-hannah": .reading(fraction: 0.71),
        "demo-marcus": .notStarted,
        "demo-priya": .reading(fraction: 0.15),
    ]
}
