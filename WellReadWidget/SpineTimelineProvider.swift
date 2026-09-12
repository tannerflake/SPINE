//
//  SpineTimelineProvider.swift
//  WellReadWidget
//
//  Renders whatever the app last wrote into the App Group. The app calls
//  WidgetCenter.reloadAllTimelines() after each snapshot write. When the
//  snapshot holds more friend books than one page shows, the timeline carries
//  minute-cadence entries that rotate through them; otherwise a single .never
//  entry.
//
//  One minute is WidgetKit's practical floor for swapping pre-rendered entries;
//  a widget cannot animate or tick on its own, so a faster cycle is not
//  available at any budget. The friends pane compensates by showing four books
//  per page instead of three.
//

import WidgetKit

struct SpineEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    /// Rotation counter: wall-clock minute index, so reloads mid-timeline
    /// continue the cycle instead of restarting it. Views mod this by their
    /// own page counts.
    let tick: Int
}

struct SpineTimelineProvider: TimelineProvider {
    /// One rotation step per minute — WidgetKit's reliable floor for
    /// pre-rendered entry swaps.
    private static let rotationInterval: TimeInterval = 60
    /// 2 hours per timeline, then .atEnd re-requests (~12 budget reloads/day).
    private static let entriesPerTimeline = 120

    func placeholder(in context: Context) -> SpineEntry {
        SpineEntry(date: .now, snapshot: .sample, tick: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (SpineEntry) -> Void) {
        let snapshot = context.isPreview ? .sample : WidgetSharedStore.loadSnapshot()
        completion(SpineEntry(date: .now, snapshot: snapshot, tick: 0))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpineEntry>) -> Void) {
        let snapshot = WidgetSharedStore.loadSnapshot()
        guard Self.hasRotatingContent(snapshot) else {
            completion(Timeline(entries: [SpineEntry(date: .now, snapshot: snapshot, tick: 0)], policy: .never))
            return
        }
        let baseMinute = Int(Date().timeIntervalSince1970 / Self.rotationInterval)
        let entries = (0..<Self.entriesPerTimeline).map { offset in
            SpineEntry(
                date: Date(timeIntervalSince1970: TimeInterval(baseMinute + offset) * Self.rotationInterval),
                snapshot: snapshot,
                tick: baseMinute + offset
            )
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    /// Only the friends pane pages now — both families show the reader's whole
    /// Reading now shelf at once, so a shelf alone never needs a timeline.
    private static func hasRotatingContent(_ snapshot: WidgetSnapshot?) -> Bool {
        guard let snapshot, snapshot.isSignedIn else { return false }
        return snapshot.friendBookItems.count > MediumWidgetView.friendsPerPage
    }
}

extension WidgetSnapshot {
    /// Widget-gallery preview. Filenames stay nil so cells render title cards —
    /// no bundled assets needed.
    static let sample = WidgetSnapshot(
        schemaVersion: WidgetSharedStore.currentSchemaVersion,
        isSignedIn: true,
        myBooks: [
            BookEntry(bookId: "sample-1", title: "East of Eden", author: "John Steinbeck", coverFilename: nil, progress: 0.62),
            BookEntry(bookId: "sample-2", title: "Giovanni's Room", author: "James Baldwin", coverFilename: nil, progress: 0.18),
        ],
        friends: [
            FriendEntry(uid: "f1", displayName: "Avery", avatarFilename: nil, books: [
                BookEntry(bookId: "sample-3", title: "The Secret History", author: "Donna Tartt", coverFilename: nil),
            ]),
            FriendEntry(uid: "f2", displayName: "Jordan", avatarFilename: nil, books: [
                BookEntry(bookId: "sample-4", title: "Pachinko", author: "Min Jin Lee", coverFilename: nil),
            ]),
            FriendEntry(uid: "f3", displayName: "Sam", avatarFilename: nil, books: [
                BookEntry(bookId: "sample-5", title: "Dune", author: "Frank Herbert", coverFilename: nil),
            ]),
            FriendEntry(uid: "f4", displayName: "Robin", avatarFilename: nil, books: [
                BookEntry(bookId: "sample-6", title: "Piranesi", author: "Susanna Clarke", coverFilename: nil),
            ]),
        ],
        generatedAt: .now
    )
}
