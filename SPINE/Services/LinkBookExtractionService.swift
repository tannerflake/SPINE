//
//  LinkBookExtractionService.swift
//  SPINE
//
//  Turns a shared link (or pasted text) into queue-able books:
//    1. Content — the page text Safari captured in the share extension, or a
//       fetch of the URL (HTML → visible text; oEmbed for TikTok / YouTube / X,
//       whose pages are JS shells with the caption hidden in scripts).
//    2. Extraction — the cheap LLM tier pulls every book the page mentions,
//       with a one-line note-to-self per book that names the source.
//    3. Matching — each title/author resolves through the search hub with the
//       same confident-only gate as the Goodreads import: a wrong book is worse
//       than "couldn't find it".
//

import Foundation

/// What we know about the shared page before the model reads it.
struct LinkContent {
    var url: URL?
    var title: String?
    var description: String?
    var text: String
    /// Author/handle for social posts ("@bookishbecca"), from oEmbed.
    var authorName: String?

    var displayHost: String? {
        guard let host = url?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

enum LinkImportError: LocalizedError {
    case nothingToRead
    case unreachable
    case notReadable
    case aiUnavailable

    var errorDescription: String? {
        switch self {
        case .nothingToRead:
            return "That share didn't include a link or any text."
        case .unreachable:
            return "Couldn't load that page. Check your connection, or open the link in Safari and share it from there."
        case .notReadable:
            return "That page didn't have any readable text. Try opening it in Safari and sharing it from there."
        case .aiUnavailable:
            return "Couldn't read the page for books right now. Try again in a moment."
        }
    }
}

final class LinkBookExtractionService {
    static let shared = LinkBookExtractionService()

    private let session: URLSession
    /// Enough for a long listicle without paying for an entire site's nav in tokens.
    private static let maxTextChars = 28_000
    /// Beyond this the page is a JS bundle or a dump, not an article.
    private static let maxHTMLChars = 800_000
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
            "Accept": "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        session = URLSession(configuration: config)
    }

    // MARK: - 1. Content

    /// Page text for the model. Safari-captured text wins (it sees what the user
    /// saw, paywalls and logins included); a bare URL is fetched. Social video
    /// links additionally pull the caption via oEmbed, since their HTML is a
    /// script shell.
    func fetchContent(for payload: LinkImportPayload) async throws -> LinkContent {
        var content = LinkContent(url: payload.url, title: payload.title, description: payload.description, text: "", authorName: nil)
        let captured = (payload.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = payload.url {
            // Social embeds first: the caption is the whole point of those pages.
            if let embed = await fetchOEmbed(for: url) {
                content.authorName = embed.authorName
                if content.title == nil { content.title = embed.title }
                if !embed.text.isEmpty { content.text = embed.text }
            }
            if captured.count < 200 {
                // Nothing (or almost nothing) captured in Safari: read the page ourselves.
                if let fetched = try? await fetchPage(url) {
                    if content.title == nil || content.title?.isEmpty == true { content.title = fetched.title }
                    if content.description == nil { content.description = fetched.description }
                    if content.url == nil || fetched.url != nil { content.url = fetched.url ?? content.url }
                    if !fetched.text.isEmpty {
                        content.text = [content.text, fetched.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    }
                } else if content.text.isEmpty, captured.isEmpty {
                    throw LinkImportError.unreachable
                }
            }
        }
        if !captured.isEmpty {
            content.text = [content.text, captured].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        content.text = Self.condenseWhitespace(content.text)
        if content.text.count > Self.maxTextChars {
            content.text = String(content.text.prefix(Self.maxTextChars))
        }
        let hasAnything = !content.text.isEmpty
            || !(content.title ?? "").isEmpty
            || !(content.description ?? "").isEmpty
        guard hasAnything else {
            throw payload.url == nil ? LinkImportError.nothingToRead : LinkImportError.notReadable
        }
        return content
    }

    private struct OEmbed {
        let title: String?
        let authorName: String?
        let text: String
    }

    /// TikTok, YouTube, and X publish public oEmbed endpoints that return the
    /// post's caption/title and author without authentication. Instagram does not.
    private func fetchOEmbed(for url: URL) async -> OEmbed? {
        guard let host = url.host?.lowercased() else { return nil }
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
        let endpoint: String?
        if host.contains("tiktok.com") {
            endpoint = "https://www.tiktok.com/oembed?url=\(encoded)"
        } else if host.contains("youtube.com") || host.contains("youtu.be") {
            endpoint = "https://www.youtube.com/oembed?url=\(encoded)&format=json"
        } else if host.contains("twitter.com") || host == "x.com" || host.hasSuffix(".x.com") {
            endpoint = "https://publish.twitter.com/oembed?url=\(encoded)&omit_script=true"
        } else {
            endpoint = nil
        }
        guard let endpoint, let embedURL = URL(string: endpoint) else { return nil }
        guard let (data, response) = try? await session.data(from: embedURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let author = (json["author_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var text = ""
        if let html = json["html"] as? String {
            // X returns the tweet body as HTML; TikTok/YouTube don't include text here.
            text = Self.plainText(fromHTML: html).text
        }
        if text.isEmpty, let title { text = title }
        if let author, !text.isEmpty { text = "Posted by \(author):\n\(text)" }
        return OEmbed(title: title, authorName: author, text: text)
    }

    private struct FetchedPage {
        let url: URL?
        let title: String?
        let description: String?
        let text: String
    }

    private func fetchPage(_ url: URL) async throws -> FetchedPage {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw LinkImportError.unreachable
        }
        let mime = (http.mimeType ?? "").lowercased()
        var encoding = String.Encoding.utf8
        if let name = http.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            }
        }
        guard var raw = String(data: data, encoding: encoding) ?? String(data: data, encoding: .isoLatin1) else {
            throw LinkImportError.notReadable
        }
        if raw.count > Self.maxHTMLChars { raw = String(raw.prefix(Self.maxHTMLChars)) }
        if mime.contains("html") || raw.range(of: "<html", options: .caseInsensitive) != nil || raw.contains("<body") {
            let parsed = Self.plainText(fromHTML: raw)
            return FetchedPage(url: http.url ?? url, title: parsed.title, description: parsed.description, text: parsed.text)
        }
        // Plain text / JSON / anything else: hand it over as-is.
        return FetchedPage(url: http.url ?? url, title: nil, description: nil, text: raw)
    }

    // MARK: HTML → text

    struct ParsedHTML {
        let title: String?
        let description: String?
        let text: String
    }

    /// Visible text of an HTML document: scripts, styles, and markup dropped,
    /// block boundaries kept as line breaks, entities decoded. Regex-based on
    /// purpose — no WebKit, runs off the main thread, good enough for prose.
    static func plainText(fromHTML html: String) -> ParsedHTML {
        let title = firstMatch(in: html, pattern: "<title[^>]*>([\\s\\S]*?)</title>").map { decodeEntities(condenseWhitespace($0)) }
        let description = metaContent(in: html, names: ["og:description", "description", "twitter:description"])

        var s = html
        // Whole subtrees that never carry article text.
        for tag in ["script", "style", "noscript", "svg", "template", "iframe", "head"] {
            s = replacing(in: s, pattern: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ")
        }
        s = replacing(in: s, pattern: "<!--[\\s\\S]*?-->", with: " ")
        // Block-level boundaries become line breaks so list items stay on their own lines.
        s = replacing(in: s, pattern: "<br\\s*/?>", with: "\n")
        s = replacing(in: s, pattern: "</?(p|div|li|ul|ol|h[1-6]|tr|td|th|section|article|header|footer|blockquote|figcaption|dd|dt|table|nav|aside|main)\\b[^>]*>", with: "\n")
        s = replacing(in: s, pattern: "<[^>]+>", with: " ")
        s = decodeEntities(s)
        return ParsedHTML(title: title, description: description, text: condenseWhitespace(s))
    }

    private static func metaContent(in html: String, names: [String]) -> String? {
        for name in names {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let patterns = [
                "<meta[^>]+(?:property|name)=[\"']\(escaped)[\"'][^>]+content=[\"']([^\"']*)[\"']",
                "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+(?:property|name)=[\"']\(escaped)[\"']"
            ]
            for pattern in patterns {
                if let value = firstMatch(in: html, pattern: pattern) {
                    let decoded = decodeEntities(condenseWhitespace(value))
                    if !decoded.isEmpty { return decoded }
                }
            }
        }
        return nil
    }

    private static func firstMatch(in s: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = regex.firstMatch(in: s, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func replacing(in s: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: replacement)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "middot": "\u{00B7}", "bull": "\u{2022}"
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        guard let regex = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);", options: []) else { return s }
        var out = ""
        var last = s.startIndex
        for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(m.range, in: s), let inner = Range(m.range(at: 1), in: s) else { continue }
            out += s[last..<whole.lowerBound]
            let body = String(s[inner])
            var replacement: String? = nil
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let v = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(v) { replacement = String(Character(scalar)) }
            } else if body.hasPrefix("#") {
                if let v = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(v) { replacement = String(Character(scalar)) }
            } else {
                replacement = namedEntities[body.lowercased()]
            }
            out += replacement ?? String(s[whole])
            last = whole.upperBound
        }
        out += s[last...]
        return out
    }

    /// Collapse runs of spaces, trim each line, and cap blank runs at one.
    static func condenseWhitespace(_ s: String) -> String {
        var lines: [String] = []
        var blank = false
        for rawLine in s.components(separatedBy: .newlines) {
            let line = rawLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
            if line.isEmpty {
                if !blank, !lines.isEmpty { lines.append("") }
                blank = true
            } else {
                lines.append(line)
                blank = false
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 2. Extraction

    struct Extraction {
        let sourceLabel: String
        let candidates: [LinkBookCandidate]
    }

    private static let systemPrompt = """
    You find books in content a reader shared from another app (a web page, a video caption, a social post, pasted text) so they can add them to their reading queue.

    Return ONLY a JSON object, no prose, no code fences:
    {"source": "...", "books": [{"title": "...", "author": "...", "note": "..."}]}

    Rules:
    - "source": a short label for where these books came from, at most 50 characters, e.g. "Mark Cuban's top 10 books", "@bookishbecca on TikTok", "NYT best books of 2025". Use the page's own framing. Never a raw URL.
    - "books": every actual book the content is about or recommends, in the order they appear. Deduplicate. Include a book mentioned once in passing only when the content is clearly recommending it. Skip movies, podcasts, articles, courses, and products that are not books. Skip sidebar/footer noise like "customers also bought" or "trending now" unless the content itself is that list. If the page is about one book (a store listing, a review, a Goodreads page), return that one book. At most 40 books.
    - "title": the book's title without series markers or subtitles.
    - "author": the author's name as given; "" if the content never names one. Do not guess an author you are not sure of.
    - "note": a private note-to-self for the reader, at most 120 characters, plain text, no em dashes, no hashtags. Name the source and, when the content says something specific about that book, the one thing it said. Examples: "From Mark Cuban's top 10. He says it taught him how to sell." / "From @bookishbecca's February reads. Her favorite of the month." / "Recommended in Tim Ferriss's newsletter."
    - If there are no books, return {"source": "...", "books": []}.
    """

    /// Ask the model for the books on the page. Empty result is a valid answer.
    func extractBooks(from content: LinkContent) async throws -> Extraction {
        var lines: [String] = []
        if let url = content.url { lines.append("URL: \(url.absoluteString)") }
        if let host = content.displayHost { lines.append("Site: \(host)") }
        if let author = content.authorName { lines.append("Posted by: \(author)") }
        if let title = content.title, !title.isEmpty { lines.append("Title: \(title)") }
        if let description = content.description, !description.isEmpty { lines.append("Description: \(description)") }
        lines.append("")
        lines.append("Content:")
        lines.append(content.text.isEmpty ? "(no body text)" : content.text)

        let reply: String
        do {
            reply = try await ClaudeService.shared.sendMessage(
                system: Self.systemPrompt,
                userMessage: lines.joined(separator: "\n"),
                maxTokens: 4096,
                timeout: 60,
                tier: .simple
            )
        } catch {
            throw LinkImportError.aiUnavailable
        }
        guard let parsed = Self.parseExtraction(reply) else {
            throw LinkImportError.aiUnavailable
        }
        return parsed
    }

    /// Lenient JSON parse: the model occasionally wraps the object in fences or
    /// a sentence, so take the outermost braces.
    static func parseExtraction(_ reply: String) -> Extraction? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close else { return nil }
        let json = String(reply[open...close])
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let source = ((obj["source"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBooks = (obj["books"] as? [[String: Any]]) ?? []
        var candidates: [LinkBookCandidate] = []
        var seenKeys = Set<String>()
        for raw in rawBooks {
            let title = ((raw["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let author = ((raw["author"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var note = ((raw["note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            note = note.replacingOccurrences(of: "\u{2014}", with: ",").replacingOccurrences(of: " ,", with: ",")
            if note.count > QueueNoteCopy.maxLength { note = String(note.prefix(QueueNoteCopy.maxLength)) }
            // Same work listed twice (different casing, "The" dropped) collapses to one card.
            let key = LibraryDedup.workKey(title: title, author: author) ?? title.lowercased()
            guard seenKeys.insert(key).inserted else { continue }
            candidates.append(LinkBookCandidate(title: title, author: author == "Unknown" ? "" : author, note: note))
            if candidates.count >= 40 { break }
        }
        return Extraction(sourceLabel: source, candidates: candidates)
    }

    // MARK: - 3. Matching

    /// Resolve a candidate to a catalog book, confident-only. Search errors are
    /// `.failed` (retryable), a clean miss is `.noMatch` (manual search card).
    func matchCandidate(_ candidate: LinkBookCandidate) async -> GoodreadsMatchOutcome {
        let mainTitle = GoodreadsTitleMatcher.mainTitle(candidate.title)
        guard !mainTitle.isEmpty else { return .noMatch }
        let primaryAuthor = GoodreadsTitleMatcher.primaryAuthor(candidate.author)
        let lastName = candidate.author.isEmpty ? nil : GoodreadsTitleMatcher.authorLastName(primaryAuthor)
        let language = Locale.current.language.languageCode?.identifier.lowercased() ?? "en"

        // Same operator form the Goodreads import uses, then a plain "title author"
        // query as a second chance — some sources only answer one shape.
        var queries: [String] = []
        var operatorQuery = "intitle:\"\(mainTitle)\""
        if let lastName { operatorQuery += " inauthor:\"\(lastName)\"" }
        queries.append(operatorQuery)
        queries.append(candidate.author.isEmpty ? mainTitle : "\(mainTitle) \(primaryAuthor)")

        var sawError = false
        for query in queries {
            do {
                let results = try await GoogleBooksService.shared.search(query: query, languageRestriction: language, searchAuthors: false)
                if let pick = Self.pickConfident(from: results, candidate: candidate, lastName: lastName) {
                    return .matched(pick)
                }
            } catch is CancellationError {
                return .failed
            } catch {
                sawError = true
            }
        }
        return sawError ? .failed : .noMatch
    }

    private static func pickConfident(from results: [Book], candidate: LinkBookCandidate, lastName: String?) -> Book? {
        let confident = results.filter { book in
            if lastName != nil {
                return GoodreadsTitleMatcher.isConfidentMatch(rowTitle: candidate.title, rowAuthor: candidate.author, candidate: book)
            }
            // No author to check against: the normalized main titles must agree exactly.
            let want = GoodreadsTitleMatcher.normalize(GoodreadsTitleMatcher.mainTitle(candidate.title))
            let have = GoodreadsTitleMatcher.normalize(GoodreadsTitleMatcher.mainTitle(book.title))
            return !want.isEmpty && want == have
        }
        return confident.first { !$0.coverURL.isEmpty && $0.isbn != nil }
            ?? confident.first { !$0.coverURL.isEmpty }
            ?? confident.first
    }
}
