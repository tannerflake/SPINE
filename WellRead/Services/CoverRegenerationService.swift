//
//  CoverRegenerationService.swift
//  WellRead
//
//  "Wrong cover?" flow on the book profile: rejects the currently displayed
//  cover, resolves the next visually distinct candidate from the fallback chain
//  (ISBNdb/Google/Open Library/iTunes), and shares the result with everyone by
//  writing `coverOverrideURL` / `coverRejectedURLs` onto the book doc — the
//  chain tries the override first, so all users converge on the fixed cover.
//
//  Undo restores exactly the fields the session changed, and every session is
//  logged to `coverRegenerations` with its final outcome ("applied" if the new
//  cover stuck, "no_change" if the member undid it).
//

import Foundation
import UIKit
import FirebaseFirestore

@MainActor
final class CoverRegenerationService {
    static let shared = CoverRegenerationService()

    enum Outcome {
        case applied
        /// Every remaining candidate failed or matched an already-shown image.
        case exhausted
        case failed
    }

    /// Everything needed to undo back to the pre-session state. Lives only in
    /// memory: leaving the session behind (navigating away, killing the app)
    /// means the regenerated cover is kept — which is the intended default.
    private struct Session {
        let signature: String
        let originalURL: URL
        var currentURL: URL
        /// Images already shown this session (original + each accepted cover), so a
        /// different URL serving the same artwork never counts as "another" cover.
        var shownImages: [UIImage]
        /// URLs this session arrayUnion'd into the doc — removed again on undo.
        var rejected: [String] = []
        /// Book-doc fields as they were before our first write (nil = field absent).
        var priorOverride: String?
        var priorEditedBy: String?
        var priorEditedAt: Timestamp?
        var attempts: Int = 0
        /// Set once the iTunes lookup has been folded into the candidate pool.
        var triedITunes: Bool = false
        var iTunesURLs: [URL] = []
    }

    private let db = FirestoreDatabase.firestore
    private var sessions: [String: Session] = [:]
    /// The session's `coverRegenerations` doc, kept past session teardown so an
    /// undo's queued write still lands on the same log entry.
    private var logDocIds: [String: String] = [:]
    /// Firestore writes per book run strictly in order (doc update → log create →
    /// … → undo restore), so rapid taps can't race a log create against an update.
    private var persistChains: [String: Task<Void, Never>] = [:]

    private init() {}

    // MARK: - View support

    /// The locked winner currently backing this book's cover on this device.
    func resolvedCoverURL(for book: Book) -> URL? {
        CoverResolutionStore.shared.resolvedURL(bookId: book.id, signature: Self.signature(for: book))
    }

    /// The control only makes sense when a real cover image is on screen.
    func canRegenerate(book: Book) -> Bool {
        resolvedCoverURL(for: book) != nil
    }

    /// Book ids whose covers any member touched since `since` — one small query
    /// against the regeneration log, used by AppState's per-launch delta check so
    /// the library can stay fully local unless a cover actually changed.
    /// Nil on failure (offline) so the caller can retry later instead of skipping edits.
    func coverEditedBookIds(since: Date) async -> Set<String>? {
        do {
            let snapshot = try await db.collection("coverRegenerations")
                .whereField("updatedAt", isGreaterThan: Timestamp(date: since))
                .limit(to: 500)
                .getDocuments()
            return Set(snapshot.documents.compactMap { $0.data()["bookId"] as? String })
        } catch {
            return nil
        }
    }

    /// The chain already gave up on this book (title placeholder is showing).
    func hasRecordedFailure(book: Book) -> Bool {
        CoverResolutionStore.shared.hasRecentFailure(bookId: book.id, signature: Self.signature(for: book))
    }

    /// A cover never resolved and the member tapped "Bad cover?" anyway: wipe the
    /// recorded failure and re-probe the full chain once (was it just a loading
    /// glitch?). Local only — no override, no rejected list, no log; a success
    /// here is simply the organic cover finally arriving.
    func retryResolve(book: Book) async -> Bool {
        let signature = Self.signature(for: book)
        if CoverResolutionStore.shared.resolvedURL(bookId: book.id, signature: signature) != nil { return true }
        CoverResolutionStore.shared.clearFailure(bookId: book.id, signature: signature)
        var candidates = book.coverImageURLsToTry
        candidates += await ITunesCoverService.shared.artworkURLs(
            isbn: book.isbn, title: book.title, author: book.author
        )
        let start = Date()
        var found = false
        for url in candidates {
            if Date().timeIntervalSince(start) > 12 { break }
            if case .success = await CoverImageCache.shared.fetch(for: url) {
                CoverResolutionStore.shared.lock(bookId: book.id, signature: signature, url: url)
                NotificationCenter.default.post(name: .bookCoverResolutionDidChange, object: book.id)
                found = true
                break
            }
        }
        Analytics.amplitude?.track(eventType: "Retried Cover Resolution", eventProperties: [
            "book_id": book.id,
            "found": found,
        ])
        return found
    }

    /// Which API served a cover URL — founder-only debug caption on the book
    /// profile, for judging source quality when tuning the fallback chain.
    static func coverSource(for url: URL) -> String {
        let host = url.host ?? ""
        if host.contains("isbndb.com") { return "ISBNdb" }
        if host.contains("books.google") || host.contains("googleusercontent") { return "Google" }
        if host.contains("openlibrary.org") { return "Open Library" }
        if host.contains("mzstatic.com") || host.contains("itunes.apple.com") { return "iTunes" }
        if host.contains("firebasestorage") { return "SPINE upload" }
        return host.isEmpty ? "unknown" : host
    }

    /// True while this book has an un-undone regeneration from this session.
    func hasActiveSession(bookId: String) -> Bool {
        sessions[bookId] != nil
    }

    // MARK: - Regenerate

    func regenerate(book: Book, userId: String) async -> Outcome {
        let signature = Self.signature(for: book)
        var session: Session
        if let existing = sessions[book.id] {
            session = existing
        } else {
            guard let current = CoverResolutionStore.shared.resolvedURL(bookId: book.id, signature: signature) else {
                return .failed
            }
            var shown: [UIImage] = []
            if let img = CoverImageCache.shared.imageSyncFromCache(for: current) {
                shown.append(img)
            }
            session = Session(signature: signature, originalURL: current, currentURL: current, shownImages: shown)
            // Snapshot prior override/attribution so undo restores them verbatim.
            // A failed read falls back to the in-memory book (same Firestore data,
            // minus attribution — acceptable: undo then clears attribution).
            if let snap = try? await db.collection("books").document(book.id).getDocument(),
               let data = snap.data() {
                session.priorOverride = data["coverOverrideURL"] as? String
                session.priorEditedBy = data["coverEditedBy"] as? String
                session.priorEditedAt = data["coverEditedAt"] as? Timestamp
            } else {
                session.priorOverride = book.coverOverrideURL
            }
        }

        // Candidate pool: the normal chain, then iTunes artwork as the tail.
        if !session.triedITunes {
            session.triedITunes = true
            session.iTunesURLs = await ITunesCoverService.shared.artworkURLs(
                isbn: book.isbn, title: book.title, author: book.author
            )
        }
        let skip = Set(session.rejected + [session.originalURL.absoluteString, session.currentURL.absoluteString])
        let candidates = (book.coverImageURLsToTry + session.iTunesURLs)
            .filter { !skip.contains($0.absoluteString) }

        let start = Date()
        let budget: TimeInterval = 12
        var accepted: (URL, UIImage)?
        for url in candidates {
            if Date().timeIntervalSince(start) > budget { break }
            guard case .success(let img) = await CoverImageCache.shared.fetch(for: url) else { continue }
            if session.shownImages.contains(where: { CoverImageCache.shared.visuallyIdentical($0, img) }) { continue }
            accepted = (url, img)
            break
        }
        guard let (newURL, newImage) = accepted else {
            // Keep the session (it may hold an undoable earlier regeneration).
            sessions[book.id] = session.attempts > 0 ? session : nil
            return .exhausted
        }

        CoverResolutionStore.shared.lock(bookId: book.id, signature: signature, url: newURL)
        NotificationCenter.default.post(name: .bookCoverResolutionDidChange, object: book.id)
        let justRejected = session.currentURL.absoluteString
        session.rejected.append(justRejected)
        session.shownImages.append(newImage)
        session.currentURL = newURL
        session.attempts += 1
        sessions[book.id] = session

        let attempts = session.attempts
        let fromURL = session.originalURL.absoluteString
        enqueuePersist(bookId: book.id) { [self] in
            do {
                try await db.collection("books").document(book.id).updateData([
                    "coverOverrideURL": newURL.absoluteString,
                    "coverRejectedURLs": FieldValue.arrayUnion([justRejected]),
                    "coverEditedBy": userId,
                    "coverEditedAt": FieldValue.serverTimestamp(),
                ])
            } catch {
                print("CoverRegeneration: book update failed: \(error)")
            }
            await writeLog(
                bookId: book.id, bookTitle: book.title, userId: userId,
                fromURL: fromURL, toURL: newURL.absoluteString,
                attempts: attempts, status: "applied"
            )
        }

        Analytics.amplitude?.track(eventType: "Regenerated Book Cover", eventProperties: [
            "book_id": book.id,
            "attempt": attempts,
        ])
        return .applied
    }

    // MARK: - Undo

    /// Puts the cover — and the book doc — back exactly as this session found
    /// them, and settles the log as "no_change". Instant for the caller; the
    /// Firestore restore runs behind the ordered write chain.
    func undo(book: Book, userId: String) {
        guard let session = sessions[book.id] else { return }
        sessions[book.id] = nil

        CoverResolutionStore.shared.lock(bookId: book.id, signature: session.signature, url: session.originalURL)
        NotificationCenter.default.post(name: .bookCoverResolutionDidChange, object: book.id)

        enqueuePersist(bookId: book.id) { [self] in
            var fields: [String: Any] = [
                "coverOverrideURL": session.priorOverride ?? FieldValue.delete(),
                "coverEditedBy": session.priorEditedBy ?? FieldValue.delete(),
                "coverEditedAt": session.priorEditedAt ?? FieldValue.delete(),
            ]
            if !session.rejected.isEmpty {
                fields["coverRejectedURLs"] = FieldValue.arrayRemove(session.rejected)
            }
            do {
                try await db.collection("books").document(book.id).updateData(fields)
            } catch {
                print("CoverRegeneration: undo update failed: \(error)")
            }
            await writeLog(
                bookId: book.id, bookTitle: book.title, userId: userId,
                fromURL: session.originalURL.absoluteString, toURL: session.originalURL.absoluteString,
                attempts: session.attempts, status: "no_change"
            )
            logDocIds[book.id] = nil
        }

        Analytics.amplitude?.track(eventType: "Undid Cover Regeneration", eventProperties: [
            "book_id": book.id,
            "attempts": session.attempts,
        ])
    }

    // MARK: - Log

    /// One `coverRegenerations` doc per session, updated in place as the member
    /// keeps trying — the doc always reflects where they finally settled.
    private func writeLog(bookId: String, bookTitle: String, userId: String, fromURL: String, toURL: String, attempts: Int, status: String) async {
        do {
            if let logId = logDocIds[bookId] {
                try await db.collection("coverRegenerations").document(logId).updateData([
                    "toURL": toURL,
                    "attempts": attempts,
                    "status": status,
                    "updatedAt": FieldValue.serverTimestamp(),
                ])
            } else {
                let ref = try await db.collection("coverRegenerations").addDocument(data: [
                    "bookId": bookId,
                    "bookTitle": bookTitle,
                    "userId": userId,
                    "fromURL": fromURL,
                    "toURL": toURL,
                    "attempts": attempts,
                    "status": status,
                    "createdAt": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp(),
                ])
                logDocIds[bookId] = ref.documentID
            }
        } catch {
            print("CoverRegeneration: log write failed: \(error)")
        }
    }

    // MARK: - Helpers

    private func enqueuePersist(bookId: String, _ op: @escaping @MainActor () async -> Void) {
        let prev = persistChains[bookId]
        persistChains[bookId] = Task { @MainActor in
            await prev?.value
            await op()
        }
    }

    /// Same signature `FallbackCoverImage` uses, so lock/undo hit the entry the
    /// cover view is actually reading.
    private static func signature(for book: Book) -> String {
        CoverResolutionStore.signature(
            coverURL: book.coverImageURLsToTry.first?.absoluteString ?? "",
            isbn: book.isbn
        )
    }
}
