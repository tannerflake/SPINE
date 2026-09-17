//
//  GridLibraryView.swift
//  SPINE
//
//  Adaptive grid of book covers (e.g. Read list when not using tier view).
//

import SwiftUI

struct GridLibraryView: View {
    let userBooks: [UserBook]
    /// When set, tapping a book cover opens the book profile.
    var onBookTap: ((Book) -> Void)? = nil

    private let columns = [
        GridItem(.adaptive(minimum: 100), spacing: Theme.gridSpacing)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.gridSpacing) {
                ForEach(userBooks) { ub in
                    if let book = ub.book {
                        VStack(alignment: .leading, spacing: 6) {
                            BookCoverView(book: book, size: 100, onTap: onBookTap != nil ? { onBookTap?(book) } : nil)
                            Text(book.title)
                                .font(Theme.caption())
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(2)
                            if let r = ub.rating {
                                HStack(spacing: 2) {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.accent)
                                    Text(Theme.formatRatingOutOfTen(r)).font(Theme.caption()).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
    }
}
