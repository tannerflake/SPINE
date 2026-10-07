//
//  WalletPassService.swift
//  SPINE
//
//  The library card in Apple Wallet. "SPINE" and the card number are native
//  Wallet fields built server-side; what the app owns is the strip image: a
//  band of the card's paper carrying the identity row (photo, OG mark, name,
//  handle) and every placed achievement stamp, rendered here with the same
//  assets and ink as the card itself. Adding the card sends that art up with
//  `createWalletPass`; every later stamp press/move/remove re-renders it and
//  calls `updateWalletCardArt`, which pushes the change silently into Wallet
//  (a no-op for members who never added the pass). Copy rule: no em-dashes in
//  user-facing text.
//

import SwiftUI
import PassKit
import FirebaseAuth
import FirebaseFunctions

// MARK: - Strip art

/// The Wallet pass strip: 375x144pt, the body of the card. Wallet fixes that
/// slot (a taller image is center-cropped to it, and the native logo row
/// above never collapses, even when empty), so this is every point of card
/// the pass can show. The identity row (photo with the OG mark, name, handle)
/// sits above the thin rule; under it, on the card's open paper, every placed
/// achievement stamp lined up small from the left (at most `maxStamps`), over
/// the reader-glyph watermark, all drawn with the same assets and ink as
/// `LibraryCardFace`. A soft bottom edge closes the card, its corners curving
/// up into the pass sides. Wallet prints the SPINE wordmark and the card
/// number above as the native logo row, and the pass itself is always the
/// full sheet: Wallet fixes that height for every third-party pass style
/// (only Apple Pay cards and IDs get the card-sized layout).
///
/// Art with another aspect gets scaled to fill the slot's height and cropped
/// at the sides: the old 375x123 band lost about 30pt per side, which cut
/// the OG mark off. Wallet may still shave a sliver on wider phones, so
/// everything printed here stays inside `safeInset`.
struct WalletStripView: View {
    let details: LibraryCardDetails

    static let size = CGSize(width: 375, height: 144)
    static let safeInset: CGFloat = 28
    /// Where the photo starts. The tilted OG mark reaches about 12pt left
    /// of it, which puts the mark's edge at 24pt: about 6pt clear of the
    /// side Wallet crops on the narrowest phones (375pt wide, ~18pt a side).
    static let contentLeading: CGFloat = 36
    /// Inset of both rules; the stamp row starts on the same left edge.
    static let ruleInset: CGFloat = 18
    /// Radius of the card's bottom corners.
    static let cornerRadius: CGFloat = 20
    /// Gap between stamps in the row.
    static let stampSpacing: CGFloat = 8
    /// The identity row's band under the header rule; the row centers in it.
    static let identityHeight: CGFloat = 92
    /// Open paper between the identity band and the thin rule, which puts
    /// the rule low on the card the way the face's sits.
    static let ruleDrop: CGFloat = 20
    /// How many stamps the row prints before it stops, in badge order.
    static let maxStamps = 6

    /// Always the printed card's light palette: Wallet passes do not theme.
    private let palette = LibraryCardPalette.fixedLight

    var body: some View {
        ZStack(alignment: .topLeading) {
            palette.page
            watermark
            VStack(spacing: 0) {
                Rectangle()
                    .fill(palette.ink)
                    .frame(height: 2)
                    .padding(.horizontal, Self.ruleInset)
                identityRow
                    .frame(height: Self.identityHeight)
                Rectangle()
                    .fill(palette.ink.opacity(0.18))
                    .frame(height: 1)
                    .padding(.horizontal, Self.ruleInset)
                    .padding(.top, Self.ruleDrop)
                stampsRow
                    .frame(maxHeight: .infinity)
            }
            cardEdge
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    /// The card's bottom edge: just the bottom line and the two corners
    /// curving up into the pass sides, in the same soft ink as the card's
    /// rules so it closes the card without a hard black frame.
    private var cardEdge: some View {
        CardBottomEdge(cornerRadius: Self.cornerRadius)
            .stroke(palette.ink.opacity(0.28), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .padding(1)
    }

    /// The reader glyph on the card's right, same ink as the face, kept
    /// inside the identity band so the thin rule runs under it, not through.
    private var watermark: some View {
        Image("SpineLogo")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 118)
            .foregroundStyle(palette.ink.opacity(0.05))
            .rotationEffect(.degrees(-10))
            .offset(x: 12, y: 0)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, Self.safeInset)
            .padding(.top, 6)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private var identityRow: some View {
        HStack(spacing: 16) {
            photoCircle
                .rotationEffect(.degrees(-2))
                .overlay(alignment: .topLeading) {
                    if details.isOGEligible {
                        ogMark
                            .rotationEffect(.degrees(-14))
                            .offset(x: -12, y: -9)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(details.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .rotationEffect(.degrees(1.2))
                Text("@\(details.handle)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .rotationEffect(.degrees(-1.4))
            }
            .frame(maxWidth: Self.size.width - Self.contentLeading - Self.safeInset - 52 - 16, alignment: .leading)
        }
        .padding(.leading, Self.contentLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Same treatment as the card's OG mark.
    private var ogMark: some View {
        Text("OG")
            .font(.system(size: 12, weight: .heavy))
            .tracking(1.8)
            .foregroundStyle(palette.stamp)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(palette.stamp, lineWidth: 1.8)
            )
    }

    private var photoCircle: some View {
        Group {
            if let photo = details.photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(palette.ink)
                    Text(details.monogramInitial)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(palette.page)
                }
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
        .overlay(Circle().stroke(palette.ink, lineWidth: 2))
    }

    /// Every placed stamp lined up small from the left in badge order (25,
    /// then 50, ...), each with its own small set tilt, at most `maxStamps`.
    /// Prints nothing until the first stamp is pressed, leaving the open
    /// paper as on the face. The card in the app keeps the reader's own
    /// placement; the pass does not mirror it. Front and back both print
    /// here (the pass has one face). Same translucent ink as the card.
    @ViewBuilder
    private var stampsRow: some View {
        let stamps = Array(
            details.stamps
                .filter(\.isPlaced)
                .sorted { $0.kind.rowOrder < $1.kind.rowOrder }
                .prefix(Self.maxStamps)
        )
        if !stamps.isEmpty {
            let baseSide: CGFloat = 20
            let available = Self.size.width - Self.ruleInset - Self.safeInset
            // Shrink the row uniformly rather than spill past the safe edge
            // once there are more stamps than the paper holds at full size.
            let fullWidth = stamps.reduce(CGFloat(0)) { $0 + baseSide * $1.kind.frameScale }
                + Self.stampSpacing * CGFloat(max(stamps.count - 1, 0))
            let shrink = fullWidth > available ? available / fullWidth : 1
            HStack(alignment: .center, spacing: Self.stampSpacing * shrink) {
                ForEach(Array(stamps.enumerated()), id: \.element.id) { index, stamp in
                    let side = (baseSide * stamp.kind.frameScale * shrink).rounded()
                    StampImage(kind: stamp.kind)
                        .frame(width: side, height: side)
                        .rotationEffect(.degrees(Self.rowTilt(at: index)))
                        .opacity(CardStampGeometry.inkOpacity)
                }
            }
            .padding(.leading, Self.ruleInset)
            .padding(.trailing, Self.safeInset)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// A pressed-by-hand look without the reader's own angles: alternating
    /// small tilts that never change between renders.
    private static func rowTilt(at index: Int) -> Double {
        let tilts: [Double] = [-7, 6, -4, 5]
        return tilts[index % tilts.count]
    }
}

private extension AchievementKind {
    /// Position in the pass's stamp row: declaration order, so new badges
    /// appended to the enum print after the ones that came before.
    var rowOrder: Int {
        AchievementKind.allCases.firstIndex(of: self) ?? .max
    }
}

/// The card's bottom edge as an open path: from the pass's left side it
/// curves down through the bottom-left corner, runs along the bottom, and
/// curves back up through the bottom-right corner to the right side. No
/// vertical runs: the pass's own sides stand in for the card's.
private struct CardBottomEdge: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(cornerRadius, rect.width / 2, rect.height)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true
        )
        return path
    }
}

// MARK: - Service

@MainActor
enum WalletPassService {
    private static let functions = Functions.functions(region: "us-central1")
    /// Coalesces a stamping session's rapid placements into one refresh.
    private static var refreshTask: Task<Void, Never>?

    /// Must match PASS_TYPE_ID in functions/src/wallet.ts and the entitlement
    /// in SPINE.entitlements.
    static let passTypeIdentifier = "pass.com.wellread.app.librarycard"

    /// Whether the signed-in member's card is already in Wallet on this device
    /// (the pass's serial number is the uid). Reading the pass library needs
    /// the pass-type-identifiers entitlement, which the app target carries.
    static func isCardInWallet() -> Bool {
        guard PKPassLibrary.isPassLibraryAvailable(),
              let uid = Auth.auth().currentUser?.uid else { return false }
        return PKPassLibrary().pass(withPassTypeIdentifier: passTypeIdentifier, serialNumber: uid) != nil
    }

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
        var payload = try stripPayload(details: details)
        payload["cardNumber"] = details.cardNumber
        let result = try await functions.httpsCallable("createWalletPass").call(payload)
        guard let data = result.data as? [String: Any],
              let base64 = data["pass"] as? String,
              let passData = Data(base64Encoded: base64) else {
            throw WalletPassError.badServerResponse
        }
        return try PKPass(data: passData)
    }

    /// Bump whenever `WalletStripView`'s layout changes, so passes already
    /// in Wallet get re-rendered art on the next launch instead of keeping
    /// whatever the build that added them drew (v1 was the 375x123 band
    /// Wallet cropped the OG mark out of).
    private static let stripArtVersion = 4

    /// What the strip prints, as a string: when it differs from what was last
    /// uploaded from this device, the pass in Wallet is out of date.
    private static func artSignature(for user: User) -> String {
        let stamps = user.achievements
            .filter(\.isPlaced)
            .map(\.kind.rawValue)
            .sorted()
            .joined(separator: ",")
        return [
            "v\(stripArtVersion)",
            user.firstName ?? "",
            user.lastName ?? "",
            user.displayName,
            user.username,
            user.profileImageURL ?? "",
            user.ogIneligible ? "-" : "og",
            stamps
        ].joined(separator: "|")
    }

    private static func uploadedSignatureKey(uid: String) -> String {
        "walletStripArtSignature.\(uid)"
    }

    /// On launch: if the card is in Wallet on this device and the strip it
    /// carries was drawn by an older layout (or before a name, photo or stamp
    /// change this device has not uploaded), re-render and push it. Stamp
    /// presses refresh on their own; this catches everything else.
    static func refreshArtIfStale(appState: AppState) {
        guard let user = appState.currentUser,
              let uid = Auth.auth().currentUser?.uid,
              isCardInWallet() else { return }
        let stored = UserDefaults.standard.string(forKey: uploadedSignatureKey(uid: uid))
        guard stored != artSignature(for: user) else { return }
        scheduleArtRefresh(appState: appState)
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
            // The strip prints the photo too, so resolve it first (ImageRenderer
            // cannot wait on the async loader).
            let photo = await LibraryCardExporter.loadPhoto(urlString: user.profileImageURL)
            guard !Task.isCancelled else { return }
            // The card number is a native Wallet field, not part of the art.
            let details = LibraryCardDetails.from(user: user, cardNumber: 0, photo: photo)
            guard let payload = try? stripPayload(details: details) else { return }
            do {
                _ = try await functions.httpsCallable("updateWalletCardArt").call(payload)
                if let uid = Auth.auth().currentUser?.uid {
                    UserDefaults.standard.set(artSignature(for: user), forKey: uploadedSignatureKey(uid: uid))
                }
            } catch {
                // Wallet art is a bonus surface: never bother the reader over it.
                print("⚠️ WalletPassService: art refresh failed: \(error.localizedDescription)")
            }
        }
    }

    /// The strip at 1x/2x/3x as base64 PNGs, keyed the way the callable wants.
    private static func stripPayload(details: LibraryCardDetails) throws -> [String: Any] {
        var payload: [String: Any] = [:]
        for scale in [1, 2, 3] {
            let renderer = ImageRenderer(content: WalletStripView(details: details))
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

/// "Add to Apple Wallet", on your own card page and under the wizard's dealt
/// card. Shown only while the card is NOT in Wallet on this device: once it is,
/// stamps flow to it on their own and the button has nothing left to offer. It
/// comes back if the pass is deleted from Wallet.
struct AddToWalletButton: View {
    let details: LibraryCardDetails
    var title: String = "Wallet"

    @Environment(\.scenePhase) private var scenePhase
    @State private var isWorking = false
    @State private var pass: PKPass?
    @State private var errorMessage: String?
    @State private var isInWallet = WalletPassService.isCardInWallet()

    var body: some View {
        if PKAddPassesViewController.canAddPasses() && !isInWallet {
            WizardSecondaryButton(title: title, systemImage: "wallet.pass") {
                add()
            }
            .opacity(isWorking ? 0.5 : 1)
            .disabled(isWorking)
            .sheet(item: $pass, onDismiss: { isInWallet = WalletPassService.isCardInWallet() }) { pass in
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
            .onAppear { isInWallet = WalletPassService.isCardInWallet() }
            // Catches a pass deleted (or added via another path) while away.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { isInWallet = WalletPassService.isCardInWallet() }
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

// MARK: - Debug preview

#if DEBUG
/// `-uiPreviewWalletStrip`: the strip art at 1:1 over the card face it
/// mirrors, so the two can be compared without adding a pass.
struct WalletStripPreview: View {
    private var details: LibraryCardDetails {
        var user = User.demo
        user.lastName = "Flake"
        user.displayName = "Tanner Flake"
        user.achievements = [
            AchievementStamp(
                kind: .ranked50,
                unlockedAt: Date(),
                seenAt: Date(),
                placement: StampPlacement(side: .back, x: 0.3, y: 0.7, rotation: 12)
            ),
            AchievementStamp(
                kind: .ranked25,
                unlockedAt: Date(),
                seenAt: Date(),
                placement: StampPlacement(side: .front, x: 0.62, y: 0.55, rotation: -9)
            )
        ]
        return LibraryCardDetails.from(user: user, cardNumber: 1, photo: nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                WalletStripView(details: details)
                    .overlay(Rectangle().stroke(Color.red.opacity(0.4), lineWidth: 0.5))
                WalletStripView(details: details)
                    // The slot on a 375pt-wide phone, the narrowest crop.
                    .frame(width: 338, height: WalletStripView.size.height)
                    .clipped()
                    .overlay(Rectangle().stroke(Color.red.opacity(0.4), lineWidth: 0.5))
                LibraryCardFace(details: details, palette: .fixedLight)
                    .frame(width: 306)
            }
            .padding(.top, 80)
        }
        .background(Color(white: 0.85))
        .ignoresSafeArea()
    }
}
#endif
