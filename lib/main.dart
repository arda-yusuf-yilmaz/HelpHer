import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_fonts/google_fonts.dart';

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
  // Register background handler before Firebase.initializeApp() is called.
  // Guarded because onBackgroundMessage is unsupported on Windows/Linux/Web.
  if (!kIsWeb &&
      defaultTargetPlatform != TargetPlatform.windows &&
      defaultTargetPlatform != TargetPlatform.linux) {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  }
  GoogleFonts.config.allowRuntimeFetching = false;
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
        providerApple: kDebugMode
            ? const AppleDebugProvider()
            : const AppleDeviceCheckProvider(),
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
