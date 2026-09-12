//
//  BookSummaryMoreService.swift
//  WellRead
//
//  Extended spoiler-free summary for a book the user may NOT have read yet:
//  a ~three-paragraph "about this book" write-up plus follow-up Q&A that stays
//  spoiler-safe by default. Counterpart to BookRefresherService (which is
//  full-spoiler and gated to finished books). Caches by book.id.
//

import Foundation

final class BookSummaryMoreService {
    static let shared = BookSummaryMoreService()
    private var summaryCache: [String: String] = [:]
    private var chatCache: [String: [RefresherChatTurn]] = [:]
    private let queue = DispatchQueue(label: "com.wellread.booksummarymore.cache")

    private init() {}

    /// Cached long summary if one was already generated this session.
    func cachedSummary(for book: Book) -> String? {
        queue.sync { summaryCache[book.id] }
    }

    /// Q&A turns from earlier this session, so reopening the sheet keeps the thread.
    func cachedChat(for book: Book) -> [RefresherChatTurn] {
        queue.sync { chatCache[book.id] ?? [] }
    }

    func saveChat(_ turns: [RefresherChatTurn], for book: Book) {
        queue.sync { chatCache[book.id] = turns }
    }

    /// Generates the ~three-paragraph spoiler-free summary. Cached by book.id;
    /// throws so the view can show a retry state.
    func longSummary(for book: Book) async throws -> String {
        if let cached = cachedSummary(for: book) { return cached }
        if let shared = await AIContentCacheRepository.shared.content(for: book.id).about {
            queue.sync { summaryCache[book.id] = shared }
            return shared
        }
        let system = """
        You write "about this book" pages for a reading app. The reader has NOT read the book yet and is deciding whether to pick it up.

        STRICTLY NO SPOILERS: never reveal the ending, late-book twists or reveals, character deaths, or how any conflict resolves. Stay within the setup a reader would get from the first act and the jacket copy.

        Write exactly three short paragraphs of plain prose, separated by blank lines, no markdown, no headings, no lists:
        1. The premise and setup: who the book follows, the world or situation, and the tension that kicks things off (fiction), or the core question the book tackles and its approach (non-fiction).
        2. The themes and ideas it explores, and what it's really about underneath the surface.
        3. The style and experience of reading it (voice, tone, pacing) and why readers love it.

        If you don't know the book well enough to be accurate, keep it general rather than inventing specifics.
        """
        var input = "Book: \(book.title) by \(book.author)."
        if let d = book.description, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            input += "\n\nPublisher description (context only):\n\(d)"
        }
        if !book.genres.isEmpty {
            input += "\n\nCategories: \(book.genres.joined(separator: ", "))"
        }
        input += "\n\nWrite the three-paragraph summary."
        // Needs real knowledge of the book's contents (and spoiler judgment) — smarter tier.
        let response = try await ClaudeService.shared.sendMessageDetailed(system: system, userMessage: input, maxTokens: 1024, tier: .complex)
        let summary = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw NSError(domain: "BookSummaryMoreService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Couldn't read the summary response."])
        }
        queue.sync { summaryCache[book.id] = summary }
        await AIContentCacheRepository.shared.storeAbout(summary, bookId: book.id, model: response.model)
        return summary
    }

    /// Answers a follow-up question, grounded in the summary and prior turns.
    /// Spoiler-safe by default; only spoils if the reader explicitly asks to be spoiled.
    func answer(question: String, for book: Book, summary: String, history: [RefresherChatTurn]) async throws -> String {
        let system = """
        You answer questions about "\(book.title)" by \(book.author) for a reader who has NOT read the book yet. Default to NO SPOILERS: never reveal the ending, twists, reveals, character deaths, or how conflicts resolve. Talk around them ("without spoiling anything…") instead. Only if the reader explicitly says they want spoilers, give a one-line warning and then answer plainly. Keep answers to a short paragraph or two. If a question goes beyond what's in the book, say so briefly. Plain text only, no markdown.

        Summary already shown to the reader:
        \(summary)
        """
        var messages = history.map { ClaudeMessageRequest.Message(role: $0.role.rawValue, content: $0.text) }
        messages.append(.init(role: "user", content: question))
        let response = try await ClaudeService.shared.sendConversation(system: system, messages: messages, tier: .complex)
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
