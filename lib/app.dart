import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:google_fonts/google_fonts.dart';

import 'models/user_profile.dart';
import 'screens/auth/auth_gate.dart';

// ignore: constant_identifier_names
const kWebAppCheckRecaptchaSiteKey = String.fromEnvironment(
  'RECAPTCHA_SITE_KEY',
);

class AppColors {
  static const brand = Color(0xFF6B4F7C);
  static const brandDark = Color(0xFF4E3860);
  static const brandLight = Color(0xFFF3EEF7);
  static const brandMid = Color(0xFF9A74AE);
  static const text = Color(0xFF1A1A1A);
  static const text2 = Color(0xFF6B6B6B);
  static const surface = Colors.white;
}

bool isComputerPlatform(TargetPlatform platform) {
  if (kIsWeb) return true;
  return platform == TargetPlatform.macOS ||
      platform == TargetPlatform.windows ||
      platform == TargetPlatform.linux;
}

Route<T> buildSlideRoute<T>({
  required Widget page,
  Offset beginOffset = const Offset(1, 0),
  bool withDimOverlay = false,
}) {
  return PageRouteBuilder<T>(
    opaque: !withDimOverlay,
    barrierDismissible: false,
    barrierColor: withDimOverlay ? Colors.black.withValues(alpha: 0.12) : null,
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      final slide = SlideTransition(
        position: Tween<Offset>(
          begin: beginOffset,
          end: Offset.zero,
        ).animate(curved),
        child: child,
      );
      if (!withDimOverlay) {
        return slide;
      }
      return Stack(
        children: [
          FadeTransition(
            opacity: curved,
            child: Container(color: Colors.black.withValues(alpha: 0.08)),
          ),
          slide,
        ],
      );
    },
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 220),
  );
}

class HelpHerApp extends StatelessWidget {
  final FirebaseBootstrapState firebaseState;

  const HelpHerApp({super.key, required this.firebaseState});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'HelpHer',
      scrollBehavior: const _NoOverscrollBehavior(),
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF7F4FA),
        textTheme: GoogleFonts.dmSansTextTheme(),
      ),
      home: AuthGate(firebaseState: firebaseState),
    );
  }
}

class _NoOverscrollBehavior extends MaterialScrollBehavior {
  const _NoOverscrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const ClampingScrollPhysics();
  }
}
