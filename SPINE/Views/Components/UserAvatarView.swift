//
//  UserAvatarView.swift
//  SPINE
//
//  The one standardized user avatar. Shows the profile photo when the user has
//  one; otherwise a two-letter monogram (first + last initial) on a deterministic
//  cover-palette color, so the same person keeps the same color on every surface.
//

import SwiftUI

enum AvatarMonogram {
    /// First + last initials, uppercased. The display name leads — the monogram
    /// must agree with the label rendered next to it, and displayName is the one
    /// field every surface has. Explicit first/last names only fill gaps.
    static func initials(displayName: String?, firstName: String? = nil, lastName: String? = nil) -> String {
        let words = splitWords(displayName)
        let f = trimmed(firstName)
        let l = trimmed(lastName)
        if words.count >= 2, let first = words.first?.first, let last = words.last?.first {
            return String(first).uppercased() + String(last).uppercased()
        }
        if let word = words.first, let first = word.first {
            // Single-word display name: add the real last initial only when the
            // word IS the first name — otherwise the monogram would contradict
            // the label (e.g. displayName "June" with an unrelated firstName).
            if let last = l.first, f.isEmpty || f.caseInsensitiveCompare(word) == .orderedSame {
                return String(first).uppercased() + String(last).uppercased()
            }
            return String(first).uppercased()
        }
        // No display name at all (wizard, pre-onboarding): explicit fields.
        if let first = f.first, let last = l.first {
            return String(first).uppercased() + String(last).uppercased()
        }
        if let only = (f.isEmpty ? l : f).first { return String(only).uppercased() }
        return "?"
    }

    /// Color seed — the normalized display name. Denormalized surfaces (comments,
    /// blend participants) only carry a display name, so seeding by it is what
    /// keeps one user the same color everywhere; first/last are the fallback for
    /// pre-onboarding surfaces where displayName ("First Last") doesn't exist yet.
    /// (`User.id` is a fresh UUID per Firestore decode and must never seed color.)
    static func seed(displayName: String?, firstName: String? = nil, lastName: String? = nil) -> String {
        let words = splitWords(displayName)
        if !words.isEmpty { return words.joined(separator: " ").lowercased() }
        return [trimmed(firstName), trimmed(lastName)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    private static func splitWords(_ name: String?) -> [String] {
        (name ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func trimmed(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Metrics of the standard avatar ring, shared with the few views that draw a
/// matching edge on a non-avatar circle (the "+N" tail of a member stack).
enum AvatarRing {
    /// Thicker on the big circles (people strip, profile headers), a hair
    /// thinner on inline ones so a 20pt comment avatar isn't half ring.
    static func lineWidth(for size: CGFloat) -> CGFloat { size < 32 ? 1.5 : 2 }
    static let shadowOpacity: Double = 0.18
    static func shadowRadius(for size: CGFloat) -> CGFloat { max(2, min(5, size * 0.06)) }
}

/// Monogram fallback: palette-colored circle with white two-letter initials.
struct InitialsAvatarView: View {
    let displayName: String?
    var firstName: String? = nil
    var lastName: String? = nil
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Theme.coverPaletteColor(
                for: AvatarMonogram.seed(displayName: displayName, firstName: firstName, lastName: lastName)
            ))
            .overlay(
                Text(AvatarMonogram.initials(displayName: displayName, firstName: firstName, lastName: lastName))
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(Theme.phosphorWhite)
                    .minimumScaleFactor(0.7)
            )
            .frame(width: size, height: size)
    }
}

/// Photo-or-monogram avatar, circle-clipped at `size`, wearing the app's one
/// standard ring: a paper-white edge (`Theme.avatarRing`) plus a soft drop
/// shadow, the Instagram treatment. Every surface gets the same ring from here
/// so profile circles look identical across the feed, comments, profiles, and
/// clubs — call sites must not stack their own strokes on top. The only
/// opt-outs (`ring: false`) are surfaces on a fixed dark backdrop that draw a
/// fixed-paper edge themselves (blend lockup, the full-screen zoom).
struct UserAvatarView: View {
    let urlString: String?
    let displayName: String?
    var firstName: String? = nil
    var lastName: String? = nil
    let size: CGFloat
    var ring: Bool = true

    var body: some View {
        CachedProfileImage(url: url, contentMode: .fill) {
            InitialsAvatarView(displayName: displayName, firstName: firstName, lastName: lastName, size: size)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            if ring {
                Circle().strokeBorder(Theme.avatarRing, lineWidth: AvatarRing.lineWidth(for: size))
            }
        }
        .shadow(
            color: ring ? Theme.shadowInk.opacity(AvatarRing.shadowOpacity) : .clear,
            radius: ring ? AvatarRing.shadowRadius(for: size) : 0,
            y: ring ? 1 : 0
        )
    }

    private var url: URL? {
        guard let urlString, !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }
}

// MARK: - Full-screen avatar zoom

/// Long-press a member's avatar anywhere in the app to blow their profile photo
/// up over a dimmed screen. Presented as a clear-background full-screen cover so
/// it also covers the nav bar; the cover's own transition is suppressed and the
/// zoom/dim are animated by hand, so the photo springs out of nothing instead of
/// sliding up from the bottom.
struct AvatarZoomOverlay: View {
    let urlString: String?
    let displayName: String?
    var firstName: String? = nil
    var lastName: String? = nil
    /// Name printed under the photo. Nil hides the caption.
    var caption: String? = nil
    let onDismiss: () -> Void

    /// Drives both the entrance spring and the exit, so dismissing reverses the
    /// same animation the press played.
    @State private var presented = false
    /// Live drag offset: flicking the photo in any direction dismisses it.
    @State private var dragOffset: CGSize = .zero

    /// 0...1 by drag distance: fades the dim and shrinks the photo as it's flicked away.
    private var dragProgress: Double {
        let distance = sqrt(dragOffset.width * dragOffset.width + dragOffset.height * dragOffset.height)
        return Double(min(distance / 220, 1))
    }

    var body: some View {
        GeometryReader { geo in
            let side = max(0, min(geo.size.width - 48, geo.size.height * 0.62))
            ZStack {
                Theme.shadowInk
                    .opacity(presented ? 0.9 * (1 - dragProgress * 0.7) : 0)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }

                VStack(spacing: 18) {
                    UserAvatarView(
                        urlString: urlString,
                        displayName: displayName,
                        firstName: firstName,
                        lastName: lastName,
                        size: side,
                        ring: false
                    )
                    // Fixed-dark backdrop in both appearances, so the dynamic
                    // standard ring is swapped for a fixed-paper one of the same
                    // weight (matching the blend lockup). A fainter edge here
                    // makes the zoomed circle the odd one out against every
                    // other avatar in the app.
                    .overlay(Circle().strokeBorder(Theme.paperFixed.opacity(0.85), lineWidth: 2.5))
                    .shadow(color: Theme.shadowInk.opacity(0.5), radius: 30, y: 12)

                    if let caption, !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.phosphorWhite)
                            .opacity(presented ? 1 - dragProgress : 0)
                    }
                }
                .scaleEffect(presented ? 1 - dragProgress * 0.12 : 0.55)
                .opacity(presented ? 1 : 0)
                .offset(dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { dragOffset = $0.translation }
                        .onEnded { value in
                            let distance = sqrt(
                                value.translation.width * value.translation.width
                                    + value.translation.height * value.translation.height
                            )
                            if distance > 90 {
                                dismiss()
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    dragOffset = .zero
                                }
                            }
                        }
                )
                .onTapGesture { dismiss() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { presented = true }
        }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.18)) {
            presented = false
        }
        // Let the shrink play before the cover goes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onDismiss() }
    }
}

enum AvatarZoomPresentation {
    /// Flip the zoom flag without the full-screen cover's own slide-up: the
    /// overlay animates its own spring, and a cover transition on top of that
    /// reads as two different animations fighting.
    static func present(_ binding: Binding<Bool>) {
        var t = Transaction(animation: nil)
        t.disablesAnimations = true
        withTransaction(t) { binding.wrappedValue = true }
    }

    /// Same, for surfaces that carry which member to show (a strip of avatars)
    /// rather than a single fixed one.
    static func present<Value>(_ binding: Binding<Value?>, _ value: Value) {
        var t = Transaction(animation: nil)
        t.disablesAnimations = true
        withTransaction(t) { binding.wrappedValue = value }
    }
}

extension View {
    /// Attach beside any avatar: pair with a long press that calls
    /// `AvatarZoomPresentation.present($flag)`. Attach it to a leaf view
    /// (not the same view as another `fullScreenCover`) so the two don't collide.
    func avatarZoom(
        isPresented: Binding<Bool>,
        urlString: String?,
        displayName: String?,
        firstName: String? = nil,
        lastName: String? = nil,
        caption: String? = nil
    ) -> some View {
        fullScreenCover(isPresented: isPresented) {
            AvatarZoomOverlay(
                urlString: urlString,
                displayName: displayName,
                firstName: firstName,
                lastName: lastName,
                caption: caption,
                onDismiss: {
                    var t = Transaction(animation: nil)
                    t.disablesAnimations = true
                    withTransaction(t) { isPresented.wrappedValue = false }
                }
            )
            .presentationBackground(.clear)
        }
    }
}
