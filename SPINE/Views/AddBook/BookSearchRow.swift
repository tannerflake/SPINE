//
//  BookSearchRow.swift
//  SPINE
//

import SwiftUI

struct BookSearchRow: View {
    let book: Book
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                BookCoverView(book: book, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(Theme.headline())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text(book.author)
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .spineCard()
        }
        .buttonStyle(.plain)
    }
}
