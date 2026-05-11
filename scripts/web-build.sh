#!/usr/bin/env bash
set -euo pipefail

: "${RECAPTCHA_SITE_KEY:?Set RECAPTCHA_SITE_KEY to your Firebase App Check reCAPTCHA v3 site key before building web.}"

flutter pub get
flutter build web --dart-define=RECAPTCHA_SITE_KEY="${RECAPTCHA_SITE_KEY}"

echo "Web build ready at build/web"
