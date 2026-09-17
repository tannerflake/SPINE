# SPINE iOS — Next Steps to Usable State

This document is a concrete roadmap for taking the SPINE MVP from “built but not wired” to a usable app: real backend, auth, Google Books, AI, tier list, and the rest of the spec.

---

## Current State vs. Target State


| Area                 | Current State                                     | Target State                                                                         |
| -------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------ |
| **Backend**          | In-memory only (`AppState`); no persistence       | Firebase (Firestore + optional Functions) for users, books, library, feed            |
| **Auth**             | Demo / placeholder; “Get started” loads mock user | Firebase Auth: email/password + Sign in with Apple                                   |
| **Google Books**     | Code exists but may be unused or unverified       | Wired and used for search + metadata; handle rate limits and errors                  |
| **AI suggestions**   | Placeholder (e.g. “popular books” or same search) | Real “Generate My Next 5 Reads” with reasons, difficulty, length (OpenAI or similar) |
| **Tier list**        | UI only; tiers not persisted                      | Tier list persisted per user, sync with backend, optional share-as-image             |
| **Feed**             | Static/mock posts                                 | Real feed from Firestore (friends’ activity, reviews, recommendations)               |
| **Profile**          | Demo user only                                    | Real profile from Firebase (avatar, stats, goal, followers)                          |
| **Goodreads import** | Not implemented                                   | Optional CSV upload → parse → map to UserBooks (with duplicate handling)             |


---

## Phase 1: Get the App Running Locally

**Goal:** Open in Xcode, build, run on simulator or device, and confirm the existing flows work.

1. **Restore or confirm project structure**
  - Ensure you have `SPINE.xcodeproj` and the `SPINE/` app target with all Swift files, `Info.plist`, and `Assets.xcassets`.
  - If the project was never committed, rebuild it from the spec (or from the same Cursor conversation that generated it).
2. **Xcode setup**
  - Open `SPINE.xcodeproj` in Xcode.
  - Select the **SPINE** target → **Signing & Capabilities**.
  - Choose your **Team** so the app can run on simulator or device.
  - Set **Bundle Identifier** (e.g. `com.yourname.wellread`) and confirm **Deployment Target** (e.g. iOS 17+).
3. **Run and smoke-test**
  - Run on an iPhone simulator (or device).
  - Walk through: onboarding (or “already have account” → demo), Add Book (search → add), Library (all segments and view modes), Feed, Discover, Profile.
  - Note what works and what’s clearly mock (e.g. “Add Book” saves only in memory and is lost on restart).

**Done when:** App builds, runs, and you can add a book and see it in Library until you kill the app.

---

## Phase 2: Firebase Project and iOS App

**Goal:** Create a Firebase project, add the iOS app, and get the SDK in the project. No auth or Firestore logic yet—just “connected.”

1. **Create Firebase project**
  - Go to [Firebase Console](https://console.firebase.google.com).
  - Create a project (e.g. “SPINE”).
  - Enable **Google Analytics** if you want it (optional for MVP).
2. **Add iOS app to the project**
  - In Project settings, add an **iOS app**.
  - Use the **Bundle ID** from Xcode (e.g. `com.yourname.wellread`).
  - Download **GoogleService-Info.plist** and add it to the SPINE target in Xcode (drag into the project, check “Copy items” and the SPINE target).
3. **Add Firebase SDK via Swift Package Manager**
  - In Xcode: **File → Add Package Dependencies**.
  - Use: `https://github.com/firebase/firebase-ios-sdk`.
  - Add at least: **FirebaseAuth**, **FirebaseFirestore**, **FirebaseStorage** (if you plan profile images). Pin a stable version (e.g. 10.x).
4. **Initialize Firebase in the app**
  - In `SpineApp.swift`, import Firebase and call `FirebaseApp.configure()` at app launch (before any Firebase usage).
  - Run again and confirm no crash; you can add a temporary `print` or breakpoint to confirm `FirebaseApp.app()` is non-nil.

**Done when:** App launches with Firebase configured and `GoogleService-Info.plist` in the target.

---

## Phase 3: Authentication (Firebase Auth)

**Goal:** Replace demo auth with real Firebase Auth (email + Apple).

1. **Enable auth methods in Firebase Console**
  - **Authentication → Sign-in method**: enable **Email/Password** and **Apple**.
2. **Apple Sign In (required if you offer it)**
  - In Xcode: SPINE target → **Signing & Capabilities** → **+ Capability** → **Sign in with Apple**.
  - In Firebase Console, Apple provider needs a Services ID and key (see Firebase docs for “Sign in with Apple” setup). Configure as needed for your Apple Developer account.
3. **Auth service in the app**
  - Create a dedicated **AuthService** (or equivalent) that:
    - Wraps `Auth.auth()` for: sign up (email/password), sign in, sign out, Apple sign in.
    - Exposes an `ObservableObject` or callbacks so the UI can react to auth state (e.g. `currentUser` or `authStateDidChange`).
  - On sign-in/sign-up success, fetch or create the **User** document in Firestore (see Phase 4) so the rest of the app has a consistent “current user” model.
4. **Wire UI to AuthService**
  - **RootView** (or equivalent): instead of toggling `isAuthenticated` from demo buttons, subscribe to Firebase Auth state (e.g. `Auth.auth().addStateDidChangeListener`). If user is nil → show onboarding/login; if user exists → load Firestore user and show main tabs.
  - **OnboardingFlowView**: replace “Get started” / “I already have an account” with:
    - Email/password sign up or sign in (email + password fields, buttons).
    - “Sign in with Apple” button that calls your AuthService.
  - **Profile**: “Sign out” should call AuthService sign-out and clear in-memory state; RootView will then show login again.
5. **Username and profile creation**
  - After first-time sign up (or Apple first sign-in), if Firestore has no User document for this `uid`, show a flow to choose **username** and optionally **display name** and **reading goal**. Write the User document (Phase 4) and then proceed to main app.

**Done when:** You can sign up with email, sign in, sign out, and (if configured) sign in with Apple; app shows main UI only when a signed-in user exists.

---

## Phase 4: Firestore Backend and Data Layer

**Goal:** Define collections, security rules, and app-side services so all core data is persisted and synced.

1. **Firestore collections (align with spec)**
  - **users** — document ID = Firebase Auth `uid`. Fields: username, displayName, bio, profileImageURL, joinedAt, followers[], following[], totalBooksRead, totalPagesRead, readingGoal.
  - **books** — document ID = Google Books ID (or generated ID). Fields: title, author, coverURL, pageCount, publishedDate, description, genres[]. (You can create/update when a user adds a book.)
  - **userBooks** — document ID = auto or UUID. Fields: userId, bookId, status, rating, reviewText, dateStarted, dateFinished, createdAt, updatedAt, recommendedTo[], **tier** (for tier list). Subcollection or top-level is fine; keep a query index for “all userBooks for userId” and “by status.”
  - **posts** — document ID = auto or UUID. Fields: userId, type (finishedBook | review | recommendation | tierListUpdate), bookId, caption, createdAt, likeCount, commentCount.
  - **comments** — document ID = auto. Fields: postId, userId, text, createdAt. Optionally support nested replies (e.g. parentCommentId).
2. **Security rules**
  - Users can read/write their own `users/{userId}`.
  - Users can read/write their own `userBooks` (where userId matches).
  - Books: read anyone; create/update when adding a book (or restrict to authenticated).
  - Posts: read for feed (e.g. posts from users you follow or public); create when userId == auth.uid; update for likeCount (or use a separate likes subcollection).
  - Comments: read with post; create when authenticated.
  - Write rules that forbid arbitrary overwrites (e.g. no writing another user’s userBooks).
3. **App-side services / repositories**
  - **UserRepository**: fetch current user by `uid`, update profile, update followers/following, increment totalBooksRead/totalPagesRead when appropriate.
  - **BookRepository**: get/create book by Google Books ID; ensure books are written to Firestore when a user adds a book so you can reuse them.
  - **UserBookRepository**: CRUD for userBooks; query by userId and status; update tier; support “add book” (create userBook), “update status/rating/review/dates,” “set tier.”
  - **PostRepository** (and **CommentRepository**): create post when user finishes a book or writes a review; fetch feed (e.g. posts ordered by createdAt, filtered by following); like, comment.
4. **Replace in-memory state with Firestore**
  - **AppState** (or equivalent) should:
    - Hold `currentUser` (from Firestore users collection).
    - Load **userBooks** from Firestore for the current user (and keep a local cache or real-time listener so the Library updates live).
    - Load **feedPosts** from Firestore (feed query) instead of a static list.
  - Add Book flow: after user selects book and status/rating, write to **books** (if new) and **userBooks**; optionally create a **post** when status is “read” or when they recommend. Then refresh or rely on listeners so the Library and Feed update.
5. **Optimistic UI and offline**
  - Use Firestore’s persistence (enable offline persistence) so reads work offline.
  - For “add book,” you can update UI optimistically and then write to Firestore; on failure, revert or show error.

**Done when:** Adding a book persists to Firestore; Library and Profile reflect real user data; Feed shows real posts (even if only your own at first).

---

## Phase 5: Google Books API (Wired and Robust)

**Goal:** Search and metadata come from Google Books; errors and edge cases handled.

1. **Confirm usage**
  - The app likely has a `GoogleBooksService` (or similar) that calls `https://www.googleapis.com/books/v1/volumes?q=...`. Ensure the **Add Book** flow uses this service for the search step and that results are displayed and selectable.
2. **API key (optional but recommended)**
  - Without a key you get a low quota. Create a key in [Google Cloud Console](https://console.cloud.google.com): APIs & Services → Credentials → Create API key. Restrict to “Books API” and optionally to your app (iOS bundle ID).
  - Add the key to the request: `...&key=YOUR_API_KEY`. Store the key in a config file or environment (e.g. `GoogleService-Info.plist` custom key, or a non-committed `Secrets.plist` that you add to .gitignore).
3. **Error handling and robustness**
  - Handle network errors (no connection, timeouts) and show a simple message or retry in the Add Book flow.
  - Handle empty or malformed responses (e.g. no `items`, or missing `volumeInfo`). Show “No results” or “Try different keywords.”
  - Normalize cover URLs (e.g. force https, or use a placeholder when missing).
  - Optionally cache recent search results in memory so repeated searches are instant.
4. **Mapping to your Book model**
  - Ensure the service maps `id`, `volumeInfo.title`, `volumeInfo.authors`, `imageLinks`, `pageCount`, `publishedDate`, `description`, `categories` into your app’s **Book** model so that when you save to Firestore you have a consistent structure.

**Done when:** Add Book search uses Google Books; results show covers and metadata; failures show a clear message; saving the selected book stores correct metadata in Firestore.

---

## Phase 6: AI Suggestions (“Generate My Next 5 Reads”)

**Goal:** “Generate My Next 5 Reads” uses real AI and returns titles with “why you’ll like it,” difficulty, length, genre.

1. **Backend vs client**
  - **Recommended:** Call an AI API from a **backend** (e.g. Firebase Functions or a small Node/Python service) so you never ship an API key in the app. Send the backend: user id or a summary of reading history (titles, authors, genres, ratings). Backend calls OpenAI (or similar) and returns 5 recommendations with structured fields.
2. **OpenAI (or alternative) integration**
  - If using **OpenAI**: backend uses the Chat Completions or similar API with a prompt that includes the user’s recent reads and asks for 5 recommendations with: title, author, why they’ll like it, difficulty, length, genre. Parse the response into a list of suggestions.
  - Store the API key only on the backend (e.g. Firebase Functions config or environment variables).
3. **Firebase Functions example**
  - Create an HTTPS callable function (e.g. `getAISuggestions`) that:
    - Takes optional payload (e.g. userId or list of recent book titles/genres).
    - Fetches user’s reading history from Firestore if needed.
    - Calls OpenAI, parses result, returns an array of recommendation objects.
  - From the app: call the function (e.g. `Functions.functions().httpsCallable("getAISuggestions")`) and show the result in the Discover tab.
4. **Discover tab UI**
  - “Generate My Next 5 Reads” button triggers the function call; show loading state; then display the 5 items with: cover (from Google Books if you look up by title), title, author, “Why you’ll like it,” difficulty, length, genre. Buttons: “Add to Want to Read” (creates a userBook), “Dismiss,” “Save” (e.g. save to a “saved suggestions” list in Firestore if you want).

**Done when:** Tapping “Generate My Next 5 Reads” returns 5 real AI-generated recommendations with the promised fields; user can add one to Want to Read.

---

## Phase 7: Tier List (Fully Functional and Persisted)

**Goal:** Tier list is not just UI—tiers are saved and synced; optional share-as-image.

1. **Persistence**
  - **userBooks** already has a `tier` field (S, A, B, C, D, or null). When the user moves a book between tiers (via context menu or drag-and-drop), call **UserBookRepository** to update that userBook’s `tier` in Firestore. AppState/listeners will refresh the Library so the Tier List view shows the correct buckets.
2. **Tier list UI behavior**
  - Ensure the Tier List view only shows **read** books (as in the spec). Unranked = books with no tier or tier null. Dragging or “Move to X” should update the tier and persist.
  - If you have drag-and-drop: on drop, compute the new tier from the drop target and persist. If you only have context menu for now, that’s enough for “usable.”
3. **Share as image (optional but in spec)**
  - Render the tier list (S, A, B, C, D, Unranked + book covers) into a `UIImage` (e.g. using SwiftUI’s `ImageRenderer` or snapshot a hidden view). Add SPINE branding (logo or text). Present share sheet (UIActivityViewController) so the user can save or share the image.

**Done when:** Moving a book to a tier persists to Firestore and survives app restart; Tier List view always reflects saved tiers; optionally user can share the tier list as an image.

---

## Phase 8: Feed, Profile, and Social Basics

**Goal:** Feed is real; profile is real; basic follow and recommendations work.

1. **Feed**
  - Feed query: posts from users the current user follows (or “all public” for MVP). Order by `createdAt` descending. Listen for real-time updates so new posts appear.
  - When a user marks a book “Read” and optionally writes a review or recommends to friends, create a **post** (type: finishedBook, review, or recommendation). Notifications (Phase 9) can reference these posts.
2. **Profile**
  - Profile tab shows the **current user** from Firestore (avatar, username, bio, followers, following, totalBooksRead, totalPagesRead, reading goal progress). Stats should be derived from real userBooks (or kept in sync when adding/finishing books). “Recent reads” = recent userBooks with status “read.”
3. **Recommend to friends**
  - When marking a book “Read,” allow multi-select of friends (from following or a “friends” list). On save: create a **post** (recommendation) and/or write to a **notifications** collection for each recommended user (“Tanner recommended Atomic Habits to you”). Store `recommendedTo` on the userBook if you want it for display.
4. **Follow/followers**
  - Add UI to follow/unfollow (update `following` / `followers` in Firestore). Profile and Feed use these lists for “following” and for the feed query.

**Done when:** Feed shows real posts from you (and from others you follow if implemented); profile shows real stats; you can recommend a book to a friend and they see it (in feed or notifications).

---

## Phase 9: Notifications (Meaningful Only)

**Goal:** Users get notified for likes, comments, recommendations, follows, and optionally reading goal milestones.

1. **Notification payload and storage**
  - Create a **notifications** collection (or subcollection under users). Each document: forUserId, type (like | comment | recommendation | follow | goalMilestone), fromUserId, postId?, bookId?, text/copy, createdAt, read (boolean).
  - When someone likes a post, comments, recommends a book to you, or follows you, write a notification document for the target user. For “reading goal milestone,” write when totalBooksRead hits the goal (e.g. in a Cloud Function or when you update the user doc).
2. **FCM and APNs**
  - Enable **Cloud Messaging** (FCM) in Firebase and add **Push Notifications** capability in Xcode. Upload APNs key or cert to Firebase. Send device token to Firestore (e.g. in a user document or a dedicated tokens collection).
3. **Sending notifications**
  - Option A: Firebase Cloud Functions triggered when a notification document is created; function calls FCM to send a push to the target user’s device(s).
  - Option B: Client-side “pull” — a Notifications tab that lists unread notifications and marks them read. Push can be added later.
4. **In-app copy**
  - Use the spec’s copy where possible, e.g. “Tanner recommended Atomic Habits to you.”

**Done when:** At least one notification type (e.g. recommendation or like) creates a document and either sends a push or appears in an in-app list.

---

## Phase 10: Goodreads Import (Optional)

**Goal:** User can upload a Goodreads CSV; backend parses and creates UserBooks; duplicates handled.

1. **CSV format**
  - Goodreads export includes: Title, Author, Date Read, Rating, Shelf, etc. Look up the exact columns from Goodreads export.
2. **Upload flow**
  - In onboarding or in Profile/Settings, add “Import from Goodreads.” User picks a file (document picker or share extension). Send file to a **Firebase Function** (or parse in the app and then batch-write to Firestore). Prefer backend parsing so you can handle large files and rate limits.
3. **Parsing and mapping**
  - Parse CSV; for each row: map title, author, date read, rating, shelf to your UserBook model (and Book if needed). Use Google Books API to resolve title+author to a book ID and cover if you want consistency. Create userBook documents; set status from “shelf” (e.g. “read” → read, “currently-reading” → currentlyReading, “to-read” → wantToRead).
4. **Duplicates**
  - Before creating a userBook, check if the user already has a userBook for the same bookId (or same title+author). Skip or merge (e.g. keep higher rating, merge dates). Optionally show “Imported X books; Y skipped as duplicates.”

**Done when:** User can upload a Goodreads CSV and see imported books in Library with correct status and rating; duplicates are skipped or merged.

---

## Phase 11: Polish and Non-Functional Requirements

**Goal:** App feels fast, works offline where possible, and matches the design system.

1. **Performance**
  - Book search: debounce input so you don’t hit Google Books on every keystroke; show loading state. Cache recent search results in memory.
  - Feed/Library: use Firestore listeners efficiently (e.g. limit query size, paginate if needed). Avoid loading huge lists at once.
2. **Optimistic UI**
  - When adding a book or updating tier, update the UI immediately; revert and show error if the Firestore write fails.
3. **Offline**
  - Firestore persistence is on by default for iOS. Ensure critical reads (user profile, userBooks) work from cache when offline; show a subtle “offline” indicator if you want.
4. **Dark mode**
  - App is dark-first; ensure all screens use Theme colors and don’t assume light mode.
5. **Accessibility**
  - Add labels for important buttons and images (e.g. book covers, “Add to Want to Read”). Support Dynamic Type where it makes sense.

**Done when:** Add book and tier list feel instant; app works with no network for already-loaded data; no obvious UI bugs in dark theme.

---

## Suggested Order of Work

Do them in this order to minimize rework and get to “usable” quickly:

1. **Phase 1** — Run locally.
2. **Phase 2** — Firebase project + SDK + init.
3. **Phase 3** — Auth (email + Apple); wire RootView and onboarding.
4. **Phase 4** — Firestore collections, rules, repositories; replace in-memory state.
5. **Phase 5** — Google Books wired and robust in Add Book.
6. **Phase 7** — Tier list persisted (tier field + UI updating from Firestore).
7. **Phase 6** — AI suggestions (backend + Discover UI).
8. **Phase 8** — Feed and profile real; recommend-to-friends and follow.
9. **Phase 9** — Notifications (at least one type).
10. **Phase 10** — Goodreads import (optional).
11. **Phase 11** — Polish and NFRs.

---

## Quick Reference: What You Need


| Item                     | Where / How                                                                              |
| ------------------------ | ---------------------------------------------------------------------------------------- |
| Firebase project         | [Firebase Console](https://console.firebase.google.com)                                  |
| GoogleService-Info.plist | Firebase project → iOS app → download                                                    |
| Firebase SDK             | Swift Package: `firebase-ios-sdk` (Auth, Firestore, Storage, Functions)                  |
| Google Books API key     | [Google Cloud Console](https://console.cloud.google.com) → APIs & Services → Credentials |
| OpenAI API key           | [OpenAI](https://platform.openai.com) → API keys (use only on backend)                   |
| Apple Developer          | Sign in with Apple + App ID + capabilities                                               |
| Firestore indexes        | Create when you hit “index required” in console or logs                                  |


---

## Definition of “Usable” (Recap)

- Real sign-up/sign-in and sign-out.
- Add book via Google Books search; data persists in Firestore.
- Library shows your real books; Tier List saves and syncs.
- “Generate My Next 5 Reads” returns real AI suggestions; you can add one to Want to Read.
- Feed shows real posts; profile shows real stats and goal.
- At least one meaningful notification works (e.g. “X recommended Y to you”).

Once these are done, you have a usable MVP. Then you can add Goodreads import, shareable tier list images, and monetization (e.g. premium AI or themes) as in the spec.