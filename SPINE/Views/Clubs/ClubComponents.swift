//
//  ClubComponents.swift
//  SPINE
//
//  Small shared pieces for the Clubs surfaces: date copy, avatar stacks,
//  progress bars, member rows, and the primary/secondary button looks.
//

import SwiftUI

enum ClubDates {
    /// "Sat, Oct 4 · 7:00 PM"
    static func meetingLine(_ date: Date) -> String {
        let day = DateFormatter()
        day.dateFormat = "EEE, MMM d"
        let time = DateFormatter()
        time.timeStyle = .short
        return "\(day.string(from: date)) · \(time.string(from: date))"
    }

    /// "Sat, Oct 4"
    static func shortDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }

    /// "MMM yyyy" for the past-reads shelf.
    static func monthYear(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f.string(from: date)
    }

    /// "Today", "Tomorrow", "In 12 days", "3 days ago".
    static func countdown(to date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: start, to: target).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...13: return "In \(days) days"
        case 14...60:
            let weeks = Int((Double(days) / 7).rounded())
            return "In \(weeks) weeks"
        case 61...: 
            let months = max(2, Int((Double(days) / 30).rounded()))
            return "In \(months) months"
        case -13...(-2): return "\(-days) days ago"
        default:
            let weeks = max(2, Int((Double(-days) / 7).rounded()))
            return "\(weeks) weeks ago"
        }
    }
}

/// Overlapping member avatars, capped with a "+N" tail.
struct ClubAvatarStack: View {
    let members: [BookClub.Member]
    var size: CGFloat = 28
    var maxShown: Int = 4

    var body: some View {
        let shown = Array(members.prefix(maxShown))
        let overflow = members.count - shown.count
        HStack(spacing: -size * 0.32) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, m in
                UserAvatarView(urlString: m.photoURL, displayName: m.displayName, firstName: m.firstName, lastName: nil, size: size)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(Theme.onChrome)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Theme.chrome))
                    .overlay(Circle().strokeBorder(Theme.avatarRing, lineWidth: AvatarRing.lineWidth(for: size)))
            }
        }
    }
}

/// Thin ink progress track. Full bar reads as finished.
struct ClubProgressBar: View {
    let fraction: Double
    var height: CGFloat = 6
    var finished: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let f = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.chrome.opacity(0.12))
                Capsule()
                    .fill(Theme.chrome)
                    .frame(width: max(f > 0 ? height : 0, proxy.size.width * f))
            }
        }
        .frame(height: height)
        .accessibilityLabel(finished ? "Finished" : "\(Int((fraction * 100).rounded())) percent")
    }
}

/// One member with where they are on the current book.
struct ClubMemberRow: View {
    let progress: ClubMemberProgress
    var isAdmin: Bool = false
    var isMe: Bool = false
    var hasBook: Bool = true
    let onTap: () -> Void

    private var statusLabel: String {
        switch progress.state {
        case .notStarted: return hasBook ? "Not started" : ""
        case .reading(let f): return "\(Int((min(1, max(0, f)) * 100).rounded()))%"
        case .finished: return "Finished"
        case .didNotFinish: return "Set aside"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                UserAvatarView(
                    urlString: progress.member.photoURL,
                    displayName: progress.member.displayName,
                    firstName: progress.member.firstName,
                    lastName: nil,
                    size: 40
                )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(isMe ? "You" : progress.member.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if isAdmin {
                            Text("ADMIN")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(1)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .overlay(Capsule().strokeBorder(Theme.chrome.opacity(0.25), lineWidth: 1))
                        }
                    }
                    if !progress.member.username.isEmpty {
                        Text("@\(progress.member.username)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if hasBook {
                    VStack(alignment: .trailing, spacing: 5) {
                        HStack(spacing: 4) {
                            if progress.isFinished {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            Text(statusLabel)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(progress.isFinished ? Theme.textPrimary : Theme.textSecondary)
                        ClubProgressBar(fraction: progress.fraction, finished: progress.isFinished)
                            .frame(width: 84)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.springPress)
    }
}

/// Full-width primary CTA used across the club flows (`SpineButtonStyle`).
struct ClubPrimaryButton: View {
    let title: String
    var icon: String? = nil
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(Theme.onChrome)
                } else if let icon {
                    Image(systemName: icon)
                }
                Text(title)
            }
        }
        .buttonStyle(.spinePrimary)
        .disabled(!isEnabled || isLoading)
    }
}

/// Outlined secondary action (`SpineButtonStyle`, regular height).
struct ClubSecondaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    Image(systemName: icon)
                }
                Text(title)
            }
        }
        .buttonStyle(.spine(.secondary, size: .regular))
    }
}

/// Text field styled like the rest of the app's inputs.
struct ClubTextField: View {
    let placeholder: String
    @Binding var text: String
    var autocapitalization: TextInputAutocapitalization = .words
    var submitLabel: SubmitLabel = .done

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.system(size: 17))
            .foregroundStyle(Theme.textPrimary)
            .textInputAutocapitalization(autocapitalization)
            .submitLabel(submitLabel)
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: Theme.cardCornerRadius).fill(Theme.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardCornerRadius).strokeBorder(Theme.chrome.opacity(0.22), lineWidth: 1))
    }
}

/// Section label used above form fields: "WHO PICKS THE BOOKS?"
struct ClubFieldLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(1.8)
            .foregroundStyle(Theme.textSecondary)
    }
}

/// Launch-flag check shared by the club views: `-uiPreviewClubs` renders the
/// demo club with no Firestore.
enum ClubsPreview {
    static var isActive: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-uiPreviewClubs") || startsEmpty || hasMultiple || voteState != nil
        #else
        return false
        #endif
    }

    /// `-uiPreviewClubsMulti`: two clubs, so the list shows instead of the
    /// single-club shortcut straight into the club page.
    static var hasMultiple: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-uiPreviewClubsMulti")
        #else
        return false
        #endif
    }

    /// `-uiPreviewClubsEmpty`: the no-clubs pitch instead of the demo club.
    static var startsEmpty: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-uiPreviewClubsEmpty")
        #else
        return false
        #endif
    }
}
