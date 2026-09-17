//
//  CircularPhotoCropView.swift
//  SPINE
//
//  “Move and Scale” crop screen for profile photos: circular window with a
//  rule-of-thirds grid; pinch to zoom, drag to reposition. Hands back a square
//  image cropped to what's visible inside the circle.
//

import SwiftUI
import UIKit

struct CircularPhotoCropView: View {
    let image: UIImage
    var onCancel: () -> Void
    var onCrop: (UIImage) -> Void

    /// Live gesture values; `steady*` are the committed values between gestures.
    @State private var zoom: CGFloat = 1
    @State private var steadyZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero

    /// Max pinch zoom relative to “image exactly fills the circle”.
    private let maxZoom: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let cropDiameter = max(1, min(geo.size.width, geo.size.height) - 64)
            let base = baseImageSize(cropDiameter: cropDiameter)

            ZStack {
                Color.black

                // The zoomed image must not drive the ZStack's layout size, or the
                // overlay circle drifts as you pinch — pin it inside a screen-sized
                // clipped frame so only its rendering (not layout) grows.
                Image(uiImage: image)
                    .resizable()
                    .frame(width: base.width * zoom, height: base.height * zoom)
                    .offset(offset)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                dimAndGrid(in: geo.size, cropDiameter: cropDiameter)
                    .allowsHitTesting(false)

                controls(base: base, cropDiameter: cropDiameter)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                dragGesture(base: base, cropDiameter: cropDiameter)
                    .simultaneously(with: zoomGesture(base: base, cropDiameter: cropDiameter))
            )
        }
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - Gestures

    private func dragGesture(base: CGSize, cropDiameter: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let proposed = CGSize(
                    width: steadyOffset.width + value.translation.width,
                    height: steadyOffset.height + value.translation.height
                )
                offset = clampedOffset(proposed, base: base, zoom: zoom, cropDiameter: cropDiameter)
            }
            .onEnded { _ in
                steadyOffset = offset
            }
    }

    private func zoomGesture(base: CGSize, cropDiameter: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newZoom = min(max(steadyZoom * value, 1), maxZoom)
                // Scale the offset with the zoom so the point under the circle's
                // center stays fixed — zooming magnifies the crop preview in place.
                let ratio = newZoom / max(steadyZoom, 0.001)
                zoom = newZoom
                let proposed = CGSize(
                    width: steadyOffset.width * ratio,
                    height: steadyOffset.height * ratio
                )
                offset = clampedOffset(proposed, base: base, zoom: newZoom, cropDiameter: cropDiameter)
            }
            .onEnded { _ in
                steadyZoom = zoom
                steadyOffset = offset
            }
    }

    /// Keeps the image covering the entire crop circle (no letterboxing inside it).
    private func clampedOffset(_ proposed: CGSize, base: CGSize, zoom: CGFloat, cropDiameter: CGFloat) -> CGSize {
        let maxX = max(0, (base.width * zoom - cropDiameter) / 2)
        let maxY = max(0, (base.height * zoom - cropDiameter) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    /// Size at zoom 1: aspect-fill so the shorter image edge spans the circle.
    private func baseImageSize(cropDiameter: CGFloat) -> CGSize {
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return CGSize(width: cropDiameter, height: cropDiameter) }
        let fill = cropDiameter / min(w, h)
        return CGSize(width: w * fill, height: h * fill)
    }

    // MARK: - Overlay

    private func dimAndGrid(in size: CGSize, cropDiameter: CGFloat) -> some View {
        let circleRect = CGRect(
            x: (size.width - cropDiameter) / 2,
            y: (size.height - cropDiameter) / 2,
            width: cropDiameter,
            height: cropDiameter
        )
        return ZStack {
            // Dim everything outside the circle (even–odd fill leaves a clear hole).
            // Rect is oversized so the dim reaches under the notch / home indicator.
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size).insetBy(dx: -200, dy: -200))
                p.addEllipse(in: circleRect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

            gridLines
                .frame(width: cropDiameter, height: cropDiameter)
                .clipShape(Circle())
                .position(x: circleRect.midX, y: circleRect.midY)

            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
                .frame(width: cropDiameter, height: cropDiameter)
                .position(x: circleRect.midX, y: circleRect.midY)
        }
    }

    private var gridLines: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            Path { p in
                for f in [1.0 / 3.0, 2.0 / 3.0] {
                    p.move(to: CGPoint(x: w * f, y: 0))
                    p.addLine(to: CGPoint(x: w * f, y: h))
                    p.move(to: CGPoint(x: 0, y: h * f))
                    p.addLine(to: CGPoint(x: w, y: h * f))
                }
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 0.5)
        }
    }

    private func controls(base: CGSize, cropDiameter: CGFloat) -> some View {
        VStack {
            Text("Move and Scale")
                .font(Theme.headline())
                .foregroundStyle(.white)
                .padding(.top, 16)
            Spacer()
            HStack {
                Button("Cancel", action: onCancel)
                    .font(Theme.body())
                    .foregroundStyle(.white)
                Spacer()
                Button("Choose") {
                    onCrop(croppedImage(cropDiameter: cropDiameter))
                }
                .font(Theme.headline())
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Crop

    /// Crops the source image (full resolution) to the square visible in the circle.
    private func croppedImage(cropDiameter: CGFloat) -> UIImage {
        let normalized = image.cropOrientationNormalized()
        let pxW = normalized.size.width
        let pxH = normalized.size.height
        guard pxW > 0, pxH > 0 else { return image }

        // On-screen points per image pixel at the current zoom.
        let s = (cropDiameter * zoom) / min(pxW, pxH)
        let side = cropDiameter / s
        let centerX = pxW / 2 - offset.width / s
        let centerY = pxH / 2 - offset.height / s
        var rect = CGRect(x: centerX - side / 2, y: centerY - side / 2, width: side, height: side)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: pxW, height: pxH))

        guard !rect.isNull, rect.width >= 1, rect.height >= 1,
              let cg = normalized.cgImage?.cropping(to: rect) else {
            return normalized
        }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}

private extension UIImage {
    /// Re-renders at full pixel size with orientation baked in, so `cgImage`
    /// pixel coordinates match what's displayed (camera portrait shots are
    /// stored as rotated landscape bitmaps + an orientation flag).
    func cropOrientationNormalized() -> UIImage {
        if imageOrientation == .up, scale == 1 { return self }
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }
}
