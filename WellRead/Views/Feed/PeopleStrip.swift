//
//  PeopleStrip.swift
//  Spine
//
//  The feed's people row: everyone you follow first, then the rest of SPINE
//  behind a horizontal sticky header, ranked by how connected each reader is
//  to you. The roster is fetched whole (a few hundred members) so the ranking
//  is global rather than per-page; revisit if the member count outgrows that.
//

import SwiftUI

/// Store behind the feed people strip.
///
/// Two groups: people you follow (reading-now first, then alphabetical), and
/// everyone else ranked by similarity — mutual connections between you and the
/// candidate, with the founder excluded from every term because he follows and
/// is followed by the whole roster (counting him would hand every pair one
/// meaningless mutual). Readers with no connection to you fall back to
/// activity: reading a book now first, then most books ranked.
@MainActor
final class PeopleStripModel: ObservableObject {
    /// App-wide instance. `MainTabView` rebuilds `FeedView` on every tab
    /// switch, so a per-view `@StateObject` would refetch the whole roster
    /// and re-show the skeleton each time the reader comes back to the feed.
    /// Holding the model here keeps the loaded strip for the session; account
    /// changes still reload via `loadIfNeeded`.
    static let shared = PeopleStripModel()

    struct Reader: Identifiable, Equatable {
        let uid: String
        let user: User
        /// Similarity score, frozen at load time (see `similarityScore`) so a
        /// follow elsewhere in the app never reshuffles cells under a
        /// scrolling finger. Pull to refresh rescores everyone.
        let score: Int

        var id: String { uid }
    }

    /// Roster fetch cap — well above the current member count. If the roster
    /// approaches it, this scoring belongs in a Cloud Function instead.
    private static let rosterLimit = 500

    @Published private(set) var followed: [Reader] = []
    @Published private(set) var discoverable: [Reader] = []
    /// Reading-now covers (uid → books in shelf order). One roster-wide query;
    /// doubles as a ranking input.
    @Published private(set) var readingNowByUid: [String: [Book]] = [:]
    @Published private(set) var isLoadingInitial = true

    private let userRepo = UserRepository()
    private let userBookRepo = UserBookRepository()

    private var currentUid: String?
    private var followingSet: Set<String> = []
    private var hasLoadedOnce = false
    /// Bumped by every (re)load so in-flight work from a previous member or a
    /// previous pull to refresh can't write its results over the current list.
    private var generation = 0

    // MARK: - Loading

    /// First load for this member. A no-op once loaded, so returning to the tab
    /// doesn't refetch the roster.
    func loadIfNeeded(currentUid: String?, following: [String]) async {
        guard !hasLoadedOnce || currentUid != self.currentUid else { return }
        await reload(currentUid: currentUid, following: following)
    }

    /// Pull to refresh: refetches the roster and covers, then reranks. The
    /// previous list stays on screen until both land.
    func reload(currentUid: String?, following: [String]) async {
        generation += 1
        let token = generation
        // A different member (sign-out / sign-in) must not see the previous
        // member's strip while theirs loads: back to the skeleton.
        let memberChanged = hasLoadedOnce && currentUid != self.currentUid
        if memberChanged {
            followed = []
            discoverable = []
            readingNowByUid = [:]
        }
        self.currentUid = currentUid
        followingSet = Set(following).subtracting([currentUid].compactMap { $0 })
        isLoadingInitial = !hasLoadedOnce || memberChanged
        hasLoadedOnce = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiPreview") {
            // No Firestore in preview runs: a demo roster so the strip and the
            // feed's "Readers to follow" row can be verified in the simulator.
            seedUIPreviewRoster()
            return
        }
        #endif

        async let rosterFetch = userRepo.fetchAllReaderProfiles(
            excludingUid: currentUid, limit: Self.rosterLimit
        )
        async let coversFetch = userBookRepo.fetchAllReadingNowBooks()
        var (roster, covers) = await (rosterFetch, coversFetch)
        guard token == generation else { return }

        // People you follow who fell past the roster cap still get cells.
        let missing = followingSet.subtracting(roster.map(\.uid))
        if !missing.isEmpty {
            roster += await userRepo.fetchReaderProfiles(uids: Array(missing), excludingUid: currentUid)
            guard token == generation else { return }
        }

        readingNowByUid = covers
        let followedRows = roster.filter { followingSet.contains($0.uid) }
        followed = sortFollowed(followedRows.map { Reader(uid: $0.uid, user: $0.user, score: 0) })
        discoverable = sortDiscoverable(
            roster
                .filter { !followingSet.contains($0.uid) }
                .map { row in
                    Reader(
                        uid: row.uid,
                        user: row.user,
                        score: similarityScore(
                            candidateUid: row.uid,
                            candidateFollowing: row.user.following,
                            peers: followedRows
                        )
                    )
                }
        )
        isLoadingInitial = false
    }

    /// Repartitions loaded readers after a follow or unfollow (from the strip's
    /// own plus button or from anywhere else in the app). Existing discoverable
    /// scores are kept as-is so the strip doesn't reshuffle mid-interaction;
    /// only a just-unfollowed reader is scored fresh, since they were carried
    /// at zero while followed.
    func syncFollowing(_ uids: Set<String>) async {
        guard hasLoadedOnce else { return }
        let normalized = uids.subtracting([currentUid].compactMap { $0 })
        guard normalized != followingSet else { return }
        let dropped = followingSet.subtracting(normalized)
        followingSet = normalized
        let token = generation

        var all = followed + discoverable
        let missing = normalized.subtracting(all.map(\.uid))
        if !missing.isEmpty {
            let rows = await userRepo.fetchReaderProfiles(uids: Array(missing), excludingUid: currentUid)
            guard token == generation else { return }
            let loaded = Set(all.map(\.uid))
            let added = rows
                .filter { !loaded.contains($0.uid) }
                .map { Reader(uid: $0.uid, user: $0.user, score: 0) }
            all.append(contentsOf: added)
            let covers = await userBookRepo.fetchReadingNowBooks(forUserIds: added.map(\.uid))
            guard token == generation else { return }
            readingNowByUid.merge(covers) { _, new in new }
        }
        let followedRows = all
            .filter { followingSet.contains($0.uid) }
            .map { (uid: $0.uid, user: $0.user) }
        followed = sortFollowed(followedRows.map { Reader(uid: $0.uid, user: $0.user, score: 0) })
        discoverable = sortDiscoverable(
            all
                .filter { !followingSet.contains($0.uid) }
                .map { reader in
                    guard dropped.contains(reader.uid) else { return reader }
                    return Reader(
                        uid: reader.uid,
                        user: reader.user,
                        score: similarityScore(
                            candidateUid: reader.uid,
                            candidateFollowing: reader.user.following,
                            peers: followedRows
                        )
                    )
                }
        )
    }

    #if DEBUG
    private func seedUIPreviewRoster() {
        func reader(_ uid: String, _ name: String, books: Int, score: Int) -> Reader {
            var u = User.demo
            u.id = UUID()
            u.username = name.lowercased()
            u.displayName = name
            u.firstName = name
            u.totalBooksRead = books
            return Reader(uid: uid, user: u, score: score)
        }
        followed = [reader("pv-june", "June", books: 42, score: 0)]
        discoverable = [
            reader("pv-1", "Priya Natarajan", books: 118, score: 4),
            reader("pv-2", "Marcus Hale", books: 67, score: 3),
            reader("pv-3", "Ana Lucía Reyes", books: 54, score: 2),
            reader("pv-4", "Theo Brandt", books: 31, score: 1),
            reader("pv-5", "Wren Okafor", books: 23, score: 0),
            reader("pv-6", "Sam Idowu", books: 12, score: 0)
        ]
        isLoadingInitial = false
    }
    #endif

    // MARK: - Ranking

    /// People you follow: anyone reading a book right now first, then alphabetical.
    private func sortFollowed(_ readers: [Reader]) -> [Reader] {
        readers.sorted { a, b in
            let aReading = isReadingNow(a.uid)
            let bReading = isReadingNow(b.uid)
            if aReading != bReading { return aReading }
            return a.user.displayName.localizedCaseInsensitiveCompare(b.user.displayName) == .orderedAscending
        }
    }

    /// Everyone else: most similar to you first. Past the readers with any
    /// connection, activity breaks the tie — reading a book now, then most
    /// books ranked, then name.
    private func sortDiscoverable(_ readers: [Reader]) -> [Reader] {
        readers.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let aReading = isReadingNow(a.uid)
            let bReading = isReadingNow(b.uid)
            if aReading != bReading { return aReading }
            if a.user.totalBooksRead != b.user.totalBooksRead {
                return a.user.totalBooksRead > b.user.totalBooksRead
            }
            return a.user.displayName.localizedCaseInsensitiveCompare(b.user.displayName) == .orderedAscending
        }
    }

    private func isReadingNow(_ uid: String) -> Bool {
        !(readingNowByUid[uid] ?? []).isEmpty
    }

    /// How connected a not-yet-followed reader is to you (see `PeopleSimilarity`,
    /// shared with the Users scope of Search).
    private func similarityScore(
        candidateUid: String,
        candidateFollowing: [String],
        peers: [(uid: String, user: User)]
    ) -> Int {
        PeopleSimilarity.score(
            candidateUid: candidateUid,
            candidateFollowing: candidateFollowing,
            following: followingSet,
            peers: peers.map { (uid: $0.uid, following: $0.user.following) },
            currentUid: currentUid
        )
    }
}

/// The people row itself: sticky header plus the horizontal strip. Owns the
/// strip's scroll offset so tracking it doesn't invalidate the whole feed.
struct PeopleStrip: View {
    @ObservedObject var model: PeopleStripModel

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService

    /// Uids with a follow write in flight (debounces the quick-follow plus button).
    @State private var followInFlight: Set<String> = []
    /// Horizontal content offset of the strip — drives the sticky header.
    @State private var scrollX: CGFloat = 0
    /// Measured width of the pinned "FOLLOWING" label (for the push-out offset).
    @State private var followingLabelWidth: CGFloat = 0
    /// Member whose photo is being held open full screen (see `AvatarZoomOverlay`).
    @State private var zoomUser: User?

    private let userRepo = UserRepository()

    private static let morePeopleTitle = "ALL USERS"
    /// Fixed people-strip metrics — cells are exactly this wide (the name label's
    /// frame), which lets the sticky header compute the group boundary statically.
    private static let peopleCellWidth: CGFloat = 72
    private static let peopleCellSpacing: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isLoadingInitial {
                loadingRow
            } else if model.followed.isEmpty && model.discoverable.isEmpty {
                EmptyView()
            } else {
                stickyHeader
                strip
            }
        }
        .padding(.top, 4)
        .avatarZoom(
            isPresented: Binding(
                get: { zoomUser != nil },
                set: { if !$0 { zoomUser = nil } }
            ),
            urlString: zoomUser?.profileImageURL,
            displayName: zoomUser?.displayName,
            firstName: zoomUser?.firstName,
            lastName: zoomUser?.lastName,
            caption: zoomUser?.displayName
        )
        .animation(.easeInOut(duration: 0.25), value: myFollowingSet)
        .task {
            await model.loadIfNeeded(
                currentUid: authService.firebaseUser?.uid,
                following: authService.appUser?.following ?? []
            )
        }
        .onChange(of: authService.firebaseUser?.uid) { _, newValue in
            Task {
                await model.reload(
                    currentUid: newValue,
                    following: authService.appUser?.following ?? []
                )
            }
        }
        .onChange(of: myFollowingSet) { _, newValue in
            Task { await model.syncFollowing(newValue) }
        }
    }

    /// Uids the signed-in user follows.
    private var myFollowingSet: Set<String> {
        Set(authService.appUser?.following ?? [])
    }

    /// Skeleton at the loaded strip's exact footprint — header label bar, then
    /// avatar circles + name bars at the real cell metrics — so the feed below
    /// doesn't shift when the roster lands.
    private var loadingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            ShimmerBar(height: 12, cornerRadius: 3)
                .frame(width: 82)
                .frame(height: 16)
                .padding(.horizontal, Theme.horizontalPadding)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Self.peopleCellSpacing) {
                    ForEach(0..<6, id: \.self) { _ in
                        VStack(spacing: 8) {
                            ShimmerCircle(size: 64)
                            ShimmerBar(height: 9, cornerRadius: 3)
                                .frame(width: 48)
                        }
                        .frame(width: Self.peopleCellWidth)
                    }
                }
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.top, 7)
                .padding(.bottom, 10)
            }
            .disabled(true)
        }
        .accessibilityLabel("Loading readers")
    }

    /// Content-space x where the not-yet-followed group starts in the strip.
    private var morePeopleContentX: CGFloat {
        let n = CGFloat(model.followed.count)
        guard n > 0 else { return Theme.horizontalPadding }
        return Theme.horizontalPadding
            + n * (Self.peopleCellWidth + Self.peopleCellSpacing)
            + Theme.chromeHairline + Self.peopleCellSpacing
    }

    /// One label line above the strip, behaving like a horizontal sticky
    /// section header: "FOLLOWING" pins at the leading edge while its people
    /// are in view; "ALL USERS" travels with its group and pushes
    /// "FOLLOWING" out once it reaches the pin.
    private var stickyHeader: some View {
        // Boundary relative to the pin point; 0 = the "more" group is at/under it.
        let moreOffset = model.followed.isEmpty
            ? 0
            : max(0, morePeopleContentX - scrollX - Theme.horizontalPadding)
        let followingOffset = min(0, moreOffset - followingLabelWidth - 12)
        return ZStack(alignment: .leading) {
            if !model.followed.isEmpty {
                headerLabel("FOLLOWING")
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { newValue in
                        followingLabelWidth = newValue
                    }
                    .offset(x: followingOffset)
            }
            if !model.discoverable.isEmpty {
                headerLabel(Self.morePeopleTitle)
                    .offset(x: moreOffset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 16)
        .clipped()
        .padding(.horizontal, Theme.horizontalPadding)
        .accessibilityElement(children: .combine)
    }

    private func headerLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold))
            .tracking(1)
            .foregroundStyle(Theme.chrome)
            .fixedSize()
    }

    /// Single horizontal strip: followed readers first, a hairline, then the
    /// ranked roster. Lazy so only on-screen cells build their avatar and
    /// cover fan.
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Self.peopleCellSpacing) {
                ForEach(model.followed) { reader in
                    readerCell(reader: reader, isFollowed: true)
                }
                if !model.followed.isEmpty && !model.discoverable.isEmpty {
                    Rectangle()
                        .fill(Theme.chrome.opacity(0.35))
                        .frame(width: Theme.chromeHairline, height: 64)
                        .accessibilityHidden(true)
                }
                ForEach(model.discoverable) { reader in
                    readerCell(reader: reader, isFollowed: false)
                }
            }
            .padding(.horizontal, Theme.horizontalPadding)
            // Headroom for the quick-follow plus, which overhangs the avatar's
            // top edge — without it the ScrollView clips it.
            .padding(.top, 7)
            .padding(.bottom, 10)
        }
        .modifier(PeopleStripScrollTracking(scrollX: $scrollX))
    }

    /// Avatar + name cell. Not-yet-followed readers get a quick-follow plus
    /// top-right; reading-now covers float on the bottom-left of the avatar.
    private func readerCell(reader: PeopleStripModel.Reader, isFollowed: Bool) -> some View {
        let readingNow = model.readingNowByUid[reader.uid] ?? []
        return NavigationLink(value: reader.uid) {
            VStack(spacing: 8) {
                // The hold lives on the avatar itself, a descendant of the
                // link's label, so it consumes the touch instead of letting the
                // release push the library.
                circleAvatar(user: reader.user, size: 64)
                    .onLongPressGesture(minimumDuration: 0.35) {
                        WizardHaptics.step()
                        AvatarZoomPresentation.present($zoomUser, reader.user)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if !readingNow.isEmpty {
                            ReadingNowFanStack(books: readingNow, coverWidth: 19)
                                .offset(x: -9, y: 8)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if !isFollowed {
                            followPlusButton(targetUid: reader.uid)
                                .offset(x: 5, y: -5)
                        }
                    }
                Text(reader.user.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: Self.peopleCellWidth)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(reader.user.displayName), \(isFollowed ? "following" : "not following"), open library")
            .accessibilityHint("Touch and hold their photo to see it full screen")
        }
        .buttonStyle(.plain)
    }

    private func followPlusButton(targetUid: String) -> some View {
        Button {
            followReader(targetUid: targetUid)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.onChrome)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.accentGloss))
                .overlay(Circle().strokeBorder(Theme.background, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .disabled(followInFlight.contains(targetUid))
        .accessibilityLabel("Follow")
    }

    private func followReader(targetUid: String) {
        guard let uid = authService.firebaseUser?.uid, uid != targetUid else { return }
        guard !followInFlight.contains(targetUid) else { return }
        followInFlight.insert(targetUid)
        Task {
            do {
                try await userRepo.setFollowing(currentUid: uid, targetUid: targetUid, follow: true)
                await authService.refreshAppUser()
                await MainActor.run {
                    WidgetDataService.shared.scheduleRefresh(appState: appState, delay: 1.0, forceFriendRefresh: true)
                }
            } catch {
                #if DEBUG
                print("followReader: \(error)")
                #endif
            }
            await MainActor.run { _ = followInFlight.remove(targetUid) }
        }
    }

    private func circleAvatar(user: User, size: CGFloat) -> some View {
        UserAvatarView(
            urlString: user.profileImageURL,
            displayName: user.displayName,
            firstName: user.firstName,
            lastName: user.lastName,
            size: size
        )
        .overlay(
            Circle()
                .strokeBorder(Theme.chrome.opacity(0.55), lineWidth: 1.5)
        )
    }
}

/// Streams the people strip's horizontal content offset into `scrollX`.
/// Uses `onScrollGeometryChange` where available; on iOS 17 the offset stays 0,
/// so the header labels sit at their resting positions instead of tracking.
private struct PeopleStripScrollTracking: ViewModifier {
    @Binding var scrollX: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.x + geo.contentInsets.leading
            } action: { _, newValue in
                scrollX = newValue
            }
        } else {
            content
        }
    }
}
