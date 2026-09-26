/**
 * Apple Wallet library card.
 *
 * The pass is a storeCard whose strip image is rendered BY THE APP (SwiftUI is
 * the source of truth for the card's look): a band of the card's paper carrying
 * the placed achievement stamps and the OG mark. The app uploads that art here;
 * these functions sign passes, run Apple's pass-update web service, and send
 * the (empty) APNs pushes that make Wallet re-fetch after a stamp lands.
 *
 * Data:
 *  - walletPasses/{uid}: authToken (Wallet presents it back to us), cardNumber
 *    (frozen at first add, same number the app prints), updatedAtMs.
 *  - walletRegistrations/{serial_deviceId}: one per device holding the pass.
 *  - Storage walletCards/{uid}/strip@{1,2,3}x.png: the current strip art.
 * Both collections are admin-only (no firestore.rules match = client denied).
 *
 * Secrets (set before deploying these functions, see WALLET_PASS_SETUP.md):
 *  - WALLET_PASS_CERT_PEM / WALLET_PASS_KEY_PEM: the Pass Type ID certificate
 *    and its unencrypted private key. The same pair authenticates the APNs
 *    pass-update pushes, so there is no separate push credential.
 */

import { randomBytes } from "crypto";
import { readFileSync } from "fs";
import * as http2 from "http2";
import * as path from "path";
import { getApps, initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { onCall, onRequest, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import { PKPass } from "passkit-generator";
import type { DocumentData } from "firebase-admin/firestore";

const walletApp = getApps().length ? getApps()[0]! : initializeApp();
const walletDb = getFirestore(walletApp, "wellread");

const walletPassCert = defineSecret("WALLET_PASS_CERT_PEM");
const walletPassKey = defineSecret("WALLET_PASS_KEY_PEM");

export const PASS_TYPE_ID = "pass.com.wellread.app.librarycard";
const TEAM_ID = "T32N9X64JM";
// Wallet appends /v1/... to this. Verify after first deploy with
// `firebase functions:list` (see WALLET_PASS_SETUP.md).
const WEB_SERVICE_URL =
  "https://us-central1-wellread-520f2.cloudfunctions.net/walletPassWebService";
const SITE_URL = "https://www.tannerflake.com/SPINE";

// The card's fixed-light palette (LibraryCardPalette.fixedLight): the pass is
// printed paper, never dark-mode.
const PAPER = "rgb(246,247,238)";
const INK = "rgb(20,16,24)";
const SECONDARY_INK = "rgb(69,66,75)";

const STRIP_SCALES = [1, 2, 3] as const;

function stripStoragePath(uid: string, scale: number): string {
  return `walletCards/${uid}/strip@${scale}x.png`;
}

function assetPath(name: string): string {
  // __dirname is lib/ at runtime; assets/ sits beside src/ and lib/.
  return path.join(__dirname, "..", "assets", name);
}

// MARK: - Pass building

/** Mirrors LibraryCardDetails.from: onboarding first/last name, else display name. */
function cardName(user: DocumentData): string {
  const first = ((user.firstName as string | undefined) ?? "").trim();
  const last = ((user.lastName as string | undefined) ?? "").trim();
  const joined = [first, last].filter((s) => s.length > 0).join(" ");
  if (joined.length > 0) return joined;
  return ((user.displayName as string | undefined) ?? "Reader").trim() || "Reader";
}

/** "JUL 2026", same as LibraryCardDetails.memberSince. */
function memberSinceText(user: DocumentData): string {
  const joined = user.joinedAt?.toDate?.() as Date | undefined;
  const date = joined ?? new Date();
  return date
    .toLocaleDateString("en-US", { month: "short", year: "numeric", timeZone: "America/Chicago" })
    .toUpperCase();
}

/** Same wording as the card's goal stamp, split into label/value. */
function goalField(user: DocumentData): { label: string; value: string } {
  const year = new Date().getFullYear();
  const goal = user.readingGoal as number | undefined;
  if (goal && goal > 0) return { label: `${year} GOAL`, value: `${goal} BOOKS` };
  return { label: `${year}`, value: "READING FREELY" };
}

/** Titles for the pass back, keyed like AchievementKind. Placed or not: the
 * back lists what was earned; the strip shows what was pressed. */
const ACHIEVEMENT_TITLES: Record<string, string> = {
  ranked25: "25 Books Ranked",
};

function earnedStampsLine(user: DocumentData): string | null {
  const achievements = (user.achievements ?? {}) as Record<string, unknown>;
  const titles = Object.keys(achievements)
    .map((id) => ACHIEVEMENT_TITLES[id])
    .filter((t): t is string => Boolean(t));
  if (titles.length === 0) return null;
  return titles.join(", ");
}

/** Builds and signs the .pkpass for one member from the live user doc, the
 * frozen card number, and whatever strip art the app last uploaded. */
async function buildPass(uid: string): Promise<Buffer> {
  const [userSnap, passSnap] = await Promise.all([
    walletDb.collection("users").doc(uid).get(),
    walletDb.collection("walletPasses").doc(uid).get(),
  ]);
  const user = userSnap.data();
  const passDoc = passSnap.data();
  if (!user || !passDoc) {
    throw new HttpsError("not-found", "No wallet pass exists for this member.");
  }

  const cardNumber = passDoc.cardNumber as number;
  const goal = goalField(user);
  const stampsLine = earnedStampsLine(user);

  const passJson: Record<string, unknown> = {
    formatVersion: 1,
    passTypeIdentifier: PASS_TYPE_ID,
    teamIdentifier: TEAM_ID,
    organizationName: "SPINE",
    description: "SPINE Library Card",
    serialNumber: uid,
    webServiceURL: WEB_SERVICE_URL,
    authenticationToken: passDoc.authToken as string,
    backgroundColor: PAPER,
    foregroundColor: INK,
    labelColor: SECONDARY_INK,
    logoText: "SPINE",
    sharingProhibited: true,
    barcodes: [
      {
        format: "PKBarcodeFormatQR",
        message: SITE_URL,
        messageEncoding: "iso-8859-1",
        altText: `CARD № ${cardNumber}`,
      },
    ],
    storeCard: {
      headerFields: [{ key: "card", label: "CARD", value: `№ ${cardNumber}` }],
      // No primaryFields: they would print over the strip art.
      secondaryFields: [
        { key: "member", label: "MEMBER", value: cardName(user) },
        {
          key: "since",
          label: "SINCE",
          value: memberSinceText(user),
          textAlignment: "PKTextAlignmentRight",
        },
      ],
      auxiliaryFields: [{ key: "goal", label: goal.label, value: goal.value }],
      backFields: [
        { key: "handle", label: "HANDLE", value: `@${(user.username as string) ?? ""}` },
        ...(stampsLine ? [{ key: "stamps", label: "STAMPS EARNED", value: stampsLine }] : []),
        {
          key: "stampNote",
          label: "STAMPS",
          value:
            "Stamps you press on your card in SPINE show up here on their own. Keep reading and ranking to earn more.",
        },
        {
          key: "about",
          label: "SPINE",
          value: `A private library club. Get your own card at ${SITE_URL}`,
        },
      ],
    },
  };

  const pass = new PKPass(
    {
      "pass.json": Buffer.from(JSON.stringify(passJson)),
      "icon.png": readFileSync(assetPath("icon.png")),
      "icon@2x.png": readFileSync(assetPath("icon@2x.png")),
      "icon@3x.png": readFileSync(assetPath("icon@3x.png")),
    },
    {
      wwdr: readFileSync(assetPath("wwdr-g4.pem")),
      signerCert: walletPassCert.value(),
      signerKey: walletPassKey.value(),
    }
  );

  // Strip art is the app's render of the stamp band. A pass created before the
  // first upload (shouldn't happen: the app sends art with the add call) is
  // still valid, just plain paper.
  const bucket = getStorage(walletApp).bucket();
  await Promise.all(
    STRIP_SCALES.map(async (scale) => {
      try {
        const [data] = await bucket.file(stripStoragePath(uid, scale)).download();
        pass.addBuffer(scale === 1 ? "strip.png" : `strip@${scale}x.png`, data);
      } catch {
        logger.warn(`walletPass: no strip@${scale}x art for ${uid}`);
      }
    })
  );

  return pass.getAsBuffer();
}

// MARK: - Strip art upload

/** Decodes and stores the app-rendered strip PNGs. Rejects anything that is
 * not a plausibly-sized PNG so the callable can't be used as blob storage. */
async function saveStripArt(uid: string, data: Record<string, unknown>): Promise<void> {
  const bucket = getStorage(walletApp).bucket();
  const writes: Promise<void>[] = [];
  for (const scale of STRIP_SCALES) {
    const b64 = data[`strip${scale}x`];
    if (typeof b64 !== "string" || b64.length === 0) {
      throw new HttpsError("invalid-argument", `Missing strip${scale}x art.`);
    }
    const buffer = Buffer.from(b64, "base64");
    const isPng = buffer.length > 8 && buffer.readUInt32BE(0) === 0x89504e47;
    if (!isPng || buffer.length > 3 * 1024 * 1024) {
      throw new HttpsError("invalid-argument", `strip${scale}x is not a valid PNG.`);
    }
    writes.push(
      bucket
        .file(stripStoragePath(uid, scale))
        .save(buffer, { contentType: "image/png", resumable: false })
    );
  }
  await Promise.all(writes);
}

// MARK: - APNs pass-update push

/** Tells every registered device to re-fetch this member's pass. Pass pushes
 * authenticate with the pass certificate itself and carry an empty payload.
 * Returns push tokens Apple reported as gone (410), for cleanup. */
async function pushPassUpdate(pushTokens: string[], cert: string, key: string): Promise<string[]> {
  if (pushTokens.length === 0) return [];
  const client = http2.connect("https://api.push.apple.com", { cert, key });
  const gone: string[] = [];
  try {
    await Promise.all(
      pushTokens.map(
        (token) =>
          new Promise<void>((resolve) => {
            const req = client.request({
              ":method": "POST",
              ":path": `/3/device/${token}`,
              "apns-topic": PASS_TYPE_ID,
              "apns-push-type": "alert",
              "apns-priority": "10",
            });
            req.setEncoding("utf8");
            let status = 0;
            req.on("response", (headers) => {
              status = Number(headers[":status"] ?? 0);
            });
            req.on("close", () => {
              if (status === 410) gone.push(token);
              else if (status !== 200) logger.warn(`walletPass: APNs push got ${status}`);
              resolve();
            });
            req.on("error", (err) => {
              logger.warn(`walletPass: APNs push failed: ${err.message}`);
              resolve();
            });
            req.end("{}");
          })
      )
    );
  } finally {
    client.close();
  }
  return gone;
}

/** Bumps the pass's updated stamp and pushes every registration. */
async function notifyPassChanged(uid: string, cert: string, key: string): Promise<number> {
  await walletDb.collection("walletPasses").doc(uid).update({ updatedAtMs: Date.now() });
  const regs = await walletDb
    .collection("walletRegistrations")
    .where("serial", "==", uid)
    .get();
  const tokens = [...new Set(regs.docs.map((d) => d.data().pushToken as string))];
  const gone = await pushPassUpdate(tokens, cert, key);
  if (gone.length > 0) {
    const batch = walletDb.batch();
    for (const doc of regs.docs) {
      if (gone.includes(doc.data().pushToken as string)) batch.delete(doc.ref);
    }
    await batch.commit();
  }
  return tokens.length - gone.length;
}

// MARK: - Callables

/**
 * Add to Apple Wallet: the app sends the strip art (1x/2x/3x PNGs, base64) and
 * the card number it already displays; back comes the signed .pkpass, base64.
 * Re-adding refreshes art and reuses the existing serial + auth token, so
 * Wallet replaces the pass in place instead of duplicating it.
 */
export const createWalletPass = onCall(
  { region: "us-central1", secrets: [walletPassCert, walletPassKey], memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to add your card.");
    const cardNumber = request.data?.cardNumber;
    if (typeof cardNumber !== "number" || !Number.isInteger(cardNumber) || cardNumber < 1) {
      throw new HttpsError("invalid-argument", "cardNumber is required.");
    }

    await saveStripArt(uid, request.data ?? {});

    const ref = walletDb.collection("walletPasses").doc(uid);
    const existing = await ref.get();
    if (existing.exists) {
      await ref.update({ updatedAtMs: Date.now() });
    } else {
      await ref.set({
        // Wallet echoes this on every web-service call; 32 hex chars.
        authToken: randomBytes(16).toString("hex"),
        cardNumber,
        createdAtMs: Date.now(),
        updatedAtMs: Date.now(),
      });
    }

    const pkpass = await buildPass(uid);
    logger.info(`walletPass: built pass for ${uid} (${pkpass.length} bytes)`);
    return { pass: pkpass.toString("base64") };
  }
);

/**
 * Called by the app after a stamp is pressed, moved, or removed (and in future
 * after any edit that changes the card): fresh strip art in, silent APNs push
 * out. A member who never added the pass gets a cheap no-op.
 */
export const updateWalletCardArt = onCall(
  { region: "us-central1", secrets: [walletPassCert, walletPassKey], memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");

    const passDoc = await walletDb.collection("walletPasses").doc(uid).get();
    if (!passDoc.exists) return { active: false, pushed: 0 };

    await saveStripArt(uid, request.data ?? {});
    const pushed = await notifyPassChanged(uid, walletPassCert.value(), walletPassKey.value());
    logger.info(`walletPass: refreshed art for ${uid}, pushed ${pushed} device(s)`);
    return { active: true, pushed };
  }
);

// MARK: - Apple's pass web service

function applePassToken(req: { headers: Record<string, unknown> }): string | null {
  const header = req.headers["authorization"];
  if (typeof header !== "string") return null;
  const match = header.match(/^ApplePass\s+(.+)$/);
  return match ? match[1]!.trim() : null;
}

async function authorizedPass(serial: string, token: string | null): Promise<DocumentData | null> {
  if (!token) return null;
  const doc = await walletDb.collection("walletPasses").doc(serial).get();
  const data = doc.data();
  if (!data || data.authToken !== token) return null;
  return data;
}

/**
 * The five endpoints Wallet calls (Apple's PassKit Web Service spec), rooted at
 * WEB_SERVICE_URL: device registration, serial listing for a device, the pass
 * itself, unregistration, and logs.
 */
export const walletPassWebService = onRequest(
  { region: "us-central1", secrets: [walletPassCert, walletPassKey], memory: "512MiB" },
  async (req, res) => {
    // req.path is everything after the function name, e.g. /v1/passes/...
    const parts = req.path.split("/").filter((p) => p.length > 0);

    try {
      // POST /v1/log — Wallet reports client-side problems here. Gold when
      // debugging a pass that won't update.
      if (req.method === "POST" && parts[0] === "v1" && parts[1] === "log") {
        logger.warn("walletPass web service log:", req.body);
        res.status(200).send();
        return;
      }

      // /v1/devices/{deviceLibraryId}/registrations/{passTypeId}[/{serial}]
      if (parts[0] === "v1" && parts[1] === "devices" && parts[3] === "registrations") {
        const deviceId = parts[2]!;
        const passTypeId = parts[4];
        if (passTypeId !== PASS_TYPE_ID) {
          res.status(404).send();
          return;
        }
        const serial = parts[5];

        if (req.method === "POST" && serial) {
          if (!(await authorizedPass(serial, applePassToken(req)))) {
            res.status(401).send();
            return;
          }
          const pushToken = req.body?.pushToken;
          if (typeof pushToken !== "string" || pushToken.length === 0) {
            res.status(400).send();
            return;
          }
          const regRef = walletDb.collection("walletRegistrations").doc(`${serial}_${deviceId}`);
          const existing = await regRef.get();
          await regRef.set({
            serial,
            deviceLibraryId: deviceId,
            pushToken,
            createdAtMs: existing.exists ? existing.data()!.createdAtMs : Date.now(),
          });
          res.status(existing.exists ? 200 : 201).send();
          return;
        }

        if (req.method === "DELETE" && serial) {
          if (!(await authorizedPass(serial, applePassToken(req)))) {
            res.status(401).send();
            return;
          }
          await walletDb.collection("walletRegistrations").doc(`${serial}_${deviceId}`).delete();
          res.status(200).send();
          return;
        }

        // GET: which of this device's passes changed since the tag?
        if (req.method === "GET" && !serial) {
          const regs = await walletDb
            .collection("walletRegistrations")
            .where("deviceLibraryId", "==", deviceId)
            .get();
          if (regs.empty) {
            res.status(404).send();
            return;
          }
          const since = Number(req.query.passesUpdatedSince ?? 0) || 0;
          const serialNumbers: string[] = [];
          let lastUpdated = since;
          for (const reg of regs.docs) {
            const passSerial = reg.data().serial as string;
            const pass = await walletDb.collection("walletPasses").doc(passSerial).get();
            const updated = (pass.data()?.updatedAtMs as number | undefined) ?? 0;
            if (updated > since) {
              serialNumbers.push(passSerial);
              lastUpdated = Math.max(lastUpdated, updated);
            }
          }
          if (serialNumbers.length === 0) {
            res.status(204).send();
            return;
          }
          res.status(200).json({ serialNumbers, lastUpdated: String(lastUpdated) });
          return;
        }
      }

      // GET /v1/passes/{passTypeId}/{serial} — the refreshed pass itself.
      if (req.method === "GET" && parts[0] === "v1" && parts[1] === "passes") {
        const passTypeId = parts[2];
        const serial = parts[3];
        if (passTypeId !== PASS_TYPE_ID || !serial) {
          res.status(404).send();
          return;
        }
        const passDoc = await authorizedPass(serial, applePassToken(req));
        if (!passDoc) {
          res.status(401).send();
          return;
        }
        const updatedAtMs = (passDoc.updatedAtMs as number | undefined) ?? Date.now();
        const ifModifiedSince = req.headers["if-modified-since"];
        if (typeof ifModifiedSince === "string") {
          const sinceMs = Date.parse(ifModifiedSince);
          // HTTP dates have second precision; compare at that grain.
          if (Number.isFinite(sinceMs) && Math.floor(updatedAtMs / 1000) <= Math.floor(sinceMs / 1000)) {
            res.status(304).send();
            return;
          }
        }
        const pkpass = await buildPass(serial);
        res
          .status(200)
          .set("Content-Type", "application/vnd.apple.pkpass")
          .set("Last-Modified", new Date(updatedAtMs).toUTCString())
          .send(pkpass);
        return;
      }

      res.status(404).send();
    } catch (err) {
      logger.error("walletPass web service error:", err);
      res.status(500).send();
    }
  }
);
