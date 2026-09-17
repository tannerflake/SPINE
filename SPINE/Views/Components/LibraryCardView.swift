//
//  LibraryCardView.swift
//  SPINE
//
//  The SPINE library card as a reusable, static face (no stamp choreography):
//  used by the profile card page (yours and other members') and by the
//  downloadable image both there and at the end of the onboarding wizard. The
//  wizard's own card (WizardCardStep) keeps its animated copy of this layout
//  because it stamps each field on individually. Copy rule: no em-dashes in
//  user-facing text.
//

import SwiftUI
import Photos
import PhotosUI
import UIKit

// MARK: - Details

/// Everything the card prints. Built from the wizard model or from a User doc.
struct LibraryCardDetails: Equatable {
    var name: String
    var handle: String
    var cardNumber: Int
    var memberSinceText: String
    var goalText: String
    /// Resolved avatar. Nil falls back to the ink monogram.
    var photo: UIImage?
    var monogramInitial: String
    /// Whether this member's OG stamp should show. Decided once at account
    /// creation and stored on the user doc (`User.ogIneligible`), NOT recomputed
    /// from `cardNumber` here — a live comparison would strip the stamp from
    /// members who already had it once real growth pushes past the cutoff.
    var isOGEligible: Bool

    static func from(user: User, cardNumber: Int, photo: UIImage?) -> LibraryCardDetails {
        let first = user.firstName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let last = user.lastName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let joined = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        let name = joined.isEmpty ? user.displayName : joined
        return LibraryCardDetails(
            name: name,
            handle: user.username,
            cardNumber: cardNumber,
            memberSinceText: Self.memberSince(user.joinedAt),
            goalText: Self.goalText(user.readingGoal),
            photo: photo,
            monogramInitial: String((name.isEmpty ? "R" : name).prefix(1)),
            isOGEligible: !user.ogIneligible
        )
    }

    /// OG stamp cutoff: new accounts only get the badge if fewer than this many
    /// real members (see `UserRepository.memberNumber`) existed at signup. Read
    /// once at creation into `User.ogIneligible`, not re-checked on every card
    /// view. Shared with `UserRepository.ensureUserDocument` and `WizardCardStep`.
    static let ogCutoff = 250

    static func memberSince(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date).uppercased()
    }

    /// Same wording as the wizard's card stamp.
    static func goalText(_ goal: Int?) -> String {
        let year = Calendar.current.component(.year, from: Date())
        guard let goal, goal > 0 else { return "\(year): READING FREELY" }
        return "\(year) GOAL: \(goal) BOOKS"
    }
}

// MARK: - Palette

/// The card's tones. `.adaptive` follows the app appearance (for on-screen use);
/// `.fixedLight` is the printed card, used for the exported image so a download
/// taken in dark mode is still a cream card on white paper.
struct LibraryCardPalette {
    let page: Color
    let ink: Color
    let secondary: Color
    let tertiary: Color
    let stamp: Color

    static let adaptive = LibraryCardPalette(
        page: Theme.surfaceElevated,
        ink: Theme.textPrimary,
        secondary: Theme.textSecondary,
        tertiary: Theme.textTertiary,
        stamp: Theme.danger
    )

    static let fixedLight = LibraryCardPalette(
        page: Color(red: 246/255, green: 247/255, blue: 238/255),
        ink: Theme.inkFixed,
        secondary: Color(red: 69/255, green: 66/255, blue: 75/255),
        tertiary: Color(red: 129/255, green: 126/255, blue: 134/255),
        stamp: Color(red: 176/255, green: 53/255, blue: 44/255)
    )
}

// MARK: - Card face

struct LibraryCardFace: View {
    let details: LibraryCardDetails
    var palette: LibraryCardPalette = .adaptive
    /// Set by on-screen callers to blow the photo up on a long press (see
    /// `AvatarZoomOverlay`). Left nil for the exported image, which is rendered
    /// by ImageRenderer and has nothing to gesture on.
    var onPhotoLongPress: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Rectangle()
                .fill(palette.ink)
                .frame(height: 2)
            identityRow
            goalStamp
                .rotationEffect(.degrees(-1.8))
            Rectangle()
                .fill(palette.ink.opacity(0.18))
                .frame(height: 1)
            footer
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(palette.page)
                .overlay(watermark)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(palette.ink, lineWidth: 2)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Library card number \(details.cardNumber). \(details.name), at \(details.handle). Member since \(details.memberSinceText)."
        )
    }

    private var watermark: some View {
        Image("SpineLogo")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 220)
            .foregroundStyle(palette.ink.opacity(0.05))
            .rotationEffect(.degrees(-10))
            .offset(x: 60, y: 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("SPINE")
                .font(.system(size: 15, weight: .heavy))
                .tracking(4)
                .foregroundStyle(palette.ink)
            Spacer()
            Text("CARD № \(details.cardNumber)")
                .font(.system(size: 10.5, weight: .bold))
                .monospacedDigit()
                .tracking(1.4)
                .foregroundStyle(palette.tertiary)
        }
    }

    private var identityRow: some View {
        HStack(spacing: 16) {
            photoCircle
                .rotationEffect(.degrees(-2))
                .overlay(alignment: .topLeading) {
                    if details.isOGEligible {
                        ogStamp
                            .rotationEffect(.degrees(-14))
                            .offset(x: -12, y: -9)
                    }
                }
                .zIndex(1)
            // Long names have to shrink rather than push the card wider: in a
            // fixed-width frame the overflow clips the card's own border.
            VStack(alignment: .leading, spacing: 3) {
                Text(details.name)
                    .font(.system(size: 21, weight: .bold))
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
            Spacer(minLength: 0)
        }
    }

    /// Red is reserved for danger everywhere else in the app; here it is ink
    /// from a real rubber stamp, which is the one place it belongs.
    private var ogStamp: some View {
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
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(palette.page)
                }
            }
        }
        .frame(width: 66, height: 66)
        .clipShape(Circle())
        .overlay(Circle().stroke(palette.ink, lineWidth: 2))
        // The card face is one accessibility element, so the hold is discovered
        // by touch, same as holding the avatar on a profile page.
        .contentShape(Circle())
        .onLongPressGesture(minimumDuration: 0.35) { onPhotoLongPress?() }
    }

    private var goalStamp: some View {
        Text(details.goalText)
            .font(.system(size: 12, weight: .heavy))
            .tracking(1.4)
            .foregroundStyle(palette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(palette.ink, lineWidth: 1.5)
            )
    }

    private var footer: some View {
        HStack {
            Text("MEMBER SINCE \(details.memberSinceText)")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(palette.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
        }
        .frame(minHeight: 16)
    }
}

// MARK: - Exported image

/// What actually gets saved to Photos: a full 9:16 story canvas (360x640
/// points, rendered at 3x for exactly 1080x1920 pixels, Instagram's story
/// size) so posting it needs no cropping. The card sits centered on either
/// the reader's chosen photo or nothing at all (a transparent canvas, so the
/// saved PNG drops onto any story background), with the App Store line under
/// it so a shared story tells people where to get SPINE.
struct LibraryCardStoryCanvas: View {
    let details: LibraryCardDetails
    /// Photo behind the card. Nil leaves the canvas transparent.
    var background: UIImage?

    /// Canvas in points. Rendered at 3x this is 1080x1920 pixels.
    static let size = CGSize(width: 360, height: 640)

    var body: some View {
        ZStack {
            // No corner glyph here: the card face already carries the brand.
            backgroundLayer

            // Dead center of the story frame.
            LibraryCardFace(details: details, palette: .fixedLight)
                .frame(width: 306)
                .shadow(
                    color: Color.black.opacity(background == nil ? 0.16 : 0.38),
                    radius: 16, y: 10
                )
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if let background {
            Image(uiImage: background)
                .resizable()
                .scaledToFill()
                .frame(width: Self.size.width, height: Self.size.height)
                .clipped()
                // Thin scrim so the card and caption read on any photo.
                .overlay(Color.black.opacity(0.15))
        } else {
            // Transparent on purpose: the share sheet previews this over a
            // checkerboard and exports it as a PNG with alpha.
            Color.clear
        }
    }
}

enum LibraryCardExporter {

    /// The card canvas as an image (1080x1920). Kept for callers that only
    /// want the picture; the share sheet renders through `StoryExporter`.
    @MainActor
    static func renderImage(details: LibraryCardDetails, background: UIImage? = nil) -> UIImage? {
        StoryExporter.render(LibraryCardStoryCanvas(details: details, background: background))
    }

    /// Resolves the avatar to a UIImage up front: ImageRenderer cannot wait on
    /// an async loader, so an unresolved photo would export as the monogram.
    static func loadPhoto(urlString: String?) async -> UIImage? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        if let cached = ProfileImageCache.shared.memoryImage(for: url) { return cached }
        return await ProfileImageCache.shared.image(for: url)
    }
}

// MARK: - Download button

/// Shared "share the card" control: opens the share sheet on the library card
/// page, where the reader can put a photo behind it, then post to Instagram
/// or save. The wizard step and the card page behave identically; from there
/// the other graphics are a swipe away.
struct LibraryCardDownloadButton: View {
    let details: LibraryCardDetails
    /// Ghost styling for the wizard (where Next is the primary action).
    var prominent: Bool = true
    /// The wizard says "Save my card" (the card is new and the reader has not
    /// kept it anywhere yet); the profile sheet, where the card already lives,
    /// just says "Share".
    var title: String = "Share"
    /// Breathing pulse until tapped, for the wizard, where the reader has not
    /// yet seen that the share sheet exists.
    var pulses: Bool = false

    @EnvironmentObject private var appState: AppState
    @State private var showShareHub = false
    @State private var pulse = false
    @State private var wasOpened = false

    private var isPulsing: Bool { pulses && !wasOpened && pulse }

    var body: some View {
        Group {
            if prominent {
                WizardCTAButton(title: title, systemImage: "square.and.arrow.up") {
                    open()
                }
            } else {
                WizardSecondaryButton(title: title, systemImage: "square.and.arrow.up") {
                    open()
                }
            }
        }
        // Body-scoped so only the scale breathes, never the button's layout
        // position; `withAnimation(.repeatForever)` in onAppear would leak into
        // an enclosing sheet's transaction and break its drag-to-dismiss.
        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { content in
            content
                .scaleEffect(isPulsing ? 1.03 : 1)
                .shadow(color: Theme.shadowInk.opacity(isPulsing ? 0.2 : 0), radius: 12, y: 5)
        }
        .onAppear { if pulses { pulse = true } }
        .sheet(isPresented: $showShareHub) {
            ShareHubSheet(details: details, userBooks: appState.userBooks, initialPage: .card)
                .environmentObject(appState)
        }
    }

    private func open() {
        wasOpened = true
        showShareHub = true
    }
}
