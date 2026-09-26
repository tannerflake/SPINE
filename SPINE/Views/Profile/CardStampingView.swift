//
//  CardStampingView.swift
//  SPINE
//
//  Stamping mode for the library card. Pick a stamp from the bank, tap the
//  card where it should land (front or back), then keep it or undo. The front
//  shades its printed elements and refuses a stamp over them; the whole back
//  is fair game. Placed stamps can be lifted and re-stamped from the bank.
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
                await WalletPassService.scheduleArtRefresh(appState: appState)
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

// MARK: - Stamping screen

struct CardStampingView: View {
    /// The card's printed fields. Stamps are read live from `appState`.
    let details: LibraryCardDetails
    /// Pre-selected stamp (the one just unlocked, or the one being re-stamped).
    var initialSelection: AchievementKind? = nil

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var side: StampPlacement.Side = .front
    @State private var selected: AchievementKind?
    /// Pressed but not yet kept.
    @State private var pending: StampPlacement?
    @State private var zones: [CardZone] = []
    @State private var faceSize: CGSize = .zero
    /// Bumps on a refused tap: the shaded zones wiggle.
    @State private var rejectShake = 0
    @State private var restampCandidate: AchievementStamp?
    /// Scale for the landing animation of the pending stamp.
    @State private var pendingLanded = false

    private var uid: String? { authService.firebaseUser?.uid }

    private var stamps: [AchievementStamp] { appState.currentUser?.achievements ?? details.stamps }

    private var liveDetails: LibraryCardDetails {
        var d = details
        d.stamps = stamps
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
                VStack(spacing: 18) {
                    sidePicker
                    card
                        .padding(.horizontal, 24)
                    hint
                    Spacer(minLength: 0)
                    actions
                    bank
                }
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .navigationTitle("Stamp your card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .confirmationDialog(
                restampCandidate.map { "\($0.kind.title) is on your card." } ?? "",
                isPresented: Binding(
                    get: { restampCandidate != nil },
                    set: { if !$0 { restampCandidate = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let candidate = restampCandidate {
                    Button("Re-stamp") { lift(candidate, thenSelect: true) }
                    Button("Remove from card", role: .destructive) { lift(candidate, thenSelect: false) }
                    Button("Cancel", role: .cancel) { restampCandidate = nil }
                }
            } message: {
                Text("Lift it off to press it somewhere else, or take it off the card.")
            }
        }
        .onAppear {
            if let initialSelection, stamps.contains(where: { $0.kind == initialSelection && !$0.isPlaced }) {
                selected = initialSelection
            } else {
                selected = unplaced.first?.kind
            }
        }
    }

    // MARK: Side picker

    private var sidePicker: some View {
        HStack(spacing: 0) {
            ForEach([StampPlacement.Side.front, .back], id: \.self) { s in
                Button {
                    guard side != s else { return }
                    pending = nil
                    withAnimation(.easeInOut(duration: 0.18)) { side = s }
                } label: {
                    Text(s == .front ? "Front" : "Back")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(side == s ? Theme.textPrimary : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(side == s ? Theme.surfaceElevated : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.surface))
        .frame(width: 200)
        .sensoryFeedback(.selection, trigger: side)
    }

    // MARK: Card

    private var card: some View {
        ZStack(alignment: .topLeading) {
            face
            if side == .front {
                CardProtectedZonesOverlay(zones: zones, ink: Theme.textPrimary)
                    .modifier(ShakeEffect(shakes: rejectShake))
            }
            if let pending, let selected {
                let frame = CardStampGeometry.frame(for: pending, faceSize: faceSize)
                StampImage(kind: selected)
                    .frame(width: frame.width, height: frame.height)
                    .rotationEffect(.degrees(pending.rotation))
                    .scaleEffect(pendingLanded ? 1 : 1.9)
                    .opacity(pendingLanded ? 1 : 0.3)
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { faceSize = $0 }
        .onTapGesture { location in press(at: location) }
        .sensoryFeedback(.error, trigger: rejectShake)
    }

    @ViewBuilder
    private var face: some View {
        // Front and back share one frame so the tap math is the same on both.
        ZStack {
            LibraryCardFace(details: liveDetails, onProtectedZonesChange: { zones = $0 })
                .opacity(side == .front ? 1 : 0)
            if side == .back {
                LibraryCardBackFace(name: details.name, stamps: stamps)
            }
        }
    }

    // MARK: Copy + actions

    private var hint: some View {
        Group {
            if pending != nil {
                Text("Like it there?")
            } else if selectedStamp != nil {
                Text(side == .front
                     ? "Tap the card to stamp it. The shaded parts are off limits."
                     : "Tap anywhere on the back to stamp it.")
            } else if stamps.isEmpty {
                Text("No stamps yet. Keep reading and ranking.")
            } else {
                Text("All your stamps are on the card. Tap one below to move it.")
            }
        }
        .font(Theme.callout())
        .foregroundStyle(Theme.textSecondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 36)
        .frame(minHeight: 36)
    }

    @ViewBuilder
    private var actions: some View {
        if pending != nil {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { pending = nil }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.spineSecondary)

                Button {
                    keep()
                } label: {
                    Label("Stamp it", systemImage: "checkmark")
                }
                .buttonStyle(.spinePrimary)
            }
            .padding(.horizontal, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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
                            StampBankTile(stamp: stamp, isSelected: selected == stamp.kind && !stamp.isPlaced)
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

    private func press(at location: CGPoint) {
        guard let selected, faceSize.width > 0 else { return }
        let protected = side == .front ? zones.map(\.rect) : []
        guard CardStampGeometry.isValid(center: location, faceSize: faceSize, protectedZones: protected) else {
            withAnimation(.default) { rejectShake += 1 }
            return
        }
        let placement = StampPlacement(
            side: side,
            x: location.x / faceSize.width,
            y: location.y / faceSize.height,
            rotation: Double.random(in: -14...14)
        )
        pendingLanded = false
        pending = placement
        WizardHaptics.step()
        withAnimation(.snappy(duration: 0.32, extraBounce: 0.18)) {
            pendingLanded = true
        }
    }

    private func keep() {
        guard let pending, let selected else { return }
        AchievementStore.setPlacement(pending, for: selected, appState: appState, uid: uid)
        WizardHaptics.success()
        withAnimation(.snappy(duration: 0.25)) {
            self.pending = nil
            self.selected = unplaced.first(where: { $0.kind != selected })?.kind
        }
    }

    private func tapBank(_ stamp: AchievementStamp) {
        if stamp.isPlaced {
            restampCandidate = stamp
        } else {
            pending = nil
            withAnimation(.easeInOut(duration: 0.15)) { selected = stamp.kind }
            WizardHaptics.selection()
        }
    }

    /// Takes a placed stamp off the card. `thenSelect` hands it to the reader
    /// to press again; otherwise it just waits in the bank.
    private func lift(_ stamp: AchievementStamp, thenSelect: Bool) {
        restampCandidate = nil
        pending = nil
        if let placementSide = stamp.placement?.side, thenSelect {
            withAnimation(.easeInOut(duration: 0.18)) { side = placementSide }
        }
        AchievementStore.setPlacement(nil, for: stamp.kind, appState: appState, uid: uid)
        withAnimation(.easeInOut(duration: 0.15)) {
            selected = thenSelect ? stamp.kind : unplaced.first?.kind
        }
        WizardHaptics.step()
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
