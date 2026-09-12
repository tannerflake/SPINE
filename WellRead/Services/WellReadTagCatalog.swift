//
//  WellReadTagCatalog.swift
//  WellRead
//
//  Loads Tags.csv from the app bundle (Category,Tag). Whitelist for AI-assigned book profile tags.
//

import Foundation

final class WellReadTagCatalog {
    static let shared = WellReadTagCatalog()

    /// Must match `Tags.csv` Format rows exactly.
    static let fictionTag = "Fiction"
    static let nonFictionTag = "Non-Fiction"

    /// Exact strings from the CSV "Tag" column (file order).
    let allTags: [String]

    /// Category header → tags (for prompts).
    private(set) var tagsByCategory: [String: [String]] = [:]

    /// Normalized lookup key → exact catalog string
    private let canonicalByKey: [String: String]

    private init() {
        let parsed = Self.loadParsed()
        self.allTags = parsed.tags
        self.tagsByCategory = parsed.byCategory
        var map: [String: String] = [:]
        for t in parsed.tags {
            map[Self.normalizeKey(t)] = t
        }
        map[Self.normalizeKey("Non-fiction")] = Self.nonFictionTag
        map[Self.normalizeKey("non-fiction")] = Self.nonFictionTag
        // 2026-08 rename: existing book profiles / user tags may still carry
        // the old name; keep them resolving to the current catalog tag.
        if let political = map[Self.normalizeKey("Political")] {
            map[Self.normalizeKey("Political Intrigue")] = political
        }
        self.canonicalByKey = map
    }

    private static func normalizeKey(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadParsed() -> (tags: [String], byCategory: [String: [String]]) {
        if let url = Bundle.main.url(forResource: "Tags", withExtension: "csv"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return parse(csv: text)
        }
        assertionFailure("Tags.csv missing from app bundle. Add Tags.csv to the WellRead target.")
        return (tags: [Self.fictionTag, Self.nonFictionTag], byCategory: ["Format": [Self.fictionTag, Self.nonFictionTag]])
    }

    /// Parses CSV lines `Category,Tag` (single comma split). Skips header row.
    static func parse(csv text: String) -> (tags: [String], byCategory: [String: [String]]) {
        var tags: [String] = []
        var byCategory: [String: [String]] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let comma = trimmed.firstIndex(of: ",") else { continue }
            let category = String(trimmed[..<comma]).trimmingCharacters(in: .whitespaces)
            let tag = String(trimmed[trimmed.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            if category.lowercased() == "category" { continue }
            guard !tag.isEmpty else { continue }
            tags.append(tag)
            byCategory[category, default: []].append(tag)
        }
        return (tags, byCategory)
    }

    /// Grouped list for LLM prompts (every tag must be copied exactly).
    func allowedTagsPromptBlock() -> String {
        let order = tagsByCategory.keys.sorted()
        var parts: [String] = []
        for cat in order {
            guard let list = tagsByCategory[cat], !list.isEmpty else { continue }
            parts.append("\(cat): \(list.joined(separator: ", "))")
        }
        if parts.isEmpty { return allTags.joined(separator: ", ") }
        return parts.joined(separator: "\n")
    }

    /// Maps model output to a catalog tag, or nil if it cannot be matched.
    func canonicalTag(matching raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let c = canonicalByKey[Self.normalizeKey(t)] { return c }
        if let exact = allTags.first(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
            return exact
        }
        let nf = t.lowercased().replacingOccurrences(of: "-", with: "")
        if nf == "nonfiction" { return Self.nonFictionTag }
        if t.lowercased() == "fiction" { return Self.fictionTag }
        return nil
    }

    /// Keep only recognized tags, in order, deduped case-insensitively.
    func whitelist(_ tags: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in tags {
            guard let c = canonicalTag(matching: raw) else { continue }
            let key = c.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(c)
        }
        return out
    }

    /// Category order for onboarding chips: broad (Format, Genre, …) first, then any extra CSV categories.
    static let onboardingCategoryPriority: [String] = [
        "Format",
        "Genre",
        "Subgenre",
        "Reading Experience",
        "Pacing / Style",
        "Nonfiction Topics",
        "Story Type",
        "Tone / Vibe",
        "Setting / World",
        "Character / Dynamics",
        "Themes",
    ]

    /// Sections for multi-select onboarding (same tags as book profiles, grouped for scanning).
    func onboardingSectionsOrdered() -> [(category: String, tags: [String])] {
        var seenCategories = Set<String>()
        var sections: [(category: String, tags: [String])] = []
        for cat in Self.onboardingCategoryPriority {
            guard let list = tagsByCategory[cat], !list.isEmpty else { continue }
            sections.append((cat, list))
            seenCategories.insert(cat)
        }
        let remaining = tagsByCategory.keys.filter { !seenCategories.contains($0) }.sorted()
        for cat in remaining {
            guard let list = tagsByCategory[cat], !list.isEmpty else { continue }
            sections.append((cat, list))
        }
        return sections
    }
}
