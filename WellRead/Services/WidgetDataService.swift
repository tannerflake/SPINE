//
//  WidgetDataService.swift
//  WellRead
//
//  Writes the "reading now" snapshot (JSON + pre-scaled images) into the App
//  Group container for WellReadWidget, then asks WidgetKit to reload. The
//  widget never touches the network — everything it renders comes from here.
//

import Foundation
import UIKit
import WidgetKit
import CryptoKit

@MainActor
final class WidgetDataService {
    static let shared = WidgetDataService()

    private let userRepo = UserRepository()
    private let userBookRepo = UserBookRepository()

    private var pendingTask: Task<Void, Never>?
    private var lastFriendFetch: Date?
    private var cachedFriends: [WidgetSnapshot.FriendEntry]?
    /// Digest of the last snapshot written (generatedAt zeroed) — skip identical rewrites
    /// to stay inside WidgetKit's daily reload budget.
    private var lastWrittenDigest: Data?

    /// Friends' shelves only change server-side; refetching more often than this
    /// just burns Firestore reads (`fetchAllReadingNowBooks` scans the collection).
    private static let friendRefreshInterval: TimeInterval = 30 * 60
    private static let maxOwnBooks = 4
    private static let maxFriends = 8
    private static let maxBooksPerFriend = 2
    private static let coverSize = CGSize(width: 200, height: 300)
    private static let avatarSize = CGSize(width: 80, height: 80)

    private init() {}

    /// Debounced entry point — safe to call from listener callbacks and scene-phase
    /// changes; bursts (e.g. queue drag reorders) collapse into one write.
    func scheduleRefresh(appState: AppState, delay: TimeInterval = 2.0, forceFriendRefresh: Bool = false) {
        if forceFriendRefresh { lastFriendFetch = nil }
        pendingTask?.cancel()
        pendingTask = Task { [weak appState] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let appState else { return }
            await WidgetDataService.shared.refresh(appState: appState)
        }
    }

    /// Called from sign-out only. Refresh paths never write this — early in launch
    /// auth may not have hydrated yet, and clobbering a good snapshot would blank the widget.
    func writeSignedOutSnapshot() {
        pendingTask?.cancel()
        lastFriendFetch = nil
        cachedFriends = nil
        let snapshot = WidgetSnapshot(
            schemaVersion: WidgetSharedStore.currentSchemaVersion,
            isSignedIn: false,
            myBooks: [],
            friends: [],
            generatedAt: Date()
        )
        write(snapshot: snapshot, referencedFilenames: [])
    }

    // MARK: - Refresh

    private func refresh(appState: AppState) async {
        guard let uid = appState.authUserId else { return }

        // Keep the UserBook alongside the Book: the widget draws each cover's
        // bookmark + percent from `readingProgress`, which only the row carries.
        let ownRows = appState.wantToReadReadingNow.prefix(Self.maxOwnBooks)

        var friends: [WidgetSnapshot.FriendEntry]
        if let cached = cachedFriends, let last = lastFriendFetch,
           Date().timeIntervalSince(last) < Self.friendRefreshInterval {
            friends = cached
        } else {
            friends = await fetchFriendEntries(ownUid: uid)
            cachedFriends = friends
            lastFriendFetch = Date()
        }

        var myEntries: [WidgetSnapshot.BookEntry] = []
        for row in ownRows {
            guard let book = row.book else { continue }
            myEntries.append(await bookEntry(for: book, progress: row.readingProgress))
        }

        let snapshot = WidgetSnapshot(
            schemaVersion: WidgetSharedStore.currentSchemaVersion,
            isSignedIn: true,
            myBooks: myEntries,
            friends: friends,
            generatedAt: Date()
        )

        var referenced = Set(snapshot.myBooks.compactMap(\.coverFilename))
        for friend in snapshot.friends {
            if let avatar = friend.avatarFilename { referenced.insert(avatar) }
            referenced.formUnion(friend.books.compactMap(\.coverFilename))
        }
        write(snapshot: snapshot, referencedFilenames: referenced)
    }

    /// Own profile is fetched fresh here (rather than trusting AppState.currentUser)
    /// so a just-completed follow is reflected without state-sync coupling.
    private func fetchFriendEntries(ownUid: String) async -> [WidgetSnapshot.FriendEntry] {
        guard let me = await userRepo.getUser(uid: ownUid) else { return cachedFriends ?? [] }
        let following = me.following.filter { $0 != ownUid }
        guard !following.isEmpty else { return [] }

        let readingNowByUid = await userBookRepo.fetchAllReadingNowBooks()

        var entries: [WidgetSnapshot.FriendEntry] = []
        for friendUid in following {
            guard entries.count < Self.maxFriends else { break }
            guard let books = readingNowByUid[friendUid], !books.isEmpty else { continue }
            guard let profile = await userRepo.getUser(uid: friendUid) else { continue }

            var bookEntries: [WidgetSnapshot.BookEntry] = []
            for book in books.prefix(Self.maxBooksPerFriend) {
                bookEntries.append(await bookEntry(for: book))
            }
            let avatar = await avatarFilename(uid: friendUid, urlString: profile.profileImageURL)
            entries.append(WidgetSnapshot.FriendEntry(
                uid: friendUid,
                displayName: profile.displayName,
                avatarFilename: avatar,
                books: bookEntries
            ))
        }
        return entries
    }

    // MARK: - Images

    /// `progress` is nil for friends' books (their `UserBook` rows aren't fetched)
    /// and for own books the reader has never scrubbed.
    private func bookEntry(for book: Book, progress: Double? = nil) async -> WidgetSnapshot.BookEntry {
        WidgetSnapshot.BookEntry(
            bookId: book.id,
            title: book.title,
            author: book.author,
            coverFilename: await coverFilename(for: book),
            progress: progress.map { min(1, max(0, $0)) }
        )
    }

    private func coverFilename(for book: Book) async -> String? {
        let candidates = book.coverImageURLsToTry
        guard let primary = candidates.first else { return nil }
        // Name keyed off the primary candidate: a changed cover URL yields a new
        // file, and the stale one is swept after the next snapshot write.
        let filename = "cover-\(Self.filenameSafe(book.id))-\(Self.hash8(primary.absoluteString)).jpg"
        if fileExists(filename) { return filename }

        for url in candidates {
            if let image = await downloadImage(from: url) {
                let scaled = Self.scaled(image, toFill: Self.coverSize)
                if writeJPEG(scaled, filename: filename) { return filename }
                return nil
            }
        }
        return nil
    }

    private func avatarFilename(uid: String, urlString: String?) async -> String? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        let filename = "avatar-\(Self.filenameSafe(uid))-\(Self.hash8(urlString)).jpg"
        if fileExists(filename) { return filename }
        guard let image = await downloadImage(from: url) else { return nil }
        let scaled = Self.scaled(image, toFill: Self.avatarSize)
        return writeJPEG(scaled, filename: filename) ? filename : nil
    }

    private func downloadImage(from url: URL) async -> UIImage? {
        guard let data = try? await URLSession.shared.data(from: url).0,
              data.count > 500,  // OpenLibrary/Google can 200 with a tiny blank pixel
              let image = UIImage(data: data),
              image.size.width > 10, image.size.height > 10 else { return nil }
        return image
    }

    private static func scaled(_ image: UIImage, toFill target: CGSize) -> UIImage {
        let scale = max(target.width / image.size.width, target.height / image.size.height)
        guard scale < 1 else { return image }  // never upscale
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Disk

    private func fileExists(_ filename: String) -> Bool {
        guard let url = WidgetSharedStore.imageURL(for: filename) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func writeJPEG(_ image: UIImage, filename: String) -> Bool {
        guard let dir = WidgetSharedStore.imagesDirectory,
              let url = WidgetSharedStore.imageURL(for: filename),
              let data = image.jpegData(compressionQuality: 0.8) else { return false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Images are already on disk by the time the JSON lands (atomic), so the
    /// widget never sees a snapshot referencing a missing file.
    private func write(snapshot: WidgetSnapshot, referencedFilenames: Set<String>) {
        guard let snapshotURL = WidgetSharedStore.snapshotURL,
              let containerDir = WidgetSharedStore.containerURL else { return }
        do {
            let comparable = WidgetSnapshot(
                schemaVersion: snapshot.schemaVersion,
                isSignedIn: snapshot.isSignedIn,
                myBooks: snapshot.myBooks,
                friends: snapshot.friends,
                generatedAt: Date(timeIntervalSince1970: 0)
            )
            let digest = Data(SHA256.hash(data: try WidgetSharedStore.makeEncoder().encode(comparable)))
            if digest == lastWrittenDigest, referencedFilenames.allSatisfy(fileExists) {
                return
            }

            try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)
            let data = try WidgetSharedStore.makeEncoder().encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
            lastWrittenDigest = digest
            cleanStaleImages(keeping: referencedFilenames)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            #if DEBUG
            print("WidgetDataService: snapshot write failed: \(error)")
            #endif
        }
    }

    private func cleanStaleImages(keeping referenced: Set<String>) {
        guard let dir = WidgetSharedStore.imagesDirectory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
    }

    // MARK: - Naming

    private static func filenameSafe(_ raw: String) -> String {
        String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
    }

    private static func hash8(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }
}
