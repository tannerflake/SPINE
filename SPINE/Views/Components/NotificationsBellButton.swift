//
//  NotificationsBellButton.swift
//  SPINE
//
//  Shared bell button for the notifications feed. Used on both the Feed
//  header and the Profile (Library) header so the two look and behave
//  identically — same icon, same badge dot, same tap target (scaled by
//  `size`). Both read the same `AppState.hasUnreadNotifications` so the
//  badge can never disagree between tabs; `action` just tells the host
//  screen to push NotificationsView.
//

import SwiftUI

struct NotificationsBellButton: View {
    /// `.standard`: beside the avatar on Profile's header row. `.compact`:
    /// tucked into a nav bar corner (Feed's top-right) where the icon needs
    /// to sit small and not claim extra vertical space.
    enum Size {
        case standard
        case compact

        var iconSize: CGFloat { self == .standard ? 22 : 16 }
        var frame: CGFloat { self == .standard ? 34 : 24 }
        var badgeDiameter: CGFloat { self == .standard ? 10 : 7 }
        var badgeOffset: CGSize { self == .standard ? CGSize(width: -2, height: 3) : CGSize(width: -1, height: 1) }
    }

    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appState: AppState
    var size: Size = .standard
    let action: () -> Void

    /// Feature flag: the notifications bell is built but not launched yet —
    /// flip to true to unhide it everywhere it appears (Feed and Profile both
    /// gate through here). `-uiPreviewNotifications` overrides in DEBUG.
    private static let isFeatureEnabled = true
    private static var isVisible: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiPreviewNotifications") { return true }
        #endif
        return isFeatureEnabled
    }

    var body: some View {
        if Self.isVisible {
            Button {
                action()
                // Optimistic only — NotificationsView does the authoritative
                // server-side markAllRead once its rows are actually on screen.
                appState.hasUnreadNotifications = false
            } label: {
                Image(systemName: "bell")
                    .font(.system(size: size.iconSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    // Badge anchors to the glyph, not the tap frame, so it hugs
                    // the bell's top-right shoulder.
                    .overlay(alignment: .topTrailing) {
                        if appState.hasUnreadNotifications {
                            Circle()
                                .fill(Theme.danger)
                                .frame(width: size.badgeDiameter, height: size.badgeDiameter)
                                .overlay(Circle().strokeBorder(Theme.background, lineWidth: 1.5))
                                .offset(x: size.badgeOffset.width, y: size.badgeOffset.height)
                        }
                    }
                    .frame(width: size.frame, height: size.frame)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(appState.hasUnreadNotifications ? "Notifications, new activity" : "Notifications")
            .task(id: authService.firebaseUser?.uid) {
                appState.refreshUnreadNotifications()
            }
        }
    }
}
