# HelpHer Web App

HelpHer is a Flutter + Firebase application with full web support.
It is designed to help women navigate daily safety, support, and community needs.

## Prerequisites

- Flutter SDK installed (`flutter --version`)
- Chrome installed for local web development
- Firebase project configured (this repository already includes `lib/firebase_options.dart`)

## Run Locally (Web)

```bash
./scripts/web-dev.sh
```

This starts the app on `http://localhost:8080`.

## Production Build (Web)

```bash
./scripts/web-build.sh
```

Build output is generated in `build/web`.

## Deploy to Firebase Hosting (Optional)

```bash
./scripts/web-deploy.sh
```

## Google Sign-In Setup for Web

If Google sign-in fails in web mode:

- Enable Google provider in Firebase Console:
  - Authentication -> Sign-in method -> Google -> Enable
- Add authorized domains in Firebase Console:
  - Authentication -> Settings -> Authorized domains
  - Include `localhost` for local testing
  - Include your Firebase Hosting domain (for example `your-app.web.app`)

## Firebase Config in CI

Firebase client config files are intentionally ignored by git. GitHub Actions
restores them from base64-encoded repository secrets before running Flutter.

Create these GitHub repository secrets:

```text
FIREBASE_OPTIONS_DART_B64                 required for all workflows
ANDROID_GOOGLE_SERVICES_JSON_B64          optional until Android CI/builds are added
IOS_GOOGLE_SERVICE_INFO_PLIST_B64         optional until iOS CI/builds are added
MACOS_GOOGLE_SERVICE_INFO_PLIST_B64       required for macOS builds
```

Generate each secret from your local files:

```bash
base64 -i lib/firebase_options.dart | pbcopy
base64 -i android/app/google-services.json | pbcopy
base64 -i ios/Runner/GoogleService-Info.plist | pbcopy
base64 -i macos/Runner/GoogleService-Info.plist | pbcopy
```

Paste each copied value into the matching GitHub secret. If you rotate Firebase
or OAuth clients, regenerate the affected files locally and update the matching
secret.

## macOS Builds in CI

The macOS workflows build unsigned release artifacts by disabling Xcode code
signing in GitHub Actions. This avoids storing Apple certificates or
provisioning profiles in repository secrets. If you later need a notarized app
for public distribution, add a separate signed release workflow with Apple
Developer certificate/profile secrets.

## Project Structure

- `lib/main.dart`: application entry point and primary UI/feature flows
- `lib/firebase_options.dart`: Firebase app configuration
- `web/`: web shell files (`index.html`, `manifest.json`, icons)
- `functions/`: Firebase Cloud Functions backend code
