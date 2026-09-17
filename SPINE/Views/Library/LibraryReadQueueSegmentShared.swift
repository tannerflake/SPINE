//
//  LibraryReadQueueSegmentShared.swift
//  SPINE
//
//  Read / Queue tab type, spring constants, and read-only segment UI shared between
//  your library (`ProfileLibraryView`) and a friend’s (`UserLibraryDetailView`).
//

import SwiftUI

// MARK: - Reading goal strip (calendar year vs goal)

enum LibraryReadingGoalStripCopy {
    /// Signed-in viewer’s own library.
    case own
    /// Another member’s library (`displayFirstName` used for “Name’s goal”, else “their”).
    case other(displayFirstName: String?)
}

/// Goal progress bar + compact caption under the nav title, above the Read/Queue control.
struct LibraryReadingGoalProgressStrip: View {
    let calendarYear: Int
    let booksRead: Int
    /// Nil when the member never set a goal: the strip still renders (an empty
    /// track plus the year's count) rather than vanishing from their profile.
    let goal: Int?
    var copy: LibraryReadingGoalStripCopy = .own

    private var goalTotal: Double {
        max(Double(goal ?? 0), 1)
    }

    /// Pace vs. a straight-line schedule through the calendar year.
    private enum GoalPace {
        case goalMet
        case ahead(Int)
        case onTrack
        case behind(Int)
    }

    /// On track means within one full book of the straight-line pace; ahead/behind
    /// only count whole books so the label never overstates a fractional gap.
    private var pace: GoalPace {
        guard let goal else { return .onTrack }
        if booksRead >= goal { return .goalMet }
        let cal = Calendar.current
        let now = Date()
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: now) ?? 1
        let daysInYear = cal.range(of: .day, in: .year, for: now)?.count ?? 365
        let expected = Double(goal) * Double(dayOfYear) / Double(daysInYear)
        let diff = Double(booksRead) - expected
        if diff >= 1 { return .ahead(Int(diff)) }
        if diff <= -1 { return .behind(Int(-diff)) }
        return .onTrack
    }

    private var paceText: String {
        switch pace {
        case .goalMet:
            return "goal met!"
        case .ahead(let n):
            return "\(n) book\(n == 1 ? "" : "s") ahead"
        case .onTrack:
            return "on track"
        case .behind(let n):
            return "\(n) book\(n == 1 ? "" : "s") behind"
        }
    }

    /// Pace commentary (and its color) is only for your own goal — on someone
    /// else's library we just report progress, never how far behind they are.
    private var showsPace: Bool {
        guard goal != nil else { return false }
        if case .own = copy { return true }
        return false
    }

    private var barFill: Color {
        guard showsPace else { return Theme.accent }
        switch pace {
        case .goalMet, .ahead: return Theme.accent
        case .onTrack: return Theme.textSecondary
        case .behind: return Theme.danger
        }
    }

    /// The parenthetical only celebrates: goal met or ahead. Behind/on-track
    /// stay silent (the bar color still tells the story).
    private var showsPaceText: Bool {
        guard showsPace else { return false }
        switch pace {
        case .goalMet, .ahead: return true
        case .onTrack, .behind: return false
        }
    }

    private var caption: String {
        guard let goal else { return "Read \(booksRead) in \(calendarYear), no goal set" }
        return showsPaceText
            ? "Read \(booksRead)/\(goal) for \(calendarYear) (\(paceText))"
            : "Read \(booksRead)/\(goal) for \(calendarYear)"
    }

    private var accessibilityValueText: String {
        guard let goal else { return "\(booksRead) books read, no goal set." }
        return showsPaceText ? "\(booksRead) of \(goal) books. \(paceText)" : "\(booksRead) of \(goal) books."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                // No goal: empty track, so the row keeps its shape without
                // implying progress toward a number they never picked.
                let fraction = goal == nil ? 0 : min(Double(booksRead), goalTotal) / goalTotal
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.textSecondary.opacity(0.18))
                    if fraction > 0 {
                        Capsule()
                            .fill(barFill)
                            .frame(width: max(geo.size.height, geo.size.width * fraction))
                    }
                }
            }
            .frame(height: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(calendarYear) reading goal")
            .accessibilityValue(accessibilityValueText)
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

/// Read vs Queue — used by your library and friend library screens.
enum LibraryReadQueueTab: String, CaseIterable {
    case read = "Read"
    case wantToRead = "Queue"

    /// Position in the Read / Queue control, for the sliding lens.
    var lensIndex: Int { self == .read ? 0 : 1 }

    init(lensIndex: Int) {
        self = lensIndex == 0 ? .read : .wantToRead
    }
}

extension Binding where Value == LibraryReadQueueTab {
    /// The segment as a lens position, for `slidingLens`.
    var lensIndex: Binding<Int> {
        Binding<Int>(
            get: { wrappedValue.lensIndex },
            set: { wrappedValue = LibraryReadQueueTab(lensIndex: $0) }
        )
    }
}

/// Geometry shared by both Read / Queue controls: the lens is pulled in to the
/// pills' 2pt side padding so it never touches its neighbour.
enum LibrarySegmentLensLayout {
    static let lensInsets = EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 2)
}

/// Springs for Read / Queue control — selection matches the main tab bar's lens spring so
/// every sliding selector in the app moves the same way; drag chrome stays a touch quicker.
enum LibrarySegmentControlAnimation {
    /// Used when the Read/Queue lens slides between segments (tap or release).
    static let selection = SlidingLensMotion.settle
    static let dragChrome = Animation.spring(response: 0.24, dampingFraction: 0.82, blendDuration: 0)
}

/// Sliding indicator for the Read/Queue control — the same liquid-glass lens as the main
/// tab bar on iOS 26+, with the old elevated-pill look as the pre-26 fallback.
struct LibrarySegmentGlassLens: View {
    var cornerRadius: CGFloat = 8

    var body: some View {
        if #available(iOS 26.0, *) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Theme.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Theme.chrome.opacity(0.55), lineWidth: 1.25)
                )
                .shadow(color: Theme.shadowInk.opacity(0.12), radius: 4, y: 1)
        }
    }
}

/// Same pill styling as your library’s Read/Queue control, without drag-and-drop chrome.
/// Tap a segment or press and slide the lens across; see `slidingLens`.
struct LibraryReadQueueSegmentControlReadOnly: View {
    @Binding var segment: LibraryReadQueueTab

    var body: some View {
        HStack(spacing: 0) {
            pill(.read)
            pill(.wantToRead)
        }
        .slidingLens(
            itemCount: LibraryReadQueueTab.allCases.count,
            selectedIndex: $segment.lensIndex,
            lensInsets: LibrarySegmentLensLayout.lensInsets,
            onTap: { segment = LibraryReadQueueTab(lensIndex: $0) }
        ) {
            LibrarySegmentGlassLens()
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .animation(LibrarySegmentControlAnimation.selection, value: segment)
        .sensoryFeedback(.selection, trigger: segment)
    }

    /// Not a `Button`: the row's single gesture handles taps and slides.
    private func pill(_ tab: LibraryReadQueueTab) -> some View {
        let isSelected = segment == tab
        return Text(tab.rawValue)
            .font(Theme.callout().weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { segment = tab }
    }
}
