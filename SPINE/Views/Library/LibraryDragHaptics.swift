//
//  LibraryDragHaptics.swift
//  SPINE
//
//  Impact feedback when a book becomes draggable and when hovering valid drop targets.
//

import UIKit

enum LibraryDragHaptics {
    private static var lastDropHoverTime: CFAbsoluteTime = 0
    /// Minimum seconds between hover pulses while scrubbing across adjacent drop zones.
    private static let dropHoverThrottle: TimeInterval = 0.14

    /// Fired once when the user’s lift begins and the book is draggable.
    static func dragLiftBegan() {
        resetDropHoverThrottle()
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare()
        g.impactOccurred(intensity: 1.0)
    }

    /// Fired when the drag preview enters a valid drop region (tab chrome, tier slot, queue slot, etc.).
    static func dropTargetHoverEntered() {
        let t = CFAbsoluteTimeGetCurrent()
        guard t - lastDropHoverTime >= dropHoverThrottle else { return }
        lastDropHoverTime = t
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare()
        g.impactOccurred(intensity: 0.85)
    }

    /// Call when a drag session ends so the next hover can fire immediately.
    static func resetDropHoverThrottle() {
        lastDropHoverTime = 0
    }
}
