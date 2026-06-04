# HelpHer Privacy Policy

**Last updated:** 27 May 2026  
**Data Controller:** Arda Yusuf Yılmaz, Hoda Hammoudeh, Can Köksal  
**Contact:** https://github.com/arda-yusuf-yilmaz/HelpHer/issues  
*(Please do not post personal data publicly. If your request requires sharing
personal information, we will direct you to a private channel.)*

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
AES-256-GCM encryption. The system is designed so that only the communicating
users can decrypt messages. We store only the encrypted ciphertext on our
servers and have no technical means to read message content.

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

| Data | Purpose | Legal Basis |
|---|---|---|
| Email, name | Account creation and authentication | Performance of contract |
| Username, profile photo | User identity within the app | Performance of contract |
| Encrypted messages | Enabling private communication | Performance of contract |
| Encrypted key backup | Message recovery on new devices | Performance of contract |
| Community posts | Enabling community features | Performance of contract |
| GPS location (SOS) | Emergency safety alerts | Vital interests / legitimate interest |
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

Firebase is operated by Google LLC. Data processed by Firebase may be
transferred to and stored in the United States. Google participates in the
EU-US Data Privacy Framework and may also rely on Standard Contractual
Clauses (SCCs) and other legally recognised transfer mechanisms where
applicable.

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

You have the right to:

- **Know** whether your personal data is being processed
- **Request access** to your personal data
- **Request correction** of inaccurate data
- **Request deletion** of your data
- **Object** to the processing of your data
- **Request restriction** of processing
- **Data portability** — receive your data in a structured, machine-readable format
- **Withdraw consent** at any time, without affecting the lawfulness of
  processing before withdrawal
- **Lodge a complaint** with a supervisory authority — if you believe your
  rights have been violated, you may file a complaint with your national
  data protection authority. For users in Turkey, this is the Personal Data
  Protection Authority (Kişisel Verileri Koruma Kurumu, KVKK):
  https://www.kvkk.gov.tr. For EU users, contact your local supervisory authority.

To exercise any of the above rights, contact us via:  
https://github.com/arda-yusuf-yilmaz/HelpHer/issues  
Please do not post personal information publicly in your request. We may
require verification of account ownership before processing data access or
deletion requests. We will respond to all requests within 30 days.

**To delete your account and all associated data**, use the account deletion
option within the app. Please note that messages already delivered to and
decrypted by other users may remain visible to those users after your account
is deleted, as we cannot retrieve content from other users' devices. Community
posts you have published will be removed upon account deletion.

---

## 8. Automated Decision-Making

HelpHer does not use automated decision-making or profiling that produces
legal or similarly significant effects on users. No decisions about you are
made solely by automated means.

---

## 9. Law Enforcement and Legal Requests

We may disclose personal data when required by applicable law, court order,
or a valid governmental or regulatory request. Where permitted by law, we
will attempt to notify affected users before disclosing their data.

---

## 10. Security

We take the security of your data seriously:

- Messages are end-to-end encrypted; the system is designed so that we
  cannot read them
- Your private encryption key never leaves your device in plaintext
- Connections between the app and our servers use TLS encryption
- We use Firebase App Check to prevent unauthorised access to our backend
- Emergency contacts are stored locally on your device only

No system is completely secure. If you discover a security vulnerability,
please report it responsibly via our GitHub issues page.

---

## 11. Children

HelpHer is not directed to children under the age of 18. We do not
knowingly collect personal data from anyone under 18. Users under 18 should
not use the service without parental permission. If you believe we have
inadvertently collected data from a minor, please contact us and we will
delete it promptly.

---

## 12. Changes to This Policy

We may update this privacy policy from time to time. We will notify users
of significant changes through the app. The "Last updated" date at the top
of this document reflects the most recent revision.

---

## 13. Contact

For any questions, requests, or concerns regarding this privacy policy or
your personal data, contact us at:

https://github.com/arda-yusuf-yilmaz/HelpHer/issues

Please do not post personal information publicly. If your request requires
sharing personal data, we will direct you to a private communication channel.
