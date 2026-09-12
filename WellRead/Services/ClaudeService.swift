//
//  ClaudeService.swift
//  WellRead
//
//  LLM gateway for AI suggestions. Despite the name it now routes across two
//  providers: Google Gemini (cheap tier) and Anthropic Claude (quality tier +
//  fallback). Uses ApiKeys.gemini / ApiKeys.claude.
//

import Foundation

private let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
private let apiVersion = "2023-06-01"
private let geminiModelsBase = "https://generativelanguage.googleapis.com/v1beta/models"

struct ClaudeMessageRequest: Encodable {
    let model: String
    let maxTokens: Int
    let messages: [Message]
    let system: String?

    struct Message: Encodable {
        let role: String
        let content: String
    }

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case messages
        case system
    }
}

struct ClaudeMessageResponse: Decodable {
    let content: [ContentBlock]
    let stopReason: String?

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }

    var text: String {
        content.compactMap { $0.text }.joined()
    }
}

final class ClaudeService {
    static let shared = ClaudeService()
    private let session: URLSession

    enum Provider {
        case anthropic
        case gemini
    }

    /// Which model a call runs on. Pick the cheapest tier that doesn't meaningfully
    /// hurt quality; each tier is a fallback chain (an HTTP error — bad model, quota,
    /// outage — falls through to the next entry, crossing providers if needed).
    enum ModelTier {
        /// Gemini Flash-Lite ($0.30/$2.50 per MTok), falling back to Haiku ($1/$5):
        /// high-volume, well-scoped tasks — condensing a provided description,
        /// picking tags from a fixed list, matching similar titles, short rec lists.
        case simple
        /// Sonnet ($3/$15 per MTok): tasks that lean on deep knowledge of a book's
        /// actual contents, where a small model is likelier to fabricate — verbatim
        /// quotes, spoiler-aware prose and Q&A, refreshers, blend generation.
        case complex

        fileprivate var modelsToTry: [(provider: Provider, model: String)] {
            switch self {
            case .simple: return [
                (.gemini, "gemini-3.5-flash-lite"),
                (.anthropic, "claude-haiku-4-5"),
                (.anthropic, "claude-sonnet-5")
            ]
            case .complex: return [
                (.anthropic, "claude-sonnet-5"),
                (.anthropic, "claude-haiku-4-5")
            ]
            }
        }
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    /// Reply text plus the model that actually produced it (the tier's fallback
    /// chain means it isn't fixed) — callers persisting content record the model.
    struct DetailedResponse {
        let text: String
        let model: String
    }

    /// Sends a user message and returns the assistant's text reply. Requires ApiKeys.claude.
    /// `timeout` caps the wait for the (non-streaming) response — callers with a user
    /// staring at a spinner should pass one and fall back when it trips.
    func sendMessage(system: String? = nil, userMessage: String, maxTokens: Int = 1024, timeout: TimeInterval? = nil, tier: ModelTier = .complex) async throws -> String {
        try await sendMessageDetailed(system: system, userMessage: userMessage, maxTokens: maxTokens, timeout: timeout, tier: tier).text
    }

    /// `sendMessage` variant that also reports which model answered.
    func sendMessageDetailed(system: String? = nil, userMessage: String, maxTokens: Int = 1024, timeout: TimeInterval? = nil, tier: ModelTier = .complex) async throws -> DetailedResponse {
        try await sendConversationDetailed(
            system: system,
            messages: [.init(role: "user", content: userMessage)],
            maxTokens: maxTokens,
            timeout: timeout,
            tier: tier
        )
    }

    /// Multi-turn variant: sends alternating user/assistant turns (e.g. refresher Q&A follow-ups).
    func sendConversation(system: String? = nil, messages: [ClaudeMessageRequest.Message], maxTokens: Int = 1024, timeout: TimeInterval? = nil, tier: ModelTier = .complex) async throws -> String {
        try await sendConversationDetailed(system: system, messages: messages, maxTokens: maxTokens, timeout: timeout, tier: tier).text
    }

    // MARK: - House style

    /// Appended to every system prompt. Models reach for em dashes constantly and
    /// SPINE never shows one, so ask up front (and strip anyway, below).
    static let houseStyleRule = """

    STYLE (applies to every word you write): never use em dashes or en dashes \
    (\u{2014} or \u{2013}). Use a period, comma, colon, or parentheses instead. This is absolute.
    """

    /// Removes em/en dashes from model output. Runs on every response because the
    /// prompt rule alone isn't reliable: a dash between spaces becomes a comma,
    /// one jammed between words becomes a comma plus a space, and a leading dash
    /// (list bullets) is dropped. Safe inside JSON string values, which is what
    /// the JSON-returning callers get back.
    static func stripDashes(_ text: String) -> String {
        let dashes = ["\u{2014}", "\u{2013}", "\u{2015}"]
        guard dashes.contains(where: { text.contains($0) }) else { return text }
        var out = text
        for dash in dashes {
            // Bullet at the start of a line: drop it, keep the line.
            out = out.replacingOccurrences(of: "\n\(dash) ", with: "\n")
            out = out.replacingOccurrences(of: " \(dash) ", with: ", ")
            out = out.replacingOccurrences(of: "\(dash) ", with: ", ")
            out = out.replacingOccurrences(of: " \(dash)", with: ",")
            out = out.replacingOccurrences(of: dash, with: ", ")
        }
        if out.hasPrefix(", ") { out.removeFirst(2) }
        return out
    }

    /// `sendConversation` variant that also reports which model answered.
    func sendConversationDetailed(system: String? = nil, messages: [ClaudeMessageRequest.Message], maxTokens: Int = 1024, timeout: TimeInterval? = nil, tier: ModelTier = .complex) async throws -> DetailedResponse {
        let system = (system?.isEmpty == false) ? system! + Self.houseStyleRule : Self.houseStyleRule
        var lastError: Error?
        for entry in tier.modelsToTry {
            let key: String?
            switch entry.provider {
            case .anthropic: key = ApiKeys.claude
            case .gemini: key = ApiKeys.gemini
            }
            // Provider not configured: skip to the next entry in the chain.
            guard let key, !key.isEmpty else { continue }
            do {
                switch entry.provider {
                case .anthropic:
                    let text = try await send(model: entry.model, key: key, system: system, messages: messages, maxTokens: maxTokens, timeout: timeout)
                    return DetailedResponse(text: Self.stripDashes(text), model: entry.model)
                case .gemini:
                    let text = try await sendGemini(model: entry.model, key: key, system: system, messages: messages, maxTokens: maxTokens, timeout: timeout)
                    return DetailedResponse(text: Self.stripDashes(text), model: entry.model)
                }
            } catch {
                lastError = error
                let ns = error as NSError
                // Any HTTP-level failure (retired model, bad key, quota, outage)
                // falls through to the next entry — crossing providers if needed.
                // Network errors (offline) surface directly; retrying won't help.
                if ns.domain == "ClaudeService", ns.code > 0 {
                    continue
                }
                throw error
            }
        }
        throw lastError ?? NSError(domain: "ClaudeService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No AI provider configured. Add CLAUDE_API_KEY or GEMINI_API_KEY to Secrets.plist."])
    }

    /// Models that reason before answering unless told not to (see `send`).
    private static func thinksByDefault(model: String) -> Bool {
        // (Fable-tier models can't disable thinking at all — 400 — so leave them out.)
        model.hasPrefix("claude-sonnet-5") || model.hasPrefix("claude-opus-5")
    }

    private func send(model: String, key: String, system: String?, messages: [ClaudeMessageRequest.Message], maxTokens: Int, timeout: TimeInterval? = nil) async throws -> String {
        var request = URLRequest(url: messagesURL)
        request.httpMethod = "POST"
        // The response arrives as one body after generation, so the idle timeout
        // effectively bounds total wait.
        if let timeout { request.timeoutInterval = timeout }
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        if let system = system, !system.isEmpty {
            body["system"] = system
        }
        // Sonnet 5 / Opus 5 run adaptive extended thinking whenever `thinking` is
        // omitted, and that thinking is billed against `max_tokens`. Every call in
        // this app wants a short, plain answer (usually JSON), so with the default
        // on, the model spent the whole budget thinking and returned truncated or
        // empty text — Book Blend silently fell back to its deterministic copy on
        // ~60% of blends (Sep 2026). Haiku 4.5 and older models don't think unless
        // asked, and reject this key with a budget, so only send it where needed.
        if Self.thinksByDefault(model: model) {
            body["thinking"] = ["type": "disabled"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ClaudeService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid response."])
        }
        if http.statusCode != 200 {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            let detail = message?["message"] as? String ?? "Request failed (HTTP \(http.statusCode))."
            throw NSError(domain: "ClaudeService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: detail])
        }
        let decoded = try JSONDecoder().decode(ClaudeMessageResponse.self, from: data)
        return decoded.text
    }

    // MARK: - Gemini

    private struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]?
            }
            let content: Content?
        }
        let candidates: [Candidate]?

        var text: String {
            (candidates?.first?.content?.parts ?? []).compactMap { $0.text }.joined()
        }
    }

    /// Same contract as `send`, against the Gemini generateContent REST API.
    /// Claude "assistant" turns map to Gemini's "model" role.
    private func sendGemini(model: String, key: String, system: String?, messages: [ClaudeMessageRequest.Message], maxTokens: Int, timeout: TimeInterval? = nil) async throws -> String {
        guard let url = URL(string: "\(geminiModelsBase)/\(model):generateContent") else {
            throw NSError(domain: "ClaudeService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini model name."])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let timeout { request.timeoutInterval = timeout }
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "contents": messages.map { message in
                [
                    "role": message.role == "assistant" ? "model" : "user",
                    "parts": [["text": message.content]]
                ]
            },
            "generationConfig": ["maxOutputTokens": maxTokens]
        ]
        if let system, !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ClaudeService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid response."])
        }
        if http.statusCode != 200 {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            let detail = message?["message"] as? String ?? "Request failed (HTTP \(http.statusCode))."
            throw NSError(domain: "ClaudeService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: detail])
        }
        return try JSONDecoder().decode(GeminiResponse.self, from: data).text
    }
}
