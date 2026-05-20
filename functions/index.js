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
          { type: "message", roomId: event.params.roomId }
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

    // Fetch the parent post to find who to notify.
    const postSnap = await admin
      .firestore()
      .collection("communityPosts")
      .doc(event.params.postId)
      .get();
    if (!postSnap.exists) return;

    const postAuthorUid = postSnap.data()?.authorUid;
    if (!postAuthorUid || postAuthorUid === commentAuthorUid) return;

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
  }
);

// ─── Push trigger: SOS alert ─────────────────────────────────────────────────

exports.onSosAlert = onDocumentCreated(
  "sosAlerts/{alertId}",
  async (event) => {
    const data = event.data?.data();
    if (!data) return;

    const senderName = data.senderName ?? "A HelpHer user";
    const locationLink = data.locationLink ?? null;
    const body = locationLink
      ? `${senderName} needs help! Tap to see location.`
      : `${senderName} needs help! Please check on them.`;

    // Broadcast to the sos_alerts topic — all subscribed devices receive this.
    await admin.messaging().send({
      topic: "sos_alerts",
      notification: {
        title: "🚨 SOS Alert",
        body,
      },
      data: {
        type: "sos",
        alertId: event.params.alertId,
        ...(locationLink ? { locationLink } : {}),
      },
      android: { priority: "high" },
      apns: {
        payload: {
          aps: { sound: "default", badge: 1, "content-available": 1 },
        },
      },
    });
  }
);
