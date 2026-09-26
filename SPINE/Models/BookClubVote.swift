//
//  BookClubVote.swift
//  SPINE
//
//  The group vote that picks a club's next book. Two 24-hour windows: everyone
//  suggests one book (or sits out), then everyone ranks the suggestions
//  (instant-runoff, Alaska style) with an optional veto. Either window closes
//  early the moment every member has responded.
//
//  Everything on the club doc is anonymous by construction: the server keeps
//  who-suggested-what and who-ranked-what in server-only subcollections and
//  only publishes the shuffled candidate list, who has responded, and the
//  result. Clients never write `vote` except to cancel it (set to null).
//

import Foundation
import FirebaseFirestore

extension BookClub {
    enum PickMode: String, CaseIterable {
        case groupVote
        case admin

        var title: String {
            switch self {
            case .groupVote: return "Group vote"
            case .admin: return "Admin picks"
            }
        }

        var blurb: String {
            switch self {
            case .groupVote: return "Everyone suggests a book anonymously, then ranks the picks. SPINE tallies it and reveals the winner."
            case .admin: return "An admin chooses the next book and sets the meeting."
            }
        }
    }

    struct Vote: Equatable {
        enum Phase: String {
            /// Members are suggesting books.
            case picks
            /// Members are ranking the suggestions.
            case voting
            /// Tallied; the winner is the club's current pick.
            case revealed
        }

        /// Suggestion or ranking window length.
        static let windowSeconds: TimeInterval = 24 * 60 * 60

        var id: String
        var phase: Phase
        var startedBy: String?
        var startedAt: Date
        /// When the current phase closes on its own (nil once revealed).
        var closesAt: Date?
        /// Members who suggested a book or sat out. Public on purpose (avatars
        /// tick off as people respond); it never says which they did.
        var respondedPickUids: [String]
        /// Shuffled suggestions, no authorship. Empty until voting opens.
        var candidates: [Candidate]
        /// Members who ranked or skipped the ballot.
        var votedUids: [String]
        var result: Result?
        /// Members who have watched the reveal. The club page hides the winner
        /// from anyone not on this list so the flow does the unveiling.
        var revealedUids: [String]
        var closedAt: Date?

        struct Candidate: Equatable, Identifiable {
            var id: String
            var bookId: String
            var title: String
            var author: String
            var coverURL: String
            var pageCount: Int?

            var asBook: Book {
                Book(id: bookId, title: title, author: author, coverURL: coverURL, pageCount: pageCount, publishedDate: nil, description: nil, genres: [])
            }
        }

        /// One instant-runoff round: first-choice tallies among the candidates
        /// still standing, and who was knocked out.
        struct Round: Equatable {
            var counts: [String: Int]
            var eliminatedCandidateId: String?
        }

        struct Result: Equatable {
            var winnerCandidateId: String
            var runnerUpCandidateId: String?
            var vetoedCandidateIds: [String]
            var totalBallots: Int
            var rounds: [Round]
            /// True when nobody ranked anything and the winner was drawn.
            var drawnByFate: Bool
        }

        // MARK: - Helpers

        var isOpen: Bool { phase == .picks || phase == .voting }

        func hasResponded(_ uid: String) -> Bool {
            switch phase {
            case .picks: return respondedPickUids.contains(uid)
            case .voting: return votedUids.contains(uid)
            case .revealed: return revealedUids.contains(uid)
            }
        }

        func hasSeenReveal(_ uid: String) -> Bool { revealedUids.contains(uid) }

        func candidate(_ id: String?) -> Candidate? {
            guard let id else { return nil }
            return candidates.first { $0.id == id }
        }

        var winner: Candidate? { candidate(result?.winnerCandidateId) }
        var runnerUp: Candidate? { candidate(result?.runnerUpCandidateId) }

        /// "23h left", "40m left", "Closing"
        func timeLeftCopy(now: Date = Date()) -> String {
            guard let closesAt else { return "" }
            let seconds = closesAt.timeIntervalSince(now)
            if seconds <= 60 { return "Closing" }
            let hours = Int(seconds / 3600)
            if hours >= 1 { return "\(hours)h left" }
            return "\(max(1, Int(seconds / 60)))m left"
        }

        // MARK: - Firestore

        static func from(data: [String: Any]) -> Vote? {
            guard let id = data["id"] as? String,
                  let phaseRaw = data["phase"] as? String,
                  let phase = Phase(rawValue: phaseRaw) else { return nil }
            let candidates = ((data["candidates"] as? [[String: Any]]) ?? []).compactMap { Candidate.from(data: $0) }
            return Vote(
                id: id,
                phase: phase,
                startedBy: data["startedBy"] as? String,
                startedAt: (data["startedAt"] as? Timestamp)?.dateValue() ?? Date(),
                closesAt: (data["closesAt"] as? Timestamp)?.dateValue(),
                respondedPickUids: (data["respondedPickUids"] as? [String]) ?? [],
                candidates: candidates,
                votedUids: (data["votedUids"] as? [String]) ?? [],
                result: (data["result"] as? [String: Any]).flatMap { Result.from(data: $0) },
                revealedUids: (data["revealedUids"] as? [String]) ?? [],
                closedAt: (data["closedAt"] as? Timestamp)?.dateValue()
            )
        }
    }
}

extension BookClub.Vote.Candidate {
    static func from(data: [String: Any]) -> BookClub.Vote.Candidate? {
        guard let id = data["id"] as? String,
              let bookId = data["bookId"] as? String,
              let title = data["title"] as? String else { return nil }
        return BookClub.Vote.Candidate(
            id: id,
            bookId: bookId,
            title: title,
            author: (data["author"] as? String) ?? "",
            coverURL: (data["coverURL"] as? String) ?? "",
            pageCount: data["pageCount"] as? Int
        )
    }
}

extension BookClub.Vote.Result {
    static func from(data: [String: Any]) -> BookClub.Vote.Result? {
        guard let winner = data["winnerCandidateId"] as? String else { return nil }
        let rounds = ((data["rounds"] as? [[String: Any]]) ?? []).map { raw -> BookClub.Vote.Round in
            var counts: [String: Int] = [:]
            if let map = raw["counts"] as? [String: Any] {
                for (k, v) in map {
                    if let n = v as? Int { counts[k] = n } else if let n = v as? Double { counts[k] = Int(n) }
                }
            }
            return BookClub.Vote.Round(counts: counts, eliminatedCandidateId: raw["eliminatedCandidateId"] as? String)
        }
        return BookClub.Vote.Result(
            winnerCandidateId: winner,
            runnerUpCandidateId: data["runnerUpCandidateId"] as? String,
            vetoedCandidateIds: (data["vetoedCandidateIds"] as? [String]) ?? [],
            totalBallots: (data["totalBallots"] as? Int) ?? 0,
            rounds: rounds,
            drawnByFate: (data["drawnByFate"] as? Bool) ?? false
        )
    }
}

extension BookClub {
    /// True while a voted-in pick should stay out of sight for this member: the
    /// vote is revealed, they haven't watched the reveal (server list or local
    /// echo), and the result is recent enough that the surprise still matters.
    func pickHiddenPendingReveal(for uid: String) -> Bool {
        guard let vote, vote.phase == .revealed, let pick = currentPick, pick.wasVoted else { return false }
        if vote.hasSeenReveal(uid) || ClubVoteRevealMemo.hasSeen(clubId: id, roundId: vote.id) { return false }
        if let closedAt = vote.closedAt, Date().timeIntervalSince(closedAt) > 14 * 86400 { return false }
        return true
    }
}

// MARK: - Demo fixtures (`-uiPreviewClubVote <phase>`)

extension BookClub.Vote {
    static let demoCandidates: [Candidate] = [
        Candidate(id: "c1", bookId: "r2", title: "Tomorrow, and Tomorrow, and Tomorrow", author: "Gabrielle Zevin", coverURL: "", pageCount: 416),
        Candidate(id: "c2", bookId: "r4", title: "The Anthropocene Reviewed", author: "John Green", coverURL: "", pageCount: 304),
        Candidate(id: "c3", bookId: "r5", title: "Circe", author: "Madeline Miller", coverURL: "", pageCount: 393),
        Candidate(id: "c4", bookId: "r7", title: "Project Hail Mary", author: "Andy Weir", coverURL: "", pageCount: 476),
        Candidate(id: "c5", bookId: "r8", title: "Lessons in Chemistry", author: "Bonnie Garmus", coverURL: "", pageCount: 400),
    ]

    /// Which preview state `-uiPreviewClubVote` asks for.
    enum DemoState: String {
        case picks, picked, voting, voted, reveal, revealed
    }

    static func demo(_ state: DemoState, me: String, members: [String]) -> BookClub.Vote {
        let now = Date()
        let others = members.filter { $0 != me }
        var vote = BookClub.Vote(
            id: "vote-demo",
            phase: .picks,
            startedBy: me,
            startedAt: now.addingTimeInterval(-3600 * 5),
            closesAt: now.addingTimeInterval(3600 * 19),
            respondedPickUids: Array(others.prefix(2)),
            candidates: [],
            votedUids: [],
            result: nil,
            revealedUids: [],
            closedAt: nil
        )
        switch state {
        case .picks:
            break
        case .picked:
            vote.respondedPickUids.append(me)
        case .voting, .voted:
            vote.phase = .voting
            vote.candidates = demoCandidates
            vote.respondedPickUids = members
            vote.votedUids = Array(others.prefix(3))
            if state == .voted { vote.votedUids.append(me) }
        case .reveal, .revealed:
            vote.phase = .revealed
            vote.candidates = demoCandidates
            vote.respondedPickUids = members
            vote.votedUids = members
            vote.closesAt = nil
            vote.closedAt = now.addingTimeInterval(-600)
            vote.result = Result(
                winnerCandidateId: "c3",
                runnerUpCandidateId: "c4",
                vetoedCandidateIds: ["c5"],
                totalBallots: members.count,
                rounds: [
                    Round(counts: ["c1": 1, "c2": 1, "c3": 2, "c4": 1], eliminatedCandidateId: "c2"),
                    Round(counts: ["c1": 1, "c3": 2, "c4": 2], eliminatedCandidateId: "c1"),
                    Round(counts: ["c3": 3, "c4": 2], eliminatedCandidateId: nil),
                ],
                drawnByFate: false
            )
            if state == .revealed { vote.revealedUids = members }
        }
        return vote
    }
}
