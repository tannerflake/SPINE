//
//  BookProfileService.swift
//  SPINE
//
//  Uses Claude to produce a two-sentence summary, notable quote, and AI profile tags for a book. Caches by book.id.
//

import Foundation

final class BookProfileService {
    static let shared = BookProfileService()
    private var summaryCache: [String: String] = [:]
    /// Inner nil = "no notable quote", cached so the LLM isn't re-asked.
    private var quoteCache: [String: String?] = [:]
    private var tagsCache: [String: [String]] = [:]
    private var whyLikeCache: [String: String] = [:]
    private let queue = DispatchQueue(label: "com.spine.bookprofile.cache")

    private init() {}

    private let summaryMaxCharacters = 200

    /// Short summary (max 200 characters). Uses book description if present; otherwise asks Claude. Cached by book.id.
    func twoSentenceSummary(for book: Book) async -> String? {
        let key = book.id
        if let cached = queue.sync(execute: { summaryCache[key] }) { return cached }
        if let shared = await AIContentCacheRepository.shared.content(for: key).summary {
            queue.sync { summaryCache[key] = shared }
            return shared
        }
        let system = "You are a concise book summarizer. Reply with a very short summary of the book in at most two sentences. HARD LIMIT: 200 characters total, including spaces. Count them, and cut a whole sentence rather than exceed it. Every sentence must be complete and end in a period. No heading, no bullets, no extra text. If given a long description, condense it. If given only title and author, write a brief summary based on common knowledge."
        let input: String
        if let d = book.description, !d.isEmpty {
            input = "Book: \(book.title) by \(book.author).\n\nDescription:\n\(d)\n\nSummarize in at most two sentences, under 200 characters."
        } else {
            input = "Book: \(book.title) by \(book.author). Write a brief summary in at most two sentences, under 200 characters."
        }
        do {
            let response = try await ClaudeService.shared.sendMessageDetailed(system: system, userMessage: input, tier: .simple)
            var trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            trimmed = Self.clampToSentence(trimmed, limit: summaryMaxCharacters)
            queue.sync { summaryCache[key] = trimmed }
            if !trimmed.isEmpty {
                await AIContentCacheRepository.shared.storeSummary(trimmed, bookId: key, model: response.model)
            }
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    /// Sentence-aware cap. Models overrun the character budget (Gemini more
    /// than Claude did), and a raw prefix chop left summaries ending mid-clause.
    /// Prefer dropping a whole trailing sentence; only ellipsize a single
    /// sentence that is itself too long.
    static func clampToSentence(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let window = String(text.prefix(limit))

        // Walk back to the last sentence terminator that actually ends a sentence.
        var cut: String.Index? = nil
        var i = window.endIndex
        while i > window.startIndex {
            i = window.index(before: i)
            guard ".!?".contains(window[i]) else { continue }
            let after = window.index(after: i)
            // A terminator at the very end of the window may be mid-sentence in
            // the full string, so require a following space here.
            guard after < window.endIndex, window[after] == " " else { continue }
            if window[i] == ".", endsWithAbbreviation(window[..<i]) { continue }
            cut = after
            break
        }
        if let cut, !window[..<cut].trimmingCharacters(in: .whitespaces).isEmpty {
            return String(window[..<cut]).trimmingCharacters(in: .whitespaces)
        }

        // One long sentence: trim to a word boundary and mark the elision.
        var fallback = window.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lastSpace = fallback.lastIndex(of: " ") {
            fallback = String(fallback[..<lastSpace])
        }
        fallback = fallback.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-"))
        return fallback.isEmpty ? fallback : fallback + "\u{2026}"
    }

    /// "…operative Mr." is not a sentence end. Guards the common title/abbrev cases.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "jr", "sr", "vs", "etc",
        "inc", "ltd", "co", "no", "vol", "ed", "eds", "approx", "e.g", "i.e"
    ]

    private static func endsWithAbbreviation(_ prefix: Substring) -> Bool {
        let word = prefix.split(whereSeparator: { $0 == " " || $0 == "\n" }).last ?? ""
        return abbreviations.contains(word.lowercased())
    }

    /// One impactful or notable quote from the book. Cached by book.id.
    func notableQuote(for book: Book) async -> String? {
        let key = book.id
        if let cached = queue.sync(execute: { quoteCache[key] }) { return cached }
        if let shared = await AIContentCacheRepository.shared.content(for: key).quote {
            queue.sync { quoteCache.updateValue(shared, forKey: key) }
            return shared
        }
        let system = "You are a literary assistant. Reply with one impactful, famous, or notable quote from this book. Output only the quote in quotation marks, nothing else. If you don't know a real quote from the book, reply with exactly: No notable quote available."
        let input: String
        if let d = book.description, !d.isEmpty {
            input = "Book: \(book.title) by \(book.author).\n\nDescription:\n\(d)\n\nGive one notable quote from this book."
        } else {
            input = "Book: \(book.title) by \(book.author). Give one notable or famous quote from this book."
        }
        do {
            // Verbatim quote recall: keep on the smarter tier so we don't fabricate quotes.
            let response = try await ClaudeService.shared.sendMessageDetailed(system: system, userMessage: input, tier: .complex)
            let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().contains("no notable quote") {
                // Cache the miss — an explicit "no quote" answer is stable, so
                // don't re-ask the LLM for this book ever again.
                queue.sync { quoteCache.updateValue(nil, forKey: key) }
                await AIContentCacheRepository.shared.storeQuote(nil, bookId: key, model: response.model)
                return nil
            }
            if trimmed.isEmpty {
                // Possibly transient (truncation, provider hiccup): skip only this session.
                queue.sync { quoteCache.updateValue(nil, forKey: key) }
                return nil
            }
            queue.sync { quoteCache[key] = trimmed }
            await AIContentCacheRepository.shared.storeQuote(trimmed, bookId: key, model: response.model)
            return trimmed
        } catch {
            return nil
        }
    }

    /// Personalized "why you might like this book" blurb (max three sentences),
    /// grounded in the reader's taste: their best-loved reads and interest tags.
    /// Spoiler-free. Cached by book.id (taste shifts slowly; session cache is fine).
    func whyYouMightLikeIt(for book: Book, library: [UserBook], user: User?) async -> String? {
        let key = book.id
        if let cached = queue.sync(execute: { whyLikeCache[key] }) { return cached }

        // Best-loved reads: high rating or top tier, most recent first.
        let loved = library
            .filter { $0.bookId != book.id && $0.status == .read }
            .filter { entry in
                if let r = entry.rating { return r >= 7.0 }
                return ["S", "A"].contains(entry.tier ?? "")
            }
            .sorted { ($0.dateFinished ?? .distantPast) > ($1.dateFinished ?? .distantPast) }
            .prefix(10)
            .compactMap { $0.book.map { b in "\(b.title) by \(b.author)" } }

        let interestTags = ((user?.readingInterestTags ?? []) + (user?.discoverCriteria.tags ?? []))

        guard !loved.isEmpty || !interestTags.isEmpty else { return nil }

        let system = """
        You write one short personalized blurb for a reading app explaining why this specific reader might like a book, based on their taste. Rules:
        - THREE SENTENCES MAXIMUM. Plain text only, no markdown, no headings, no lists.
        - Speak to the reader as "you". Never mention AI, algorithms, data, or "match scores".
        - Ground it in their actual taste: connect the book's themes, style, or feel to books they loved or interests they've named. Reference at most two of their books by title.
        - NO SPOILERS for the recommended book: premise, themes, and feel only.
        - If the connection is thin, keep it honest and general rather than inventing overlap.
        """
        var input = "Book to recommend: \(book.title) by \(book.author)."
        if let d = book.description, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            input += "\n\nPublisher description (context only):\n\(d)"
        }
        if !book.genres.isEmpty {
            input += "\n\nCategories: \(book.genres.joined(separator: ", "))"
        }
        if !loved.isEmpty {
            input += "\n\nBooks this reader loved:\n" + loved.map { "- \($0)" }.joined(separator: "\n")
        }
        if !interestTags.isEmpty {
            input += "\n\nReading interests they've named: \(interestTags.joined(separator: ", "))"
        }
        input += "\n\nWrite the blurb (three sentences max)."
        do {
            let response = try await ClaudeService.shared.sendMessage(system: system, userMessage: input, tier: .simple)
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            queue.sync { whyLikeCache[key] = trimmed }
            return trimmed
        } catch {
            return nil
        }
    }

    /// Up to 5 tags from Claude, each chosen **only** from `Tags.csv` (see `SpineTagCatalog`). Every book gets either Fiction or Non-Fiction. Cached by book.id.
    func profileTags(for book: Book) async -> [String] {
        let key = book.id
        if let cached = queue.sync(execute: { tagsCache[key] }) { return cached }
        if let stored = await AIContentCacheRepository.shared.content(for: key).tags {
            // Re-whitelist in case the shipped catalog changed since they were written.
            let valid = SpineTagCatalog.shared.whitelist(stored)
            if !valid.isEmpty {
                queue.sync { tagsCache[key] = valid }
                return valid
            }
        }
        let enriched = await mergeWithVolumeIfNeeded(book)
        let allowed = SpineTagCatalog.shared.allowedTagsPromptBlock()
        let system = """
        You assign book profile tags for a reading app. Reply with ONLY a JSON array of 1 to 5 tag strings. No markdown fences, no explanation, no keys, just the array.

        CRITICAL: Every tag string MUST be copied **exactly** from the allowed list below (same spelling, spacing, capitalization, and punctuation). Do not invent new tags or paraphrase.

        Rules:
        - Include exactly ONE of: "\(SpineTagCatalog.fictionTag)" or "\(SpineTagCatalog.nonFictionTag)" (from the Format category).
        - Add up to four more tags from other categories that best fit the book (Genre, Story Type, Tone / Vibe, Setting / World, Character / Dynamics, Pacing / Style, Themes, Nonfiction Topics, Reading Experience, only where relevant).
        - At most 5 tags total. Do not repeat tags.
        - Prefer a mix of categories when useful (e.g. Genre + Tone + one Theme), not five from the same line.

        Allowed tags (exact strings only):
        \(allowed)
        """
        var metadata = "Title: \(enriched.title)\nAuthor: \(enriched.author)\n"
        if let d = enriched.description, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata += "\nDescription:\n\(d)\n"
        } else {
            metadata += "\nDescription: (not available)\n"
        }
        if !enriched.genres.isEmpty {
            metadata += "\nPublisher / store categories (hints only; do not copy verbatim as the only tags):\n\(enriched.genres.joined(separator: ", "))\n"
        }
        if let p = enriched.pageCount, p > 0 {
            metadata += "\nPage count: \(p)"
            let approxWords = p * 250
            metadata += "\nApproximate word count (rough estimate from pages): ~\(approxWords)"
        } else {
            metadata += "\nPage count: unknown"
        }
        if let pub = enriched.publishedDate {
            let f = DateFormatter()
            f.dateStyle = .medium
            metadata += "\nPublished: \(f.string(from: pub))"
        }
        let userMessage = "Assign tags for this book.\n\n\(metadata)"
        do {
            let response = try await ClaudeService.shared.sendMessageDetailed(system: system, userMessage: userMessage, tier: .simple)
            let parsed = parseTagsFromResponse(response.text) ?? []
            let normalized = normalizeProfileTags(parsed, book: enriched)
            queue.sync { tagsCache[key] = normalized }
            if !normalized.isEmpty {
                await AIContentCacheRepository.shared.storeTags(normalized, bookId: key, model: response.model)
            }
            return normalized
        } catch {
            // Keyword fallback is a degraded guess — keep it session-local, never
            // persist it as the book's tags for everyone.
            let fallback = fallbackProfileTags(for: enriched)
            queue.sync { tagsCache[key] = fallback }
            return fallback
        }
    }

    /// Merges Google Books volume data when local metadata is thin (for AI context only). Aborts API wait after 2s.
    private func mergeWithVolumeIfNeeded(_ book: Book) async -> Book {
        let needs = (book.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || book.genres.isEmpty
            || book.pageCount == nil
        guard needs else { return book }
        guard let fetched = await fetchVolumeWithinTwoSeconds(id: book.id) else { return book }
        var merged = book
        if merged.description == nil || merged.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            merged.description = fetched.description
        }
        if merged.genres.isEmpty { merged.genres = fetched.genres }
        if merged.pageCount == nil { merged.pageCount = fetched.pageCount }
        if merged.publishedDate == nil { merged.publishedDate = fetched.publishedDate }
        return merged
    }

    private enum VolumeRace: Sendable {
        case volume(Book?)
        case timedOut
    }

    /// Google Books volume fetch with a 2s budget; otherwise keep local `book` as-is.
    private func fetchVolumeWithinTwoSeconds(id: String) async -> Book? {
        await withTaskGroup(of: VolumeRace.self) { group in
            group.addTask {
                .volume(try? await GoogleBooksService.shared.fetchVolume(id: id))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return .timedOut
            }
            guard let first = await group.next() else {
                group.cancelAll()
                return nil
            }
            switch first {
            case .timedOut:
                group.cancelAll()
                return nil
            case .volume(let b):
                group.cancelAll()
                return b
            }
        }
    }

    private func parseTagsFromResponse(_ text: String) -> [String]? {
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
        if let data = t.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            return arr
        }
        // Fallback: non-JSON lines
        let lines = t
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]\"'")) }
            .filter { !$0.isEmpty && !$0.hasPrefix("{") }
        return lines.isEmpty ? nil : lines
    }

    private func normalizeProfileTags(_ raw: [String], book: Book) -> [String] {
        let catalog = SpineTagCatalog.shared
        var tags = raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        tags = tags.filter { tag in
            let key = tag.lowercased()
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
        tags = catalog.whitelist(tags)
        tags = resolveFictionNonFictionConflict(tags, book: book)
        let fic = SpineTagCatalog.fictionTag
        let nf = SpineTagCatalog.nonFictionTag
        if !tags.contains(fic), !tags.contains(nf) {
            tags.insert(inferFictionNonFiction(book: book), at: 0)
        } else if let idx = tags.firstIndex(where: { $0 == fic || $0 == nf }), idx != 0 {
            let t = tags.remove(at: idx)
            tags.insert(t, at: 0)
        }
        return Array(tags.prefix(5))
    }

    /// If both Format tags appear after whitelisting, keep one using book hints.
    private func resolveFictionNonFictionConflict(_ tags: [String], book: Book) -> [String] {
        let fic = SpineTagCatalog.fictionTag
        let nf = SpineTagCatalog.nonFictionTag
        guard tags.contains(fic), tags.contains(nf) else { return tags }
        let want = inferFictionNonFiction(book: book)
        let remove = want == fic ? nf : fic
        return tags.filter { $0 != remove }
    }

    private func inferFictionNonFiction(book: Book) -> String {
        let fic = SpineTagCatalog.fictionTag
        let nf = SpineTagCatalog.nonFictionTag
        let blob = (book.genres.joined(separator: " ") + " " + (book.description ?? "")).lowercased()
        if blob.contains("non-fiction") || blob.contains("nonfiction") { return nf }
        let strongFiction = ["science fiction", "sci-fi", "scifi", "fantasy", "romance", "thriller", "mystery", "horror", "graphic novel", "literary fiction", "short stories", "historical fiction", "young adult", "ya fiction"]
        if strongFiction.contains(where: { blob.contains($0) }) { return fic }
        let nfHints = ["biography", "autobiography", "memoir", "self-help", "business", "travel guide", "cookbook", "true crime", "philosophy", "religion", "politics", "essay", "reference", "textbook"]
        if nfHints.contains(where: { blob.contains($0) }) { return nf }
        let ficHints = ["fiction", "novel", "novella", "story collection"]
        if ficHints.contains(where: { blob.contains($0) }) { return fic }
        if blob.contains("history") && !blob.contains("historical fiction") { return nf }
        if blob.contains("science") { return nf }
        return fic
    }

    /// Uses only `SpineTagCatalog` tags; prefers substrings of description/genres against catalog labels.
    private func fallbackProfileTags(for book: Book) -> [String] {
        let catalog = SpineTagCatalog.shared
        let root = inferFictionNonFiction(book: book)
        let blob = (book.genres.joined(separator: " ") + " " + (book.description ?? "")).lowercased()
        var extra: [String] = []
        var seen = Set<String>()
        for tag in catalog.allTags where tag != SpineTagCatalog.fictionTag && tag != SpineTagCatalog.nonFictionTag {
            let tl = tag.lowercased()
            guard tl.count >= 4 else { continue }
            guard !seen.contains(tl) else { continue }
            if blob.contains(tl) {
                seen.insert(tl)
                extra.append(tag)
            }
            if extra.count >= 4 { break }
        }
        return [root] + extra
    }

    /// Books from the user's read list that are most similar to this book. Returns 2–4 books for "Similar to" section. Uses Claude to pick by title/author; empty if read list is empty or Claude returns nothing.
    func similarBooks(for book: Book, readBooks: [UserBook]) async -> [Book] {
        let readTitles = readBooks.compactMap { ub -> (title: String, book: Book)? in
            guard let b = ub.book else { return nil }
            return (b.title, b)
        }
        guard !readTitles.isEmpty else { return [] }
        let titleList = readTitles.map(\.title).joined(separator: ", ")
        let system = "You are a book comparison assistant. Given one book and a list of books the user has read, pick 2 to 4 books from the list that are most similar in theme, genre, or style. Reply with only those book titles, one per line. Use the exact title as given. If none are similar, reply with exactly: None."
        let input = "Book to compare: \(book.title) by \(book.author).\n\nBooks the user has read:\n\(titleList)\n\nList 2 to 4 titles from the user's list that are most similar (one per line), or reply None."
        do {
            let response = try await ClaudeService.shared.sendMessage(system: system, userMessage: input, tier: .simple)
            let lines = response
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("none") }
            var result: [Book] = []
            for line in lines.prefix(4) {
                let normalized = line.lowercased()
                if let match = readTitles.first(where: { $0.title.lowercased() == normalized || $0.title.lowercased().contains(normalized) || normalized.contains($0.title.lowercased()) }) {
                    result.append(match.book)
                }
            }
            return result
        } catch {
            return []
        }
    }
}
