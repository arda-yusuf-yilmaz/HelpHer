#!/usr/bin/env bash
set -euo pipefail

flutter pub get
flutter build web

echo "Web build ready at build/web"
