//
//  NotificationsView.swift
//  WellRead
//
//  Notification feed behind the bell on the Feed and Profile tabs: follows,
//  likes, comments, replies, blend invites/results, friend reviews. Rows
//  deep-link to the same destinations as their push notifications.
//

import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    /// nil while loading; empty when the feed has nothing.
    @State private var notifications: [UserNotification]? = nil
    private let repo = NotificationsRepository()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let items = notifications {
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                            if item.id != items.last?.id {
                                Divider()
                                    .overlay(Theme.textTertiary.opacity(0.2))
                                    .padding(.leading, Theme.horizontalPadding + 48)
                            }
                        }
                    }
                    .padding(.bottom, 100)
                }
                .refreshable { await load() }
            }
        } else {
            ProgressView()
                .tint(Theme.accent)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("No notifications yet")
                .font(Theme.headline())
                .foregroundStyle(Theme.textPrimary)
            Text("Follows, likes, comments, and Book Blends will show up here.")
                .font(Theme.callout())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: UserNotification) -> some View {
        Button {
            open(item)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                leadingArt(item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(Theme.callout().weight(item.read ? .regular : .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    if !item.body.isEmpty {
                        Text(item.body)
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                    Text(Self.compactAge(item.createdAt))
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                if !item.read {
                    Circle()
                        .fill(Theme.danger)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Book cover when the event has one; otherwise a type glyph in a circle.
    @ViewBuilder
    private func leadingArt(_ item: UserNotification) -> some View {
        if let cover = item.coverURL, let url = URL(string: cover) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Theme.surface
                }
            }
            .frame(width: 36, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.textTertiary.opacity(0.25), lineWidth: 0.5)
            )
        } else {
            Circle()
                .fill(Theme.surface)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: Self.glyph(for: item.type))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                )
        }
    }

    private static func glyph(for type: String) -> String {
        switch type {
        case "new_follower": return "person.badge.plus"
        case "contact_joined": return "person.2.fill"
        case "review_liked", "comment_liked": return "heart.fill"
        case "review_commented", "comment_replied", "thread_commented": return "bubble.left.fill"
        case "review_mentioned", "comment_mentioned": return "at"
        case "blend_request", "blend_ready": return "sparkles"
        case "friend_review_posted": return "book.fill"
        case "book_recommended": return "paperplane.fill"
        default: return "bell.fill"
        }
    }

    /// "now", "5m", "2h", "3d", "2w" — feed rows want a glance, not a sentence.
    private static func compactAge(_ date: Date) -> String {
        let s = max(0, Date().timeIntervalSince(date))
        if s < 60 { return "now" }
        let m = Int(s / 60)
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        let d = h / 24
        if d < 7 { return "\(d)d" }
        return "\(d / 7)w"
    }

    /// Rows route exactly like their pushes: the doc carries the same type +
    /// deep-link ids as the push data payload, so the push tap handler does the
    /// rest (tab switch, sheet, blend landing).
    private func open(_ item: UserNotification) {
        var info: [AnyHashable: Any] = ["type": item.type]
        if let postId = item.postId { info["postId"] = postId }
        if let commentId = item.commentId { info["commentId"] = commentId }
        if let blendId = item.blendId { info["blendId"] = blendId }
        if let actorId = item.actorId { info["followerId"] = actorId }
        dismiss()
        PushNotificationService.handleRemoteNotificationTap(userInfo: info)
    }

    private func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiPreviewNotifications") {
            notifications = Self.uiPreviewDemo
            return
        }
        #endif
        guard let uid = authService.firebaseUser?.uid else {
            notifications = []
            return
        }
        let items = await repo.fetchLatest(uid: uid)
        notifications = items
        // Clear the shared bell badge (both tabs) only after the rows are on
        // screen — the fetched snapshot above keeps this visit's unread styling
        // intact. Goes through AppState so whichever bell opened us, and the
        // other one too, stay in sync.
        if items.contains(where: { !$0.read }) {
            appState.markNotificationsRead()
        }
    }

    #if DEBUG
    /// `-uiPreviewNotifications`: demo rows for simulator UI verification.
    private static var uiPreviewDemo: [UserNotification] {
        let now = Date()
        return [
            UserNotification(id: "1", type: "new_follower", title: "👋 Alex followed you", body: "See what they're reading on SPINE.", postId: nil, commentId: nil, blendId: nil, actorId: "demo", coverURL: nil, createdAt: now.addingTimeInterval(-300), read: false),
            UserNotification(id: "1b", type: "contact_joined", title: "🎉 Katie joined SPINE", body: "Katie Nguyen is in your contacts. Tap to follow.", postId: nil, commentId: nil, blendId: nil, actorId: "demo", coverURL: nil, createdAt: now.addingTimeInterval(-900), read: false),
            UserNotification(id: "2", type: "review_liked", title: "❤️ Maya liked your review", body: "Your review of Sapiens.", postId: "demo", commentId: nil, blendId: nil, actorId: "demo", coverURL: "https://covers.openlibrary.org/b/isbn/9780062316097-L.jpg", createdAt: now.addingTimeInterval(-7200), read: false),
            UserNotification(id: "3", type: "blend_request", title: "🔀 Jordan invited you", body: "Book Blend: see how your reading tastes line up. Tap to accept.", postId: nil, commentId: nil, blendId: "demo", actorId: "demo", coverURL: nil, createdAt: now.addingTimeInterval(-86400), read: true),
            UserNotification(id: "4", type: "review_commented", title: "💬 Sam commented", body: "On your review of The Overstory: “Great take on chapter three...”", postId: "demo", commentId: nil, blendId: nil, actorId: "demo", coverURL: nil, createdAt: now.addingTimeInterval(-3 * 86400), read: true),
            UserNotification(id: "5", type: "friend_review_posted", title: "⭐ Riley gave a 9.0", body: "Project Hail Mary: “Smart, ambitious, and way more readable than...”", postId: "demo", commentId: nil, blendId: nil, actorId: "demo", coverURL: nil, createdAt: now.addingTimeInterval(-9 * 86400), read: true),
            UserNotification(id: "6", type: "book_recommended", title: "📖 Maya sent you a book", body: "Piranesi: “You'd love this one”", postId: nil, commentId: nil, blendId: nil, actorId: "demo", coverURL: nil, createdAt: now.addingTimeInterval(-12 * 86400), read: true),
        ]
    }
    #endif
}
