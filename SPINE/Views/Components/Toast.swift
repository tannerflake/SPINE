//
//  Toast.swift
//  Spine
//
//  Lightweight success toasts for major user actions (queue, mark-as-read,
//  feed posts, imports, recommendations). Non-blocking, self-dismissing,
//  styled to the terminal/Win95 design system.
//
//  Usage:
//    ToastCenter.shared.show(.addedToQueue(bookTitle: book.title))
//  and attach `.toastHost()` once near the root (see MainTabView).
//

import SwiftUI
import UIKit

// MARK: - Model

/// A single transient toast. Build via the factory helpers below rather than
/// constructing directly, so copy and styling stay consistent.
struct Toast: Identifiable, Equatable {
    enum Style: Equatable {
        case success
        case info
        case error

        /// Leading accent / badge color.
        var chrome: Color {
            switch self {
            case .success: return Theme.chrome
            case .info: return Theme.chromeStrong
            case .error: return Theme.danger
            }
        }

        /// SF Symbol shown in the badge.
        var icon: String {
            switch self {
            case .success: return "checkmark"
            case .info: return "info"
            case .error: return "exclamationmark"
            }
        }
    }

    let id = UUID()
    let style: Style
    /// Short uppercase status word, shown as `QUEUED`.
    let status: String
    /// Human-readable detail line. Optional — some toasts are status-only.
    let message: String?
    /// Seconds on screen before auto-dismiss.
    let duration: TimeInterval
    /// Book whose cover replaces the status badge (e.g. the just-queued book).
    let thumbnail: Book?
    /// Runs on tap (after the toast dismisses). Without one, a tap just dismisses.
    let action: (() -> Void)?

    init(
        style: Style,
        status: String,
        message: String? = nil,
        duration: TimeInterval = 2.6,
        thumbnail: Book? = nil,
        action: (() -> Void)? = nil
    ) {
        self.style = style
        self.status = status
        self.message = message
        self.duration = duration
        self.thumbnail = thumbnail
        self.action = action
    }

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

// MARK: - Factories (canonical copy for each action)

extension Toast {
    /// Truncates a title so a long book name never blows out the toast.
    private static func short(_ title: String, max: Int = 40) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func addedToQueue(bookTitle: String) -> Toast {
        Toast(style: .success, status: "Queued", message: "“\(short(bookTitle))” added to your queue")
    }

    static func startedReading(bookTitle: String) -> Toast {
        Toast(style: .success, status: "Reading", message: "“\(short(bookTitle))” added to Currently Reading")
    }

    /// Queue confirmation with the book's cover and a nudge to jot a note-to-self;
    /// `action` opens the note composer. Stays up a beat longer than a plain toast
    /// so there's time to read the nudge and tap.
    static func queued(book: Book, startedReading: Bool, action: @escaping () -> Void) -> Toast {
        Toast(
            style: .success,
            status: startedReading ? "Reading" : "Queued",
            message: "“\(short(book.title, max: 32))” added. \(QueueNoteCopy.toastPrompt)",
            duration: 3.5,
            thumbnail: book,
            action: action
        )
    }

    static func queueNoteSaved(bookTitle: String) -> Toast {
        Toast(style: .success, status: "Note saved", message: "Saved to “\(short(bookTitle))”")
    }

    static func queueNoteRemoved(bookTitle: String) -> Toast {
        Toast(style: .success, status: "Note removed", message: "Cleared from “\(short(bookTitle))”")
    }

    static func markedAsDNF(bookTitle: String) -> Toast {
        Toast(style: .success, status: "DNF", message: "“\(short(bookTitle))” moved to Did Not Finish")
    }

    static func markedAsRead(bookTitle: String, sharedToFeed: Bool) -> Toast {
        Toast(
            style: .success,
            status: "Marked read",
            message: sharedToFeed
                ? "“\(short(bookTitle))” logged & shared to your feed"
                : "“\(short(bookTitle))” added to your shelf"
        )
    }

    /// The mark-as-read drawer was closed with unsaved thoughts; the draft is on
    /// device and comes back the next time they open the book.
    static func draftSaved(bookTitle: String) -> Toast {
        Toast(
            style: .info,
            status: "Draft saved",
            message: "Your thoughts on “\(short(bookTitle))” will be here when you're back",
            duration: 3.0
        )
    }

    /// A re-read of a book already on the read shelf was logged from the
    /// mark-as-read drawer.
    static func anotherReadLogged(bookTitle: String, sharedToFeed: Bool) -> Toast {
        Toast(
            style: .success,
            status: "Read again",
            message: sharedToFeed
                ? "Another read of \u{201C}\(short(bookTitle))\u{201D} logged & shared to your feed"
                : "Another read of \u{201C}\(short(bookTitle))\u{201D} logged"
        )
    }

    static func reviewUpdated(sharedToFeed: Bool) -> Toast {
        Toast(
            style: .success,
            status: "Saved",
            message: sharedToFeed ? "Review updated & shared to your feed" : "Your review was updated"
        )
    }

    static func postedToFeed() -> Toast {
        Toast(style: .success, status: "Posted", message: "Shared to your feed")
    }

    static func postDeleted() -> Toast {
        Toast(style: .success, status: "Deleted", message: "Post removed from your feed")
    }

    static func commentDeleted() -> Toast {
        Toast(style: .success, status: "Deleted", message: "Your comment was removed")
    }

    /// The "finish adding books" callout was dismissed from the queue, throwing
    /// away the rest of a paused link import. `action` puts the session back.
    static func linkImportDismissed(count: Int, action: @escaping () -> Void) -> Toast {
        let noun = count == 1 ? "book" : "books"
        return Toast(
            style: .info,
            status: "Dismissed",
            message: "\(count) \(noun) discarded. Tap to undo",
            duration: 4.0,
            action: action
        )
    }

    static func importedBooks(count: Int) -> Toast {
        let noun = count == 1 ? "book" : "books"
        return Toast(
            style: .success,
            status: "Imported",
            message: count == 0 ? "No new books to import" : "\(count) \(noun) added to your library",
            duration: 3.0
        )
    }

    static func recommendationSent(to name: String) -> Toast {
        Toast(style: .success, status: "Sent", message: "Recommendation sent to \(name)")
    }

    /// A Goodreads row resolved to a book that's already in the library, so the
    /// import flow skipped past it without showing a review card.
    static func duplicateSkipped(bookTitle: String, readDateSaved: Bool) -> Toast {
        Toast(
            style: .info,
            status: "Already in library",
            message: readDateSaved
                ? "“\(short(bookTitle))” is on your shelf, added its read date"
                : "“\(short(bookTitle))” is already in your library, skipped",
            duration: 3.2
        )
    }
}

// MARK: - Center

/// Presents one toast at a time. `@MainActor` so mutations publish on the main
/// thread even when fired from background `Task`s in `AppState`.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var current: Toast?
    /// Note-to-self composer dropped in over the current screen (from the
    /// post-queue toast). Rendered by the same host as the toast.
    @Published private(set) var noteRequest: QueueNoteRequest?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// Replace the toast with the note composer for `request.book`.
    func presentQueueNote(_ request: QueueNoteRequest) {
        dismiss()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            noteRequest = request
        }
    }

    func dismissQueueNote() {
        withAnimation(.easeOut(duration: 0.2)) {
            noteRequest = nil
        }
    }

    /// Show a toast, replacing any that's on screen. Fires a light success haptic.
    func show(_ toast: Toast) {
        dismissTask?.cancel()

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(toast.style == .error ? .error : .success)

        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            current = toast
        }

        dismissTask = Task { [weak self, id = toast.id] in
            try? await Task.sleep(nanoseconds: UInt64(toast.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: id)
        }
    }

    /// Dismiss the current toast. If `id` is given, only dismisses when it still
    /// matches (so a stale timer can't clear a newer toast).
    func dismiss(id: UUID? = nil) {
        if let id, current?.id != id { return }
        dismissTask?.cancel()
        dismissTask = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            current = nil
        }
    }
}

// MARK: - View

/// The pill itself. Rendered by `ToastHost`; not used directly.
private struct ToastView: View {
    let toast: Toast
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let book = toast.thumbnail {
                // The just-queued book's cover stands in for the badge.
                BookCoverView(book: book, size: 28)
                    .shadow(color: Theme.shadowInk.opacity(0.18), radius: 2, x: 0, y: 1)
            } else {
                // Badge — chrome square with an SF Symbol, echoing the window close-box glyph.
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(toast.style.chrome)
                    Image(systemName: toast.style.icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.onChrome)
                }
                .frame(width: 30, height: 30)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(SpinesGlyphs.caps(toast.status))
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(toast.style.chrome)
                if let message = toast.message {
                    Text(message)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if toast.action != nil {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(toast.style.chrome)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .fill(Theme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(toast.style.chrome.opacity(0.45), lineWidth: Theme.chromeHairline)
        )
        .shadow(color: Theme.shadowInk.opacity(0.14), radius: 10, x: 0, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .onTapGesture {
            onDismiss()
            toast.action?()
        }
        // Swipe up to dismiss early.
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height < -20 { onDismiss() }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel([toast.status, toast.message].compactMap { $0 }.joined(separator: ". "))
        .accessibilityHint(toast.action != nil ? "Opens the note composer" : "Dismisses")
    }
}

/// Overlays the active toast at the top of its content, below the status bar.
private struct ToastHostModifier: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast = center.current {
                    ToastView(toast: toast) { center.dismiss(id: toast.id) }
                        .padding(.horizontal, Theme.horizontalPadding)
                        .padding(.top, 8)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            )
                        )
                        .id(toast.id)
                }
            }
            // The note-to-self composer rides the same host so it renders
            // wherever the toast that offered it did.
            .overlay {
                if let request = center.noteRequest {
                    QueueNoteComposerOverlay(request: request) { center.dismissQueueNote() }
                        .transition(.opacity)
                        .id(request.id)
                }
            }
    }
}

extension View {
    /// Attach once near the root so success toasts render above app content.
    func toastHost() -> some View {
        modifier(ToastHostModifier())
    }
}
