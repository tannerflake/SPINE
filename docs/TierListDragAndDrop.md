# Tier List Drag-and-Drop: Technical Notes

This document describes the technical choices that make the SPINE tier list drag-and-drop reliable and responsive.

---

## Overview

The tier list lets users rank “Read” books into tiers (S, A, B, C, D, Unranked) by **drag-and-drop only**: long-press a book cover to start a drag, then drop it on a tier row. The implementation relies on SwiftUI’s `.draggable()` and `.dropDestination()`, with a few targeted fixes for transfer reliability, hit targets, and perceived performance.

---

## 1. Transfer Representation: Plain-Text UUID

**Problem:** Using `CodableRepresentation(contentType: UTType.json)` for the drag payload was unreliable—drops often didn’t register or decode correctly in-app.

**Solution:** Use **plain-text UUID** with `DataRepresentation`:

- **Export:** Encode `userBookId.uuidString` as `Data` with content type `.plainText`.
- **Import:** Decode the string from the dropped data and construct `UUID(uuidString:)`, then return a `TierDragItem(userBookId: id)`.

This gives a trivial, unambiguous payload that SwiftUI’s drag/drop system can round-trip reliably within the same app.

```swift
struct TierDragItem: Transferable, Hashable {
    let userBookId: UUID

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { item in
            Data(item.userBookId.uuidString.utf8)
        }
        DataRepresentation(importedContentType: .plainText) { data in
            let s = String(decoding: data, as: UTF8.self)
            guard let id = UUID(uuidString: s) else { throw DecodeError() }
            return TierDragItem(userBookId: id)
        }
    }
}
```

---

## 2. One Drop Zone per Row (Whole-Row Target)

**Problem:** Multiple small “slots” between books (e.g. 24–44pt wide) were hard to hit, especially with nested horizontal `ScrollView`s. Users had to hold the drag over a tiny region for the drop to register.

**Solution:** Treat the **entire tier row** as a single drop target:

- Each row (S, A, B, C, D, Unranked) has one `.dropDestination(for: TierDragItem.self)` on the row’s content area (the horizontal scroll region).
- Dropping anywhere on that row moves the book to that tier and appends it at the **end** of the row (`order: nil` → append in `setTierAndOrder`).
- No slot index is needed for the drop; the row identity (tier) is enough.

Benefits:

- Large, easy-to-hit drop area.
- Fewer views and modifiers, so less chance of gesture/drop conflicts.
- Clear mental model: “drop on the row = move to that tier.”

Implementation: the row’s scroll content uses `.contentShape(Rectangle())` and `.dropDestination(...)` so the full row area accepts the drop. Reordering within a tier (e.g. slot index) can be added later as a separate interaction if desired.

---

## 3. Shorter Long-Press to Start Drag

**Problem:** SwiftUI’s `.draggable()` uses a system long-press with a default duration (~1 second), which felt sluggish.

**Solution:** A small **UIKit bridge** that finds the underlying `UILongPressGestureRecognizer` used for the drag and shortens its `minimumPressDuration` (e.g. to 0.25s):

- A transparent `UIViewRepresentable` is added as a **background** to the draggable view (so it doesn’t block touches).
- In `updateUIView`, we traverse the superview and subviews for gesture recognizers whose type name contains `"Lift"` or `"Drag"` (the system drag recognizer).
- Set `long.minimumPressDuration = 0.25` (or similar) so the drag starts after a brief press.

This keeps SwiftUI’s native `.draggable()` while making the interaction feel more responsive.

---

## 4. Immediate Visual Feedback on Drop Target

**Problem:** Users couldn’t tell which row would receive the drop until after releasing.

**Solution:** Use the `isTargeted` callback of `.dropDestination(...)` to drive row highlighting:

- When `isTargeted` becomes `true`, set a state flag (e.g. `isTargeted`) so the row’s background changes (e.g. accent color at low opacity).
- When the drag leaves or the drop completes, clear the flag so the highlight disappears.

The row’s background is drawn with this state (e.g. `Theme.accent.opacity(0.2)` when targeted), so the valid drop target is obvious before the user releases.

---

## 5. Cover Image Cache (Post-Drop UX)

**Problem:** After a drop, the list re-renders and book covers were re-fetched, causing spinners and a “flash” that made the list feel broken.

**Solution:** An **in-memory image cache** for cover art:

- A singleton `CoverImageCache` uses `NSCache<NSString, UIImage>` keyed by cover URL.
- Book cover views load via `CoverImageCache.shared.image(for: url)` (async). On cache hit, the image is shown immediately with no network request.
- After a tier drop, the same URLs are used for the same books, so covers appear instantly from cache.

This keeps the drag-and-drop interaction feeling smooth and avoids unnecessary network use when reordering.

---

## 6. Drag-Only Interaction (No Context Menu)

**Problem:** A context menu on long-press (e.g. “Move to A”, “Move to S”) competed with the long-press-for-drag gesture and made the interaction ambiguous.

**Solution:** Remove the context menu from tier book cells. The **only** way to move a book between tiers is drag-and-drop. This removes gesture conflict and keeps the interaction model simple and consistent.

---

## 7. Data Flow

- **Drag source:** `TierBookCell` uses `ReadListBookDragCover` (UIKit `UIDragInteraction`, same UUID payload as `TierDragItem`) so the Read tab can show remove chrome while dragging.
- **Drop destination:** Each `TierRowView` applies `.dropDestination(for: TierDragItem.self)` to the row’s content area and calls `onUpdateTierAndOrder(payload.userBookId, tier, nil)` on successful drop (`nil` = append at end).
- **App state:** `setTierAndOrder(for:tier:order:)` updates the in-memory `userBooks` (tier and `tierOrder`), then persists changed documents to Firestore. Order within a tier is determined by `tierOrder`; `nil` order means “append.”

---

## File References

| Concern              | Primary file(s)                          |
|----------------------|------------------------------------------|
| Tier list UI & drop  | `SPINE/Views/Library/TierListView.swift` |
| Transfer payload     | `TierListView.swift` (`TierDragItem`)    |
| Read drag cover      | `SPINE/Views/Library/QueueBookDragCover.swift` (`ReadListBookDragCover`) |
| Cover image cache    | `SPINE/Views/Components/BookCoverView.swift` |
| Tier/order updates   | `SPINE/AppState/AppState.swift` (`setTierAndOrder`) |

---

## Summary

The tier list works well because:

1. **Payload** is a simple plain-text UUID, so encode/decode is reliable.
2. **Drop target** is the whole row, so hits are easy and predictable.
3. **Drag** uses UIKit’s drag interaction on the cover (consistent with queue cells).
4. **Feedback** is immediate with row highlighting when targeted.
5. **Covers** are cached so post-drop re-renders don’t refetch images.
6. **Interaction** is drag-only, with no competing context menu.

Together, these choices make tier-to-tier moves feel responsive, predictable, and smooth.
