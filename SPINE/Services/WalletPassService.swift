//
//  WalletPassService.swift
//  SPINE
//
//  The library card in Apple Wallet. The pass's text (name, card number, goal)
//  is native Wallet fields built server-side; what the app owns is the strip
//  image: a band of the card's paper carrying the OG mark and every placed
//  achievement stamp, rendered here with the same assets and fractional
//  placements as the card itself. Adding the card sends that art up with
//  `createWalletPass`; every later stamp press/move/remove re-renders it and
//  calls `updateWalletCardArt`, which pushes the change silently into Wallet
//  (a no-op for members who never added the pass). Copy rule: no em-dashes in
//  user-facing text.
//

import SwiftUI
import PassKit
import FirebaseFunctions

// MARK: - Strip art

/// The Wallet pass strip: 375x123pt of card paper. Stamps keep their pressed
/// horizontal position and tilt; the band is too short for the card's full
/// height, so the vertical fraction just nudges them within the band. Front
/// and back stamps both print here (the pass has one face).
struct WalletStripView: View {
    let stamps: [AchievementStamp]
    let isOGEligible: Bool

    static let size = CGSize(width: 375, height: 123)

    /// Always the printed card's light palette: Wallet passes do not theme.
    private let palette = LibraryCardPalette.fixedLight

    var body: some View {
        ZStack(alignment: .leading) {
            palette.page
            ruledLines
            watermark
            if isOGEligible {
                ogMark
                    .rotationEffect(.degrees(-14))
                    .padding(.leading, 16)
            }
            placedStamps
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    private var ruledLines: some View {
        VStack(spacing: 26) {
            ForEach(0..<3, id: \.self) { _ in
                Rectangle()
                    .fill(palette.ink.opacity(0.14))
                    .frame(height: 1)
            }
        }
        .padding(.horizontal, 18)
    }

    private var watermark: some View {
        Image("SpineLogo")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 150)
            .foregroundStyle(palette.ink.opacity(0.05))
            .rotationEffect(.degrees(-10))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 20)
    }

    /// Same treatment as the card's OG mark.
    private var ogMark: some View {
        Text("OG")
            .font(.system(size: 13, weight: .heavy))
            .tracking(1.8)
            .foregroundStyle(palette.stamp)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(palette.stamp, lineWidth: 1.8)
            )
    }

    private var placedStamps: some View {
        let side: CGFloat = 92
        let width = Self.size.width
        let height = Self.size.height
        return ForEach(stamps.filter(\.isPlaced)) { stamp in
            if let placement = stamp.placement {
                StampImage(kind: stamp.kind)
                    .frame(width: side, height: side)
                    .rotationEffect(.degrees(placement.rotation))
                    .position(
                        x: 8 + side / 2 + placement.x * (width - side - 16),
                        y: side / 2 + 6 + placement.y * (height - side - 12)
                    )
            }
        }
    }
}

// MARK: - Service

@MainActor
enum WalletPassService {
    private static let functions = Functions.functions(region: "us-central1")
    /// Coalesces a stamping session's rapid placements into one refresh.
    private static var refreshTask: Task<Void, Never>?

    enum WalletPassError: LocalizedError {
        case renderFailed
        case badServerResponse

        var errorDescription: String? {
            switch self {
            case .renderFailed: return "Could not draw your card."
            case .badServerResponse: return "The pass could not be created. Try again in a moment."
            }
        }
    }

    /// Builds the signed pass for the signed-in member: renders the strip art
    /// from the card details on screen, sends it with the card number, and
    /// decodes the returned .pkpass.
    static func makePass(details: LibraryCardDetails) async throws -> PKPass {
        var payload = try stripPayload(stamps: details.stamps, isOGEligible: details.isOGEligible)
        payload["cardNumber"] = details.cardNumber
        let result = try await functions.httpsCallable("createWalletPass").call(payload)
        guard let data = result.data as? [String: Any],
              let base64 = data["pass"] as? String,
              let passData = Data(base64Encoded: base64) else {
            throw WalletPassError.badServerResponse
        }
        return try PKPass(data: passData)
    }

    /// Fire-and-forget after a stamp changes: re-render the strip from the
    /// live user and let the server push it to Wallet. Debounced so pressing
    /// three stamps in a row updates the pass once. Members who never added
    /// the pass cost one cheap no-op call.
    static func scheduleArtRefresh(appState: AppState) {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let user = appState.currentUser else { return }
            guard let payload = try? stripPayload(
                stamps: user.achievements,
                isOGEligible: !user.ogIneligible
            ) else { return }
            do {
                _ = try await functions.httpsCallable("updateWalletCardArt").call(payload)
            } catch {
                // Wallet art is a bonus surface: never bother the reader over it.
                print("⚠️ WalletPassService: art refresh failed: \(error.localizedDescription)")
            }
        }
    }

    /// The strip at 1x/2x/3x as base64 PNGs, keyed the way the callable wants.
    private static func stripPayload(stamps: [AchievementStamp], isOGEligible: Bool) throws -> [String: Any] {
        var payload: [String: Any] = [:]
        for scale in [1, 2, 3] {
            let renderer = ImageRenderer(content: WalletStripView(stamps: stamps, isOGEligible: isOGEligible))
            renderer.scale = CGFloat(scale)
            renderer.isOpaque = true
            guard let png = renderer.uiImage?.pngData() else {
                throw WalletPassError.renderFailed
            }
            payload["strip\(scale)x"] = png.base64EncodedString()
        }
        return payload
    }
}

// MARK: - Add button

/// "Add to Apple Wallet" on your own card page. Builds the pass, then hands it
/// to the system add sheet; adding again later just refreshes the pass in place.
struct AddToWalletButton: View {
    let details: LibraryCardDetails

    @State private var isWorking = false
    @State private var pass: PKPass?
    @State private var errorMessage: String?

    var body: some View {
        if PKAddPassesViewController.canAddPasses() {
            WizardSecondaryButton(title: "Wallet", systemImage: "wallet.pass") {
                add()
            }
            .opacity(isWorking ? 0.5 : 1)
            .disabled(isWorking)
            .sheet(item: $pass) { pass in
                AddPassesSheet(pass: pass)
                    .ignoresSafeArea()
            }
            .alert("Could not add your card", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func add() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                pass = try await WalletPassService.makePass(details: details)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension PKPass: @retroactive Identifiable {}

private struct AddPassesSheet: UIViewControllerRepresentable {
    let pass: PKPass

    func makeUIViewController(context: Context) -> PKAddPassesViewController {
        // The initializer only fails for malformed passes; ours was just decoded.
        PKAddPassesViewController(pass: pass) ?? PKAddPassesViewController()
    }

    func updateUIViewController(_ controller: PKAddPassesViewController, context: Context) {}
}
