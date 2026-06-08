#!/usr/bin/env node
/**
 * Seed initial articles into Firestore.
 *
 * Usage:
 *   GOOGLE_APPLICATION_CREDENTIALS=path/to/serviceAccount.json node scripts/seed-firestore.js
 *
 * Get a service account key from:
 *   Firebase Console → Project Settings → Service accounts → Generate new private key
 *
 * Safe to re-run — uses doc IDs so existing docs are overwritten, not duplicated.
 */

const admin = require("firebase-admin");

admin.initializeApp();
const db = admin.firestore();

const ARTICLES = [
  {
    id: "safety-walking-alone",
    title: "Staying Safe When Walking Alone",
    author: "HelpHer Team",
    summary:
      "Practical tips for staying aware, confident, and safe when you're out on your own — day or night.",
    content: `## Trust your instincts
If a situation feels wrong, it probably is. Cross the street, enter a shop, or call someone — your gut is a powerful safety tool.

## Stay aware of your surroundings
Keep headphone volume low enough to hear approaching footsteps or vehicles. Avoid looking at your phone when walking in unfamiliar areas.

## Plan your route
Let someone know where you're going and when to expect you back. Share your live location with a trusted contact for longer trips.

## Keep your phone charged
A low battery is a safety risk. Carry a portable charger, or reduce screen brightness if you're running low.

## Use well-lit, populated routes
Favour streets with open shops, streetlights, and foot traffic — even if they take a few minutes longer.

## Know your emergency number
Save the local emergency number in your contacts and know how to trigger an SOS from your lock screen.`,
    category: "Safety",
    readTime: "4 min read",
    accent: "0xFF6B4F7C",
    icon: "directions_walk",
  },
  {
    id: "digital-safety-basics",
    title: "Digital Safety: Protecting Yourself Online",
    author: "HelpHer Team",
    summary:
      "How to protect your personal information, manage your privacy settings, and recognise online threats.",
    content: `## Use strong, unique passwords
A password manager (Bitwarden, 1Password) lets you use a different strong password for every account without remembering them.

## Enable two-factor authentication
2FA means an attacker needs your phone as well as your password. Enable it on email, banking, and social media first.

## Review your privacy settings
Check who can see your posts, location, and contact details on every social platform. Default settings are rarely the safest.

## Be cautious with location sharing
Posting your real-time location publicly lets strangers track your routine. Use "approximate location" or share only with close friends.

## Recognise phishing
Unexpected messages asking you to click a link or enter your password are almost always scams. Go directly to the official website instead.

## Report and block harassers
Every platform has a reporting mechanism. Use it — reports accumulate and lead to account removals. Screenshot evidence first.`,
    category: "Safety",
    readTime: "5 min read",
    accent: "0xFF4F6B7C",
    icon: "shield",
  },
  {
    id: "know-your-legal-rights",
    title: "Know Your Rights: A Practical Overview",
    author: "HelpHer Team",
    summary:
      "Key legal rights every woman should know — in public spaces, the workplace, and when dealing with authorities.",
    content: `## The right to say no
Consent applies everywhere — to physical contact, sharing personal information, and being photographed. You are never obligated to comply with requests that make you uncomfortable.

## Workplace rights
Discrimination based on gender, pregnancy, or marital status is illegal in most countries. Document incidents in writing with dates and names. HR and employment tribunals are formal escalation paths.

## Street harassment
In many jurisdictions, persistent following, groping, or threatening behaviour in public is a criminal offence. You can report to police even if the perpetrator has left the scene.

## Your rights if stopped by police
You have the right to know why you are being stopped. In most countries you are not required to answer questions beyond identifying yourself. You can request a lawyer before answering further questions.

## Restraining orders and protection orders
If you feel threatened by a specific person, a civil protection order can legally bar them from contacting or approaching you. Local legal aid organisations can help you apply at low or no cost.

## Getting legal help
Many countries have free legal helplines specifically for women. Search for "[your country] women's legal aid" — these services are confidential.`,
    category: "Legal",
    readTime: "6 min read",
    accent: "0xFF7C6B4F",
    icon: "gavel",
  },
  {
    id: "supporting-a-friend",
    title: "How to Support a Friend in Crisis",
    author: "HelpHer Team",
    summary:
      "What to say (and what not to say) when someone you care about is going through something difficult.",
    content: `## Listen first
Resist the urge to jump to solutions. Ask open questions: "How are you feeling about it?" and then actually listen without interrupting.

## Believe them
One of the most powerful things you can say is "I believe you." Doubt — even unintentional — can cause someone to shut down and stop seeking help.

## Avoid blame
Phrases like "Why didn't you leave sooner?" or "What were you wearing?" shift responsibility. Focus on the person in front of you, not the circumstances.

## Offer practical help
"Let me know if you need anything" is easy to ignore. Specific offers are better: "I'm free Thursday — can I bring you dinner?" or "I can drive you to the appointment."

## Respect their pace
Healing isn't linear. Don't pressure someone to "move on" or make decisions before they're ready.

## Take care of yourself too
Supporting someone in crisis is emotionally demanding. Seek your own support — a trusted friend, counsellor, or helpline — so you don't burn out.`,
    category: "Community",
    readTime: "5 min read",
    accent: "0xFF4F7C6B",
    icon: "favorite",
  },
];

async function seed() {
  console.log(`Seeding ${ARTICLES.length} articles…`);
  const batch = db.batch();
  for (const article of ARTICLES) {
    const { id, ...data } = article;
    const ref = db.collection("articles").doc(id);
    batch.set(ref, {
      ...data,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log(`  • ${id}`);
  }
  await batch.commit();
  console.log("Done.");
  process.exit(0);
}

seed().catch((err) => {
  console.error(err);
  process.exit(1);
});
