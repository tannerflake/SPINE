//
//  ShareHubSheet.swift
//  WellRead
//
//  The share sheet, modeled on Strava's activity share: swipe through the
//  story graphics SPINE can make (tier list peek, library card, a period of
//  reading floating or as a tier list), tune the one you land on, then post
//  it to an Instagram story or save it to Photos. Deliberately just those two
//  destinations. Copy rule: no em-dashes in user-facing text.
//

import SwiftUI
import PhotosUI
import UIKit

/// The graphics in the carousel, in swipe order.
enum SharePage: String, Hashable, CaseIterable, Identifiable {
    case tiers
    case card
    case monthFloating
    case monthTiers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiers: return "Tier list peek"
        case .card: return "Library card"
        case .monthFloating: return "Floating shelf"
        case .monthTiers: return "Tier list"
        }
    }

    var usesPeriod: Bool { self == .monthFloating || self == .monthTiers }
}

struct ShareHubSheet: View {
    /// Card details when the caller already has them (the card page, the
    /// wizard finale). When nil, the card is built from `user`.
    var details: LibraryCardDetails?
    var user: User?
    let userBooks: [UserBook]
    var initialPage: SharePage = .tiers

    init(details: LibraryCardDetails? = nil, user: User? = nil, userBooks: [UserBook], initialPage: SharePage = .tiers) {
        self.details = details
        self.user = user
        self.userBooks = userBooks
        self.initialPage = initialPage
        // The carousel must open on the right page in its very first layout:
        // a programmatic scrollPosition applied after the fact (or after the
        // page list changes underneath it) is unreliable and leaves the dots
        // disagreeing with what's on screen.
        let list = Self.pages(for: userBooks)
        _page = State(initialValue: list.contains(initialPage) ? initialPage : list.first)
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var coverResolver = ShareCoverResolver()
    private let userRepo = UserRepository()

    @State private var page: SharePage?
    @State private var loadedDetails: LibraryCardDetails?
    /// Photo behind each graphic, chosen per page.
    @State private var photos: [SharePage: UIImage] = [:]
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var period: SharePeriod?
    /// Books the reader took out of the month graphics, by `Book.id`.
    @State private var hiddenBookIds: Set<String> = []
    @State private var floatingCoverWidth: CGFloat = 104
    @State private var floatingShowsTiers = true
    @State private var showBookPicker = false
    @State private var isExporting = false
    @State private var resultLine: (text: String, isError: Bool)?
    @State private var instagramAvailable = false

    // MARK: - Derived

    private var cardDetails: LibraryCardDetails? { details ?? loadedDetails }
    private var handle: String { cardDetails?.handle ?? user?.username ?? "" }

    private var peekRows: [TierPeekStoryCanvas.Row] { TierPeekStoryCanvas.rows(from: userBooks) }
    private var periods: [SharePeriod] { SharePeriod.available(in: userBooks) }

    /// Books in the selected period that the reader hasn't hidden.
    private var periodBooks: [UserBook] {
        guard let period else { return [] }
        return period.books(in: userBooks)
    }
    private var visiblePeriodBooks: [UserBook] {
        periodBooks.filter { !hiddenBookIds.contains($0.bookId) }
    }

    /// Only pages with something to print. Fixed for the life of the sheet:
    /// the card pages show a loading canvas until their details arrive rather
    /// than appearing later and shifting the carousel.
    private static func pages(for userBooks: [UserBook]) -> [SharePage] {
        var list: [SharePage] = [.card]
        if !TierPeekStoryCanvas.rows(from: userBooks).isEmpty { list.insert(.tiers, at: 0) }
        if !SharePeriod.available(in: userBooks).isEmpty {
            list.append(.monthFloating)
            list.append(.monthTiers)
        }
        return list
    }
    private var pages: [SharePage] { Self.pages(for: userBooks) }

    /// The card pages can't export until the card details are in.
    private var currentPageIsReady: Bool {
        guard let p = currentPage else { return false }
        return (p != .tiers && p != .card) || cardDetails != nil
    }

    private var currentPage: SharePage? { page ?? pages.first }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 12) {
                    pager
                    pageDots
                    controls
                    if let resultLine {
                        Text(resultLine.text)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(resultLine.isError ? Theme.danger : Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 24)
                            .transition(.opacity)
                    }
                    actions
                }
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDragIndicator(.visible)
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem, matching: .images)
        .sheet(isPresented: $showBookPicker) {
            SharePeriodBookPicker(books: periodBooks, hiddenBookIds: $hiddenBookIds)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .animation(.easeInOut(duration: 0.2), value: resultLine?.text)
        .onAppear(perform: start)
        .onChange(of: pickerItem) { _, item in
            guard let item, let target = currentPage else { return }
            Task {
                let image = await PhotosPickerImageLoader.load(item)
                await MainActor.run {
                    if let image {
                        withAnimation(.easeInOut(duration: 0.2)) { photos[target] = image }
                    }
                    // Re-arm the picker so choosing the same photo again works.
                    pickerItem = nil
                }
            }
        }
        .onChange(of: period) { _, _ in
            hiddenBookIds = []
            coverResolver.resolve(periodBooks.compactMap(\.book))
        }
        .onChange(of: page) { _, _ in
            resultLine = nil
        }
        .onChange(of: pages) { _, list in
            // Only reachable if the library changes while the sheet is up.
            if let current = page, !list.contains(current) { page = list.first }
        }
    }

    // MARK: - Pager

    /// Strava's carousel: the current graphic centered with its neighbors
    /// peeking in from the sides, paging one at a time.
    private var pager: some View {
        GeometryReader { geo in
            let itemWidth = min(geo.size.width * 0.68, geo.size.height * 9 / 16)
            let itemHeight = itemWidth * 16 / 9
            let sideInset = (geo.size.width - itemWidth) / 2
            // A plain HStack, not lazy: four pages at most, and a programmatic
            // scrollPosition to a page a LazyHStack hasn't laid out yet is
            // silently dropped (the dots moved, the carousel didn't).
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(pages) { p in
                            canvasPreview(p, width: itemWidth, height: itemHeight)
                                .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                    content
                                        .scaleEffect(phase.isIdentity ? 1 : 0.93)
                                        .opacity(phase.isIdentity ? 1 : 0.7)
                                }
                                .id(p)
                        }
                    }
                    .scrollTargetLayout()
                    .frame(height: geo.size.height)
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $page, anchor: .center)
                .scrollIndicators(.hidden)
                .safeAreaPadding(.horizontal, sideInset)
                .frame(width: geo.size.width, height: geo.size.height)
                .onAppear {
                    // The scrollPosition binding's initial value is not honored
                    // while the sheet is still sizing itself; an explicit scroll
                    // one tick later lands on the requested page every time.
                    guard let target = page, target != pages.first else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The exact canvas that exports, scaled to the carousel. Sizing goes
    /// through scaleEffect rather than a smaller layout so text wrapping and
    /// minimum scale factors resolve identically to the saved image. Tapping
    /// the graphic picks the photo behind it.
    private func canvasPreview(_ p: SharePage, width: CGFloat, height: CGFloat) -> some View {
        let scale = width / StoryExporter.canvasSize.width
        return canvas(for: p)
            .scaleEffect(scale)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 26))
            .overlay(
                RoundedRectangle(cornerRadius: 26)
                    .strokeBorder(Theme.textPrimary.opacity(0.14), lineWidth: 2)
            )
            .shadow(color: Theme.shadowInk.opacity(0.14), radius: 14, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 26))
            .onTapGesture {
                if page == p {
                    showPhotoPicker = true
                } else {
                    withAnimation(.snappy(duration: 0.3, extraBounce: 0.12)) { page = p }
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(p.title). \(photos[p] == nil ? "Tap to choose a background photo" : "Tap to change the background photo")")
    }

    @ViewBuilder
    private func canvas(for p: SharePage) -> some View {
        switch p {
        case .tiers:
            if let cardDetails {
                TierPeekStoryCanvas(rows: peekRows, covers: coverResolver.images, details: cardDetails, background: photos[p])
            } else {
                StoryLoadingCanvas()
            }
        case .card:
            if let cardDetails {
                LibraryCardStoryCanvas(details: cardDetails, background: photos[p])
            } else {
                StoryLoadingCanvas()
            }
        case .monthFloating:
            if let period {
                MonthFloatingStoryCanvas(
                    period: period,
                    books: visiblePeriodBooks,
                    covers: coverResolver.images,
                    coverWidth: floatingCoverWidth,
                    showsTiers: floatingShowsTiers,
                    handle: handle,
                    background: photos[p]
                )
            }
        case .monthTiers:
            if let period {
                MonthTierStoryCanvas(
                    period: period,
                    books: visiblePeriodBooks,
                    covers: coverResolver.images,
                    handle: handle,
                    background: photos[p]
                )
            }
        }
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(pages) { p in
                Circle()
                    .fill(Theme.textPrimary.opacity(currentPage == p ? 0.9 : 0.22))
                    .frame(width: 7, height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: currentPage)
        .accessibilityHidden(true)
    }

    // MARK: - Controls

    /// What the current graphic lets you change. One row of chips, plus the
    /// cover-size slider for the floating shelf.
    @ViewBuilder
    private var controls: some View {
        if let p = currentPage {
            VStack(spacing: 10) {
                Text(p.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        photoChip(for: p)
                        if p.usesPeriod {
                            periodChip
                            booksChip
                        }
                        if p == .monthFloating {
                            toggleChip(title: "Tiers", systemImage: "square.stack", isOn: $floatingShowsTiers)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .scrollIndicators(.hidden)
                if p == .monthFloating {
                    coverSizeSlider
                }
            }
        }
    }

    @ViewBuilder
    private func photoChip(for p: SharePage) -> some View {
        if photos[p] == nil {
            chip(title: "Add photo", systemImage: "photo") { showPhotoPicker = true }
        } else {
            chip(title: "Change photo", systemImage: "photo") { showPhotoPicker = true }
            chip(title: "Remove", systemImage: "xmark") {
                withAnimation(.easeInOut(duration: 0.2)) { photos[p] = nil }
            }
        }
    }

    private var periodChip: some View {
        Menu {
            ForEach(periods) { candidate in
                Button {
                    period = candidate
                } label: {
                    if candidate == period {
                        Label(candidate.chipTitle, systemImage: "checkmark")
                    } else {
                        Text(candidate.chipTitle)
                    }
                }
            }
        } label: {
            chipLabel(title: period?.chipTitle ?? "Month", systemImage: "calendar", trailingChevron: true)
        }
        .buttonStyle(.springPress)
    }

    private var booksChip: some View {
        let total = periodBooks.count
        let shown = visiblePeriodBooks.count
        return chip(
            title: shown == total ? "Books (\(total))" : "Books (\(shown) of \(total))",
            systemImage: "books.vertical"
        ) {
            showBookPicker = true
        }
    }

    private var coverSizeSlider: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.system(size: 11, weight: .semibold))
            Slider(
                value: $floatingCoverWidth,
                in: MonthFloatingStoryCanvas.minCoverWidth...MonthFloatingStoryCanvas.maxCoverWidth
            )
            .tint(Theme.chrome)
            Image(systemName: "book.closed")
                .font(.system(size: 18, weight: .semibold))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cover size")
    }

    private func chip(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chipLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.springPress)
    }

    private func toggleChip(title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isOn.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(isOn.wrappedValue ? Theme.onChrome : Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(isOn.wrappedValue ? Theme.chrome : Theme.surface))
            .overlay(Capsule().strokeBorder(Theme.textTertiary.opacity(isOn.wrappedValue ? 0 : 0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.springPress)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func chipLabel(title: String, systemImage: String, trailingChevron: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if trailingChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.textTertiary.opacity(0.35), lineWidth: 1))
        .contentShape(Capsule())
    }

    // MARK: - Actions

    /// Just two ways out: Instagram story, or Photos. Where Instagram isn't
    /// installed, saving is the one primary action.
    private var actions: some View {
        VStack(spacing: 10) {
            if instagramAvailable {
                InstagramStoryShareButton {
                    shareToInstagram()
                }
                WizardSecondaryButton(title: isExporting ? "Saving…" : "Save to Photos") {
                    save()
                }
            } else {
                WizardCTAButton(title: "Save to Photos", showsProgress: isExporting) {
                    save()
                }
            }
        }
        .padding(.horizontal, 24)
        .disabled(!currentPageIsReady)
        .opacity(currentPageIsReady ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.2), value: currentPageIsReady)
    }

    private func start() {
        instagramAvailable = StoryExporter.canShareToInstagramStories
        if period == nil { period = SharePeriod.defaultPeriod(in: userBooks) }
        let peekBooks = peekRows.flatMap { $0.books.compactMap(\.book) }
        coverResolver.resolve(peekBooks + periodBooks.compactMap(\.book))
        if cardDetails == nil, let user {
            Task { await loadDetails(for: user) }
        }
    }

    private func loadDetails(for user: User) async {
        let photo = await LibraryCardExporter.loadPhoto(urlString: user.profileImageURL)
        let number = await userRepo.memberNumber(joinedAt: user.joinedAt)
        await MainActor.run {
            loadedDetails = LibraryCardDetails.from(user: user, cardNumber: max(1, number ?? 1), photo: photo)
        }
    }

    /// Renders the current page after giving in-flight covers a moment to land.
    @MainActor
    private func exportCurrentImage() async -> UIImage? {
        guard let p = currentPage else { return nil }
        await coverResolver.waitUntilSettled(timeout: 5)
        return StoryExporter.render(canvas(for: p))
    }

    private func shareToInstagram() {
        guard !isExporting, let p = currentPage else { return }
        resultLine = nil
        isExporting = true
        Task {
            let image = await exportCurrentImage()
            await MainActor.run {
                isExporting = false
                let ok = image.map { StoryExporter.shareToInstagramStories($0, hasPhoto: photos[p] != nil) } ?? false
                if ok {
                    WizardHaptics.success()
                } else {
                    resultLine = ("Could not open Instagram. Try again.", true)
                }
            }
        }
    }

    private func save() {
        guard !isExporting else { return }
        resultLine = nil
        isExporting = true
        Task {
            guard let image = await exportCurrentImage() else {
                await MainActor.run {
                    isExporting = false
                    resultLine = ("Could not make the image. Try again.", true)
                }
                return
            }
            let outcome = await StoryExporter.saveToPhotos(image)
            await MainActor.run {
                isExporting = false
                switch outcome {
                case .saved:
                    WizardHaptics.success()
                    resultLine = ("Saved to your Photos. Ready for your story.", false)
                case .permissionDenied:
                    resultLine = ("SPINE needs photo access to save. Turn it on in Settings.", true)
                case .failed:
                    resultLine = ("Could not save the image. Try again.", true)
                }
            }
        }
    }
}

// MARK: - Loading canvas

/// Paper with a spinner, shown on the card pages while the card details load.
private struct StoryLoadingCanvas: View {
    var body: some View {
        ZStack {
            Theme.paperFixed
            ProgressView()
                .tint(Theme.inkFixed.opacity(0.5))
                .scaleEffect(1.6)
        }
        .frame(width: StoryExporter.canvasSize.width, height: StoryExporter.canvasSize.height)
    }
}

// MARK: - Book picker

/// Show or hide books in the month graphics. Everything starts shown.
private struct SharePeriodBookPicker: View {
    let books: [UserBook]
    @Binding var hiddenBookIds: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(books) { ub in
                            if let book = ub.book {
                                row(ub: ub, book: book)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("Books")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    private func row(ub: UserBook, book: Book) -> some View {
        let shown = !hiddenBookIds.contains(ub.bookId)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if shown { hiddenBookIds.insert(ub.bookId) } else { hiddenBookIds.remove(ub.bookId) }
            }
        } label: {
            HStack(spacing: 12) {
                BookCoverView(book: book, size: 30)
                    .opacity(shown ? 1 : 0.45)
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(book.author)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let tier = ub.normalizedTier {
                    TierBadge(tier: tier, size: .mini)
                }
                Image(systemName: shown ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(shown ? Theme.accent : Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(shown ? .isSelected : [])
    }
}

// MARK: - Instagram share button

/// The Instagram story CTA: official brand gradient, the app glyph, white
/// text, dressed with the same gloss treatment as the app's hero buttons.
/// Deliberately off-palette for SPINE: it borrows Instagram's brand so the
/// destination is unmistakable, matching the share convention users know.
struct InstagramStoryShareButton: View {
    let action: () -> Void

    /// Instagram's brand gradient, diagonal like their app icon.
    private static let gradient = LinearGradient(
        colors: [
            Color(red: 64/255, green: 93/255, blue: 230/255),
            Color(red: 131/255, green: 58/255, blue: 180/255),
            Color(red: 225/255, green: 48/255, blue: 108/255),
            Color(red: 253/255, green: 89/255, blue: 73/255),
            Color(red: 247/255, green: 119/255, blue: 55/255)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image("InstagramLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .shadow(color: Color.black.opacity(0.3), radius: 3, y: 1)
                Text("Share to Instagram Story")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .background(Self.gradient, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Theme.shadowInk.opacity(0.30), radius: 9, x: 0, y: 4)
        .buttonStyle(.springPress)
    }
}

// MARK: - Photo loading

enum PhotosPickerImageLoader {
    static func load(_ item: PhotosPickerItem) async -> UIImage? {
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            return image
        }
        guard let url = try? await item.loadTransferable(type: URL.self) else { return nil }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            return image
        }
        if FileManager.default.fileExists(atPath: url.path) {
            return UIImage(contentsOfFile: url.path)
        }
        return nil
    }
}
