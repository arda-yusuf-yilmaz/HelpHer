#!/usr/bin/env bash
set -euo pipefail

decode_base64_to_file() {
  local secret_name="$1"
  local destination="$2"
  local value="$3"
  local required="$4"

  if [[ -z "${value}" ]]; then
    if [[ "${required}" == "true" ]]; then
      echo "::error::Missing required GitHub secret: ${secret_name}"
      exit 1
    fi
    echo "::notice::Skipping optional Firebase config: ${secret_name}"
    return 0
  fi

  mkdir -p "$(dirname "${destination}")"

  if printf '' | base64 --decode >/dev/null 2>&1; then
    printf '%s' "${value}" | base64 --decode >"${destination}"
  else
    printf '%s' "${value}" | base64 -D >"${destination}"
  fi
}

decode_base64_to_file \
  "FIREBASE_OPTIONS_DART_B64" \
  "lib/firebase_options.dart" \
  "${FIREBASE_OPTIONS_DART_B64:-}" \
  "true"

decode_base64_to_file \
  "ANDROID_GOOGLE_SERVICES_JSON_B64" \
  "android/app/google-services.json" \
  "${ANDROID_GOOGLE_SERVICES_JSON_B64:-}" \
  "${REQUIRE_ANDROID_GOOGLE_SERVICES_JSON:-false}"

decode_base64_to_file \
  "IOS_GOOGLE_SERVICE_INFO_PLIST_B64" \
  "ios/Runner/GoogleService-Info.plist" \
  "${IOS_GOOGLE_SERVICE_INFO_PLIST_B64:-}" \
  "${REQUIRE_IOS_GOOGLE_SERVICE_INFO_PLIST:-false}"

decode_base64_to_file \
  "MACOS_GOOGLE_SERVICE_INFO_PLIST_B64" \
  "macos/Runner/GoogleService-Info.plist" \
  "${MACOS_GOOGLE_SERVICE_INFO_PLIST_B64:-}" \
  "${REQUIRE_MACOS_GOOGLE_SERVICE_INFO_PLIST:-false}"

echo "Firebase config restored from GitHub secrets."
