# SPINE iOS

A modern, minimal book tracking app — dark-first, SwiftUI, designed to replace Goodreads.

## Requirements

- Xcode 15+ (iOS 17+)
- macOS for building and running the simulator

## Open and Run

1. Open `SPINE.xcodeproj` in Xcode.
2. In **Signing & Capabilities**, select your **Team** (required for running on device/simulator).
3. Choose a simulator or device and press **Run** (⌘R).

### Secrets & test account (optional)

- Copy `Secrets.example.plist` to `Secrets.plist` **in the repo root** (`Secrets.plist` is gitignored).
  The root `Secrets.plist` is the only one registered in the app target's Copy Resources phase, so it is the only one that gets bundled. A `Secrets.plist` placed in `SPINE/` is silently ignored at runtime, and missing keys fail quietly (the Gemini tier just falls through to Claude).
- Add API keys and, for a **dev-only test login**, create an **Email/Password** user in Firebase Authentication with your chosen email and password, then set:
  - `TEST_ACCOUNT_EMAIL`
  - `TEST_ACCOUNT_PASSWORD`
- On the **login / welcome** screen, tap the **book icon 5 times** to sign in with that account (no sheet). Long-press the book (2s) still opens the reviewer email/password sheet.

## MVP Features

- **Onboarding** — Welcome → username → reading goal (demo mode skips to main app).
- **Add book** — Search via Google Books API, set status (Want to Read / Currently Reading / Read), optional rating (1–10) and review.
- **Library** — Segmented by All / Read / Currently Reading / Want to Read. View modes: Grid, Timeline, Rating, Tier List (S/A/B/C/D with context menu to move).
- **Feed** — Placeholder feed with post layout (user, book, caption, like/comment).
- **Discover** — “Generate My Next 5 Reads” (uses your read history + Google Books search); Trending from your reads.
- **Profile** — Avatar, username, bio, followers/following, total books/pages, reading goal progress, recent reads. Sign out in menu.

## Design

- **Theme**: Deep indigo primary, soft green accent, near-black background (see `Theme/Theme.swift`).
- **Navigation**: Bottom tab bar — Feed, Discover, **Add** (center), Library, Profile.

## Tech Stack

- **Swift** + **SwiftUI**
- **Google Books API** for search and metadata (no API key required for basic search)
- In-memory state for MVP (`AppState`); ready to plug in **Firebase** (Auth, Firestore, Storage) and **OpenAI** for richer AI suggestions

## Next Steps (from spec)

1. Add Firebase Auth (email + Apple Sign In) and Firestore for persistence.
2. Add OpenAI-backed “Generate My Next 5 Reads” with reasons and difficulty/length.
3. Goodreads CSV import.
4. Notifications (likes, comments, recommendations, follows).
5. Shareable assets (tier list image, monthly/year recap).

## License

Private / use as you like.
