//
//  LinkImportView.swift
//  SPINE
//
//  "Add to your queue" from a link shared to SPINE: a web page, a TikTok, a
//  pasted list. The app reads the page, finds every book it mentions, and
//  walks the user through them one card at a time (the Goodreads wizard's
//  shape), each with a prefilled note-to-self naming the source. One book on
//  the page → one card, no progress header. Progress persists so a ten-book
//  list can be finished later from the queue's "Finish adding books" callout.
//

import SwiftUI

// MARK: - Model

@MainActor
final class LinkImportModel: ObservableObject {
    enum Step: Equatable {
        /// Fetching / extracting, with a status line.
        case loading(String)
        case failed(String)
        /// The page had no books in it.
        case empty
        case wizard
        case bulkAdding
        case done
    }

    enum MatchState: Equatable {
        case pending
        case matched(Book)
        /// Clean miss — the manual search card takes over.
        case noMatch
        /// Lookup errored (offline, throttled) — retryable.
        case failed
    }

    private struct UndoRecord {
        let candidateId: String
        let decision: LinkImportDecision
        let book: Book?
    }

    @Published private(set) var step: Step = .loading("Reading the page…")
    @Published private(set) var session: LinkImportSession?
    @Published private(set) var matchStates: [String: MatchState] = [:]
    /// Transient write problem — the affected book stays pending.
    @Published private(set) var importError: String?
    @Published private(set) var bulkDone = 0
    @Published private(set) var bulkTotal = 0
    @Published private(set) var canUndo = false
    /// Source label to show on the "no books" screen (no session exists then).
    @Published private(set) var emptySourceLabel: String = ""

    private weak var appState: AppState?
    private var configured = false
    private var startTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var undoStack: [UndoRecord] = []

    private let service = LinkBookExtractionService.shared

    var currentCandidate: LinkBookCandidate? { session?.currentCandidate }

    var currentMatch: MatchState {
        guard let c = currentCandidate else { return .pending }
        return matchStates[c.id] ?? .pending
    }

    var currentBook: Book? {
        if case .matched(let book) = currentMatch { return book }
        return nil
    }

    var isSingleBook: Bool { session?.isSingleBook ?? false }

    // MARK: Lifecycle

    func configure(appState: AppState, payload: LinkImportPayload?) {
        guard !configured else { return }
        configured = true
        self.appState = appState
        if let payload {
            start(payload)
        } else if let saved = appState.loadLinkImportSession(), saved.hasRemainingWork {
            resume(saved)
        } else {
            step = .failed("There's nothing left to add from that link.")
        }
    }

    private func start(_ payload: LinkImportPayload) {
        step = .loading("Reading the page…")
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await self.service.fetchContent(for: payload)
                guard !Task.isCancelled else { return }
                self.step = .loading("Finding the books…")
                let extraction = try await self.service.extractBooks(from: content)
                guard !Task.isCancelled else { return }
                let label = extraction.sourceLabel.isEmpty
                    ? (content.displayHost ?? "a shared link")
                    : extraction.sourceLabel
                Analytics.amplitude?.track(eventType: "Shared Link To Queue", eventProperties: [
                    "host": content.displayHost ?? "text",
                    "book_count": extraction.candidates.count
                ])
                guard !extraction.candidates.isEmpty else {
                    self.emptySourceLabel = label
                    self.step = .empty
                    return
                }
                let session = LinkImportSession(
                    sourceURL: content.url ?? payload.url,
                    sourceLabel: label,
                    candidates: extraction.candidates
                )
                // A newer share replaces whatever was paused before.
                self.session = session
                self.persist()
                self.step = .wizard
                self.prefetchMatches()
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LinkImportError)?.errorDescription ?? error.localizedDescription
                self.step = .failed(message)
            }
        }
    }

    private func resume(_ saved: LinkImportSession) {
        session = saved
        for (id, book) in saved.matchedBooks {
            matchStates[id] = .matched(book)
        }
        step = .wizard
        prefetchMatches()
    }

    /// Throw the session away and close out (the view dismisses).
    func startOver() {
        startTask?.cancel()
        prefetchTask?.cancel()
        appState?.clearLinkImportSession()
        session = nil
        undoStack = []
        canUndo = false
        step = .done
    }

    private func persist() {
        guard let session else { return }
        appState?.saveLinkImportSession(session)
    }

    // MARK: Matching

    /// Resolve every pending candidate in order, in the background, so the card
    /// for book 2 is ready by the time book 1 is decided.
    private func prefetchMatches() {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self, let session = self.session else { return }
            for candidate in session.candidates {
                guard !Task.isCancelled else { return }
                guard self.session?.decisions[candidate.id] == nil else { continue }
                if case .matched = self.matchStates[candidate.id] ?? .pending { continue }
                await self.match(candidate)
            }
        }
    }

    private func match(_ candidate: LinkBookCandidate) async {
        let outcome = await service.matchCandidate(candidate)
        guard !Task.isCancelled else { return }
        switch outcome {
        case .matched(let book):
            matchStates[candidate.id] = .matched(book)
            if var s = session {
                s.matchedBooks[candidate.id] = book
                session = s
                persist()
            }
            advancePastDuplicates()
        case .noMatch:
            matchStates[candidate.id] = .noMatch
        case .failed:
            matchStates[candidate.id] = .failed
        }
    }

    func retryCurrentMatch() {
        guard let c = currentCandidate else { return }
        matchStates[c.id] = .pending
        Task { [weak self] in await self?.match(c) }
    }

    /// The current book is already in the library (any status): skip past it
    /// with a toast instead of showing a card whose only answer is "no".
    private func advancePastDuplicates() {
        guard let appState else { return }
        while step == .wizard, let c = currentCandidate, let book = currentBook,
              appState.userBook(sameWorkAs: book) != nil {
            ToastCenter.shared.show(.duplicateSkipped(bookTitle: book.title, readDateSaved: false))
            decide(c, .duplicate, book: book, undoable: false)
        }
    }

    // MARK: Decisions

    private func decide(_ candidate: LinkBookCandidate, _ decision: LinkImportDecision, book: Book?, undoable: Bool = true) {
        guard var s = session else { return }
        s.decisions[candidate.id] = decision
        session = s
        if undoable {
            undoStack.append(UndoRecord(candidateId: candidate.id, decision: decision, book: book))
            canUndo = true
        }
        persist()
        transitionIfFinished()
        if step == .wizard { advancePastDuplicates() }
    }

    /// Queue the current book with the note as it stands on the card. Optimistic:
    /// the wizard advances at once; a write failure puts the book back.
    func queueCurrent(note: String) {
        guard let appState, let candidate = currentCandidate, let book = currentBook else { return }
        importError = nil
        if var s = session {
            s.editedNotes[candidate.id] = note
            session = s
        }
        decide(candidate, .queued, book: book)
        Analytics.amplitude?.track(eventType: "Queued Book From Link", eventProperties: [
            "has_note": !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ])
        Task { [weak self] in
            let outcome = await appState.queueBookFromLink(book: book, note: note)
            guard let self else { return }
            switch outcome {
            case .imported:
                break
            case .duplicate:
                // Raced an add elsewhere — record what actually happened.
                if var s = self.session { s.decisions[candidate.id] = .duplicate; self.session = s; self.persist() }
            case .failed:
                self.revertFailedQueue(candidate: candidate, book: book)
            }
        }
    }

    private func revertFailedQueue(candidate: LinkBookCandidate, book: Book) {
        guard var s = session else { return }
        s.decisions[candidate.id] = nil
        session = s
        undoStack.removeAll { $0.candidateId == candidate.id }
        canUndo = !undoStack.isEmpty
        persist()
        importError = "Couldn't add “\(book.title)” . Check your connection and try again."
        if step == .done || step == .bulkAdding { step = .wizard }
    }

    func skipCurrent() {
        guard let candidate = currentCandidate else { return }
        decide(candidate, .skipped, book: currentBook)
    }

    /// Manual search picked an edition: it takes the automatic guess's place
    /// and the normal card comes back for this candidate.
    func applyManualMatch(_ book: Book) {
        guard let candidate = currentCandidate else { return }
        matchStates[candidate.id] = .matched(book)
        if var s = session {
            s.matchedBooks[candidate.id] = book
            session = s
            persist()
        }
        advancePastDuplicates()
    }

    func markCurrentUnmatched() {
        guard let candidate = currentCandidate else { return }
        decide(candidate, .unmatched, book: nil)
    }

    func undoLastDecision() {
        guard let record = undoStack.popLast(), var s = session else { return }
        canUndo = !undoStack.isEmpty
        s.decisions[record.candidateId] = nil
        session = s
        if record.decision == .queued, let book = record.book {
            appState?.unqueueBookFromLink(book: book)
        }
        importError = nil
        persist()
        if step == .done { step = .wizard }
    }

    /// Queue every remaining book with its suggested note. Books that can't be
    /// matched are reported, never guessed.
    func queueAllRemaining() {
        guard let appState, let s = session else { return }
        prefetchTask?.cancel()
        let pending = s.candidates.filter { s.decisions[$0.id] == nil }
        bulkTotal = pending.count
        bulkDone = 0
        step = .bulkAdding
        importError = nil
        Task { [weak self] in
            guard let self else { return }
            var failures = 0
            for candidate in pending {
                guard !Task.isCancelled else { return }
                if case .pending = self.matchStates[candidate.id] ?? .pending {
                    await self.match(candidate)
                } else if case .failed = self.matchStates[candidate.id] ?? .pending {
                    await self.match(candidate)
                }
                // A duplicate auto-skip inside match() may already have decided it.
                guard self.session?.decisions[candidate.id] == nil else {
                    self.bulkDone += 1
                    continue
                }
                switch self.matchStates[candidate.id] ?? .pending {
                case .matched(let book):
                    let note = self.session?.note(for: candidate) ?? candidate.note
                    let outcome = await appState.queueBookFromLink(book: book, note: note)
                    switch outcome {
                    case .imported: self.decide(candidate, .queued, book: book, undoable: false)
                    case .duplicate: self.decide(candidate, .duplicate, book: book, undoable: false)
                    case .failed: failures += 1
                    }
                case .noMatch:
                    self.decide(candidate, .unmatched, book: nil, undoable: false)
                case .failed, .pending:
                    failures += 1
                }
                self.bulkDone += 1
            }
            if failures > 0 {
                self.importError = failures == 1
                    ? "1 book couldn't be added . Check your connection and try again."
                    : "\(failures) books couldn't be added . Check your connection and try again."
                self.step = .wizard
                self.prefetchMatches()
            } else {
                self.transitionIfFinished()
            }
        }
    }

    private func transitionIfFinished() {
        guard let s = session, !s.hasRemainingWork else { return }
        step = .done
        appState?.clearLinkImportSession()
    }
}

// MARK: - View

struct LinkImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    /// The share that opened this sheet; nil resumes the saved session.
    let payload: LinkImportPayload?

    @StateObject private var model = LinkImportModel()
    @State private var cardNote = ""
    @State private var showManualSearch = false
    @State private var showAddAllConfirm = false
    @State private var showStartOverConfirm = false
    @FocusState private var noteFocused: Bool

    init(payload: LinkImportPayload?) {
        self.payload = payload
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle(model.isSingleBook ? "Add to queue" : "Add to your queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            // Lives above MainTabView's toast host — needs its own for the
            // duplicate-skip toasts.
            .toastHost()
            // Mid-list, a scroll on the card easily reads as a sheet drag. Close
            // is the exit; progress is saved either way.
            .interactiveDismissDisabled(isMidWizard)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(closeTitle) { dismiss() }
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textTertiary)
                }
                if model.session != nil, !model.isSingleBook, model.step == .wizard {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Start over and delete progress", role: .destructive) {
                                showStartOverConfirm = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            .onAppear {
                model.configure(appState: appState, payload: payload)
            }
            .onChange(of: model.currentCandidate?.id) { _, _ in
                syncCardState()
            }
            .onChange(of: model.step) { _, step in
                if step == .wizard { syncCardState() }
            }
            .alert("Delete progress?", isPresented: $showStartOverConfirm) {
                Button("Delete progress", role: .destructive) {
                    model.startOver()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The books still waiting on this list are dropped. Anything you already added stays in your queue.")
            }
            .alert("Add all remaining?", isPresented: $showAddAllConfirm) {
                Button("Add all") { model.queueAllRemaining() }
                Button("Keep reviewing", role: .cancel) {}
            } message: {
                Text("Every remaining book goes to your queue with its suggested note. Books that can't be matched are listed at the end instead of guessed.")
            }
        }
    }

    private var closeTitle: String {
        switch model.step {
        case .wizard, .bulkAdding: return model.isSingleBook ? "Cancel" : "Close"
        case .done: return "Done"
        default: return "Cancel"
        }
    }

    private var isMidWizard: Bool {
        guard !model.isSingleBook else { return false }
        switch model.step {
        case .wizard, .bulkAdding: return true
        default: return false
        }
    }

    /// Seed the editable note from the session (the user's edit if they came
    /// back to this card, else the model's suggestion).
    private func syncCardState() {
        noteFocused = false
        showManualSearch = false
        guard let session = model.session, let candidate = model.currentCandidate else {
            cardNote = ""
            return
        }
        cardNote = session.note(for: candidate)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .loading(let status):
            loadingContent(status: status)
        case .failed(let message):
            failedContent(message: message)
        case .empty:
            emptyContent
        case .wizard:
            wizardContent
        case .bulkAdding:
            bulkContent
        case .done:
            doneContent
        }
    }

    // MARK: Loading / failed / empty

    private func loadingContent(status: String) -> some View {
        VStack(spacing: 20) {
            SpinningSpineLogo()
            Text(status)
                .font(Theme.title2())
                .foregroundStyle(Theme.textSecondary)
            if let host = payload?.displayHost {
                Text(host)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
    }

    private func failedContent(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "link")
                .font(.system(size: 44))
                .foregroundStyle(Theme.chrome)
            Text("Couldn't read that link")
                .font(Theme.title())
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.callout())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let host = payload?.displayHost {
                Text(host)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            secondaryWideButton("Close") { dismiss() }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }

    private var emptyContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(Theme.chrome)
            Text("No books found")
                .font(Theme.title())
                .foregroundStyle(Theme.textPrimary)
            Text("We read \(model.emptySourceLabel) but didn't spot any book titles. If it's a video, the books may only be named out loud.")
                .font(Theme.callout())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            secondaryWideButton("Close") { dismiss() }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }

    // MARK: Wizard

    @ViewBuilder
    private var wizardContent: some View {
        if let session = model.session {
            VStack(spacing: 0) {
                if !session.isSingleBook {
                    progressHeader(
                        position: session.currentPosition,
                        total: session.candidates.count,
                        remaining: session.pendingCount
                    )
                }
                sourceLine(session.sourceLabel)
                importErrorBanner
                ScrollView {
                    VStack(spacing: 20) {
                        if let candidate = model.currentCandidate {
                            currentCard(for: candidate)
                        }
                    }
                    .padding(Theme.cardPadding)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    @ViewBuilder
    private func currentCard(for candidate: LinkBookCandidate) -> some View {
        switch model.currentMatch {
        case .matched(let book):
            if showManualSearch {
                ManualBookMatchCard(
                    title: candidate.title,
                    author: candidate.author,
                    hint: "Tap the right edition and it takes this book's place on the card.",
                    onMatch: { model.applyManualMatch($0); showManualSearch = false },
                    onSkip: { model.skipCurrent() }
                )
                .id("manual-\(candidate.id)")
            } else {
                bookCard(book: book, candidate: candidate)
            }
        case .noMatch:
            ManualBookMatchCard(
                title: candidate.title,
                author: candidate.author,
                hint: "Search for it below and tap the right edition to queue it.",
                onMatch: { model.applyManualMatch($0) },
                onSkip: { model.markCurrentUnmatched() }
            )
            .id("nomatch-\(candidate.id)")
        case .failed:
            lookupFailedCard(candidate: candidate)
        case .pending:
            matchingCard(candidate: candidate)
        }
    }

    private func bookCard(book: Book, candidate: LinkBookCandidate) -> some View {
        VStack(spacing: 16) {
            BookCoverView(book: book, size: 120)
            VStack(spacing: 4) {
                Text(book.title)
                    .font(Theme.title2())
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text(book.author)
                    .font(Theme.callout())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }

            noteEditor

            HStack(spacing: 10) {
                Button {
                    model.skipCurrent()
                } label: {
                    Text(model.isSingleBook ? "Not now" : "Skip")
                }
                .buttonStyle(.spineSecondary)

                Button {
                    noteFocused = false
                    model.queueCurrent(note: cardNote)
                } label: {
                    Text("Add to queue")
                }
                .buttonStyle(.spinePrimary)
            }

            Button {
                noteFocused = false
                showManualSearch = true
            } label: {
                Text("Not the right book?")
                    .font(Theme.caption())
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }

    /// Editable note-to-self, prefilled from the page. Same look as the
    /// standalone composer (QueueNoteComposerOverlay) so it reads as the same
    /// feature.
    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(SpinesGlyphs.caps(QueueNoteCopy.title))
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.chrome)
                Spacer()
                if !cardNote.isEmpty {
                    Button("Clear") { cardNote = "" }
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textTertiary)
                        .buttonStyle(.plain)
                }
            }
            ZStack(alignment: .topLeading) {
                if cardNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(QueueNoteCopy.placeholder)
                        .font(Theme.body())
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $cardNote)
                    .font(Theme.body())
                    .lineSpacing(Theme.bodyLineSpacing)
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(minHeight: 56)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($noteFocused)
                    .onChange(of: cardNote) { _, new in
                        if new.count > QueueNoteCopy.maxLength {
                            cardNote = String(new.prefix(QueueNoteCopy.maxLength))
                        }
                    }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(noteFocused ? Theme.chrome : Theme.chrome.opacity(0.35), lineWidth: noteFocused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: noteFocused)
            .onTapGesture { noteFocused = true }
            HStack {
                Text("Private to you. Edit it or clear it.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                let remaining = QueueNoteCopy.maxLength - cardNote.count
                if remaining <= 40 {
                    Text("\(remaining)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(remaining <= 0 ? Theme.danger : Theme.textTertiary)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func matchingCard(candidate: LinkBookCandidate) -> some View {
        VStack(spacing: 20) {
            SpinningSpineLogo()
            Text("Finding “\(candidate.title)”…")
                .font(Theme.title2())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if !candidate.author.isEmpty {
                Text(candidate.author)
                    .font(Theme.callout())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }

    private func lookupFailedCard(candidate: LinkBookCandidate) -> some View {
        VStack(spacing: 16) {
            Text("Couldn't look up “\(candidate.title)”")
                .font(Theme.headline())
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Check your connection and try again.")
                .font(Theme.callout())
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                secondaryWideButton("Skip") { model.skipCurrent() }
                Button {
                    model.retryCurrentMatch()
                } label: {
                    Text("Try again")
                }
                .buttonStyle(.spinePrimary)
            }
        }
        .padding(.top, 32)
    }

    private func progressHeader(position: Int, total: Int, remaining: Int) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("BOOK \(position) OF \(total)")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Theme.textPrimary)
                if model.canUndo {
                    pill(icon: "arrow.uturn.backward", label: "Undo") { model.undoLastDecision() }
                }
                Spacer()
                pill(icon: nil, label: "Add all") { showAddAllConfirm = true }
                    .disabled(remaining == 0)
            }
            ProgressView(value: Double(max(0, total - remaining)), total: Double(max(total, 1)))
                .tint(Theme.accent)
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func pill(icon: String?, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(label)
                    .font(Theme.caption())
                    .fontWeight(.medium)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surface)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Theme.textTertiary.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func sourceLine(_ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text("From \(label)")
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.top, model.isSingleBook ? 12 : 4)
    }

    @ViewBuilder
    private var importErrorBanner: some View {
        if let err = model.importError {
            Text(err)
                .font(Theme.caption())
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.cardPadding)
                .padding(.top, 8)
        }
    }

    // MARK: Bulk + done

    private var bulkContent: some View {
        VStack(spacing: 24) {
            ProgressView(value: Double(model.bulkDone), total: Double(max(1, model.bulkTotal)))
                .tint(Theme.accent)
                .padding(.horizontal, 40)
            Text("Adding \(min(model.bulkDone + 1, max(model.bulkTotal, 1))) of \(model.bulkTotal)…")
                .font(Theme.title2())
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    @ViewBuilder
    private var doneContent: some View {
        if let session = model.session {
            let queued = session.candidates(with: .queued)
            let duplicates = session.candidates(with: .duplicate)
            let skipped = session.candidates(with: .skipped)
            let unmatched = session.candidates(with: .unmatched)
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: queued.isEmpty ? "books.vertical" : "checkmark.circle")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.chrome)
                        .padding(.top, 24)
                    VStack(spacing: 6) {
                        Text(doneHeadline(queuedCount: queued.count))
                            .font(Theme.title())
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.center)
                        Text("From \(session.sourceLabel)")
                            .font(Theme.callout())
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    if !queued.isEmpty {
                        summaryList(queued, session: session, showNotes: true)
                    }
                    if !duplicates.isEmpty {
                        summarySection("Already in your library", duplicates, session: session)
                    }
                    if !skipped.isEmpty {
                        summarySection("Skipped", skipped, session: session)
                    }
                    if !unmatched.isEmpty {
                        summarySection("Couldn't find", unmatched, session: session)
                    }

                    VStack(spacing: 10) {
                        if !queued.isEmpty {
                            Button {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    appState.openQueue()
                                }
                            } label: {
                                Text("Open queue")
                            }
                            .buttonStyle(.spinePrimary)
                        }
                        secondaryWideButton("Done") { dismiss() }
                    }
                    .padding(.top, 8)
                }
                .padding(Theme.cardPadding)
            }
        } else {
            // Start-over path: nothing to summarize.
            Color.clear.onAppear { dismiss() }
        }
    }

    private func doneHeadline(queuedCount: Int) -> String {
        switch queuedCount {
        case 0: return "Nothing added"
        case 1: return "Added 1 book to your queue"
        default: return "Added \(queuedCount) books to your queue"
        }
    }

    private func summarySection(_ title: String, _ items: [LinkBookCandidate], session: LinkImportSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SpinesGlyphs.caps(title))
                .font(.system(size: 12, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)
            summaryList(items, session: session, showNotes: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryList(_ items: [LinkBookCandidate], session: LinkImportSession, showNotes: Bool) -> some View {
        VStack(spacing: 8) {
            ForEach(items) { candidate in
                HStack(spacing: 10) {
                    if let book = session.matchedBooks[candidate.id] {
                        BookCoverView(book: book, size: 44)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.surface)
                            .frame(width: 44 * 0.66, height: 44)
                            .overlay(
                                Image(systemName: "questionmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary)
                            )
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.matchedBooks[candidate.id]?.title ?? candidate.title)
                            .font(Theme.callout())
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(session.matchedBooks[candidate.id]?.author ?? candidate.author)
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        if showNotes {
                            let note = session.note(for: candidate)
                            if !note.isEmpty {
                                Text(note)
                                    .font(Theme.caption())
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: Shared bits

    private func secondaryWideButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(.spineSecondary)
    }
}
