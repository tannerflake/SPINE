//
//  TimelineLibraryView.swift
//  SPINE
//
//  Vertical scroll by date finished, grouped by month/year.
//

import SwiftUI

struct TimelineLibraryView: View {
    let userBooks: [UserBook]
    
    private var grouped: [(String, [UserBook])] {
        let withDate = userBooks.filter { $0.dateFinished != nil }
            .sorted { ($0.dateFinished ?? .distantPast) > ($1.dateFinished ?? .distantPast) }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        var dict: [String: [UserBook]] = [:]
        for ub in withDate {
            guard let d = ub.dateFinished else { continue }
            let key = ReadDate.isLongAgo(d) ? ReadDate.longAgoLabel : formatter.string(from: d)
            dict[key, default: []].append(ub)
        }
        return dict.sorted { ($0.value.first?.dateFinished ?? .distantPast) > ($1.value.first?.dateFinished ?? .distantPast) }
            .map { ($0.key, $0.value) }
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(grouped, id: \.0) { monthYear, books in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(monthYear)
                            .font(Theme.headline())
                            .foregroundStyle(Theme.textSecondary)
                        ForEach(books) { ub in
                            if let book = ub.book {
                                HStack(spacing: 14) {
                                    BookCoverView(book: book, size: 56)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(book.title).font(Theme.headline()).foregroundStyle(Theme.textPrimary)
                                        if let r = ub.rating {
                                            HStack(spacing: 2) {
                                                Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.accent)
                                                Text("\(Theme.formatRatingOutOfTen(r))/10").font(Theme.caption()).foregroundStyle(Theme.textSecondary)
                                            }
                                        }
                                        if let snippet = ub.reviewText, !snippet.isEmpty {
                                            Text(snippet)
                                                .font(Theme.caption())
                                                .foregroundStyle(Theme.textTertiary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding()
                                .spineCard()
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
}
