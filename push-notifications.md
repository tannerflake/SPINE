# Spines Push Notifications: Product Spec

## Current copy set (September 2026) — supersedes the examples below

The examples further down are the original spec. In practice titles were getting cut at
roughly 18 characters in the stacked Notification Center view (title shares its line with
the app icon and a timestamp like "Yesterday, 11:12 PM"), so the meat of every alert was
lost. The copy now follows three rules, implemented in `functions/src/index.ts`:

1. **Title = emoji + first name + short verb**, 22 characters or fewer. The emoji is
   prefixed once in `notifyUser` (map `TITLE_EMOJI`, keyed by notification type) so the
   push and the bell-feed row carry the same string.
2. **Body leads with the specific object** (book title, other person, score) in its first
   ~40 characters, then the quoted ~8-word teaser or the payoff line.
3. **Book titles never appear in the title.** They are unbounded in length and were the
   part that pushed everything else off the end.

| Type | Title | Body |
|---|---|---|
| friend_review_posted (rated) | ⭐ Hannah gave a 9.2 | Sapiens: “Smart, ambitious, provocative, and way more…” |
| friend_review_posted (unrated) | 📚 Hannah finished a book | Sapiens: “caption…” / Sapiens. See what they thought. |
| review_liked | ❤️ Hannah liked your review | Your review of Sapiens. |
| comment_liked | ❤️ Hannah liked your comment | On Sapiens: “comment teaser…” |
| review_commented | 💬 Hannah commented | On your review of Sapiens: “teaser…” |
| comment_replied | ↩️ Hannah replied to you | On Sapiens: “teaser…” |
| thread_commented | 💬 Hannah also commented | In the Sapiens thread you joined: “teaser…” |
| review_mentioned | 📣 Hannah mentioned you | In their review of Sapiens: “teaser…” |
| comment_mentioned | 📣 Hannah mentioned you | In a comment on Sapiens: “teaser…” |
| new_follower | 👋 Hannah followed you | See what they're reading on SPINE. |
| founder join alert (new_follower) | 🎉 Hannah joined SPINE | They follow you, and you now follow them back. |
| contact_joined | 🎉 Hannah joined SPINE | Hannah Smith is in your contacts. Tap to follow. |
| blend_request | 🔀 Hannah invited you | Book Blend: see how your reading tastes line up. Tap to accept. |
| blend_ready | 🔀 Your Blend is ready | You and Hannah scored 84%. Tap to watch it. |
| book_recommended | 📖 Hannah sent you a book | Sapiens: “note teaser…” / Sapiens. It's on the Recommended shelf of your queue. |

"read" replaces "review" for `readRecord` discussion carriers, as before.

---

## Purpose

This document defines the first set of meaningful push notifications for Spines. The goal is to drive re-engagement around social activity that already feels valuable inside the product, especially activity tied to reviews, discovery, and conversation.

These notifications should feel personal, social, and curiosity-inducing without feeling spammy. The implementation details can be chosen by the coding agent based on the existing architecture, but the intended product behavior should stay consistent with the guidance below.

---

## Goals

The first push notifications should do four things well:

1. Bring users back when people they care about do something interesting.
2. Reinforce the social graph, especially friend-to-friend book activity.
3. Encourage deeper engagement with reviews and comment threads.
4. Create curiosity through short teaser copy instead of fully satisfying the user in the notification itself.

---

## Initial Notification Types

The first batch of push notifications should include these four types:

1. **A friend posts a book review to their feed**
2. **Someone likes your review**
3. **Someone comments on your review**
4. **Someone comments on a review that you also commented on**

These should be the starting set before expanding into anything broader.

---

## 1) Friend posts a book review to their feed

### User value

This is likely the most compelling early notification because it combines:
- a person the recipient already knows
- a specific book
- a score
- a teaser of opinion/review content

This should feel like social proof plus curiosity.

### Core behavior

When a user posts a book review to their feed, their friends should be eligible to receive a push notification.

The notification should:
- identify the friend by **first name only**
- include the **book title**
- include the **rating/score**
- include a short teaser from the review body
- intentionally truncate the teaser to create curiosity

### Example copy

**Title or leading line concept**
- `Tanner gave Sapiens a 9.2`
- If the book was marked read without a rating/tier, drop the score entirely: `Tanner read Sapiens` (never show a placeholder like `?`)

**Body concept**
- Start with a colon after the score, then show the review teaser
- Example:
  - `Tanner gave Sapiens a 9.2: Smart, ambitious, provocative, and way more readable...`

### Copy rules

- Use only the poster's **first name**
- Do not use full names, usernames, or handles in this notification
- Include the **book title** exactly as the user would recognize it in product
- Include the **numeric score**
- Append a colon and then the review teaser
- The review teaser should always be truncated after roughly **8 words**
- The truncation should happen even if the review is short enough to fit fully in a push
- The point is to create a teaser, not to fully present the review

### Truncation guidance

The truncation should feel intentional, not accidental.

Suggested behavior:
- take the first ~8 words from the review body
- preserve readable spacing/punctuation where possible
- append an ellipsis if there is more review content after the teaser
- keep the result natural and readable, not robotic

Examples:
- Full review: `Smart, ambitious, provocative, and way more readable than I expected from a book trying to explain all of human history.`
- Push teaser: `Smart, ambitious, provocative, and way more readable than...`

Another example:
- Full review: `I loved the ideas but I think the author overstates some of the claims in the back half.`
- Push teaser: `I loved the ideas but I think the author...`

### Product intent

This notification should make the recipient want to tap in and read:
- the full review
- the comments
- the surrounding feed context

It should not feel like the push already gave away the whole opinion.

### Tap behavior

Tapping should deep link the user as directly as possible into the relevant review detail or feed item, not just the general home screen.

---

## 2) Someone liked your review

### User value

This validates contribution and gives users quick social feedback. It is a lightweight but meaningful reinforcement notification.

### Core behavior

When someone likes a user's review, the review author should be eligible to receive a push notification.

### Example copy

- `Ava liked your review of Sapiens`
- `Noah liked your review`
- `Emma liked your review of The Secret History`

### Copy guidance

- Prefer first name only if that is the pattern being used across social notifications
- Mention the book title when it improves clarity and fits cleanly
- Keep this notification short and clean
- This one does not need teaser text

### Tap behavior

Tapping should take the user directly to the review and ideally surface the like context naturally from there.

---

## 3) Someone commented on your review

### User value

This is stronger than a like because it signals active conversation and invites response.

### Core behavior

When someone comments on a user's review, the review author should be eligible to receive a push notification.

### Example copy

- `Ava commented on your review of Sapiens`
- `Noah replied to your review`
- `Emma commented on your review: Totally agree about the ending...`

### Copy guidance

There are two acceptable patterns:
- simple notification with no comment preview
- notification with a short teaser of the comment

A teaser is likely helpful if it fits comfortably and increases curiosity. If included, it should still be concise and not feel noisy.

Good default direction:
- keep the main notification focused on the actor and the review
- include a short preview only if it improves open rate and still feels clean

### Tap behavior

Tapping should deep link into the review detail, with the comment thread visible and easy to continue.

---

## 4) Someone commented on a review that you commented on

### User value

This helps users stay connected to conversations they joined, even when the review is not theirs. It makes comment threads feel alive and social.

### Core behavior

When a user has commented on a review, and another person later comments on that same review, the earlier commenter should be eligible to receive a push notification.

This is not about ownership of the review. It is about participation in the thread.

### Example copy

- `Ava also commented on a review you commented on`
- `Noah replied in a review thread you joined`
- `Emma commented on the Sapiens review you joined`

### Copy guidance

This notification should make it obvious why the user is receiving it.
The relationship is:
- you participated in this thread
- now there is more activity in it

If the book title fits cleanly, including it may improve clarity.
If the actor is someone recognizable to the user, showing first name is good.

### Tap behavior

Tapping should deep link into the relevant review thread with the newest comment visible or easy to find.

---

## Notification Principles

### 1) Make them feel social, not system-generated

These pushes should feel like people activity, not generic app activity.
Names, books, ratings, and snippets all help.

### 2) Optimize for curiosity

Especially for review-post notifications, do not fully satisfy the curiosity in the push.
A short, deliberate teaser is better than a full excerpt.

### 3) Keep them easy to parse

A push should be understandable almost instantly from the lock screen.
The user should know:
- who acted
- what happened
- why it matters to them

### 4) Prefer first names

For these early social notifications, first-name-only presentation seems best.
It feels personal and clean.

### 5) Deep link to the exact destination

Pushes should land the user at the most relevant place possible:
- the specific review
- the comment thread
- the exact discussion context

That destination quality matters almost as much as the push copy itself.

---

## Suggested Event Definitions

This section is intentionally high level so the coding agent can map it to the existing app and backend architecture.

### Event: friend_review_posted
Triggered when:
- a user creates/posts a review to their feed
Eligible recipients:
- that user's friends

Payload should conceptually include:
- actor first name
- book title
- numeric rating
- review body teaser
- target review identifier / deep link target

### Event: review_liked
Triggered when:
- a user likes another user's review
Eligible recipients:
- the author of that review

Payload should conceptually include:
- actor first name
- optional book title
- target review identifier / deep link target

### Event: review_commented
Triggered when:
- a user comments on another user's review
Eligible recipients:
- the author of that review

Payload should conceptually include:
- actor first name
- optional book title
- optional short comment preview
- target review/thread identifier

### Event: thread_commented
Triggered when:
- a user comments on a review thread
Eligible recipients:
- other participants in that thread, especially users who previously commented there

Payload should conceptually include:
- actor first name
- optional book title
- optional short comment preview
- target review/thread identifier

---

## Important Product Considerations

### Relevance and spam control

These notification types are good because they are naturally high signal, but they still need sane guardrails.

The coding agent should think through things like:
- not notifying users about their own actions
- avoiding duplicate or redundant notifications
- avoiding excessive thread notifications in very active discussions
- respecting user notification preferences if those already exist or are added later

### Ordering and batching

This spec does not prescribe whether notifications should be sent instantly, slightly delayed, or batched in some cases.
That decision can depend on the current system and desired UX.

Still, the user experience should preserve urgency for:
- comments on your review
- meaningful thread activity
- friend review posts

### Reliability

These should be driven by durable social events rather than fragile client-side behavior.
The notification should reflect something that actually happened and that the user can immediately view after tapping.

### Copy consistency

The final in-app and push copy should use a consistent voice across all social notifications.
It should feel clean, personal, and a little curiosity-driven.

---

## Recommended Starting Copy Set

These are not hard requirements, just strong starting points.

### Friend review posted
- `Tanner gave Sapiens a 9.2: Smart, ambitious, provocative, and way more readable than...`
- `Tanner gave Sapiens a 9.2: I loved the ideas but I think the author...`

### Review liked
- `Ava liked your review of Sapiens`
- `Noah liked your review`

### Review commented
- `Ava commented on your review of Sapiens`
- `Emma commented on your review: Totally agree about the middle section...`

### Thread commented
- `Ava also commented on a review you commented on`
- `Noah replied in a review thread you joined`

---

## Open Implementation Decisions for the Coding Agent

The coding agent should decide the best approach for things like:
- where push-triggering events should be produced
- how notification payloads should be assembled
- how first-name formatting should be derived safely
- how teaser truncation should be handled consistently
- how deep links should be structured
- how deduping/throttling should work
- whether comment-preview text should be included for comment notifications
- how these notification types fit into any existing notification center or in-app activity model

This spec is intentionally product-focused, not architecture-prescriptive.

---

## Bottom Line

The first push notification system for Spines should start with social events that are obviously meaningful:

- a friend posts a review
- someone likes your review
- someone comments on your review
- someone comments in a review thread you joined

The highest priority and most differentiated one is the **friend review posted** push, especially because it combines:
- first-name familiarity
- book title
- score
- teaser review text

That one should feel sharp, personal, and curiosity-inducing, with the review preview always cut to about 8 words so the user wants to tap in and read more.

---

## Implementation notes: rich cover thumbnails + tap-to-review (July 2026)

**Book-cover thumbnails.** Every push tied to a single book now carries the book's cover as a rich-notification image:

- Cloud Functions (`functions/src/index.ts`) read `coverURL` from `books/{bookId}`, upgrade it to https, and send it via APNs `fcm_options.image` with `mutable-content: 1` (plus a `coverImageURL` data key as fallback).
- The `WellReadNotificationService` Notification Service Extension downloads the cover and attaches it, so the banner shows a cover thumbnail next to the alert text. Any failure (no URL, download error, timeout) falls back to the plain notification.
- Diagnostics test pushes use a fixed sample cover so the rich path can be verified from Push Diagnostics.

**Tap behavior for `friend_review_posted`.** Tapping now lands on the Feed tab scrolled to the exact review, which pulses with a brief accent highlight (`wellreadOpenFeedScrollToPost` → `AppState.scrollToFeedPostId` → `FeedView` ScrollViewReader). Like/comment/thread pushes still open the post's comment thread directly.

---

## 5) New follower (`new_follower`) — added July 2026

Sent by `onUserFollowingChanged` in `functions/src/index.ts`, which diffs the `following`
array on any `users/{uid}` update and pushes to each newly-followed user:

- **Title:** `{FirstName} started following you`
- **Body:** `See what they're reading on Spine.`
- **Tap:** opens the Feed tab (the Following strip is at the top). No cover image.
- Bulk updates (more than 10 additions at once, i.e. a migration/backfill) are skipped.
- Unfollows stay silent.

Related: `onUserCreated` notifies the founder when a new account is created
(`{FirstName} joined Spine`), and auto-follows the new member back server-side.
New accounts are seeded client-side following only the founder — the old
everyone-follows-everyone mesh is retired (it never actually worked, since
Firestore rules only allow writing your own user doc).
