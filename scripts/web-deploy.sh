#!/usr/bin/env bash
set -euo pipefail

if ! command -v firebase >/dev/null 2>&1; then
  echo "Firebase CLI not found. Install with: npm install -g firebase-tools"
  exit 1
fi

flutter pub get
flutter build web
firebase deploy --only hosting
