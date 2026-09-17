//
//  BookSearchRanker.swift
//  SPINE
//
//  Ranks and de-duplicates Google Books search results so the edition a user
//  expects lands at the top. Google's raw relevance order surfaces reissues
//  ("10th Anniversary Edition"), foreign-language editions, knockoff listings
//  with publisher-as-author, and duplicate entries of the same work; this
//  re-scores results on query match, popularity (ratingsCount, when Google
//  returns it), metadata completeness, and edition noise, then collapses
//  editions of the same work down to the best one, backfilling missing
//  metadata (cover, ISBN, description) from sibling editions.
//

import Foundation

/// Per-result signals from the search payload that `Book` doesn't carry.
struct BookSearchSignals {
    var ratingsCount: Int?
    var averageRating: Double?
    var language: String?
}

enum BookSearchRanker {

    struct Candidate {
        let book: Book
        let signals: BookSearchSignals
    }

    /// Ranks candidates against the query. When `deduplicate` is true, editions
    /// of the same work (same core title + primary author) collapse to the
    /// highest-scored one. `libraryAuthors` are author names already in the
    /// user's library; their books get a small personalization boost.
    /// `popularKeys` are `popularityKey` values of works 2+ SPINE members have
    /// logged (see `BookPopularityService`); those get a large boost — a book
    /// real users shelved beats any catalog-noise listing.
    static func rank(
        _ candidates: [Candidate],
        query: String,
        deduplicate: Bool = true,
        libraryAuthors: Set<String> = [],
        popularKeys: Set<String> = []
    ) -> [Book] {
        let normQuery = normalize(query)
        guard !normQuery.isEmpty else { return candidates.map(\.book) }
        let queryTokens = normQuery.split(separator: " ").map(String.init)
        let deviceLanguage = Locale.current.language.languageCode?.identifier.lowercased()
        let normalizedLibraryAuthors = Set(libraryAuthors.map(normalize).filter { !$0.isEmpty })

        // Google's own relevance order breaks score ties (stable sort by index).
        let scored = candidates.enumerated()
            .map { (index: $0.offset, candidate: $0.element, score: score(
                $0.element,
                normQuery: normQuery,
                queryTokens: queryTokens,
                deviceLanguage: deviceLanguage,
                libraryAuthors: normalizedLibraryAuthors,
                popularKeys: popularKeys
            )) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }

        guard deduplicate else { return scored.map(\.candidate.book) }
        // Collapse each work to its best-scored edition, but backfill metadata the
        // winner lacks from sibling editions: Google often lists the canonical
        // edition without a cover while a reissue of the same work has one.
        // Grouping uses `collapseKey`, which is deliberately more aggressive than
        // the persisted `workKey`: catalogs list the same work as "Consider the
        // Lobster", "Consider the Lobster And Other Essays" (subtitle appended
        // without a colon), and "…and Other Essays Lib/E" by "Unknown" — all of
        // which must land in one row.
        var order: [String] = []
        var winners: [String: Book] = [:]
        var groupForTitle: [String: String] = [:]
        for entry in scored {
            let book = entry.candidate.book
            let collapse = collapseKey(title: book.title, author: book.author)
            var key = collapse.full
            // Authorless catalog records ("Unknown") join the group a real author
            // already claimed for this title instead of surviving as their own row.
            if winners[key] == nil, collapse.surname.isEmpty,
               let claimed = groupForTitle[collapse.titlePart] {
                key = claimed
            }
            if var winner = winners[key] {
                let sibling = book
                if winner.coverURL.isEmpty && !sibling.coverURL.isEmpty {
                    winner.coverURL = sibling.coverURL
                    winner.fallbackCoverURLs = sibling.fallbackCoverURLs
                }
                if winner.isbn == nil { winner.isbn = sibling.isbn }
                if (winner.description ?? "").isEmpty { winner.description = sibling.description }
                winners[key] = winner
            } else {
                order.append(key)
                winners[key] = book
                if !collapse.surname.isEmpty, groupForTitle[collapse.titlePart] == nil {
                    groupForTitle[collapse.titlePart] = key
                }
            }
        }
        return order.compactMap { winners[$0] }
    }

    // MARK: - Scoring

    private static func score(
        _ candidate: Candidate,
        normQuery: String,
        queryTokens: [String],
        deviceLanguage: String?,
        libraryAuthors: Set<String>,
        popularKeys: Set<String>
    ) -> Double {
        let book = candidate.book
        let rawMainTitle = book.title.split(separator: ":", maxSplits: 1).first.map(String.init) ?? book.title
        let normTitle = normalize(book.title)
        let normMainTitle = normalize(rawMainTitle)
        let normAuthor = normalize(book.author)
        let titleTokens = normTitle.split(separator: " ").map(String.init)
        let authorTokens = normAuthor.split(separator: " ").map(String.init)

        var score = 0.0

        // Title match: exact > main-title exact > prefix (supports search-as-you-type)
        // > token coverage. A subtitle-only exact match ranks below the whole-title
        // one so "Sapiens" beats "Sapiens: A Graphic History" for query "sapiens".
        // Comparisons are leading-article-insensitive (like workKey): "A Game of
        // Thrones" must take the whole-title tier for query "game of thrones",
        // or every companion book titled "Game of Thrones: <subtitle>" outranks
        // the actual novel on the main-title tier.
        let coreQuery = stripLeadingArticle(normQuery)
        let coreTitle = stripLeadingArticle(normTitle)
        let coreMainTitle = stripLeadingArticle(normMainTitle)
        var titleTierBonus = 0.0
        if normTitle == normQuery || coreTitle == coreQuery {
            titleTierBonus = 120
        } else if normMainTitle == normQuery || coreMainTitle == coreQuery {
            titleTierBonus = 100
        } else if coreMainTitle.hasPrefix(coreQuery) || coreQuery.hasPrefix(coreMainTitle) {
            titleTierBonus = 80
        }
        score += titleTierBonus
        var titleCoverage = 0.0
        var authorCoverage = 0.0
        var tokensFoundAnywhere = 0
        for (i, queryToken) in queryTokens.enumerated() {
            // The token still being typed may be a prefix of a full word.
            let allowPrefix = i == queryTokens.count - 1
            let inTitle = bestTokenMatch(queryToken, in: titleTokens, allowPrefix: allowPrefix)
            let inAuthor = bestTokenMatch(queryToken, in: authorTokens, allowPrefix: allowPrefix)
            titleCoverage += inTitle
            authorCoverage += inAuthor
            if max(inTitle, inAuthor) >= 0.7 { tokensFoundAnywhere += 1 }
        }
        let queryTokenCount = Double(queryTokens.count)
        score += 60 * titleCoverage / queryTokenCount
        score += 40 * authorCoverage / queryTokenCount
        // Every query word accounted for across title+author (e.g. "hobbit tolkien").
        if tokensFoundAnywhere == queryTokens.count { score += 25 }

        // Popularity: ratingsCount separates the canonical edition from catalog noise.
        let ratings = candidate.signals.ratingsCount ?? 0
        score += min(36, log10(Double(ratings) + 1) * 12)

        // Metadata completeness correlates strongly with "real" editions.
        if !book.coverURL.isEmpty { score += 12 }
        if book.isbn != nil { score += 8 }
        if !(book.description ?? "").isEmpty { score += 4 }

        // Language: soft preference for the device language, not a hard filter.
        // Records with no explicit language (common from ISBNdb) fall back to the
        // language implied by the ISBN registration group — a 978-602 ISBN is an
        // Indonesian-market edition even when the record and title say nothing.
        let language = candidate.signals.language ?? impliedLanguageCode(fromISBN: book.isbn)
        if let lang = language?.lowercased(), let device = deviceLanguage {
            score += lang == device ? 8 : -15
        }

        // Reissue noise sinks below the standard edition unless explicitly searched for.
        if containsEditionNoise(normTitle) && !containsEditionNoise(normQuery) {
            score -= 18
        }

        // Derivative works (graphic adaptations, workbooks, journals) rank below
        // the original unless the query asks for them.
        if containsDerivativeMarker(normTitle) && !containsDerivativeMarker(normQuery) {
            score -= 18
        }

        // Franchise companion/merch listings (costume books, storyboards,
        // "...and Philosophy" litcrit) sink below real works unless asked for.
        // Big enough to undo their main-title-exact bonus edge over token matches.
        if containsCompanionMarker(normTitle) && !containsCompanionMarker(normQuery) {
            score -= 30
        }

        // Knockoff listings credit a publisher-sounding name ("University Press",
        // "Readtrepreneur Publishing", "Book Of Thrones") as the author. Sink
        // them hard — and revoke the title-tier bonus, since these listings
        // copy the franchise title verbatim and would otherwise ride an exact
        // match above every legitimate book except the one true exact match.
        if authorLooksLikePublisher(book.author) {
            score -= 60 + titleTierBonus
        } else if normAuthor.isEmpty || normAuthor == "unknown" {
            score -= 20
        }

        // Slight preference for concise titles over keyword-stuffed catalog entries.
        let extraTokens = titleTokens.count - queryTokens.count - 2
        if extraTokens > 0 { score -= min(12, Double(extraTokens) * 1.5) }

        // Personalization: the user already reads this author.
        if !libraryAuthors.isEmpty {
            let bookAuthors = book.author.split(separator: ",").map { normalize(String($0)) }
            if bookAuthors.contains(where: { libraryAuthors.contains($0) }) { score += 10 }
        }

        // Community signal: 2+ SPINE members shelved this work. Big enough to
        // dominate metadata/edition noise, small enough that an exact title
        // match on something else still wins.
        if !popularKeys.isEmpty, popularKeys.contains(popularityKey(title: book.title, author: book.author)) {
            score += 30
        }

        return score
    }

    /// 1.0 exact token, 0.9 prefix (last query token only), 0.7 fuzzy (typo), 0 none.
    private static func bestTokenMatch(_ queryToken: String, in tokens: [String], allowPrefix: Bool) -> Double {
        var best = 0.0
        for token in tokens {
            if token == queryToken { return 1.0 }
            if allowPrefix, queryToken.count >= 2, token.hasPrefix(queryToken) {
                best = max(best, 0.9)
            } else if queryToken.count >= 5 {
                let threshold = queryToken.count >= 8 ? 2 : 1
                if abs(token.count - queryToken.count) <= threshold,
                   levenshtein(queryToken, token, limit: threshold) <= threshold {
                    best = max(best, 0.7)
                }
            }
        }
        return best
    }

    /// True when one of the top `topN` results is plausibly the thing `query`
    /// names: its main title (leading article ignored) or its author matches
    /// the query or starts with it. The search hub asks this of the literal
    /// query's results before spending anything on a completion (see
    /// `SearchQueryCompletion`) — if the book or the author is already on
    /// screen, finishing the user's last word for them would only churn the
    /// list, and waiting on a probe to say so would only stall the field.
    static func anyResultMatchesQuery(_ books: [Book], query: String, topN: Int = 5) -> Bool {
        let coreQuery = stripLeadingArticle(normalize(query))
        guard !coreQuery.isEmpty else { return false }
        return books.prefix(topN).contains { book in
            let mainTitle = book.title.split(separator: ":", maxSplits: 1).first.map(String.init) ?? book.title
            let coreTitle = stripLeadingArticle(normalize(mainTitle))
            if coreTitle == coreQuery || coreTitle.hasPrefix(coreQuery) { return true }
            return book.author.split(separator: ",").contains { segment in
                let author = normalize(String(segment))
                return !author.isEmpty && author.hasPrefix(coreQuery)
            }
        }
    }

    // MARK: - Deduplication

    /// Editions of the same work share a key: core title (parentheticals and
    /// edition phrases stripped, subtitle dropped) + primary author. Digits in
    /// the subtitle (volume/part numbers) stay in the key so "Vol 1" and
    /// "Vol 2" never merge, and derivative markers ("A Graphic History") stay
    /// so adaptations never merge with the original work.
    static func workKey(title: String, author: String) -> String {
        var raw = title
        raw = raw.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
        let parts = raw.split(separator: ":", maxSplits: 1)
        var main = parts.first.map(String.init) ?? raw
        let subtitle = parts.count > 1 ? String(parts[1]) : ""
        main = stripEditionPhrases(from: main)
        // Leading articles differ between catalog entries of the same work.
        let norm = stripLeadingArticle(normalize(main))
        let normSubtitle = normalize(subtitle)
        let subtitleMarkers = derivativeMarkers.filter { normSubtitle.contains($0) }.joined(separator: " ")
        let subtitleDigits = subtitle.filter(\.isNumber)
        // Surname only: catalogs list the same author as "J.R.R. Tolkien",
        // "J. R. R. Tolkien", and "John Ronald Reuel Tolkien".
        let primaryAuthor = normalize(String(author.split(separator: ",").first ?? ""))
        let surname = primaryAuthor.split(separator: " ").last.map(String.init) ?? primaryAuthor
        return norm + "|" + subtitleMarkers + subtitleDigits + "|" + surname
    }

    /// In-list edition-collapse identity, deliberately more aggressive than
    /// `workKey`. NEVER persisted — `workKey` is stored on Firestore book docs
    /// and queried for canonical-doc resolution, so its semantics must stay
    /// frozen; this key only decides which search rows merge on screen. On top
    /// of `workKey`'s stripping it removes audio/format suffixes ("Lib/E",
    /// "MP3 CD"), drops a trailing run of collection-subtitle words appended
    /// without a colon ("…And Other Essays", "…Essays and Arguments"), and
    /// reports a missing/"Unknown" author as an empty surname so the dedup
    /// loop can attach those records to a same-titled group.
    struct CollapseKey {
        let titlePart: String
        let surname: String
        var full: String { titlePart + "|" + surname }
    }

    static func collapseKey(title: String, author: String) -> CollapseKey {
        var raw = title
        raw = raw.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
        raw = stripFormatSuffixes(from: raw)
        let parts = raw.split(separator: ":", maxSplits: 1)
        var main = parts.first.map(String.init) ?? raw
        let subtitle = parts.count > 1 ? String(parts[1]) : ""
        main = stripEditionPhrases(from: main)
        var norm = stripLeadingArticle(normalize(main))
        norm = stripTrailingCollectionWords(from: norm)
        let normSubtitle = normalize(subtitle)
        let subtitleMarkers = derivativeMarkers.filter { normSubtitle.contains($0) }.joined(separator: " ")
        let subtitleDigits = subtitle.filter(\.isNumber)
        let primaryAuthor = normalize(String(author.split(separator: ",").first ?? ""))
        var surname = primaryAuthor.split(separator: " ").last.map(String.init) ?? primaryAuthor
        if surname == "unknown" || surname == "anonymous" { surname = "" }
        return CollapseKey(titlePart: norm + "|" + subtitleMarkers + subtitleDigits, surname: surname)
    }

    /// Audio/format markers catalogs bolt onto the title itself: "Lib/E" is
    /// Blackstone's library-edition audiobook suffix, "MP3 CD" and friends are
    /// physical-audio formats. Runs on the raw title (pre-normalize).
    private static let formatSuffixPatterns: [String] = [
        #"\blib\s*/?\s*e\b"#,
        #"\bmp3\s*cd\b"#,
        #"\baudio\s*cd\b"#,
        #"\bcompact\s+disc\b"#,
        #"\baudiobook\b"#
    ]

    private static func stripFormatSuffixes(from title: String) -> String {
        var result = title
        for pattern in formatSuffixPatterns {
            result = result.replacingOccurrences(
                of: pattern, with: " ", options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    /// Collection-subtitle words that catalogs append to the main title without
    /// a colon ("Consider the Lobster And Other Essays"). Only a *trailing* run
    /// is dropped, and never the whole title ("Collected Poems" stays intact).
    private static let trailingCollectionWords: Set<String> = [
        "and", "other", "a", "an", "the", "collected", "selected",
        "essays", "stories", "poems", "poetry", "tales", "writings",
        "arguments", "novellas", "novel", "memoir"
    ]

    private static func stripTrailingCollectionWords(from normalized: String) -> String {
        var tokens = normalized.split(separator: " ")
        while let last = tokens.last, trailingCollectionWords.contains(String(last)) {
            tokens.removeLast()
        }
        guard !tokens.isEmpty else { return normalized }
        return tokens.joined(separator: " ")
    }

    private static let editionPhrasePatterns: [String] = [
        #"(\d+(st|nd|rd|th)\s+)?anniversary(\s+edition)?"#,
        #"deluxe(\s+edition)?"#,
        #"collector'?s?(\s+edition)?"#,
        #"special\s+edition"#,
        #"illustrated(\s+edition)?"#,
        #"annotated(\s+edition)?"#,
        #"commemorative(\s+edition)?"#,
        #"large\s+print"#,
        #"(movie|tv|media)\s+tie[- ]?in(\s+edition)?"#,
        #"unabridged"#,
        #"abridged"#,
        #"box(ed)?\s+set"#
    ]

    private static func stripEditionPhrases(from title: String) -> String {
        var result = title
        for pattern in editionPhrasePatterns {
            result = result.replacingOccurrences(
                of: pattern, with: " ", options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    private static let editionNoiseTerms: [String] = [
        "anniversary", "deluxe", "collectors", "special edition", "illustrated",
        "annotated", "commemorative", "large print", "tie in", "unabridged",
        "abridged", "boxed set", "box set"
    ]

    private static func containsEditionNoise(_ normalized: String) -> Bool {
        editionNoiseTerms.contains { normalized.contains($0) }
    }

    // MARK: - Junk listings

    /// Catalog listings that aren't a real standalone edition of a work: multi-book
    /// collection sets, study guides / summaries, and foreign-language reprints.
    /// Patterns run against *normalized* text (lowercased, punctuation collapsed
    /// to spaces), for both the title and the query.
    private static let junkListingPatterns: [String] = [
        // Multi-book bundles. SPINE users log individual books, essentially never
        // collection listings, so bundle shapes are filtered aggressively:
        // count-first phrasing ("3 volumes : …", "4-Book Digital Collection") is
        // a bundle; name-first phrasing ("Volume 2", "Book 3", "tome 1") is
        // series numbering and stays. "(?!\s+of)" spares titles like "The Five
        // Books of Moses".
        #"\b\d+\s+(books?|volumes?|novels?)(?!\s+of\b)"#,
        #"\bbooks?\s+(collection|set|bundle)\b"#,
        #"\bcollection\b"#,
        #"\btrilogy\b"#,
        #"\bomnibus\b"#,
        #"\bbox(ed)?\s+set\b"#,
        #"\b\d+\s+in\s+1\b"#,
        #"\b(double|dual)\s+edition\b"#,
        // Study-guide / summary knockoffs, and free promotional excerpts —
        // "Brandon Sanderson Sampler", "Hunger Games tome 1 extrait gratuit",
        // "Smart Pop Preview 2013".
        #"summar"#,
        #"\bsampler\b"#,
        #"\bpreview\b"#,
        #"\bexcerpt\b"#,
        #"\bextrait\b"#,
        #"\bgratuit\b"#,
        #"\bfree\s+(sample|preview|excerpt)\b"#,
        #"\bstudy\s+guide\b"#,
        #"sparknotes"#,
        #"cliffsnotes"#,
        #"\bbook\s+review\b"#,
        #"\banalysis\s+of\b"#,
        #"\breading\s+guide\b"#,
        #"\bconversation\s+starters\b"#,
        #"\bkey\s+takeaways\b"#,
        // Franchise merch that isn't a book at all: calendars, quiz/trivia
        // paperbacks, coloring/sticker/tarot tie-ins, "unofficial" knockoffs.
        #"\bcalendar\b"#,
        #"\bunofficial\b"#,
        #"\bquiz(zes)?\s+book\b"#,
        #"\btrivia\s+(book|questions?|quiz)\b"#,
        #"\bword\s+search(es)?\b"#,
        #"\bcolou?ring\s+book\b"#,
        #"\bsticker\s+book\b"#,
        #"\btarot\b"#,
        #"\bpop\s+up\s+(book|guide)\b"#,
        // Foreign-language reprints labeled in English: "(French Edition)".
        #"\b(french|spanish|german|italian|portuguese|dutch|russian|chinese|japanese|korean|polish|romanian|czech|swedish|norwegian|danish|finnish|turkish|arabic|hindi|thai|vietnamese|indonesian|greek|hebrew|ukrainian|hungarian|bulgarian|croatian|serbian|slovak|persian|urdu|bengali|multilingual|bilingual)\s+(edition|version)\b"#
    ]

    /// True when the title is a junk listing the query didn't explicitly ask for.
    /// A query that itself matches any junk pattern disables the filter entirely —
    /// the user is deliberately hunting that kind of listing. Used as a hard filter
    /// in the search chain (the "show all editions" fallback also bypasses it, so
    /// nothing becomes unfindable).
    static func isJunkListing(title: String, query: String, author: String = "") -> Bool {
        let normQuery = normalize(query)
        let matchesAny: (String) -> Bool = { text in
            junkListingPatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
        }
        if matchesAny(normQuery) { return false }
        let normTitle = normalize(title)
        if matchesAny(normTitle) { return true }
        // Blank-book merch ("Hunger Games NOTEBOOK" by "Games, The Hunger"): a
        // notebook/journal-class title whose "author" is just the title's own
        // words rearranged is never a real book. Both signals are required —
        // real novels named "The Notebook" and real dream journals by real
        // authors have authors that share nothing with the title.
        if normTitle.range(of: blankBookMarkerPattern, options: .regularExpression) != nil,
           authorIsTitleClone(author: author, normalizedTitle: normTitle) {
            return true
        }
        return false
    }

    private static let blankBookMarkerPattern =
        #"\b(notebook|notepad|journal|diary|planner|sketchbook|log\s+book)\b"#

    /// True when every non-article author token appears among the title's own
    /// tokens (and there is at least one) — the author is the franchise name,
    /// not a person. "Games, The Hunger" vs "hunger games notebook" → true;
    /// "Nicholas Sparks" vs "the notebook" → false.
    private static func authorIsTitleClone(author: String, normalizedTitle: String) -> Bool {
        let stopwords: Set<String> = ["the", "a", "an", "of", "and"]
        let authorTokens = normalize(author).split(separator: " ").map(String.init)
            .filter { !stopwords.contains($0) }
        guard !authorTokens.isEmpty else { return false }
        let titleTokens = Set(normalizedTitle.split(separator: " ").map(String.init))
        return authorTokens.allSatisfy { titleTokens.contains($0) }
    }

    /// Words marking a distinct derivative work rather than another edition:
    /// "Sapiens: A Graphic History" is not an edition of "Sapiens".
    private static let derivativeMarkers: [String] = [
        "graphic", "workbook", "journal", "coloring", "screenplay", "cookbook", "companion"
    ]

    private static func containsDerivativeMarker(_ normalized: String) -> Bool {
        derivativeMarkers.contains { normalized.contains($0) }
    }

    /// Franchise companion/merch/litcrit signals, matched on word boundaries
    /// against normalized text ("art of" must not hit "heart of darkness").
    /// Soft ranking penalty only — never a hard filter, since a few real works
    /// legitimately carry these words.
    private static let companionMarkerPatterns: [String] = [
        #"\bcostumes?\b"#, #"\bstoryboards?\b"#, #"\bconcept art\b"#,
        #"\bart of\b"#, #"\bmaking of\b"#, #"\bbehind the scenes\b"#,
        #"\band philosophy\b"#, #"\ba to z\b"#, #"\ba z\b"#, #"\bhandbook\b"#,
        #"\bofficial guide\b"#, #"\bviewers? guide\b"#, #"\bepisode guide\b"#,
        #"\btribute guide\b"#, #"\bmovie companion\b"#, #"\bfilm companion\b"#,
        #"\ba guide to\b"#, #"\b(complete|essential|ultimate|insiders?|unauthorized) guide\b"#,
        #"\btrivia\b"#, #"\bquotes? from\b"#, #"\bwit and wisdom\b"#,
        // Blank-book merch ("Hunger Games NOTEBOOK"). Soft on purpose: real
        // novels exist named "The Notebook" — exact-title queries still win.
        #"\bnotebook\b"#, #"\bnotepad\b"#, #"\bplanner\b"#, #"\bsketchbook\b"#
    ]

    private static func containsCompanionMarker(_ normalized: String) -> Bool {
        companionMarkerPatterns.contains {
            normalized.range(of: $0, options: .regularExpression) != nil
        }
    }

    /// Publisher names credited as the author are a strong knockoff signal
    /// ("University Press", "Summareads Media"). Matches whole words only, so
    /// real authors with e.g. surname "Pressfield" are unaffected.
    private static let publisherAuthorTerms: Set<String> = [
        "press", "publishing", "publishers", "publication", "publications",
        "media", "summaries", "library", "editions", "print", "books",
        // Franchise-knockoff "authors" ("Book Of Thrones", "History of Thrones",
        // "HBO") — brand words, not names anyone is actually called.
        "book", "history", "hbo", "netflix", "official", "unofficial"
    ]

    private static func authorLooksLikePublisher(_ author: String) -> Bool {
        author.split(separator: ",").contains { segment in
            normalize(String(segment)).split(separator: " ")
                .contains { publisherAuthorTerms.contains(String($0)) }
        }
    }

    // MARK: - Popularity key

    /// Cross-edition identity for the community-popularity signal: normalized
    /// main title (parentheticals stripped, subtitle dropped, leading article
    /// removed) + "|" + primary author's surname. Coarser than `workKey` on
    /// purpose — it must be reproduced exactly by the Cloud Functions trigger
    /// that maintains `bookStats` (see functions/src/index.ts `popularityKey`);
    /// keep the two implementations in lockstep. Empty when the title
    /// normalizes to nothing.
    static func popularityKey(title: String, author: String) -> String {
        var raw = title.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
        raw = raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? raw
        let t = stripLeadingArticle(normalize(raw))
        guard !t.isEmpty else { return "" }
        let primary = normalize(String(author.split(separator: ",").first ?? ""))
        let surname = primary.split(separator: " ").last.map(String.init) ?? ""
        return t + "|" + surname
    }

    // MARK: - ISBN language inference

    /// ISO 639-1 language implied by the ISBN's registration group (the digits
    /// after the 978/979 prefix). Catalog records — ISBNdb especially — often
    /// carry no language field, but the registration group still identifies the
    /// publishing market: 978-602 is Indonesia, so 9786021606810 is almost
    /// certainly an Indonesian translation even when the title is left in
    /// English. Groups covering multilingual or heavily-English markets (India,
    /// Philippines, Singapore, international agencies, …) are omitted and infer
    /// nothing. ISBN-10s share the 978 group space.
    static func impliedLanguageCode(fromISBN isbn: String?) -> String? {
        guard let isbn else { return nil }
        let digits = isbn.filter(\.isNumber)
        let group: Substring
        let table: [String: String]
        if digits.count == 13, digits.hasPrefix("978") {
            group = digits.dropFirst(3)
            table = isbn978GroupLanguages
        } else if digits.count == 13, digits.hasPrefix("979") {
            group = digits.dropFirst(3)
            table = isbn979GroupLanguages
        } else if digits.count == 10 {
            group = Substring(digits)
            table = isbn978GroupLanguages
        } else {
            return nil
        }
        // Registration groups have variable length; in the 978 space 1-digit
        // (0–7), 2-digit (80–94), and 3-digit (600s, 950s–980s) ranges don't
        // overlap, so the first table hit is the group.
        for length in 1...3 where group.count >= length {
            if let lang = table[String(group.prefix(length))] { return lang }
        }
        return nil
    }

    private static let isbn978GroupLanguages: [String: String] = [
        "0": "en", "1": "en",
        "2": "fr", "3": "de", "4": "ja", "5": "ru", "7": "zh",
        "80": "cs", "82": "no", "83": "pl", "84": "es", "85": "pt", "87": "da",
        "88": "it", "89": "ko", "90": "nl", "91": "sv", "94": "nl",
        "600": "fa", "602": "id", "603": "ar", "604": "vi", "605": "tr",
        "606": "ro", "607": "es", "608": "mk", "609": "lt", "611": "th",
        "612": "es", "614": "ar", "615": "hu", "616": "th", "617": "uk",
        "618": "el", "619": "bg", "622": "fa", "623": "id", "625": "tr",
        "626": "zh", "628": "es",
        "950": "es", "951": "fi", "952": "fi", "953": "hr", "954": "bg",
        "956": "es", "957": "zh", "958": "es", "959": "es", "960": "el",
        "961": "sl", "963": "hu", "964": "fa", "965": "he", "966": "uk",
        "968": "es", "970": "es", "972": "pt", "973": "ro", "974": "th",
        "975": "tr", "977": "ar", "980": "es", "986": "zh", "987": "es",
        "989": "pt"
    ]

    private static let isbn979GroupLanguages: [String: String] = [
        "8": "en", "10": "fr", "11": "ko", "12": "it"
    ]

    // MARK: - Text utilities

    /// Drops one leading English article from already-normalized text.
    static func stripLeadingArticle(_ normalized: String) -> String {
        for article in ["the ", "a ", "an "] where normalized.hasPrefix(article) {
            return String(normalized.dropFirst(article.count))
        }
        return normalized
    }

    /// Lowercased, diacritics folded, apostrophes removed, all other
    /// punctuation collapsed to single spaces.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        let mapped = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    /// Edit distance with early exit once every path exceeds `limit`.
    private static func levenshtein(_ a: String, _ b: String, limit: Int) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if abs(aChars.count - bChars.count) > limit { return limit + 1 }
        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = Swift.min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }
}
