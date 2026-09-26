//
//  FeedCaughtUpMarker.swift
//  SPINE
//
//  The "You're all caught up" break in the unified feed. Sits right after the
//  last new post from someone you follow (or at the very top when there were
//  none) and segments what's above from the community posts below, the way
//  Instagram's does. Plays once per feed session as it scrolls into view: a
//  ring draws itself, the check strokes in, two rules push out from the ring
//  to the page edges, and the copy rises underneath. Scrolled back to later
//  in the same session it sits still in its finished state.
//

import SwiftUI

struct FeedCaughtUpMarker: View {
    /// False when this session has already played the entrance — the marker
    /// then renders straight into its final state.
    let animates: Bool
    var onAnimated: () -> Void = {}

    @State private var ringProgress: CGFloat = 0
    @State private var checkProgress: CGFloat = 0
    @State private var ruleProgress: CGFloat = 0
    @State private var badgeScale: CGFloat = 1
    @State private var copyOpacity: Double = 1
    @State private var copyOffset: CGFloat = 0

    private static let ringSize: CGFloat = 44
    private static let ringWidth: CGFloat = 2

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                rule(growsTowardLeading: true)
                badge
                rule(growsTowardLeading: false)
            }
            VStack(spacing: 4) {
                Text("You're all caught up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("You've seen every new post from people you follow.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .opacity(copyOpacity)
            .offset(y: copyOffset)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.top, 34)
        .padding(.bottom, 26)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You're all caught up. You've seen every new post from people you follow.")
        .onAppear(perform: play)
    }

    /// Ring with the check inside, both stroked in.
    private var badge: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(Theme.chrome, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            CheckmarkShape()
                .trim(from: 0, to: checkProgress)
                .stroke(Theme.chrome, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .padding(13)
        }
        .frame(width: Self.ringSize, height: Self.ringSize)
        .scaleEffect(badgeScale)
    }

    /// One of the two rules that push out from the ring toward the page edge.
    private func rule(growsTowardLeading: Bool) -> some View {
        GeometryReader { geo in
            Capsule()
                .fill(Theme.chromeSoft.opacity(0.35))
                .frame(width: geo.size.width * ruleProgress, height: 1)
                .frame(maxWidth: .infinity, alignment: growsTowardLeading ? .trailing : .leading)
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: Self.ringSize)
    }

    private func play() {
        guard animates else {
            ringProgress = 1
            checkProgress = 1
            ruleProgress = 1
            return
        }
        onAnimated()
        ringProgress = 0
        checkProgress = 0
        ruleProgress = 0
        badgeScale = 0.86
        copyOpacity = 0
        copyOffset = 8
        withAnimation(.easeOut(duration: 0.5)) {
            ringProgress = 1
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            badgeScale = 1
        }
        withAnimation(.easeOut(duration: 0.32).delay(0.3)) {
            checkProgress = 1
        }
        withAnimation(.easeOut(duration: 0.55).delay(0.4)) {
            ruleProgress = 1
        }
        withAnimation(.easeOut(duration: 0.4).delay(0.45)) {
            copyOpacity = 1
            copyOffset = 0
        }
    }
}

/// A check drawn as one stroke, short leg first, in the unit square of its rect.
private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.05, y: rect.minY + rect.height * 0.55))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.88))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.97, y: rect.minY + rect.height * 0.15))
        return p
    }
}

#Preview {
    ZStack {
        Theme.background.ignoresSafeArea()
        FeedCaughtUpMarker(animates: true)
    }
}
