//
//  BookBlendSummaryCard.swift
//  Spine
//
//  The blend in one shareable card: the pair crest (both readers with the
//  archetype badge at the seam), the myth (archetype plus the AI's
//  pair-specific line) and the data (taste match, shared books, agreements,
//  shared genres). Rendered at 360x640 points through StoryExporter
//  (1080x1920 at 3x) for Instagram Stories and Photos, and shown scaled
//  down as the story's closing slide so what the reader sees is exactly what
//  exports. Fixed dark blend tones in both appearance modes. Copy rule: no
//  em-dashes in user-facing text.
//

import SwiftUI
import UIKit

// MARK: - Pair crest

/// Both readers overlapped, with the blend's archetype emoji sitting on a
/// paper badge at the bottom seam: the pair's shared crest. Used on the
/// archetype slide and the summary card so the two faces carry the story.
struct BlendPairCrest: View {
    let leftURL: String?
    let rightURL: String?
    let leftName: String
    let rightName: String
    var leftImage: UIImage? = nil
    var rightImage: UIImage? = nil
    var size: CGFloat = 96
    var emoji: String? = nil

    private var badgeSize: CGFloat { size * 0.46 }

    var body: some View {
        BlendAvatarLockup(
            leftURL: leftURL,
            rightURL: rightURL,
            leftName: leftName,
            rightName: rightName,
            size: size,
            leftImage: leftImage,
            rightImage: rightImage
        )
        .overlay(alignment: .bottom) {
            if let emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: badgeSize * 0.56))
                    .frame(width: badgeSize, height: badgeSize)
                    .background(Circle().fill(Theme.paperFixed))
                    .overlay(Circle().strokeBorder(Theme.inkFixed.opacity(0.12), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.35), radius: 6, y: 3)
                    .offset(y: badgeSize * 0.42)
            }
        }
        // Reserve the badge's overhang so stacks below don't collide with it.
        .padding(.bottom, emoji == nil ? 0 : badgeSize * 0.42)
    }
}

// MARK: - Summary canvas

/// The exported card. Every color here is a fixed token: ImageRenderer has
/// no appearance environment, and the blend is ink-and-paper regardless.
struct BlendSummaryCanvas: View {
    let blend: BookBlend
    let myUid: String
    /// uid → pre-resolved profile photo. ImageRenderer cannot wait on the
    /// async avatar loader, so the story resolves both up front and hands
    /// them in; a missing entry falls back to the monogram.
    var photos: [String: UIImage] = [:]

    private var otherUid: String { blend.otherUserId(from: myUid) }
    private var me: BookBlend.Participant? { blend.participants[myUid] }
    private var them: BookBlend.Participant? { blend.participants[otherUid] }
    private var myName: String { me?.firstName ?? "You" }
    private var otherName: String { them?.firstName ?? "Them" }
    private var result: BookBlend.Result? { blend.result }

    /// Shared books both readers put on the same tier rung.
    private var agreedCount: Int {
        (result?.sharedBooks ?? []).filter { book in
            guard let mine = book.tiers[myUid], let theirs = book.tiers[otherUid] else { return false }
            return mine == theirs
        }.count
    }

    /// The pair-specific line from the AI pass: the one that names what each
    /// reader brings. Prefers an insight that talks about both readers by name.
    private var analysis: String {
        let insights = result?.insights ?? []
        let contrast = insights.first {
            $0.body.contains(myName) && $0.body.contains(otherName)
        }
        return (contrast ?? insights.first)?.body ?? ""
    }

    var body: some View {
        ZStack {
            BlendCanvasBackdrop()
            brandGlyph

            VStack(spacing: 0) {
                header
                    .padding(.top, 52)

                Spacer(minLength: 14)

                BlendPairCrest(
                    leftURL: me?.photoURL,
                    rightURL: them?.photoURL,
                    leftName: myName,
                    rightName: otherName,
                    leftImage: photos[myUid],
                    rightImage: photos[otherUid],
                    size: 112,
                    emoji: result?.archetypeEmoji
                )

                Text("\(myName) × \(otherName)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.paperFixed)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 14)
                    .padding(.horizontal, 28)

                Spacer(minLength: 14)

                mythBlock

                Spacer(minLength: 16)

                dataBlock
                    .padding(.horizontal, 22)

                // Give back exactly what the header took so the whole stack
                // shifts down 12pt together instead of the crest and the myth
                // getting squeezed into the gap the header left behind.
                Spacer(minLength: 28)
            }
            .frame(width: StoryExporter.canvasSize.width, height: StoryExporter.canvasSize.height)
        }
        .frame(width: StoryExporter.canvasSize.width, height: StoryExporter.canvasSize.height)
        .clipped()
    }

    /// The reader glyph behind the wordmark, same read as the other story
    /// canvases: big, faint, clipped by the right edge.
    private var brandGlyph: some View {
        Image("SpineLogo")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 130)
            .foregroundStyle(Theme.paperFixed.opacity(0.10))
            .rotationEffect(.degrees(-10))
            // Centered on the wordmark's line (header sits 52pt down here).
            .offset(x: 34, y: -8)
            .frame(
                width: StoryExporter.canvasSize.width,
                height: StoryExporter.canvasSize.height,
                alignment: .topTrailing
            )
            .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("BOOK BLEND")
                .font(.system(size: 15.4, weight: .heavy))
                .tracking(4.9)
                .foregroundStyle(Theme.paperFixed.opacity(0.7))
            Spacer()
            Text("SPINE")
                .font(.system(size: 13, weight: .heavy))
                .tracking(3.5)
                .foregroundStyle(Theme.paperFixed)
        }
        .padding(.horizontal, 26)
    }

    /// The myth: who the two of you are as a reading pair, and why. No tagline
    /// here on purpose: the pair-specific line says more than a subtitle does.
    private var mythBlock: some View {
        VStack(spacing: 8) {
            Text(result?.archetype ?? "")
                .font(.system(size: 32, weight: .heavy))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.paperFixed, Theme.paperFixed.opacity(0.78)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .padding(.horizontal, 26)
            if !analysis.isEmpty {
                Text(analysis)
                    .font(.system(size: 14, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .lineLimit(4)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(Theme.paperFixed.opacity(0.72))
                    .padding(.top, 2)
                    .padding(.horizontal, 30)
            }
        }
    }

    /// The data: the taste match dial and the numbers behind the verdict.
    private var dataBlock: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Theme.paperFixed.opacity(0.16), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat(result?.score ?? 0) / 100)
                    .stroke(
                        AngularGradient(
                            colors: [Theme.paperFixed.opacity(0.55), Theme.paperFixed, Theme.paperFixed.opacity(0.55)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: -2) {
                    Text("\(result?.score ?? 0)%")
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(Theme.paperFixed)
                    Text("MATCH")
                        .font(.system(size: 8, weight: .heavy))
                        .tracking(1.5)
                        .foregroundStyle(Theme.paperFixed.opacity(0.6))
                }
            }
            .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 9) {
                statLine(value: result?.sharedBooks.count ?? 0, label: "books read by both")
                statLine(value: agreedCount, label: "landed on the same tier")
                statLine(value: result?.sharedGenres.count ?? 0, label: "genres in common")
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Theme.paperFixed.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.paperFixed.opacity(0.14), lineWidth: 1))
        )
    }

    private func statLine(value: Int, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(value)")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Theme.paperFixed)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.paperFixed.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - Backdrop

/// The blend's aurora look, drawn with radial gradients instead of blurred
/// circles so it rasterizes identically on screen and through ImageRenderer.
struct BlendCanvasBackdrop: View {
    var body: some View {
        ZStack {
            Theme.inkFixed
            glow(opacity: 0.20, radius: 230, x: -80, y: -240)
            glow(opacity: 0.12, radius: 210, x: 150, y: -60)
            glow(opacity: 0.09, radius: 220, x: -110, y: 190)
            glow(opacity: 0.14, radius: 180, x: 110, y: 270)
        }
    }

    private func glow(opacity: Double, radius: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Theme.paperFixed.opacity(opacity), Theme.paperFixed.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
            .frame(width: radius * 2, height: radius * 2)
            .offset(x: x, y: y)
    }
}
