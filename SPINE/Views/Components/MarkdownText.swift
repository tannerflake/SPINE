//
//  MarkdownText.swift
//  SPINE
//
//  Renders LLM prose that may carry light inline markdown. Models habitually
//  italicize book titles even when the prompt forbids markdown, so blurb
//  surfaces parse inline emphasis instead of showing raw asterisks.
//

import SwiftUI

enum MarkdownProse {
    /// Parses inline emphasis (*italic*, **bold**, `code`, [links]) and leaves
    /// everything else — including block syntax like headings and bullets —
    /// as literal text. Returns plain text unchanged if parsing fails.
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

extension Text {
    /// `Text(markdown:)` — inline-emphasis-aware alternative to `Text(someString)`,
    /// which never parses markdown when handed a `String` variable.
    init(markdown text: String) {
        self.init(MarkdownProse.attributed(text))
    }
}
