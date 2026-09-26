//
//  ClubVoteComponents.swift
//  SPINE
//
//  Pieces of the group-vote flow: the member cloud that ticks off as people
//  respond, drifting candidate covers, the countdown pill, the drag-to-rank
//  ballot, the in-flow book search, and the status card the club page shows
//  while a vote is running. The flow itself forces the dark scheme (ink page,
//  paper text) so every Theme token and SpineButtonStyle reads correctly on it.
//

import SwiftUI

// MARK: - Preview flag

extension ClubsPreview {
    /// `-uiPreviewClubVote <picks|picked|voting|voted|reveal|revealed>`: the demo
    /// club with a vote in that state, so every page of the flow can be opened
    /// without Firestore.
    static var voteState: BookClub.Vote.DemoState? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uiPreviewClubVote"), i + 1 < args.count else { return nil }
        return BookClub.Vote.DemoState(rawValue: args[i + 1])
        #else
        return nil
        #endif
    }

    /// The demo club with the requested vote grafted on. The reveal states swap
    /// the current pick for the winner (the way finalize does on the server).
    static func demoClubWithVote(_ base: BookClub) -> BookClub {
        guard let state = voteState else { return base }
        var club = base
        club.vote = .demo(state, me: "ui-preview", members: base.memberIds)
        if state == .reveal || state == .revealed, let winner = club.vote?.winner {
            var history = club.pastPicks
            if let outgoing = club.currentPick { history.insert(outgoing, at: 0) }
            club.pastPicks = history
            club.currentPick = BookClub.Pick(
                id: "pick-demo-vote",
                bookId: winner.bookId,
                title: winner.title,
                author: winner.author,
                coverURL: winner.coverURL,
                pageCount: winner.pageCount,
                chosenAt: Date().addingTimeInterval(-600),
                chosenBy: nil,
                meetingAt: nil,
                chosenVia: "vote"
            )
        }
        return club
    }
}

// MARK: - Member cloud

/// Every member's avatar in a loose, gently drifting cluster. Members in
/// `done` are bright with a check; the rest wait, dimmed. Reads as "3 of 5 are
/// in" without a single word.
struct ClubVoteMemberCloud: View {
    let members: [(uid: String, member: BookClub.Member)]
    let done: Set<String>
    var size: CGFloat = 52
    var drift: Bool = true

    var body: some View {
        let count = members.count
        let columns = min(count, count <= 4 ? count : (count <= 9 ? 3 : 4))
        let rows = Int(ceil(Double(count) / Double(max(1, columns))))
        let cell = size * 1.45
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !drift)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(members.enumerated()), id: \.element.uid) { index, entry in
                    let col = index % max(1, columns)
                    let row = index / max(1, columns)
                    let inLastRow = row == rows - 1
                    let lastRowCount = count - (rows - 1) * columns
                    let rowWidth = CGFloat(inLastRow ? lastRowCount : columns) * cell
                    let x = CGFloat(col) * cell - rowWidth / 2 + cell / 2
                    let y = CGFloat(row) * cell - CGFloat(rows) * cell / 2 + cell / 2
                    let phase = Double(index) * 1.7
                    let dx = drift ? CGFloat(sin(t * 0.9 + phase)) * 4 : 0
                    let dy = drift ? CGFloat(cos(t * 0.7 + phase * 1.3)) * 5 : 0
                    let isDone = done.contains(entry.uid)
                    ZStack(alignment: .bottomTrailing) {
                        UserAvatarView(
                            urlString: entry.member.photoURL,
                            displayName: entry.member.displayName,
                            firstName: entry.member.firstName,
                            lastName: nil,
                            size: size,
                            ring: false
                        )
                        .overlay(Circle().strokeBorder(Theme.paperFixed.opacity(isDone ? 0.9 : 0.25), lineWidth: 2))
                        .saturation(isDone ? 1 : 0.15)
                        .opacity(isDone ? 1 : 0.45)
                        if isDone {
                            Image(systemName: "checkmark")
                                .font(.system(size: size * 0.22, weight: .heavy))
                                .foregroundStyle(Theme.inkFixed)
                                .frame(width: size * 0.4, height: size * 0.4)
                                .background(Circle().fill(Theme.paperFixed))
                                .offset(x: 2, y: 2)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .offset(x: x + dx, y: y + dy)
                    .animation(.snappy(duration: 0.4, extraBounce: 0.2), value: isDone)
                }
            }
            .frame(width: CGFloat(max(1, columns)) * cell, height: CGFloat(rows) * cell)
        }
    }
}

// MARK: - Floating covers

/// Candidate covers adrift on the page: each one bobs on its own sine path
/// and tilts a little, like books tossed on a table. `emphasis` (a candidate
/// id) pulls one cover to the center, full size, for the reveal.
struct ClubVoteFloatingCovers: View {
    let candidates: [BookClub.Vote.Candidate]
    var coverSize: CGFloat = 78
    var emphasis: String? = nil
    var faded: Set<String> = []

    var body: some View {
        GeometryReader { geo in
            let count = max(1, candidates.count)
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, cand in
                        let angle = (Double(index) / Double(count)) * .pi * 2 - .pi / 2
                        let radiusX = geo.size.width * 0.34
                        let radiusY = geo.size.height * 0.30
                        let phase = Double(index) * 2.1
                        let baseX = cos(angle) * radiusX + sin(t * 0.55 + phase) * 9
                        let baseY = sin(angle) * radiusY + cos(t * 0.75 + phase) * 11
                        let tilt = sin(t * 0.5 + phase) * 7
                        let isHero = emphasis == cand.id
                        let isFaded = faded.contains(cand.id)
                        BookCoverView(book: cand.asBook, size: coverSize)
                            .rotationEffect(.degrees(isHero ? 0 : tilt))
                            .scaleEffect(isHero ? 1.9 : (isFaded ? 0.72 : 1))
                            .opacity(isFaded ? 0.22 : 1)
                            .saturation(isFaded ? 0 : 1)
                            .offset(x: isHero ? 0 : baseX, y: isHero ? 0 : baseY)
                            .zIndex(isHero ? 10 : 0)
                            .animation(.snappy(duration: 0.7, extraBounce: 0.18), value: isHero)
                            .animation(.easeInOut(duration: 0.45), value: isFaded)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

// MARK: - Countdown

/// "19h left" pill that keeps itself honest without a timer of its own.
struct ClubVoteCountdownPill: View {
    let vote: BookClub.Vote
    var onInk: Bool = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let copy = vote.timeLeftCopy(now: timeline.date)
            if !copy.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .bold))
                    Text(copy)
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.6)
                }
                .foregroundStyle(onInk ? Theme.inkFixed : Theme.onChrome)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(onInk ? Theme.paperFixed : Theme.chrome))
            }
        }
    }
}

// MARK: - Ballot

/// Drag-to-reorder ranking. Top row is the first choice. A row can be vetoed
/// (one per ballot): it drops out of the ranking, dims, and sits at the bottom.
struct ClubVoteRankList: View {
    @Binding var order: [BookClub.Vote.Candidate]
    @Binding var veto: String?

    @State private var draggingId: String?
    @State private var dragOffset: CGFloat = 0
    @State private var dragStartIndex: Int = 0

    private let rowHeight: CGFloat = 78
    private let rowGap: CGFloat = 8
    private var slot: CGFloat { rowHeight + rowGap }

    private var ranked: [BookClub.Vote.Candidate] { order.filter { $0.id != veto } }
    private var vetoed: BookClub.Vote.Candidate? { order.first { $0.id == veto } }

    private var dragTargetIndex: Int {
        let raw = Int((CGFloat(dragStartIndex) * slot + dragOffset + slot / 2) / slot)
        return min(max(0, raw), ranked.count - 1)
    }

    var body: some View {
        VStack(spacing: rowGap) {
            ForEach(Array(ranked.enumerated()), id: \.element.id) { index, cand in
                row(cand, position: index)
                    .offset(y: rowOffset(for: index, id: cand.id))
                    .zIndex(draggingId == cand.id ? 10 : 0)
                    .scaleEffect(draggingId == cand.id ? 1.03 : 1)
                    .shadow(color: Theme.inkFixed.opacity(draggingId == cand.id ? 0.5 : 0), radius: 18, y: 8)
                    .animation(.snappy(duration: 0.28, extraBounce: 0.1), value: dragTargetIndex)
                    .animation(.snappy(duration: 0.28, extraBounce: 0.1), value: draggingId)
                    .gesture(dragGesture(for: cand.id, at: index))
            }
            if let vetoed {
                vetoRow(vetoed)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.35, extraBounce: 0.1), value: veto)
    }

    private func rowOffset(for index: Int, id: String) -> CGFloat {
        guard let draggingId else { return 0 }
        if id == draggingId { return dragOffset }
        let target = dragTargetIndex
        if dragStartIndex < index && index <= target { return -slot }
        if target <= index && index < dragStartIndex { return slot }
        return 0
    }

    private func dragGesture(for id: String, at index: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.12)
            .sequenced(before: DragGesture(minimumDistance: 2, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .first(true):
                    if draggingId == nil {
                        draggingId = id
                        dragStartIndex = index
                        dragOffset = 0
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                case .second(true, let drag?):
                    if draggingId == nil {
                        draggingId = id
                        dragStartIndex = index
                    }
                    dragOffset = drag.translation.height
                default:
                    break
                }
            }
            .onEnded { _ in
                guard draggingId != nil else { return }
                let from = dragStartIndex
                let to = dragTargetIndex
                if from != to {
                    var list = ranked
                    let moved = list.remove(at: from)
                    list.insert(moved, at: to)
                    if let v = vetoed { list.append(v) }
                    order = list
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                draggingId = nil
                dragOffset = 0
            }
    }

    private func row(_ cand: BookClub.Vote.Candidate, position: Int) -> some View {
        HStack(spacing: 12) {
            positionBadge(position)
            BookCoverView(book: cand.asBook, size: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(cand.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.paperFixed)
                    .lineLimit(2)
                Text(cand.author)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.paperFixed.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.paperFixed.opacity(0.35))
            Button {
                withAnimation(.snappy(duration: 0.35, extraBounce: 0.1)) { veto = cand.id }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            } label: {
                Image(systemName: "hand.raised.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.paperFixed.opacity(0.45))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Veto \(cand.title)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.paperFixed.opacity(position == 0 ? 0.16 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.paperFixed.opacity(position == 0 ? 0.55 : 0.14), lineWidth: position == 0 ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    private func positionBadge(_ position: Int) -> some View {
        Group {
            if position == 0 {
                Image(systemName: "crown.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.inkFixed)
            } else {
                Text("\(position + 1)")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Theme.paperFixed)
            }
        }
        .frame(width: 30, height: 30)
        .background(Circle().fill(position == 0 ? Theme.paperFixed : Theme.paperFixed.opacity(0.14)))
    }

    private func vetoRow(_ cand: BookClub.Vote.Candidate) -> some View {
        HStack(spacing: 12) {
            Text("VETO")
                .font(.system(size: 9, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(Theme.paperFixed.opacity(0.7))
                .frame(width: 30)
            BookCoverView(book: cand.asBook, size: 44)
                .saturation(0)
                .opacity(0.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(cand.title)
                    .font(.system(size: 14, weight: .semibold))
                    .strikethrough()
                    .foregroundStyle(Theme.paperFixed.opacity(0.55))
                    .lineLimit(1)
                Text("Not this month.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.paperFixed.opacity(0.45))
            }
            Spacer(minLength: 6)
            Button {
                withAnimation(.snappy(duration: 0.35, extraBounce: 0.1)) { veto = nil }
            } label: {
                Text("Undo")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.paperFixed.opacity(0.8))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .overlay(Capsule().strokeBorder(Theme.paperFixed.opacity(0.35), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.paperFixed.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.paperFixed.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

// MARK: - In-flow book search

/// Search field plus results, with the reader's own queue as the first
/// suggestion. Dark-scheme styled for the vote flow.
struct ClubVoteBookSearch: View {
    let excludeBookIds: Set<String>
    let onSelect: (Book) -> Void

    @EnvironmentObject var appState: AppState
    @State private var query = ""
    @State private var results: [Book] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var queueBooks: [Book] {
        appState.userBooks
            .filter { $0.status == .wantToRead && !excludeBookIds.contains($0.bookId) }
            .compactMap(\.book)
            .prefix(10)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.paperFixed.opacity(0.5))
                TextField("", text: $query, prompt: Text("Title or author").foregroundStyle(Theme.paperFixed.opacity(0.4)))
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.paperFixed)
                    .tint(Theme.paperFixed)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .focused($focused)
                    .onSubmit { runSearch(immediate: true) }
                    .onChange(of: query) { _, _ in runSearch(immediate: false) }
                if searching {
                    ProgressView().tint(Theme.paperFixed).scaleEffect(0.8)
                } else if !query.isEmpty {
                    Button { query = ""; results = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.paperFixed.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.paperFixed.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.paperFixed.opacity(0.25), lineWidth: 1))
            .padding(.horizontal, Theme.horizontalPadding)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        if !queueBooks.isEmpty {
                            Text("FROM YOUR QUEUE")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(1.8)
                                .foregroundStyle(Theme.paperFixed.opacity(0.55))
                                .padding(.top, 16)
                                .padding(.bottom, 4)
                            ForEach(queueBooks) { book in
                                resultRow(book)
                            }
                        }
                    } else if results.isEmpty && !searching {
                        Text("Nothing for \u{201C}\(query)\u{201D}. Try the author.")
                            .font(Theme.callout())
                            .foregroundStyle(Theme.paperFixed.opacity(0.6))
                            .padding(.top, 24)
                    } else {
                        ForEach(results.filter { !excludeBookIds.contains($0.id) }) { book in
                            resultRow(book)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true }
        }
    }

    private func resultRow(_ book: Book) -> some View {
        Button {
            focused = false
            onSelect(book)
        } label: {
            HStack(spacing: 12) {
                BookCoverView(book: book, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.paperFixed)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(book.author)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.paperFixed.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.paperFixed.opacity(0.6))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.paperFixed.opacity(0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.springPress)
    }

    private func runSearch(immediate: Bool) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            results = []
            searching = false
            return
        }
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
            }
            searching = true
            defer { searching = false }
            do {
                let books = try await GoogleBooksService.shared.search(query: trimmed)
                if Task.isCancelled { return }
                results = books
            } catch {
                if Task.isCancelled { return }
                results = []
            }
        }
    }
}

// MARK: - Club page status card

/// What the club page shows while a vote is running or waiting to be revealed.
/// One line of state, the member cloud, and the one button that matters.
struct ClubVoteStatusCard: View {
    let club: BookClub
    let vote: BookClub.Vote
    let myUid: String?
    let onOpen: () -> Void

    private var members: [(uid: String, member: BookClub.Member)] {
        club.orderedMemberIds.compactMap { uid in club.members[uid].map { (uid: uid, member: $0) } }
    }

    private var done: Set<String> {
        switch vote.phase {
        case .picks: return Set(vote.respondedPickUids)
        case .voting: return Set(vote.votedUids)
        case .revealed: return Set(vote.revealedUids)
        }
    }

    private var iResponded: Bool { myUid.map(vote.hasResponded) ?? false }

    private var headline: String {
        switch vote.phase {
        case .picks: return iResponded ? "Your pick is in." : "Pick time."
        case .voting: return iResponded ? "Ballot cast." : "Time to vote."
        case .revealed: return iResponded ? "Rewatch the reveal" : "The votes are in."
        }
    }

    private var detail: String {
        let n = club.memberIds.count
        switch vote.phase {
        case .picks:
            return iResponded
                ? "\(done.count) of \(n) in. Voting opens when everyone's answered, or when the clock runs out."
                : "Suggest the club's next book. It's anonymous."
        case .voting:
            return iResponded
                ? "\(done.count) of \(n) voted. The winner drops when everyone's in, or when the clock runs out."
                : "\(vote.candidates.count) books are in. Rank your favorites."
        case .revealed:
            return iResponded ? "Relive the moment." : "Your next read is decided. Tap to see it."
        }
    }

    private var buttonTitle: String {
        switch vote.phase {
        case .picks: return iResponded ? "See who's in" : "Suggest a book"
        case .voting: return iResponded ? "See who's voted" : "Vote"
        case .revealed: return iResponded ? "Rewatch" : "Reveal the book"
        }
    }

    private var icon: String {
        switch vote.phase {
        case .picks: return "text.book.closed.fill"
        case .voting: return "checkmark.seal.fill"
        case .revealed: return "party.popper.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if vote.isOpen {
                    ClubVoteCountdownPill(vote: vote, onInk: false)
                }
            }
            if vote.phase != .revealed {
                HStack(spacing: -8) {
                    ForEach(members, id: \.uid) { entry in
                        UserAvatarView(urlString: entry.member.photoURL, displayName: entry.member.displayName, firstName: entry.member.firstName, lastName: nil, size: 30)
                            .opacity(done.contains(entry.uid) ? 1 : 0.35)
                            .saturation(done.contains(entry.uid) ? 1 : 0.2)
                    }
                    Text("\(done.count)/\(club.memberIds.count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.leading, 16)
                }
            }
            if iResponded && vote.phase != .revealed {
                ClubSecondaryButton(title: buttonTitle, icon: icon, action: onOpen)
            } else {
                ClubPrimaryButton(title: buttonTitle, icon: icon, action: onOpen)
            }
        }
        .hingeSectionCard(title: vote.phase == .revealed ? "Next book" : "Group vote")
    }
}
