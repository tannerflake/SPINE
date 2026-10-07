//
//  DiscoverSwipeDeck.swift
//  SPINE
//
//  Tinder-style decision layer for the Discover tab: a short stack of cards,
//  one book per card. Drag the top card left to skip or right to queue, or
//  tap the two round buttons under the stack, which do the exact same thing.
//  The tilt, the rubber stamp that grows with the drag, the threshold tick,
//  the fly-out and the next card rising into place all live here. What a card
//  *is* (a BookProfileView with no action bar) is the caller's.
//
//  The stack is a single ForEach keyed by book id, so when the top card flies
//  off and the caller advances, the card that was waiting underneath keeps its
//  view identity (and everything it has already loaded) and simply becomes
//  the top card. Nothing is rebuilt at the handoff, so nothing can pop.
//

import SwiftUI

enum DiscoverSwipeDecision: Equatable {
    case skip
    case queue

    var glyph: String { self == .queue ? "plus" : "xmark" }
    var label: String { self == .queue ? "QUEUE" : "SKIP" }
    var pastTense: String { self == .queue ? "Queued" : "Skipped" }
    /// Skip is the one place the brick hue is allowed in; queue stays ink.
    var color: Color { self == .queue ? Theme.chrome : Theme.danger }
}

/// How a decision was made, for analytics: a drag past the threshold (or a
/// fling) versus a tap on the X / + button.
enum DiscoverDecisionInput: String {
    case swipe
    case button
}

struct DiscoverSwipeDeck<Card: View, Placeholder: View>: View {
    @Environment(\.mainTabBarOverlapExtraHeight) private var mainTabBarOverlapExtraHeight

    /// The book on top, the one being decided on.
    let current: Book
    /// The book waiting underneath, if the batch has one ready.
    let next: Book?
    /// First few decisions: a small "or swipe" cue sits between the buttons.
    var showsSwipeHint: Bool
    /// The coach overlay is up: the real buttons step out so they don't show
    /// through the scrim under the coach's own controls.
    var hidesButtons: Bool = false
    /// The last decision's outcome, flashed between the two buttons for a
    /// beat. The caller owns its timing; the token lets a quick second
    /// decision replace the first badge.
    var badge: (decision: DiscoverSwipeDecision, token: UUID)? = nil
    /// Fires the instant a decision commits, before the fly-out finishes, so
    /// the caller's outcome badge can land while the card is still leaving.
    var onCommit: ((DiscoverSwipeDecision, DiscoverDecisionInput) -> Void)? = nil
    /// Fires once the card has flown off screen. The caller advances the deck.
    let onDecision: (DiscoverSwipeDecision) -> Void
    /// The page for one book. Built once per book and kept for as long as
    /// that book is anywhere in the stack.
    @ViewBuilder let card: (Book) -> Card
    /// What fills the card slot underneath when there is no next book yet
    /// (the batch is refilling).
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var translation: CGSize = .zero
    /// Locked on the first few points of movement: vertical drags belong to
    /// the page's own ScrollView and never move the card.
    @State private var dragAxis: Axis?
    @State private var flyingOut: DiscoverSwipeDecision?
    /// Set the moment the drag crosses the commit line (and cleared if it
    /// comes back), so the haptic fires once per crossing.
    @State private var armed: DiscoverSwipeDecision?
    @State private var cardWidth: CGFloat = 390
    /// Set at commit: the card beneath rises to the front position.
    @State private var revealed = false
    /// Which book the drag/fly-out state belongs to. The transforms apply
    /// only to this card, so the instant the caller promotes the next book it
    /// renders in the resting position with no reset frame in between.
    @State private var movingBookId: String?

    /// How far the card has to travel to commit.
    private let threshold: CGFloat = 112
    /// Corner radius and side gutter of a card.
    private let cornerRadius: CGFloat = 22
    private let gutter: CGFloat = 12
    /// Resting pose of the card underneath: a touch smaller, fully hidden
    /// behind the top card until that one lifts.
    private let backScale: CGFloat = 0.95

    /// -1 (all the way to skip) through 1 (all the way to queue).
    private var progress: CGFloat { max(-1, min(1, translation.width / threshold)) }
    private var isLifted: Bool { translation != .zero || flyingOut != nil }

    /// Bottom to top. The ForEach keeps a card's identity wherever it sits.
    private var stack: [Book] {
        var books: [Book] = []
        if let next, next.id != current.id { books.append(next) }
        books.append(current)
        return books
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if next == nil || next?.id == current.id {
                    placeholderCard
                }
                ForEach(stack, id: \.id) { book in
                    stackCard(book, in: geo.size)
                }
            }
            .onAppear { cardWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, new in cardWidth = new }
        }
        .padding(.horizontal, gutter)
        .padding(.top, 2)
        // The card runs off the bottom of the screen, under the tab bar: only
        // its top corners and sides read as a card.
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay(alignment: .bottom) {
            if !hidesButtons { decisionButtons }
        }
        // The card that was dragged is gone (the caller promoted the next one):
        // drop the drag state so the new top card starts at rest. The new
        // back card appears directly in its resting pose, not by settling.
        .onChange(of: current.id) { _, _ in
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                translation = .zero
                flyingOut = nil
                armed = nil
                revealed = false
                movingBookId = nil
                dragAxis = nil
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, new in new != nil }
        .sensoryFeedback(.success, trigger: flyingOut) { _, new in new != nil }
    }

    // MARK: - Cards

    /// One card in the stack. The same modifier chain for every position, so
    /// a card moving from the back to the front keeps its identity and the
    /// pose change animates instead of re-rendering.
    private func stackCard(_ book: Book, in size: CGSize) -> some View {
        let isTop = book.id == current.id
        let isMoving = book.id == movingBookId
        let drag = isMoving ? translation : .zero
        let lean = isMoving ? progress : 0
        // Back card: smaller, creeping toward the front as the top card leans,
        // then springing the rest of the way on commit. Hidden until the top
        // card lifts so it never shows through at rest.
        let settled = isTop || revealed
        let scale: CGFloat = settled ? 1 : backScale + (1 - backScale) * 0.5 * abs(progress)
        return card(book)
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Theme.background))
            .overlay(washOverlay.opacity(isMoving ? 1 : 0))
            .overlay(alignment: .top) { stampRow.opacity(isMoving ? 1 : 0) }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.chrome.opacity(0.22), lineWidth: Theme.chromeHairline)
            )
            .shadow(color: Theme.shadowInk.opacity(isTop ? 0.16 : 0.08), radius: isTop ? 18 : 10, y: isTop ? 8 : 4)
            .scaleEffect(scale, anchor: .bottom)
            .offset(drag)
            .rotationEffect(.degrees(Double(lean) * 6), anchor: .bottom)
            .opacity(isTop || isLifted ? 1 : 0)
            .simultaneousGesture(dragGesture)
            .allowsHitTesting(isTop && flyingOut == nil)
            .zIndex(isTop ? 2 : 1)
            .accessibilityHidden(!isTop)
            // A book that lands on top from outside the stack (undo a pass,
            // "Selected for you" from the feed) slides in from the side it
            // left by. Cards never fade out: the one that flew is already off
            // screen when it leaves the stack.
            .transition(.asymmetric(
                insertion: isTop ? .move(edge: .leading).combined(with: .opacity) : .identity,
                removal: .identity
            ))
    }

    /// Stand-in back card while the batch refills.
    private var placeholderCard: some View {
        placeholder()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Theme.background))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.chrome.opacity(0.22), lineWidth: Theme.chromeHairline)
            )
            .shadow(color: Theme.shadowInk.opacity(0.08), radius: 10, y: 4)
            .scaleEffect(revealed ? 1 : backScale, anchor: .bottom)
            .opacity(isLifted ? 1 : 0)
            .zIndex(0)
    }

    // MARK: - Card dressing

    /// Faint tint over the whole page in the decision's colour, so the lean
    /// reads even before the stamp is fully in.
    private var washOverlay: some View {
        Rectangle()
            .fill(progress > 0 ? DiscoverSwipeDecision.queue.color : DiscoverSwipeDecision.skip.color)
            .opacity(Double(abs(progress)) * 0.08)
            .allowsHitTesting(false)
    }

    /// QUEUE stamp top-left (fades in as the card goes right), SKIP top-right
    /// (as it goes left). Each is pressed in at an angle, like ink on a card.
    private var stampRow: some View {
        HStack(alignment: .top) {
            stamp(.queue)
                .opacity(Double(max(0, progress)))
                .scaleEffect(0.8 + 0.2 * max(0, progress), anchor: .topLeading)
                .rotationEffect(.degrees(-14), anchor: .topLeading)
            Spacer(minLength: 16)
            stamp(.skip)
                .opacity(Double(max(0, -progress)))
                .scaleEffect(0.8 + 0.2 * max(0, -progress), anchor: .topTrailing)
                .rotationEffect(.degrees(14), anchor: .topTrailing)
        }
        .padding(.horizontal, 22)
        .padding(.top, 40)
        .allowsHitTesting(false)
    }

    private func stamp(_ decision: DiscoverSwipeDecision) -> some View {
        let committed = flyingOut == decision
        return HStack(spacing: 8) {
            Image(systemName: committed ? (decision == .queue ? "checkmark" : "xmark") : decision.glyph)
                .font(.system(size: 22, weight: .heavy))
            Text(committed ? decision.pastTense.uppercased() : decision.label)
                .font(.system(size: 30, weight: .heavy))
                .tracking(3)
        }
        .foregroundStyle(decision.color)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.background.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(decision.color, lineWidth: 4)
        )
        .animation(.snappy(duration: 0.2), value: committed)
    }

    // MARK: - Buttons

    /// The two decisions, floating over the bottom of the card.
    private var decisionButtons: some View {
        HStack(spacing: 0) {
            decisionButton(.skip)
            Spacer(minLength: 0)
            if showsSwipeHint {
                swipeHint
            }
            Spacer(minLength: 0)
            decisionButton(.queue)
        }
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .padding(.bottom, 14 + mainTabBarOverlapExtraHeight)
        // Centred between the buttons, riding a little above their middle.
        .overlay(alignment: .top) {
            if let badge {
                DiscoverDecisionBadge(decision: badge.decision)
                    .id(badge.token)
                    .padding(.top, 22)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        // Paper fade under the row so the labels and hint stay legible over
        // whatever the page has scrolled to; the buttons still read as
        // floating rather than sitting on a panel.
        .background(
            LinearGradient(
                colors: [Theme.background.opacity(0), Theme.background.opacity(0.92), Theme.background],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
    }

    private var swipeHint: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.left")
            Text("or swipe")
            Image(systemName: "arrow.right")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.textTertiary)
        .padding(.bottom, 22)
        .opacity(isLifted || badge != nil ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: isLifted || badge != nil)
    }

    private func decisionButton(_ decision: DiscoverSwipeDecision) -> some View {
        // How far the drag leans *toward* this button, 0...1.
        let lean = decision == .queue ? max(0, progress) : max(0, -progress)
        let hot = lean >= 1 || flyingOut == decision
        let isQueue = decision == .queue
        return VStack(spacing: 8) {
            Button {
                commit(decision, via: .button)
            } label: {
                ZStack {
                    Circle()
                        .fill(isQueue || hot ? decision.color : Theme.surfaceElevated)
                    Circle()
                        .strokeBorder(isQueue || hot ? Color.clear : Theme.chrome.opacity(0.35), lineWidth: 1.5)
                    Image(systemName: decision.glyph)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(isQueue ? Theme.onChrome : (hot ? Theme.phosphorWhite : decision.color))
                }
                .frame(width: 66, height: 66)
                .shadow(color: Theme.shadowInk.opacity(0.16), radius: 10, y: 4)
                .contentShape(Circle())
            }
            .buttonStyle(.springPress)
            .scaleEffect(1 + 0.2 * lean)
            .animation(.snappy(duration: 0.2), value: hot)
            .disabled(flyingOut != nil)
            .accessibilityLabel(isQueue ? "Queue this book" : "Skip this book")

            Text(decision.label)
                .font(.system(size: 11, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard flyingOut == nil else { return }
                // The left strip belongs to the system back swipe (and the
                // return-to-feed swipe in DiscoverView).
                guard value.startLocation.x > 28 else { return }
                if dragAxis == nil {
                    let t = value.translation
                    guard abs(t.width) > 8 || abs(t.height) > 8 else { return }
                    dragAxis = abs(t.width) > abs(t.height) * 1.3 ? .horizontal : .vertical
                }
                guard dragAxis == .horizontal else { return }
                movingBookId = current.id
                translation = CGSize(width: value.translation.width, height: value.translation.height * 0.25)
                let p = progress
                let nowArmed: DiscoverSwipeDecision? = p >= 1 ? .queue : (p <= -1 ? .skip : nil)
                if nowArmed != armed { armed = nowArmed }
            }
            .onEnded { value in
                let axis = dragAxis
                dragAxis = nil
                guard flyingOut == nil, axis == .horizontal else { return }
                let predicted = value.predictedEndTranslation.width
                let flung = abs(predicted) > threshold * 2.2 && abs(value.translation.width) > 40
                if abs(translation.width) >= threshold {
                    commit(translation.width > 0 ? .queue : .skip, via: .swipe)
                } else if flung {
                    commit(predicted > 0 ? .queue : .skip, via: .swipe)
                } else {
                    armed = nil
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                        translation = .zero
                    }
                }
            }
    }

    /// Send the top card off the matching edge while the card beneath rises
    /// into its place, then hand the decision up.
    private func commit(_ decision: DiscoverSwipeDecision, via input: DiscoverDecisionInput) {
        guard flyingOut == nil else { return }
        movingBookId = current.id
        flyingOut = decision
        armed = decision
        onCommit?(decision, input)
        let direction: CGFloat = decision == .queue ? 1 : -1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            revealed = true
        }
        withAnimation(.easeIn(duration: 0.32)) {
            translation = CGSize(width: direction * cardWidth * 1.4, height: translation.height - 24)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 360_000_000)
            onDecision(decision)
        }
    }
}

/// Pops in over the deck once a card has left, so the outcome is unmistakable
/// even when the stamp went by fast. Hosted by DiscoverView, which outlives
/// the card it describes.
struct DiscoverDecisionBadge: View {
    let decision: DiscoverSwipeDecision

    var body: some View {
        let isQueue = decision == .queue
        HStack(spacing: 8) {
            Image(systemName: isQueue ? "checkmark" : "xmark")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(isQueue ? Theme.onChrome : decision.color)
            Text(decision.pastTense)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(isQueue ? Theme.onChrome : Theme.textPrimary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .background(Capsule().fill(isQueue ? Theme.chrome : Theme.surfaceElevated))
        .overlay(Capsule().strokeBorder(isQueue ? Color.clear : Theme.chrome.opacity(0.35), lineWidth: Theme.chromeHairline))
        .shadow(color: Theme.shadowInk.opacity(0.18), radius: 14, y: 6)
        // Slightly see-through so the card behind still reads.
        .opacity(0.75)
        .allowsHitTesting(false)
    }
}

// MARK: - First-run coach

/// Shown once, the first time the deck has a book on it: a paper scrim with a
/// small card that swipes itself left (SKIP) and right (QUEUE) on a loop, and
/// "Swipe" between the two arrows under it. Any tap or swipe dismisses it, for good.
struct DiscoverSwipeCoachOverlay: View {
    let onDismiss: () -> Void

    /// -1 = leaning skip, 0 = centred, 1 = leaning queue.
    @State private var lean: CGFloat = 0
    @State private var demo: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.background.opacity(0.94)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 0)
                demoCard
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        }
        .contentShape(Rectangle())
        // Any touch ends the lesson: a tap, or a swipe in either direction.
        .onTapGesture { onDismiss() }
        .simultaneousGesture(DragGesture(minimumDistance: 10).onEnded { _ in onDismiss() })
        .onAppear(perform: startDemo)
        .onDisappear { demo?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Swipe left or tap X to skip a book. Swipe right or tap plus to queue it.")
    }

    /// A toy card with the two stamps, nudged side to side by `lean`.
    private var demoCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.chrome.opacity(0.35), lineWidth: Theme.chromeHairline)
                )
                .shadow(color: Theme.shadowInk.opacity(0.18), radius: 16, y: 8)
            // Stand-in for a cover and its title lines.
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.chrome.opacity(0.85))
                    .frame(width: 64, height: 96)
                Capsule().fill(Theme.chrome.opacity(0.5)).frame(width: 90, height: 8)
                Capsule().fill(Theme.chrome.opacity(0.25)).frame(width: 60, height: 8)
            }
            stamp(.queue)
                .opacity(Double(max(0, lean)))
                .rotationEffect(.degrees(-14))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
            stamp(.skip)
                .opacity(Double(max(0, -lean)))
                .rotationEffect(.degrees(14))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(10)
        }
        .frame(width: 180, height: 240)
        .offset(x: lean * 56)
        .rotationEffect(.degrees(Double(lean) * 8), anchor: .bottom)
        .overlay(alignment: .bottom) {
            // The two directions the card can go.
            HStack {
                arrow("arrow.left", color: DiscoverSwipeDecision.skip.color).opacity(lean <= 0 ? 1 : 0.25)
                Spacer()
                Text("Swipe")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                arrow("arrow.right", color: DiscoverSwipeDecision.queue.color).opacity(lean >= 0 ? 1 : 0.25)
            }
            .frame(width: 290)
            .offset(y: 36)
        }
        .padding(.bottom, 36)
    }

    private func arrow(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .heavy))
            .foregroundStyle(color)
    }

    private func stamp(_ decision: DiscoverSwipeDecision) -> some View {
        HStack(spacing: 4) {
            Image(systemName: decision.glyph).font(.system(size: 12, weight: .heavy))
            Text(decision.label).font(.system(size: 15, weight: .heavy)).tracking(2)
        }
        .foregroundStyle(decision.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(decision.color, lineWidth: 3))
    }

    /// Centre, left, centre, right, centre, and around again.
    private func startDemo() {
        demo?.cancel()
        demo = Task { @MainActor in
            let steps: [CGFloat] = [-1, 0, 1, 0]
            try? await Task.sleep(nanoseconds: 500_000_000)
            while !Task.isCancelled {
                for step in steps {
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) { lean = step }
                    try? await Task.sleep(nanoseconds: step == 0 ? 500_000_000 : 1_000_000_000)
                }
            }
        }
    }
}
