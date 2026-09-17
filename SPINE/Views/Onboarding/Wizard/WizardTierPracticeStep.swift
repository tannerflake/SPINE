//
//  WizardTierPracticeStep.swift
//  SPINE
//
//  The hands-on step that follows the "how tiers work" explainer. Reading
//  about the tier list teaches nothing about working it, so this step makes
//  the member perform both gestures the app is built on, on one board that
//  never resets:
//
//    1. Drag    - tap and hold the 🤩 book stranded on F, drag it up a tier.
//    2. Select  - double tap one of the two duds sitting in S, add the other,
//                 then Move the pair down to F in one go.
//
//  Nothing advances on its own: each phase waits for the real gesture, and an
//  indicator (pulsing outline, arrow, double tap ripple) always names the next
//  thing to touch. The payoff copy names the rest of that menu (year read,
//  remove, fix cover) before the CTA.
//
//  The board is local demo state: no Firestore, no real books. Copy rule: no
//  em-dashes.
//
//  DEBUG: -uiPreviewOnboardingWizard -uiPreviewWizardTierPractice jumps here;
//  add -uiPreviewWizardTierProTip to land on the pro tip recap.
//

import SwiftUI

// MARK: - Shared board

/// A demo cover on the practice board.
struct TierPracticeBook: Identifiable, Equatable {
    let id = UUID()
    let face: String
    var tier: String
}

/// Row frames in the board's coordinate space, so a drag can tell which tier
/// the finger is over.
private struct TierPracticeRowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Cover frames in the same space. Indicators that have to sit outside a cover
/// (an arrow above it) are drawn over the whole board from these, since each
/// row clips its own contents.
private struct TierPracticeCoverFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

enum TierPracticeMetrics {
    static let rowSpacing: CGFloat = 6
    static let letterWidth: CGFloat = 38
    static let coordinateSpace = "wizardTierPractice"

    static func coverSize(rowHeight: CGFloat) -> CGSize {
        CGSize(width: (rowHeight * 0.5).rounded(), height: (rowHeight * 0.72).rounded())
    }

    /// Rows fill what the copy and footer leave behind, inside sane bounds.
    static func rowHeight(boardHeight: CGFloat) -> CGFloat {
        let perRow = boardHeight / CGFloat(spineTierLabels.count) - rowSpacing
        return min(64, max(42, perRow))
    }
}

/// The faceless, hued jacket the step drags around. Same language as the
/// explainer step's demo covers: a palette hue and the face you'd make.
struct TierPracticeCoverArt: View {
    let face: String
    let size: CGSize
    let seed: String

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.coverPaletteColor(for: seed))
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.22)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 2)
                .padding(.leading, 3)
            Text(face)
                .font(.system(size: size.width * 0.62))
                .frame(maxWidth: .infinity)
                .padding(.leading, 3)
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: Theme.shadowInk.opacity(0.18), radius: 3, x: 0, y: 2)
    }
}

/// Two rings expanding out of a cover: the universal "double tap this" mark.
/// Static concentric rings under Reduce Motion, which still read as a target.
struct DoubleTapPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        ZStack {
            ring(delay: 0)
            ring(delay: 0.32)
            Circle()
                .fill(Theme.textPrimary.opacity(0.75))
                .frame(width: 9, height: 9)
        }
        .allowsHitTesting(false)
        .onAppear { animating = true }
    }

    private func ring(delay: Double) -> some View {
        Circle()
            .stroke(Theme.textPrimary.opacity(0.85), lineWidth: 2)
            .frame(width: 26, height: 26)
            .scaleEffect(reduceMotion ? (delay > 0 ? 1.4 : 0.9) : (animating ? 1.7 : 0.45))
            .opacity(reduceMotion ? 0.5 : (animating ? 0 : 0.95))
            .animation(
                reduceMotion ? nil : .easeOut(duration: 1.2).repeatForever(autoreverses: false).delay(delay),
                value: animating
            )
    }
}

/// An arrow that bobs toward whatever it is pointing at, so it reads as a
/// pointer rather than a button.
struct TierPracticePointer: View {
    /// SF Symbol naming the direction, e.g. "arrow.left" or "arrow.down".
    let systemName: String
    /// Bob axis: the arrow travels a few points along it and back.
    var horizontal: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bobbing = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 19, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .offset(
                x: horizontal ? (bobbing && !reduceMotion ? -6 : 4) : 0,
                y: horizontal ? 0 : (bobbing && !reduceMotion ? -6 : 4)
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: bobbing
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { bobbing = true }
    }
}

/// Six tier rows holding the demo books. The caller builds each cover so it can
/// attach its own gestures and decorations.
struct TierPracticeBoard<Cover: View>: View {
    let books: [TierPracticeBook]
    let rowHeight: CGFloat
    /// Row lit as the current drop target.
    var highlightedTier: String?
    /// Row called out as where the book in hand should go ("Drop here").
    var suggestedTier: String?
    @ViewBuilder let cover: (TierPracticeBook, CGSize) -> Cover

    var body: some View {
        VStack(spacing: TierPracticeMetrics.rowSpacing) {
            ForEach(spineTierLabels, id: \.self) { tier in
                row(tier)
            }
        }
    }

    private func row(_ tier: String) -> some View {
        let lit = highlightedTier == tier
        let suggested = suggestedTier == tier && !lit
        let size = TierPracticeMetrics.coverSize(rowHeight: rowHeight)
        return HStack(spacing: 0) {
            ZStack {
                spineTierColor(for: tier)
                VStack(spacing: 0) {
                    Text(tier)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Text("Tier")
                        .font(.system(size: 8, weight: .medium))
                        .opacity(0.7)
                }
                .foregroundStyle(Color.black.opacity(0.75))
            }
            .frame(width: TierPracticeMetrics.letterWidth)

            HStack(spacing: 7) {
                ForEach(books.filter { $0.tier == tier }) { book in
                    cover(book, size)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(Theme.surface.opacity(lit || suggested ? 0.95 : 0.6))
            .overlay(alignment: .trailing) {
                if suggested {
                    Text("Drop here")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.trailing, 12)
                        .transition(.opacity)
                }
            }
        }
        .frame(height: rowHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .stroke(Theme.textPrimary.opacity(lit ? 0.55 : 0), lineWidth: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(
                    Theme.textPrimary.opacity(suggested ? 0.5 : 0),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 5])
                )
        )
        .shadow(color: Theme.shadowInk.opacity(lit ? 0.18 : 0), radius: 10, x: 0, y: 6)
        .scaleEffect(lit ? 1.015 : 1)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TierPracticeRowFramesKey.self,
                    value: [tier: proxy.frame(in: .named(TierPracticeMetrics.coordinateSpace))]
                )
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tier) tier")
    }
}

extension View {
    /// Collects the practice board's row frames.
    func onTierPracticeRowFrames(_ handler: @escaping ([String: CGRect]) -> Void) -> some View {
        coordinateSpace(name: TierPracticeMetrics.coordinateSpace)
            .onPreferenceChange(TierPracticeRowFramesKey.self, perform: handler)
    }

    /// Collects the practice board's cover frames.
    func onTierPracticeCoverFrames(_ handler: @escaping ([UUID: CGRect]) -> Void) -> some View {
        onPreferenceChange(TierPracticeCoverFramesKey.self, perform: handler)
    }

    /// Reports this cover's frame in the board's coordinate space.
    func tierPracticeCoverFrame(_ id: UUID) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TierPracticeCoverFramesKey.self,
                    value: [id: proxy.frame(in: .named(TierPracticeMetrics.coordinateSpace))]
                )
            }
        )
    }
}

// MARK: - The step

struct WizardTierPracticeStep: View {
    @ObservedObject var model: OnboardingWizardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One board, three phases, no resets in between.
    private enum Phase { case drag, select, done }

    /// S opens holding two books nobody would put there; F opens holding one
    /// everybody would rescue. Both jobs are visible from the first frame.
    @State private var books: [TierPracticeBook] = [
        TierPracticeBook(face: "😍", tier: "S"),
        TierPracticeBook(face: "🤢", tier: "S"),
        TierPracticeBook(face: "😖", tier: "S"),
        TierPracticeBook(face: "😁", tier: "A"),
        TierPracticeBook(face: "🙂", tier: "B"),
        TierPracticeBook(face: "😐", tier: "C"),
        TierPracticeBook(face: "🤩", tier: "F"),
    ]
    /// The misfiled book the drag phase wants rescued.
    @State private var heroId: UUID?
    /// The two duds the select phase wants sent down, in board order.
    @State private var dudIds: [UUID] = []

    // Drag phase
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var coverFrames: [UUID: CGRect] = [:]
    @State private var draggingId: UUID?
    @State private var dragPoint: CGPoint = .zero
    @State private var hoverTier: String?
    @State private var didDrag = false

    // Select phase
    @State private var isSelecting = false
    @State private var selected: Set<UUID> = []
    @State private var showMovePicker = false
    @State private var movedCount = 0

    @State private var hintPulsing = false

    private var phase: Phase {
        if movedCount >= 2 { return .done }
        return didDrag ? .select : .drag
    }

    private static let copyHeight: CGFloat = 150
    private static let footerHeight: CGFloat = 76

    var body: some View {
        GeometryReader { geo in
            let boardHeight = geo.size.height - Self.copyHeight - Self.footerHeight - 34
            let rowHeight = TierPracticeMetrics.rowHeight(boardHeight: boardHeight)
            VStack(alignment: .leading, spacing: 0) {
                copyBlock
                    .frame(height: Self.copyHeight, alignment: .topLeading)
                    .clipped()

                if phase == .done {
                    proTipCard
                } else {
                    board(rowHeight: rowHeight)
                }

                Spacer(minLength: 12)

                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 24)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .onAppear {
            heroId = books.first { $0.tier == "F" }?.id
            dudIds = books.filter { $0.tier == "S" && $0.face != "😍" }.map(\.id)
            hintPulsing = true
            // Design flag: jump to the pro tip recap without playing the two
            // gestures out first.
            if model.previewMode, ProcessInfo.processInfo.arguments.contains("-uiPreviewWizardTierProTip") {
                didDrag = true
                movedCount = 2
            }
        }
        .sheet(isPresented: $showMovePicker) {
            movePicker
                .presentationDetents([.height(240)])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: Copy

    private var headline: String {
        switch phase {
        case .drag: return "Move a book."
        case .select:
            if !isSelecting { return "Select multiple books." }
            return selected.count >= 2 ? "Now tap \"Move\"." : "Add the second one."
        case .done: return "Pro tip."
        }
    }

    private var subline: String {
        switch phase {
        case .drag:
            return "Tap and hold a book to drag it into the tier it belongs in."
        case .select:
            if !isSelecting {
                return "Two of the books in the S-tier don't belong. Double tap a book to enable multi-select."
            }
            return selected.count >= 2
                ? "Tap \"Move\", then send them down to F."
                : "Tap the other one to add it to the selection."
        case .done:
            return "You can use the multi-select menu to:"
        }
    }

    private var copyBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            TypewriterText(
                text: headline,
                font: .system(size: 28, weight: .bold),
                centered: false
            )
            .id(headline)
            Text(subline)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .id(subline)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.25), value: subline)
    }

    // MARK: Board

    private func board(rowHeight: CGFloat) -> some View {
        TierPracticeBoard(
            books: books,
            rowHeight: rowHeight,
            highlightedTier: hoverTier,
            suggestedTier: draggingId != nil ? "S" : nil
        ) { book, size in
            if phase == .drag {
                coverArt(book, size: size)
                    .gesture(dragGesture(for: book))
            } else {
                coverArt(book, size: size)
                    .onTapGesture(count: 2) { enterSelection(book) }
                    .onTapGesture { if isSelecting { toggle(book) } }
            }
        }
        .overlay(alignment: .topLeading) {
            if let draggingId, let book = books.first(where: { $0.id == draggingId }) {
                TierPracticeCoverArt(
                    face: book.face,
                    size: TierPracticeMetrics.coverSize(rowHeight: rowHeight),
                    seed: seed(book)
                )
                .scaleEffect(1.25)
                .shadow(color: Theme.shadowInk.opacity(0.3), radius: 12, x: 0, y: 8)
                .position(dragPoint)
                .allowsHitTesting(false)
            }
        }
        // Arrows live above the board, not inside a row: rows clip their own
        // contents, and these have to sit over the cover they point at.
        .overlay(alignment: .topLeading) {
            ForEach(arrowTargets, id: \.self) { id in
                if let frame = coverFrames[id] {
                    TierPracticePointer(systemName: "arrow.down", horizontal: false)
                        .position(x: frame.midX, y: frame.minY - 20)
                }
            }
        }
        .onTierPracticeRowFrames { rowFrames = $0 }
        .onTierPracticeCoverFrames { coverFrames = $0 }
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: books)
        .animation(.easeInOut(duration: 0.2), value: draggingId)
        .animation(.easeInOut(duration: 0.18), value: selected)
    }

    private func seed(_ book: TierPracticeBook) -> String { "wizard-practice-\(book.id)" }

    /// One cover plus whatever indicator the current phase puts on it.
    private func coverArt(_ book: TierPracticeBook, size: CGSize) -> some View {
        let picked = selected.contains(book.id)
        return TierPracticeCoverArt(face: book.face, size: size, seed: seed(book))
            .opacity(draggingId == book.id ? 0.25 : 1)
            .overlay {
                if picked {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Theme.textPrimary, lineWidth: 2.5)
                } else if wantsOutline(book) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Theme.textPrimary.opacity(hintPulsing && !reduceMotion ? 0.2 : 0.8), lineWidth: 2)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                            value: hintPulsing
                        )
                }
            }
            .overlay {
                if wantsDoubleTapMark(book) {
                    // Just above the face, so the ripple and the emoji read as
                    // one target instead of covering each other.
                    DoubleTapPulse()
                        .offset(y: -size.height * 0.34)
                }
            }
            .overlay(alignment: .topTrailing) {
                if picked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.textPrimary, Theme.background)
                        .offset(x: 5, y: -5)
                }
            }
            .overlay(alignment: .trailing) {
                if wantsPointer(book) {
                    TierPracticePointer(systemName: "arrow.left")
                        .offset(x: size.width / 2 + 24)
                }
            }
            .scaleEffect(picked ? 0.9 : 1)
            .tierPracticeCoverFrame(book.id)
            .accessibilityLabel("Book in \(book.tier) tier")
            .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// The book to grab, while nothing has been grabbed yet.
    private func wantsOutline(_ book: TierPracticeBook) -> Bool {
        switch phase {
        case .drag: return book.id == heroId && draggingId == nil
        case .select: return isSelecting && nextDudId == book.id
        case .done: return false
        }
    }

    /// Rings sit on both duds until selection mode has started: either one is a
    /// fine place to start, and the double tap is the gesture being taught, so
    /// it gets the loudest mark.
    private func wantsDoubleTapMark(_ book: TierPracticeBook) -> Bool {
        phase == .select && !isSelecting && dudIds.contains(book.id)
    }

    /// The sideways arrow belongs to the drag phase only; the select phase
    /// points from above (see `arrowTargets`), where the rings are.
    private func wantsPointer(_ book: TierPracticeBook) -> Bool {
        phase == .drag && book.id == heroId && draggingId == nil
    }

    /// Covers an arrow hangs over: both duds while they wait to be picked, then
    /// whichever one is still unselected.
    private var arrowTargets: [UUID] {
        guard phase == .select else { return [] }
        if !isSelecting { return dudIds }
        guard selected.count < 2, let next = nextDudId else { return [] }
        return [next]
    }

    /// The dud still waiting to be selected.
    private var nextDudId: UUID? {
        dudIds.first { !selected.contains($0) }
    }

    // MARK: Drag phase

    /// Matches the real tier list: a brief press picks the cover up, then it
    /// follows the finger until it is dropped on a row.
    private func dragGesture(for book: TierPracticeBook) -> some Gesture {
        LongPressGesture(minimumDuration: 0.16)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(TierPracticeMetrics.coordinateSpace)))
            .onChanged { value in
                switch value {
                case .first(true):
                    lift(book)
                case .second(true, let drag):
                    lift(book)
                    guard let drag else { return }
                    dragPoint = drag.location
                    let tier = tier(at: drag.location)
                    if tier != hoverTier {
                        hoverTier = tier
                        if tier != nil { WizardHaptics.selection() }
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                guard case .second(true, let drag?) = value else {
                    cancelDrag()
                    return
                }
                drop(book, at: drag.location)
            }
    }

    private func lift(_ book: TierPracticeBook) {
        guard draggingId != book.id else { return }
        draggingId = book.id
        hoverTier = book.tier
        WizardHaptics.step()
    }

    private func tier(at point: CGPoint) -> String? {
        rowFrames.first { $0.value.contains(point) }?.key
    }

    private func cancelDrag() {
        draggingId = nil
        hoverTier = nil
    }

    private func drop(_ book: TierPracticeBook, at point: CGPoint) {
        let target = tier(at: point)
        cancelDrag()
        guard let target, target != book.tier,
              let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.74)) {
            books[index].tier = target
        }
        // Any real move passes the drag phase, wherever it landed.
        WizardHaptics.success()
        withAnimation(.easeInOut(duration: 0.3)) {
            didDrag = true
        }
    }

    // MARK: Select phase

    private func enterSelection(_ book: TierPracticeBook) {
        guard phase == .select else { return }
        WizardHaptics.step()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            isSelecting = true
        }
        selected.insert(book.id)
    }

    private func toggle(_ book: TierPracticeBook) {
        WizardHaptics.selection()
        if selected.contains(book.id) {
            selected.remove(book.id)
        } else {
            selected.insert(book.id)
        }
    }

    private func performMove(to tier: String) {
        let count = selected.count
        withAnimation(.spring(response: 0.38, dampingFraction: 0.74)) {
            for index in books.indices where selected.contains(books[index].id) {
                books[index].tier = tier
            }
        }
        showMovePicker = false
        isSelecting = false
        selected = []
        WizardHaptics.success()
        withAnimation(.easeInOut(duration: 0.25)) {
            movedCount = max(movedCount, count)
        }
    }

    /// A quieter stand-in for the real TierSelectionActionBar: same shape and
    /// same actions, with only Move live inside the wizard.
    ///
    /// `live` false renders it as a picture of itself for the pro tip recap:
    /// nothing responds to touch and every icon comes up to full strength,
    /// because there the icons are the subject rather than the distraction.
    private func selectionBar(count: Int, live: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    isSelecting = false
                }
                selected = []
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done selecting")

            Text(count == 1 ? "1 book" : "\(count) books")
                .font(Theme.callout().weight(.semibold))
                .foregroundStyle(count == 0 ? Theme.textTertiary : Theme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 2)

            demoAction(label: "Remove from read shelf", dimmed: live) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.danger)
            }
            demoAction(label: "Change year read", dimmed: live) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            demoAction(label: "Fix covers", dimmed: live) {
                CoverRefreshGlyph(tint: Theme.textPrimary)
            }

            Button {
                WizardHaptics.step()
                showMovePicker = true
            } label: {
                Label("Move", systemImage: "arrow.up.arrow.down")
                    .fixedSize()
            }
            .buttonStyle(.spine(.primary, size: .small, fullWidth: false))
            .disabled(live && count < 2)
        }
        .allowsHitTesting(live)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .strokeBorder(Theme.chrome.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Theme.shadowInk.opacity(0.2), radius: 10, y: 4)
        // Once the pair is picked, Move is the only thing left to touch.
        .overlay(alignment: .topTrailing) {
            if live, count >= 2, !showMovePicker {
                TierPracticePointer(systemName: "arrow.down", horizontal: false)
                    .offset(x: -22, y: -30)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var actionBar: some View {
        selectionBar(count: selected.count, live: true)
    }

    /// Present in the bar for recognition, dimmed while something else is the
    /// lesson: the wizard teaches one action at a time.
    private func demoAction<Glyph: View>(
        label: String,
        dimmed: Bool,
        @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        glyph()
            .frame(width: 34, height: 34)
            .background(Circle().fill(Theme.surface))
            .opacity(dimmed ? 0.4 : 1)
            .accessibilityLabel(label)
            .accessibilityHidden(true)
    }

    // MARK: Pro tip recap

    /// The last beat keeps the menu on screen instead of describing it from
    /// memory: the bar the member just used, with each icon spelled out under
    /// it in the same circle it wears in the bar.
    private var proTipCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            selectionBar(count: 2, live: false)

            VStack(alignment: .leading, spacing: 14) {
                tipRow(label: "Change the year you read a book") {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                tipRow(label: "Take a book off your shelf") {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                }
                tipRow(label: "Regenerate a bad book cover") {
                    CoverRefreshGlyph(tint: Theme.textPrimary)
                }
            }
        }
        .padding(.top, 4)
        .transition(.opacity.combined(with: .offset(y: 12)))
    }

    private func tipRow<Glyph: View>(
        label: String,
        @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        HStack(spacing: 12) {
            glyph()
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.surface))
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Stands in for the app's "Move to tier" sheet, trimmed to the one choice
    /// this step is teaching. F wears the ring: it is where the duds belong.
    private var movePicker: some View {
        VStack(spacing: 16) {
            Text("Move \(selected.count) books to")
                .font(Theme.headline())
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 10) {
                ForEach(spineTierLabels, id: \.self) { tier in
                    Button {
                        performMove(to: tier)
                    } label: {
                        Text(tier)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.75))
                            .frame(width: 44, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(spineTierColor(for: tier))
                            )
                            .overlay {
                                if tier == "F" {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(
                                            Theme.textPrimary.opacity(hintPulsing && !reduceMotion ? 0.25 : 0.9),
                                            lineWidth: 2.5
                                        )
                                        .animation(
                                            reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                                            value: hintPulsing
                                        )
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Move to \(tier) tier")
                }
            }

            Text("Send them to F, where they belong.")
                .font(Theme.caption())
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        ZStack {
            switch phase {
            case .drag:
                hint("move the book to pass")
            case .select:
                if isSelecting {
                    actionBar
                } else {
                    hint("double tap a book to pass")
                }
            case .done:
                WizardCTAButton(title: "Got it") { model.advance() }
                    .transition(.opacity.combined(with: .offset(y: 10)))
            }
        }
        .frame(height: Self.footerHeight)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: isSelecting)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: movedCount)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .tracking(2.4)
            .textCase(.uppercase)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity)
    }
}
