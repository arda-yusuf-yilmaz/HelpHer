const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const nodemailer = require("nodemailer");
const crypto = require("crypto");

admin.initializeApp();

const GMAIL_USER = defineSecret("GMAIL_USER");
const GMAIL_PASS = defineSecret("GMAIL_PASS");
const hashCode = (code) =>
  crypto.createHash("sha256").update(code).digest("hex");

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