import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'firebase_options.dart';
import 'models/user_profile.dart';

/// Top-level handler called when a push notification arrives while the app is
/// terminated or in the background (Android / iOS / macOS).
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Firebase is already initialised by the platform before this is called.
  // No UI work here — the OS notification tray handles display.
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Desktop window chrome ─────────────────────────────────────────────────
  // macOS  → hiddenInset: traffic-light buttons stay visible, Flutter content
  //          fills the full window height (like the Claude app).
  // Windows → hidden: system title bar removed; custom controls are rendered
  //            inside the sidebar header.
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows)) {
    await windowManager.ensureInitialized();
    windowManager.waitUntilReadyToShow(
      WindowOptions(
        // hidden + windowButtonVisibility:true on macOS → transparent title bar
        // with traffic-light buttons still rendered; Flutter content extends to
        // the full window height (same behaviour as TitleBarStyle.hiddenInset on
        // older APIs). On Windows, hidden removes the system title bar entirely.
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility:
            defaultTargetPlatform == TargetPlatform.macOS ? true : false,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  // Register background handler before Firebase.initializeApp() is called.
  // Guarded because onBackgroundMessage is unsupported on Windows/Linux/Web.
  if (!kIsWeb &&
      defaultTargetPlatform != TargetPlatform.windows &&
      defaultTargetPlatform != TargetPlatform.linux) {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  }
  GoogleFonts.config.allowRuntimeFetching = true;
  final firebaseState = await _initializeFirebase();
  runApp(HelpHerApp(firebaseState: firebaseState));
}

Future<FirebaseBootstrapState> _initializeFirebase() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    if (kIsWeb) {
      if (kWebAppCheckRecaptchaSiteKey.isNotEmpty) {
        await FirebaseAppCheck.instance.activate(
          providerWeb: ReCaptchaV3Provider(kWebAppCheckRecaptchaSiteKey),
        );
      }
    } else {
      await FirebaseAppCheck.instance.activate(
        providerAndroid: kDebugMode
            ? const AndroidDebugProvider()
            : const AndroidPlayIntegrityProvider(),
        providerApple: (kDebugMode ||
                defaultTargetPlatform == TargetPlatform.macOS)
            ? const AppleDebugProvider(
                // Pass via --dart-define=APP_CHECK_DEBUG_TOKEN=<uuid>
                // Never hardcode this value — token is registered in
                // Firebase Console → App Check → Debug tokens.
                // macOS release also uses debug provider until the provisioning
                // profile is updated to include the App Attest capability.
                debugToken: String.fromEnvironment('APP_CHECK_DEBUG_TOKEN'),
              )
            : const AppleAppAttestProvider(),
        // The Firebase Flutter SDK has no production App Check provider for
        // Windows — WindowsDebugProvider is the only available option and must
        // be used unconditionally. Windows release builds therefore have no
        // App Check attestation; compensate with strict Firestore/Storage
        // security rules and monitor for abuse in the Firebase console.
        providerWindows: const WindowsDebugProvider(),
      );
    }
    return const FirebaseBootstrapState.ready();
  } on FirebaseException catch (error) {
    return FirebaseBootstrapState.failed(
      'Firebase is not configured yet. Add your Firebase app files and run '
      '`flutterfire configure`.\n\n${error.message ?? error.code}',
    );
  } catch (error) {
    return FirebaseBootstrapState.failed(
      'Firebase failed to initialize.\n\n$error',
    );
  }
}
