//
//  CardStamps.swift
//  SPINE
//
//  Drawing achievement stamps on the library card. `CardStampsLayer` prints
//  every placed stamp for one side of the card at its stored fractional
//  position, so the profile card, the share export, and the stamping screen
//  all agree on where a stamp sits. `CardZone` is how the front face reports
//  its printed elements (name, photo, card number...) so the stamping screen
//  can keep stamps off them. Copy rule: no em-dashes in user-facing text.
//

import SwiftUI

// MARK: - Geometry

enum CardStampGeometry {
    /// Stamp width as a fraction of the card face width. On the profile card
    /// (about 326pt wide) that is a 38pt stamp; on the 306pt export, 35pt.
    static let widthFraction: CGFloat = 0.116

    /// Printed stamps are translucent ink, not stickers: the card shows through.
    static let inkOpacity: Double = 0.6

    /// How far a stamp must stay from a printed element, in points.
    static let zoneInset: CGFloat = 4

    /// The side one stamp prints at: the face's base size times the stamp's
    /// own `frameScale`, so a narrow stamp can be pressed a little larger and
    /// still read at the same weight as a round one.
    static func stampSize(faceWidth: CGFloat, kind: AchievementKind) -> CGFloat {
        (faceWidth * widthFraction * kind.frameScale).rounded()
    }

    /// The stamp's frame in the face's coordinate space.
    static func frame(for placement: StampPlacement, kind: AchievementKind, faceSize: CGSize) -> CGRect {
        let side = stampSize(faceWidth: faceSize.width, kind: kind)
        return CGRect(
            x: placement.x * faceSize.width - side / 2,
            y: placement.y * faceSize.height - side / 2,
            width: side,
            height: side
        )
    }

    /// Whether a stamp centered at `point` (face coordinates) would land on
    /// the card clear of every protected zone. Hanging off the card's edge is
    /// fine: the face clips it, like a stamp pressed half off the paper.
    static func isValid(center point: CGPoint, kind: AchievementKind, faceSize: CGSize, protectedZones: [CGRect]) -> Bool {
        guard CGRect(origin: .zero, size: faceSize).contains(point) else { return false }
        let side = stampSize(faceWidth: faceSize.width, kind: kind)
        let rect = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        for zone in protectedZones where rect.intersects(zone.insetBy(dx: -zoneInset, dy: -zoneInset)) {
            return false
        }
        return true
    }
}

// MARK: - Stamp image

/// One stamp's art. Assets are transparent PNGs; a missing asset (a stamp
/// added before its art landed) draws a labeled ring so nothing renders blank.
struct StampImage: View {
    let kind: AchievementKind

    var body: some View {
        if UIImage(named: kind.assetName) != nil {
            Image(kind.assetName)
                .resizable()
                .scaledToFit()
        } else {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                ZStack {
                    Circle().strokeBorder(Theme.textPrimary, lineWidth: side * 0.05)
                    Text(kind.title.uppercased())
                        .font(.system(size: side * 0.12, weight: .heavy))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(side * 0.14)
                }
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Printed stamps

/// Every stamp pressed on `side`, drawn at its stored position. Overlaid on a
/// card face; the face's own size is what the fractions are measured against.
struct CardStampsLayer: View {
    let stamps: [AchievementStamp]
    let side: StampPlacement.Side
    /// Draw this stamp faded (the stamping screen lifts it while re-placing).
    var liftedKind: AchievementKind? = nil

    var body: some View {
        GeometryReader { proxy in
            ForEach(stamps.filter { $0.placement?.side == side }) { stamp in
                if let placement = stamp.placement {
                    let frame = CardStampGeometry.frame(for: placement, kind: stamp.kind, faceSize: proxy.size)
                    StampImage(kind: stamp.kind)
                        .frame(width: frame.width, height: frame.height)
                        .rotationEffect(.degrees(placement.rotation))
                        .opacity(liftedKind == stamp.kind ? 0.25 : CardStampGeometry.inkOpacity)
                        .position(x: frame.midX, y: frame.midY)
                        .accessibilityLabel("\(stamp.kind.title) stamp")
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Protected zones

/// A printed element on the front face, reported in the face's coordinate
/// space so the stamping screen can shade it and refuse stamps over it.
struct CardZone: Equatable {
    let name: String
    let rect: CGRect
    /// Shaded as a circle rather than a rounded rectangle (the photo).
    var circular: Bool = false
}

struct CardZonesPreferenceKey: PreferenceKey {
    static var defaultValue: [CardZone] = []
    static func reduce(value: inout [CardZone], nextValue: () -> [CardZone]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Marks this element as un-stampable. `inset` grows the reported rect
    /// (negative values) for things that overhang their frame, like the OG mark.
    func cardZone(_ name: String, inset: CGFloat = 0, circular: Bool = false) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CardZonesPreferenceKey.self,
                    value: [CardZone(
                        name: name,
                        rect: proxy.frame(in: .named(LibraryCardFace.coordinateSpace)).insetBy(dx: inset, dy: inset),
                        circular: circular
                    )]
                )
            }
        )
    }
}

/// Hatches the protected zones while stamping so the reader can see where a
/// stamp will not go. Diagonal lines read as "blocked"; a flat tint read as a
/// highlighted target.
struct CardProtectedZonesOverlay: View {
    let zones: [CardZone]
    let ink: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(zones, id: \.name) { zone in
                let rect = zone.rect.insetBy(dx: -CardStampGeometry.zoneInset, dy: -CardStampGeometry.zoneInset)
                let shape = zone.circular
                    ? AnyShape(Circle())
                    : AnyShape(RoundedRectangle(cornerRadius: 6))
                DiagonalHatch(spacing: 5)
                    .stroke(ink.opacity(0.4), lineWidth: 1)
                    .clipShape(shape)
                    .overlay(shape.stroke(ink.opacity(0.4), lineWidth: 1))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Parallel 45-degree lines filling the rect.
private struct DiagonalHatch: Shape {
    let spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}

// MARK: - Bank tile

/// A stamp in the bank: art and name. Whether it is on the card is shown, not
/// said: a stamp already pressed is faded with a check badge. Pass
/// `locked` for a stamp not yet earned: the art shows through a blur under a
/// lock, enough to want it, not enough to see it.
/// A locked stamp tapped in the bank: a short sheet that names the stamp,
/// shows it blurred under its lock the way the tile does, and says what it
/// takes. Hugs its content like the other nudge sheets.
struct LockedStampExplainerSheet: View {
    let kind: AchievementKind
    let onDismiss: () -> Void

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 22) {
            Text(kind.title)
                .font(Theme.title2())
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            ZStack {
                StampImage(kind: kind)
                    .frame(width: 120, height: 120)
                    .blur(radius: 4)
                    .opacity(0.55)
                    .saturation(0.35)
                Image(systemName: "lock.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Theme.textTertiary.opacity(0.25), lineWidth: 1)
            )
            .accessibilityHidden(true)

            Text(kind.howToUnlock)
                .font(Theme.body())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Got it", action: onDismiss)
                .buttonStyle(.spinePrimary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height + proxy.safeAreaInsets.bottom
        } action: { contentHeight = $0 }
        .presentationDetents(contentHeight > 0 ? [.height(contentHeight)] : [.medium])
        .presentationDragIndicator(.visible)
    }
}

struct StampBankTile: View {
    let kind: AchievementKind
    var isPlaced: Bool = false
    var isSelected: Bool = false
    var locked: Bool = false

    init(stamp: AchievementStamp, isSelected: Bool = false) {
        self.kind = stamp.kind
        self.isPlaced = stamp.isPlaced
        self.isSelected = isSelected
        self.locked = false
    }

    init(locked kind: AchievementKind) {
        self.kind = kind
        self.locked = true
    }

    private var status: String {
        if locked { return "Locked" }
        return isPlaced ? "On your card" : "Not stamped yet"
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                StampImage(kind: kind)
                    .frame(width: 64, height: 64)
                    .blur(radius: locked ? 2.5 : 0)
                    .opacity(locked ? 0.55 : (isPlaced ? 0.45 : 1))
                    .saturation(locked ? 0.35 : 1)
                if isPlaced {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.onChrome, Theme.chrome)
                        .offset(x: 4, y: 4)
                }
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 64, height: 64)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Theme.chrome : Theme.textTertiary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            )
            Text(kind.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(locked ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1)
        }
        .frame(width: 96)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.title), \(status.lowercased())")
    }
}
