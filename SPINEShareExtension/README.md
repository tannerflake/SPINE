# SPINE Share Extension

This folder contains the source for the **Share Extension** so users can share a Goodreads CSV from the share sheet into SPINE.

## Add the Share Extension target in Xcode

1. **File → New → Target**
2. Choose **iOS → Share Extension**, click Next.
3. **Product Name:** `SPINEShareExtension`  
   **Bundle ID:** `com.wellread.app.SPINEShareExtension` (or same base as main app + `.SPINEShareExtension`)  
   Uncheck "Include UI Extension" if you only want the minimal flow (no custom share UI).
4. Click Finish. Xcode will create a new target and a group with a default `ShareViewController.swift` and `Info.plist`.

5. **Replace the generated files with the ones in this folder:**
   - Replace the contents of `ShareViewController.swift` with this folder’s `ShareViewController.swift` (or add this folder’s file to the target and remove the generated one).
   - Replace the target’s **Info.plist** with this folder’s `Info.plist` (or copy the `NSExtension` and related keys into the target’s plist).
   - In the target’s **Signing & Capabilities**, add **App Groups** and use: `group.com.wellread.app` (same as the main app). You can use this folder’s `SPINEShareExtension.entitlements` as the entitlements file for the target.

6. **Main app:** Ensure the main app target has **App Groups** with `group.com.wellread.app` (already in `SPINE.entitlements`) and a **URL scheme** `wellread` (already in `Info.plist`).

7. **Embed the extension:** The main app target should have an “Embed Foundation Extensions” (or “Embed App Extensions”) build phase that embeds `SPINEShareExtension.appex`. Xcode usually adds this when you create the Share Extension target.

## Flow

1. User exports their library on Goodreads and gets a CSV (e.g. in Safari or Files).
2. User taps **Share** and chooses **SPINE** (or “Import to SPINE”) from the share sheet.
3. The extension copies the CSV into the app group and opens the main app with `spine://goodreads-import`.
4. The main app reads the CSV from the app group and presents the Goodreads import preview on the Profile tab; the user confirms and imports.

## Apple Developer

Create the App Group **group.com.wellread.app** in the Apple Developer portal (Identifiers → App Groups) and assign it to both the main app and the Share Extension app IDs.
