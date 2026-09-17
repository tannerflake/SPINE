//
//  ReadingNowFanStack.swift
//  SPINE
//
//  Fanned mini-stack of the covers on the "Reading now" shelf, floated next to
//  a profile picture — a quick visual of what someone is reading right now.
//  Shows up to 3 covers (tilted like a loose hand of cards); extras become "+N".
//  Renders nothing when the shelf is empty.
//

import SwiftUI

struct ReadingNowFanStack: View {
    /// Reading-now books in shelf order (first = current top read, drawn front-most).
    let books: [Book]
    var coverWidth: CGFloat = 30
    var onTap: ((Book) -> Void)? = nil
    /// When true, the covers gently bob and sway forever — use where the fan is a
    /// hero element (own profile header), not in dense lists.
    var floats: Bool = false

    /// Drives the continuous float; each cover reads it with its own amplitude/sign
    /// so they drift out of step instead of bobbing in unison.
    @State private var floatPhase = false

    private static let maxCovers = 3

    private var visible: [Book] { Array(books.prefix(Self.maxCovers)) }
    private var overflow: Int { max(0, books.count - Self.maxCovers) }

    /// Alternating tilts sell the "floating" look; values shrink as the fan grows crowded.
    private func rotation(_ index: Int) -> Double {
        [-7, 5, -4][index % 3]
    }

    private func xOffset(_ index: Int) -> CGFloat {
        CGFloat(index) * coverWidth * 0.55
    }

    private func yOffset(_ index: Int) -> CGFloat {
        [0, 2, 4][index % 3]
    }

    /// Vertical bob amplitude per cover (points, sign alternates direction).
    private func bob(_ index: Int) -> CGFloat {
        [3.0, -3.5, 2.5][index % 3]
    }

    /// Sway amplitude per cover (degrees, sign alternates direction).
    private func sway(_ index: Int) -> Double {
        [2.5, -3.0, 2.0][index % 3]
    }

    private var fanWidth: CGFloat {
        coverWidth + CGFloat(max(0, visible.count - 1)) * coverWidth * 0.55 + 6
    }

    var body: some View {
        if !books.isEmpty {
            HStack(alignment: .center, spacing: 5) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, book in
                        BookCoverView(
                            book: book,
                            size: coverWidth,
                            onTap: onTap != nil ? { onTap?(book) } : nil
                        )
                        .rotationEffect(.degrees(rotation(index) + (floats && floatPhase ? sway(index) : 0)))
                        .offset(
                            x: xOffset(index),
                            y: yOffset(index) + (floats && floatPhase ? bob(index) : 0)
                        )
                        .zIndex(Double(visible.count - index))
                    }
                }
                .frame(width: fanWidth, height: coverWidth * 1.5 + 6, alignment: .topLeading)
                .onAppear {
                    guard floats else { return }
                    withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                        floatPhase = true
                    }
                }

                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.system(size: max(9, coverWidth * 0.3), weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Theme.surface)
                        )
                        .overlay(
                            Capsule().strokeBorder(Theme.chrome.opacity(0.4), lineWidth: 0.75)
                        )
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reading now: \(books.map(\.title).joined(separator: ", "))")
        }
    }
}
