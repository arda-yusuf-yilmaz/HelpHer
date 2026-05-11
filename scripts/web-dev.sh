#!/usr/bin/env bash
set -euo pipefail

flutter pub get
if [[ -n "${RECAPTCHA_SITE_KEY:-}" ]]; then
  flutter run -d web-server --web-port 8080 --dart-define=RECAPTCHA_SITE_KEY="${RECAPTCHA_SITE_KEY}"
else
  flutter run -d web-server --web-port 8080
fi
