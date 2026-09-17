# Import books into SPINE Firestore

One-time script to add books from `books.json` to the **wellread** Firestore database under your user.

## Prerequisites

1. **Firebase service account key**  
   Firebase Console → Project Settings → Service Accounts → Generate new private key.  
   Save the JSON file as `service-account.json` in this folder (it is gitignored).

2. **Google Books API key**  
   Same key you use in the app, or create one in Google Cloud Console for the Books API.

3. **Your Firebase Auth UID**  
   Firebase Console → Authentication → Users → your user (@tannerflake) → copy the **User UID**.

## Run

```bash
cd scripts/import-books
npm install
FIREBASE_UID="your-uid" GOOGLE_BOOKS_API_KEY="your-key" node import.js
```

Each row in `books.json` is looked up by ISBN via Google Books API; a `books` document and a `userBooks` document (status **Read**, rating 1–10) are created. If an ISBN isn’t found, the script falls back to the title/author from the JSON.
