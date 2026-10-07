//
//  CardStampingView.swift
//  SPINE
//
//  Stamping mode for the library card. Front and back are stacked on one
//  screen: pick a stamp from the bank and tap either face where it should
//  land. A press is kept right away and the stamp stays in hand, so tapping
//  again moves it; "Remove stamp" takes it off. The bank here only picks a
//  stamp up (the card page's tiles are where Remove lives otherwise). The front
//  hatches its printed elements and refuses a stamp over them; the whole back
//  is fair game, and a stamp may hang off either edge. Tapping a placed stamp
//  in the bank offers Remove, which hands it back to be pressed again.
//  Copy rule: no em-dashes in user-facing text.
//

import SwiftUI

// MARK: - Store

/// Placement and seen-state writes, applied to `appState.currentUser` first
/// so the card updates under the finger, then persisted. A `-uiPreview` run
/// keeps everything local.
@MainActor
enum AchievementStore {
    private static let userRepo = UserRepository()

    private static var isPreviewRun: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-uiPreview")
        #else
        return false
        #endif
    }

    static func setPlacement(_ placement: StampPlacement?, for kind: AchievementKind, appState: AppState, uid: String?) {
        guard var user = appState.currentUser,
              let index = user.achievements.firstIndex(where: { $0.kind == kind }) else { return }
        let previous = user.achievements[index].placement
        user.achievements[index].placement = placement
        appState.currentUser = user
        guard !isPreviewRun, let uid else { return }
        Task {
            do {
                try await userRepo.setAchievementPlacement(uid: uid, kind: kind, placement: placement)
                // The stamped card lives in Apple Wallet too: send fresh art.
                WalletPassService.scheduleArtRefresh(appState: appState)
            } catch {
                print("⚠️ AchievementStore: placement write failed: \(error.localizedDescription)")
                await MainActor.run {
                    guard var current = appState.currentUser,
                          let i = current.achievements.firstIndex(where: { $0.kind == kind }) else { return }
                    current.achievements[i].placement = previous
                    appState.currentUser = current
                }
            }
        }
    }

    static func markSeen(_ kind: AchievementKind, appState: AppState, uid: String?) {
        guard var user = appState.currentUser,
              let index = user.achievements.firstIndex(where: { $0.kind == kind }),
              user.achievements[index].seenAt == nil else { return }
        user.achievements[index].seenAt = Date()
        appState.currentUser = user
        guard !isPreviewRun, let uid else { return }
        Task {
            do {
                try await userRepo.markAchievementSeen(uid: uid, kind: kind)
            } catch {
                print("⚠️ AchievementStore: seen write failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Loading

extension LibraryCardDetails {
    /// Everything the card prints for `user`, with the photo and card number
    /// resolved (ImageRenderer and the stamping screen cannot wait on either).
    static func load(for user: User) async -> LibraryCardDetails {
        let photo = await LibraryCardExporter.loadPhoto(urlString: user.profileImageURL)
        let number = await UserRepository().memberNumber(joinedAt: user.joinedAt)
        return .from(user: user, cardNumber: max(1, number ?? 1), photo: photo)
    }
}

// MARK: - Stamp flow

/// A stamp's whole trip onto the card in ONE sheet: the celebration (when
/// `celebrate`), then the stamping screen cross-fades in on "Stamp my card".
/// Presenting the stamping screen as its own sheet or cover after the
/// celebration closed stacked two or three transitions in a row. The card
/// loads while the celebration plays, so the swap is instant.
struct AchievementStampFlow: View {
    let kind: AchievementKind
    var celebrate: Bool = true

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authService: AuthService

    @State private var details: LibraryCardDetails?
    @State private var wantsToStamp = false

    var body: some View {
        ZStack {
            if (wantsToStamp || !celebrate), let details {
                CardStampingView(details: details, initialSelection: kind)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if celebrate {
                AchievementUnlockedModal(kind: kind) {
                    withAnimation(.easeInOut(duration: 0.3)) { wantsToStamp = true }
                }
                .transition(.opacity)
            } else {
                Theme.background.ignoresSafeArea()
                    .overlay(ProgressView().tint(Theme.textSecondary))
            }
        }
        .task {
            guard details == nil, let user = appState.currentUser else { return }
            let loaded = await LibraryCardDetails.load(for: user)
            withAnimation(.easeInOut(duration: 0.3)) { details = loaded }
        }
    }
}

// MARK: - Stamping screen

struct CardStampingView: View {
    /// The card's printed fields. Stamps are read live from `appState`.
    let details: LibraryCardDetails
    /// Pre-selected stamp (the one just unlocked, or the one being re-stamped).
    var initialSelection: AchievementKind? = nil

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    /// The stamp in hand: a card tap presses it (or moves it, if it is
    /// already on the card). Stays in hand after a press.
    @State private var selected: AchievementKind?
    /// The stamp just pressed, drawn by the landing animation instead of the
    /// card's own stamp layer until it settles.
    @State private var landing: Landing?
    @State private var zones: [CardZone] = []
    @State private var faceSize: CGSize = .zero
    /// Bumps on a refused tap: the shaded zones wiggle.
    @State private var rejectShake = 0
    /// Scale for the landing animation of the stamp just pressed.
    @State private var landed = false

    private struct Landing: Equatable {
        let id = UUID()
        let kind: AchievementKind
        let placement: StampPlacement
    }

    private var uid: String? { authService.firebaseUser?.uid }

    private var stamps: [AchievementStamp] { appState.currentUser?.achievements ?? details.stamps }

    /// Stamps as the card faces print them: the one mid-landing is left off
    /// so it is not drawn twice.
    private var printedStamps: [AchievementStamp] {
        guard let landing else { return stamps }
        return stamps.map { stamp in
            guard stamp.kind == landing.kind else { return stamp }
            var hidden = stamp
            hidden.placement = nil
            return hidden
        }
    }

    private var liveDetails: LibraryCardDetails {
        var d = details
        d.stamps = printedStamps
        return d
    }

    private var selectedStamp: AchievementStamp? {
        guard let selected else { return nil }
        return stamps.first { $0.kind == selected }
    }

    private var unplaced: [AchievementStamp] { stamps.filter { !$0.isPlaced } }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                // Front over back, both stampable at once. Scrolls only on
                // phones too short to fit both cards above the bank.
                ScrollView {
                    VStack(spacing: 14) {
                        card(.front)
                        card(.back)
                        // Remove takes the hint's slot, so it never covers
                        // the back card.
                        if selectedStamp?.isPlaced == true {
                            removeButton
                        } else {
                            hint
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .sensoryFeedback(.error, trigger: rejectShake)
                }
                .scrollBounceBehavior(.basedOnSize)
                .safeAreaInset(edge: .bottom) {
                    bank
                        .padding(.bottom, 12)
                    .background(Theme.background)
                }
            }
            .navigationTitle("Stamp your card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
        .onAppear {
            if let initialSelection, stamps.contains(where: { $0.kind == initialSelection }) {
                selected = initialSelection
            } else {
                selected = unplaced.first?.kind ?? stamps.first?.kind
            }
        }
    }

    // MARK: Card

    private func card(_ side: StampPlacement.Side) -> some View {
        ZStack(alignment: .topLeading) {
            face(side)
            if side == .front {
                CardProtectedZonesOverlay(zones: zones, ink: Theme.textPrimary)
                    .modifier(ShakeEffect(shakes: rejectShake))
            }
            if let landing, landing.placement.side == side {
                let frame = CardStampGeometry.frame(for: landing.placement, kind: landing.kind, faceSize: faceSize)
                // Clipped like the printed layer so a stamp off the edge
                // previews exactly as it will print.
                ZStack(alignment: .topLeading) {
                    StampImage(kind: landing.kind)
                        .frame(width: frame.width, height: frame.height)
                        .rotationEffect(.degrees(landing.placement.rotation))
                        .scaleEffect(landed ? 1 : 1.9)
                        .opacity(landed ? CardStampGeometry.inkOpacity : 0.3)
                        .position(x: frame.midX, y: frame.midY)
                }
                .frame(width: faceSize.width, height: faceSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { faceSize = $0 }
        .onTapGesture { location in press(at: location, on: side) }
    }

    @ViewBuilder
    private func face(_ side: StampPlacement.Side) -> some View {
        switch side {
        case .front:
            LibraryCardFace(details: liveDetails, onProtectedZonesChange: { zones = $0 })
        case .back:
            // Laid over an invisible front so the back is exactly the front's
            // size and the tap math is the same on both.
            LibraryCardFace(details: details)
                .opacity(0)
                .accessibilityHidden(true)
                .overlay { LibraryCardBackFace(name: details.name, stamps: printedStamps) }
        }
    }

    // MARK: Copy + actions

    private var hint: some View {
        Group {
            if selectedStamp != nil {
                Text("Tap your card to stamp it.")
            } else if stamps.isEmpty {
                Text("No stamps yet. Keep reading and ranking.")
            } else {
                Text("Tap a stamp below to pick it up.")
            }
        }
        .font(Theme.callout())
        .foregroundStyle(Theme.textSecondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 36)
        .frame(minHeight: 36)
    }

    private var removeButton: some View {
        Button {
            removeSelected()
        } label: {
            Label("Remove stamp", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(.spine(.secondary, size: .regular, fullWidth: false))
        .frame(minHeight: 36)
        .transition(.opacity)
    }

    // MARK: Bank

    private var bank: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR STAMPS")
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 24)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(stamps) { stamp in
                        Button {
                            tapBank(stamp)
                        } label: {
                            StampBankTile(stamp: stamp, isSelected: selected == stamp.kind)
                        }
                        .buttonStyle(.springPress)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, 6)
    }

    // MARK: Logic

    private func press(at location: CGPoint, on side: StampPlacement.Side) {
        guard let kind = selected, faceSize.width > 0 else { return }
        let protected = side == .front ? zones.map(\.rect) : []
        guard CardStampGeometry.isValid(center: location, kind: kind, faceSize: faceSize, protectedZones: protected) else {
            withAnimation(.default) { rejectShake += 1 }
            return
        }
        let placement = StampPlacement(
            side: side,
            x: location.x / faceSize.width,
            y: location.y / faceSize.height,
            rotation: Double.random(in: -14...14)
        )
        // Pressed is kept: no confirm step. Pressing a stamp already on the
        // card just moves it.
        AchievementStore.setPlacement(placement, for: kind, appState: appState, uid: uid)
        let thisLanding = Landing(kind: kind, placement: placement)
        landed = false
        landing = thisLanding
        WizardHaptics.step()
        withAnimation(.snappy(duration: 0.32, extraBounce: 0.18)) {
            landed = true
        }
        // Hand the stamp to the card's own layer once it has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if landing == thisLanding { landing = nil }
        }
    }

    /// Takes the stamp in hand off the card. It stays in hand, so the next
    /// card tap presses it somewhere new.
    private func removeSelected() {
        guard let kind = selected, selectedStamp?.isPlaced == true else { return }
        landing = nil
        AchievementStore.setPlacement(nil, for: kind, appState: appState, uid: uid)
        WizardHaptics.selection()
    }

    /// Picks a stamp up. Placed or not, it becomes the one a card tap presses.
    private func tapBank(_ stamp: AchievementStamp) {
        guard selected != stamp.kind else { return }
        landing = nil
        withAnimation(.easeInOut(duration: 0.15)) { selected = stamp.kind }
        WizardHaptics.selection()
    }
}

// MARK: - Remove popover

extension View {
    /// The one action on a placed stamp in the bank: a small "Remove" bubble
    /// pointing at the tile. Tapping outside dismisses it.
    func stampRemovePopover(
        for kind: AchievementKind,
        candidate: Binding<AchievementKind?>,
        onRemove: @escaping () -> Void
    ) -> some View {
        popover(
            isPresented: Binding(
                get: { candidate.wrappedValue == kind },
                set: { if !$0, candidate.wrappedValue == kind { candidate.wrappedValue = nil } }
            ),
            arrowEdge: .bottom
        ) {
            Button(role: .destructive, action: onRemove) {
                Text("Remove")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Shake

/// Horizontal wiggle, driven by an incrementing counter.
struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    init(shakes: Int) {
        animatableData = CGFloat(shakes)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = sin(animatableData * .pi * 4) * 5
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}
