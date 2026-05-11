# HelpHer Web App

<<<<<<< HEAD
HelpHer is a Flutter + Firebase application with full web support.

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

## Project Structure

- `lib/main.dart`: application entry point and primary UI/feature flows
- `lib/firebase_options.dart`: Firebase app configuration
- `web/`: web shell files (`index.html`, `manifest.json`, icons)
- `functions/`: Firebase Cloud Functions backend code
=======
An app designed for helping women with their daily struggles.
>>>>>>> b13ebada0276c5dc06baa8aa8c61447a80cb2760
