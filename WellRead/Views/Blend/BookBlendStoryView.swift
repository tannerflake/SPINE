//
//  BookBlendStoryView.swift
//  Spine
//
//  The Book Blend story: full-bleed auto-advancing pages (Wrapped-style) built
//  from the stored blend result — score reveal, archetype, one rating-reveal
//  slide per shared book (did you agree?), taste map, insights, shelf-steal
//  recs, fresh picks, outro. Hold to pause, tap the edges to scrub, swipe down
//  to leave. Rewatch is just replaying the doc.
//

import SwiftUI

struct BookBlendStoryView: View {
    let blend: BookBlend
    let myUid: String
    let onDismiss: () -> Void

    @EnvironmentObject var appState: AppState

    private enum Page {
        case intro
        case score
        case archetype
        case sharedIntro
        case bookReveal(Int)
        case insight(BookBlend.Insight)
        case recs(uid: String)
        case freshPicks
        case outro
    }

    @State private var pageIndex = 0
    @State private var pageProgress: Double = 0
    @State private var paused = false
    @State private var pressStarted: Date?
    /// Live offset while the user pulls the story downward — the whole story
    /// follows the finger, then dismisses or springs back on release.
    @State private var dismissDrag: CGFloat = 0
    /// Score page count-up.
    @State private var displayedScore = 0
    @State private var scoreRevealToken = 0
    /// Recs queued from this story (by rec key) — instant button flip, and the only
    /// signal for AI recs with no bookId to match against the queue.
    @State private var queuedRecKeys: Set<String> = []

    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private var result: BookBlend.Result? { blend.result }
    private var otherUid: String { blend.otherUserId(from: myUid) }
    private var myName: String { blend.participants[myUid]?.firstName ?? "You" }
    private var otherName: String { blend.participants[otherUid]?.firstName ?? "Them" }

    private var pages: [Page] {
        guard let result else { return [.outro] }
        var list: [Page] = [.intro, .score, .archetype]
        if !result.sharedBooks.isEmpty {
            list.append(.sharedIntro)
            for i in result.sharedBooks.indices { list.append(.bookReveal(i)) }
        }
        for insight in result.insights.prefix(2) { list.append(.insight(insight)) }
        // One slide per direction: all of a reader's picks together.
        if !(result.recs[myUid] ?? []).isEmpty { list.append(.recs(uid: myUid)) }
        if !(result.recs[otherUid] ?? []).isEmpty { list.append(.recs(uid: otherUid)) }
        if !result.freshPicks.isEmpty { list.append(.freshPicks) }
        list.append(.outro)
        return list
    }

    private var pageDuration: Double {
        switch pages[pageIndex] {
        case .score: return 8.5
        case .sharedIntro: return 4.0
        // Quick beats: cover in, my verdict, their verdict, agree/clash stamp.
        case .bookReveal: return 4.4
        // Three titles to skim (and Add to Queue to hit on my page).
        case .recs: return 8.0
        default: return 7.0
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                BlendAuroraBackground(drift: true)
                    .hueRotation(.degrees(Double(pageIndex) * 16))
                    .animation(.easeInOut(duration: 0.8), value: pageIndex)

                pageView(pages[pageIndex])
                    .id(pageIndex)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 1.03)),
                        removal: .opacity
                    ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 0) {
                    progressBars
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    HStack {
                        Text("\(myName) × \(otherName)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.paperFixed.opacity(0.7))
                        Spacer()
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.paperFixed.opacity(0.85))
                                .padding(9)
                                .background(Circle().fill(.white.opacity(0.14)))
                        }
                        .buttonStyle(.springPress)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    Spacer()
                }
            }
            .contentShape(Rectangle())
            .offset(y: dismissDrag)
            .gesture(storyGesture(width: geo.size.width))
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .sensoryFeedback(.impact(weight: .light), trigger: pageIndex)
        .onReceive(tick) { _ in
            guard !paused else { return }
            pageProgress += (1.0 / 30.0) / pageDuration
            if pageProgress >= 1 { advance() }
        }
        .onChange(of: pageIndex) { _, _ in
            if case .score = pages[pageIndex] { startScoreReveal() }
        }
    }

    // MARK: Mechanics

    /// One gesture does it all: press-and-hold pauses, a quick release taps
    /// (left third = back, rest = forward), a downward pull tracks the finger
    /// and dismisses when released past the threshold (or flicked).
    private func storyGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pressStarted == nil { pressStarted = Date() }
                paused = true
                let h = value.translation.height
                // Follow a downward-dominant pull; ignore horizontal scrubs.
                if dismissDrag > 0 || (h > 10 && h > abs(value.translation.width)) {
                    dismissDrag = max(0, h)
                }
            }
            .onEnded { value in
                defer {
                    paused = false
                    pressStarted = nil
                }
                if value.translation.height > 90 || value.predictedEndTranslation.height > 220 {
                    onDismiss()
                    return
                }
                if dismissDrag != 0 {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        dismissDrag = 0
                    }
                }
                let held = pressStarted.map { Date().timeIntervalSince($0) } ?? 0
                let moved = hypot(value.translation.width, value.translation.height)
                guard held < 0.35, moved < 24 else { return }
                if value.location.x < width / 3 {
                    goBack()
                } else {
                    advance()
                }
            }
    }

    private func advance() {
        if pageIndex >= pages.count - 1 {
            onDismiss()
            return
        }
        // Reset progress before the page switch: the incoming page's reveal
        // beats key off pageProgress, and flipping pageIndex first lets it
        // render one frame at the old page's ~1.0 (fully-revealed ghost flash).
        pageProgress = 0
        withAnimation(.easeOut(duration: 0.3)) {
            pageIndex += 1
        }
    }

    private func goBack() {
        pageProgress = 0
        if pageIndex == 0 { return }
        withAnimation(.easeOut(duration: 0.3)) {
            pageIndex -= 1
        }
    }

    private var progressBars: some View {
        HStack(spacing: 4) {
            ForEach(pages.indices, id: \.self) { i in
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule()
                            .fill(Theme.paperFixed)
                            .frame(width: g.size.width * segmentFill(i))
                    }
                }
                .frame(height: 3)
            }
        }
    }

    private func segmentFill(_ i: Int) -> CGFloat {
        if i < pageIndex { return 1 }
        if i > pageIndex { return 0 }
        return CGFloat(min(1, max(0, pageProgress)))
    }

    private func startScoreReveal() {
        guard let target = result?.score else { return }
        scoreRevealToken += 1
        let token = scoreRevealToken
        displayedScore = 0
        Task { @MainActor in
            // Ease-out count-up: fast start, landing softly on the number.
            let steps = 45
            for step in 1...steps {
                guard token == scoreRevealToken else { return }
                let t = Double(step) / Double(steps)
                displayedScore = Int((1 - pow(1 - t, 3)) * Double(target))
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
            displayedScore = target
        }
    }

    // MARK: Pages

    @ViewBuilder
    private func pageView(_ page: Page) -> some View {
        switch page {
        case .intro: introPage
        case .score: scorePage
        case .archetype: archetypePage
        case .sharedIntro: sharedIntroPage
        case .bookReveal(let index): bookRevealPage(index)
        case .insight(let insight): insightPage(insight)
        case .recs(let uid): recsPage(uid: uid)
        case .freshPicks: freshPicksPage
        case .outro: outroPage
        }
    }

    private var introPage: some View {
        VStack(spacing: 24) {
            Spacer()
            BlendAvatarLockup(
                leftURL: blend.participants[myUid]?.photoURL,
                rightURL: blend.participants[otherUid]?.photoURL,
                leftName: myName,
                rightName: otherName,
                size: 96
            )
            VStack(spacing: 8) {
                Text("BOOK BLEND")
                    .font(.system(size: 14, weight: .heavy))
                    .tracking(5)
                    .foregroundStyle(Theme.paperFixed.opacity(0.7))
                Text("\(myName) × \(otherName)")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.paperFixed)
                if let count = mergedBookCount {
                    Text("\(count) books, two shelves, one verdict.")
                        .font(Theme.callout())
                        .foregroundStyle(Theme.paperFixed.opacity(0.7))
                }
            }
            Spacer()
            Text("Tap to begin")
                .font(Theme.caption())
                .foregroundStyle(Theme.paperFixed.opacity(0.5))
                .padding(.bottom, 40)
        }
    }

    private var mergedBookCount: Int? {
        let a = blend.participants[myUid]?.readCount ?? 0
        let b = blend.participants[otherUid]?.readCount ?? 0
        return a + b > 0 ? a + b : nil
    }

    private var scorePage: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("Your taste match")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.paperFixed.opacity(0.75))
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: CGFloat(displayedScore) / 100)
                    .stroke(
                        AngularGradient(
                            colors: [Theme.paperFixed.opacity(0.55), Theme.paperFixed, Theme.paperFixed.opacity(0.55)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text("\(displayedScore)%")
                    .font(.system(size: 72, weight: .heavy))
                    .foregroundStyle(Theme.paperFixed)
                    .contentTransition(.numericText(value: Double(displayedScore)))
            }
            .frame(width: 230, height: 230)
            if let verdict = result?.verdict {
                Text(verdict)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.paperFixed)
                    .opacity(displayedScore == result?.score ? 1 : 0)
                    .animation(.easeIn(duration: 0.4), value: displayedScore)
            }
            Spacer()
        }
        .onAppear { startScoreReveal() }
    }

    private var archetypePage: some View {
        VStack(spacing: 18) {
            Spacer()
            Text(result?.archetypeEmoji ?? "📚")
                .font(.system(size: 72))
            Text("You two are")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.paperFixed.opacity(0.75))
            Text(result?.archetype ?? "")
                .font(.system(size: 38, weight: .heavy))
                .multilineTextAlignment(.center)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.paperFixed, Theme.paperFixed.opacity(0.75)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .padding(.horizontal, 28)
            Text(result?.tagline ?? "")
                .font(Theme.body())
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.paperFixed.opacity(0.8))
                .padding(.horizontal, 44)
            Spacer()
        }
    }

    private var sharedIntroPage: some View {
        let count = result?.sharedBooks.count ?? 0
        return VStack(spacing: 24) {
            Spacer()
            BlendAvatarLockup(
                leftURL: blend.participants[myUid]?.photoURL,
                rightURL: blend.participants[otherUid]?.photoURL,
                leftName: myName,
                rightName: otherName,
                size: 84
            )
            pageHeader("You've both read", big: "\(count) of the same \(count == 1 ? "book" : "books")", centered: true)
            Text("Let's see if you agreed.")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.paperFixed.opacity(0.75))
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func bookRevealPage(_ index: Int) -> some View {
        let books = result?.sharedBooks ?? []
        let book = books[min(index, max(0, books.count - 1))]
        return BlendBookRevealPage(
            book: book,
            coverBook: bookFor(shared: book),
            index: index,
            total: books.count,
            myUid: myUid,
            otherUid: otherUid,
            myName: myName,
            otherName: otherName,
            myPhotoURL: blend.participants[myUid]?.photoURL,
            otherPhotoURL: blend.participants[otherUid]?.photoURL,
            progress: pageProgress
        )
    }

    private func insightPage(_ insight: BookBlend.Insight) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "quote.opening")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.punch)
            Text(insight.title)
                .font(.system(size: 30, weight: .heavy))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.paperFixed)
                .padding(.horizontal, 30)
            Text(insight.body)
                .font(.system(size: 18, weight: .medium))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .foregroundStyle(Theme.paperFixed.opacity(0.85))
                .padding(.horizontal, 36)
            Spacer()
        }
    }

    /// All of one reader's picks on a single slide — quick rows that land one
    /// by one. The header names whose shelf they came from, and the AI reasons
    /// stay off-screen entirely (better gone than truncated).
    private func recsPage(uid: String) -> some View {
        let recs = Array((result?.recs[uid] ?? []).prefix(3))
        let isMine = uid == myUid
        let shelfOwner = isMine ? otherName : myName
        return VStack(spacing: 0) {
            Spacer(minLength: 86)
            Spacer()
            VStack(spacing: 6) {
                Text((isMine ? "Picked for you, \(myName)" : "Picked for \(otherName)").uppercased())
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(Theme.paperFixed.opacity(0.55))
                Text(recs.count == 1 ? "A book off \(shelfOwner)'s shelf" : "\(recs.count) books off \(shelfOwner)'s shelf")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.paperFixed)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            VStack(spacing: 12) {
                ForEach(Array(recs.enumerated()), id: \.offset) { i, rec in
                    recRow(rec, isMine: isMine, shelfOwner: shelfOwner, revealed: pageProgress > 0.06 + Double(i) * 0.13)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 30)
            Spacer()
            Spacer(minLength: 44)
        }
        .sensoryFeedback(.success, trigger: queuedRecKeys)
        .sensoryFeedback(.impact(weight: .light), trigger: recs.indices.filter { pageProgress > 0.06 + Double($0) * 0.13 }.count)
    }

    private func recRow(_ rec: BookBlend.Rec, isMine: Bool, shelfOwner: String, revealed: Bool) -> some View {
        HStack(spacing: 14) {
            BookCoverView(book: bookFor(rec: rec), size: 64)
                .shadow(color: Theme.shadowInk.opacity(0.4), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(rec.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.paperFixed)
                    .lineLimit(2)
                Text(rec.author)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.paperFixed.opacity(0.65))
                    .lineLimit(1)
                if let tier = shelfTier(rec) {
                    HStack(spacing: 6) {
                        TierBadge(tier: tier, size: .mini)
                        Text("\(shelfOwner)'s rank")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.paperFixed.opacity(0.55))
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            if isMine {
                addToQueueButton(for: rec)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.white.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        )
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 24)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: revealed)
    }

    /// The tier the shelf owner gave this pick. Stored on the rec since the blend
    /// was generated; for picks off my own shelf, my live library entry wins so
    /// blends generated before `sourceTier` existed still show a badge.
    private func shelfTier(_ rec: BookBlend.Rec) -> String? {
        var tier = rec.sourceTier
        if rec.sourceUid == myUid,
           let live = appState.userBook(sameWorkAs: bookFor(rec: rec), status: .read)?.normalizedTier {
            tier = live
        }
        return tier.flatMap { spineTierLabels.contains($0) ? $0 : nil }
    }

    // MARK: Steal-page queueing

    private func addToQueueButton(for rec: BookBlend.Rec) -> some View {
        let queued = isRecQueued(rec)
        return Button {
            addRecToQueue(rec)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: queued ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .heavy))
                Text(queued ? "Queued" : "Queue")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(queued ? Theme.paperFixed.opacity(0.75) : Theme.inkFixed)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(queued ? AnyShapeStyle(.white.opacity(0.14)) : AnyShapeStyle(Theme.paperFixed)))
        }
        .buttonStyle(.springPress)
        .disabled(queued)
    }

    /// Compact circular plus on the fresh-picks slide — same queueing path as the
    /// steal pages, flipping to a check once the book is in the queue.
    private func queuePlusButton(for rec: BookBlend.Rec) -> some View {
        let queued = isRecQueued(rec)
        return Button {
            addRecToQueue(rec)
        } label: {
            Image(systemName: queued ? "checkmark" : "plus")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(queued ? Theme.paperFixed : Theme.inkFixed)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(queued ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(Theme.paperFixed))
                        .overlay(Circle().strokeBorder(Theme.inkFixed.opacity(0.25), lineWidth: 1))
                )
                .shadow(color: Theme.shadowInk.opacity(0.4), radius: 6, y: 3)
        }
        .buttonStyle(.springPress)
        .disabled(queued)
        .accessibilityLabel(queued ? "\(rec.title) is in your queue" : "Add \(rec.title) to your queue")
    }

    private func recKey(_ rec: BookBlend.Rec) -> String {
        rec.bookId ?? "\(rec.title)|\(rec.author)"
    }

    private func isRecQueued(_ rec: BookBlend.Rec) -> Bool {
        if queuedRecKeys.contains(recKey(rec)) { return true }
        if let bookId = rec.bookId { return appState.isBookInQueue(bookId: bookId) }
        return false
    }

    private func addRecToQueue(_ rec: BookBlend.Rec) {
        guard !isRecQueued(rec) else { return }
        withAnimation(.spring(duration: 0.3)) {
            _ = queuedRecKeys.insert(recKey(rec))
        }
        if rec.bookId != nil {
            appState.addToWantToRead(book: bookFor(rec: rec))
        } else {
            // AI recs the blend couldn't hydrate: resolve on Google Books so the queue
            // entry carries a real book id + cover; unmatched falls back to title-only.
            Task {
                let match = (try? await GoogleBooksService.shared.search(query: "\(rec.title) \(rec.author)", searchAuthors: false))?.first
                let book = match ?? bookFor(rec: rec)
                await MainActor.run { appState.addToWantToRead(book: book) }
            }
        }
    }

    private var freshPicksPage: some View {
        let picks = result?.freshPicks ?? []
        return VStack(alignment: .center, spacing: 20) {
            Spacer(minLength: 70)
            pageHeader("Neither of you has read", big: "Your next reads, together", centered: true)
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(picks.prefix(2).enumerated()), id: \.offset) { _, pick in
                    VStack(spacing: 8) {
                        BookCoverView(book: bookFor(rec: pick), size: 92)
                            .overlay(alignment: .bottomTrailing) {
                                queuePlusButton(for: pick)
                                    .padding(5)
                            }
                        Text(pick.title)
                            .font(.system(size: 15, weight: .bold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.paperFixed)
                            .lineLimit(2)
                        Text(pick.reason)
                            .font(.system(size: 12, weight: .regular))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.paperFixed.opacity(0.75))
                            .lineLimit(4)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 24)
            Spacer()
        }
        .sensoryFeedback(.success, trigger: queuedRecKeys)
    }

    private var outroPage: some View {
        VStack(spacing: 16) {
            Spacer()
            if let result {
                Text("\(result.score)%")
                    .font(.system(size: 52, weight: .heavy))
                    .foregroundStyle(Theme.paperFixed)
                Text("\(result.archetypeEmoji) \(result.archetype)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.paperFixed.opacity(0.9))
            }
            Text("Saved for both of you. Rewatch it anytime from \(otherName)'s profile.")
                .font(Theme.callout())
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.paperFixed.opacity(0.7))
                .padding(.horizontal, 44)
            Spacer()
            Button(action: onDismiss) {
                Text("Done")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.onChrome)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .glossyProminent(Theme.accent, cornerRadius: 28)
            .buttonStyle(.springPress)
            .padding(.horizontal, 28)
            .padding(.bottom, 34)
        }
    }

    private func pageHeader(_ small: String, big: String, centered: Bool = false) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            Text(small.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .tracking(2)
                .foregroundStyle(Theme.paperFixed.opacity(0.6))
            Text(big)
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(Theme.paperFixed)
                .multilineTextAlignment(centered ? .center : .leading)
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    // MARK: Book adapters (covers ride the shared BookCoverView pipeline)

    private func bookFor(shared: BookBlend.SharedBook) -> Book {
        Book(id: shared.bookId, title: shared.title, author: shared.author, coverURL: shared.coverURL, pageCount: nil, publishedDate: nil, description: nil, genres: [])
    }

    private func bookFor(rec: BookBlend.Rec) -> Book {
        Book(id: rec.bookId ?? UUID().uuidString, title: rec.title, author: rec.author, coverURL: rec.coverURL ?? "", pageCount: nil, publishedDate: nil, description: nil, genres: [])
    }
}

// MARK: - Per-book rating reveal

/// One shared book, one slide: the cover pops in over the two readers, then each
/// verdict flips from "?" in turn — mine, then theirs — and an AGREED! /
/// HARD DISAGREE stamp lands when the pair calls for one. Reveal beats key off
/// the story's page progress, so hold-to-pause freezes mid-reveal and tapping
/// forward skips the wait.
private struct BlendBookRevealPage: View {
    let book: BookBlend.SharedBook
    let coverBook: Book
    let index: Int
    let total: Int
    let myUid: String
    let otherUid: String
    let myName: String
    let otherName: String
    let myPhotoURL: String?
    let otherPhotoURL: String?
    let progress: Double

    private var showCover: Bool { progress > 0.03 }
    private var showMine: Bool { progress > 0.22 }
    private var showTheirs: Bool { progress > 0.50 }
    private var showStamp: Bool { progress > 0.72 }

    private enum Stamp { case agreed, hardDisagree }

    /// Tier-vs-tier only — numeric ratings never enter the reveal. Same tier =
    /// agreed; three or more rungs apart on the S–F ladder = hard disagree.
    private var stamp: Stamp? {
        guard let mine = book.tiers[myUid].flatMap({ spineTierLabels.firstIndex(of: $0) }),
              let theirs = book.tiers[otherUid].flatMap({ spineTierLabels.firstIndex(of: $0) }) else { return nil }
        if mine == theirs { return .agreed }
        if abs(mine - theirs) >= 3 { return .hardDisagree }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 86)
            Text("BOOK \(index + 1) OF \(total)")
                .font(.system(size: 11, weight: .heavy))
                .tracking(2)
                .foregroundStyle(Theme.paperFixed.opacity(0.55))
            Spacer()
            VStack(spacing: 16) {
                BookCoverView(book: coverBook, size: 170)
                    .shadow(color: Theme.shadowInk.opacity(0.5), radius: 18, y: 10)
                VStack(spacing: 3) {
                    Text(book.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.paperFixed)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(book.author)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.paperFixed.opacity(0.65))
                        .lineLimit(1)
                }
                .padding(.horizontal, 32)
            }
            .opacity(showCover ? 1 : 0)
            .scaleEffect(showCover ? 1 : 0.7)
            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: showCover)
            Spacer()
            HStack(alignment: .top, spacing: 0) {
                readerColumn(name: myName, photoURL: myPhotoURL, uid: myUid, revealed: showMine)
                Text("vs")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Theme.paperFixed.opacity(0.45))
                    .padding(.top, 24)
                readerColumn(name: otherName, photoURL: otherPhotoURL, uid: otherUid, revealed: showTheirs)
            }
            .padding(.horizontal, 28)
            .overlay { stampView }
            Spacer()
            Spacer(minLength: 40)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: showMine)
        .sensoryFeedback(.impact(weight: .medium), trigger: showTheirs)
        .sensoryFeedback(stamp == .agreed ? .success : .impact(weight: .heavy), trigger: showStamp && stamp != nil)
    }

    private func readerColumn(name: String, photoURL: String?, uid: String, revealed: Bool) -> some View {
        VStack(spacing: 10) {
            BlendAvatar(urlString: photoURL, name: name, size: 64)
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.paperFixed.opacity(0.8))
                .lineLimit(1)
            ZStack {
                Text("?")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(Theme.paperFixed.opacity(0.55))
                    .frame(width: 54, height: 54)
                    .background(RoundedRectangle(cornerRadius: 13).fill(.white.opacity(0.12)))
                    .opacity(revealed ? 0 : 1)
                    .scaleEffect(revealed ? 0.5 : 1)
                verdictBadge(uid: uid)
                    .opacity(revealed ? 1 : 0)
                    .scaleEffect(revealed ? 1 : 1.7)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.62), value: revealed)
        }
        .frame(maxWidth: .infinity)
    }

    /// Tier badge only — numeric ratings are deliberately never shown here.
    @ViewBuilder
    private func verdictBadge(uid: String) -> some View {
        if let tier = book.tiers[uid] {
            Text(tier)
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(Color.black.opacity(0.78))
                .frame(width: 54, height: 54)
                .background(RoundedRectangle(cornerRadius: 13).fill(spineTierColor(for: tier)))
                .shadow(color: Theme.shadowInk.opacity(0.4), radius: 8, y: 4)
        } else {
            Text("Read it")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.paperFixed)
                .padding(.horizontal, 13)
                .padding(.vertical, 13)
                .background(Capsule().fill(.white.opacity(0.16)))
        }
    }

    @ViewBuilder
    private var stampView: some View {
        let visible = showStamp && stamp != nil
        Group {
            switch stamp {
            case .agreed:
                Text("AGREED!")
                    .font(.system(size: 24, weight: .heavy))
                    .tracking(1.5)
                    .foregroundStyle(Theme.inkFixed)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Theme.paperFixed))
                    .rotationEffect(.degrees(-7))
            case .hardDisagree:
                HStack(spacing: 7) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16, weight: .heavy))
                    Text("HARD DISAGREE")
                        .font(.system(size: 18, weight: .heavy))
                        .tracking(1.2)
                }
                .foregroundStyle(Theme.paperFixed)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(Theme.inkFixed)
                        .overlay(Capsule().strokeBorder(Theme.paperFixed, lineWidth: 2))
                )
                .rotationEffect(.degrees(5))
            case nil:
                EmptyView()
            }
        }
        .shadow(color: Theme.shadowInk.opacity(0.45), radius: 10, y: 5)
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 2.1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: visible)
        .offset(y: -34)
        .allowsHitTesting(false)
    }
}

// MARK: - Taste map

#if DEBUG
extension BookBlend {
    /// Demo blend for `-uiPreviewBlend` simulator runs — exercises every story page.
    static var uiPreviewDemo: BookBlend {
        let me = "ui-preview", them = "demo-friend"
        return BookBlend(
            id: pairId(me, them),
            userIds: [me, them].sorted(),
            requesterId: them,
            recipientId: me,
            status: .ready,
            createdAt: Date(),
            respondedAt: Date(),
            participants: [
                me: Participant(firstName: "Tanner", photoURL: nil, readCount: 42),
                them: Participant(firstName: "Alex", photoURL: nil, readCount: 57),
            ],
            result: Result(
                score: 84,
                verdict: "Same Chapter",
                archetype: "The Plot Twisters",
                archetypeEmoji: "🌀",
                tagline: "You read for the moment the floor drops out.",
                // Ratings stay populated to prove the reveal never displays them —
                // slides are tier-only. Book 4 = tier hard disagree; book 6 = one
                // side untier'd ("Read it").
                sharedBooks: [
                    SharedBook(bookId: "1", title: "Project Hail Mary", author: "Andy Weir", coverURL: "", ratings: [me: 9.4, them: 9.0], tiers: [me: "S", them: "S"]),
                    SharedBook(bookId: "2", title: "Educated", author: "Tara Westover", coverURL: "", ratings: [them: 8.6], tiers: [me: "A", them: "B"]),
                    SharedBook(bookId: "3", title: "The Martian", author: "Andy Weir", coverURL: "", ratings: [me: 8.8, them: 7.9], tiers: [me: "B", them: "A"]),
                    SharedBook(bookId: "4", title: "Atomic Habits", author: "James Clear", coverURL: "", ratings: [me: 3.9], tiers: [me: "F", them: "B"]),
                    SharedBook(bookId: "5", title: "Dune", author: "Frank Herbert", coverURL: "", ratings: [me: 9.9, them: 9.5], tiers: [me: "S", them: "S"]),
                    SharedBook(bookId: "6", title: "The Midnight Library", author: "Matt Haig", coverURL: "", ratings: [them: 8.1], tiers: [me: "B"]),
                    SharedBook(bookId: "7", title: "Sapiens", author: "Yuval Noah Harari", coverURL: "", ratings: [me: 8.4, them: 9.1], tiers: [me: "A", them: "S"]),
                    SharedBook(bookId: "8", title: "The Name of the Wind", author: "Patrick Rothfuss", coverURL: "", ratings: [me: 9.2], tiers: [me: "S", them: "S"]),
                ],
                sharedGenres: ["Science Fiction", "Memoir", "Psychology"],
                distinctGenres: [me: ["History", "Economics"], them: ["Literary Fiction", "Horror"]],
                insights: [
                    Insight(title: "Weir believers", body: "Andy Weir is your load-bearing author. You both rated him a 9 or better, twice."),
                    Insight(title: "Rating twins", body: "When you both read a book, your scores land within half a point. Suspiciously in sync."),
                ],
                recs: [
                    me: [
                        Rec(title: "The Secret History", author: "Donna Tartt", bookId: nil, coverURL: nil, reason: "Alex's highest-rated fiction: dark academia you'd devour.", sourceUid: them, sourceTier: "S"),
                        Rec(title: "Mexican Gothic", author: "Silvia Moreno-Garcia", bookId: nil, coverURL: nil, reason: "The horror gateway Alex swears by.", sourceUid: them, sourceTier: "A"),
                    ],
                    them: [
                        Rec(title: "Basic Economics", author: "Thomas Sowell", bookId: nil, coverURL: nil, reason: "Tanner's A-tier: the nonfiction spine of his shelf.", sourceUid: me, sourceTier: "A"),
                        Rec(title: "Endurance", author: "Alfred Lansing", bookId: nil, coverURL: nil, reason: "Survival stakes with none of the fiction.", sourceUid: me, sourceTier: "B"),
                    ],
                ],
                freshPicks: [
                    Rec(title: "Piranesi", author: "Susanna Clarke", bookId: nil, coverURL: nil, reason: "A puzzle-box world for two plot twisters.", sourceUid: nil),
                    Rec(title: "Recursion", author: "Blake Crouch", bookId: nil, coverURL: nil, reason: "Sci-fi that rewrites itself: buddy-read bait.", sourceUid: nil),
                ],
                generatedAt: Date(),
                generatedBy: me
            )
        )
    }
}
#endif
