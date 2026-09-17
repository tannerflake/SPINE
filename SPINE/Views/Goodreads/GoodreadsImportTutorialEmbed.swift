//
//  GoodreadsImportTutorialEmbed.swift
//  SPINE
//
//  Tutorial for Goodreads import (below “Sign into Goodreads”).
//
//  Primary: opens the official Shorts walkthrough on YouTube.
//  Optional: add `GoodreadsImportTutorial.mp4` / `.m4v` to the app target, or set
//  `remoteVideoURL` to a direct HTTPS link to an `.mp4` / `.m4v` file (plays in-app).
//

import SwiftUI
import AVKit

struct GoodreadsImportTutorialEmbed: View {
    @Environment(\.openURL) private var openURL

    /// Official Goodreads import tutorial (Shorts). Set to `nil` to fall back to bundled / `remoteVideoURL` video.
    static var youtubeTutorialURL: URL? = URL(string: "https://www.youtube.com/shorts/uaVKGaryCvA")

    /// Optional: hosted video file (HTTPS `.mp4` / `.m4v`). Used only when no YouTube URL is set.
    static var remoteVideoURL: URL? = nil

    private static let bundleBaseName = "GoodreadsImportTutorial"

    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let youTube = Self.youtubeTutorialURL {
                youtubeTutorialCard(url: youTube)
            } else if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(maxWidth: .infinity)
            } else {
                tutorialPlaceholder
            }
        }
        .onAppear {
            if Self.youtubeTutorialURL == nil, player == nil {
                player = Self.resolvePlayer()
            }
        }
        .onDisappear {
            player?.pause()
        }
    }

    private func youtubeTutorialCard(url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.danger.opacity(0.92))
                        .frame(width: 56, height: 56)
                    Image(systemName: "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .offset(x: 2)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("1 min walkthrough")
                        .font(Theme.callout())
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text("See how it works in 45 seconds")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right.square")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
            }
            .padding(14)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.textTertiary.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens YouTube in Safari or the YouTube app.")
    }

    private var tutorialPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.textTertiary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [7, 5]))
            VStack(spacing: 12) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent.opacity(0.85))
                Text("Tutorial video")
                    .font(Theme.callout())
                    .foregroundStyle(Theme.textSecondary)
                Text("Add “GoodreadsImportTutorial.mp4” to the SPINE app target, set GoodreadsImportTutorialEmbed.youtubeTutorialURL, or set remoteVideoURL to a hosted .mp4.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .padding(.vertical, 28)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }

    private static func resolvePlayer() -> AVPlayer? {
        if let remote = remoteVideoURL {
            return AVPlayer(url: remote)
        }
        if let url = Bundle.main.url(forResource: bundleBaseName, withExtension: "mp4")
            ?? Bundle.main.url(forResource: bundleBaseName, withExtension: "m4v") {
            return AVPlayer(url: url)
        }
        return nil
    }
}
