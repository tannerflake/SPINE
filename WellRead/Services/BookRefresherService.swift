//
//  BookRefresherService.swift
//  WellRead
//
//  AI refresher for books the user has already read: plot, key concepts,
//  characters, takeaways, memorable moments — plus follow-up Q&A. Spoilers are
//  fine by design (the reader finished the book). Caches by book.id.
//

import Foundation

/// One named person/figure in the refresher (character for fiction, key figure for non-fiction).
struct RefresherCharacter: Codable, Equatable, Identifiable {
    let name: String
    let detail: String

    var id: String { name }
}

/// Structured AI recap of a finished book. Empty arrays hide their sections.
struct BookRefresher: Codable, Equatable {
    let plot: String
    let keyConcepts: [String]
    let characters: [RefresherCharacter]
    let takeaways: [String]
    let memorableMoments: [String]
}

/// One turn of the follow-up Q&A under a refresher.
struct RefresherChatTurn: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
}

final class BookRefresherService {
    static let shared = BookRefresherService()
    private var refresherCache: [String: BookRefresher] = [:]
    private var chatCache: [String: [RefresherChatTurn]] = [:]
    private let queue = DispatchQueue(label: "com.wellread.bookrefresher.cache")

    private init() {}

    /// Cached refresher if one was already generated this session.
    func cachedRefresher(for book: Book) -> BookRefresher? {
        queue.sync { refresherCache[book.id] }
    }

    /// Q&A turns from earlier this session, so reopening the sheet keeps the thread.
    func cachedChat(for book: Book) -> [RefresherChatTurn] {
        queue.sync { chatCache[book.id] ?? [] }
    }

    func saveChat(_ turns: [RefresherChatTurn], for book: Book) {
        queue.sync { chatCache[book.id] = turns }
    }

    /// Generates the full refresher. Cached by book.id; throws so the view can show a retry state.
    func refresher(for book: Book) async throws -> BookRefresher {
        if let cached = cachedRefresher(for: book) { return cached }
        if let shared = await AIContentCacheRepository.shared.content(for: book.id).refresher {
            queue.sync { refresherCache[book.id] = shared }
            return shared
        }
        let system = """
        You write "refresher" pages for a reading app: the reader FINISHED this book a while ago and wants their memory jogged. Full spoilers are expected and good. Do not hold anything back or warn about spoilers.

        Reply with ONLY a JSON object (no markdown fences, no commentary) using exactly these keys:
        {
          "plot": "The story or argument of the book in 3-5 sentences, including how it ends.",
          "keyConcepts": ["3-6 central ideas, themes, or concepts, each one crisp sentence"],
          "characters": [{"name": "Character or key figure", "detail": "who they are and what happens to them, one sentence"}],
          "takeaways": ["3-5 lasting lessons or points the reader should retain"],
          "memorableMoments": ["2-4 scenes, passages, or moments most readers remember"]
        }

        Rules:
        - Fiction: "plot" is the plot; "characters" covers the main cast (4-7 entries).
        - Non-fiction: "plot" is the book's core argument/arc; "characters" lists key figures if any, otherwise an empty array.
        - If you don't know the book well enough to be accurate, keep entries you're unsure of out rather than inventing specifics.
        - Plain text only inside strings, no markdown.
        """
        var input = "Book: \(book.title) by \(book.author)."
        if let d = book.description, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            input += "\n\nPublisher description (context only):\n\(d)"
        }
        if !book.genres.isEmpty {
            input += "\n\nCategories: \(book.genres.joined(separator: ", "))"
        }
        input += "\n\nWrite the refresher JSON."
        // Plot/character recall with full spoilers — fabrication risk is high on small models.
        let response = try await ClaudeService.shared.sendMessageDetailed(system: system, userMessage: input, maxTokens: 2048, tier: .complex)
        guard let refresher = Self.parseRefresher(from: response.text) else {
            throw NSError(domain: "BookRefresherService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Couldn't read the refresher response."])
        }
        queue.sync { refresherCache[book.id] = refresher }
        await AIContentCacheRepository.shared.storeRefresher(refresher, bookId: book.id, model: response.model)
        return refresher
    }

    /// Answers a follow-up question about the book, grounded in the refresher and prior Q&A turns.
    func answer(question: String, for book: Book, refresher: BookRefresher, history: [RefresherChatTurn]) async throws -> String {
        let system = """
        You answer follow-up questions about "\(book.title)" by \(book.author) for a reader who has FINISHED the book and is refreshing their memory. Spoilers are fine. Be specific and concrete, cite what happens in the book, and keep answers to a short paragraph or two. If a question goes beyond what's in the book, say so briefly. Plain text only, no markdown.

        Refresher already shown to the reader:
        \(refresherContext(refresher))
        """
        var messages = history.map { ClaudeMessageRequest.Message(role: $0.role.rawValue, content: $0.text) }
        messages.append(.init(role: "user", content: question))
        let response = try await ClaudeService.shared.sendConversation(system: system, messages: messages, tier: .complex)
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refresherContext(_ r: BookRefresher) -> String {
        var parts: [String] = ["Plot: \(r.plot)"]
        if !r.keyConcepts.isEmpty {
            parts.append("Key concepts: \(r.keyConcepts.joined(separator: " | "))")
        }
        if !r.characters.isEmpty {
            parts.append("Characters: \(r.characters.map { "\($0.name) — \($0.detail)" }.joined(separator: " | "))")
        }
        if !r.takeaways.isEmpty {
            parts.append("Takeaways: \(r.takeaways.joined(separator: " | "))")
        }
        if !r.memorableMoments.isEmpty {
            parts.append("Memorable moments: \(r.memorableMoments.joined(separator: " | "))")
        }
        return parts.joined(separator: "\n")
    }

    /// Strips markdown fences if present and decodes the refresher JSON.
    static func parseRefresher(from text: String) -> BookRefresher? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = String(t.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.lowercased().hasPrefix("json") {
                t = String(t.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let endRange = t.range(of: "```") {
                t = String(t[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Tolerate stray prose around the object by slicing to the outermost braces.
        if let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end {
            t = String(t[start...end])
        }
        guard let data = t.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONDecoder().decode(BookRefresher.self, from: data) else { return nil }
        let plot = parsed.plot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plot.isEmpty else { return nil }
        return parsed
    }
}
