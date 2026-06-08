const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const nodemailer = require("nodemailer");
const crypto = require("crypto");

admin.initializeApp();

const GMAIL_USER = defineSecret("GMAIL_USER");
const GMAIL_PASS = defineSecret("GMAIL_PASS");
const hashCode = (code) =>
  crypto.createHash("sha256").update(code).digest("hex");

// ─── OTP helpers ─────────────────────────────────────────────────────────────

exports.sendOtp = onCall(
  { secrets: [GMAIL_USER, GMAIL_PASS], enforceAppCheck: true },
  async (request) => {
    const email = (request.data.email || "").trim().toLowerCase();
    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      throw new HttpsError("invalid-argument", "A valid email is required.");
    }

    const otpRef = admin.firestore().collection("otps").doc(email);
    const existing = await otpRef.get();
    const existingData = existing.data();
    const cooldownMs = 60 * 1000;
    if (existingData?.lastSentAt && Date.now() - existingData.lastSentAt < cooldownMs) {
      throw new HttpsError(
        "resource-exhausted",
        "Please wait a minute before requesting a new code."
      );
    }

    const code = Math.floor(100000 + Math.random() * 900000).toString();
    const expiresAt = Date.now() + 10 * 60 * 1000;
    const codeHash = hashCode(code);

    await otpRef.set({
      codeHash,
      expiresAt,
      attempts: 0,
      lastSentAt: Date.now(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const transporter = nodemailer.createTransport({
      service: "gmail",
      auth: {
        user: GMAIL_USER.value(),
        pass: GMAIL_PASS.value(),
      },
    });

    await transporter.sendMail({
      from: `"HelpHer" <${GMAIL_USER.value()}>`,
      to: email,
      subject: "Your HelpHer sign-in code",
      text: `Your HelpHer sign-in code is: ${code}\n\nExpires in 10 minutes. If you didn't request this, ignore this email.`,
      html: `
        <div style="font-family:sans-serif;max-width:480px;margin:auto">
          <h2 style="color:#C1244A">Your HelpHer sign-in code</h2>
          <p style="font-size:36px;font-weight:bold;letter-spacing:8px;color:#C1244A">
            ${code}
          </p>
          <p>This code expires in <strong>10 minutes</strong>.</p>
          <p style="color:#999;font-size:12px">
            If you didn't request this, you can safely ignore it.
          </p>
        </div>
      `,
    });

    return { success: true };
  }
);

// ─── 2FA helpers ─────────────────────────────────────────────────────────────

/**
 * Sends a 2FA OTP to the signed-in user's own email address.
 * Unlike sendOtp (which takes email from data for sign-in), this reads the
 * email from the verified auth token so the caller cannot target other inboxes.
 */
exports.send2faOtp = onCall(
  { secrets: [GMAIL_USER, GMAIL_PASS], enforceAppCheck: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in.");
    }
    const email = request.auth.token.email?.trim().toLowerCase();
    if (!email) {
      throw new HttpsError("failed-precondition", "No email on this account.");
    }

    const otpRef = admin.firestore().collection("otps").doc(email);
    const existing = await otpRef.get();
    const existingData = existing.data();
    const cooldownMs = 60 * 1000;
    if (existingData?.lastSentAt && Date.now() - existingData.lastSentAt < cooldownMs) {
      throw new HttpsError(
        "resource-exhausted",
        "Please wait a minute before requesting a new code."
      );
    }

    const code = Math.floor(100000 + Math.random() * 900000).toString();
    const expiresAt = Date.now() + 10 * 60 * 1000;
    const codeHash = hashCode(code);

    await otpRef.set({
      codeHash,
      expiresAt,
      attempts: 0,
      lastSentAt: Date.now(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const transporter = nodemailer.createTransport({
      service: "gmail",
      auth: { user: GMAIL_USER.value(), pass: GMAIL_PASS.value() },
    });

    await transporter.sendMail({
      from: `"HelpHer" <${GMAIL_USER.value()}>`,
      to: email,
      subject: "Your HelpHer verification code",
      text: `Your HelpHer verification code is: ${code}\n\nExpires in 10 minutes. If you did not sign in to HelpHer, change your password immediately.`,
      html: `
        <div style="font-family:sans-serif;max-width:480px;margin:auto">
          <h2 style="color:#6B4F7C">Your HelpHer verification code</h2>
          <p style="font-size:36px;font-weight:bold;letter-spacing:8px;color:#6B4F7C">
            ${code}
          </p>
          <p>This code expires in <strong>10 minutes</strong>.</p>
          <p style="color:#999;font-size:12px">
            If you did not sign in to HelpHer, change your password immediately.
          </p>
        </div>
      `,
    });

    return { success: true };
  }
);

/**
 * Verifies a 2FA OTP for an already-authenticated user.
 * Returns { success: true } on match; throws on failure.
 */
exports.verify2fa = onCall({ enforceAppCheck: true }, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be signed in.");
  }

  const email = request.auth.token.email?.trim().toLowerCase();
  const code = (request.data.code || "").trim();

  if (!email || !/^\d{6}$/.test(code)) {
    throw new HttpsError("invalid-argument", "A 6-digit code is required.");
  }

  const ref = admin.firestore().collection("otps").doc(email);
  const snap = await ref.get();

  if (!snap.exists) {
    throw new HttpsError("not-found", "Invalid or expired code.");
  }

  const { codeHash, expiresAt, attempts } = snap.data();

  if (attempts >= 5) {
    await ref.delete();
    throw new HttpsError(
      "resource-exhausted",
      "Too many attempts. Please request a new code."
    );
  }

  if (Date.now() > expiresAt) {
    await ref.delete();
    throw new HttpsError("deadline-exceeded", "Invalid or expired code.");
  }

  if (hashCode(code) !== codeHash) {
    await ref.update({ attempts: admin.firestore.FieldValue.increment(1) });
    throw new HttpsError("unauthenticated", "Invalid or expired code.");
  }

  await ref.delete();
  return { success: true };
});

// ─── Account deletion ─────────────────────────────────────────────────────────

/**
 * Permanently deletes the caller's account: Firestore data (including
 * subcollections), Storage profile photo, username reservation, and
 * Firebase Auth record.  Must be called last — once Auth is deleted
 * the session token is invalid.
 */
exports.deleteAccount = onCall({ enforceAppCheck: true }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

  const db = admin.firestore();

  // users/{uid} and all subcollections (fcmTokens, notificationReads, privateData)
  await db.recursiveDelete(db.collection("users").doc(uid));

  // Other top-level documents
  const batch = db.batch();
  batch.delete(db.collection("userDirectory").doc(uid));
  const usernameSnap = await db
    .collection("usernames")
    .where("uid", "==", uid)
    .get();
  usernameSnap.docs.forEach((doc) => batch.delete(doc.ref));
  await batch.commit();

  // Storage profile photo (best-effort — may not exist)
  try {
    await admin.storage().bucket().file(`users/${uid}/profile.jpg`).delete();
  } catch (_) {}

  // Firebase Auth — must be last; invalidates the caller's session token
  await admin.auth().deleteUser(uid);

  return { success: true };
});

exports.verifyOtp = onCall({ enforceAppCheck: true }, async (request) => {
  if (request.app == null) {
    throw new HttpsError("failed-precondition", "App Check token is missing.");
  }
  const email = (request.data.email || "").trim().toLowerCase();
  const code = (request.data.code || "").trim();

  if (!email || !/^\d{6}$/.test(code)) {
    throw new HttpsError("invalid-argument", "Email and code are required.");
  }

  const ref = admin.firestore().collection("otps").doc(email);
  const snap = await ref.get();

  if (!snap.exists) {
    throw new HttpsError("not-found", "Invalid or expired code.");
  }

  const { codeHash, expiresAt, attempts } = snap.data();

  if (attempts >= 5) {
    await ref.delete();
    throw new HttpsError(
      "resource-exhausted",
      "Too many attempts. Please request a new code."
    );
  }

  if (Date.now() > expiresAt) {
    await ref.delete();
    throw new HttpsError(
      "deadline-exceeded",
      "Invalid or expired code."
    );
  }

  if (hashCode(code) !== codeHash) {
    await ref.update({ attempts: admin.firestore.FieldValue.increment(1) });
    throw new HttpsError("unauthenticated", "Invalid or expired code.");
  }

  await ref.delete();

  let userRecord;
  try {
    userRecord = await admin.auth().getUserByEmail(email);
  } catch {
    userRecord = await admin.auth().createUser({ email });
  }

  const customToken = await admin.auth().createCustomToken(userRecord.uid);
  return { customToken };
});

// ─── FCM helpers ──────────────────────────────────────────────────────────────

/**
 * Returns all FCM tokens stored for a given uid.
 * Tokens are stored as document IDs under users/{uid}/fcmTokens/{token}.
 */
async function getTokensForUid(uid) {
  const snap = await admin
    .firestore()
    .collection("users")
    .doc(uid)
    .collection("fcmTokens")
    .get();
  return snap.docs.map((d) => d.data().token).filter(Boolean);
}

/**
 * Sends an FCM multicast push to a list of tokens.
 * Automatically removes stale (unregistered) tokens from Firestore.
 *
 * @param {string[]} tokens
 * @param {string} uid  - Owner uid, used for stale-token cleanup.
 * @param {{ title: string, body: string }} notification
 * @param {Record<string, string>} [data]
 */
async function sendPushToTokens(tokens, uid, notification, data = {}) {
  if (!tokens.length) return;
  const messaging = admin.messaging();
  const response = await messaging.sendEachForMulticast({
    tokens,
    notification,
    data,
    android: { priority: "high" },
    apns: { payload: { aps: { sound: "default", badge: 1 } } },
  });

  // Remove tokens that are no longer registered.
  const stale = [];
  response.responses.forEach((res, idx) => {
    if (!res.success) {
      const code = res.error?.code ?? "";
      if (
        code === "messaging/registration-token-not-registered" ||
        code === "messaging/invalid-registration-token"
      ) {
        stale.push(tokens[idx]);
      }
    }
  });
  if (stale.length > 0) {
    const batch = admin.firestore().batch();
    stale.forEach((token) => {
      const ref = admin
        .firestore()
        .collection("users")
        .doc(uid)
        .collection("fcmTokens")
        .doc(token);
      batch.delete(ref);
    });
    await batch.commit();
  }
}

// ─── Push trigger: new chat message ──────────────────────────────────────────

exports.onNewChatMessage = onDocumentCreated(
  "chatRooms/{roomId}/messages/{messageId}",
  async (event) => {
    const data = event.data?.data();
    if (!data) return;

    const senderUid = data.senderUid;
    const senderName = data.senderName ?? "Someone";
    const isEncrypted = data.enc === true;
    const body = isEncrypted
      ? "🔒 New encrypted message"
      : (typeof data.text === "string" ? data.text.slice(0, 120) : "");

    // Fetch the chat room to get the full members list.
    const roomSnap = await admin
      .firestore()
      .collection("chatRooms")
      .doc(event.params.roomId)
      .get();
    if (!roomSnap.exists) return;

    const members = roomSnap.data()?.members ?? [];
    const recipients = members.filter((uid) => uid !== senderUid);
    if (!recipients.length) return;

    await Promise.all(
      recipients.map(async (uid) => {
        const tokens = await getTokensForUid(uid);
        await sendPushToTokens(
          tokens,
          uid,
          { title: senderName, body: body || "New message" },
          { type: "chat", roomId: event.params.roomId }
        );
      })
    );
  }
);

// ─── Push trigger: new comment ────────────────────────────────────────────────

exports.onNewComment = onDocumentCreated(
  "communityPosts/{postId}/comments/{commentId}",
  async (event) => {
    const data = event.data?.data();
    if (!data) return;

    const commentAuthorUid = data.authorUid;
    const commentAuthorName = data.author ?? "Someone";
    const commentText = typeof data.content === "string"
      ? data.content.slice(0, 120)
      : "";

    const postSnap = await admin
      .firestore()
      .collection("communityPosts")
      .doc(event.params.postId)
      .get();
    if (!postSnap.exists) return;

    const postAuthorUid = postSnap.data()?.authorUid;
    if (!postAuthorUid || postAuthorUid === commentAuthorUid) return;

    // FCM push
    const tokens = await getTokensForUid(postAuthorUid);
    await sendPushToTokens(
      tokens,
      postAuthorUid,
      {
        title: "💬 New comment on your post",
        body: `${commentAuthorName}: ${commentText}`,
      },
      { type: "comment", postId: event.params.postId }
    );

    // In-app notification (written server-side so client rules cannot be abused)
    await admin.firestore().collection("notifications").add({
      type: "comment",
      title: "New comment on your post",
      body: `${commentAuthorName}: ${commentText}`,
      targetUid: postAuthorUid,
      createdByUid: commentAuthorUid,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
);

// ─── Push trigger: SOS alert ─────────────────────────────────────────────────

exports.onSosAlert = onDocumentCreated(
  "sosAlerts/{alertId}",
  async (_event) => {
    // SOS alerts are delivered via SMS to the user's emergency contacts
    // (handled entirely client-side).  Broadcasting an FCM push to all
    // app users would expose the sender's identity and location to strangers,
    // so no FCM is sent here.
  }
);
