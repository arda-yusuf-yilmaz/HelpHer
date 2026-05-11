#!/usr/bin/env bash
set -euo pipefail

flutter pub get
flutter run -d web-server --web-port 8080
