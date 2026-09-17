//
//  SlidingLens.swift
//  SPINE
//
//  Press-and-slide selection for a lens parked behind a row of equal-width items:
//  the main tab bar and the Read / Queue control. Mirrors the iOS 26 tab bar:
//  touching the row lifts the lens, dragging carries it under the finger and
//  switches selection live as it crosses each item, and releasing snaps it onto
//  whichever item it landed on. A touch that never travels is a tap.
//

import SwiftUI

extension View {
    /// Draws `lens` behind this row of `itemCount` equal-width items and lets the
    /// user tap an item or press and slide the lens between them.
    ///
    /// Apply directly to the `HStack` of items, before any outer padding or
    /// background chrome: the lens is sized to the row's width divided by
    /// `itemCount`, shrunk by `lensInsets`. `selectedIndex` is updated live while
    /// sliding; `onTap` fires for stationary touches (including one on the item
    /// that is already selected, so callers can implement tap-again behaviour).
    func slidingLens<Lens: View>(
        itemCount: Int,
        selectedIndex: Binding<Int>,
        lensInsets: EdgeInsets = EdgeInsets(),
        isVisible: Bool = true,
        onTap: @escaping (Int) -> Void,
        @ViewBuilder lens: @escaping () -> Lens
    ) -> some View {
        modifier(SlidingLensModifier(
            itemCount: itemCount,
            selectedIndex: selectedIndex,
            lensInsets: lensInsets,
            isVisible: isVisible,
            onTap: onTap,
            lens: lens
        ))
    }
}

/// Springs shared by every sliding lens so the tab bar and the Read / Queue
/// control move the same way.
enum SlidingLensMotion {
    /// Lens settling onto an item after a tap or a release.
    static let settle = Animation.snappy(duration: 0.3, extraBounce: 0.12)
    /// Lens chasing the finger mid-slide: quick, no bounce, a hint of weight.
    static let follow = Animation.interactiveSpring(response: 0.16, dampingFraction: 0.86)
    /// Lift on touch-down and drop on release.
    static let lift = Animation.snappy(duration: 0.22, extraBounce: 0.08)
    /// How far a touch may travel and still count as a tap.
    static let tapSlop: CGFloat = 6
    /// Lens scale while held.
    static let liftedScale: CGFloat = 1.08
}

private struct SlidingLensModifier<Lens: View>: ViewModifier {
    let itemCount: Int
    @Binding var selectedIndex: Int
    let lensInsets: EdgeInsets
    let isVisible: Bool
    let onTap: (Int) -> Void
    let lens: () -> Lens

    /// Transient touch state. `@GestureState` so a cancelled gesture (incoming
    /// sheet, system interruption) can never leave the lens stranded mid-slide
    /// or stuck at the lifted scale.
    @GestureState(resetTransaction: Transaction(animation: SlidingLensMotion.settle))
    private var touch = Touch()
    /// Sticky for the duration of one touch: once the finger has travelled past
    /// the tap slop, selection tracks it even if it wanders back near the origin.
    @State private var slidThisTouch = false
    /// Row width as last laid out, for turning a finger position into an item
    /// index. The lens itself never reads this: it takes its geometry straight
    /// from the `GeometryReader` it is drawn in, so it is the right size on the
    /// very first frame instead of hopping there a render later. (A lens whose
    /// width arrived via state was seen ballooning from a sliver to full width
    /// over many seconds on a starved simulator: the glass shape morphs frame by
    /// frame, and every stale-width render restarted it.)
    @State private var rowWidth: CGFloat = 0

    private struct Touch: Equatable {
        var isPressed = false
        var isSliding = false
        var fingerX: CGFloat = 0
    }

    private func itemWidth(rowWidth: CGFloat) -> CGFloat {
        itemCount > 0 ? rowWidth / CGFloat(itemCount) : 0
    }

    private func index(atX x: CGFloat, rowWidth: CGFloat) -> Int {
        let itemWidth = itemWidth(rowWidth: rowWidth)
        guard itemWidth > 0 else { return selectedIndex }
        return min(max(Int(floor(x / itemWidth)), 0), itemCount - 1)
    }

    /// Lens centre: under the finger (clamped to the row) while sliding, else
    /// parked on the selected item.
    private func lensCenterX(rowWidth: CGFloat) -> CGFloat {
        let itemWidth = itemWidth(rowWidth: rowWidth)
        if touch.isSliding {
            return min(max(touch.fingerX, itemWidth / 2), rowWidth - itemWidth / 2)
        }
        return (CGFloat(selectedIndex) + 0.5) * itemWidth
    }

    func body(content: Content) -> some View {
        content
            .background(alignment: .leading) {
                if isVisible, itemCount > 0 {
                    GeometryReader { geo in
                        let rowWidth = geo.size.width
                        let itemWidth = itemWidth(rowWidth: rowWidth)
                        let centerX = lensCenterX(rowWidth: rowWidth)
                        lens()
                            .padding(lensInsets)
                            .frame(width: itemWidth)
                            .scaleEffect(touch.isPressed ? SlidingLensMotion.liftedScale : 1)
                            .animation(SlidingLensMotion.lift, value: touch.isPressed)
                            .offset(x: centerX - itemWidth / 2)
                            .animation(
                                touch.isSliding ? SlidingLensMotion.follow : SlidingLensMotion.settle,
                                value: centerX
                            )
                            .onChange(of: rowWidth, initial: true) { _, width in
                                self.rowWidth = width
                            }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag)
            .onChange(of: touch.isPressed) { _, pressed in
                if !pressed { slidThisTouch = false }
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($touch) { value, state, _ in
                state.isPressed = true
                state.fingerX = value.location.x
                if !state.isSliding, Self.travel(of: value) > SlidingLensMotion.tapSlop {
                    state.isSliding = true
                }
            }
            .onChanged { value in
                if !slidThisTouch, Self.travel(of: value) > SlidingLensMotion.tapSlop {
                    slidThisTouch = true
                }
                guard slidThisTouch else { return }
                let under = index(atX: value.location.x, rowWidth: rowWidth)
                if under != selectedIndex {
                    selectedIndex = under
                }
            }
            .onEnded { value in
                // A slide has already committed its selection live; only a
                // stationary touch is a tap.
                guard !slidThisTouch, Self.travel(of: value) <= SlidingLensMotion.tapSlop else { return }
                onTap(index(atX: value.location.x, rowWidth: rowWidth))
            }
    }

    private static func travel(of value: DragGesture.Value) -> CGFloat {
        hypot(value.translation.width, value.translation.height)
    }
}
