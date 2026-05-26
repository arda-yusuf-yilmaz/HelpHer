# HelpHer Privacy Policy

**Last updated:** 27 May 2026  
**Data Controller:** Arda Yusuf Yılmaz, Hoda Hammoudeh, Can Köksal  
**Contact:** https://github.com/arda-yusuf-yilmaz/HelpHer/issues

---

> **Note:** This document is a draft prepared for legal review. It has not yet
> been reviewed by a qualified lawyer and does not constitute legal advice.
> Before onboarding users at scale, this policy should be reviewed by a legal
> professional familiar with Turkish data protection law (KVKK) and, where
> applicable, the EU General Data Protection Regulation (GDPR).

---

## 1. Who We Are

HelpHer is a safety and community application designed to empower women to
speak up and access support. The application is developed by Arda Yusuf
Yılmaz, Hoda Hammoudeh, and Can Köksal ("we," "us," or "our").

We are the data controller for all personal data processed through the
HelpHer application.

---

## 2. Data We Collect

### 2.1 Account Information
When you create an account, we collect:
- **Email address** — provided directly or via Google Sign-In
- **Full name** — provided directly or imported from your Google account
- **Username** — chosen by you during onboarding
- **Profile photo** — optionally uploaded by you

### 2.2 Messages
HelpHer supports direct messaging between users. All messages are
**end-to-end encrypted (E2EE)** using the X25519 key exchange protocol and
AES-256-GCM encryption. This means:
- Message content cannot be read by us or any third party, including Google
- Only you and the person you are messaging can decrypt your messages
- We store only the encrypted ciphertext on our servers

If you choose to set a recovery passphrase, an encrypted copy of your
private key is stored on our servers to allow recovery on a new device.
This backup is encrypted with AES-256-GCM using a key derived from your
passphrase via PBKDF2 (100,000 iterations, SHA-256). We cannot access
your private key.

### 2.3 Community Content
Posts and articles you publish in the Community section are stored on our
servers and are visible to other HelpHer users. Do not share personally
identifying information in public posts.

### 2.4 Emergency Alerts (SOS)
When you trigger an SOS alert, we collect:
- **Your GPS location** at the time of the alert
- **The timestamp** of the alert

This data is stored in our database and may be visible to users you have
designated as emergency contacts. Location data is collected **only** when
you explicitly trigger an SOS alert — we do not track your location
continuously.

Your emergency contacts (names and phone numbers) are stored **locally on
your device only** and are never transmitted to our servers.

### 2.5 Push Notification Token
To deliver push notifications (including safety alerts), we store a device
token provided by Firebase Cloud Messaging. This token is associated with
your account.

### 2.6 Technical Data
We may collect basic technical information such as app version and platform
(iOS, macOS, Windows) to support app functionality. We do not collect
analytics or advertising identifiers.

---

## 3. Why We Collect This Data

| Data | Purpose | Legal Basis (KVKK) |
|---|---|---|
| Email, name | Account creation and authentication | Explicit consent / contract |
| Username, profile photo | User identity within the app | Explicit consent |
| Encrypted messages | Enabling private communication | Explicit consent |
| Encrypted key backup | Message recovery on new devices | Explicit consent |
| Community posts | Enabling community features | Explicit consent |
| GPS location (SOS) | Emergency safety alerts | Legitimate interest / vital interests |
| Push notification token | Delivering safety notifications | Explicit consent |

---

## 4. Data Retention

| Data | Retention Period |
|---|---|
| Account data | Until you delete your account |
| Messages | Until you or the other party deletes the conversation |
| Community posts | Until you delete the post |
| SOS alerts | 90 days from the date of the alert |
| Push notification tokens | Until you log out or uninstall |
| Encrypted key backup | Until you generate a new keypair |

---

## 5. Third Parties

We use the following third-party services to operate HelpHer:

**Google Firebase** (Google LLC, USA)
- Firebase Authentication — account management
- Cloud Firestore — data storage
- Firebase Storage — profile photo storage
- Firebase Cloud Messaging — push notifications
- Firebase App Check — abuse prevention

Firebase is operated by Google LLC, which is subject to US law. Data
processed by Firebase may be transferred to and stored in the United States.
Google participates in the EU-US Data Privacy Framework.

We do not sell, rent, or share your personal data with any other third
parties for commercial purposes.

---

## 6. International Data Transfers

Our infrastructure is hosted on Google Firebase, which may process and
store data on servers located outside of Turkey. By using HelpHer, you
consent to this transfer. We take reasonable steps to ensure that any
such transfers are subject to appropriate safeguards.

---

## 7. Your Rights

Under the Turkish Personal Data Protection Law (KVKK, Law No. 6698) and,
where applicable, the EU General Data Protection Regulation (GDPR), you
have the right to:

- **Know** whether your personal data is being processed
- **Request access** to your personal data
- **Request correction** of inaccurate data
- **Request deletion** of your data
- **Object** to the processing of your data
- **Request restriction** of processing
- **Data portability** — receive your data in a structured, machine-readable format
- **Withdraw consent** at any time, without affecting the lawfulness of
  processing before withdrawal

To exercise any of these rights, open an issue at:  
https://github.com/arda-yusuf-yilmaz/HelpHer/issues

We will respond to all requests within 30 days.

**To delete your account and all associated data**, use the account deletion
option within the app, or contact us via the link above.

---

## 8. Security

We take the security of your data seriously:

- All messages are end-to-end encrypted — we cannot read them
- Your private encryption key never leaves your device in plaintext
- Connections between the app and our servers use TLS encryption
- We use Firebase App Check to prevent unauthorized access to our backend
- Emergency contacts are stored locally on your device only and never
  uploaded to our servers

No system is completely secure. If you discover a security vulnerability,
please report it responsibly via our GitHub issues page.

---

## 9. Children

HelpHer is intended for adult users. We do not knowingly collect personal
data from anyone under the age of 18. If you believe we have inadvertently
collected data from a minor, please contact us and we will delete it promptly.

---

## 10. Changes to This Policy

We may update this privacy policy from time to time. We will notify users
of significant changes through the app. The "Last updated" date at the top
of this document reflects the most recent revision.

---

## 11. Contact

For any questions, requests, or concerns regarding this privacy policy or
your personal data:

https://github.com/arda-yusuf-yilmaz/HelpHer/issues

---

*This privacy policy should be translated into Turkish before being
presented to users in Turkey, as required under KVKK.*
