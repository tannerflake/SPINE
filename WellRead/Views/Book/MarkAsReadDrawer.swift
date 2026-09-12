//
//  MarkAsReadDrawer.swift
//  Spine
//
//  The "Mark as read" drawer: a full-height sheet where Thoughts is the hero
//  and grows with the review, with the finish date, tier, and feed toggle
//  underneath and the confirm button pinned above the keyboard. Every edit is
//  persisted on-device via `ReadDraftStore`, so swiping the drawer away never
//  loses a half-written review; the user gets a toast telling them so, and the
//  draft comes back the next time they open this book.
//
//  Used from the book profile (FINISHED button) and the queue → Read drop in
//  the library. Present with `.sheet`; the drawer sizes itself.
//

import SwiftUI

struct MarkAsReadDrawer: View {
    /// Draft key. Stable across the profile and queue entry points.
    let bookId: String
    /// Header cover + title. `nil` for legacy queue rows whose book never hydrated.
    let book: Book?
    var fallbackTitle: String = "Book"
    /// (dateFinished, rating, postToFeed, thoughts, tier). Tier nil = Unranked → tier-list "Rank me" prompt.
    let onConfirm: (Date, Double?, Bool, String?, String?) -> Void
    /// Re-read mode: the book is already on the read shelf and this logs another
    /// read of it. Same drawer, different copy, and its own draft slot so a
    /// half-written re-read never collides with a first-finish draft.
    var isAdditionalRead: Bool = false
    /// One-line note under the header, e.g. the reads already logged.
    var subtitle: String? = nil
    /// Seeded into the fields when there's no saved draft. A re-read starts from
    /// the existing review, rating-free tier, and feed choice so confirming
    /// doesn't quietly wipe what the user already wrote.
    var initialThoughts: String = ""
    var initialTier: String? = nil
    var initialPostToFeed: Bool = true

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isThoughtsFocused: Bool
    /// Roster for @mention autocomplete in Thoughts.
    @ObservedObject private var mentionCatalog = MentionCatalog.shared

    @State private var thoughts = ""
    /// Starts empty on purpose: defaulting to today let users save without ever
    /// noticing the date, so finished-on dates silently became "whenever I tapped".
    @State private var dateFinished: Date? = nil
    @State private var selectedTier: String? = nil
    @State private var postToFeed = true
    @State private var showDatePopover = false
    @State private var showDateError = false
    /// True when this open restored a saved draft; shows the "picked up" row.
    @State private var restoredDraft = false
    /// Set on confirm so the disappear hook knows not to announce a saved draft.
    @State private var didConfirm = false
    /// Draft restore / seeding runs once per presentation.
    @State private var didPrepare = false

    private var title: String { book?.title ?? fallbackTitle }

    /// Re-read drafts live in their own slot, keyed off the same book.
    private var draftKey: String { isAdditionalRead ? "\(bookId)#reread" : bookId }

    /// True while nothing has been changed from what the drawer opened with. A
    /// re-read opens pre-filled, so "has content" alone can't tell an untouched
    /// drawer from a real draft.
    private var isSeededState: Bool {
        thoughts == initialThoughts
            && dateFinished == nil
            && selectedTier == initialTier
            && postToFeed == initialPostToFeed
    }

    private var currentDraft: ReadDraft {
        ReadDraft(thoughts: thoughts, dateFinished: dateFinished, tier: selectedTier, postToFeed: postToFeed)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header

                        if restoredDraft {
                            restoredDraftRow
                        }

                        thoughtsSection
                            .id("thoughts")

                        dateSection
                            .id("dateFinished")

                        InlineTierPicker(selection: $selectedTier)

                        Toggle(isOn: $postToFeed) {
                            Text("Post to feed")
                                .font(Theme.callout())
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .tint(Theme.toggleOn)
                    }
                    .padding(20)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                /// Scroll once on focus only — per-keystroke scroll caused lag and "variant selector cell index" errors.
                .onChange(of: isThoughtsFocused) { _, focused in
                    if focused {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("thoughts", anchor: .top)
                            }
                        }
                    }
                }
                // The confirm button is pinned at the bottom; the date field it
                // complains about may be scrolled away. Bring the error into view.
                .onChange(of: showDateError) { _, showing in
                    if showing {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("dateFinished", anchor: .center)
                        }
                    }
                }
            }
            .background(Theme.background)
            .safeAreaInset(edge: .bottom) { confirmBar }
            .navigationTitle(isAdditionalRead ? "Log another read" : "Mark as read")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.springPress)
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
        // Half-typed thoughts survive a deep-link tap: the drawer stays put and
        // the link lands once they finish or close.
        .composerDraftGuard(isSeededState ? "" : thoughts)
        .onAppear(perform: restoreDraftIfAny)
        .onChange(of: thoughts) { _, _ in persistDraft() }
        .onChange(of: dateFinished) { _, _ in persistDraft() }
        .onChange(of: selectedTier) { _, _ in persistDraft() }
        .onChange(of: postToFeed) { _, _ in persistDraft() }
        .onDisappear {
            // Swipe-down, the X, or a deep-link teardown: the draft is already on
            // disk, so just tell them it's safe.
            guard !didConfirm, !isSeededState, currentDraft.hasContent else { return }
            ToastCenter.shared.show(.draftSaved(bookTitle: title))
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 14) {
            if let book {
                BookCoverView(book: book, size: 64)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.headline())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                if let author = book?.author, !author.isEmpty {
                    Text(author)
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var restoredDraftRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.chrome)
            Text("Picked up where you left off")
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Button {
                withAnimation(.easeOut(duration: 0.2)) { discardDraft() }
            } label: {
                Text("DISCARD")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.springPress)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.chrome.opacity(0.25), lineWidth: Theme.chromeHairline)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// The hero: a review box that starts tall and grows with the text (the
    /// page scrolls, the editor never traps the user in a tiny inner scroll).
    private var thoughtsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Thoughts")
            ZStack(alignment: .topLeading) {
                if thoughts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("What did you think? Tag a friend with @")
                        .font(Theme.body())
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $thoughts)
                    .font(Theme.body())
                    .lineSpacing(Theme.bodyLineSpacing)
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(minHeight: 200)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($isThoughtsFocused)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isThoughtsFocused ? Theme.chrome : Theme.chrome.opacity(0.35), lineWidth: isThoughtsFocused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: isThoughtsFocused)
            .onTapGesture { isThoughtsFocused = true }

            // Tag readers with "@" — suggestions appear one letter in.
            if let query = MentionScanner.activeQuery(in: thoughts) {
                let matches = mentionCatalog.suggestions(matching: query)
                if !matches.isEmpty {
                    MentionSuggestionBar(suggestions: matches) { user in
                        thoughts = MentionScanner.insertMention(
                            handle: user.username.lowercased(),
                            into: thoughts
                        )
                    }
                }
            }
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(isAdditionalRead ? "Finished this read on" : "Finished on")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    pickDateChip
                    dateChip("Today", date: Date())
                    Spacer(minLength: 0)
                }
                longAgoChip
            }
            if showDateError {
                Text(isAdditionalRead ? "Add the date you finished this read." : "Add the date you finished this book.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .transition(.opacity)
            }
        }
    }

    private func dateChip(_ label: String, date: Date) -> some View {
        let isSelected = dateFinished.map {
            !ReadDate.isLongAgo($0) && Calendar.current.isDate($0, inSameDayAs: date)
        } ?? false
        return Button {
            isThoughtsFocused = false
            withAnimation(.easeOut(duration: 0.15)) {
                dateFinished = date
                showDateError = false
            }
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.onChrome : Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(isSelected ? Theme.chrome : Theme.surfaceElevated)
                )
                .overlay(
                    Capsule().stroke(Theme.chrome.opacity(isSelected ? 0 : 0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.springPress)
    }

    /// Calendar chip. Shows the picked date when it isn't today or "Old".
    private var pickDateChip: some View {
        let isCustom: Bool = {
            guard let d = dateFinished else { return false }
            return !Calendar.current.isDateInToday(d) && !ReadDate.isLongAgo(d)
        }()
        return Button {
            isThoughtsFocused = false
            showDatePopover = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                Text(isCustom ? (dateFinished?.formatted(date: .abbreviated, time: .omitted) ?? "") : "Pick a date")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isCustom ? Theme.onChrome : Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(isCustom ? Theme.chrome : Theme.surfaceElevated)
            )
            .overlay(
                Capsule().stroke(showDateError ? Theme.danger : Theme.chrome.opacity(isCustom ? 0 : 0.4), lineWidth: showDateError ? 1.5 : 1)
            )
        }
        .buttonStyle(.springPress)
        .popover(isPresented: $showDatePopover) {
            DatePicker(
                "",
                selection: Binding(
                    get: {
                        guard let d = dateFinished, !ReadDate.isLongAgo(d) else { return Date() }
                        return d
                    },
                    set: { dateFinished = $0 }
                ),
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .tint(Theme.accent)
            .padding(12)
            // The graphical calendar has no usable intrinsic width inside a
            // popover — without an explicit frame it collapses to a narrow
            // clipped column. Size it to the calendar's natural dimensions.
            .frame(width: 320, height: 360)
            .presentationCompactAdaptation(.popover)
            // Tapping a specific day changes the selection — close the calendar
            // immediately instead of waiting for the user to tap outside it.
            .onChange(of: dateFinished) { _, _ in
                showDatePopover = false
                showDateError = false
            }
        }
    }

    /// Catch-all for school-era reads nobody remembers the date of. Stores the
    /// 1900-01-01 sentinel, which shows as "Old" wherever the read date appears.
    private var longAgoChip: some View {
        let isSelected = dateFinished.map { ReadDate.isLongAgo($0) } ?? false
        return Button {
            isThoughtsFocused = false
            withAnimation(.easeOut(duration: 0.15)) {
                dateFinished = ReadDate.longAgo
                showDateError = false
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "hourglass")
                    .font(.system(size: 12, weight: .semibold))
                Text("A long, long time ago")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Theme.onChrome : Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(isSelected ? Theme.chrome : Theme.surfaceElevated)
            )
            .overlay(
                Capsule().stroke(Theme.chrome.opacity(isSelected ? 0 : 0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.springPress)
    }

    /// Pinned above the keyboard / home indicator. The keyboard dismiss button
    /// lives here rather than in a `.keyboard` toolbar: the system accessory bar
    /// is a separate UIKit view that sits between this inset and the keyboard,
    /// leaving a seam the drawer content shows through.
    private var confirmBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.chrome.opacity(0.18))
                .frame(height: Theme.chromeHairline)
            if isThoughtsFocused {
                HStack {
                    Spacer()
                    Button("Done") { isThoughtsFocused = false }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.springPress)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            Button(action: confirm) {
                Text(isAdditionalRead ? "LOG THIS READ" : "MARK AS READ")
                    .font(.system(size: 14, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Theme.onChrome)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                            .fill(Theme.accentGloss)
                    )
            }
            .buttonStyle(.springPress)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(Theme.background)
    }

    /// Mono section label, e.g. "FINISHED ON".
    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(1)
            .foregroundStyle(Theme.chrome)
    }

    // MARK: - Actions

    private func confirm() {
        guard let date = dateFinished else {
            isThoughtsFocused = false
            withAnimation(.easeOut(duration: 0.2)) { showDateError = true }
            return
        }
        let trimmed = thoughts.trimmingCharacters(in: .whitespacesAndNewlines)
        didConfirm = true
        ReadDraftStore.clear(bookId: draftKey)
        onConfirm(date, nil, postToFeed, trimmed.isEmpty ? nil : trimmed, selectedTier)
        dismiss()
    }

    // MARK: - Drafts

    private func restoreDraftIfAny() {
        MentionCatalog.shared.ensureLoadedForCurrentUser()
        guard !didPrepare else { return }
        didPrepare = true
        guard let draft = ReadDraftStore.load(bookId: draftKey) else {
            thoughts = initialThoughts
            selectedTier = initialTier
            postToFeed = initialPostToFeed
            return
        }
        thoughts = draft.thoughts
        dateFinished = draft.dateFinished
        selectedTier = draft.tier
        postToFeed = draft.postToFeed
        restoredDraft = true
    }

    private func persistDraft() {
        // Don't bank the values the drawer seeded itself with — that would greet
        // the next open with a "picked up where you left off" row for nothing.
        guard !isSeededState else {
            ReadDraftStore.clear(bookId: draftKey)
            return
        }
        ReadDraftStore.save(currentDraft, bookId: draftKey)
    }

    private func discardDraft() {
        thoughts = initialThoughts
        dateFinished = nil
        selectedTier = initialTier
        postToFeed = initialPostToFeed
        restoredDraft = false
        ReadDraftStore.clear(bookId: draftKey)
    }
}
