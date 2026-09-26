//
//  ClubVoteFlowView.swift
//  SPINE
//
//  The group vote, start to finish, as one full-screen flow on the ink page:
//
//    picks    → "Pick time" → search → lock it in → "Your pick is in"
//    voting   → "The picks are in" → rank (drag) + optional veto → "Ballot cast"
//    revealed → "The votes are in" → runoff rounds play out → winner → done
//
//  It reads the live club doc, so a waiting page flips to the next phase the
//  moment the server moves it. Nothing here ever shows who suggested or ranked
//  what; the only member-level state is who has responded.
//

import SwiftUI

struct ClubVoteFlowView: View {
    let club: BookClub
    let myUid: String
    let onDone: () -> Void

    @EnvironmentObject var appState: AppState

    private enum Step: Equatable {
        case pickIntro
        case pickSearch
        case pickConfirm(Book)
        case pickDone
        case voteIntro
        case voteRank
        case voteDone
        case revealIntro
        case revealRunoff
        case revealWinner
        case revealDone
        case closed
    }

    @State private var step: Step = .closed
    @State private var busy = false
    @State private var error: String?
    /// Ballot state.
    @State private var order: [BookClub.Vote.Candidate] = []
    @State private var veto: String?
    /// Reveal choreography.
    @State private var roundIndex = -1
    @State private var eliminated: Set<String> = []
    @State private var runoffTask: Task<Void, Never>?
    @State private var winnerShown = false
    /// Preview mode has no server; these stand in for the doc moving.
    @State private var previewResponded = false

    private var vote: BookClub.Vote? { club.vote }
    private var isPreview: Bool { ClubsPreview.isActive }

    private var members: [(uid: String, member: BookClub.Member)] {
        club.orderedMemberIds.compactMap { uid in club.members[uid].map { (uid: uid, member: $0) } }
    }

    private var responded: Set<String> {
        guard let vote else { return [] }
        var set: Set<String>
        switch vote.phase {
        case .picks: set = Set(vote.respondedPickUids)
        case .voting: set = Set(vote.votedUids)
        case .revealed: set = Set(club.memberIds)
        }
        if previewResponded { set.insert(myUid) }
        return set
    }

    var body: some View {
        ZStack {
            BlendAuroraBackground(drift: true)
            page
                .id(stepKey)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 1.03)),
                    removal: .opacity
                ))
        }
        .animation(.snappy(duration: 0.4, extraBounce: 0.05), value: stepKey)
        .overlay(alignment: .topTrailing) { closeButton }
        // The tab bar's host sits under this cover; the winner's burst needs its own.
        .finishConfettiHost()
        .preferredColorScheme(.dark)
        .onAppear { step = initialStep() }
        .onChange(of: club.vote?.phase) { _, _ in advanceIfWaiting() }
        .onChange(of: club.vote?.id) { _, _ in advanceIfWaiting() }
        .onDisappear { runoffTask?.cancel() }
    }

    /// Enum with a payload can't drive `.id`; a stable string can.
    private var stepKey: String {
        switch step {
        case .pickIntro: return "pickIntro"
        case .pickSearch: return "pickSearch"
        case .pickConfirm(let book): return "pickConfirm-\(book.id)"
        case .pickDone: return "pickDone"
        case .voteIntro: return "voteIntro"
        case .voteRank: return "voteRank"
        case .voteDone: return "voteDone"
        case .revealIntro: return "revealIntro"
        case .revealRunoff: return "revealRunoff"
        case .revealWinner: return "revealWinner"
        case .revealDone: return "revealDone"
        case .closed: return "closed"
        }
    }

    private func initialStep() -> Step {
        guard let vote else { return .closed }
        switch vote.phase {
        case .picks: return vote.respondedPickUids.contains(myUid) ? .pickDone : .pickIntro
        case .voting: return vote.votedUids.contains(myUid) ? .voteDone : .voteIntro
        case .revealed: return .revealIntro
        }
    }

    /// The doc moved on while this member was on a waiting page (or mid-step in
    /// a phase that just closed): follow it.
    private func advanceIfWaiting() {
        guard let vote else {
            if step != .closed { step = .closed }
            return
        }
        switch (vote.phase, step) {
        case (.voting, .pickDone), (.voting, .pickIntro), (.voting, .pickSearch), (.voting, .pickConfirm):
            previewResponded = false
            step = vote.votedUids.contains(myUid) ? .voteDone : .voteIntro
        case (.revealed, .pickDone), (.revealed, .voteDone), (.revealed, .voteIntro), (.revealed, .voteRank), (.revealed, .pickIntro), (.revealed, .pickSearch), (.revealed, .pickConfirm):
            previewResponded = false
            step = .revealIntro
        default:
            break
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var page: some View {
        switch step {
        case .pickIntro: pickIntro
        case .pickSearch: pickSearch
        case .pickConfirm(let book): pickConfirm(book)
        case .pickDone: pickDone
        case .voteIntro: voteIntro
        case .voteRank: voteRank
        case .voteDone: voteDone
        case .revealIntro: revealIntro
        case .revealRunoff: revealRunoff
        case .revealWinner: revealWinner
        case .revealDone: revealDone
        case .closed: closedPage
        }
    }

    private var closeButton: some View {
        Button(action: finish) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.paperFixed.opacity(0.85))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.paperFixed.opacity(0.12)))
        }
        .buttonStyle(.springPress)
        .padding(.top, 14)
        .padding(.trailing, 18)
        .accessibilityLabel("Close")
        .opacity(step == .revealRunoff ? 0 : 1)
    }

    // MARK: Picks

    private var pickIntro: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            eyebrow("GROUP VOTE")
            Text("\(club.name) needs a book.")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Theme.paperFixed)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.top, 8)
            Text("Suggest one. Nobody sees whose it was.")
                .font(.system(size: 16))
                .foregroundStyle(Theme.paperFixed.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.top, 10)
            Spacer(minLength: 20)
            ClubVoteMemberCloud(members: members, done: responded)
            Spacer(minLength: 20)
            if let vote { ClubVoteCountdownPill(vote: vote).padding(.bottom, 18) }
            VStack(spacing: 10) {
                Button {
                    withAnimation(.snappy) { step = .pickSearch }
                } label: {
                    Label("Suggest a book", systemImage: "text.book.closed.fill")
                }
                .buttonStyle(.spinePrimary)
                quietButton("Sit this one out") { skipPick() }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            errorLine
        }
    }

    private var pickSearch: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                eyebrow("YOUR SUGGESTION")
                Text("What should the club read?")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.paperFixed)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 64)
            ClubVoteBookSearch(excludeBookIds: Set([club.currentPick?.bookId].compactMap { $0 })) { book in
                withAnimation(.snappy) { step = .pickConfirm(book) }
            }
        }
    }

    private func pickConfirm(_ book: Book) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            eyebrow("YOUR SUGGESTION")
            BookCoverView(book: book, size: 180)
                .shadow(color: Theme.inkFixed.opacity(0.6), radius: 24, y: 14)
                .padding(.top, 18)
            Text(book.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.paperFixed)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 32)
                .padding(.top, 20)
            Text(book.author)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.paperFixed.opacity(0.65))
                .padding(.top, 4)
            Spacer(minLength: 20)
            VStack(spacing: 10) {
                Button { submitPick(book) } label: {
                    if busy { ProgressView().tint(Theme.inkFixed) } else { Label("Lock it in", systemImage: "lock.fill") }
                }
                .buttonStyle(.spinePrimary)
                .disabled(busy)
                quietButton("Pick a different one") { withAnimation(.snappy) { step = .pickSearch } }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            errorLine
        }
    }

    private var pickDone: some View {
        waitingPage(
            stamp: "checkmark",
            title: "Your pick is in.",
            body: "We'll ping you when it's time to vote. Keep push notifications on.",
            footer: "\(responded.count) of \(club.memberIds.count) in"
        )
    }

    // MARK: Voting

    private var voteIntro: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                eyebrow("GROUP VOTE")
                Text("The picks are in.")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Theme.paperFixed)
                Text("\(vote?.candidates.count ?? 0) books. Rank them, top to bottom.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.paperFixed.opacity(0.7))
            }
            .padding(.top, 70)
            ClubVoteFloatingCovers(candidates: vote?.candidates ?? [])
                .frame(maxHeight: .infinity)
            if let vote { ClubVoteCountdownPill(vote: vote).padding(.bottom, 18) }
            VStack(spacing: 10) {
                Button {
                    order = vote?.candidates ?? []
                    veto = nil
                    withAnimation(.snappy) { step = .voteRank }
                } label: {
                    Label("Let's vote", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(.spinePrimary)
                quietButton("Skip voting") { skipBallot() }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            errorLine
        }
    }

    private var voteRank: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                eyebrow("YOUR BALLOT")
                Text("Rank them.")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.paperFixed)
                Text("Hold and drag. Top is your first choice.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.paperFixed.opacity(0.65))
            }
            .padding(.top, 62)
            .padding(.bottom, 14)
            ScrollView {
                ClubVoteRankList(order: $order, veto: $veto)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                Text(veto == nil
                     ? "The hand is a veto. Use it only if you'd sit the month out."
                     : "One veto per ballot. It counts against the book for everyone.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.paperFixed.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 14)
                    .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                Button { submitBallot() } label: {
                    if busy { ProgressView().tint(Theme.inkFixed) } else { Label("Cast my ballot", systemImage: "envelope.fill") }
                }
                .buttonStyle(.spinePrimary)
                .disabled(busy || order.filter { $0.id != veto }.isEmpty)
                errorLine
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .background(
                LinearGradient(colors: [Theme.inkFixed.opacity(0), Theme.inkFixed.opacity(0.9), Theme.inkFixed], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
        }
    }

    private var voteDone: some View {
        waitingPage(
            stamp: "envelope.fill",
            title: "Ballot cast.",
            body: "The winner drops the moment everyone's voted, or when the clock runs out.",
            footer: "\(responded.count) of \(club.memberIds.count) voted"
        )
    }

    // MARK: Reveal

    private var revealIntro: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                eyebrow("GROUP VOTE")
                Text("The votes are in.")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.paperFixed)
                Text(revealSubtitle)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.paperFixed.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.top, 70)
            ClubVoteFloatingCovers(candidates: vote?.candidates ?? [])
                .frame(maxHeight: .infinity)
            ClubVoteMemberCloud(members: members, done: Set(club.memberIds), size: 34)
                .padding(.bottom, 20)
            Button { startRunoff() } label: {
                Label("Count the votes", systemImage: "wand.and.stars")
            }
            .buttonStyle(.spinePrimary)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    private var revealSubtitle: String {
        guard let vote, let result = vote.result else { return "" }
        let books = "\(vote.candidates.count) \(vote.candidates.count == 1 ? "book" : "books")"
        if result.totalBallots == 0 { return "\(books). Nobody ranked, so fate did." }
        return "\(books). \(result.totalBallots) \(result.totalBallots == 1 ? "ballot" : "ballots"). One winner."
    }

    private var revealRunoff: some View {
        let candidates = vote?.candidates ?? []
        let rounds = vote?.result?.rounds ?? []
        let current = roundIndex >= 0 && roundIndex < rounds.count ? rounds[roundIndex] : nil
        let standing = candidates.filter { !eliminated.contains($0.id) && !(vote?.result?.vetoedCandidateIds.contains($0.id) ?? false) }
        return VStack(spacing: 0) {
            VStack(spacing: 6) {
                eyebrow(roundIndex < 0 ? "COUNTING" : "ROUND \(roundIndex + 1)")
                Text(roundCopy(current, standing: standing.count))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.paperFixed)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .contentTransition(.opacity)
            }
            .padding(.top, 70)
            Spacer(minLength: 0)
            runoffBoard(candidates: candidates, counts: current?.counts ?? [:])
            Spacer(minLength: 0)
        }
        .animation(.snappy(duration: 0.45, extraBounce: 0.1), value: roundIndex)
        .animation(.snappy(duration: 0.45, extraBounce: 0.1), value: eliminated)
    }

    private func roundCopy(_ round: BookClub.Vote.Round?, standing: Int) -> String {
        guard let round else { return "Tallying first choices…" }
        let total = round.counts.values.reduce(0, +)
        if let out = round.eliminatedCandidateId, let cand = vote?.candidate(out) {
            // The cover drops a beat after the count; the words wait for it.
            return eliminated.contains(out) ? "\(cand.title) is out." : "No majority yet."
        }
        if standing <= 1 { return "That settles it." }
        return total > 0 ? "\(total) first choices counted." : "Counting…"
    }

    private func runoffBoard(candidates: [BookClub.Vote.Candidate], counts: [String: Int]) -> some View {
        let vetoed = Set(vote?.result?.vetoedCandidateIds ?? [])
        let total = max(1, counts.values.reduce(0, +))
        let columns = [GridItem(.adaptive(minimum: 92), spacing: 14)]
        return LazyVGrid(columns: columns, spacing: 18) {
            ForEach(candidates) { cand in
                let out = eliminated.contains(cand.id) || vetoed.contains(cand.id)
                let n = counts[cand.id] ?? 0
                VStack(spacing: 8) {
                    BookCoverView(book: cand.asBook, size: 84)
                        .saturation(out ? 0 : 1)
                        .opacity(out ? 0.28 : 1)
                        .scaleEffect(out ? 0.86 : 1)
                        .overlay {
                            if vetoed.contains(cand.id) {
                                Text("VETOED")
                                    .font(.system(size: 10, weight: .heavy))
                                    .tracking(1)
                                    .foregroundStyle(Theme.paperFixed)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Theme.inkFixed.opacity(0.85)))
                                    .rotationEffect(.degrees(-12))
                            }
                        }
                    if !out && roundIndex >= 0 {
                        HStack(spacing: 3) {
                            ForEach(0..<n, id: \.self) { _ in
                                Circle().fill(Theme.paperFixed).frame(width: 7, height: 7)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .frame(height: 8)
                        .animation(.snappy(duration: 0.3, extraBounce: 0.2), value: n)
                        ClubProgressBar(fraction: Double(n) / Double(total), height: 4)
                            .frame(width: 70)
                            .colorScheme(.dark)
                    } else {
                        Color.clear.frame(width: 70, height: 16)
                    }
                }
                .frame(width: 92)
            }
        }
        .padding(.horizontal, 24)
    }

    private var revealWinner: some View {
        let winner = vote?.winner
        let runnerUp = vote?.runnerUp
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            eyebrow(vote?.result?.drawnByFate == true ? "DRAWN BY FATE" : "THE WINNER")
                .opacity(winnerShown ? 1 : 0)
            if let winner {
                BookCoverView(book: winner.asBook, size: 200)
                    .shadow(color: Theme.inkFixed.opacity(0.7), radius: 30, y: 16)
                    .scaleEffect(winnerShown ? 1 : 0.3)
                    .rotationEffect(.degrees(winnerShown ? 0 : -18))
                    .opacity(winnerShown ? 1 : 0)
                    .padding(.top, 16)
                    .background(
                        GeometryReader { geo in
                            Color.clear.onChange(of: winnerShown) { _, shown in
                                guard shown else { return }
                                let frame = geo.frame(in: .global)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    FinishConfettiCenter.shared.fire(from: CGPoint(x: frame.midX, y: frame.midY))
                                }
                            }
                        }
                    )
                Text(winner.title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.paperFixed)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .opacity(winnerShown ? 1 : 0)
                    .offset(y: winnerShown ? 0 : 14)
                Text(winner.author)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.paperFixed.opacity(0.7))
                    .padding(.top, 4)
                    .opacity(winnerShown ? 1 : 0)
            }
            if let runnerUp {
                HStack(spacing: 8) {
                    BookCoverView(book: runnerUp.asBook, size: 26)
                    Text("Runner-up: \(runnerUp.title)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.paperFixed.opacity(0.6))
                        .lineLimit(1)
                }
                .padding(.top, 18)
                .opacity(winnerShown ? 1 : 0)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.snappy) { step = .revealDone }
            } label: {
                Label("Love it", systemImage: "heart.fill")
            }
            .buttonStyle(.spinePrimary)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .opacity(winnerShown ? 1 : 0)
        }
        .animation(.snappy(duration: 0.8, extraBounce: 0.25), value: winnerShown)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                winnerShown = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private var revealDone: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let winner = vote?.winner {
                BookCoverView(book: winner.asBook, size: 110)
                    .shadow(color: Theme.inkFixed.opacity(0.6), radius: 20, y: 10)
            }
            Text("It's on everyone's Reading now.")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.paperFixed)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 22)
            Text(club.isAdmin(myUid)
                 ? "Set a meeting date from the club page so everyone reads toward it."
                 : "Your admin will set the meeting. Happy reading.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.paperFixed.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.top, 8)
            Spacer(minLength: 20)
            ClubVoteMemberCloud(members: members, done: Set(club.memberIds), size: 40)
                .padding(.bottom, 26)
            Button(action: finish) {
                Text("Done")
            }
            .buttonStyle(.spinePrimary)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    private var closedPage: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("This vote wrapped up.")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.paperFixed)
            Text("Head back to the club to see what's next.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.paperFixed.opacity(0.7))
            Spacer()
            Button("Back to the club", action: finish)
                .buttonStyle(.spinePrimary)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
        }
    }

    // MARK: - Shared bits

    private func waitingPage(stamp: String, title: String, body: String, footer: String) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(systemName: stamp)
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(Theme.inkFixed)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Theme.paperFixed))
                .transition(.scale.combined(with: .opacity))
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.paperFixed)
                .padding(.top, 20)
            Text(body)
                .font(.system(size: 15))
                .foregroundStyle(Theme.paperFixed.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.top, 8)
            Spacer(minLength: 20)
            ClubVoteMemberCloud(members: members, done: responded)
            HStack(spacing: 10) {
                Text(footer)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.paperFixed.opacity(0.7))
                if let vote, vote.isOpen { ClubVoteCountdownPill(vote: vote) }
            }
            .padding(.top, 22)
            Spacer(minLength: 20)
            Button("Done", action: finish)
                .buttonStyle(.spinePrimary)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(2.2)
            .foregroundStyle(Theme.paperFixed.opacity(0.6))
    }

    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.paperFixed.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.springPress)
        .disabled(busy)
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error {
            Text(error)
                .font(Theme.caption())
                .foregroundStyle(Theme.paperFixed.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 12)
        }
    }

    // MARK: - Actions

    private func run(_ work: @escaping () async throws -> Void, then next: Step) {
        error = nil
        if isPreview {
            previewResponded = true
            withAnimation(.snappy) { step = next }
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
                withAnimation(.snappy) { step = next }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func submitPick(_ book: Book) {
        guard let vote else { return }
        run({ try await BookClubService.shared.submitPick(clubId: club.id, roundId: vote.id, book: book) }, then: .pickDone)
    }

    private func skipPick() {
        guard let vote else { return }
        run({ try await BookClubService.shared.skipPick(clubId: club.id, roundId: vote.id) }, then: .pickDone)
    }

    private func submitBallot() {
        guard let vote else { return }
        let ranking = order.filter { $0.id != veto }.map(\.id)
        run({ try await BookClubService.shared.submitBallot(clubId: club.id, roundId: vote.id, ranking: ranking, veto: veto) }, then: .voteDone)
    }

    private func skipBallot() {
        guard let vote else { return }
        run({ try await BookClubService.shared.skipBallot(clubId: club.id, roundId: vote.id) }, then: .voteDone)
    }

    /// Plays the rounds one beat at a time, then hands off to the winner page.
    private func startRunoff() {
        roundIndex = -1
        eliminated = []
        winnerShown = false
        withAnimation(.snappy) { step = .revealRunoff }
        let rounds = vote?.result?.rounds ?? []
        runoffTask?.cancel()
        runoffTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            for (i, round) in rounds.enumerated() {
                if Task.isCancelled { return }
                roundIndex = i
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                if let out = round.eliminatedCandidateId {
                    eliminated.insert(out)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                }
            }
            if rounds.isEmpty { try? await Task.sleep(nanoseconds: 600_000_000) }
            if Task.isCancelled { return }
            withAnimation(.snappy) { step = .revealWinner }
        }
    }

    /// Leaving after the reveal records that this member has seen it, so the
    /// club page can show the book. Every other exit just closes.
    private func finish() {
        runoffTask?.cancel()
        if let vote, vote.phase == .revealed, (step == .revealDone || step == .revealWinner), !vote.hasSeenReveal(myUid), !isPreview {
            Task { try? await BookClubService.shared.ackReveal(clubId: club.id, roundId: vote.id) }
            ClubVoteRevealMemo.markSeen(clubId: club.id, roundId: vote.id)
        } else if isPreview, let vote, vote.phase == .revealed, step == .revealDone || step == .revealWinner {
            ClubVoteRevealMemo.markSeen(clubId: club.id, roundId: vote.id)
        }
        onDone()
    }
}

/// Local echo of "I watched the reveal", so the club page unhides the book the
/// instant the flow closes instead of waiting on the callable's round trip.
enum ClubVoteRevealMemo {
    private static let key = "clubVoteRevealsSeen"

    static func hasSeen(clubId: String, roundId: String) -> Bool {
        let seen = UserDefaults.standard.stringArray(forKey: key) ?? []
        return seen.contains("\(clubId)|\(roundId)")
    }

    static func markSeen(clubId: String, roundId: String) {
        var seen = UserDefaults.standard.stringArray(forKey: key) ?? []
        seen.append("\(clubId)|\(roundId)")
        UserDefaults.standard.set(Array(seen.suffix(40)), forKey: key)
    }
}
