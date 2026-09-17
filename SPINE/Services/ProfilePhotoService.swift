//
//  ProfilePhotoService.swift
//  SPINE
//
//  Uploads profile photos to Firebase Storage: downscales large picks, then JPEG-compresses before upload.
//

import FirebaseStorage
import UIKit

enum ProfilePhotoService {
    private static let profilePrefix = "profile_photos"
    /// Longest edge in **pixels**; larger images are scaled down (saves Storage + bandwidth). Profile avatars don’t need full camera resolution.
    private static let maxPixelDimension: CGFloat = 1024
    /// JPEG quality (0…1). Moderate compression — not so low that faces look mushy.
    private static let jpegCompressionQuality: CGFloat = 0.78

    /// Uploads image data to Storage at `profile_photos/{uid}.jpg`, returns the download URL.
    static func uploadProfilePhoto(uid: String, imageData: Data) async throws -> String {
        guard !imageData.isEmpty else {
            throw NSError(
                domain: "ProfilePhotoService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Image data was empty. Try another photo."]
            )
        }
        let ref = Storage.storage().reference().child("\(profilePrefix)/\(uid).jpg")
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        _ = try await ref.putDataAsync(imageData, metadata: metadata)
        return try await downloadURL(after: ref)
    }

    /// Convenience: resize if needed, then JPEG-compress and upload (e.g. from PhotosPicker).
    static func uploadProfilePhoto(uid: String, image: UIImage) async throws -> String {
        let prepared = imagePreparedForUpload(image)
        guard let data = prepared.jpegData(compressionQuality: jpegCompressionQuality) else {
            throw NSError(
                domain: "ProfilePhotoService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode image as JPEG"]
            )
        }
        return try await uploadProfilePhoto(uid: uid, imageData: data)
    }

    /// Downscales so the longest edge is at most `maxPixelDimension` pixels (aspect ratio preserved).
    /// Uses `UIImage.size` × `scale`, not `cgImage` dimensions — raw bitmap size ignores `imageOrientation`,
    /// which would distort photos from the camera/Photos (e.g. portrait shots stored as landscape pixels + rotation).
    private static func imagePreparedForUpload(_ image: UIImage) -> UIImage {
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let maxSide = max(pixelW, pixelH)
        guard maxSide > maxPixelDimension, maxSide > 0 else { return image }

        let downscale = maxPixelDimension / maxSide
        let newW = floor(pixelW * downscale)
        let newH = floor(pixelH * downscale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: newW, height: newH), format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: newW, height: newH))
        }
    }

    private static func downloadURL(after ref: StorageReference) async throws -> String {
        var lastError: Error?
        for attempt in 0 ..< 4 {
            do {
                return try await ref.downloadURL().absoluteString
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: UInt64(200_000_000 * (attempt + 1)))
            }
        }
        throw lastError ?? NSError(
            domain: "ProfilePhotoService",
            code: -3,
            userInfo: [NSLocalizedDescriptionKey: "Could not get download URL for profile photo."]
        )
    }
}
