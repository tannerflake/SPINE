# Which Firestore database does the app use?

In **`SPINE/Info.plist`**, **`FirestoreDatabaseID`** controls this:

- **Empty string** (default in repo) → **`(default)`** Firestore database. Rules you edit under Firestore → **(default)** in the Console apply. This avoids “permissions” errors when rules were never published to a named DB.
- **`wellread`** (or any non-empty id) → **named** database with that id. You must open **that** database in the Console and publish **`firestore.rules`** there.

Security rules are **per database**. If the app points at `wellread` but you only deploy rules to `(default)`, you get **permission denied** everywhere.

## Older setups

If your data already lives in a **named** database (e.g. `wellread`), set:

```xml
<key>FirestoreDatabaseID</key>
<string>wellread</string>
```

## Deploy rules to `wellread`

1. Install [Firebase CLI](https://firebase.google.com/docs/cli) and run `firebase login`.
2. From the repo root (where `firebase.json` and `firestore.rules` live), link the project if needed: `firebase use <your-project-id>`.
3. Run:
   ```bash
   firebase deploy --only firestore:rules
   ```
   The included `firebase.json` targets the **`wellread`** database.

## Or: Firebase Console (manual)

1. Open **Firebase Console** → **Firestore Database**.
2. Use the **database picker** at the top and select **`wellread`** (not “(default)”).
3. Open the **Rules** tab.
4. Paste the contents of `firestore.rules` from this repo.
5. Click **Publish**.

If you pick the wrong database, handle checks and profile save will fail with `Missing or insufficient permissions`.
