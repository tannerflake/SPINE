//
//  BookBlendInviteView.swift
//  Spine
//
//  Book Blend entry flow: the profile button, and the full-screen landing that
//  routes a pair doc to the right moment — invite (accept / decline), the
//  "blending" generation interlude, waiting-on-them, or straight into the story.
//

import SwiftUI
import FirebaseFirestore

// MARK: - Profile entry button

enum BookBlendEntryState: Equatable {
    /// No blend yet (or a declined one) — show "Book Blend".
    case none
    case requestedByMe
    case invitedMe
    case ready
}

/// Ink capsule on another member's profile — the single doorway into a blend.
struct BookBlendEntryButton: View {
    let state: BookBlendEntryState
    let otherFirstName: String
    let action: () -> Void

    @State private var pulse = false

    private var label: String {
        switch state {
        case .none: return "Book Blend"
        case .requestedByMe: return "Blend requested"
        case .invitedMe: return "\(otherFirstName) invited you to Blend"
        case .ready: return "Watch your Book Blend"
        }
    }

    private var icon: String {
        switch state {
        case .none: return "shuffle"
        case .requestedByMe: return "hourglass"
        case .invitedMe: return "envelope.open.fill"
        case .ready: return "play.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(state == .requestedByMe ? Theme.textSecondary : Theme.onChrome)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                // Softened ink rather than full `chrome`: full-width and filled,
                // solid ink read as a black slab against the paper page.
                Capsule().fill(state == .requestedByMe ? Theme.chromeGray : Theme.chromeSoft)
            )
            .clipShape(Capsule())
            // Faint breathing pulse — alive without shouting.
            .scaleEffect(state == .requestedByMe ? 1 : (pulse ? 1.01 : 1))
            // Value-scoped: `withAnimation(.repeatForever)` in onAppear leaks into
            // the enclosing sheet's transaction and breaks its drag-to-dismiss.
            .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulse)
        }
        .buttonStyle(.springPress)
        .onAppear { pulse = true }
    }
}

// MARK: - Push presentation

/// Presents the blend landing when a blend push is tapped — warm (NotificationCenter)
/// or cold start (stash consumed on appear). Applied once, on `MainTabView`.
struct BookBlendPushPresenter: ViewModifier {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appState: AppState
    @State private var presented: Presentation?
    #if DEBUG
    /// `-uiPreviewBlend` (with `-uiPreview`): opens the blend story on demo data
    /// for simulator UI verification — no Firestore, no second account.
    @State private var showDemoStory = false
    #endif

    private struct Presentation: Identifiable {
        let id: String
        var autoAccept = false
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                if let blendId = PushNotificationService.consumePendingBlendTap() {
                    presented = Presentation(id: blendId)
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-uiPreviewBlend") {
                    showDemoStory = true
                }
                #endif
            }
            #if DEBUG
            .fullScreenCover(isPresented: $showDemoStory) {
                BookBlendStoryView(blend: .uiPreviewDemo, myUid: "ui-preview") {
                    showDemoStory = false
                }
                .environmentObject(appState)
            }
            #endif
            .onReceive(NotificationCenter.default.publisher(for: .spineOpenBookBlend)) { note in
                if let blendId = note.userInfo?["blendId"] as? String {
                    // Consume the cold-start stash too, so onAppear doesn't re-present.
                    _ = PushNotificationService.consumePendingBlendTap()
                    presented = Presentation(
                        id: blendId,
                        autoAccept: note.userInfo?["autoAccept"] as? Bool ?? false
                    )
                }
            }
            .fullScreenCover(item: $presented) { presentation in
                BookBlendLandingView(blendId: presentation.id, autoAccept: presentation.autoAccept)
                    .environmentObject(authService)
                    .environmentObject(appState)
            }
    }
}

extension View {
    func bookBlendPushPresenter() -> some View {
        modifier(BookBlendPushPresenter())
    }
}

// MARK: - Landing (router)

/// Full-screen destination for the profile button and both blend pushes. Routes
/// the pair doc by status + my role; accepting runs generation right here and
/// drops straight into the story.
struct BookBlendLandingView: View {
    let blendId: String
    /// Set when the user already said "Let's Blend" (launch invite modal):
    /// a pending invite accepts immediately instead of re-pitching. Consumed
    /// once, so an accept failure still falls back to the invite screen.
    var autoAccept = false

    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case loading
        case invite
        case generating
        case story(BookBlend)
        case waiting
        case gone
    }

    @State private var blend: BookBlend?
    @State private var listener: ListenerRegistration?
    @State private var phase: Phase = .loading
    @State private var acceptError: String?
    @State private var autoAcceptConsumed = false

    private var myUid: String { authService.firebaseUser?.uid ?? "" }

    private var otherName: String {
        guard let blend else { return "them" }
        return blend.participants[blend.otherUserId(from: myUid)]?.firstName ?? "them"
    }

    var body: some View {
        ZStack {
            BlendAuroraBackground(drift: true)

            switch phase {
            case .loading:
                ProgressView().tint(Theme.paperFixed)
            case .invite:
                if let blend {
                    inviteScreen(blend)
                }
            case .generating:
                BlendGeneratingView(
                    myPhotoURL: blend?.participants[myUid]?.photoURL,
                    otherPhotoURL: blend.flatMap { $0.participants[$0.otherUserId(from: myUid)]?.photoURL },
                    myName: blend?.participants[myUid]?.firstName ?? "You",
                    otherName: otherName
                )
            case .story(let ready):
                BookBlendStoryView(blend: ready, myUid: myUid) { dismiss() }
            case .waiting:
                waitingScreen
            case .gone:
                goneScreen
            }

            // Close chip — the story page has its own dismiss affordances. Kept
            // during generation as an escape hatch: the accept Task owns its own
            // copies, so generation finishes and saves even if the cover closes.
            if !isStory {
                VStack {
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Theme.paperFixed.opacity(0.85))
                                .padding(10)
                                .background(Circle().fill(.white.opacity(0.14)))
                        }
                        .buttonStyle(.springPress)
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { startListening() }
        .onDisappear {
            listener?.remove()
            listener = nil
        }
    }

    private var isStory: Bool {
        if case .story = phase { return true }
        return false
    }

    private func startListening() {
        guard listener == nil else { return }
        listener = BookBlendService.shared.listenBlend(pairId: blendId) { updated, isFromCache in
            blend = updated
            route(updated, isFromCache: isFromCache)
        }
    }

    /// Local phases the listener must not stomp: generation in flight, or a story
    /// already playing (a doc refresh mid-story would restart it). Cache snapshots
    /// can be stale, so they never lock a phase the server can't correct: a story
    /// entered from cache is re-routed if the server later disagrees, and a
    /// cached "no doc" stays on the loading spinner until the server confirms.
    private func route(_ updated: BookBlend?, isFromCache: Bool) {
        if phase == .generating { return }
        if isStory {
            // Same ready doc refreshing mid-story: keep playing. Server
            // contradiction (e.g. the story came from a stale cache): re-route.
            if isFromCache || updated?.status == .ready { return }
        }
        guard let updated else {
            // A cached miss isn't truth — wait for the server before "gone".
            if !isFromCache { phase = .gone }
            return
        }
        switch updated.status {
        case .ready:
            if let _ = updated.result {
                phase = .story(updated)
            } else if !isFromCache {
                phase = .gone
            }
        case .pending:
            if updated.recipientId == myUid {
                if autoAccept && !autoAcceptConsumed {
                    autoAcceptConsumed = true
                    accept(updated)
                } else {
                    phase = .invite
                }
            } else {
                phase = .waiting
            }
        case .declined:
            phase = .gone
        }
    }

    // MARK: Invite (accept / decline)

    private func inviteScreen(_ blend: BookBlend) -> some View {
        VStack(spacing: 0) {
            Spacer()

            BlendAvatarLockup(
                leftURL: blend.participants[blend.requesterId]?.photoURL,
                rightURL: blend.participants[blend.recipientId]?.photoURL,
                leftName: blend.participants[blend.requesterId]?.firstName ?? "?",
                rightName: blend.participants[blend.recipientId]?.firstName ?? "?",
                size: 92
            )
            .padding(.bottom, 28)

            Text("BOOK BLEND")
                .font(.system(size: 13, weight: .heavy))
                .tracking(4)
                .foregroundStyle(Theme.paperFixed.opacity(0.7))
                .padding(.bottom, 10)

            Text("\(otherName) wants to blend\nlibraries with you")
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.paperFixed)
                .padding(.horizontal, 28)
                .padding(.bottom, 14)

            Text("Get a taste match score. See which books you both loved. Get fun insights and books to steal from one another.")
                .font(Theme.callout())
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.paperFixed.opacity(0.75))
                .padding(.horizontal, 40)

            Spacer()

            if let acceptError {
                Text(acceptError)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.paperFixed.opacity(0.9))
                    .padding(.horizontal, 32)
                    .padding(.bottom, 10)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button("Let's Blend") { accept(blend) }
                    .buttonStyle(.spinePrimary)

                Button { declineAndDismiss(blend) } label: {
                    Text("Not now")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.paperFixed.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.springPress)

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                    Text("Blends are best when your full library is imported.")
                        .font(Theme.caption())
                }
                .foregroundStyle(Theme.paperFixed.opacity(0.55))
                .padding(.top, 2)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 30)
        }
    }

    /// Floor for the "Blending" beat. The requester's device usually precomputed
    /// the result, so accepting is one field write and returns almost instantly.
    /// Hold long enough for the two avatars to visibly merge, then reveal.
    private static let minGeneratingBeat: TimeInterval = 1.2

    private func accept(_ blend: BookBlend) {
        acceptError = nil
        phase = .generating
        let startedAt = Date()
        Task {
            do {
                let ready = try await BookBlendService.shared.generateAndSave(blend, accepterUid: myUid)
                let elapsed = Date().timeIntervalSince(startedAt)
                if elapsed < Self.minGeneratingBeat {
                    try? await Task.sleep(nanoseconds: UInt64((Self.minGeneratingBeat - elapsed) * 1_000_000_000))
                }
                await MainActor.run { phase = .story(ready) }
            } catch {
                await MainActor.run {
                    phase = .invite
                    acceptError = "Couldn't build the blend. Check your connection and try again."
                }
            }
        }
    }

    private func declineAndDismiss(_ blend: BookBlend) {
        Task {
            try? await BookBlendService.shared.decline(blend)
            await MainActor.run { dismiss() }
        }
    }

    // MARK: Waiting / gone

    private var waitingScreen: some View {
        VStack(spacing: 16) {
            BlendAvatarLockup(
                leftURL: blend?.participants[myUid]?.photoURL,
                rightURL: blend.flatMap { $0.participants[$0.otherUserId(from: myUid)]?.photoURL },
                leftName: blend?.participants[myUid]?.firstName ?? "?",
                rightName: otherName,
                size: 72
            )
            Text("Blend requested")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.paperFixed)
            Text("We'll ping you the moment \(otherName) accepts. The blend builds itself from there.")
                .font(Theme.callout())
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.paperFixed.opacity(0.7))
                .padding(.horizontal, 44)
        }
    }

    private var goneScreen: some View {
        VStack(spacing: 12) {
            Text("📖")
                .font(.system(size: 44))
            Text("No blend here yet")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.paperFixed)
            Text("Visit a reader's profile and request a Book Blend to get one going.")
                .font(Theme.callout())
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.paperFixed.opacity(0.7))
                .padding(.horizontal, 44)
        }
    }
}

// MARK: - Generating interlude

/// The "shelves merging" moment: avatars orbit into each other while status
/// lines rotate. Runs as long as generation takes.
struct BlendGeneratingView: View {
    let myPhotoURL: String?
    let otherPhotoURL: String?
    let myName: String
    let otherName: String

    @State private var merged = false
    @State private var lineIndex = 0

    private let lines = [
        "Merging shelves…",
        "Comparing ratings…",
        "Weighing tiers…",
        "Consulting the librarian…",
        "Pouring the blend…",
    ]

    var body: some View {
        VStack(spacing: 36) {
            Spacer()
            ZStack {
                Circle()
                    .strokeBorder(Theme.paperFixed.opacity(0.18), lineWidth: 1)
                    .frame(width: 190, height: 190)
                    .scaleEffect(merged ? 1.12 : 0.9)
                    .opacity(merged ? 0.2 : 0.7)
                BlendAvatar(urlString: myPhotoURL, name: myName, size: 84)
                    .offset(x: merged ? -18 : -62)
                BlendAvatar(urlString: otherPhotoURL, name: otherName, size: 84)
                    .offset(x: merged ? 18 : 62)
            }
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: merged)

            VStack(spacing: 10) {
                Text("Blending")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.paperFixed)
                Text(lines[lineIndex])
                    .font(Theme.callout())
                    .foregroundStyle(Theme.paperFixed.opacity(0.7))
                    .contentTransition(.opacity)
                    .id(lineIndex)
                    .transition(.opacity)
            }
            Spacer()
        }
        .onAppear { merged = true }
        .onReceive(Timer.publish(every: 1.8, on: .main, in: .common).autoconnect()) { _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                lineIndex = (lineIndex + 1) % lines.count
            }
        }
    }
}

// MARK: - Shared bits

struct BlendAvatar: View {
    let urlString: String?
    let name: String
    var size: CGFloat = 72
    /// Pre-resolved photo for ImageRenderer exports (the summary card), where
    /// the async avatar loader never gets to run. Nil uses the live loader.
    var image: UIImage? = nil

    var body: some View {
        // Fixed-dark backdrop in both appearances, so the dynamic standard ring
        // is swapped for a fixed-paper one of the same weight.
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                UserAvatarView(urlString: urlString, displayName: name, size: size, ring: false)
            }
        }
        .overlay(Circle().strokeBorder(Theme.paperFixed.opacity(0.85), lineWidth: min(2.5, max(1.5, size * 0.03))))
        .shadow(color: Theme.shadowInk.opacity(0.35), radius: size * 0.11, y: size * 0.04)
    }
}

struct BlendAvatarLockup: View {
    let leftURL: String?
    let rightURL: String?
    let leftName: String
    let rightName: String
    var size: CGFloat = 84
    var leftImage: UIImage? = nil
    var rightImage: UIImage? = nil

    var body: some View {
        HStack(spacing: -size * 0.28) {
            BlendAvatar(urlString: leftURL, name: leftName, size: size, image: leftImage)
            BlendAvatar(urlString: rightURL, name: rightName, size: size, image: rightImage)
        }
    }
}

/// Immersive blend backdrop — SPINE ink base with drifting paper-glow auroras
/// (the inverted mark, in motion). Fixed dark treatment in both appearance
/// modes (Wrapped-style full bleed).
struct BlendAuroraBackground: View {
    var drift: Bool = true
    @State private var animate = false

    var body: some View {
        ZStack {
            Theme.inkFixed

            blob(Theme.paperFixed.opacity(0.16), size: 420)
                .offset(x: animate ? -110 : -30, y: animate ? -220 : -140)
            blob(Theme.paperFixed.opacity(0.10), size: 380)
                .offset(x: animate ? 130 : 60, y: animate ? -40 : 60)
            blob(Theme.paperFixed.opacity(0.07), size: 360)
                .offset(x: animate ? -70 : 40, y: animate ? 260 : 180)
            blob(Theme.paperFixed.opacity(0.12), size: 300)
                .offset(x: animate ? 100 : -60, y: animate ? 120 : 260)
        }
        .ignoresSafeArea()
        // Value-scoped animation, not `withAnimation` in onAppear: a bare
        // repeatForever started during sheet presentation leaks into the sheet's
        // transaction and breaks interactive drag-to-dismiss tracking.
        .animation(.easeInOut(duration: 9).repeatForever(autoreverses: true), value: animate)
        .onAppear {
            guard drift else { return }
            animate = true
        }
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .blur(radius: 90)
    }
}

// MARK: - Launch invite modal

/// Per-invite snooze/dismiss state for the launch invite modal. Keyed by uid +
/// pair id + request time, so a brand-new request (fresh `createdAt`) shows again
/// even after an earlier invite was dismissed with "No thanks".
enum BookBlendInviteModalStorage {
    private static func key(uid: String, blend: BookBlend) -> String {
        "blendInviteModalState_\(uid)_\(blend.id)_\(Int(blend.createdAt.timeIntervalSince1970))"
    }

    /// Stored value: `-1` = never show again; positive = epoch after which it may show again.
    static func isEligible(uid: String, blend: BookBlend, now: Date = Date()) -> Bool {
        let v = UserDefaults.standard.double(forKey: key(uid: uid, blend: blend))
        if v == 0 { return true }
        if v < 0 { return false }
        return now.timeIntervalSince1970 >= v
    }

    static func snoozeTwoDays(uid: String, blend: BookBlend, from now: Date = Date()) {
        UserDefaults.standard.set(
            now.addingTimeInterval(2 * 24 * 60 * 60).timeIntervalSince1970,
            forKey: key(uid: uid, blend: blend)
        )
    }

    static func dismissForever(uid: String, blend: BookBlend) {
        UserDefaults.standard.set(-1.0, forKey: key(uid: uid, blend: blend))
    }
}

/// Launch modal for a pending blend invite — the in-app fallback so an invite is
/// never seen only by push. Blend-branded (aurora ink) with both readers' avatars.
struct BookBlendInviteNudgeModal: View {
    let blend: BookBlend
    let onBlend: () -> Void
    let onRemindLater: () -> Void
    let onNoThanks: () -> Void

    private var requesterName: String {
        blend.participants[blend.requesterId]?.firstName ?? "A friend"
    }

    var body: some View {
        ZStack {
            BlendAuroraBackground()

            VStack(spacing: 0) {
                Spacer()

                BlendAvatarLockup(
                    leftURL: blend.participants[blend.requesterId]?.photoURL,
                    rightURL: blend.participants[blend.recipientId]?.photoURL,
                    leftName: blend.participants[blend.requesterId]?.firstName ?? "?",
                    rightName: blend.participants[blend.recipientId]?.firstName ?? "?",
                    size: 84
                )
                .padding(.bottom, 22)

                Text("BOOK BLEND")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(4)
                    .foregroundStyle(Theme.paperFixed.opacity(0.7))
                    .padding(.bottom, 8)

                Text("\(requesterName) wants to\nBlend with you")
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.paperFixed)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)

                Text("Merge libraries for a taste match score, shared favorites, and books to steal from each other.")
                    .font(Theme.callout())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.paperFixed.opacity(0.75))
                    .padding(.horizontal, 36)

                Spacer()

                VStack(spacing: 10) {
                    Button(action: onBlend) {
                        Label("Let's Blend", systemImage: "shuffle")
                    }
                    .buttonStyle(.spinePrimary)

                    Button(action: onRemindLater) {
                        Text("Remind me in a bit")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.paperFixed.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.springPress)

                    Button(action: onNoThanks) {
                        Text("No thanks")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.paperFixed.opacity(0.55))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.springPress)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
            }
        }
    }
}
