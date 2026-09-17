//
//  ProfilePhotoNudgeModal.swift
//  SPINE
//
//  Launch reminder for signed-in users without a profile photo — pick, crop,
//  and upload without leaving the modal. Shown until dismissed 4 times.
//

import PhotosUI
import SwiftUI
import UIKit

/// Identifiable wrapper so a freshly picked photo can drive a `fullScreenCover(item:)` crop step.
private struct PendingCropPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ProfilePhotoNudgeModal: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject private var appState: AppState

    /// Photo uploaded successfully — close without counting a dismissal.
    let onPhotoAdded: () -> Void
    let onNotNow: () -> Void

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoPendingCrop: PendingCropPhoto?
    @State private var showPhotoPicker = false
    @State private var isUploadingPhoto = false
    @State private var photoUploadError: String?
    /// Measured content height (plus the bottom safe area) so the sheet detent hugs the
    /// content instead of stretching to a half-screen `.medium`.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("Add a profile photo")
                .font(Theme.title2())
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Theme.accent, Theme.textSecondary)
                Text("SPINE is more fun with a profile pic!")
                    .font(Theme.body())
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                Button {
                    showPhotoPicker = true
                } label: {
                    if isUploadingPhoto {
                        ProgressView()
                            .tint(Theme.onChrome)
                    } else {
                        Label("Choose a photo", systemImage: "photo.on.rectangle")
                    }
                }
                .buttonStyle(.spinePrimary)
                .disabled(isUploadingPhoto)

                Button("Later", action: onNotNow)
                    .buttonStyle(.spineTertiary)
                .disabled(isUploadingPhoto)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height + proxy.safeAreaInsets.bottom
        } action: { contentHeight = $0 }
        .presentationDetents(contentHeight > 0 ? [.height(contentHeight)] : [.medium])
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared())
        .onChange(of: selectedPhotoItem) { _, newItem in
            showPhotoPicker = false
            guard let item = newItem else { return }
            Task {
                let image = await Self.loadUIImage(from: item)
                await MainActor.run {
                    selectedPhotoItem = nil
                }
                guard let image else {
                    await MainActor.run { photoUploadError = "Could not load image. Try another photo." }
                    return
                }
                await MainActor.run { photoPendingCrop = PendingCropPhoto(image: image) }
            }
        }
        .fullScreenCover(item: $photoPendingCrop) { pending in
            CircularPhotoCropView(image: pending.image) {
                photoPendingCrop = nil
            } onCrop: { cropped in
                photoPendingCrop = nil
                Task { await uploadProfileImage(cropped) }
            }
        }
        .alert("Photo", isPresented: Binding(
            get: { photoUploadError != nil },
            set: { if !$0 { photoUploadError = nil } }
        )) {
            Button("OK", role: .cancel) { photoUploadError = nil }
        } message: {
            Text(photoUploadError ?? "")
        }
    }

    private static func loadUIImage(from item: PhotosPickerItem) async -> UIImage? {
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            return image
        }
        guard let url = try? await item.loadTransferable(type: URL.self) else { return nil }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            return image
        }
        if FileManager.default.fileExists(atPath: url.path) {
            return UIImage(contentsOfFile: url.path)
        }
        return nil
    }

    private func uploadProfileImage(_ image: UIImage) async {
        guard let uid = authService.firebaseUser?.uid else { return }
        await MainActor.run {
            isUploadingPhoto = true
            photoUploadError = nil
        }
        do {
            let urlString = try await ProfilePhotoService.uploadProfilePhoto(uid: uid, image: image)
            let cacheBust = "\(urlString.contains("?") ? "&" : "?")t=\(Int(Date().timeIntervalSince1970))"
            let fullURLString = urlString + cacheBust
            if let profileURL = URL(string: fullURLString) {
                ProfileImageCache.shared.store(image, for: profileURL)
            }
            try await UserRepository().updateProfileImageURL(uid: uid, url: fullURLString)
            await authService.refreshAppUser()
            await MainActor.run {
                appState.currentUser = authService.appUser
                isUploadingPhoto = false
                photoUploadError = nil
                onPhotoAdded()
            }
        } catch {
            await MainActor.run {
                photoUploadError = error.localizedDescription
                isUploadingPhoto = false
            }
        }
    }
}
