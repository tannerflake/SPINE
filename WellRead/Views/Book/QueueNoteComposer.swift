//
//  QueueNoteComposer.swift
//  Spine
//
//  "Note to self" on a queued book: why it's in the queue, who recommended it,
//  where you heard about it. Private to the owner; never shown to other readers.
//
//  Two surfaces share one composer card:
//   • the post-queue toast — tap it and the card drops in over whatever screen
//     you're on (hosted by ToastHost, see Toast.swift)
//   • the book profile's note card (pencil, or the "add a note" row), hosted
//     as an overlay inside BookProfileView
//

import SwiftUI

// MARK: - Copy

/// Every user-facing string for the feature, so renaming ("Queue note",
/// "Why this book", …) is a one-line change.
enum QueueNoteCopy {
    /// Section title on the book profile and the composer header.
    static let title = "Note to self"
    /// Empty-state row on the book profile.
    static let addPrompt = "Add a note to self"
    static let placeholder = "ex. John recommended it"
    /// Tail of the post-queue toast message.
    static let toastPrompt = "Tap to add a note"
    static let maxLength = 280
}

// MARK: - Request

/// What the composer needs: the book (cover + title in the header), the note
/// as it stands, and where to send the result.
struct QueueNoteRequest: Identifiable {
    let id = UUID()
    let book: Book
    let initialNote: String
    /// Called with the trimmed note, or `nil` when the note was cleared.
    let onSave: (String?) -> Void
}

// MARK: - Composer overlay

/// Dimmed backdrop + a compact card anchored at the top (clear of the keyboard).
/// Tap the backdrop or Cancel to leave without saving.
struct QueueNoteComposerOverlay: View {
    let request: QueueNoteRequest
    let onClose: () -> Void

    @State private var text: String
    @State private var appeared = false
    @FocusState private var isFocused: Bool

    init(request: QueueNoteRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _text = State(initialValue: request.initialNote)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var baseline: String { request.initialNote.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasChanges: Bool { trimmed != baseline }
    /// Existing note emptied out: Save reads as "Remove note".
    private var isClearing: Bool { trimmed.isEmpty && !baseline.isEmpty }
    private var remaining: Int { QueueNoteCopy.maxLength - text.count }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.shadowInk.opacity(0.32)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { cancel() }

            card
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.top, 8)
                .offset(y: appeared ? 0 : -28)
                .opacity(appeared ? 1 : 0)
        }
        // A half-typed note survives a deep-link tap: the composer stays put.
        .composerDraftGuard(text, baseline: request.initialNote)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { appeared = true }
            // Focus once the card has landed so the keyboard rides in with it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { isFocused = true }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            editor
            footer
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .fill(Theme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(Theme.chrome.opacity(0.45), lineWidth: Theme.chromeHairline)
        )
        .shadow(color: Theme.shadowInk.opacity(0.18), radius: 14, x: 0, y: 6)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            BookCoverView(book: request.book, size: 36)
                .shadow(color: Theme.shadowInk.opacity(0.18), radius: 2, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(SpinesGlyphs.caps(QueueNoteCopy.title))
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.chrome)
                Text(request.book.title)
                    .font(Theme.headline())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(request.book.author)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(6)
            }
            .buttonStyle(.springPress)
            .accessibilityLabel("Cancel")
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if trimmed.isEmpty {
                Text(QueueNoteCopy.placeholder)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(Theme.body())
                .lineSpacing(Theme.bodyLineSpacing)
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                // Starts as a two-line jot box and grows with the text; the
                // 280-char cap keeps it from ever getting tall.
                .scrollDisabled(true)
                .frame(minHeight: 64)
                .fixedSize(horizontal: false, vertical: true)
                .focused($isFocused)
                .onChange(of: text) { _, new in
                    if new.count > QueueNoteCopy.maxLength {
                        text = String(new.prefix(QueueNoteCopy.maxLength))
                    }
                }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isFocused ? Theme.chrome : Theme.chrome.opacity(0.35), lineWidth: isFocused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .onTapGesture { isFocused = true }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if remaining <= 40 {
                Text("\(remaining)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(remaining <= 0 ? Theme.danger : Theme.textTertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            Button("Cancel", action: cancel)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .buttonStyle(.springPress)

            Button(action: save) {
                Text(SpinesGlyphs.caps(isClearing ? "Remove note" : "Save"))
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.onChrome)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.springPress)
            .glossyProminent(Theme.chrome, cornerRadius: 10)
            .disabled(!hasChanges)
            .opacity(hasChanges ? 1 : 0.45)
        }
    }

    private func save() {
        guard hasChanges else { return }
        isFocused = false
        request.onSave(trimmed.isEmpty ? nil : trimmed)
        onClose()
    }

    private func cancel() {
        isFocused = false
        onClose()
    }
}

// MARK: - Book profile card

/// The note as it appears on the book profile for a queued book: the note text
/// with a pencil when one exists, otherwise a one-row invitation to add one.
/// Both paths call `onEdit`, which opens the composer.
struct QueueNoteCard: View {
    let note: String?
    let onEdit: () -> Void

    var body: some View {
        if let note {
            Button(action: onEdit) {
                Text(note)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(Theme.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .hingeSectionCard(title: QueueNoteCopy.title) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.background)
                        .padding(7)
                        .background(Circle().fill(Theme.chrome))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit note")
            } titleAccessory: {
                EmptyView()
            }
        } else {
            Button(action: onEdit) {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.chrome)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(QueueNoteCopy.addPrompt)
                            .font(Theme.callout())
                            .foregroundStyle(Theme.textPrimary)
                        Text(QueueNoteCopy.placeholder)
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.chrome)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.springPress)
            .hingeSectionCard(title: QueueNoteCopy.title)
        }
    }
}
