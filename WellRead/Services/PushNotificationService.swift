//
//  PushNotificationService.swift
//  WellRead
//
//  FCM registration, permission, Firestore token storage, and deep-link extraction from push payloads.
//

import Foundation
import SwiftUI
import UIKit
import UserNotifications
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging

enum WellreadDeepLink {
    /// `wellread://club/join/{CODE}` — a club invite link; opens the join sheet
    /// with the code filled in (or joins outright once signed in).
    static func clubInviteCode(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "wellread" else { return nil }
        guard url.host?.lowercased() == "club" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0].lowercased() == "join" else { return nil }
        return BookClub.normalizeInviteCode(parts[1])
    }

    /// `wellread://club/{clubId}` — straight to a club the reader belongs to.
    static func clubId(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "wellread" else { return nil }
        guard url.host?.lowercased() == "club" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, parts[0].lowercased() != "join" else { return nil }
        return parts[0]
    }

    /// `wellread://post/{postUUID}` — opens Feed and the post’s comment thread.
    static func postId(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "wellread" else { return nil }
        guard url.host?.lowercased() == "post" else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// `wellread://queue` — a widget tap on one of your own reading-now covers.
    static func isQueueLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "wellread" && url.host?.lowercased() == "queue"
    }

    /// `wellread://book/{bookId}?reader={uid}` — a widget tap on a friend's cover.
    /// The reader is the person whose shelf the cover came from; the book profile
    /// uses it to show their read in context.
    static func bookLink(from url: URL) -> (bookId: String, readerUid: String?)? {
        guard url.scheme?.lowercased() == "wellread", url.host?.lowercased() == "book" else { return nil }
        let bookId = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bookId.isEmpty else { return nil }
        let reader = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "reader" })?.value
        return (bookId, reader?.isEmpty == false ? reader : nil)
    }

    /// Reads `postId` from FCM `data` (and common alternate keys).
    static func postId(fromNotificationUserInfo userInfo: [AnyHashable: Any]) -> String? {
        for key in ["postId", "post_id"] {
            if let s = userInfo[AnyHashable(key)] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    /// Reads `commentId` from FCM `data` — set on comment-targeted pushes (liked,
    /// replied, mentioned, commented) so the tap can scroll the thread to the
    /// exact comment.
    static func commentId(fromNotificationUserInfo userInfo: [AnyHashable: Any]) -> String? {
        for key in ["commentId", "comment_id"] {
            if let s = userInfo[AnyHashable(key)] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    /// `data.type` from FCM (e.g. `friend_review_posted`); used to tune tap behavior.
    static func pushNotificationType(from userInfo: [AnyHashable: Any]) -> String? {
        for key in ["type", "notification_type"] {
            if let s = userInfo[AnyHashable(key)] as? String, !s.isEmpty { return s }
        }
        return nil
    }
}

enum PushNotificationService {
    private static let userRepo = UserRepository()

    /// Blend push tapped before the UI was mounted (cold start): stashed here and
    /// consumed by `MainTabView.onAppear`, since a NotificationCenter post at tap
    /// time would land before any listener exists.
    private static var pendingBlendId: String?
    /// Club pushes (`club_*`) carry `clubId`; stashed until the Clubs tab is up.
    static var pendingClubId: String?
    /// A `wellread://club/join/{CODE}` link opened before the main UI existed.
    static var pendingClubInviteCode: String?

    static func consumePendingBlendTap() -> String? {
        defer { pendingBlendId = nil }
        return pendingBlendId
    }

    /// Cold-start stashes for the non-blend pushes (same problem as `pendingBlendId`:
    /// the tap fires before MainTabView mounts, so the NotificationCenter post is lost).
    /// Warm taps are handled by the observers, which also consume the stash.
    private static var pendingOpenPostCommentsId: String?
    /// Set alongside `pendingOpenPostCommentsId` when the push targets one comment
    /// (liked, replied, mentioned, commented): the thread scrolls to and flashes it.
    private static var pendingOpenPostCommentsCommentId: String?
    private static var pendingProfileUserId: String?
    /// Book-recommendation push tapped on a cold start: the tap lands on the
    /// queue (Recommended shelf), no id needed — just "go there" once mounted.
    private static var pendingOpenQueue = false

    static func consumePendingOpenPostCommentsTap() -> String? {
        defer { pendingOpenPostCommentsId = nil }
        return pendingOpenPostCommentsId
    }

    static func consumePendingOpenPostCommentsCommentTap() -> String? {
        defer { pendingOpenPostCommentsCommentId = nil }
        return pendingOpenPostCommentsCommentId
    }

    static func consumePendingProfileUserTap() -> String? {
        defer { pendingProfileUserId = nil }
        return pendingProfileUserId
    }

    static func consumePendingOpenQueueTap() -> Bool {
        defer { pendingOpenQueue = false }
        return pendingOpenQueue
    }

    /// Widget tap on a friend's cover before the UI mounted (cold start).
    private static var pendingBookProfile: (bookId: String, readerUid: String?)?

    static func consumePendingBookProfileTap() -> (bookId: String, readerUid: String?)? {
        defer { pendingBookProfile = nil }
        return pendingBookProfile
    }

    /// Widget tap on one of your own covers: land on Profile → Queue. Stashes
    /// first so a cold start replays it from `MainTabView.onAppear`.
    static func routeToQueue() {
        // Same standing as a push tap: launch nudges must not cover where the
        // tap is navigating to.
        lastDeepLinkTapAt = Date()
        pendingOpenQueue = true
        routeAfterClearingPresentedModals {
            NotificationCenter.default.post(name: .spineOpenQueue, object: nil)
        }
    }

    /// Widget tap on a friend's cover: open that book's profile over whatever
    /// tab is showing.
    static func routeToBookProfile(bookId: String, readerUid: String?) {
        // Stamped before the book fetch: `deepLinkBook` stays nil until the
        // fetch lands, so this is what holds the nudges off in the meantime.
        lastDeepLinkTapAt = Date()
        pendingBookProfile = (bookId, readerUid)
        routeAfterClearingPresentedModals {
            var info: [String: Any] = ["bookId": bookId]
            if let readerUid { info["readerUid"] = readerUid }
            NotificationCenter.default.post(name: .spineOpenBookProfile, object: nil, userInfo: info)
        }
    }

    /// Registers with APNs without showing the permission dialog (for users who already granted alerts, or after cold start).
    static func registerForRemoteNotificationsOnly() {
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    static func requestPermissionAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
                /// APNs/FCM can produce a token shortly after registration; delegate may have fired before auth was ready — sync once permission is granted.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    syncFCMTokenToFirestoreIfSignedIn()
                }
            }
        }
    }

    /// Fetches the current FCM token and writes `users/{uid}/fcmTokens/{hash}`. Call after sign-in and when fixing “skipped (not signed in)” races.
    static func syncFCMTokenToFirestoreIfSignedIn() {
        guard Auth.auth().currentUser != nil else { return }
        Task {
            do {
                let token = try await Messaging.messaging().token()
                persistFCMTokenToFirestore(token)
            } catch {
                #if DEBUG
                print("syncFCMTokenToFirestoreIfSignedIn: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// If permission was denied, opens Settings; otherwise requests authorization (shows system prompt when still undetermined).
    static func requestPermissionOrOpenSettingsIfDenied() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .denied:
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                case .notDetermined:
                    requestPermissionAndRegister()
                default:
                    requestPermissionAndRegister()
                }
            }
        }
    }

    /// `true` when we should show the recurring push nudge (no full alert permission yet).
    static func needsPushPermissionNudge(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let needs: Bool
            switch settings.authorizationStatus {
            case .authorized:
                needs = false
            case .provisional, .ephemeral:
                needs = false
            case .denied, .notDetermined:
                needs = true
            @unknown default:
                needs = true
            }
            DispatchQueue.main.async {
                completion(needs)
            }
        }
    }

    static func persistFCMTokenToFirestore(_ token: String) {
        guard let uid = Auth.auth().currentUser?.uid else {
            PushRegistrationDiagnostics.recordFirestoreSkippedNotSignedIn()
            return
        }
        Task {
            do {
                try await userRepo.saveFCMToken(uid: uid, token: token)
                PushRegistrationDiagnostics.recordFirestoreWriteSuccess(at: Date())
            } catch {
                PushRegistrationDiagnostics.recordFirestoreWriteFailed(error)
            }
        }
    }

    /// The requester withdrew a Book Blend request: clear the matching invite
    /// alert from this device's Notification Center (arrives as a silent push
    /// so the withdrawal itself never makes a sound).
    static func removeDeliveredBlendRequestNotifications(blendId: String, completion: @escaping () -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { note in
                    let info = note.request.content.userInfo
                    return WellreadDeepLink.pushNotificationType(from: info) == "blend_request"
                        && (info[AnyHashable("blendId")] as? String) == blendId
                }
                .map(\.request.identifier)
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
            DispatchQueue.main.async { completion() }
        }
    }

    /// When the user last tapped a push (any type). Launch nudges stand down for a
    /// while afterwards so they don't cover the screen the tap navigated to.
    private(set) static var lastDeepLinkTapAt: Date?

    static var recentlyHandledDeepLinkTap: Bool {
        guard let t = lastDeepLinkTapAt else { return false }
        return Date().timeIntervalSince(t) < 30
    }

    /// How long to wait after a modal teardown before routing. UIKit's dismissal
    /// completion fires before SwiftUI has written `false`/`nil` back into the
    /// `isPresented`/`item` bindings behind it, and a sheet asked for inside that
    /// window is silently dropped ("only one sheet can be presented").
    private static let postDismissRoutingDelay: TimeInterval = 0.35

    /// The frontmost window's root controller (single-scene app).
    private static func activeRootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })?
            .rootViewController
    }

    /// A tapped deep link outranks whatever sheet/drawer the user left open: only
    /// one sheet can present at a time, so routing straight into a target while a
    /// drawer is up used to do nothing visible until they closed the drawer by
    /// hand. Tear the presented stack down first, then route.
    static func routeAfterClearingPresentedModals(_ route: @escaping () -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { routeAfterClearingPresentedModals(route) }
            return
        }
        guard let root = activeRootViewController(), root.presentedViewController != nil else {
            // Nothing in the way (cold start included) — unchanged behavior.
            route()
            return
        }
        var chain: [UIViewController] = []
        var next = root.presentedViewController
        while let current = next {
            chain.append(current)
            next = current.presentedViewController
        }
        // An unsent draft (a half-typed comment, review, or note) keeps the screen
        // for the same reason: the teardown can't give the typing back. Holding
        // the screen isn't enough on its own — routing underneath would swap the
        // comments sheet's post out from under the composer — so the link waits
        // for the draft to be sent or abandoned, then lands.
        guard !ComposerDraftGuard.hasLiveDraft else {
            ComposerDraftGuard.deferUntilDraftsClear(route)
            return
        }
        // Flows that deliberately block swipe-to-dismiss (profile completion, the
        // push permission prompt, a mid-flight Goodreads import) keep the screen;
        // the deep link routes underneath and lands when that flow finishes.
        guard !chain.contains(where: { $0.isModalInPresentation }) else {
            route()
            return
        }
        // Already on its way out (a bell row calls SwiftUI's `dismiss()` first):
        // let that finish rather than dismissing on top of it.
        guard !chain.contains(where: { $0.isBeingDismissed }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + postDismissRoutingDelay, execute: route)
            return
        }
        // Dismissing on the root takes the whole presented stack with it.
        root.dismiss(animated: true) {
            DispatchQueue.main.asyncAfter(deadline: .now() + postDismissRoutingDelay, execute: route)
        }
    }

    static func handleRemoteNotificationTap(userInfo: [AnyHashable: Any]) {
        lastDeepLinkTapAt = Date()
        routeAfterClearingPresentedModals {
            routeRemoteNotificationTap(userInfo: userInfo)
        }
    }

    private static func routeRemoteNotificationTap(userInfo: [AnyHashable: Any]) {
        let type = WellreadDeepLink.pushNotificationType(from: userInfo)
        /// Every club push lands on the club page: added, new book, meeting reminders.
        if (type ?? "").hasPrefix("club_") {
            if let clubId = userInfo[AnyHashable("clubId")] as? String, !clubId.isEmpty {
                pendingClubId = clubId
                NotificationCenter.default.post(
                    name: .spineOpenClub,
                    object: nil,
                    userInfo: ["clubId": clubId]
                )
            }
            return
        }
        /// Book Blend pushes (invite or ready) land on the blend landing screen,
        /// which routes by the doc's status — both types carry `blendId`.
        if type == "blend_request" || type == "blend_ready" {
            if let blendId = userInfo[AnyHashable("blendId")] as? String, !blendId.isEmpty {
                pendingBlendId = blendId
                NotificationCenter.default.post(
                    name: .spineOpenBookBlend,
                    object: nil,
                    userInfo: ["blendId": blendId]
                )
            }
            return
        }
        /// Friend-review, review-liked, and review-mention pushes open the review's
        /// drawer (the comment thread, whose header is the review itself). Nothing
        /// tries to scroll the feed to the post: that silently did nothing whenever
        /// the post was outside the feed's listener window or never on the feed at
        /// all (a liked read with no post). The drawer fetches the post by id, so
        /// it always lands.
        if type == "friend_review_posted" || type == "review_liked" || type == "review_mentioned" {
            guard let postId = WellreadDeepLink.postId(fromNotificationUserInfo: userInfo) else {
                NotificationCenter.default.post(name: .wellreadOpenFeed, object: nil)
                return
            }
            openPostComments(postId: postId, commentId: nil)
            return
        }
        /// New-follower and contact-joined pushes both land on that person's
        /// profile (their tier list), where the Follow button is. Both carry the
        /// uid as `followerId`. Legacy payloads without it fall back to the feed.
        if type == "new_follower" || type == "contact_joined" {
            if let followerId = userInfo[AnyHashable("followerId")] as? String, !followerId.isEmpty {
                pendingProfileUserId = followerId
                NotificationCenter.default.post(
                    name: .spineOpenUserProfile,
                    object: nil,
                    userInfo: ["userId": followerId]
                )
            } else {
                NotificationCenter.default.post(name: .wellreadOpenFeed, object: nil)
            }
            return
        }
        /// Book-recommendation pushes land on the queue, whose Recommended shelf
        /// holds the pending recommendation.
        if type == "book_recommended" {
            pendingOpenQueue = true
            NotificationCenter.default.post(name: .spineOpenQueue, object: nil)
            return
        }
        /// Everything else (review_commented, comment_replied, thread_commented,
        /// comment_mentioned, comment_liked) opens the post's comment thread.
        /// Each carries `commentId` so the thread scrolls to the exact comment
        /// (legacy payloads without it just open the thread).
        guard let postId = WellreadDeepLink.postId(fromNotificationUserInfo: userInfo) else { return }
        openPostComments(postId: postId, commentId: WellreadDeepLink.commentId(fromNotificationUserInfo: userInfo))
    }

    /// Opens the post's comment drawer (review-context header + thread), scrolled
    /// to `commentId` when given. Stashes for the cold-start replay, then posts
    /// for the warm-tap observers.
    private static func openPostComments(postId: String, commentId: String?) {
        pendingOpenPostCommentsId = postId
        pendingOpenPostCommentsCommentId = commentId
        var info: [AnyHashable: Any] = ["postId": postId]
        if let commentId { info["commentId"] = commentId }
        NotificationCenter.default.post(
            name: .wellreadOpenFeedPost,
            object: nil,
            userInfo: info
        )
    }
}

/// Screens where the user is mid-sentence (a comment box, review thoughts, a
/// recommendation note) register their unsent draft here. A tapped deep link
/// tears down whatever is presented, and typed text is the one thing that
/// teardown can't give back — so a live draft holds the screen, exactly like the
/// deliberately non-dismissible onboarding flows. The link still routes
/// underneath and lands when the user is done, which is the pre-teardown
/// behavior. Main-thread only (registered from SwiftUI, read from the tap).
enum ComposerDraftGuard {
    private static var draftIds: Set<String> = []
    /// A deep link that arrived mid-draft, waiting for the composer to clear.
    /// Only the newest is kept — a second tap supersedes the first.
    private static var pendingRoute: (() -> Void)?

    /// True while any registered composer holds text the user hasn't sent.
    static var hasLiveDraft: Bool { !draftIds.isEmpty }

    /// Runs `route` once every composer draft is gone (sent or abandoned), back
    /// through the normal teardown so the link still clears whatever is open by
    /// then. If nothing ever clears, nothing routes — which is the point.
    static func deferUntilDraftsClear(_ route: @escaping () -> Void) {
        pendingRoute = route
    }

    static func set(_ id: String, hasDraft: Bool) {
        let hadDrafts = !draftIds.isEmpty
        if hasDraft {
            draftIds.insert(id)
        } else {
            draftIds.remove(id)
        }
        guard hadDrafts, draftIds.isEmpty, let waiting = pendingRoute else { return }
        pendingRoute = nil
        // A beat, because this often fires from `onDisappear` mid-dismissal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            PushNotificationService.routeAfterClearingPresentedModals(waiting)
        }
    }
}

private struct ComposerDraftGuardModifier: ViewModifier {
    let text: String
    /// What the field started with. Edit sheets open pre-filled, so "has text"
    /// isn't the question — "has unsaved changes" is (clearing an existing review
    /// counts too).
    let baseline: String
    @State private var id = UUID().uuidString

    private var hasDraft: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed != baseline.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func body(content: Content) -> some View {
        content
            .onAppear { ComposerDraftGuard.set(id, hasDraft: hasDraft) }
            .onChange(of: text) { _, _ in ComposerDraftGuard.set(id, hasDraft: hasDraft) }
            .onDisappear { ComposerDraftGuard.set(id, hasDraft: false) }
    }
}

extension View {
    /// Marks this screen as holding an unsent draft while `text` is non-blank, so
    /// a deep-link tap leaves it standing instead of throwing the draft away.
    /// Attach to the composer's outermost view, not the field itself — the whole
    /// sheet is what would be torn down.
    func composerDraftGuard(_ text: String, baseline: String = "") -> some View {
        modifier(ComposerDraftGuardModifier(text: text, baseline: baseline))
    }
}

extension Notification.Name {
    /// Opens the Feed tab without scrolling to a post or opening comments.
    static let wellreadOpenFeed = Notification.Name("wellreadOpenFeed")
    /// Opens the post's comment drawer (review header + thread) over the Feed tab, without repositioning the feed itself. `userInfo["postId"]` is the post UUID string; optional `userInfo["commentId"]` scrolls the thread to that comment.
    static let wellreadOpenFeedPost = Notification.Name("wellreadOpenFeedPost")
    /// After a user marks a book as read: switch to Profile tab → Read segment, scroll the tier list to Unranked, and pulse-glow the just-reviewed book until they tier it. `userInfo["bookId"]` is the `Book.id`.
    static let spineHighlightTierBook = Notification.Name("spineHighlightTierBook")
    /// After a user adds a book to their queue from the search flow: switch to Profile tab → Queue segment so they land on the queue and see it was added.
    static let spineOpenQueue = Notification.Name("spineOpenQueue")
    /// Switch to the Discover tab (no way back to where the user came from).
    static let spineOpenDiscover = Notification.Name("spineOpenDiscover")
    /// "Discover more" on the feed's Selected for you row: switch to the Discover
    /// tab and remember the feed as the way in, so Discover offers a back arrow
    /// (and a left-edge swipe) home to the reader's exact place in the feed.
    static let spineOpenDiscoverFromFeed = Notification.Name("spineOpenDiscoverFromFeed")
    /// Back arrow / left-edge swipe on a Discover opened from the feed: return to
    /// the Feed tab, restoring its scroll offset.
    static let spineReturnToFeed = Notification.Name("spineReturnToFeed")
    /// Blend push tapped: present the Book Blend landing screen. `userInfo["blendId"]` is the pair doc id.
    static let spineOpenBookBlend = Notification.Name("spineOpenBookBlend")
    /// Widget tap on a friend's cover: present that book's profile. `userInfo["bookId"]` is the `Book.id`; optional `userInfo["readerUid"]` is the friend whose shelf it came from.
    static let spineOpenBookProfile = Notification.Name("spineOpenBookProfile")
    /// New-follower push tapped: present the follower's profile (tier list). `userInfo["userId"]` is their Firebase UID.
    static let spineOpenUserProfile = Notification.Name("spineOpenUserProfile")
    /// Feed tab tapped while already selected: FeedView scrolls to top if scrolled down, or refreshes if already at top.
    static let spineFeedTabTappedAgain = Notification.Name("spineFeedTabTappedAgain")
    static let spineClubsTabTappedAgain = Notification.Name("spineClubsTabTappedAgain")
    /// userInfo["clubId"]: open that club (Clubs tab + detail page).
    static let spineOpenClub = Notification.Name("spineOpenClub")
    /// userInfo["code"]: open the join sheet with an invite code filled in.
    static let spineJoinClubWithCode = Notification.Name("spineJoinClubWithCode")
    /// Discover tab tapped while already selected: DiscoverView pops any pushed pages back to its root.
    static let spineDiscoverTabTappedAgain = Notification.Name("spineDiscoverTabTappedAgain")
    /// Search tab tapped while already selected: SearchView pops any pushed pages back to its root.
    static let spineSearchTabTappedAgain = Notification.Name("spineSearchTabTappedAgain")
    /// Profile tab tapped while already selected: ProfileLibraryView pops any pushed pages back to its root.
    static let spineProfileTabTappedAgain = Notification.Name("spineProfileTabTappedAgain")
}
