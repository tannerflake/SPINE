//
//  QueueBookDragCover.swift
//  SPINE
//
//  UIKit drag on top of SwiftUI `BookCoverView` so queue cells match normal covers (including title placeholders)
//  and we still get `UIDragInteraction` session callbacks for Read/Queue tab chrome.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Library scroll during drag (top edge + nav title boost)

/// Drives `UIScrollView.contentOffset` while a `UIDragSession` is active.
///
/// All finger positions are computed in **viewport** space (visible bounds of the scroll view), not content space.
/// `UIDragSession.location(in:)` on a scroll view returns *content* coordinates (its bounds origin is the
/// `contentOffset`), so the raw value grows as you scroll down — comparing it against a top-edge band made the band
/// unreachable once scrolled, and made the bottom band “always hit” (the old runaway downward scroll). Subtracting
/// `contentOffset` fixes both, so both directions are enabled.
///
/// Speed ramps smoothly with how deep the finger is in the edge band (smoothstep, 0 at the rim → max at the edge),
/// and keeps ramping up to a fast “jump to top” speed as the finger moves above the visible list over the header /
/// nav chrome — relative to the scroll view itself, so callouts like “Finish importing” shifting the list down
/// don’t open a dead gap.
private final class DragAutoScrollDriver: NSObject {
    weak var scrollView: UIScrollView?
    weak var session: UIDragSession?

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var sessionStartTimestamp: CFTimeInterval?
    private var framesSinceStart: Int = 0

    /// Max scroll speed (points / second) at the very edge of the band.
    private let maxEdgeSpeed: CGFloat = 620
    /// Speed once the finger is well above the visible list (header / nav chrome) — jumps to the top quickly.
    private let chromeBoostSpeed: CGFloat = 2400
    /// Distance above the viewport top over which speed ramps from `maxEdgeSpeed` to `chromeBoostSpeed`.
    private let chromeRampDistance: CGFloat = 120
    /// Edge inset from top/bottom of the scroll view used for auto-scroll (capped so bands never overlap).
    private let edgeFraction: CGFloat = 0.12
    private let edgeMinPoints: CGFloat = 60
    private let edgeMaxPoints: CGFloat = 100
    /// Brief delay after lift so the first noisy location frames don’t scroll.
    private let armDelaySeconds: CFTimeInterval = 0.12
    private let warmupFrames: Int = 1

    func start() {
        guard displayLink == nil else { return }
        lastTimestamp = nil
        sessionStartTimestamp = nil
        framesSinceStart = 0
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
        sessionStartTimestamp = nil
        framesSinceStart = 0
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let session, let sv = scrollView else { return }
        let now = link.timestamp
        if sessionStartTimestamp == nil {
            sessionStartTimestamp = now
        }
        framesSinceStart += 1
        guard framesSinceStart > warmupFrames else { return }

        let dt: CGFloat
        if let last = lastTimestamp {
            dt = CGFloat(now - last)
        } else {
            dt = 0
        }
        lastTimestamp = now
        guard dt > 0, dt < 0.25 else { return }

        let start = sessionStartTimestamp ?? now
        guard now - start >= armDelaySeconds else { return }

        sv.layoutIfNeeded()

        let h = max(1, sv.bounds.height)
        /// `location(in:)` is in content coordinates for a scroll view; subtract the offset for viewport space
        /// (0 = visible top edge, negative = above the list over header / nav chrome).
        let fingerY = session.location(in: sv).y - sv.contentOffset.y

        var zone = min(edgeMaxPoints, max(edgeMinPoints, h * edgeFraction))
        zone = min(zone, max(24, (h - 40) / 2))

        let inset = sv.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, sv.contentSize.height - h + inset.bottom)
        let y0 = sv.contentOffset.y

        var velocity: CGFloat = 0
        if fingerY < zone, y0 > minY + 0.5 {
            if fingerY < 0 {
                // Above the visible list: keep ramping past max band speed toward the chrome boost.
                let over = min(1, -fingerY / chromeRampDistance)
                velocity = -(maxEdgeSpeed + (chromeBoostSpeed - maxEdgeSpeed) * over)
            } else {
                velocity = -maxEdgeSpeed * Self.smoothstep((zone - fingerY) / zone)
            }
        } else if fingerY > h - zone, y0 < maxY - 0.5 {
            velocity = maxEdgeSpeed * Self.smoothstep((fingerY - (h - zone)) / zone)
        }

        let delta = velocity * dt
        guard abs(delta) > 0.05 else { return }

        var offset = sv.contentOffset
        offset.y += delta
        offset.y = min(maxY, max(minY, offset.y))
        sv.contentOffset = offset
    }

    /// 0→1 with zero slope at both ends, so speed eases in at the band rim instead of kicking on abruptly.
    private static func smoothstep(_ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }
}

/// Pins the enclosing `UIScrollView` so drag auto-scroll can adjust `contentOffset`.
struct LibraryScrollViewAnchor: UIViewRepresentable {
    @ObservedObject var dragCoordinator: QueueBookDragCoordinator

    func makeUIView(context: Context) -> ScrollViewAnchorUIView {
        let v = ScrollViewAnchorUIView()
        v.onScrollViewFound = { [weak dragCoordinator] sv in
            dragCoordinator?.registerLibraryScrollView(sv)
        }
        return v
    }

    func updateUIView(_ uiView: ScrollViewAnchorUIView, context: Context) {
        uiView.onScrollViewFound = { [weak dragCoordinator] sv in
            dragCoordinator?.registerLibraryScrollView(sv)
        }
    }
}

final class ScrollViewAnchorUIView: UIView {
    var onScrollViewFound: ((UIScrollView) -> Void)?
    private weak var lastSent: UIScrollView?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let sv = findEnclosingScrollView() else { return }
        if lastSent !== sv {
            lastSent = sv
            onScrollViewFound?(sv)
        }
    }

    /// SwiftUI can nest several `UIScrollView`s (lazy containers, etc.). The **first** one up the tree is often a
    /// small inner scroller — auto-scroll then thinks the finger is always in the “bottom edge” and death-scrolls.
    /// Prefer the **largest** scroll view among ancestors (the main library `ScrollView`).
    private func findEnclosingScrollView() -> UIScrollView? {
        var v: UIView? = superview
        var best: UIScrollView?
        var bestArea: CGFloat = 0
        while let cur = v {
            if let sc = cur as? UIScrollView {
                let area = sc.bounds.width * sc.bounds.height
                if area > bestArea {
                    bestArea = area
                    best = sc
                }
            }
            v = cur.superview
        }
        return best
    }
}

@MainActor
final class QueueBookDragCoordinator: ObservableObject {
    @Published private(set) var isDraggingQueueBook = false
    @Published private(set) var isDraggingReadBook = false

    private let autoScrollDriver = DragAutoScrollDriver()

    func registerLibraryScrollView(_ scrollView: UIScrollView?) {
        autoScrollDriver.scrollView = scrollView
    }

    func beginDragSession(_ session: UIDragSession) {
        autoScrollDriver.session = session
        autoScrollDriver.start()
    }

    func endDragSession() {
        autoScrollDriver.session = nil
        autoScrollDriver.stop()
        LibraryDragHaptics.resetDropHoverThrottle()
    }

    func setDraggingQueueBook(_ value: Bool) {
        guard isDraggingQueueBook != value else { return }
        isDraggingQueueBook = value
    }

    func setDraggingReadBook(_ value: Bool) {
        guard isDraggingReadBook != value else { return }
        isDraggingReadBook = value
    }
}

/// Hosts `BookCoverView` (same visuals as everywhere else) + `UIDragInteraction` for `TierDragItem` payload.
struct QueueBookDragCover: UIViewControllerRepresentable {
    let book: Book
    let userBookId: UUID
    let bookSize: CGFloat
    var onTap: (() -> Void)?
    /// In-app queue drop landed on this cover: (dropped userBook id, insertBefore).
    /// Left half of the cover inserts before it, right half after. A `UIDropInteraction`
    /// (not a SwiftUI overlay) so the cover stays fully tappable and drag-liftable.
    var onDropItem: ((UUID, Bool) -> Void)? = nil
    @ObservedObject var dragCoordinator: QueueBookDragCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(
            userBookId: userBookId,
            dragCoordinator: dragCoordinator,
            onTap: onTap,
            onDropItem: onDropItem
        )
    }

    func makeUIViewController(context: Context) -> UIHostingController<BookCoverView> {
        let root = BookCoverView(book: book, size: bookSize, onTap: onTap)
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        context.coordinator.host = host
        context.coordinator.userBookId = userBookId
        context.coordinator.onTap = onTap
        context.coordinator.onDropItem = onDropItem

        let drag = UIDragInteraction(delegate: context.coordinator)
        host.view.addInteraction(drag)
        let drop = UIDropInteraction(delegate: context.coordinator)
        host.view.addInteraction(drop)

        return host
    }

    func updateUIViewController(_ host: UIHostingController<BookCoverView>, context: Context) {
        host.rootView = BookCoverView(book: book, size: bookSize, onTap: onTap)
        context.coordinator.host = host
        context.coordinator.userBookId = userBookId
        context.coordinator.onTap = onTap
        context.coordinator.onDropItem = onDropItem
    }

    final class Coordinator: NSObject, UIDragInteractionDelegate, UIDropInteractionDelegate {
        var userBookId: UUID
        let dragCoordinator: QueueBookDragCoordinator
        var onTap: (() -> Void)?
        var onDropItem: ((UUID, Bool) -> Void)?
        weak var host: UIHostingController<BookCoverView>?

        init(
            userBookId: UUID,
            dragCoordinator: QueueBookDragCoordinator,
            onTap: (() -> Void)?,
            onDropItem: ((UUID, Bool) -> Void)?
        ) {
            self.userBookId = userBookId
            self.dragCoordinator = dragCoordinator
            self.onTap = onTap
            self.onDropItem = onDropItem
        }

        // MARK: UIDragInteractionDelegate

        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
            Task { @MainActor in
                dragCoordinator.setDraggingQueueBook(true)
                dragCoordinator.beginDragSession(session)
            }
        }

        func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
            Task { @MainActor in
                dragCoordinator.setDraggingQueueBook(false)
                dragCoordinator.endDragSession()
            }
        }

        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
            let provider = NSItemProvider()
            let idString = userBookId.uuidString
            provider.registerDataRepresentation(for: UTType.plainText, visibility: .all) { completion in
                completion(Data(idString.utf8), nil)
                return nil
            }
            let item = UIDragItem(itemProvider: provider)
            item.localObject = idString
            return [item]
        }

        func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession) -> UITargetedDragPreview? {
            guard let view = host?.view else { return nil }
            let params = UIDragPreviewParameters()
            params.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 6)
            return UITargetedDragPreview(view: view, parameters: params)
        }

        // MARK: UIDropInteractionDelegate — the whole cover accepts queue drops

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            // In-app queue drags only (the drag item carries the uuid as localObject).
            onDropItem != nil && session.localDragSession?.items.first?.localObject is String
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
            LibraryDragHaptics.dropTargetHoverEntered()
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: .move)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            guard let view = host?.view,
                  let idString = session.localDragSession?.items.first?.localObject as? String,
                  let droppedId = UUID(uuidString: idString)
            else { return }
            let insertBefore = session.location(in: view).x < view.bounds.midX
            onDropItem?(droppedId, insertBefore)
        }
    }
}

/// Same as `QueueBookDragCover` but drives **Read** tab chrome (red −) while dragging a tier-list read book.
///
/// Taps are handled here in UIKit rather than by `BookCoverView`'s SwiftUI tap so a
/// double-tap (enter multi-select) can be told apart from a single tap (open the
/// book). Outside selection mode the single tap waits for the double-tap
/// recognizer to fail, which is the standard ~0.3s iOS disambiguation delay; in
/// selection mode the double-tap recognizer is disabled so toggling is instant.
struct ReadListBookDragCover: UIViewControllerRepresentable {
    let book: Book
    let userBookId: UUID
    let bookSize: CGFloat
    var onTap: (() -> Void)?
    /// Double-tap on the cover. Nil disables double-tap detection entirely (no
    /// single-tap delay).
    var onDoubleTap: (() -> Void)? = nil
    /// True while the tier list is in multi-select: taps toggle immediately and
    /// drag-and-drop is switched off so the action bar is the only way to move.
    var isSelecting: Bool = false
    @ObservedObject var dragCoordinator: QueueBookDragCoordinator

    func makeCoordinator() -> ReadCoordinator {
        ReadCoordinator(
            userBookId: userBookId,
            dragCoordinator: dragCoordinator,
            onTap: onTap
        )
    }

    func makeUIViewController(context: Context) -> UIHostingController<BookCoverView> {
        // No SwiftUI onTap: the coordinator's recognizers own every tap.
        let root = BookCoverView(book: book, size: bookSize, onTap: nil)
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        context.coordinator.host = host
        context.coordinator.hostedBook = book
        context.coordinator.hostedSize = bookSize
        context.coordinator.userBookId = userBookId
        context.coordinator.onTap = onTap
        context.coordinator.onDoubleTap = onDoubleTap

        let drag = UIDragInteraction(delegate: context.coordinator)
        host.view.addInteraction(drag)
        context.coordinator.dragInteraction = drag

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(ReadCoordinator.handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(ReadCoordinator.handleSingleTap))
        singleTap.require(toFail: doubleTap)
        host.view.addGestureRecognizer(doubleTap)
        host.view.addGestureRecognizer(singleTap)
        context.coordinator.doubleTapRecognizer = doubleTap
        context.coordinator.applyMode(isSelecting: isSelecting, doubleTapEnabled: onDoubleTap != nil)

        return host
    }

    func updateUIViewController(_ host: UIHostingController<BookCoverView>, context: Context) {
        // Only swap the hosted cover when it actually changed. Reassigning
        // rootView on every SwiftUI update (selection toggles re-render every
        // cell) makes each hosting view invalidate and re-lay out inside the
        // tier list's scroll view, which is both slow with hundreds of covers
        // and a source of scroll-position churn.
        if context.coordinator.hostedBook != book || context.coordinator.hostedSize != bookSize {
            host.rootView = BookCoverView(book: book, size: bookSize, onTap: nil)
            context.coordinator.hostedBook = book
            context.coordinator.hostedSize = bookSize
        }
        context.coordinator.host = host
        context.coordinator.userBookId = userBookId
        context.coordinator.onTap = onTap
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.applyMode(isSelecting: isSelecting, doubleTapEnabled: onDoubleTap != nil)
    }

    final class ReadCoordinator: NSObject, UIDragInteractionDelegate {
        var userBookId: UUID
        let dragCoordinator: QueueBookDragCoordinator
        var onTap: (() -> Void)?
        var onDoubleTap: (() -> Void)?
        weak var host: UIHostingController<BookCoverView>?
        /// What the hosting controller currently shows, so updates can skip
        /// the rootView swap when nothing about the cover changed.
        var hostedBook: Book?
        var hostedSize: CGFloat = 0
        weak var dragInteraction: UIDragInteraction?
        weak var doubleTapRecognizer: UITapGestureRecognizer?

        init(
            userBookId: UUID,
            dragCoordinator: QueueBookDragCoordinator,
            onTap: (() -> Void)?
        ) {
            self.userBookId = userBookId
            self.dragCoordinator = dragCoordinator
            self.onTap = onTap
        }

        /// Selection mode: instant single taps (no double-tap to wait on) and no drag lift.
        func applyMode(isSelecting: Bool, doubleTapEnabled: Bool) {
            doubleTapRecognizer?.isEnabled = doubleTapEnabled && !isSelecting
            dragInteraction?.isEnabled = !isSelecting
        }

        @objc func handleSingleTap() {
            onTap?()
        }

        @objc func handleDoubleTap() {
            onDoubleTap?()
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
            Task { @MainActor in
                LibraryDragHaptics.dragLiftBegan()
                dragCoordinator.setDraggingReadBook(true)
                dragCoordinator.beginDragSession(session)
            }
        }

        func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
            Task { @MainActor in
                dragCoordinator.setDraggingReadBook(false)
                dragCoordinator.endDragSession()
            }
        }

        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
            let provider = NSItemProvider()
            let idString = userBookId.uuidString
            provider.registerDataRepresentation(for: UTType.plainText, visibility: .all) { completion in
                completion(Data(idString.utf8), nil)
                return nil
            }
            let item = UIDragItem(itemProvider: provider)
            item.localObject = idString
            return [item]
        }

        func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession) -> UITargetedDragPreview? {
            guard let view = host?.view else { return nil }
            let params = UIDragPreviewParameters()
            params.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 6)
            return UITargetedDragPreview(view: view, parameters: params)
        }
    }
}

// MARK: - Reading now card (whole-card lift)

/// Hosts a full Reading now card so a long press anywhere on it (above the
/// scrubber) lifts the *whole card* as the drag preview. Same `TierDragItem`
/// payload as the covers, so it drops on every existing queue target: between
/// other Reading now cards, into Up next / Backlog slots, or on the Read segment.
/// The card also accepts drops itself: top half inserts before it, bottom half after.
///
/// The scrubber band (everything below `liftableHeight`) never lifts, so holding
/// the bookmark thumb still doesn't pick the card up mid-scrub.
struct QueueReadingNowDragCard<Content: View>: UIViewControllerRepresentable {
    let userBookId: UUID
    /// Height from the card's top edge inside which a long press starts a lift.
    let liftableHeight: CGFloat
    /// (dropped userBook id, insertBefore)
    var onDropItem: ((UUID, Bool) -> Void)? = nil
    @ObservedObject var dragCoordinator: QueueBookDragCoordinator
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(userBookId: userBookId, dragCoordinator: dragCoordinator)
    }

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.view.clipsToBounds = false
        host.sizingOptions = [.intrinsicContentSize]
        context.coordinator.host = host
        context.coordinator.userBookId = userBookId
        context.coordinator.liftableHeight = liftableHeight
        context.coordinator.onDropItem = onDropItem

        let drag = UIDragInteraction(delegate: context.coordinator)
        host.view.addInteraction(drag)
        let drop = UIDropInteraction(delegate: context.coordinator)
        host.view.addInteraction(drop)
        return host
    }

    func updateUIViewController(_ host: UIHostingController<Content>, context: Context) {
        host.rootView = content()
        context.coordinator.host = host
        context.coordinator.userBookId = userBookId
        context.coordinator.liftableHeight = liftableHeight
        context.coordinator.onDropItem = onDropItem
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController host: UIHostingController<Content>, context: Context) -> CGSize? {
        // Compressed height: the card has a Spacer in its text column, so an
        // expanded proposal would balloon it to fill the whole scroll view.
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let fitted = host.sizeThatFits(in: CGSize(width: width, height: UIView.layoutFittingCompressedSize.height))
        return CGSize(width: proposal.width ?? fitted.width, height: fitted.height)
    }

    final class Coordinator: NSObject, UIDragInteractionDelegate, UIDropInteractionDelegate {
        var userBookId: UUID
        var liftableHeight: CGFloat = .greatestFiniteMagnitude
        let dragCoordinator: QueueBookDragCoordinator
        var onDropItem: ((UUID, Bool) -> Void)?
        weak var host: UIHostingController<Content>?

        init(userBookId: UUID, dragCoordinator: QueueBookDragCoordinator) {
            self.userBookId = userBookId
            self.dragCoordinator = dragCoordinator
        }

        // MARK: UIDragInteractionDelegate

        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
            // Refuse lifts that start on the scrubber row.
            if let view = host?.view, session.location(in: view).y > liftableHeight { return [] }
            let provider = NSItemProvider()
            let idString = userBookId.uuidString
            provider.registerDataRepresentation(for: UTType.plainText, visibility: .all) { completion in
                completion(Data(idString.utf8), nil)
                return nil
            }
            let item = UIDragItem(itemProvider: provider)
            item.localObject = idString
            return [item]
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
            Task { @MainActor in
                LibraryDragHaptics.dragLiftBegan()
                dragCoordinator.setDraggingQueueBook(true)
                dragCoordinator.beginDragSession(session)
            }
        }

        func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
            Task { @MainActor in
                dragCoordinator.setDraggingQueueBook(false)
                dragCoordinator.endDragSession()
            }
        }

        func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession) -> UITargetedDragPreview? {
            guard let view = host?.view else { return nil }
            let params = UIDragPreviewParameters()
            params.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: Theme.cardCornerRadius)
            params.backgroundColor = .clear
            return UITargetedDragPreview(view: view, parameters: params)
        }

        // MARK: UIDropInteractionDelegate

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            guard onDropItem != nil,
                  let idString = session.localDragSession?.items.first?.localObject as? String
            else { return false }
            // Dropping a card on itself is a no-op; let the drop fall through.
            return idString != userBookId.uuidString
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
            LibraryDragHaptics.dropTargetHoverEntered()
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: .move)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            guard let view = host?.view,
                  let idString = session.localDragSession?.items.first?.localObject as? String,
                  let droppedId = UUID(uuidString: idString)
            else { return }
            let insertBefore = session.location(in: view).y < view.bounds.midY
            onDropItem?(droppedId, insertBefore)
        }
    }
}
