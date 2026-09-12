//
//  Mentions.swift
//  Spine
//
//  @-mention support for reviews and comments: detecting the handle being
//  typed, suggesting accounts, inserting the chosen tag, and rendering
//  mentions in finished text as tappable, ink-weighted tokens.
//
//  Mentions travel as plain "@handle" text — no doc schema. Cloud Functions
//  re-resolve handles server-side (handleClaims) to send mention pushes, so
//  the client and server never need to agree on a mentions array.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// MARK: - Scanning & rendering

enum MentionScanner {
    /// Characters allowed in a handle (usernames are lowercased email
    /// local-parts or chosen handles).
    private static let handleCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// The mention being typed: text ends in "@" + what's been typed since,
    /// with the "@" at the start of the text or after whitespace (so emails
    /// don't trigger). Returns the partial query (lowercased) or nil.
    ///
    /// One interior space is allowed so a full name ("@tanner f") keeps
    /// suggesting; a trailing space ends the mention, which is what closes the
    /// bar after `insertMention` appends one.
    ///
    /// Trailing-token only: SwiftUI text fields don't expose the cursor, and
    /// people type mentions at the end of what they're writing.
    static func activeQuery(in text: String) -> String? {
        guard let atIndex = text.lastIndex(of: "@") else { return nil }
        if atIndex != text.startIndex {
            let before = text[text.index(before: atIndex)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }
        let tail = text[text.index(after: atIndex)...]
        guard !tail.isEmpty, tail.count <= 40 else { return nil }
        guard let last = tail.last, !last.isWhitespace else { return nil }
        var spaces = 0
        for ch in tail {
            if ch == " " {
                spaces += 1
                if spaces > 1 { return nil }
                continue
            }
            guard ch.unicodeScalars.count == 1,
                  let scalar = ch.unicodeScalars.first,
                  handleCharacters.contains(scalar) else { return nil }
        }
        return tail.lowercased()
    }

    /// Replaces the trailing partial mention (see `activeQuery`) with the
    /// chosen handle plus a trailing space, ready to keep typing.
    static func insertMention(handle: String, into text: String) -> String {
        guard let atIndex = text.lastIndex(of: "@") else { return text }
        return text[..<atIndex] + "@\(handle) "
    }

    /// All complete @handle tokens in the text (lowercased, deduped), each
    /// preceded by start-of-text or whitespace.
    static func mentionHandles(in text: String) -> [String] {
        var handles: [String] = []
        var seen = Set<String>()
        for range in mentionRanges(in: text) {
            let handle = String(text[text.index(after: range.lowerBound)..<range.upperBound]).lowercased()
            if seen.insert(handle).inserted { handles.append(handle) }
        }
        return handles
    }

    /// Ranges of "@handle" tokens (including the "@").
    private static func mentionRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "@" {
                let validStart = i == text.startIndex || text[text.index(before: i)].isWhitespace || text[text.index(before: i)].isNewline
                if validStart {
                    var j = text.index(after: i)
                    while j < text.endIndex, let scalar = text[j].unicodeScalars.first, text[j].unicodeScalars.count == 1, handleCharacters.contains(scalar) {
                        j = text.index(after: j)
                    }
                    if j > text.index(after: i) {
                        ranges.append(i..<j)
                        i = j
                        continue
                    }
                }
            }
            i = text.index(after: i)
        }
        return ranges
    }

    /// Text with each @mention rendered semibold in `mentionColor` and carrying
    /// a `spine-mention://handle` link so taps can resolve to a profile via an
    /// `openURL` handler.
    static func attributed(_ text: String, mentionColor: Color) -> AttributedString {
        var result = AttributedString(text)
        for range in mentionRanges(in: text) {
            guard let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            let handle = String(text[text.index(after: range.lowerBound)..<range.upperBound]).lowercased()
            result[lower..<upper].foregroundColor = mentionColor
            result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            result[lower..<upper].link = URL(string: "spine-mention://\(handle)")
        }
        return result
    }

    /// The handle from a `spine-mention://handle` URL, or nil for other URLs.
    static func handle(fromMentionURL url: URL) -> String? {
        guard url.scheme == "spine-mention" else { return nil }
        return url.host()?.lowercased()
    }
}

// MARK: - Suggestion catalog

/// Session-cached roster of accounts for mention autocomplete (same source as
/// the people strip, hidden-account filtering applied via the viewer uid).
/// Loading is one-shot per viewer; refreshed on sign-in changes.
@MainActor
final class MentionCatalog: ObservableObject {
    static let shared = MentionCatalog()

    @Published private(set) var profiles: [(uid: String, user: User)] = []
    private var loadedForViewer: String?
    private var loadTask: Task<Void, Never>?
    private let userRepo = UserRepository()

    /// `ensureLoaded` for call sites without an AppState in scope (the review
    /// composition overlays).
    func ensureLoadedForCurrentUser() {
        ensureLoaded(viewerUid: Auth.auth().currentUser?.uid)
    }

    /// Kick off (or reuse) the roster load for this viewer.
    func ensureLoaded(viewerUid: String?) {
        guard let viewerUid else { return }
        if loadedForViewer == viewerUid, !profiles.isEmpty { return }
        if let loadTask, loadedForViewer == viewerUid { _ = loadTask; return }
        loadedForViewer = viewerUid
        loadTask = Task { [userRepo] in
            let rows = await userRepo.fetchAllReaderProfiles(excludingUid: viewerUid)
            await MainActor.run { self.profiles = rows }
        }
    }

    /// Accounts matching what's been typed after "@" — name matches first,
    /// handle matches after (see `PersonSearch`).
    func suggestions(matching query: String, limit: Int = 5) -> [(uid: String, user: User)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return Array(PersonSearch.ranked(profiles, query: q, user: { $0.user }).prefix(limit))
    }

    /// Handle for a uid — from the loaded roster, else a one-off fetch (e.g.
    /// replying to your own comment; the roster excludes the viewer).
    func handle(forUid uid: String) async -> String? {
        if let row = profiles.first(where: { $0.uid == uid }) {
            return row.user.username.lowercased()
        }
        return await userRepo.getUser(uid: uid)?.username.lowercased()
    }

    /// Uid for a handle, for mention taps. Roster first, then the
    /// `handleClaims/{handle}` doc (covers accounts beyond the roster page).
    func uid(forHandle handle: String) async -> String? {
        let h = handle.lowercased()
        if let row = profiles.first(where: { $0.user.username.lowercased() == h }) {
            return row.uid
        }
        do {
            let snap = try await FirestoreDatabase.firestore.collection("handleClaims").document(h).getDocument()
            return snap.data()?["uid"] as? String
        } catch {
            return nil
        }
    }
}

// MARK: - Suggestion bar

/// Compact account list shown while a mention is being typed. Sits directly
/// against the input it completes; rows insert "@handle " on tap.
struct MentionSuggestionBar: View {
    let suggestions: [(uid: String, user: User)]
    let onSelect: (User) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.uid) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.chrome.opacity(0.18))
                        .frame(height: Theme.chromeHairline)
                }
                Button {
                    onSelect(row.user)
                } label: {
                    HStack(spacing: 10) {
                        UserAvatarView(urlString: row.user.profileImageURL, displayName: row.user.displayName, size: 28)
                        Text(row.user.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text("@\(row.user.username.lowercased())")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.chrome.opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - Person search ranking

/// Shared name-first matching for every place we search people (mention
/// autocomplete, the Users scope of Search, recommend/find-friends sheets).
///
/// Names are what people actually know each other by, so a name hit always
/// outranks a handle hit; handles are the fallback for people who type them.
enum PersonSearch {
    /// Lower is a better match; nil means no match at all.
    static func rank(_ user: User, query: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return 0 }

        let name = user.displayName.lowercased()
        let handle = user.username.lowercased()
        // Full name plus the parts, so "flake" and "tanner flake" both hit.
        var nameWords = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if let f = user.firstName?.lowercased(), !f.isEmpty { nameWords.append(f) }
        if let l = user.lastName?.lowercased(), !l.isEmpty { nameWords.append(l) }

        if name == q { return 0 }
        if name.hasPrefix(q) { return 1 }
        if nameWords.contains(where: { $0.hasPrefix(q) }) { return 2 }
        if handle == q { return 3 }
        if handle.hasPrefix(q) { return 4 }
        if name.contains(q) { return 5 }
        if handle.contains(q) { return 6 }
        return nil
    }

    /// Matching people, best match first, ties broken alphabetically by name.
    static func ranked<T>(_ rows: [T], query: String, user: (T) -> User) -> [T] {
        let scored = rows.compactMap { row -> (row: T, score: Int, name: String)? in
            guard let score = rank(user(row), query: query) else { return nil }
            return (row, score, user(row).displayName)
        }
        return scored.sorted { a, b in
            if a.score != b.score { return a.score < b.score }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        .map(\.row)
    }
}

/// How connected a reader you don't follow is to you: people you both follow,
/// plus people you follow who follow them, plus one if they already follow you.
///
/// The founder is excluded from every term — he follows and is followed by the
/// whole roster, so counting him would hand every pair one meaningless mutual.
///
/// Shared by the Social tab's people strip and the Users scope of Search, so
/// "people you might know" means the same thing in both places.
enum PeopleSimilarity {
    /// - Parameters:
    ///   - peers: the people you follow, as (uid, their following list).
    static func score(
        candidateUid: String,
        candidateFollowing: [String],
        following: Set<String>,
        peers: [(uid: String, following: [String])],
        currentUid: String?
    ) -> Int {
        let mutualPool = following.subtracting([SpineFounder.uid])
        var score = mutualPool.intersection(candidateFollowing).count
        for peer in peers where peer.uid != SpineFounder.uid && peer.following.contains(candidateUid) {
            score += 1
        }
        if let me = currentUid, candidateFollowing.contains(me) { score += 1 }
        return score
    }
}
