//
//  DiscoverBookPickerView.swift
//  Spine
//
//  Tier-list book picker for Discover criteria: the user's read books rendered
//  read-only with tap-to-select, used to choose recommendation seed books.
//

import SwiftUI

struct DiscoverBookPickerView: View {
    /// Max seed books so the recommendation prompt stays focused.
    static let maxSeeds = 12

    let readBooks: [UserBook]
    @Binding var selectedSeeds: [DiscoverSeedBook]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tap books to use them as seeds for your next suggestions.")
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.top, 10)
                .padding(.bottom, 4)

            TierListView(
                userBooks: readBooks,
                onUpdateTierAndOrder: { _, _, _ in },  // inert in readOnly
                onBookTap: { book in toggle(book) },
                readOnly: true,
                selectedBookIds: Set(selectedSeeds.map(\.bookId))
            )
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Pick books")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ book: Book) {
        if let i = selectedSeeds.firstIndex(where: { $0.bookId == book.id }) {
            selectedSeeds.remove(at: i)
        } else if selectedSeeds.count >= Self.maxSeeds {
            ToastCenter.shared.show(Toast(style: .info, status: "LIMIT", message: "Up to \(Self.maxSeeds) seed books"))
        } else {
            selectedSeeds.append(DiscoverSeedBook(bookId: book.id, title: book.title, author: book.author))
        }
    }
}
