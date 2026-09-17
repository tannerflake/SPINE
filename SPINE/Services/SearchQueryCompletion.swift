//
//  SearchQueryCompletion.swift
//  SPINE
//
//  Finishes a half-typed last word in a book search. Every catalog API the app
//  talks to matches whole words, so "lord of the rin" returns literal-"rin"
//  oddities and never The Lord of the Rings, no matter how the results are
//  ranked. This resolves the partial word *before* the search runs: Open
//  Library's Solr index accepts a trailing wildcard, so "lord of the rin*"
//  answers with the popular works whose titles the typed prefix could still
//  become, and the most-shelved one supplies the missing letters.
//
//  Used by `GoogleBooksService.searchDetailed`, which surfaces the completion
//  so the UI can say what it searched for and offer the literal query back.
//

import Foundation

enum SearchQueryCompletion {

    /// How many catalog rows the wildcard probe considers. Open Library returns
    /// them in relevance order; popularity picks the winner among those.
    private static let probeLimit = 10
    /// Interactive search waits on the probe before showing anything, so cap it:
    /// past this, no completion is a better answer than a stalled field.
    private static let probeTimeout: UInt64 = 4_000_000_000
    /// A completion adding more than this many letters is a different word, not
    /// the word being typed ("the ro" → "the roadmaster's daughter").
    private static let maxAddedCharacters = 10
    /// Never offered as a completion: nobody needs help finishing "of", and
    /// "Harry Potter and the O…" must reach for "Order", not the "of" three
    /// words later in the same title.
    private static let stopwords: Set<String> = [
        "of", "and", "the", "a", "an", "in", "on", "to", "or",
        "for", "with", "from", "by", "at", "is", "it", "as"
    ]

    private static let lock = NSLock()
    /// Memoized verdicts (including "no completion"), keyed by normalized query.
    /// Typing forward re-probes for each new prefix, but re-running, retrying,
    /// or backspacing to an earlier query is free.
    private static var memo: [String: String?] = [:]
    private static let memoCap = 60

    /// The query with its last word completed, or nil when the last word is
    /// already whole, nothing popular extends it, or the query isn't the shape
    /// this applies to. Never throws: a failed probe just means no completion.
    static func completedQuery(for query: String) async -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, !trimmed.lowercased().hasPrefix("isbn:") else { return nil }
        let normalized = BookSearchRanker.normalize(trimmed)
        let tokens = normalized.split(separator: " ").map(String.init)
        // A trailing number is a volume/year, not a truncated word. A single
        // letter is only worth completing when the words before it carry the
        // query ("where the crawdads s"); alone it says nothing.
        let minimumLastToken = tokens.count > 1 ? 1 : 2
        guard let lastToken = tokens.last, lastToken.count >= minimumLastToken,
              !lastToken.allSatisfy(\.isNumber) else { return nil }
        if let memoized = cachedVerdict(for: normalized) { return memoized }

        let headTokens = Array(tokens.dropLast())
        // Two probes, started together. Open Library's title-only index answers
        // a wildcard in about a second where its everything index can take five
        // or more, so the title answer usually settles it; the slower one is
        // only waited on when titles alone had nothing, which is exactly the
        // case it exists for (a half-typed author name).
        //
        // A one-word query skips the title index entirely: with no other word to
        // anchor on, its ten most relevant wildcard rows can miss the very book
        // spelling the word out ("circe" saw Circeo travel guides but not Circe),
        // and the everything index answers a one-word wildcard quickly anyway.
        let probes = tokens.count > 1
            ? [probeTask(for: trimmed, index: .title), probeTask(for: trimmed, index: .everything)]
            : [probeTask(for: trimmed, index: .everything)]
        var completion: String?
        var probed = false
        for probe in probes {
            guard let rows = await probe.value else { continue }
            probed = true
            if let word = completionWord(in: rows, headTokens: headTokens, lastToken: lastToken) {
                completion = word
                break
            }
        }
        probes.forEach { $0.cancel() }
        // Both probes failed or timed out: no verdict, and nothing to memoize —
        // the next attempt at this query should try again.
        guard probed else { return nil }
        let result = completion.map { substitutingLastWord(in: trimmed, with: $0) }
        memoize(result, for: normalized)
        return result
    }

    /// One wildcard probe, capped by `probeTimeout`. Resolves to nil when the
    /// request fails or runs long.
    private static func probeTask(
        for query: String,
        index: OpenLibraryService.PrefixIndex
    ) -> Task<[OpenLibraryService.PrefixMatch]?, Never> {
        Task {
            await withTaskGroup(of: [OpenLibraryService.PrefixMatch]?.self) { group in
                group.addTask {
                    try? await OpenLibraryService.shared.prefixMatches(query: query, index: index, limit: probeLimit)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: probeTimeout)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
    }

    /// The word the last token should become, or nil to leave the query alone.
    ///
    /// Only rows accounting for every *other* query word are consulted — one
    /// that matched the wildcard on an unrelated word says nothing about what
    /// the user is typing. Those rows split two ways: rows using the typed
    /// token as a whole word (evidence the query is already finished) and rows
    /// extending it (evidence it isn't). Shelvings settle it, so an obscure
    /// "The Hob and Miss Minkin" can't veto The Hobbit, while "dune" and
    /// "the road" stay untouched because the works spelling them whole are the
    /// popular ones. A one-letter token is never taken as a whole word: that's
    /// an author's initial ("J. R. R. Tolkien"), not a word.
    private static func completionWord(
        in rows: [OpenLibraryService.PrefixMatch],
        headTokens: [String],
        lastToken: String
    ) -> String? {
        var best: (word: String, popularity: Int)?
        var bestWholeWord = -1
        for row in rows {
            let words = BookSearchRanker.normalize(row.title).split(separator: " ").map(String.init)
                + BookSearchRanker.normalize(row.author).split(separator: " ").map(String.init)
            let wordSet = Set(words)
            guard headTokens.allSatisfy({ wordSet.contains($0) }) else { continue }
            if lastToken.count >= 2, wordSet.contains(lastToken) {
                bestWholeWord = max(bestWholeWord, row.popularity)
                continue
            }
            let extensions = words.filter {
                $0.hasPrefix(lastToken) && $0.count > lastToken.count
                    && $0.count - lastToken.count <= maxAddedCharacters
                    && !stopwords.contains($0)
            }
            // Shortest extension: the typed prefix is likelier to be reaching for
            // "rings" than "ringbearers".
            guard let word = extensions.min(by: { $0.count < $1.count }) else { continue }
            if best == nil || row.popularity > best!.popularity {
                best = (word, row.popularity)
            }
        }
        guard let best, best.popularity > bestWholeWord else { return nil }
        return best.word
    }

    /// Swaps the query's last whitespace-separated run for `word`, matching the
    /// capitalization the user was typing so the completion reads back as their
    /// own query ("lord of the rin" → "lord of the rings").
    private static func substitutingLastWord(in query: String, with word: String) -> String {
        guard let separator = query.lastIndex(where: { $0.isWhitespace }) else {
            return matchingCase(of: query, in: word)
        }
        let typed = String(query[query.index(after: separator)...])
        return String(query[...separator]) + matchingCase(of: typed, in: word)
    }

    private static func matchingCase(of typed: String, in word: String) -> String {
        guard let first = typed.first, first.isUppercase else { return word }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    // MARK: - Memo

    private static func cachedVerdict(for normalized: String) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return memo[normalized]
    }

    private static func memoize(_ result: String?, for normalized: String) {
        lock.lock()
        defer { lock.unlock() }
        // Plain reset rather than an LRU: this is a typing-session convenience,
        // and the next few keystrokes refill it.
        if memo.count >= memoCap { memo.removeAll(keepingCapacity: true) }
        memo[normalized] = result
    }
}
