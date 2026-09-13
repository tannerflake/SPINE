import { createHash } from "crypto";
import { initializeApp, getApps } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { onDocumentCreated, onDocumentUpdated, onDocumentWritten } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import type { DocumentData, Firestore } from "firebase-admin/firestore";

const app = getApps().length ? getApps()[0]! : initializeApp();
const db: Firestore = getFirestore(app, "wellread");
const messaging = getMessaging(app);

const DATABASE_ID = "wellread";

function firstNameFromUser(data: DocumentData | undefined): string {
  if (!data) return "Someone";
  const fn = (data.firstName as string | undefined)?.trim();
  if (fn && fn.length > 0) return fn;
  const dn = (data.displayName as string | undefined)?.trim() ?? "";
  if (dn.length === 0) return "Someone";
  return dn.split(/\s+/)[0] ?? "Someone";
}

/** Null when the post has no usable rating (e.g. marked read without ranking). */
function formatRating(r: unknown): string | null {
  if (typeof r === "number" && Number.isFinite(r)) return r.toFixed(1);
  if (typeof r === "string") {
    const n = parseFloat(r);
    if (Number.isFinite(n)) return n.toFixed(1);
  }
  return null;
}

/** First ~8 words; ellipsis if more remains in source. */
function teaser8Words(text: string): string {
  const t = text.trim().replace(/\s+/g, " ");
  if (!t) return "";
  const words = t.split(/\s+/);
  const head = words.slice(0, 8).join(" ");
  if (words.length <= 8) return head;
  return `${head}...`;
}

/** Teaser wrapped in quotes for a push body, or "" when there is nothing to quote. */
function quotedTeaser(text: string): string {
  const t = teaser8Words(text);
  return t ? `“${t}”` : "";
}

/**
 * Leading glyph per notification type. Titles get cut to ~18 characters in the
 * stacked Notification Center view, so the emoji carries the event type even when
 * the words after the name are gone. Applied once in notifyUser so the push and
 * the bell-feed row match.
 */
const TITLE_EMOJI: Record<string, string> = {
  friend_review_posted: "⭐",
  review_liked: "❤️",
  comment_liked: "❤️",
  review_commented: "💬",
  thread_commented: "💬",
  comment_replied: "↩️",
  review_mentioned: "📣",
  comment_mentioned: "📣",
  new_follower: "👋",
  contact_joined: "🎉",
  blend_request: "🔀",
  blend_ready: "🔀",
  book_recommended: "📖",
  club_added: "📚",
  club_member_joined: "👋",
  club_new_book: "📖",
  club_meeting_moved: "📅",
  club_meeting_soon: "📅",
};

/** Unrated finishes share a type with rated reviews but read as a "book" event. */
const FINISHED_BOOK_EMOJI = "📚";
/** The founder's join alert reuses new_follower but is really a "joined" event. */
const JOINED_EMOJI = "🎉";

/** "On {book}: “teaser”" with graceful fallbacks when either half is missing. */
function bodyOnBook(book: string | null, teaser: string): string {
  if (book && teaser) return `On ${book}: ${teaser}`;
  if (book) return `On ${book}.`;
  return teaser;
}

function withEmoji(type: string, title: string, override?: string): string {
  const glyph = override ?? TITLE_EMOJI[type];
  return glyph ? `${glyph} ${title}` : title;
}

/** "@handle" tokens in text (lowercased, deduped) — each preceded by start-of-text
 * or whitespace so email addresses don't register as mentions. */
function mentionHandles(text: string): string[] {
  const out = new Set<string>();
  const re = /(^|\s)@([A-Za-z0-9._-]+)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    out.add(m[2]!.toLowerCase());
  }
  return [...out];
}

/**
 * Resolves @handles in `text` to uids: `handleClaims/{handle}` first (doc id =
 * lowercase handle), then a username query for accounts predating claims.
 * Unknown handles are dropped — plain "@aside" text never notifies anyone.
 * Capped at 10 mentions per text.
 */
async function resolveMentionUids(text: string): Promise<Map<string, string>> {
  const result = new Map<string, string>();
  for (const handle of mentionHandles(text).slice(0, 10)) {
    const claim = await db.collection("handleClaims").doc(handle).get();
    const claimUid = claim.data()?.uid as string | undefined;
    if (claimUid) {
      result.set(handle, claimUid);
      continue;
    }
    const q = await db.collection("users").where("username", "==", handle).limit(1).get();
    if (!q.empty) result.set(handle, q.docs[0]!.id);
  }
  return result;
}

/** APNs attachments require https; Google Books covers are often stored as http. */
function httpsUpgraded(url: string | null): string | null {
  if (!url) return null;
  if (url.startsWith("https://")) return url;
  if (url.startsWith("http://")) return `https://${url.slice("http://".length)}`;
  return null;
}

async function bookInfo(
  bookId: string | undefined
): Promise<{ title: string | null; coverURL: string | null }> {
  if (!bookId) return { title: null, coverURL: null };
  const snap = await db.collection("books").doc(bookId).get();
  const data = snap.data();
  const title = (data?.title as string | undefined)?.trim() || null;
  const coverURL = httpsUpgraded((data?.coverURL as string | undefined)?.trim() || null);
  return { title, coverURL };
}

async function tokensForUser(uid: string): Promise<string[]> {
  const snap = await db.collection("users").doc(uid).collection("fcmTokens").get();
  return snap.docs.map((d) => d.data().token as string).filter((t): t is string => typeof t === "string" && t.length > 0);
}

/**
 * Data-only background push (no alert, no sound) — wakes the app so it can
 * react, e.g. clearing a withdrawn blend invite from Notification Center.
 */
async function sendSilentToUser(uid: string, data: Record<string, string>): Promise<void> {
  const tokens = await tokensForUser(uid);
  if (!tokens.length) return;
  const messages = tokens.map((token) => ({
    token,
    data,
    apns: {
      headers: {
        "apns-push-type": "background",
        "apns-priority": "5",
      },
      payload: { aps: { "content-available": 1 } },
    },
  }));
  const resp = await messaging.sendEach(messages);
  logger.info("push sendSilentToUser", { uid, type: data.type, tokenCount: tokens.length, successCount: resp.successCount, failureCount: resp.failureCount });
}

async function sendToUser(
  uid: string,
  title: string,
  body: string,
  data: Record<string, string>,
  imageUrl?: string | null
): Promise<void> {
  const tokens = await tokensForUser(uid);
  if (!tokens.length) {
    logger.warn("push skipped: no FCM tokens for user", { uid });
    return;
  }
  // iOS often drops or mishandles alerts with an empty body; keep a short fallback.
  const bodyText = body.trim().length > 0 ? body.trim() : "Tap to open SPINE";
  // Book covers ride along as a rich-notification image: `fcmOptions.imageUrl` puts the URL in
  // the APNs payload and `mutableContent` routes it through the app's Notification Service
  // Extension, which downloads and attaches the thumbnail. `coverImageURL` in data is the
  // extension's fallback key.
  const dataPayload = imageUrl ? { ...data, coverImageURL: imageUrl } : data;
  const messages = tokens.map((token) => ({
    token,
    notification: { title, body: bodyText },
    data: dataPayload,
    apns: {
      payload: {
        aps: {
          alert: {
            title,
            body: bodyText,
          },
          sound: "default",
          ...(imageUrl ? { mutableContent: true } : {}),
        },
      },
      ...(imageUrl ? { fcmOptions: { imageUrl } } : {}),
    },
  }));
  const resp = await messaging.sendEach(messages);
  if (resp.failureCount > 0) {
    resp.responses.forEach((r, i) => {
      if (!r.success) {
        logger.error("FCM send failed", {
          uid,
          tokenPrefix: tokens[i]?.slice(0, 12),
          error: r.error?.message,
          code: r.error?.code,
        });
      }
    });
  }
  logger.info("push sendToUser", { uid, tokenCount: tokens.length, successCount: resp.successCount, failureCount: resp.failureCount });
}

/**
 * Persists an in-app notification at `users/{uid}/notifications/{autoId}` — the
 * feed behind the bell on the profile page. Written alongside every real push
 * (never for diagnostics pushes) so the feed mirrors what the user was alerted
 * about, including alerts they missed without push permission.
 */
async function writeNotification(
  uid: string,
  title: string,
  body: string,
  data: Record<string, string>,
  actorId: string | null,
  coverURL?: string | null
): Promise<void> {
  try {
    await db.collection("users").doc(uid).collection("notifications").add({
      ...data,
      title,
      body,
      ...(actorId ? { actorId } : {}),
      ...(coverURL ? { coverURL } : {}),
      read: false,
      createdAt: FieldValue.serverTimestamp(),
    });
  } catch (e) {
    logger.error("writeNotification failed", { uid, type: data.type, error: (e as Error).message });
  }
}

/** In-app notification doc + push alert in one call — the standard path for real events. */
async function notifyUser(
  uid: string,
  title: string,
  body: string,
  data: Record<string, string>,
  actorId: string | null,
  imageUrl?: string | null,
  emojiOverride?: string
): Promise<void> {
  const fullTitle = withEmoji(data.type ?? "", title, emojiOverride);
  await writeNotification(uid, fullTitle, body, data, actorId, imageUrl);
  await sendToUser(uid, fullTitle, body, data, imageUrl);
}

/** Fixed post id for diagnostics-only pushes (deep link may not resolve to a real post). */
const TEST_PUSH_POST_ID = "00000000-0000-4000-8000-000000000001";

/** Stable sample cover (Sapiens) so diagnostics pushes exercise the rich-notification path. */
const TEST_PUSH_COVER_URL = "https://covers.openlibrary.org/b/isbn/9780062316097-L.jpg";

const TEST_PUSH_TYPES = new Set([
  "friend_review_posted",
  "review_liked",
  "review_commented",
  "thread_commented",
  "new_follower",
]);

/**
 * Authenticated clients only: sends one sample notification of the given type to the caller’s uid
 * using stored FCM tokens (same path as production `sendToUser`).
 */
export const sendTestPushNotification = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Sign in required");
    }
    const uid = request.auth.uid;
    const raw = request.data as { type?: string } | undefined;
    const type = raw?.type;
    if (!type || !TEST_PUSH_TYPES.has(type)) {
      throw new HttpsError(
        "invalid-argument",
        "type must be one of: friend_review_posted, review_liked, review_commented, thread_commented, new_follower"
      );
    }

    const tokens = await tokensForUser(uid);
    if (!tokens.length) {
      throw new HttpsError(
        "failed-precondition",
        "No FCM tokens stored for this user. Use a physical device, allow notifications, and wait for the Firestore write."
      );
    }

    switch (type) {
      case "friend_review_posted":
        await sendToUser(
          uid,
          withEmoji("friend_review_posted", "Alex gave a 9.0"),
          "Sample Book: “Smart, ambitious, provocative, and way more readable than...”",
          { type: "friend_review_posted", postId: TEST_PUSH_POST_ID },
          TEST_PUSH_COVER_URL
        );
        break;
      case "review_liked":
        await sendToUser(
          uid,
          withEmoji("review_liked", "Alex liked your review"),
          "Your review of Sample Book.",
          { type: "review_liked", postId: TEST_PUSH_POST_ID },
          TEST_PUSH_COVER_URL
        );
        break;
      case "review_commented":
        await sendToUser(
          uid,
          withEmoji("review_commented", "Alex commented"),
          "On your review of Sample Book: “Great take on chapter three...”",
          { type: "review_commented", postId: TEST_PUSH_POST_ID }
        );
        break;
      case "thread_commented":
        await sendToUser(
          uid,
          withEmoji("thread_commented", "Alex also commented"),
          "In the Sample Book thread you joined: “Adding my two cents here...”",
          { type: "thread_commented", postId: TEST_PUSH_POST_ID }
        );
        break;
      case "new_follower":
        // followerId is the caller so the tap deep-links to a real profile (your own).
        await sendToUser(
          uid,
          withEmoji("new_follower", "Alex followed you"),
          "See what they're reading on SPINE.",
          { type: "new_follower", followerId: uid }
        );
        break;
      default:
        throw new HttpsError("invalid-argument", "Unknown type");
    }

    return { ok: true, sent: tokens.length, type };
  }
);

// MARK: Account deletion (App Store guideline 5.1.1(v))

/** Deletes every document matched by `query` in batches; returns count deleted. */
async function deleteByQuery(
  query: FirebaseFirestore.Query,
  batchSize = 300
): Promise<number> {
  let total = 0;
  for (;;) {
    const snap = await query.limit(batchSize).get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
    total += snap.size;
    if (snap.size < batchSize) break;
  }
  return total;
}

/**
 * Permanently deletes the caller's account: all Firestore data they own,
 * references to them in other users' following lists, and finally the
 * Firebase Auth user. Client signs out locally after this resolves.
 */
export const deleteAccount = onCall(
  { region: "us-central1" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in required");
    }
    logger.info("deleteAccount start", { uid });

    // Posts authored by the user, plus comments/likes attached to those posts.
    const postsSnap = await db.collection("posts").where("userId", "==", uid).get();
    for (const post of postsSnap.docs) {
      await deleteByQuery(db.collection("comments").where("postId", "==", post.id));
      await deleteByQuery(db.collection("postLikes").where("postId", "==", post.id));
      await post.ref.delete();
    }

    // Content the user created on other people's posts / shared state.
    await deleteByQuery(db.collection("comments").where("userId", "==", uid));
    await deleteByQuery(db.collection("postLikes").where("userId", "==", uid));
    await deleteByQuery(db.collection("userBooks").where("userId", "==", uid));
    await deleteByQuery(db.collection("recommendations").where("fromUserId", "==", uid));
    await deleteByQuery(db.collection("recommendations").where("toUserId", "==", uid));
    await deleteByQuery(db.collection("bookBlends").where("userIds", "array-contains", uid));
    await deleteByQuery(db.collection("dismissedSuggestions").where("userId", "==", uid));
    await deleteByQuery(db.collection("handleClaims").where("uid", "==", uid));

    // Remove the user from other members' following lists.
    const followersSnap = await db
      .collection("users")
      .where("following", "array-contains", uid)
      .get();
    for (const follower of followersSnap.docs) {
      await follower.ref.update({ following: FieldValue.arrayRemove(uid) });
    }

    // User doc + subcollections (fcmTokens etc.), then the Auth account itself.
    await db.recursiveDelete(db.collection("users").doc(uid));
    await getAuth(app).deleteUser(uid);

    logger.info("deleteAccount done", { uid });
    return { ok: true };
  }
);

/** Tanner's Firebase Auth uid (@tan). New accounts follow him by default (seeded client-side);
 * this side follows them back, since Firestore rules only let clients write their own doc. */
const FOUNDER_UID = "jCaSGxcYgHZd6OzXfxmGNn1GZBj2";

/** Accounts hidden app-wide except from specific viewers (mirrors `HiddenAccounts` in the iOS app).
 * Their activity must not generate pushes to anyone outside the allowlist. */
const HIDDEN_ACCOUNT_VIEWERS: Record<string, string[]> = {
  // tanner@tinyhealth.com test account (@tantest) — visible only to Tanner (tannerflake@gmail.com).
  lWfYPy4fOxdQYFUYEXAGnpvNscw2: [FOUNDER_UID],
};

/** False when `actorUid` is a hidden account and `recipientUid` isn't allowed to see it. */
function hiddenAccountCanNotify(actorUid: string, recipientUid: string): boolean {
  const allowed = HIDDEN_ACCOUNT_VIEWERS[actorUid];
  if (!allowed) return true;
  return recipientUid === actorUid || allowed.includes(recipientUid);
}

/**
 * New account created: the founder auto-follows the new member, and gets a push that
 * someone joined (the new doc is already seeded following him).
 */
export const onUserCreated = onDocumentCreated(
  {
    document: "users/{uid}",
    database: DATABASE_ID,
  },
  async (event) => {
    const uid = event.params.uid as string;
    if (!uid || uid === FOUNDER_UID) return;
    const first = firstNameFromUser(event.data?.data());
    try {
      await db.collection("users").doc(FOUNDER_UID).update({
        following: FieldValue.arrayUnion(uid),
      });
    } catch (e) {
      logger.error("founder auto-follow failed", { uid, error: (e as Error).message });
    }
    await notifyUser(
      FOUNDER_UID,
      `${first} joined SPINE`,
      "They follow you, and you now follow them back.",
      { type: "new_follower", followerId: uid },
      uid,
      null,
      JOINED_EMOJI
    );
  }
);

/**
 * A user's `following` array grew: push a new-follower alert to each newly-followed user.
 * (Follows are written client-side as arrayUnion on the follower's own doc, so an update
 * trigger diff is the only reliable hook. Unfollows stay silent.)
 */
export const onUserFollowingChanged = onDocumentUpdated(
  {
    document: "users/{uid}",
    database: DATABASE_ID,
  },
  async (event) => {
    const followerUid = event.params.uid as string;
    const before = (event.data?.before.data()?.following as string[] | undefined) ?? [];
    const after = (event.data?.after.data()?.following as string[] | undefined) ?? [];
    const beforeSet = new Set(before);
    const added = after.filter((t) => t && !beforeSet.has(t) && t !== followerUid);
    if (added.length === 0) return;
    // A bulk write (migration/backfill) should not fan out notifications.
    if (added.length > 10) {
      logger.warn("skipping new_follower fanout for bulk following update", {
        followerUid,
        addedCount: added.length,
      });
      return;
    }
    const follower = (await db.collection("users").doc(followerUid).get()).data();
    const first = firstNameFromUser(follower);
    for (const target of added.filter((t) => hiddenAccountCanNotify(followerUid, t))) {
      await notifyUser(
        target,
        `${first} followed you`,
        "See what they're reading on SPINE.",
        { type: "new_follower", followerId: followerUid },
        followerUid
      );
    }
  }
);

/** Days after joining that a member still counts as "just joined" for contact alerts. */
const CONTACT_JOIN_WINDOW_DAYS = 14;

/** Most contact matches one call may notify. A real address book match set is small. */
const CONTACT_JOIN_MAX_TARGETS = 50;

/**
 * A new member's device matched their address book against SPINE and found
 * these members. Notifies each of them that someone they know just joined.
 *
 * The address book itself never leaves the device (see ContactSyncService):
 * the client sends only the resulting SPINE uids, which is why this is a
 * callable rather than a Firestore trigger. The server has no contact data of
 * its own and could not derive this on its own.
 *
 * Guarded so it can only ever congratulate a genuinely new account, once per
 * pair: an existing member re-syncing contacts must not re-announce themselves.
 */
export const notifyContactsOfJoin = onCall(
  { region: "us-central1" },
  async (request) => {
    const joinerUid = request.auth?.uid;
    if (!joinerUid) {
      throw new HttpsError("unauthenticated", "Sign in required");
    }
    const raw = request.data as { uids?: unknown } | undefined;
    const requested = Array.isArray(raw?.uids) ? raw.uids : [];
    const targets = Array.from(
      new Set(
        requested
          .filter((u): u is string => typeof u === "string" && u.length > 0)
          .filter((u) => u !== joinerUid)
      )
    ).slice(0, CONTACT_JOIN_MAX_TARGETS);
    if (targets.length === 0) return { notified: 0 };

    const joinerSnap = await db.collection("users").doc(joinerUid).get();
    const joiner = joinerSnap.data();
    if (!joinerSnap.exists || !joiner) {
      throw new HttpsError("failed-precondition", "No profile for this account");
    }
    // Test accounts are invisible everywhere else; they don't get to announce
    // themselves to real members either.
    if (joiner.isTestAccount === true) return { notified: 0 };

    // Only a genuinely new member "joined". Without this, any later contact
    // re-sync would re-announce an account that has been here for months.
    const joinedAt = joiner.joinedAt as Timestamp | undefined;
    const ageMs = joinedAt ? Date.now() - joinedAt.toMillis() : Number.MAX_SAFE_INTEGER;
    if (ageMs > CONTACT_JOIN_WINDOW_DAYS * 24 * 60 * 60 * 1000) {
      return { notified: 0 };
    }

    const first = firstNameFromUser(joiner);
    // Contact matching means the recipient knows this person by their full name.
    const fullName = ((joiner.displayName as string | undefined)?.trim() || first);
    const photo = (joiner.profileImageURL as string | undefined) ?? null;
    let notified = 0;

    for (const target of targets) {
      if (!hiddenAccountCanNotify(joinerUid, target)) continue;
      // One alert per (joiner, target) forever. The ledger id is the pair, so a
      // retried call or a second contact sync is a no-op rather than a repeat.
      const ledger = db.collection("contactJoinNotifications").doc(`${joinerUid}_${target}`);
      try {
        await ledger.create({
          joinerUid,
          targetUid: target,
          createdAt: FieldValue.serverTimestamp(),
        });
      } catch {
        // Already exists: this pair has been alerted.
        continue;
      }
      const targetSnap = await db.collection("users").doc(target).get();
      const targetData = targetSnap.data();
      if (!targetSnap.exists || !targetData) continue;
      // They already found each other. Nothing to announce.
      const following = (targetData.following as string[] | undefined) ?? [];
      if (following.includes(joinerUid)) continue;

      await notifyUser(
        target,
        `${first} joined SPINE`,
        `${fullName} is in your contacts. Tap to follow.`,
        { type: "contact_joined", followerId: joinerUid },
        joinerUid,
        photo
      );
      notified += 1;
    }
    logger.info("notifyContactsOfJoin", { joinerUid, requested: targets.length, notified });
    return { notified };
  }
);

/** Friends who follow `authorUid` (Firestore `following` contains author string ids). */
async function recipientUidsWhoFollow(authorUid: string): Promise<string[]> {
  const q = await db.collection("users").where("following", "array-contains", authorUid).get();
  return q.docs.map((d) => d.id).filter((id) => id !== authorUid);
}

/**
 * Push cap for rating sprees, mirroring the feed's day-group carousel
 * (FeedItem.groupingThreshold = 4): an author's first three finished-book
 * posts on a calendar day push normally; from the fourth onward, followers
 * still get the in-app bell entry but no push. The server can't know each
 * viewer's timezone, so "day" uses the app's home timezone — the exact
 * midnight boundary matters far less than capping the burst.
 */
const MAX_FINISHED_BOOK_PUSHES_PER_DAY = 3;
const APP_DAY_TIMEZONE = "America/Chicago";

/** Calendar-day key (YYYY-MM-DD) in the app's home timezone. */
function appDayKey(date: Date): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: APP_DAY_TIMEZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}

/**
 * How many finished-book posts the author created earlier on the same
 * (app-timezone) calendar day as `createdAt`. Any same-day earlier post is
 * within the trailing 24h, so one indexed range query covers all candidates.
 */
async function earlierFinishedBooksSameDay(authorId: string, createdAt: Timestamp): Promise<number> {
  const windowStart = Timestamp.fromMillis(createdAt.toMillis() - 24 * 60 * 60 * 1000);
  const q = await db.collection("posts")
    .where("userId", "==", authorId)
    .where("createdAt", ">=", windowStart)
    .where("createdAt", "<", createdAt)
    .get();
  const dayKey = appDayKey(createdAt.toDate());
  return q.docs.filter((d) => {
    const p = d.data();
    const ts = p.createdAt as Timestamp | undefined;
    return p.type === "finishedBook" && ts !== undefined && appDayKey(ts.toDate()) === dayKey;
  }).length;
}

export const onFriendReviewPosted = onDocumentCreated(
  {
    document: "posts/{postId}",
    database: DATABASE_ID,
    // Default 60s would kill the function mid-wait (see delay below).
    timeoutSeconds: 300,
  },
  async (event) => {
    const postId = event.params.postId as string;
    const snap = event.data;
    if (!snap) return;
    const data = snap.data();
    if (data.type !== "finishedBook") return;
    const authorId = data.userId as string;
    if (!authorId) return;

    // Right after reviewing, the author is sent to the tier list to rank the book —
    // wait so the push can reflect the tier (and not tease a rank that isn't set yet).
    await new Promise((resolve) => setTimeout(resolve, 2 * 60 * 1000));

    // Re-read the post: the tier/rating may have landed while we waited, and the
    // author may have deleted the post entirely (in which case, stay silent).
    const freshSnap = await snap.ref.get();
    if (!freshSnap.exists) return;
    const fresh = freshSnap.data() ?? {};

    const author = (await db.collection("users").doc(authorId).get()).data();
    const first = firstNameFromUser(author);
    const { title: book, coverURL } = await bookInfo(data.bookId as string | undefined);
    const tier = (fresh.tier as string | undefined)?.trim();
    const rating = formatRating(fresh.rating);
    const caption = (fresh.caption as string | undefined)?.trim() ?? "";

    // The book title is unbounded, so it leads the body (two full lines) rather
    // than the title (~18 visible characters in Notification Center).
    let title: string;
    let body: string;
    let emoji: string | undefined;
    const teaser = quotedTeaser(caption);
    if (tier && rating !== null) {
      title = `${first} gave a ${rating}`;
      body = book
        ? (teaser ? `${book}: ${teaser}` : `${book}. Open SPINE to read the full review.`)
        : (teaser || "Open SPINE to read the full review.");
    } else {
      // Unranked: no mention of rating/rank — just the finish and their review.
      title = `${first} finished a book`;
      body = book
        ? (teaser ? `${book}: ${teaser}` : `${book}. See what they thought.`)
        : (teaser || "See what they're reading on SPINE.");
      emoji = FINISHED_BOOK_EMOJI;
    }

    // Rating-spree cap: past three finished books today, skip the push (the
    // feed collapses the burst into a carousel; followers keep the bell entry).
    let pushCapped = false;
    const postCreatedAt = data.createdAt as Timestamp | undefined;
    if (postCreatedAt) {
      const earlierToday = await earlierFinishedBooksSameDay(authorId, postCreatedAt);
      pushCapped = earlierToday >= MAX_FINISHED_BOOK_PUSHES_PER_DAY;
      if (pushCapped) {
        logger.info("rating-spree push cap hit", { postId, authorId, earlierToday });
      }
    }

    // Users @mentioned in the review already got an immediate, more specific
    // review_mentioned alert (see onPostCaptionMentions) — don't alert them twice.
    const mentionedUids = new Set((await resolveMentionUids(caption)).values());
    const recipients = (await recipientUidsWhoFollow(authorId))
      .filter((uid) => hiddenAccountCanNotify(authorId, uid))
      .filter((uid) => !mentionedUids.has(uid));
    const payload = {
      type: "friend_review_posted",
      postId,
    };
    for (const uid of recipients) {
      if (pushCapped) {
        await writeNotification(uid, withEmoji(payload.type, title, emoji), body, payload, authorId, coverURL);
      } else {
        await notifyUser(uid, title, body, payload, authorId, coverURL, emoji);
      }
    }
  }
);

/**
 * @mentions in review captions: review_mentioned to each newly-tagged user when
 * a post is created or its caption edited to add them. Fires on every post
 * write, so it bails immediately when the caption didn't change (tier updates,
 * commentCount bumps). Editing a caption never re-notifies existing mentions.
 */
export const onPostCaptionMentions = onDocumentWritten(
  {
    document: "posts/{postId}",
    database: DATABASE_ID,
  },
  async (event) => {
    const postId = event.params.postId as string;
    const before = event.data?.before.exists ? event.data.before.data() : undefined;
    const after = event.data?.after.exists ? event.data.after.data() : undefined;
    if (!after) return;
    const beforeCaption = ((before?.caption as string | undefined) ?? "").trim();
    const afterCaption = ((after.caption as string | undefined) ?? "").trim();
    if (afterCaption.length === 0 || beforeCaption === afterCaption) return;
    const authorId = after.userId as string | undefined;
    if (!authorId) return;

    const beforeHandles = new Set(mentionHandles(beforeCaption));
    const newHandles = mentionHandles(afterCaption).filter((h) => !beforeHandles.has(h));
    if (newHandles.length === 0) return;
    const resolved = await resolveMentionUids(afterCaption);
    const newUids = new Set(
      newHandles
        .map((h) => resolved.get(h))
        .filter((u): u is string => typeof u === "string" && u !== authorId)
    );
    if (newUids.size === 0) return;

    const author = (await db.collection("users").doc(authorId).get()).data();
    const first = firstNameFromUser(author);
    const { title: book, coverURL } = await bookInfo(after.bookId as string | undefined);
    const title = `${first} mentioned you`;
    const teaser = quotedTeaser(afterCaption);
    const where = book ? `In their review of ${book}` : "In a review";
    const body = teaser ? `${where}: ${teaser}` : `${where}.`;
    for (const uid of newUids) {
      if (!hiddenAccountCanNotify(authorId, uid)) continue;
      await notifyUser(
        uid,
        title,
        body,
        { type: "review_mentioned", postId },
        authorId,
        coverURL
      );
    }
  }
);

/**
 * A member recommended a book to another (`recommendations/{recId}` created as
 * pending by RecommendationRepository.send): push + bell entry to the recipient.
 * The tap deep-links to the queue, where the Recommended shelf holds the book.
 * Repeat sends are already a client-side no-op (send reuses the pending doc),
 * so every created doc is a genuinely new recommendation.
 */
export const onRecommendationCreated = onDocumentCreated(
  {
    document: "recommendations/{recId}",
    database: DATABASE_ID,
  },
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const data = snap.data();
    if (data.status !== "pending") return;
    const fromUserId = data.fromUserId as string | undefined;
    const toUserId = data.toUserId as string | undefined;
    if (!fromUserId || !toUserId || fromUserId === toUserId) return;
    if (!hiddenAccountCanNotify(fromUserId, toUserId)) return;

    const sender = (await db.collection("users").doc(fromUserId).get()).data();
    const first = firstNameFromUser(sender);
    const { title: book, coverURL } = await bookInfo(data.bookId as string | undefined);
    const note = ((data.note as string | undefined) ?? "").trim();
    const title = `${first} sent you a book`;
    const noteTeaser = quotedTeaser(note);
    const shelf = "It's on the Recommended shelf of your queue.";
    const body = book
      ? (noteTeaser ? `${book}: ${noteTeaser}` : `${book}. ${shelf}`)
      : (noteTeaser || shelf);
    const payload: Record<string, string> = {
      type: "book_recommended",
      recommendationId: event.params.recId as string,
      ...(typeof data.bookId === "string" && data.bookId ? { bookId: data.bookId } : {}),
    };
    await notifyUser(toUserId, title, body, payload, fromUserId, coverURL);
  }
);

/**
 * Book Blend pair doc (`bookBlends/{uidLow_uidHigh}`) changed:
 * - created as pending, or re-requested (declined → pending): blend_request push to the recipient.
 * - pending → ready (the accepter's device saved the generated result): blend_ready push to the requester.
 * - deleted while pending (requester undid the request, or account cleanup):
 *   silent push so the recipient's device removes the stale invite alert.
 * Declines stay silent. Both alert payloads deep-link via `blendId`.
 */
export const onBookBlendWritten = onDocumentWritten(
  {
    document: "bookBlends/{blendId}",
    database: DATABASE_ID,
  },
  async (event) => {
    const blendId = event.params.blendId as string;
    const before = event.data?.before.exists ? event.data.before.data() : undefined;
    const after = event.data?.after.exists ? event.data.after.data() : undefined;
    if (!after) {
      // Deleted. If it was still pending, the invite alert on the recipient's
      // device is now stale — tell their app to clear it. Best-effort: iOS may
      // defer or drop background pushes, in which case the alert just stays.
      const priorRecipient = before?.recipientId as string | undefined;
      if (before?.status === "pending" && priorRecipient) {
        // The invite row in the recipient's in-app notification feed is stale too.
        await deleteByQuery(
          db.collection("users").doc(priorRecipient).collection("notifications")
            .where("type", "==", "blend_request")
            .where("blendId", "==", blendId)
        );
        await sendSilentToUser(priorRecipient, {
          type: "blend_request_withdrawn",
          blendId,
        });
      }
      return;
    }

    const beforeStatus = (before?.status as string | undefined) ?? null;
    const afterStatus = after.status as string | undefined;
    if (beforeStatus === afterStatus) return;

    const requesterId = after.requesterId as string | undefined;
    const recipientId = after.recipientId as string | undefined;
    if (!requesterId || !recipientId) return;

    const participants = (after.participants ?? {}) as Record<string, { firstName?: string }>;
    const nameOf = async (uid: string): Promise<string> => {
      const snapshotName = participants[uid]?.firstName?.trim();
      if (snapshotName) return snapshotName;
      return firstNameFromUser((await db.collection("users").doc(uid).get()).data());
    };

    if (afterStatus === "pending" && (beforeStatus === null || beforeStatus === "declined")) {
      if (!hiddenAccountCanNotify(requesterId, recipientId)) return;
      const requesterName = await nameOf(requesterId);
      await notifyUser(
        recipientId,
        `${requesterName} invited you`,
        "Book Blend: see how your reading tastes line up. Tap to accept.",
        { type: "blend_request", blendId, otherUserId: requesterId },
        requesterId
      );
      return;
    }

    if (afterStatus === "ready" && beforeStatus === "pending") {
      if (!hiddenAccountCanNotify(recipientId, requesterId)) return;
      const recipientName = await nameOf(recipientId);
      const score = (after.result as { score?: number } | undefined)?.score;
      await notifyUser(
        requesterId,
        "Your Blend is ready",
        typeof score === "number"
          ? `You and ${recipientName} scored ${score}%. Tap to watch it.`
          : `Tap to watch it with ${recipientName}.`,
        { type: "blend_ready", blendId, otherUserId: recipientId },
        recipientId
      );
    }
  }
);

export const onPostLiked = onDocumentCreated(
  {
    document: "postLikes/{likeId}",
    database: DATABASE_ID,
  },
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const d = snap.data();
    const likerId = d.userId as string;
    const postId = d.postId as string;
    if (!likerId || !postId) return;

    const post = await db.collection("posts").doc(postId).get();
    const postData = post.data();
    if (!postData) return;
    const authorId = postData.userId as string;
    if (!authorId || likerId === authorId) return;
    if (!hiddenAccountCanNotify(likerId, authorId)) return;

    const liker = (await db.collection("users").doc(likerId).get()).data();
    const first = firstNameFromUser(liker);
    const { title: book, coverURL } = await bookInfo(postData.bookId as string | undefined);
    // readRecord = hidden discussion carrier for a read that was never posted
    // to the feed, so "review" would ring false.
    const likedNoun = postData.type === "readRecord" ? "read" : "review";
    const title = `${first} liked your ${likedNoun}`;
    // The book moved out of the title (it was the part that got truncated), so
    // the body names it. Without a book the push falls back to "Tap to open SPINE".
    const body = book ? `Your ${likedNoun} of ${book}.` : "";
    await notifyUser(
      authorId,
      title,
      body,
      { type: "review_liked", postId },
      likerId,
      coverURL
    );
  }
);

export const onCommentLiked = onDocumentCreated(
  {
    document: "commentLikes/{likeId}",
    database: DATABASE_ID,
  },
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const d = snap.data();
    const likerId = d.userId as string;
    const commentId = d.commentId as string;
    const postId = d.postId as string;
    if (!likerId || !commentId || !postId) return;

    const comment = await db.collection("comments").doc(commentId).get();
    const commentData = comment.data();
    if (!commentData) return;
    const authorId = commentData.userId as string;
    if (!authorId || likerId === authorId) return;
    if (!hiddenAccountCanNotify(likerId, authorId)) return;

    const liker = (await db.collection("users").doc(likerId).get()).data();
    const first = firstNameFromUser(liker);
    const postData = (await db.collection("posts").doc(postId).get()).data();
    const { title: book, coverURL } = await bookInfo(postData?.bookId as string | undefined);
    const title = `${first} liked your comment`;
    // Body names the book and echoes the liked comment so the alert reads on its
    // own; the tap deep-links to the thread scrolled to this exact comment.
    const body = bodyOnBook(book, quotedTeaser((commentData.text as string | undefined) ?? ""));

    await notifyUser(
      authorId,
      title,
      body,
      { type: "comment_liked", postId, commentId },
      likerId,
      coverURL
    );
  }
);

export const onCommentCreated = onDocumentCreated(
  {
    document: "comments/{commentId}",
    database: DATABASE_ID,
  },
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const d = snap.data();
    const commenterId = d.userId as string;
    const postId = d.postId as string;
    // Every payload below carries the new comment's id so the tap can scroll
    // the thread to (and flash) the exact comment, like comment_liked does.
    const commentId = event.params.commentId;
    const commentText = (d.text as string | undefined)?.trim() ?? "";
    if (!commenterId || !postId) return;

    const post = await db.collection("posts").doc(postId).get();
    const postData = post.data();
    if (!postData) return;
    const authorId = postData.userId as string;
    if (!authorId) return;

    const commenter = (await db.collection("users").doc(commenterId).get()).data();
    const first = firstNameFromUser(commenter);
    const { title: book, coverURL } = await bookInfo(postData.bookId as string | undefined);

    // Reply to another comment: comment_replied to the parent comment's author.
    const parentCommentId = d.parentCommentId as string | undefined;
    let replyTargetUid: string | null = null;
    if (parentCommentId) {
      const parent = await db.collection("comments").doc(parentCommentId).get();
      const parentUid = parent.data()?.userId as string | undefined;
      if (parentUid && parentUid !== commenterId && hiddenAccountCanNotify(commenterId, parentUid)) {
        replyTargetUid = parentUid;
        const replyTitle = `${first} replied to you`;
        const replyBody = bodyOnBook(book, quotedTeaser(commentText));
        await notifyUser(
          replyTargetUid,
          replyTitle,
          replyBody,
          { type: "comment_replied", postId, commentId },
          commenterId,
          coverURL
        );
      }
    }

    // Author: review_commented (not if self-comment; skip if they already got comment_replied).
    // readRecord posts are read discussions without a review, so say "read".
    const commentNoun = postData.type === "readRecord" ? "read" : "review";
    if (commenterId !== authorId && authorId !== replyTargetUid && hiddenAccountCanNotify(commenterId, authorId)) {
      const title = `${first} commented`;
      const where = book ? `On your ${commentNoun} of ${book}` : `On your ${commentNoun}`;
      const preview = quotedTeaser(commentText);
      const body = preview ? `${where}: ${preview}` : `${where}.`;
      await notifyUser(
        authorId,
        title,
        body,
        { type: "review_commented", postId, commentId },
        commenterId,
        coverURL
      );
    }

    // @mentions: comment_mentioned to each tagged user — but one alert per person:
    // the replied-to commenter keeps their comment_replied (replies auto-tag them,
    // so without this exclusion every reply would double-notify), and the post
    // author keeps their review_commented.
    const mentionUids = new Set((await resolveMentionUids(commentText)).values());
    const mentionTitle = `${first} mentioned you`;
    const mentionWhere = book ? `In a comment on ${book}` : "In a comment";
    const mentionTeaser = quotedTeaser(commentText);
    const mentionBody = mentionTeaser ? `${mentionWhere}: ${mentionTeaser}` : `${mentionWhere}.`;
    for (const uid of mentionUids) {
      if (uid === commenterId || uid === authorId || uid === replyTargetUid) continue;
      if (!hiddenAccountCanNotify(commenterId, uid)) continue;
      await notifyUser(
        uid,
        mentionTitle,
        mentionBody,
        { type: "comment_mentioned", postId, commentId },
        commenterId,
        coverURL
      );
    }

    // Thread participants (exclude new commenter, post author, the replied-to
    // commenter, and mentioned users — each already notified above)
    const commentsSnap = await db.collection("comments").where("postId", "==", postId).get();
    const participantIds = new Set<string>();
    commentsSnap.forEach((doc) => {
      const uid = doc.data().userId as string | undefined;
      if (uid) participantIds.add(uid);
    });
    participantIds.delete(commenterId);
    participantIds.delete(authorId);
    if (replyTargetUid) participantIds.delete(replyTargetUid);
    for (const uid of mentionUids) participantIds.delete(uid);

    const threadTitle = `${first} also commented`;
    const threadWhere = book ? `In the ${book} thread you joined` : `In a ${commentNoun} thread you joined`;
    const threadTeaser = quotedTeaser(commentText);
    const threadBody = threadTeaser ? `${threadWhere}: ${threadTeaser}` : `${threadWhere}.`;

    for (const uid of participantIds) {
      await notifyUser(
        uid,
        threadTitle,
        threadBody,
        { type: "thread_commented", postId, commentId },
        commenterId,
        coverURL
      );
    }
  }
);

// ---------------------------------------------------------------------------
// Community book popularity (bookStats/)
//
// Search ranking boosts works that 2+ SPINE members have shelved. This trigger
// maintains one bookStats doc per *work* — keyed by a hash of popularityKey —
// with the distinct set of users who currently have any userBooks entry for it.
// The client (BookPopularityService) reads keys where count >= 2.
// ---------------------------------------------------------------------------

/**
 * Cross-edition identity for the popularity signal: normalized main title
 * (parentheticals stripped, subtitle dropped, leading article removed) + "|" +
 * primary author's surname. MUST stay in lockstep with the Swift
 * `BookSearchRanker.popularityKey` — the client matches search candidates
 * against these exact strings. Empty when the title normalizes to nothing.
 */
export function popularityKey(title: string, author: string): string {
  const normalize = (s: string): string =>
    s
      .normalize("NFD")
      .replace(/[̀-ͯ]/g, "")
      .toLowerCase()
      .replace(/['’]/g, "")
      .replace(/[^a-z0-9]+/g, " ")
      .trim();
  let raw = title.replace(/\([^)]*\)|\[[^\]]*\]/g, " ");
  raw = raw.split(":")[0] ?? raw;
  let t = normalize(raw);
  for (const article of ["the ", "a ", "an "]) {
    if (t.startsWith(article)) {
      t = t.slice(article.length);
      break;
    }
  }
  if (!t) return "";
  const primary = normalize(author.split(",")[0] ?? "");
  const surname = primary.split(" ").filter(Boolean).pop() ?? "";
  return `${t}|${surname}`;
}

/** Adds/removes one user's membership in a work's bookStats doc. */
async function adjustBookPopularity(userId: string, bookId: string, add: boolean): Promise<void> {
  if (!userId || !bookId) return;
  // Test accounts never count toward community popularity.
  const user = (await db.collection("users").doc(userId).get()).data();
  if (user?.isTestAccount === true) return;
  const book = (await db.collection("books").doc(bookId).get()).data();
  const title = ((book?.title as string | undefined) ?? "").trim();
  const author = ((book?.author as string | undefined) ?? "").trim();
  const key = popularityKey(title, author);
  if (!key) return;
  const docId = createHash("sha256").update(key).digest("hex").slice(0, 40);
  const ref = db.collection("bookStats").doc(docId);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const userIds = new Set<string>((snap.data()?.userIds as string[] | undefined) ?? []);
    if (add) userIds.add(userId);
    else userIds.delete(userId);
    if (userIds.size === 0) {
      if (snap.exists) tx.delete(ref);
      return;
    }
    tx.set(ref, {
      key,
      sampleTitle: title,
      sampleAuthor: author,
      userIds: [...userIds],
      count: userIds.size,
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
}

export const onUserBookWritten = onDocumentWritten(
  {
    document: "userBooks/{userBookId}",
    database: DATABASE_ID,
  },
  async (event) => {
    const before = event.data?.before?.exists ? event.data.before.data() : undefined;
    const after = event.data?.after?.exists ? event.data.after.data() : undefined;
    const beforeUser = (before?.userId as string | undefined) ?? "";
    const beforeBook = (before?.bookId as string | undefined) ?? "";
    const afterUser = (after?.userId as string | undefined) ?? "";
    const afterBook = (after?.bookId as string | undefined) ?? "";
    // Status/tier/rating edits keep the same membership — nothing to do.
    if (beforeUser === afterUser && beforeBook === afterBook) return;
    try {
      if (before && beforeBook) await adjustBookPopularity(beforeUser, beforeBook, false);
      if (after && afterBook) await adjustBookPopularity(afterUser, afterBook, true);
    } catch (err) {
      logger.error("bookStats update failed", { beforeBook, afterBook, err });
    }
  }
);

/**
 * Dedup backstop: old app versions shelve whatever book id their search source
 * produced. When that doc is a tombstone (`mergedInto` pointer left by a dedup
 * merge), remap the new userBook to the canonical doc. Current clients resolve
 * before writing (BookRepository.ensureCanonicalBook); this catches the rest.
 * The bookId update re-fires onUserBookWritten, which moves the popularity
 * count to the canonical book.
 */
export const onUserBookCreatedDedup = onDocumentCreated(
  {
    document: "userBooks/{userBookId}",
    database: DATABASE_ID,
  },
  async (event) => {
    const bookId = event.data?.data()?.bookId as string | undefined;
    if (!bookId) return;
    try {
      let canonicalId = bookId;
      for (let hops = 0; hops < 3; hops++) {
        const snap = await db.collection("books").doc(canonicalId).get();
        const target = snap.exists ? (snap.data()?.mergedInto as string | undefined) : undefined;
        if (!target) break;
        canonicalId = target;
      }
      if (canonicalId === bookId) return;
      await event.data!.ref.update({ bookId: canonicalId });
      logger.info("Remapped userBook to canonical book", {
        userBookId: event.params.userBookId,
        from: bookId,
        to: canonicalId,
      });
    } catch (err) {
      logger.error("userBook dedup remap failed", { bookId, err });
    }
  }
);

/* ------------------------------------------------------------------------- *
 * Founder blend outreach
 *
 * Once a member has ranked FOUNDER_BLEND_RANK_THRESHOLD books, their library is
 * rich enough for a Book Blend to say something real. 24 hours after they cross
 * that line, the founder (@tan) sends them a blend request automatically.
 *
 * Two stages so the 24h delay is durable across deploys:
 *   1. onUserBookRankedForFounderBlend — the crossing writes a one-per-user
 *      ledger doc at `founderBlendSchedules/{uid}` with `dueAt = now + 24h`.
 *   2. sendDueFounderBlendRequests — hourly sweep creates the pending
 *      `bookBlends` doc, which `onBookBlendWritten` turns into the invite push.
 *
 * The ledger doc is never deleted, so each member gets at most one of these
 * ever — a member who declines is not asked again.
 * ------------------------------------------------------------------------- */

/** Ranked = the book sits in a tier on the tier list. Mirrors `spineTierLabels`. */
const TIER_VALUES = ["S", "A", "B", "C", "D", "F"] as const;

/** Books ranked before the founder reaches out. */
const FOUNDER_BLEND_RANK_THRESHOLD = 50;

const FOUNDER_BLEND_DELAY_MS = 24 * 60 * 60 * 1000;

/** Quiet hours guard (app home timezone) — a due request waits for the next
 * sweep rather than buzzing someone's phone at 4am. */
const FOUNDER_BLEND_SEND_HOUR_START = 9;
const FOUNDER_BLEND_SEND_HOUR_END = 21;

const FOUNDER_BLEND_SCHEDULES = "founderBlendSchedules";

/** Hour (0-23) in the app's home timezone. */
function appHour(date: Date): number {
  const hour = new Intl.DateTimeFormat("en-US", {
    timeZone: APP_DAY_TIMEZONE,
    hour: "2-digit",
    hour12: false,
  }).format(date);
  return parseInt(hour, 10);
}

/** Empty strings are legacy "unranked" — `UserBook.normalizedTier` collapses them too. */
function normalizedTier(data: DocumentData | undefined): string | null {
  const raw = data?.tier;
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

async function rankedBookCount(uid: string): Promise<number> {
  const snap = await db
    .collection("userBooks")
    .where("userId", "==", uid)
    .where("tier", "in", [...TIER_VALUES])
    .count()
    .get();
  return snap.data().count;
}

/** Sorted pair id, matching `BookBlend.pairId` on the client. */
function blendPairId(a: string, b: string): string {
  return [a, b].sort().join("_");
}

/** Participant snapshot in the shape `BookBlend.Participant` decodes. */
async function blendParticipant(uid: string): Promise<Record<string, unknown>> {
  const data = (await db.collection("users").doc(uid).get()).data();
  const photoURL = (data?.profileImageURL as string | undefined)?.trim();
  return {
    firstName: firstNameFromUser(data),
    ...(photoURL ? { photoURL } : {}),
    readCount: 0,
  };
}

/**
 * A book moved from unranked into a tier. Once that pushes the member past the
 * threshold, schedule the founder's blend request for 24h out — unless they
 * already have a blend pair doc with him (requested, declined, or watched),
 * were scheduled before, or are a test account.
 */
export const onUserBookRankedForFounderBlend = onDocumentWritten(
  {
    document: "userBooks/{userBookId}",
    database: DATABASE_ID,
  },
  async (event) => {
    const after = event.data?.after?.exists ? event.data.after.data() : undefined;
    if (!after) return;
    const beforeTier = normalizedTier(event.data?.before?.exists ? event.data.before.data() : undefined);
    const afterTier = normalizedTier(after);
    // Only a newly ranked book can raise the count. Re-tiering an already
    // ranked book leaves it unchanged.
    if (beforeTier !== null || afterTier === null) return;

    const uid = (after.userId as string | undefined)?.trim();
    if (!uid || uid === FOUNDER_UID) return;

    try {
      const scheduleRef = db.collection(FOUNDER_BLEND_SCHEDULES).doc(uid);
      if ((await scheduleRef.get()).exists) return;

      const pairId = blendPairId(uid, FOUNDER_UID);
      if ((await db.collection("bookBlends").doc(pairId).get()).exists) return;

      const user = await db.collection("users").doc(uid).get();
      if (!user.exists || user.data()?.isTestAccount === true) return;

      const rankedCount = await rankedBookCount(uid);
      if (rankedCount < FOUNDER_BLEND_RANK_THRESHOLD) return;

      await scheduleRef.create({
        uid,
        rankedCount,
        status: "scheduled",
        createdAt: FieldValue.serverTimestamp(),
        dueAt: Timestamp.fromMillis(Date.now() + FOUNDER_BLEND_DELAY_MS),
      });
      logger.info("founder blend scheduled", { uid, rankedCount });
    } catch (err) {
      // ALREADY_EXISTS means a sibling write won the race — that's the intended outcome.
      if ((err as { code?: number }).code === 6) return;
      logger.error("founder blend scheduling failed", { uid, error: (err as Error).message });
    }
  }
);

/**
 * Hourly sweep: every schedule whose 24h wait has elapsed becomes a pending
 * `bookBlends` doc from the founder. Everything is re-checked at send time —
 * the member may have unranked books, requested the blend themselves, or
 * deleted their account during the wait.
 */
async function sweepDueFounderBlendRequests(ignoreQuietHours: boolean): Promise<number> {
  const hour = appHour(new Date());
  if (!ignoreQuietHours && (hour < FOUNDER_BLEND_SEND_HOUR_START || hour >= FOUNDER_BLEND_SEND_HOUR_END)) {
    logger.info("founder blend sweep skipped (quiet hours)", { hour });
    return 0;
  }

  const due = await db
    .collection(FOUNDER_BLEND_SCHEDULES)
    .where("status", "==", "scheduled")
    .where("dueAt", "<=", Timestamp.now())
    .orderBy("dueAt")
    .limit(50)
    .get();
  if (due.empty) return 0;

  const founder = await blendParticipant(FOUNDER_UID);
  let sent = 0;

  for (const doc of due.docs) {
    const uid = doc.id;
    const skip = async (reason: string): Promise<void> => {
      await doc.ref.update({ status: "skipped", skippedReason: reason, resolvedAt: FieldValue.serverTimestamp() });
      logger.info("founder blend skipped", { uid, reason });
    };
    try {
      const user = await db.collection("users").doc(uid).get();
      if (!user.exists) {
        await skip("user_missing");
        continue;
      }
      if (user.data()?.isTestAccount === true) {
        await skip("test_account");
        continue;
      }
      const pairId = blendPairId(uid, FOUNDER_UID);
      const blendRef = db.collection("bookBlends").doc(pairId);
      if ((await blendRef.get()).exists) {
        await skip("blend_exists");
        continue;
      }
      const rankedCount = await rankedBookCount(uid);
      if (rankedCount < FOUNDER_BLEND_RANK_THRESHOLD) {
        await skip("below_threshold");
        continue;
      }

      const userIds = [uid, FOUNDER_UID].sort();
      // `create` (not `set`): a blend the member opened seconds ago must win.
      await blendRef.create({
        userIds,
        requesterId: FOUNDER_UID,
        recipientId: uid,
        status: "pending",
        createdAt: Timestamp.now(),
        respondedAt: null,
        participants: {
          [FOUNDER_UID]: founder,
          [uid]: await blendParticipant(uid),
        },
        result: null,
      });
      await doc.ref.update({
        status: "sent",
        rankedCount,
        sentAt: FieldValue.serverTimestamp(),
        resolvedAt: FieldValue.serverTimestamp(),
      });
      sent += 1;
      logger.info("founder blend sent", { uid, rankedCount });
    } catch (err) {
      if ((err as { code?: number }).code === 6) {
        await skip("blend_exists");
        continue;
      }
      logger.error("founder blend send failed", { uid, error: (err as Error).message });
    }
  }
  return sent;
}

export const sendDueFounderBlendRequests = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: APP_DAY_TIMEZONE,
    region: "us-central1",
  },
  async () => {
    await sweepDueFounderBlendRequests(false);
  }
);

/** Founder-only manual trigger for the sweep (bypasses quiet hours) — how this
 * feature gets verified end to end without waiting on the hourly schedule. */
export const runFounderBlendSweepNow = onCall(
  { region: "us-central1" },
  async (request) => {
    if (request.auth?.uid !== FOUNDER_UID) {
      throw new HttpsError("permission-denied", "Founder only.");
    }
    const sent = await sweepDueFounderBlendRequests(true);
    return { ok: true, sent };
  }
);


// ---------------------------------------------------------------------------
// Book clubs
// ---------------------------------------------------------------------------

const CLUB_MAX_MEMBERS = 50;
const CLUB_CODE_RE = /^[A-Z0-9]{6}$/;
const CLUB_PHONE_HASH_RE = /^[a-f0-9]{64}$/;

interface ClubMemberSnapshot {
  firstName: string;
  displayName: string;
  username: string;
  photoURL: string | null;
  joinedAt: Timestamp;
}

function clubMemberSnapshot(user: DocumentData | undefined): ClubMemberSnapshot {
  const displayName = ((user?.displayName as string | undefined)?.trim() || "Reader");
  return {
    firstName: firstNameFromUser(user),
    displayName,
    username: ((user?.username as string | undefined) ?? "").toLowerCase(),
    photoURL: (user?.profileImageURL as string | undefined) ?? null,
    joinedAt: Timestamp.now(),
  };
}

function clubMemberFirstName(club: DocumentData, uid: string): string {
  const members = (club.members ?? {}) as Record<string, { firstName?: string; displayName?: string }>;
  const m = members[uid];
  const first = m?.firstName?.trim();
  if (first) return first;
  const dn = m?.displayName?.trim();
  if (dn) return dn.split(/\s+/)[0] ?? "Someone";
  return "Someone";
}

/** "Sat, Oct 4 at 7:00 PM" in the app's home timezone. */
function formatMeeting(ts: Timestamp): string {
  const d = ts.toDate();
  const day = new Intl.DateTimeFormat("en-US", { weekday: "short", month: "short", day: "numeric", timeZone: APP_DAY_TIMEZONE }).format(d);
  const time = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", timeZone: APP_DAY_TIMEZONE }).format(d);
  return `${day} at ${time}`;
}

/**
 * Adds `uid` to a club inside a transaction. Returns the club name, or null when
 * nothing changed (already a member) / the club is full (throws).
 */
async function addMemberToClub(clubId: string, uid: string, actorUid: string): Promise<{ clubName: string; alreadyMember: boolean }> {
  const clubRef = db.collection("clubs").doc(clubId);
  const userSnap = await db.collection("users").doc(uid).get();
  const snapshot = clubMemberSnapshot(userSnap.data());
  return db.runTransaction(async (tx) => {
    const clubSnap = await tx.get(clubRef);
    const club = clubSnap.data();
    if (!clubSnap.exists || !club) {
      throw new HttpsError("not-found", "That club no longer exists.");
    }
    const memberIds = (club.memberIds as string[] | undefined) ?? [];
    const clubName = (club.name as string | undefined) ?? "your club";
    if (memberIds.includes(uid)) return { clubName, alreadyMember: true };
    if (memberIds.length >= CLUB_MAX_MEMBERS) {
      throw new HttpsError("resource-exhausted", "That club is full.");
    }
    tx.update(clubRef, {
      memberIds: FieldValue.arrayUnion(uid),
      [`members.${uid}`]: snapshot,
      updatedAt: FieldValue.serverTimestamp(),
      updatedBy: actorUid,
    });
    return { clubName, alreadyMember: false };
  });
}

/** Redeems a six-character invite code for the caller. Returns { clubId, clubName, alreadyMember }. */
export const joinClubByCode = onCall(
  { region: "us-central1" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in required");
    }
    const raw = request.data as { code?: unknown } | undefined;
    const code = String(raw?.code ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (!CLUB_CODE_RE.test(code)) {
      throw new HttpsError("invalid-argument", "Codes are 6 letters and numbers.");
    }
    const codeSnap = await db.collection("clubInviteCodes").doc(code).get();
    const clubId = codeSnap.data()?.clubId as string | undefined;
    if (!codeSnap.exists || !clubId) {
      throw new HttpsError("not-found", "No club with that code.");
    }
    const result = await addMemberToClub(clubId, uid, uid);
    logger.info("club join by code", { clubId, uid, alreadyMember: result.alreadyMember });
    return { clubId, ...result };
  }
);

/**
 * Registers hashed phone numbers (SHA-256 of the last ten digits) the caller
 * texted an invite to. When a user later saves that number on their profile,
 * `onUserWrittenForClubInvites` drops them into the club. Raw numbers never
 * reach the server.
 */
export const inviteClubPhones = onCall(
  { region: "us-central1" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in required");
    }
    const raw = request.data as { clubId?: unknown; hashes?: unknown } | undefined;
    const clubId = typeof raw?.clubId === "string" ? raw.clubId : "";
    const hashes = Array.from(
      new Set(
        (Array.isArray(raw?.hashes) ? raw.hashes : [])
          .filter((h): h is string => typeof h === "string" && CLUB_PHONE_HASH_RE.test(h))
      )
    ).slice(0, 50);
    if (!clubId || hashes.length === 0) {
      throw new HttpsError("invalid-argument", "clubId and hashes are required.");
    }
    const clubSnap = await db.collection("clubs").doc(clubId).get();
    const club = clubSnap.data();
    if (!clubSnap.exists || !club) {
      throw new HttpsError("not-found", "That club no longer exists.");
    }
    const memberIds = (club.memberIds as string[] | undefined) ?? [];
    if (!memberIds.includes(uid)) {
      throw new HttpsError("permission-denied", "Only members can invite.");
    }
    const batch = db.batch();
    for (const hash of hashes) {
      batch.set(
        db.collection("clubPhoneInvites").doc(hash),
        {
          clubIds: FieldValue.arrayUnion(clubId),
          [`invitedBy.${clubId}`]: uid,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    }
    await batch.commit();
    return { count: hashes.length };
  }
);

function clubPhoneHash(phoneNumber: string): string | null {
  const digits = phoneNumber.replace(/\D/g, "");
  if (digits.length < 10) return null;
  return createHash("sha256").update(digits.slice(-10)).digest("hex");
}

/**
 * A user doc gained (or changed) its phone number: if anyone texted that number
 * a club invite, add them to those clubs and let them know.
 */
export const onUserWrittenForClubInvites = onDocumentWritten(
  {
    document: "users/{uid}",
    database: DATABASE_ID,
  },
  async (event) => {
    const uid = event.params.uid as string;
    const before = event.data?.before.exists ? event.data.before.data() : undefined;
    const after = event.data?.after.exists ? event.data.after.data() : undefined;
    if (!after) return;
    const phone = (after.phoneNumber as string | undefined)?.trim();
    if (!phone) return;
    if (before && (before.phoneNumber as string | undefined)?.trim() === phone) return;
    if (after.isTestAccount === true) return;

    const hash = clubPhoneHash(phone);
    if (!hash) return;
    const inviteRef = db.collection("clubPhoneInvites").doc(hash);
    const inviteSnap = await inviteRef.get();
    const invite = inviteSnap.data();
    if (!inviteSnap.exists || !invite) return;

    const clubIds = ((invite.clubIds as string[] | undefined) ?? []).slice(0, 10);
    const invitedBy = (invite.invitedBy ?? {}) as Record<string, string>;
    for (const clubId of clubIds) {
      const actor = invitedBy[clubId] ?? uid;
      try {
        const result = await addMemberToClub(clubId, uid, actor);
        logger.info("club phone invite matched", { clubId, uid, alreadyMember: result.alreadyMember });
      } catch (err) {
        logger.warn("club phone invite failed", { clubId, uid, err: String(err) });
      }
    }
    // One-shot: the number has been matched; the club doc now carries membership.
    await inviteRef.delete();
  }
);

/**
 * Club doc changed: welcome new members, tell the room who joined, announce a
 * new book or a moved meeting, keep an admin around, and tidy up on delete.
 * `updatedBy` (written by every client write) is the actor, who is never pushed
 * about their own change.
 */
export const onClubWritten = onDocumentWritten(
  {
    document: "clubs/{clubId}",
    database: DATABASE_ID,
  },
  async (event) => {
    const clubId = event.params.clubId as string;
    const before = event.data?.before.exists ? event.data.before.data() : undefined;
    const after = event.data?.after.exists ? event.data.after.data() : undefined;

    if (!after) {
      const code = before?.inviteCode as string | undefined;
      if (code) {
        await db.collection("clubInviteCodes").doc(code).delete().catch(() => undefined);
      }
      return;
    }

    const clubName = (after.name as string | undefined) ?? "your club";
    const memberIds = (after.memberIds as string[] | undefined) ?? [];
    const priorMemberIds = (before?.memberIds as string[] | undefined) ?? [];
    const actor = (after.updatedBy as string | undefined) ?? (after.createdBy as string | undefined) ?? null;

    // Empty club: nobody left to read anything.
    if (memberIds.length === 0) {
      await event.data!.after.ref.delete();
      return;
    }

    // Keep an admin around when the last one leaves.
    const everyoneIsAdmin = after.everyoneIsAdmin === true;
    const adminIds = ((after.adminIds as string[] | undefined) ?? []).filter((a) => memberIds.includes(a));
    if (!everyoneIsAdmin && adminIds.length === 0) {
      const members = (after.members ?? {}) as Record<string, { joinedAt?: Timestamp }>;
      const eldest = [...memberIds].sort((a, b) => {
        const ja = members[a]?.joinedAt?.toMillis() ?? Number.MAX_SAFE_INTEGER;
        const jb = members[b]?.joinedAt?.toMillis() ?? Number.MAX_SAFE_INTEGER;
        return ja - jb;
      })[0]!;
      await event.data!.after.ref.update({ adminIds: [eldest] });
      logger.info("club admin promoted", { clubId, uid: eldest });
    }

    // New members.
    const newMembers = memberIds.filter((m) => !priorMemberIds.includes(m));
    if (newMembers.length > 0) {
      const actorName = actor ? clubMemberFirstName(after, actor) : "Someone";
      for (const uid of newMembers) {
        if (uid === actor) continue;
        if (actor && !hiddenAccountCanNotify(actor, uid)) continue;
        await notifyUser(
          uid,
          `You're in ${clubName}`,
          actor && actor !== uid
            ? `${actorName} added you. See what the club is reading.`
            : "See what the club is reading.",
          { type: "club_added", clubId },
          actor
        );
      }
      // Tell the existing room, unless this is the club being created.
      if (before) {
        const joinedNames = newMembers.map((m) => clubMemberFirstName(after, m));
        const body =
          joinedNames.length === 1
            ? `${joinedNames[0]} joined ${clubName}.`
            : joinedNames.length === 2
              ? `${joinedNames[0]} and ${joinedNames[1]} joined ${clubName}.`
              : `${joinedNames[0]} and ${joinedNames.length - 1} others joined ${clubName}.`;
        const firstNew = newMembers[0]!;
        for (const uid of priorMemberIds) {
          if (uid === actor || newMembers.includes(uid)) continue;
          if (!hiddenAccountCanNotify(firstNew, uid)) continue;
          await notifyUser(uid, "New member", body, { type: "club_member_joined", clubId }, firstNew);
        }
      }
    }

    // Book / meeting changes.
    const pick = after.currentPick as DocumentData | undefined | null;
    const priorPick = before?.currentPick as DocumentData | undefined | null;
    if (pick && pick.id !== priorPick?.id) {
      const title = (pick.title as string | undefined) ?? "the next book";
      const author = (pick.author as string | undefined) ?? "";
      const meeting = pick.meetingAt as Timestamp | undefined | null;
      const body = meeting
        ? `${title}${author ? ` by ${author}` : ""}. Meeting ${formatMeeting(meeting)}. Tap to add it to your Reading now.`
        : `${title}${author ? ` by ${author}` : ""}. Tap to add it to your Reading now.`;
      const cover = (pick.coverURL as string | undefined) || null;
      for (const uid of memberIds) {
        if (uid === actor) continue;
        if (actor && !hiddenAccountCanNotify(actor, uid)) continue;
        await notifyUser(uid, `${clubName}: next up`, body, { type: "club_new_book", clubId, bookId: String(pick.bookId ?? "") }, actor, cover);
      }
      return;
    }
    if (pick && priorPick && pick.id === priorPick.id) {
      const meeting = pick.meetingAt as Timestamp | undefined | null;
      const priorMeeting = priorPick.meetingAt as Timestamp | undefined | null;
      const changed = (meeting?.toMillis() ?? null) !== (priorMeeting?.toMillis() ?? null);
      if (changed && meeting) {
        const title = (pick.title as string | undefined) ?? "the book";
        for (const uid of memberIds) {
          if (uid === actor) continue;
          if (actor && !hiddenAccountCanNotify(actor, uid)) continue;
          await notifyUser(
            uid,
            `${clubName} meeting ${priorMeeting ? "moved" : "set"}`,
            `${formatMeeting(meeting)} for ${title}.`,
            { type: "club_meeting_moved", clubId },
            actor
          );
        }
      }
    }
  }
);

/**
 * Day-before reminders: every club whose meeting falls 23–25 hours from now
 * (and has not been reminded) pushes each member their own progress line.
 */
async function sweepClubMeetingReminders(): Promise<number> {
  const now = Date.now();
  const lower = Timestamp.fromMillis(now + 23 * 60 * 60 * 1000);
  const upper = Timestamp.fromMillis(now + 25 * 60 * 60 * 1000);
  const snap = await db.collection("clubs")
    .where("currentPick.meetingAt", ">", lower)
    .where("currentPick.meetingAt", "<=", upper)
    .get();
  let sent = 0;
  for (const doc of snap.docs) {
    const club = doc.data();
    const pick = club.currentPick as DocumentData | undefined;
    if (!pick || pick.reminderSentAt) continue;
    const clubName = (club.name as string | undefined) ?? "Book club";
    const title = (pick.title as string | undefined) ?? "the book";
    const bookId = pick.bookId as string | undefined;
    const meeting = pick.meetingAt as Timestamp;
    const memberIds = (club.memberIds as string[] | undefined) ?? [];
    // Claim first so a slow loop never double-sends.
    await doc.ref.update({ "currentPick.reminderSentAt": FieldValue.serverTimestamp() });
    for (const uid of memberIds) {
      let line = `Meeting ${formatMeeting(meeting)}. Still time to finish ${title}.`;
      if (bookId) {
        const rows = await db.collection("userBooks")
          .where("userId", "==", uid)
          .where("bookId", "==", bookId)
          .limit(3)
          .get();
        let best: DocumentData | undefined;
        for (const r of rows.docs) {
          const d = r.data();
          if (!best || d.status === "Read" || ((d.readingProgress as number) ?? 0) > ((best.readingProgress as number) ?? 0)) best = d;
        }
        if (best?.status === "Read") {
          line = `Meeting ${formatMeeting(meeting)}. You've finished ${title}. Bring opinions.`;
        } else if (typeof best?.readingProgress === "number" && best.readingProgress > 0) {
          line = `Meeting ${formatMeeting(meeting)}. You're ${Math.round(best.readingProgress * 100)}% through ${title}.`;
        }
      }
      await notifyUser(uid, `${clubName} meets tomorrow`, line, { type: "club_meeting_soon", clubId: doc.id }, null);
      sent += 1;
    }
  }
  return sent;
}

export const sendClubMeetingReminders = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: APP_DAY_TIMEZONE,
    region: "us-central1",
  },
  async () => {
    const sent = await sweepClubMeetingReminders();
    if (sent > 0) logger.info("club meeting reminders", { sent });
  }
);
