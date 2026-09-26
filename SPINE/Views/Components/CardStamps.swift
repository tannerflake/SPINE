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
    /// (about 326pt wide) that is a 95pt stamp; on the 306pt export, 89pt.
    static let widthFraction: CGFloat = 0.29

    /// Breathing room from the card's edge, in points, when placing.
    static let edgeInset: CGFloat = 8

    /// How far a stamp must stay from a printed element, in points.
    static let zoneInset: CGFloat = 4

    static func stampSize(faceWidth: CGFloat) -> CGFloat {
        (faceWidth * widthFraction).rounded()
    }

    /// The stamp's frame in the face's coordinate space.
    static func frame(for placement: StampPlacement, faceSize: CGSize) -> CGRect {
        let side = stampSize(faceWidth: faceSize.width)
        return CGRect(
            x: placement.x * faceSize.width - side / 2,
            y: placement.y * faceSize.height - side / 2,
            width: side,
            height: side
        )
    }

    /// Whether a stamp centered at `point` (face coordinates) would sit fully on
    /// the card and clear of every protected zone.
    static func isValid(center point: CGPoint, faceSize: CGSize, protectedZones: [CGRect]) -> Bool {
        let side = stampSize(faceWidth: faceSize.width)
        let rect = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        let bounds = CGRect(origin: .zero, size: faceSize).insetBy(dx: edgeInset, dy: edgeInset)
        guard bounds.contains(rect) else { return false }
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
                    let frame = CardStampGeometry.frame(for: placement, faceSize: proxy.size)
                    StampImage(kind: stamp.kind)
                        .frame(width: frame.width, height: frame.height)
                        .rotationEffect(.degrees(placement.rotation))
                        .opacity(liftedKind == stamp.kind ? 0.25 : 1)
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
    func cardZone(_ name: String, inset: CGFloat = 0) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CardZonesPreferenceKey.self,
                    value: [CardZone(
                        name: name,
                        rect: proxy.frame(in: .named(LibraryCardFace.coordinateSpace)).insetBy(dx: inset, dy: inset)
                    )]
                )
            }
        )
    }
}

/// Shades the protected zones while stamping so the reader can see where a
/// stamp will not go.
struct CardProtectedZonesOverlay: View {
    let zones: [CardZone]
    let ink: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(zones, id: \.name) { zone in
                let rect = zone.rect.insetBy(dx: -CardStampGeometry.zoneInset, dy: -CardStampGeometry.zoneInset)
                RoundedRectangle(cornerRadius: 8)
                    .fill(ink.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(ink.opacity(0.35))
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Bank tile

/// A stamp in the bank: art, name, and whether it is on the card. Pass
/// `locked` for a stamp not yet earned: the art shows through a blur under a
/// lock, enough to want it, not enough to see it.
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
            Text(status)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .frame(width: 96)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.title), \(status.lowercased())")
    }
}
