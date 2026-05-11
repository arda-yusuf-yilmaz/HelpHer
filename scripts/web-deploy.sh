#!/usr/bin/env bash
set -euo pipefail

: "${RECAPTCHA_SITE_KEY:?Set RECAPTCHA_SITE_KEY to your Firebase App Check reCAPTCHA v3 site key before deploying web.}"

if ! command -v firebase >/dev/null 2>&1; then
  echo "Firebase CLI not found. Install with: npm install -g firebase-tools"
  exit 1
fi

flutter pub get
flutter build web --dart-define=RECAPTCHA_SITE_KEY="${RECAPTCHA_SITE_KEY}"
firebase deploy --only hosting
