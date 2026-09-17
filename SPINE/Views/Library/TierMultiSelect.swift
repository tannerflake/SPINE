//
//  TierMultiSelect.swift
//  SPINE
//
//  Multi-select inside the tier list. Double-tapping a cover picks that book
//  and opens a bottom action bar; from there the selection can move to another
//  tier, leave the read shelf, or get one cover regeneration per book. This
//  file owns the action bar, the tier picker sheet, and the batch cover-fix
//  runner. TierListView owns the selection set itself.
//

import SwiftUI

// MARK: - Actions supplied by the owning library page

/// What the library page lets a selection do. Nil on TierListView means
/// multi-select is off (someone else's library, the Discover seed picker).
struct TierMultiSelectActions {
    /// Move these read books (in display order) to `tier`, appended at the end.
    /// nil tier = Unranked.
    let moveToTier: ([UUID], String?) -> Void
    /// Remove these read books, reviews and feed posts included. Returns how
    /// many failed.
    let remove: ([UUID]) async -> Int
    /// Re-file these read books under `year`, the same move the list view's
    /// "Move to year" sheet performs.
    let setReadYear: ([UUID], Int) -> Void
    /// Signed-in uid that cover regeneration writes are attributed to. Nil hides
    /// the cover action.
    let userId: String?
}

/// Multi-select plumbing TierListView hands down to every cell.
struct TierCellSelection {
    let isSelecting: Bool
    let selectedIds: Set<UUID>
    let coverFixStatuses: [UUID: TierCoverFixStatus]
    /// Single tap while selecting: flip this book in or out of the selection.
    let onToggle: (UUID) -> Void
    /// Double tap outside selection mode: start selecting with this book.
    let onEnter: (UUID) -> Void
}

// MARK: - Batch cover regeneration

/// Per-book outcome badge drawn on the cover while a batch fix runs and
/// afterwards, until the member keeps or undoes the run.
enum TierCoverFixStatus: Equatable {
    case working
    /// A new, visually different cover is now showing.
    case changed
    /// Every candidate was the same artwork or failed to load.
    case noAlternative
    /// No cover could be resolved at all.
    case failed
}

/// Runs "Bad cover?" once per selected book, one book at a time (the fallback
/// chain and the iTunes lookup both rate-limit), reporting progress as it goes.
/// Covers repaint live in the tier rows through `bookCoverResolutionDidChange`,
/// so the member watches each new cover land in place. Leaving the results in
/// place is the default, matching the single-book flow: `keep()` just clears
/// the badges, `undoAll` puts every changed cover back.
@MainActor
final class TierCoverFixRunner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(done: Int, total: Int)
        /// `attempted` < the selection size when the member stopped early.
        case finished(changed: Int, attempted: Int, total: Int)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statuses: [UUID: TierCoverFixStatus] = [:]

    /// Books whose cover changed this run, so "Undo all" can restore each one.
    private var changedBooks: [Book] = []
    private var task: Task<Void, Never>?
    /// Bumped by every start/reset so a run that was abandoned (the member left
    /// selection mode mid-fix) finishes its in-flight book silently instead of
    /// writing stale progress over a fresh state.
    private var generation = 0

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    var isShowingResults: Bool {
        if case .finished = phase { return true }
        return false
    }

    func start(books: [UserBook], userId: String) {
        guard !isWorking else { return }
        let targets = books.filter { $0.book != nil }
        guard !targets.isEmpty else { return }
        statuses = [:]
        changedBooks = []
        generation += 1
        let gen = generation
        phase = .working(done: 0, total: targets.count)

        task = Task { [weak self] in
            var changed = 0
            var attempted = 0
            for ub in targets {
                guard let self, self.generation == gen, let book = ub.book else { return }
                self.statuses[ub.id] = .working
                // The in-flight book always runs to completion: a cover that
                // already changed must be reported, not silently kept.
                let status = await Self.regenerateOnce(book: book, userId: userId)
                guard self.generation == gen else { return }
                self.statuses[ub.id] = status
                attempted += 1
                if status == .changed {
                    changed += 1
                    self.changedBooks.append(book)
                }
                self.phase = .working(done: attempted, total: targets.count)
                if Task.isCancelled { break }
            }
            guard let self, self.generation == gen else { return }
            self.phase = .finished(changed: changed, attempted: attempted, total: targets.count)
        }
    }

    /// Stops after the book currently being processed. The summary then covers
    /// only what was attempted.
    func stop() {
        task?.cancel()
    }

    /// Restore every cover this run changed and clear the badges.
    func undoAll(userId: String) {
        for book in changedBooks {
            CoverRegenerationService.shared.undo(book: book, userId: userId)
        }
        reset()
    }

    /// Accept the run: the new covers are already shared, so this only clears
    /// the badges. Single-book undo stays available on each book's profile.
    func keep() {
        reset()
    }

    private func reset() {
        generation += 1
        task?.cancel()
        task = nil
        changedBooks = []
        statuses = [:]
        phase = .idle
    }

    /// Same decision tree as BookProfileView's "Bad cover?" tap: a book with no
    /// resolved cover gets a chain retry first, then one regeneration.
    private static func regenerateOnce(book: Book, userId: String) async -> TierCoverFixStatus {
        // No candidate URLs at all: BookCoverView draws the title-only jacket
        // without consulting the resolution store, so even a lookup hit could
        // never show. Report it honestly instead of a "new cover" that isn't there.
        guard !book.coverImageURLsToTry.isEmpty else { return .failed }
        let service = CoverRegenerationService.shared
        var recoveredFromPlaceholder = false
        if !service.canRegenerate(book: book), !service.hasActiveSession(bookId: book.id) {
            let found = await service.retryResolve(book: book)
            guard found, service.canRegenerate(book: book) else { return .failed }
            recoveredFromPlaceholder = true
        }
        switch await service.regenerate(book: book, userId: userId) {
        case .applied:
            return .changed
        case .exhausted, .failed:
            // A title placeholder that just turned into a real cover is a fix in
            // its own right, even if no second candidate exists.
            return recoveredFromPlaceholder ? .changed : .noAlternative
        }
    }
}

// MARK: - Cover badges

/// Small status glyph pinned to a cover's top-trailing corner during and after a
/// batch cover fix. Replaces the selection check so the two never stack.
struct TierCoverFixBadge: View {
    let status: TierCoverFixStatus

    var body: some View {
        Group {
            switch status {
            case .working:
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.onChrome)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.chrome))
            case .changed:
                glyph("arrow.2.squarepath", fill: Theme.chrome, ink: Theme.onChrome)
            case .noAlternative:
                glyph("minus", fill: Theme.textTertiary, ink: Theme.background)
            case .failed:
                glyph("exclamationmark", fill: Theme.danger, ink: Theme.onChrome)
            }
        }
        .background(Circle().fill(Theme.background).padding(-1.5))
        .accessibilityLabel(accessibilityText)
    }

    private func glyph(_ name: String, fill: Color, ink: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(ink)
            .frame(width: 18, height: 18)
            .background(Circle().fill(fill))
    }

    private var accessibilityText: String {
        switch status {
        case .working: return "Finding a new cover"
        case .changed: return "New cover"
        case .noAlternative: return "No other cover found"
        case .failed: return "Cover not found"
        }
    }
}

// MARK: - Cover refresh glyph

/// A book cover (portrait rectangle, softly rounded) holding a faint picture
/// (hills and sky, the usual "image" motif) with refresh arrows over it. SF
/// Symbols only offers photo/upload-flavoured cover icons, which read as "pick
/// an image from my library" rather than "go find a better cover", so this one
/// is drawn by hand.
struct CoverRefreshGlyph: View {
    var tint: Color
    /// Height of the cover rectangle; the width follows a book-ish trim.
    var height: CGFloat = 18

    private var width: CGFloat { (height * 0.74).rounded() }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .strokeBorder(tint, lineWidth: 1.4)
                .frame(width: width, height: height)

            // Artwork sitting in the lower half of the jacket, faint enough that
            // the arrows stay the thing you read first. Clipped to the inside of
            // the outline so it never spills over the stroke.
            Image(systemName: "mountain.2.fill")
                .font(.system(size: height * 0.48))
                .foregroundStyle(tint.opacity(0.3))
                .frame(width: width - 3, height: height - 3, alignment: .bottom)
                .clipped()

            // Sized to sit clear of the cover outline on every side.
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: height * 0.38, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: height, height: height)
    }
}

// MARK: - Bottom action bar

/// Floating bar that rides above the tab bar while books are selected. Three
/// faces: the normal action row, the cover-fix progress row, and the cover-fix
/// results row (keep / undo all).
struct TierSelectionActionBar: View {
    @Environment(\.mainTabBarOverlapExtraHeight) private var mainTabBarOverlapExtraHeight

    let selectionCount: Int
    let coverFixPhase: TierCoverFixRunner.Phase
    /// False when there's no signed-in user to attribute cover edits to.
    let canFixCovers: Bool
    let onDone: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void
    let onEditDate: () -> Void
    let onFixCovers: () -> Void
    let onStopFixing: () -> Void
    let onUndoCovers: () -> Void
    let onKeepCovers: () -> Void

    var body: some View {
        Group {
            switch coverFixPhase {
            case .idle:
                actionRow
            case .working(let done, let total):
                progressRow(done: done, total: total)
            case .finished(let changed, let attempted, let total):
                resultsRow(changed: changed, attempted: attempted, total: total)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .strokeBorder(Theme.chrome.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Theme.shadowInk.opacity(0.2), radius: 10, y: 4)
        .padding(.horizontal, 12)
        // Same lift the floating + button uses so the bar clears the tab pill.
        .padding(.bottom, mainTabBarOverlapExtraHeight + 12)
        .animation(.easeInOut(duration: 0.2), value: coverFixPhase)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var countText: String {
        switch selectionCount {
        case 0: return "Select"
        case 1: return "1 book"
        default: return "\(selectionCount) books"
        }
    }

    // MARK: Faces

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(action: onDone) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done selecting")

            // The count is the one flexible piece: on a 390pt phone the three
            // actions need all the room they can get, so it shrinks before
            // anything else wraps.
            Text(countText)
                .font(Theme.callout().weight(.semibold))
                .foregroundStyle(selectionCount == 0 ? Theme.textTertiary : Theme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(-1)

            Spacer(minLength: 2)

            iconAction(label: "Remove from read shelf", action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.danger)
            }
            iconAction(label: "Change year read", action: onEditDate) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            if canFixCovers {
                iconAction(label: "Fix covers", action: onFixCovers) {
                    CoverRefreshGlyph(tint: Theme.textPrimary)
                }
            }

            Button(action: onMove) {
                Label("Move", systemImage: "arrow.up.arrow.down")
                    .fixedSize()
            }
            .buttonStyle(.spine(.primary, size: .small, fullWidth: false))
            .disabled(selectionCount == 0)
        }
    }

    private func iconAction<Glyph: View>(
        label: String,
        action: @escaping () -> Void,
        @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        Button(action: action) {
            glyph()
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.surface))
        }
        .buttonStyle(.plain)
        .disabled(selectionCount == 0)
        .opacity(selectionCount == 0 ? 0.4 : 1)
        .accessibilityLabel(label)
    }

    private func progressRow(done: Int, total: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.chrome)
                    Text("Finding new covers")
                        .font(Theme.callout().weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(done) of \(total)")
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(Theme.chrome)
            }
            Spacer(minLength: 4)
            Button(action: onStopFixing) {
                Text("Stop")
                    .font(Theme.callout().weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Theme.surface))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func resultsRow(changed: Int, attempted: Int, total: Int) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(resultsTitle(changed: changed, attempted: attempted))
                    .font(Theme.callout().weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let detail = resultsDetail(changed: changed, attempted: attempted, total: total) {
                    Text(detail)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if changed > 0 {
                Button(action: onUndoCovers) {
                    Label("Undo all", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.spine(.secondary, size: .small, fullWidth: false))
            }
            Button(changed > 0 ? "Keep" : "OK", action: onKeepCovers)
                .buttonStyle(.spine(.primary, size: .small, fullWidth: false))
        }
    }

    private func resultsTitle(changed: Int, attempted: Int) -> String {
        if changed == 0 { return "No new covers found" }
        if changed == attempted { return changed == 1 ? "New cover found" : "\(changed) new covers found" }
        return "New covers for \(changed) of \(attempted)"
    }

    private func resultsDetail(changed: Int, attempted: Int, total: Int) -> String? {
        var parts: [String] = []
        let stopped = total - attempted
        if stopped > 0 {
            parts.append(stopped == 1 ? "1 book skipped" : "\(stopped) books skipped")
        }
        if changed > 0 {
            parts.append("Undo one at a time from its book page.")
        } else if attempted > 0 {
            parts.append("Nothing different turned up for these books.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: - Target tier picker

/// Pick the tier the selection moves to. Every tier is listed with its color
/// swatch and current count; the tier the whole selection already sits in is
/// shown but disabled so the sheet still reads as the full ladder.
struct MoveToTierSheet: View {
    let selectionCount: Int
    /// Books per tier right now (key nil = Unranked), for the trailing counts.
    let tierCounts: [String?: Int]
    /// Non-nil when every selected book is already in this tier.
    let commonTier: String??
    let onMove: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    /// S through F, then Unranked.
    private var ladder: [String?] {
        spineTierLabels.map { Optional($0) } + [nil]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(SpinesGlyphs.caps(selectionCount == 1 ? "Move 1 book to" : "Move \(selectionCount) books to"))
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.chrome)
                        .padding(.bottom, 2)
                    ForEach(ladder, id: \.self) { tier in
                        tierRow(tier)
                    }
                    Text("Books land at the end of the tier, in the order they're in now.")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 6)
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Move to tier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func tierRow(_ tier: String?) -> some View {
        let isCurrent: Bool = {
            guard let commonTier else { return false }
            return commonTier == tier
        }()
        let count = tierCounts[tier] ?? 0
        return Button {
            onMove(tier)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(spineTierColor(for: tier))
                    if let tier {
                        Text(tier)
                            .font(Theme.headline())
                            .foregroundStyle(Color.black.opacity(0.75))
                    } else {
                        Image(systemName: "minus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tier.map { "\($0) Tier" } ?? "Unranked")
                        .font(Theme.headline())
                        .foregroundStyle(Theme.textPrimary)
                    if isCurrent {
                        Text("Already here")
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 8)
                Text(count == 1 ? "1 book" : "\(count) books")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .strokeBorder(Theme.chrome.opacity(0.25), lineWidth: 1)
            )
            .opacity(isCurrent ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .accessibilityLabel(tier.map { "\($0) Tier" } ?? "Unranked")
        .accessibilityHint(isCurrent ? "Already in this tier" : "")
    }
}

// MARK: - Drag-time discovery tip

/// Lightweight nudge that rides above the tab bar while a cover is in hand:
/// dragging one book at a time is exactly the moment double-tap multi-select
/// is worth knowing about. Purely decorative, so it never eats a drop.
struct TierMultiSelectDragTip: View {
    @Environment(\.mainTabBarOverlapExtraHeight) private var mainTabBarOverlapExtraHeight

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Tip: Double tap a book to multi-select")
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceElevated)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Theme.chrome.opacity(0.35), lineWidth: 1))
        .shadow(color: Theme.shadowInk.opacity(0.18), radius: 8, y: 3)
        // Centered in the space left of the floating + button rather than the
        // full width, so the pill never sits under it.
        .padding(.leading, 12)
        .padding(.trailing, 76)
        .padding(.bottom, mainTabBarOverlapExtraHeight + 12)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
