//
//  GoodreadsImportView.swift
//  WellRead
//
//  Goodreads import wizard. Single entry path: grab the CSV export from
//  Goodreads (in-app browser) or upload it. Read books are reviewed one at a
//  time on an inline-editable card (stars, date read, tier, review → Skip /
//  Looks good), then the user is offered their queue (to-read) books. Progress
//  is persisted after every action so closing the app resumes exactly where
//  they left off.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

@MainActor
final class GoodreadsWizardModel: ObservableObject {
    enum Step: Equatable {
        case explainer
        case readWizard
        case queuePrompt
        case queueWizard
        case bulkImporting
        case done
    }

    enum MatchState: Equatable {
        case matching
        case matched(Book)
        /// Lookups completed and nothing met the confidence bar — a real no-match.
        case unmatched
        /// Lookup errored (offline, rate limit) — retryable, never auto-skipped.
        case failed
    }

    @Published var step: Step = .explainer
    @Published private(set) var session: GoodreadsWizardSession?
    @Published private(set) var matchStates: [String: MatchState] = [:]
    @Published var bulkDone = 0
    @Published var bulkTotal = 0
    @Published var parseError: String?
    /// Non-fatal problem to surface on the wizard (failed save, bulk-import hiccups).
    @Published var importError: String?

    private let service = GoodreadsImportService()
    private weak var appState: AppState?
    private var inFlightRowIds: Set<String> = []
    /// Rows already pushed to the end of the review queue because they didn't
    /// match cleanly. When one of these comes up again it gets a manual-match
    /// card instead of being deferred a second time. In-memory only: on a fresh
    /// launch every problem row gets one more automatic try first.
    private var deferredRowIds: Set<String> = []
    /// Imported this session — the Firestore listener lags the write, so `appState.userBooks` alone can't catch same-session duplicates.
    private var importedBookIds: Set<String> = []
    /// Work keys (title+author) imported this session — catches the same book
    /// arriving again as a different edition with a different volume id.
    private var importedWorkKeys: Set<String> = []
    private var configured = false

    /// One Skip/Add the user can take back. In-memory only — undo covers taps
    /// made this session, not decisions from a resumed one.
    private struct UndoRecord {
        let rowId: String
        let decision: GoodreadsRowDecision
        /// The book that was imported (nil for skips).
        let book: Book?
        /// The import promoted an existing queue entry to Read; undo re-queues it.
        let wasQueuedBefore: Bool
    }
    private var undoStack: [UndoRecord] = []
    @Published private(set) var canUndo = false

    /// How many upcoming books to match ahead of the user so cards appear instantly.
    private let prefetchWindow = 4

    var currentRow: GoodreadsRow? { session?.currentRow }

    var currentMatch: MatchState? {
        currentRow.flatMap { matchStates[$0.id] }
    }

    var currentBook: Book? {
        if case .matched(let b)? = currentMatch { return b }
        return nil
    }

    /// True when the current row couldn't be matched automatically (no confident
    /// match, or lookups kept erroring) — shows the search-to-match card.
    var currentNeedsManualMatch: Bool {
        switch currentMatch {
        case .unmatched?, .failed?: return true
        default: return false
        }
    }

    func configure(appState: AppState, initialRows: [GoodreadsRow]?) {
        guard !configured else { return }
        configured = true
        self.appState = appState
        if let rows = initialRows, !rows.isEmpty {
            startSession(rows: rows)
        } else if let saved = appState.loadGoodreadsWizardSession(), saved.hasRemainingWork {
            resume(saved)
        }
    }

    // MARK: Session lifecycle

    func startSession(rows: [GoodreadsRow]) {
        parseError = nil
        var s = GoodreadsWizardSession.fromRows(rows)
        guard !s.readRows.isEmpty || !s.queueRows.isEmpty else {
            parseError = "No books were found in that file. Make sure it's your Goodreads library export (goodreads_library_export.csv)."
            return
        }
        // Re-importing a fresh export must not lose progress: Goodreads row ids
        // (Book Id column) are stable, so carry over the saved session's decisions
        // and cached matches for rows present in both. "Start over and delete
        // progress" is the explicit reset path.
        if let saved = appState?.loadGoodreadsWizardSession() {
            let ids = Set((s.readRows + s.queueRows).map(\.id))
            for (id, decision) in saved.decisions where ids.contains(id) {
                // `.unmatched` is machine-derived (and was historically written even
                // for transient lookup errors) — always re-derive it on a fresh
                // import instead of inheriting a possibly-bogus skip.
                if decision == .unmatched { continue }
                s.decisions[id] = decision
            }
            for (id, book) in saved.matchedBooks where ids.contains(id) {
                s.matchedBooks[id] = book
            }
        }
        if s.readRows.isEmpty {
            s.phase = .queuePrompt
        }
        session = s
        matchStates = s.matchedBooks.mapValues { .matched($0) }
        importedBookIds = []
        importedWorkKeys = []
        persist()
        enterStep(for: s.phase)
        warmISBNCache()
        advancePastUndecidable()
    }

    private func resume(_ saved: GoodreadsWizardSession) {
        session = saved
        matchStates = saved.matchedBooks.mapValues { .matched($0) }
        warmISBNCache()
        enterStep(for: saved.phase)
        advancePastUndecidable()
    }

    func startOver() {
        appState?.clearGoodreadsWizardSession()
        session = nil
        matchStates = [:]
        importedBookIds = []
        importedWorkKeys = []
        parseError = nil
        importError = nil
        step = .explainer
    }

    private func enterStep(for phase: GoodreadsWizardPhase) {
        switch phase {
        case .readBooks: step = .readWizard
        case .queuePrompt: step = .queuePrompt
        case .queueBooks: step = .queueWizard
        case .done: step = .done
        }
    }

    private func persist() {
        guard let s = session else { return }
        appState?.saveGoodreadsWizardSession(s)
    }

    // MARK: Matching

    private var pendingActiveRows: [GoodreadsRow] {
        guard let s = session else { return [] }
        return s.activeRows.filter { s.decisions[$0.id] == nil }
    }

    /// Resolve every undecided row's ISBN in bulk up front (batched cache check
    /// + one ISBNdb bulk request), so the per-row match lookups become cache
    /// hits. Re-kicks the match window when done, in case its first rows ran
    /// before the warm cache landed.
    private func warmISBNCache() {
        guard let s = session else { return }
        let rows = (s.readRows + s.queueRows).filter { s.decisions[$0.id] == nil && s.matchedBooks[$0.id] == nil }
        guard !rows.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.service.prefetchISBNs(for: rows)
            self.prefetchMatches()
        }
    }

    private func prefetchMatches() {
        guard let s = session, s.phase == .readBooks || s.phase == .queueBooks else { return }
        for row in pendingActiveRows.prefix(prefetchWindow) {
            guard matchStates[row.id] == nil, !inFlightRowIds.contains(row.id) else { continue }
            inFlightRowIds.insert(row.id)
            matchStates[row.id] = .matching
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.service.matchRow(row)
                self.inFlightRowIds.remove(row.id)
                switch outcome {
                case .matched(let book):
                    self.matchStates[row.id] = .matched(book)
                    self.session?.matchedBooks[row.id] = book
                    self.persist()
                case .noMatch:
                    self.matchStates[row.id] = .unmatched
                case .failed:
                    self.matchStates[row.id] = .failed
                }
                self.advancePastUndecidable()
            }
        }
    }

    /// The user found the book by hand on the match card: treat it exactly like
    /// an automatic match — the normal review card takes over (or the duplicate
    /// merge runs) with the row's Goodreads data.
    func applyManualMatch(_ book: Book) {
        guard let row = currentRow else { return }
        importError = nil
        matchStates[row.id] = .matched(book)
        session?.matchedBooks[row.id] = book
        persist()
        advancePastUndecidable()
    }

    /// Give up on a book from the manual-match card. Recorded as `.unmatched`
    /// (listed under "Couldn't match" on the summary), distinct from a user
    /// skipping a book we did find.
    func markCurrentUnmatched() {
        decideCurrent(.unmatched)
    }

    /// Skip forward over rows the user never needs to see, and push rows that
    /// didn't match cleanly (no confident match, or errored lookups) to the very
    /// end of the review queue — they come back as manual-match cards, never
    /// silently skipped.
    private func advancePastUndecidable() {
        guard var s = session else { return }
        var changed = false
        loop: while let row = s.currentRow {
            switch matchStates[row.id] {
            case .none, .matching:
                break loop
            case .unmatched, .failed:
                // Second encounter: it's already at the end — stop and show the
                // manual-match card.
                if deferredRowIds.contains(row.id) { break loop }
                deferredRowIds.insert(row.id)
                if let idx = s.readRows.firstIndex(where: { $0.id == row.id }) {
                    s.readRows.append(s.readRows.remove(at: idx))
                } else if let idx = s.queueRows.firstIndex(where: { $0.id == row.id }) {
                    s.queueRows.append(s.queueRows.remove(at: idx))
                }
                // Errored lookups get one fresh automatic try when they resurface.
                if matchStates[row.id] == .failed {
                    matchStates.removeValue(forKey: row.id)
                }
                changed = true
            case .matched(let book):
                if isDuplicate(book) {
                    // Re-read of a book already on the shelf: log the date on the
                    // existing entry (single tier entry, extra year for goals).
                    let savesReadDate = s.phase == .readBooks && row.dateRead != nil
                    if s.phase == .readBooks, let appState {
                        let dateRead = row.dateRead
                        Task { await appState.mergeGoodreadsReReadDate(book: book, dateRead: dateRead) }
                    }
                    // The row vanishes from the queue with no review card — say why.
                    ToastCenter.shared.show(.duplicateSkipped(bookTitle: book.title, readDateSaved: savesReadDate))
                    s.decisions[row.id] = .duplicate
                    changed = true
                } else {
                    break loop
                }
            }
        }
        if changed {
            session = s
            persist()
        }
        transitionIfPhaseFinished()
        prefetchMatches()
    }

    private func isDuplicate(_ book: Book) -> Bool {
        guard let appState else { return false }
        if importedBookIds.contains(book.id) { return true }
        if let key = LibraryDedup.workKey(for: book), importedWorkKeys.contains(key) { return true }
        switch session?.phase {
        case .queuePrompt, .queueBooks:
            return appState.userBook(sameWorkAs: book) != nil
        default:
            return appState.userBook(sameWorkAs: book, status: .read) != nil
        }
    }

    private func recordImported(_ book: Book) {
        importedBookIds.insert(book.id)
        if let key = LibraryDedup.workKey(for: book) { importedWorkKeys.insert(key) }
    }

    private func unrecordImported(_ book: Book) {
        importedBookIds.remove(book.id)
        if let key = LibraryDedup.workKey(for: book) { importedWorkKeys.remove(key) }
    }

    // MARK: Decisions

    private func decideCurrent(_ decision: GoodreadsRowDecision) {
        guard var s = session, let row = s.currentRow else { return }
        importError = nil
        s.decisions[row.id] = decision
        session = s
        persist()
        advancePastUndecidable()
    }

    /// A Firestore write failed after the row was optimistically marked imported:
    /// put the row back in play (and rewind the phase if it already advanced) so
    /// the book is never silently lost.
    private func revertFailedImport(rowId: String, book: Book) {
        dropUndoRecord(rowId: rowId)
        unrecordImported(book)
        guard var s = session else { return }
        s.decisions.removeValue(forKey: rowId)
        let isReadRow = s.readRows.contains { $0.id == rowId }
        if isReadRow, s.phase != .readBooks {
            s.phase = .readBooks
        } else if !isReadRow, s.phase == .done {
            s.phase = .queueBooks
        }
        session = s
        persist()
        enterStep(for: s.phase)
        importError = "\"\(book.title)\" didn't save — check your connection, then tap Add again."
    }

    func skipCurrent() {
        if let row = session?.currentRow {
            pushUndo(UndoRecord(rowId: row.id, decision: .skipped, book: nil, wasQueuedBefore: false))
        }
        decideCurrent(.skipped)
    }

    // MARK: Undo

    private func pushUndo(_ record: UndoRecord) {
        undoStack.append(record)
        canUndo = true
    }

    /// A failed import already reverted itself — its undo record is stale.
    private func dropUndoRecord(rowId: String) {
        undoStack.removeAll { $0.rowId == rowId }
        canUndo = !undoStack.isEmpty
    }

    /// Take back the most recent Skip/Add: the row's decision is cleared so its
    /// card comes back, and an added book is removed from the library again
    /// (re-queued if the import had promoted it out of the queue).
    func undoLastDecision() {
        guard let record = undoStack.popLast(), var s = session else { return }
        canUndo = !undoStack.isEmpty
        importError = nil
        s.decisions.removeValue(forKey: record.rowId)
        // Rewind the phase if that decision had closed it out.
        let isReadRow = s.readRows.contains { $0.id == record.rowId }
        if isReadRow, s.phase != .readBooks {
            s.phase = .readBooks
        } else if !isReadRow, s.phase == .done {
            s.phase = .queueBooks
        }
        session = s
        persist()
        if record.decision == .imported, let book = record.book, let appState {
            unrecordImported(book)
            if isReadRow {
                appState.removeFromReadList(book: book)
                if record.wasQueuedBefore {
                    Task { _ = await appState.importGoodreadsQueueBook(book: book) }
                }
            } else {
                appState.removeFromQueue(book: book)
            }
        }
        enterStep(for: s.phase)
        prefetchMatches()
    }

    /// "Looks good" — import with the values currently on the card (all inline-editable).
    func acceptCurrentEdited(stars: Int?, review: String?, dateFinished: Date?, tier: String?) {
        guard currentRow != nil, let book = currentBook else { return }
        importRead(
            book: book,
            rating: GoodreadsImportService.ratingOutOfTen(from: stars),
            review: review,
            dateFinished: dateFinished,
            tier: tier
        )
    }

    private func importRead(book: Book, rating: Double?, review: String?, dateFinished: Date?, tier: String?) {
        guard let appState, let rowId = session?.currentRow?.id else { return }
        pushUndo(UndoRecord(
            rowId: rowId,
            decision: .imported,
            book: book,
            wasQueuedBefore: appState.userBook(sameWorkAs: book, status: .wantToRead) != nil
        ))
        recordImported(book)
        decideCurrent(.imported)
        Task { [weak self] in
            let outcome = await appState.importGoodreadsReadBook(book: book, rating: rating, review: review, dateFinished: dateFinished, tier: tier)
            if case .failed = outcome {
                self?.revertFailedImport(rowId: rowId, book: book)
            }
        }
    }

    // MARK: Queue phase

    func chooseQueueOneByOne() {
        guard var s = session else { return }
        s.phase = .queueBooks
        session = s
        persist()
        step = .queueWizard
        advancePastUndecidable()
    }

    func declineQueue() {
        guard var s = session else { return }
        for row in s.queueRows where s.decisions[row.id] == nil {
            s.decisions[row.id] = .declined
        }
        session = s
        finish()
    }

    // MARK: Summary screen

    /// Books the user tapped Skip on (matched book included when we have it).
    var skippedBooks: [(row: GoodreadsRow, book: Book?)] {
        guard let s = session else { return [] }
        return (s.readRows + s.queueRows)
            .filter { s.decisions[$0.id] == .skipped }
            .map { ($0, s.matchedBooks[$0.id]) }
    }

    /// Books auto-skipped because they were already in the library.
    var duplicateBooks: [(row: GoodreadsRow, book: Book?)] {
        guard let s = session else { return [] }
        return (s.readRows + s.queueRows)
            .filter { s.decisions[$0.id] == .duplicate }
            .map { ($0, s.matchedBooks[$0.id]) }
    }

    /// Rows that never got a confident catalog match.
    var unmatchedRows: [GoodreadsRow] {
        guard let s = session else { return [] }
        return (s.readRows + s.queueRows).filter { s.decisions[$0.id] == .unmatched }
    }

    /// Put every user-skipped book back in play and jump back into the wizard.
    func reopenSkippedBooks() {
        guard var s = session else { return }
        var reopenedRead = false
        var reopenedQueue = false
        for row in s.readRows where s.decisions[row.id] == .skipped {
            s.decisions.removeValue(forKey: row.id)
            reopenedRead = true
        }
        for row in s.queueRows where s.decisions[row.id] == .skipped {
            s.decisions.removeValue(forKey: row.id)
            reopenedQueue = true
        }
        guard reopenedRead || reopenedQueue else { return }
        s.phase = reopenedRead ? .readBooks : .queueBooks
        session = s
        persist()
        enterStep(for: s.phase)
        advancePastUndecidable()
    }

    func acceptCurrentQueueBook() {
        guard let book = currentBook, let appState, let rowId = session?.currentRow?.id else { return }
        pushUndo(UndoRecord(rowId: rowId, decision: .imported, book: book, wasQueuedBefore: false))
        recordImported(book)
        decideCurrent(.imported)
        Task { [weak self] in
            let outcome = await appState.importGoodreadsQueueBook(book: book)
            if case .failed = outcome {
                self?.revertFailedImport(rowId: rowId, book: book)
            }
        }
    }

    // MARK: Bulk import (import-all)

    /// Import every remaining book in the active phase automatically (no tiers).
    func importAllRemaining() {
        // From the queue prompt, "Add all automatically" starts the queue phase.
        if var s = session, s.phase == .queuePrompt {
            s.phase = .queueBooks
            session = s
            persist()
        }
        guard let s = session, s.phase == .readBooks || s.phase == .queueBooks else { return }
        let rows = pendingActiveRows
        guard !rows.isEmpty else { return }
        let phase = s.phase
        bulkTotal = rows.count
        bulkDone = 0
        importError = nil
        step = .bulkImporting
        Task { [weak self] in
            guard let self, let appState = self.appState else { return }
            // Bulk-resolve every ISBN first (cache check + one bulk API call);
            // the per-row matches below then mostly read from cache.
            await self.service.prefetchISBNs(for: rows)
            var failedCount = 0
            for row in rows {
                var outcome: GoodreadsMatchOutcome
                switch self.matchStates[row.id] {
                case .matched(let b):
                    outcome = .matched(b)
                case .unmatched:
                    outcome = .noMatch
                default:
                    outcome = await self.service.matchRow(row)
                    if case .failed = outcome {
                        // Likely throttling — wait it out once before giving up on the row.
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        outcome = await self.service.matchRow(row)
                    }
                    // Light pacing for rows that miss the prefetched cache and
                    // fall to per-row API lookups (no-ISBN rows' title searches;
                    // ISBNdb's own pacer handles its tier). Prefetched rows are
                    // cache hits, so this loop is no longer API-bound.
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                switch outcome {
                case .failed:
                    // Transient error: leave the row pending (no decision) so it
                    // comes back as a manual-match card instead of being dropped.
                    self.matchStates[row.id] = .failed
                    self.deferredRowIds.insert(row.id)
                    failedCount += 1
                case .noMatch:
                    // Same: no decision — the user matches or skips it by hand.
                    self.matchStates[row.id] = .unmatched
                    self.deferredRowIds.insert(row.id)
                    failedCount += 1
                case .matched(let book):
                    self.matchStates[row.id] = .matched(book)
                    self.session?.matchedBooks[row.id] = book
                    if self.isDuplicate(book) {
                        if phase == .readBooks {
                            await appState.mergeGoodreadsReReadDate(book: book, dateRead: row.dateRead)
                        }
                        self.session?.decisions[row.id] = .duplicate
                    } else {
                        let importOutcome: AppState.GoodreadsImportOutcome
                        if phase == .readBooks {
                            importOutcome = await appState.importGoodreadsReadBook(
                                book: book,
                                rating: GoodreadsImportService.ratingOutOfTen(from: row.myRating),
                                review: row.plainTextReview,
                                dateFinished: row.dateRead ?? row.dateAdded,
                                tier: nil
                            )
                        } else {
                            importOutcome = await appState.importGoodreadsQueueBook(book: book)
                        }
                        switch importOutcome {
                        case .imported:
                            self.recordImported(book)
                            self.session?.decisions[row.id] = .imported
                        case .duplicate:
                            self.session?.decisions[row.id] = .duplicate
                        case .failed:
                            failedCount += 1
                        }
                    }
                }
                self.bulkDone += 1
                self.persist()
            }
            if failedCount > 0 {
                // Problem rows are still pending — drop back into the wizard,
                // where each gets a search-to-match card. Never silently lost.
                self.importError = "\(failedCount) book\(failedCount == 1 ? "" : "s") couldn't be imported automatically — match \(failedCount == 1 ? "it" : "them") by hand below, or skip."
                self.enterStep(for: phase)
            } else {
                self.transitionIfPhaseFinished()
            }
        }
    }

    // MARK: Phase transitions

    private func transitionIfPhaseFinished() {
        guard var s = session else { return }
        switch s.phase {
        case .readBooks:
            guard s.pendingReadCount == 0 else { return }
            // pendingQueueCount == 0 covers re-entry from "Review skipped books"
            // after the queue phase already ran — don't re-prompt for an empty queue.
            if s.queueRows.isEmpty || s.pendingQueueCount == 0 {
                finish()
            } else {
                s.phase = .queuePrompt
                session = s
                persist()
                step = .queuePrompt
            }
        case .queueBooks:
            guard s.pendingQueueCount == 0 else { return }
            finish()
        case .queuePrompt, .done:
            break
        }
    }

    private func finish() {
        guard var s = session else { return }
        s.phase = .done
        session = s
        appState?.clearGoodreadsWizardSession()
        step = .done
    }
}

// MARK: - View

struct GoodreadsImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    /// When non-nil (e.g. from Share Extension), skip the explainer and go straight to the wizard.
    var initialRows: [GoodreadsRow]? = nil

    @StateObject private var model = GoodreadsWizardModel()
    @State private var showFileImporter = false
    @State private var showExportWebView = false
    /// Goodreads bounces an unauthenticated visit to its login page, then
    /// strands the user on the homepage instead of the export page — so the
    /// explainer walks two visits: log in first ("I'm logged in" advances this
    /// flag), then reopen the same page to actually export.
    @State private var goodreadsLoginDone = false
    @State private var showImportAllConfirm = false
    @State private var showStartOverConfirm = false
    // Inline-editable card state, re-seeded from the Goodreads row for each book.
    @State private var selectedTier: String? = nil
    @State private var cardReview: String = ""
    @State private var cardDateRead: Date = Date()
    // Where the seeded date came from, so a missing Goodreads read date is
    // flagged instead of silently defaulting to today.
    @State private var cardDateNote: String? = nil
    /// "A long, long time ago": ignores the picker and stores the `ReadDate.longAgo`
    /// sentinel, for school-era books whose real date nobody knows.
    @State private var cardDateIsLongAgo = false
    /// Review editor focus — cleared whenever the card advances so the keyboard
    /// from one book never carries over to the next.
    @FocusState private var reviewFocused: Bool

    init(initialRows: [GoodreadsRow]? = nil) {
        self.initialRows = initialRows
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Import from Goodreads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            // This view lives in a sheet above MainTabView's toast host, so it
            // needs its own for duplicate-skip toasts to be visible mid-import.
            .toastHost()
            // Mid-import, a scroll attempt on the card easily reads as a sheet drag
            // and throws the drawer away. Kill swipe-to-dismiss there — Close (with
            // its progress-saved modal) is the exit. Explainer/summary stay swipeable.
            .interactiveDismissDisabled(isMidImport)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.session?.hasRemainingWork == true ? "Close" : "Cancel") {
                        dismiss()
                    }
                    .font(Theme.callout())
                    .foregroundStyle(Theme.textTertiary)
                }
                if model.session != nil {
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
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText],
                allowsMultipleSelection: false
            ) { result in
                handleFileResult(result)
            }
            .onAppear {
                model.configure(appState: appState, initialRows: initialRows)
            }
            .onChange(of: model.currentRow?.id) { _, _ in
                syncCardState()
            }
            .fullScreenCover(isPresented: $showExportWebView) {
                GoodreadsExportWebView(
                    mode: goodreadsLoginDone ? .export : .login,
                    onLoggedIn: {
                        goodreadsLoginDone = true
                        showExportWebView = false
                    },
                    onRows: { rows in
                        // Already-logged-in users can export on the first visit.
                        goodreadsLoginDone = true
                        showExportWebView = false
                        model.startSession(rows: rows)
                    }
                )
            }
            .alert("Delete import progress?", isPresented: $showStartOverConfirm) {
                Button("Delete progress", role: .destructive) { model.startOver() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Starting over deletes your place in this import and every book still waiting for review — you'd begin again from a fresh CSV. Books you've already imported stay in your library.")
            }
            .alert("Import all remaining?", isPresented: $showImportAllConfirm) {
                Button("Import all anyway") { model.importAllRemaining() }
                Button("Keep reviewing", role: .cancel) {}
            } message: {
                Text("Importing everything at once can occasionally mismatch books, so going book by book is recommended. Your progress is always saved — you can close this and pick up right where you left off anytime.")
            }
        }
    }

    /// True while the user is actively working through books (or a bulk import is
    /// running) — the steps where an accidental swipe-down would hurt.
    private var isMidImport: Bool {
        switch model.step {
        case .readWizard, .queuePrompt, .queueWizard, .bulkImporting:
            return true
        case .explainer, .done:
            return false
        }
    }

    /// Seed the inline-editable card fields from the current Goodreads row.
    /// Rows without a "Date Read" fall back to the Goodreads "Date Added"
    /// (flagged), never silently to today.
    private func syncCardState() {
        reviewFocused = false
        selectedTier = nil
        guard let row = model.currentRow else { return }
        cardReview = row.plainTextReview ?? ""
        cardDateIsLongAgo = false
        if let dateRead = row.dateRead {
            cardDateIsLongAgo = ReadDate.isLongAgo(dateRead)
            cardDateRead = cardDateIsLongAgo ? Date() : dateRead
            cardDateNote = nil
        } else if let dateAdded = row.dateAdded {
            cardDateRead = dateAdded
            cardDateNote = "No read date in your Goodreads export — this is the date you added it. Adjust if needed."
        } else {
            cardDateRead = Date()
            cardDateNote = "No date in your Goodreads export — pick when you finished it."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .explainer:
            explainerContent
        case .readWizard:
            readWizardContent
        case .queuePrompt:
            queuePromptContent
        case .queueWizard:
            queueWizardContent
        case .bulkImporting:
            bulkImportingContent
        case .done:
            doneContent
        }
    }

    // MARK: Explainer (CSV-only entry path)

    private var explainerContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("How to Import:")
                        .font(Theme.headline())
                        .foregroundStyle(Theme.textPrimary)

                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            stepNumberBadge(1, done: goodreadsLoginDone, active: !goodreadsLoginDone)
                            stepBody(
                                "Log in to Goodreads — tap the button below and sign in. Once you’re in, tap “I’m logged in”.",
                                dimmed: goodreadsLoginDone
                            )
                        }
                        // Step 2 only appears once they're back from logging in.
                        if goodreadsLoginDone {
                            GridRow {
                                stepNumberBadge(2, done: false, active: false)
                                stepBody(
                                    Text("Tap “Export Library”, then the ")
                                        + GoodreadsExportLinkMock.text
                                        + Text(" link.")
                                )
                            }
                        }
                    }
                }

                Button {
                    showExportWebView = true
                } label: {
                    HStack {
                        Image(systemName: goodreadsLoginDone ? "square.and.arrow.down" : "person.crop.circle")
                        Text(goodreadsLoginDone ? "Get my Goodreads export" : "Log in to Goodreads")
                    }
                    .font(Theme.headline())
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accentGloss)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                }
                .buttonStyle(.plain)

                if let err = model.parseError {
                    Text(err)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.cardPadding)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                showFileImporter = true
            } label: {
                Text("Already have the export file?")
                    .font(Theme.caption())
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.textTertiary)
                    .underline()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
        }
    }

    private func stepNumberBadge(_ number: Int, done: Bool, active: Bool) -> some View {
        Group {
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.background)
            } else {
                Text("\(number)")
                    .font(Theme.headline())
                    .foregroundStyle(active ? Theme.background : Theme.textPrimary)
            }
        }
        .frame(width: 28, height: 28)
        .background(
            done || active
                ? AnyShapeStyle(Theme.accentGloss)
                : AnyShapeStyle(Theme.surface)
        )
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(
                    done || active ? Color.clear : Theme.textTertiary.opacity(0.35),
                    lineWidth: 1
                )
        )
    }

    private func stepBody(_ text: String, dimmed: Bool = false) -> some View {
        stepBody(Text(text), dimmed: dimmed)
    }

    private func stepBody(_ text: Text, dimmed: Bool = false) -> some View {
        text
            .font(Theme.callout())
            .foregroundStyle(dimmed ? Theme.textTertiary : Theme.textSecondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Read-books wizard

    @ViewBuilder
    private var readWizardContent: some View {
        if let session = model.session {
            VStack(spacing: 0) {
                wizardProgressHeader(
                    position: session.currentPosition,
                    total: session.readRows.count,
                    remaining: session.pendingReadCount
                )

                importErrorBanner

                ScrollView {
                    VStack(spacing: 20) {
                        if let book = model.currentBook, let row = model.currentRow {
                            readBookCard(book: book, row: row)
                        } else if model.currentNeedsManualMatch, let row = model.currentRow {
                            manualMatchCard(row: row)
                        } else {
                            matchingCard
                        }
                    }
                    .padding(Theme.cardPadding)
                }
            }
        }
    }

    /// Shown when a save or bulk import hit a transient problem — the affected books stay pending.
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

    /// Search-to-match card for books that didn't match cleanly. Tapping a
    /// result matches it to the Goodreads row (the normal review card takes
    /// over with the row's rating/review/date), instead of opening a profile.
    private func manualMatchCard(row: GoodreadsRow) -> some View {
        ManualBookMatchCard(
            title: row.title,
            author: row.author,
            hint: "Search for it below and tap the right edition to match it. Your Goodreads rating, review, and dates come along.",
            onMatch: { model.applyManualMatch($0) },
            onSkip: { model.markCurrentUnmatched() }
        )
        .id(row.id)
    }

    private func readBookCard(book: Book, row: GoodreadsRow) -> some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                BookCoverView(book: book, size: 100)

                VStack(alignment: .leading, spacing: 8) {
                    Text(book.title)
                        .font(Theme.title2())
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    Text(book.author)
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    GoodreadsStarsRow(rating: row.myRating)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Date read")
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                        // The 1900 sentinel never reaches a picker: a long-ago read
                        // shows the chip alone, in prose.
                        if !cardDateIsLongAgo {
                            DatePicker("", selection: $cardDateRead, in: ...Date(), displayedComponents: .date)
                                .datePickerStyle(.compact)
                                .labelsHidden()
                                .tint(Theme.accent)
                        }
                        cardLongAgoChip
                        if let note = cardDateNote, !cardDateIsLongAgo {
                            Text(note)
                                .font(Theme.caption())
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            InlineTierPicker(selection: $selectedTier)

            reviewSection

            HStack(spacing: 10) {
                Button {
                    model.skipCurrent()
                } label: {
                    Text("Don't add")
                        .font(Theme.headline())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                                .strokeBorder(Theme.textTertiary.opacity(0.35), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    model.acceptCurrentEdited(
                        stars: row.myRating,
                        review: cardReview,
                        dateFinished: cardDateIsLongAgo ? ReadDate.longAgo : cardDateRead,
                        tier: selectedTier
                    )
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .bold))
                        Text("Add")
                            .font(Theme.headline())
                    }
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accentGloss)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { syncCardState() }
    }

    /// Catch-all for books read so long ago the exact date is a guess. Stores the
    /// `ReadDate.longAgo` sentinel, shown as "Old" everywhere the read date appears.
    private var cardLongAgoChip: some View {
        Button {
            cardDateIsLongAgo.toggle()
            // Turning it off must land on a real date, not Jan 1, 1900.
            if !cardDateIsLongAgo, ReadDate.isLongAgo(cardDateRead) {
                cardDateRead = Date()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: cardDateIsLongAgo ? "checkmark" : "hourglass")
                    .font(.system(size: 11, weight: .bold))
                Text("A long, long time ago")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(cardDateIsLongAgo ? Theme.onChrome : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(cardDateIsLongAgo ? Theme.chrome : Theme.surface)
            )
            .overlay(
                Capsule().stroke(Theme.chrome.opacity(cardDateIsLongAgo ? 0 : 0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private func cardSectionLabel(_ text: String) -> some View {
        Text(SpinesGlyphs.caps(text))
            .font(.system(size: 11, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(Theme.chrome)
    }

    /// Inline-editable review with a one-tap wipe button (doesn't focus the keyboard).
    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                cardSectionLabel("Your review")
                Spacer()
                if !cardReview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        cardReview = ""
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                            Text("CLEAR")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.5)
                        }
                        .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            ZStack(alignment: .topLeading) {
                if cardReview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Thoughts on this book…")
                        .font(Theme.body())
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $cardReview)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90, maxHeight: 180)
                    .focused($reviewFocused)
            }
            .padding(10)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.chrome.opacity(0.3), lineWidth: Theme.chromeHairline)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var matchingCard: some View {
        VStack(spacing: 20) {
            SpinningSpineLogo()
            Text("Finding your book…")
                .font(Theme.title2())
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
    }

    private func wizardProgressHeader(position: Int, total: Int, remaining: Int) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("BOOK \(position) OF \(total)")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Theme.textPrimary)
                if model.canUndo {
                    Button {
                        model.undoLastDecision()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Undo")
                                .font(Theme.caption())
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.surface)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Theme.textTertiary.opacity(0.35), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    showImportAllConfirm = true
                } label: {
                    Text("Import all")
                        .font(Theme.caption())
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.surface)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Theme.textTertiary.opacity(0.35), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(remaining == 0)
            }
            ProgressView(value: Double(max(0, total - remaining)), total: Double(max(total, 1)))
                .tint(Theme.accent)
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: Queue prompt + wizard

    private var queuePromptContent: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(Theme.chrome)
            VStack(spacing: 8) {
                Text("Read books done!")
                    .font(Theme.title2())
                    .foregroundStyle(Theme.textPrimary)
                Text("You have \(model.session?.pendingQueueCount ?? 0) books on your Goodreads to-read shelf. Add them to the Backlog section in your queue?")
                    .font(Theme.callout())
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            VStack(spacing: 10) {
                Button {
                    model.importAllRemaining()
                } label: {
                    Text("Add all automatically")
                        .font(Theme.headline())
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accentGloss)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                }
                .buttonStyle(.plain)

                Button {
                    model.chooseQueueOneByOne()
                } label: {
                    Text("Review one by one")
                        .font(Theme.headline())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                                .strokeBorder(Theme.textTertiary.opacity(0.35), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    model.declineQueue()
                } label: {
                    Text("No thanks")
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(Theme.cardPadding)
    }

    @ViewBuilder
    private var queueWizardContent: some View {
        if let session = model.session {
            VStack(spacing: 0) {
                wizardProgressHeader(
                    position: session.currentPosition,
                    total: session.queueRows.count,
                    remaining: session.pendingQueueCount
                )

                importErrorBanner

                ScrollView {
                    VStack(spacing: 20) {
                        if let book = model.currentBook {
                            queueBookCard(book: book)
                        } else if model.currentNeedsManualMatch, let row = model.currentRow {
                            manualMatchCard(row: row)
                        } else {
                            matchingCard
                        }
                    }
                    .padding(Theme.cardPadding)
                }
            }
        }
    }

    private func queueBookCard(book: Book) -> some View {
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

            HStack(spacing: 10) {
                Button {
                    model.skipCurrent()
                } label: {
                    Text("Don't add")
                        .font(Theme.headline())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                                .strokeBorder(Theme.textTertiary.opacity(0.35), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    model.acceptCurrentQueueBook()
                } label: {
                    Text("Add to queue")
                        .font(Theme.headline())
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accentGloss)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Bulk importing + done

    private var bulkImportingContent: some View {
        VStack(spacing: 24) {
            ProgressView(value: Double(model.bulkDone), total: Double(max(1, model.bulkTotal)))
                .tint(Theme.accent)
                .padding(.horizontal, 32)
            Text("Importing… \(model.bulkDone) of \(model.bulkTotal)")
                .font(Theme.callout())
                .foregroundStyle(Theme.textSecondary)
            Text("Keep the app open — this can take a bit for a large library.")
                .font(Theme.caption())
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text("Maybe leave your phone inside and touch grass.")
                .font(Theme.caption())
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var doneContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 32)
                Text("Import complete")
                    .font(Theme.title2())
                    .foregroundStyle(Theme.textPrimary)

                if let s = model.session {
                    doneStatLine("\(s.importedCount) imported")
                }

                duplicateBooksSection

                skippedBooksSection

                unmatchedBooksSection

                Button {
                    let count = model.session?.importedCount ?? 0
                    dismiss()
                    ToastCenter.shared.show(.importedBooks(count: count))
                } label: {
                    Text("Done")
                        .font(Theme.headline())
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accentGloss)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(Theme.cardPadding)
            .padding(.bottom, 16)
        }
    }

    private func doneStatLine(_ text: String) -> some View {
        Text(text)
            .font(Theme.callout())
            .foregroundStyle(Theme.textSecondary)
    }

    /// Bulleted title-and-author list used by the summary sections.
    private func summaryBookList(_ items: [(row: GoodreadsRow, book: Book?)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.row.id) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("·")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textTertiary)
                    Text(item.book?.title ?? item.row.title)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(item.book?.author ?? item.row.author)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Books that were already in the library — auto-skipped, listed so the user
    /// knows exactly where they went (nothing was lost or duplicated).
    @ViewBuilder
    private var duplicateBooksSection: some View {
        let duplicates = model.duplicateBooks
        if !duplicates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                cardSectionLabel("Already in your library · \(duplicates.count)")
                Text("These were skipped automatically so you don't end up with duplicates.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
                summaryBookList(duplicates)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .strokeBorder(Theme.chrome.opacity(0.3), lineWidth: Theme.chromeHairline)
            )
        }
    }

    /// Books the user skipped, with a way to jump back into the wizard for them.
    @ViewBuilder
    private var skippedBooksSection: some View {
        let skipped = model.skippedBooks
        if !skipped.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                cardSectionLabel("Skipped by you · \(skipped.count)")
                summaryBookList(skipped)
                Button {
                    model.reopenSkippedBooks()
                } label: {
                    Text("Review skipped books")
                        .font(Theme.callout())
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                                .strokeBorder(Theme.textTertiary.opacity(0.35), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .strokeBorder(Theme.chrome.opacity(0.3), lineWidth: Theme.chromeHairline)
            )
        }
    }

    /// Rows with no confident catalog match — listed so the user can add them manually.
    @ViewBuilder
    private var unmatchedBooksSection: some View {
        let unmatched = model.unmatchedRows
        if !unmatched.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                cardSectionLabel("Couldn't match · \(unmatched.count)")
                summaryBookList(unmatched.map { ($0, nil) })
                Text("You can add these by hand with Search.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .strokeBorder(Theme.chrome.opacity(0.3), lineWidth: Theme.chromeHairline)
            )
        }
    }

    // MARK: File handling

    private func handleFileResult(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else {
            model.parseError = "Couldn't open that file. Try picking it again."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let rows = GoodreadsCSVParser.parse(data: data)
            if rows.isEmpty {
                model.parseError = "No book data found in that file. Make sure you picked your Goodreads library export (goodreads_library_export.csv)."
            } else {
                model.startSession(rows: rows)
            }
        } catch {
            model.parseError = "Couldn't read that file. Try downloading your export again."
        }
    }
}

// MARK: - Manual match card

/// Shown for books that didn't match cleanly (deferred to the end of the review
/// queue). The user searches the catalog and taps a result to match it with the
/// Goodreads row — the wizard then imports the row's data for that book. Books
/// are never lost here: the only exits are a manual match or an explicit skip.
/// Search-to-match card for a book the automatic lookup couldn't place. Shared
/// by the Goodreads import and the link → queue wizard: `title`/`author` are
/// whatever the source said, `hint` explains what tapping a result does.
struct ManualBookMatchCard: View {
    let title: String
    let author: String
    let hint: String
    let onMatch: (Book) -> Void
    let onSkip: () -> Void

    @State private var query: String = ""
    @State private var results: [Book] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>? = nil

    private static let maxResults = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't match this book automatically")
                    .font(Theme.headline())
                    .foregroundStyle(Theme.textPrimary)
                Text(author.isEmpty ? title : "\(title) — \(author)")
                    .font(Theme.callout())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(hint)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search by title or author", text: $query)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textPrimary)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { runSearch(debounce: false) }
                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                        searchError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.chrome.opacity(0.3), lineWidth: Theme.chromeHairline)
            )

            if isSearching {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.accent)
                    Text("Searching…")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if let err = searchError {
                Text(err)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if results.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No results — try fewer words or a different spelling.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
            } else {
                VStack(spacing: 8) {
                    ForEach(results.prefix(Self.maxResults)) { book in
                        Button {
                            onMatch(book)
                        } label: {
                            HStack(spacing: 10) {
                                BookCoverView(book: book, size: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(book.title)
                                        .font(Theme.callout())
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text(book.author)
                                        .font(Theme.caption())
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text("Select")
                                    .font(Theme.caption())
                                    .fontWeight(.medium)
                                    .foregroundStyle(Theme.onChrome)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Theme.accent)
                                    .clipShape(Capsule())
                            }
                            .padding(8)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                onSkip()
            } label: {
                Text("Skip this book")
                    .font(Theme.callout())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                            .strokeBorder(Theme.textTertiary.opacity(0.35), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            let mainTitle = GoodreadsTitleMatcher.mainTitle(title)
            let primaryAuthor = GoodreadsTitleMatcher.primaryAuthor(author)
            query = (primaryAuthor == "Unknown" || primaryAuthor.isEmpty) ? mainTitle : "\(mainTitle) \(primaryAuthor)"
            runSearch(debounce: false)
        }
        .onChange(of: query) { _, _ in
            runSearch(debounce: true)
        }
    }

    private func runSearch(debounce: Bool) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            searchError = nil
            isSearching = false
            return
        }
        searchTask = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            guard !Task.isCancelled else { return }
            isSearching = true
            do {
                let books = try await GoogleBooksService.shared.search(query: trimmed)
                // A cancelled task was superseded by a newer search — leave its state alone.
                guard !Task.isCancelled else { return }
                results = books
                searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                searchError = "Search didn't go through — check your connection and try again."
            }
            isSearching = false
        }
    }
}

// MARK: - Goodreads stars (read-only)

private struct GoodreadsStarsRow: View {
    let rating: Int?

    var body: some View {
        HStack(spacing: 3) {
            if let r = rating, r > 0 {
                ForEach(1...5, id: \.self) { i in
                    Image(systemName: i <= r ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundStyle(i <= r ? Theme.accent : Theme.textTertiary.opacity(0.6))
                }
            } else {
                Text("No rating")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// Tier picker moved to TierBadge.swift as `InlineTierPicker` so the mark-as-read
// card can share it.
