//
//  TagCatalogPicker.swift
//  Spine
//
//  Sectioned Tags.csv chip grid (onboarding order). Shared by onboarding step 2,
//  Edit profile, and the Discover criteria editor.
//

import SwiftUI

struct TagCatalogPicker: View {
    @Binding var selected: Set<String>
    /// When true and exactly one Format is picked (Fiction XOR Non-Fiction), tags that
    /// can't apply to that format are hidden — e.g. Dystopian disappears once the user
    /// picks Non-Fiction only. Off by default so onboarding/profile show the full catalog.
    var filterByFormat: Bool = false
    /// When true, a hairline rule is drawn above each category after the first,
    /// visually separating the groups (used by the Discover criteria editor).
    var separated: Bool = false

    /// Categories/tags that only make sense for fiction.
    private static let fictionOnlyCategories: Set<String> = ["Subgenre", "Story Type", "Setting / World", "Character / Dynamics"]
    private static let fictionOnlyTags: Set<String> = ["Mystery & Thriller", "Sci-Fi & Fantasy", "Romance"]
    /// Categories/tags that only make sense for non-fiction.
    private static let nonFictionOnlyCategories: Set<String> = ["Nonfiction Topics"]
    private static let nonFictionOnlyTags: Set<String> = ["Biography & Memoir", "Self-Improvement", "Business", "Psychology", "Science"]

    private var visibleSections: [(category: String, tags: [String])] {
        let all = SpineTagCatalog.shared.onboardingSectionsOrdered()
        let fiction = selected.contains(SpineTagCatalog.fictionTag)
        let nonFiction = selected.contains(SpineTagCatalog.nonFictionTag)
        guard filterByFormat, fiction != nonFiction else { return all }
        let hiddenCategories = nonFiction ? Self.fictionOnlyCategories : Self.nonFictionOnlyCategories
        let hiddenTags = nonFiction ? Self.fictionOnlyTags : Self.nonFictionOnlyTags
        return all.compactMap { section in
            if hiddenCategories.contains(section.category) { return nil }
            let tags = section.tags.filter { !hiddenTags.contains($0) }
            return tags.isEmpty ? nil : (section.category, tags)
        }
    }

    var body: some View {
        let sections = visibleSections
        ForEach(Array(sections.enumerated()), id: \.element.category) { index, section in
            VStack(alignment: .leading, spacing: 10) {
                if separated && index > 0 {
                    Rectangle()
                        .fill(Theme.textTertiary.opacity(0.25))
                        .frame(height: 1)
                        .padding(.bottom, 6)
                }
                Text(section.category.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .tracking(0.6)
                FlowLayout(spacing: 10) {
                    ForEach(section.tags, id: \.self) { tag in
                        chip(tag)
                    }
                }
            }
        }
    }

    private func chip(_ tag: String) -> some View {
        Button {
            if selected.contains(tag) {
                selected.remove(tag)
            } else {
                selected.insert(tag)
            }
            // Toggling Format can hide whole sections — drop any now-hidden picks
            // so they don't silently ride along into the saved criteria.
            if filterByFormat {
                let visible = Set(visibleSections.flatMap(\.tags))
                let pruned = selected.filter { visible.contains($0) }
                if pruned.count != selected.count { selected = pruned }
            }
        } label: {
            let isSelected = selected.contains(tag)
            Text(tag)
                .font(Theme.callout())
                .foregroundStyle(isSelected ? Theme.accent : Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(isSelected ? Theme.accent : Color.white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
    }
}
