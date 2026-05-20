import 'package:flutter/material.dart';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_sms/flutter_sms.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:convert';

import 'firebase_options.dart';

const kWebAppCheckRecaptchaSiteKey = String.fromEnvironment(
  'RECAPTCHA_SITE_KEY',
);

bool isComputerPlatform(TargetPlatform platform) {
  if (kIsWeb) return true;
  return platform == TargetPlatform.macOS ||
      platform == TargetPlatform.windows ||
      platform == TargetPlatform.linux;
}

bool supportsNativeSms(TargetPlatform platform) {
  return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
}

bool supportsProfilePhotoPicker(TargetPlatform platform) {
  // With file selector, desktop can pick images too.
  if (kIsWeb) return true;
  return platform == TargetPlatform.android ||
      platform == TargetPlatform.iOS ||
      platform == TargetPlatform.macOS ||
      platform == TargetPlatform.windows ||
      platform == TargetPlatform.linux;
}

/// Normalizes a HelpHer username: trim, optional leading `@`, lowercase, [a-z0-9_]{3,30}.
String? normalizeHelpherUsernameKey(String raw) {
  var s = raw.trim().toLowerCase();
  if (s.startsWith('@')) {
    s = s.substring(1);
  }
  if (s.isEmpty) {
    return null;
  }
  if (!RegExp(r'^[a-z0-9_]{3,30}$').hasMatch(s)) {
    return null;
  }
  return s;
}

/// Resolves a public username to a uid via [usernames] (see Firestore rules).
Future<Map<String, String>?> lookupHelpherUidByUsername(
  FirebaseFirestore firestore,
  String rawUsername,
) async {
  final key = normalizeHelpherUsernameKey(rawUsername);
  if (key == null) {
    return null;
  }
  final doc = await firestore.collection('usernames').doc(key).get();
  if (!doc.exists) {
    return null;
  }
  final data = doc.data();
  final uid = (data?['uid'] as String?)?.trim();
  if (uid == null || uid.isEmpty) {
    return null;
  }
  final displayName = (data?['displayName'] as String?)?.trim();
  return {
    'uid': uid,
    if (displayName != null && displayName.isNotEmpty)
      'displayName': displayName,
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

class _ProfileInitialsAvatar extends StatelessWidget {
  final String name;
  final double fontSize;

  const _ProfileInitialsAvatar({required this.name, required this.fontSize});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.brandLight,
      child: Center(
        child: Text(
          name.isNotEmpty ? name.substring(0, 1).toUpperCase() : 'U',
          style: TextStyle(
            color: AppColors.brand,
            fontWeight: FontWeight.w700,
            fontSize: fontSize,
          ),
        ),
      ),
    );
  }
}

class FirebaseBootstrapState {
  final bool isReady;
  final String? message;

  const FirebaseBootstrapState._({required this.isReady, this.message});

  const FirebaseBootstrapState.ready() : this._(isReady: true);

  const FirebaseBootstrapState.failed(String message)
    : this._(isReady: false, message: message);
}

class EmergencyContact {
  final String name;
  final String phone;

  const EmergencyContact({required this.name, required this.phone});
}

class UserProfileData {
  final String name;
  final String? photoUrl;

  /// Lowercase public handle; others use this to start DMs / groups.
  final String? username;
  final List<EmergencyContact> emergencyContacts;

  const UserProfileData({
    required this.name,
    this.photoUrl,
    this.username,
    required this.emergencyContacts,
  });
}

enum _E2eeStatus { ready, newKeypair, backupAvailable }

/// Manages X25519 keypairs and AES-256-GCM encryption for direct chat E2EE.
class _E2eeManager {
  static const _storage = FlutterSecureStorage();
  static final _x25519 = X25519();
  static final _aesGcm = AesGcm.with256bits();

  static String _privKey(String uid) => 'e2ee_priv_$uid';
  static String _pubKey(String uid) => 'e2ee_pub_$uid';

  /// Ensures a keypair exists locally and publishes the public key to Firestore.
  /// Returns [_E2eeStatus.ready] if the keypair already existed,
  /// [_E2eeStatus.backupAvailable] if no local key but a Firestore backup
  /// exists (new device — caller should prompt for passphrase recovery), or
  /// [_E2eeStatus.newKeypair] if a brand-new keypair was generated (caller
  /// should prompt to set up a backup passphrase).
  static Future<_E2eeStatus> ensureKeypair(
    String uid,
    FirebaseFirestore firestore,
  ) async {
    try {
      final storedPriv = await _storage.read(key: _privKey(uid));
      final storedPub = await _storage.read(key: _pubKey(uid));
      if (storedPriv != null && storedPub != null) {
        // Already have a local keypair — just make sure public key is published.
        await firestore.collection('users').doc(uid).set(
          {'e2eePublicKey': base64.encode(base64.decode(storedPub))},
          SetOptions(merge: true),
        );
        return _E2eeStatus.ready;
      }
      // No local keypair. Check whether the user has a Firestore backup.
      final backupDoc = await firestore
          .collection('users')
          .doc(uid)
          .collection('privateData')
          .doc('keyBackup')
          .get();
      if (backupDoc.exists) {
        return _E2eeStatus.backupAvailable;
      }
      // Nothing anywhere — generate a fresh keypair.
      final keyPair = await _x25519.newKeyPair();
      final privBytes = await keyPair.extractPrivateKeyBytes();
      final pubBytes = (await keyPair.extractPublicKey()).bytes;
      await _storage.write(key: _privKey(uid), value: base64.encode(privBytes));
      await _storage.write(key: _pubKey(uid), value: base64.encode(pubBytes));
      await firestore.collection('users').doc(uid).set(
        {'e2eePublicKey': base64.encode(pubBytes)},
        SetOptions(merge: true),
      );
      return _E2eeStatus.newKeypair;
    } catch (_) {
      return _E2eeStatus.ready; // Non-fatal fallback.
    }
  }

  /// Encrypts the local private key with a PBKDF2-derived wrapping key and
  /// stores the result in Firestore under users/{uid}/privateData/keyBackup.
  static Future<void> backupPrivateKey(
    String uid,
    String passphrase,
    FirebaseFirestore firestore,
  ) async {
    final privB64 = await _storage.read(key: _privKey(uid));
    if (privB64 == null) return;
    final privBytes = base64.decode(privB64);

    final salt = _aesGcm.newNonce(); // 16 random bytes as salt
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );
    final wrappingKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
    final wrappingKeyBytes = await wrappingKey.extractBytes();
    final wrapKey = await _aesGcm.newSecretKeyFromBytes(wrappingKeyBytes);
    final nonce = _aesGcm.newNonce();
    final box = await _aesGcm.encrypt(privBytes, secretKey: wrapKey, nonce: nonce);

    await firestore
        .collection('users')
        .doc(uid)
        .collection('privateData')
        .doc('keyBackup')
        .set({
      'enc': base64.encode([...box.cipherText, ...box.mac.bytes]),
      'salt': base64.encode(salt),
      'iv': base64.encode(nonce),
    });
  }

  /// Fetches the Firestore backup, derives the wrapping key from [passphrase],
  /// decrypts the private key, and saves it to local secure storage.
  /// Returns true on success, false if the passphrase is wrong or no backup exists.
  static Future<bool> restoreFromBackup(
    String uid,
    String passphrase,
    FirebaseFirestore firestore,
  ) async {
    try {
      final doc = await firestore
          .collection('users')
          .doc(uid)
          .collection('privateData')
          .doc('keyBackup')
          .get();
      if (!doc.exists) return false;
      final data = doc.data()!;
      final salt = base64.decode(data['salt'] as String);
      final iv = base64.decode(data['iv'] as String);
      final raw = base64.decode(data['enc'] as String);
      final mac = raw.sublist(raw.length - 16);
      final ct = raw.sublist(0, raw.length - 16);

      final pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: 100000,
        bits: 256,
      );
      final wrappingKey = await pbkdf2.deriveKey(
        secretKey: SecretKey(utf8.encode(passphrase)),
        nonce: salt,
      );
      final wrapKey = await _aesGcm.newSecretKeyFromBytes(
        await wrappingKey.extractBytes(),
      );
      final privBytes = await _aesGcm.decrypt(
        SecretBox(ct, nonce: iv, mac: Mac(mac)),
        secretKey: wrapKey,
      );

      // Reconstruct the X25519 public key from the private key.
      final keyPair = await _x25519.newKeyPairFromSeed(privBytes);
      final pubBytes = (await keyPair.extractPublicKey()).bytes;

      await _storage.write(key: _privKey(uid), value: base64.encode(privBytes));
      await _storage.write(key: _pubKey(uid), value: base64.encode(pubBytes));
      await firestore.collection('users').doc(uid).set(
        {'e2eePublicKey': base64.encode(pubBytes)},
        SetOptions(merge: true),
      );
      return true;
    } catch (_) {
      return false; // Wrong passphrase or decryption failure.
    }
  }

  /// Derives the shared secret bytes for a direct chat with [theirPublicKeyB64].
  /// Returns null if our keypair is missing.
  static Future<Uint8List?> deriveSharedSecret(
    String myUid,
    String theirPublicKeyB64,
  ) async {
    try {
      final privB64 = await _storage.read(key: _privKey(myUid));
      final pubB64 = await _storage.read(key: _pubKey(myUid));
      if (privB64 == null || pubB64 == null) return null;
      final keyPair = SimpleKeyPairData(
        base64.decode(privB64),
        publicKey: SimplePublicKey(
          base64.decode(pubB64),
          type: KeyPairType.x25519,
        ),
        type: KeyPairType.x25519,
      );
      final sharedKey = await _x25519.sharedSecretKey(
        keyPair: keyPair,
        remotePublicKey: SimplePublicKey(
          base64.decode(theirPublicKeyB64),
          type: KeyPairType.x25519,
        ),
      );
      return Uint8List.fromList(await sharedKey.extractBytes());
    } catch (_) {
      return null;
    }
  }

  /// Encrypts [plaintext]. Returns base64-encoded `iv` and `ct` (ciphertext+MAC).
  static Future<({String iv, String ct})> encrypt(
    String plaintext,
    Uint8List sharedSecret,
  ) async {
    final secretKey = await _aesGcm.newSecretKeyFromBytes(sharedSecret);
    final nonce = _aesGcm.newNonce();
    final box = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonce,
    );
    return (
      iv: base64.encode(box.nonce),
      ct: base64.encode([...box.cipherText, ...box.mac.bytes]),
    );
  }

  /// Decrypts a message. Returns null if decryption fails.
  static Future<String?> decrypt(
    String ivB64,
    String ctB64,
    Uint8List sharedSecret,
  ) async {
    try {
      final secretKey = await _aesGcm.newSecretKeyFromBytes(sharedSecret);
      final raw = base64.decode(ctB64);
      final mac = raw.sublist(raw.length - 16);
      final ct = raw.sublist(0, raw.length - 16);
      final plain = await _aesGcm.decrypt(
        SecretBox(ct, nonce: base64.decode(ivB64), mac: Mac(mac)),
        secretKey: secretKey,
      );
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }
}

class HelpHerArticle {
  final String id;
  final String title;
  final String author;
  final String readTime;
  final String category;
  final String summary;
  final String content;
  final IconData icon;
  final Color accent;

  const HelpHerArticle({
    required this.id,
    required this.title,
    required this.author,
    required this.readTime,
    required this.category,
    required this.summary,
    required this.content,
    required this.icon,
    required this.accent,
  });

  Map<String, dynamic> toFirestoreData() {
    return {
      'title': title,
      'author': author,
      'readTime': readTime,
      'category': category,
      'summary': summary,
      'content': content,
    };
  }

  factory HelpHerArticle.fromFirestoreData(
    String id,
    Map<String, dynamic> data,
  ) {
    final category = (data['category'] as String?) ?? 'Safety';
    return HelpHerArticle(
      id: id,
      title: (data['title'] as String?) ?? '',
      author: (data['author'] as String?) ?? 'HelpHer Team',
      readTime: (data['readTime'] as String?) ?? '1 min',
      category: category,
      summary: (data['summary'] as String?) ?? '',
      content: (data['content'] as String?) ?? '',
      icon: _iconForCategory(category),
      accent: _accentForCategory(category),
    );
  }

  static IconData _iconForCategory(String category) {
    switch (category) {
      case 'Legal':
        return Icons.gavel_outlined;
      case 'Community':
        return Icons.people_alt_outlined;
      case 'Safety':
      default:
        return Icons.shield_outlined;
    }
  }

  static Color _accentForCategory(String category) {
    switch (category) {
      case 'Legal':
        return const Color(0xFFEDE7F6);
      case 'Community':
        return const Color(0xFFE8F5E9);
      case 'Safety':
      default:
        return const Color(0xFFFFEBEE);
    }
  }
}

class CommunityPost {
  final String id;
  final String author;
  final String authorUid;
  final String? authorPhotoUrl;
  final String role;
  final String content;
  final int likes;
  final int comments;
  final String tag;
  final DateTime createdAt;

  const CommunityPost({
    required this.id,
    required this.author,
    required this.authorUid,
    this.authorPhotoUrl,
    required this.role,
    required this.content,
    required this.likes,
    required this.comments,
    required this.tag,
    required this.createdAt,
  });
}

enum AppNotificationType { article, message, comment }

class AppNotificationItem {
  final String id;
  final AppNotificationType type;
  final String title;
  final String body;
  final DateTime createdAt;
  final bool isRead;
  final String? createdByUid;

  const AppNotificationItem({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.isRead,
    this.createdByUid,
  });

  AppNotificationItem copyWith({bool? isRead}) {
    return AppNotificationItem(
      id: id,
      type: type,
      title: title,
      body: body,
      createdAt: createdAt,
      isRead: isRead ?? this.isRead,
      createdByUid: createdByUid,
    );
  }
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

const List<HelpHerArticle> kSeedArticles = [
  HelpHerArticle(
    id: 'seed-1',
    title: 'Know Your Rights at Work',
    author: 'HelpHer Legal Team',
    readTime: '6 min',
    category: 'Legal',
    summary: 'What to document and how to report workplace harassment safely.',
    content:
        'Start by documenting incidents with dates, times, and witnesses. Keep '
        'copies of messages or emails in a personal folder. Review internal HR '
        'reporting procedures, and request all responses in writing. If you need '
        'external help, local bar associations and women support centers can guide '
        'you on complaint processes and legal aid.',
    icon: Icons.gavel_outlined,
    accent: Color(0xFFEDE7F6),
  ),
  HelpHerArticle(
    id: 'seed-2',
    title: 'Safety Planning for Difficult Situations',
    author: 'Crisis Support Network',
    readTime: '8 min',
    category: 'Safety',
    summary: 'Create a practical plan before an emergency happens.',
    content:
        'Prepare a short emergency checklist: trusted contacts, transport options, '
        'and safe places nearby. Keep essentials ready, including IDs, medication, '
        'and backup phone charging. Share a code word with trusted people to quickly '
        'signal help if speaking freely is not possible.',
    icon: Icons.shield_outlined,
    accent: Color(0xFFFFEBEE),
  ),
  HelpHerArticle(
    id: 'seed-3',
    title: 'How to Support a Friend in Crisis',
    author: 'Dr. Ayse Kaya',
    readTime: '5 min',
    category: 'Community',
    summary: 'Listen first, avoid judgment, and connect to professional help.',
    content:
        'Lead with calm listening and clear validation: "I believe you." Avoid '
        'pressuring your friend to make immediate decisions. Offer concrete support '
        'such as accompanying them to services or helping organize documents. '
        'Encourage professional support and respect their pace.',
    icon: Icons.people_alt_outlined,
    accent: Color(0xFFE8F5E9),
  ),
  HelpHerArticle(
    id: 'seed-4',
    title: 'Digital Privacy Basics',
    author: 'HelpHer Security Team',
    readTime: '4 min',
    category: 'Safety',
    summary: 'Simple steps to improve privacy on your phone and accounts.',
    content:
        'Use unique passwords and enable two-factor authentication for critical '
        'accounts. Review app permissions regularly and disable location sharing '
        'for apps that do not need it. Keep your device updated and lock it with a '
        'strong passcode or biometric login.',
    icon: Icons.shield_outlined,
    accent: Color(0xFFFFEBEE),
  ),
];

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
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
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

enum AuthMode { signIn, signUp }

class AuthGate extends StatefulWidget {
  final FirebaseBootstrapState firebaseState;

  const AuthGate({super.key, required this.firebaseState});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  AuthMode _authMode = AuthMode.signIn;
  bool _isSigningIn = false;
  String? _authMessage;
  String? _eligibilityMessage;

  FirebaseAuth get _firebaseAuth => FirebaseAuth.instance;
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  String? _lastSyncedUserUid;
  bool _isConfirmingEligibility = false;

  @override
  void initState() {
    super.initState();
    _initGoogleSignIn();
  }

  Future<void> _initGoogleSignIn() async {
    try {
      if (kIsWeb) {
        return;
      }
      // Windows and Linux have no native Google Sign-In SDK; skip init there.
      if (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux) {
        return;
      }
      // iOS and macOS: initialise with the OAuth client ID from Firebase config.
      final clientId = DefaultFirebaseOptions.currentPlatform.iosClientId;
      if (clientId != null && clientId.isNotEmpty) {
        await _googleSignIn.initialize(clientId: clientId);
      }
    } on UnimplementedError {
      // Widget tests can run without a platform implementation for sign-in.
    } catch (_) {
      // Keep auth screen usable even if Google Sign-In init fails.
    }
  }
  
Future<void> _signInWithGoogle() async {
    if (!widget.firebaseState.isReady) {
      return;
    }
    setState(() => _isSigningIn = true);
    try {
      if (kIsWeb) {
        await _firebaseAuth.signInWithPopup(GoogleAuthProvider());
        _clearMessage();
        return;
      }

      // Windows has no native Google Sign-In SDK; use Firebase's browser flow.
      if (defaultTargetPlatform == TargetPlatform.windows) {
        await _firebaseAuth.signInWithProvider(
          GoogleAuthProvider()
            ..addScope('email')
            ..addScope('profile'),
        );
        _clearMessage();
        return;
      }

      // iOS, macOS, and Android: use the native GoogleSignIn SDK (GIDSignIn).
      // macOS release builds require a Developer ID provisioning profile with
      // keychain-access-groups to allow GIDSignIn to store OAuth tokens.
      final account = await _googleSignIn.authenticate();
      final googleAuth = account.authentication;
      final idToken = googleAuth.idToken;
      if (idToken == null) {
        throw FirebaseAuthException(
          code: 'missing-google-id-token',
          message: 'Google did not return an ID token.',
        );
      }
      final credential = GoogleAuthProvider.credential(idToken: idToken);
      await _firebaseAuth.signInWithCredential(credential);
      _clearMessage();
    } on FirebaseAuthException catch (error) {
      _showMessage(_friendlyAuthError(error.message));
    } catch (error) {
      _showMessage('Google sign-in failed. Please try again or use email/password.');
    } finally {
      if (mounted) {
        setState(() => _isSigningIn = false);
      }
    }
  }

  Future<void> _submitEmailAuth() async {
    if (!widget.firebaseState.isReady) {
      return;
    }
    setState(() => _isSigningIn = true);
    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text.trim();
      if (email.isEmpty || password.isEmpty) {
        _showMessage('Enter both email and password.');
        return;
      }

      if (_authMode == AuthMode.signUp) {
        final cred = await _firebaseAuth.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
        await cred.user?.sendEmailVerification();
        return;
      } else {
        await _firebaseAuth.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
        await _firebaseAuth.currentUser?.reload();
        final verified = _firebaseAuth.currentUser?.emailVerified ?? false;
        if (!verified) {
          await _firebaseAuth.currentUser?.sendEmailVerification();
          _showMessage(
            'Your email isn\'t verified yet — we just resent the link. '
            'Check your inbox and click it, then sign in again.',
          );
          return;
        }
      }
      _clearMessage();
    } on FirebaseAuthException catch (error) {
      _showMessage(_friendlyAuthError(error.message));
    } catch (error) {
      _showMessage('Sign in failed. Please check your connection and try again.');
    } finally {
      if (mounted) {
        setState(() => _isSigningIn = false);
      }
    }
  }

  Future<void> _resetPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      _showMessage('Enter your email address first, then tap "Forgot password?".');
      return;
    }
    setState(() => _isSigningIn = true);
    try {
      await _firebaseAuth.sendPasswordResetEmail(email: email);
      _showMessage('Password reset email sent to $email. Check your inbox.');
    } on FirebaseAuthException catch (error) {
      _showMessage(_friendlyAuthError(error.message));
    } finally {
      if (mounted) setState(() => _isSigningIn = false);
    }
  }

  Future<void> _signOut() async {
    await _firebaseAuth.signOut();
    if (!kIsWeb) {
      await _googleSignIn.signOut();
    }
  }

  Future<void> _refreshUser() async {
    await _firebaseAuth.currentUser?.reload();
    if (mounted) setState(() {});
  }

  Future<void> _syncUserProfileDoc(User user) async {
    final email = user.email?.trim().toLowerCase();
    final userRef = _firestore.collection('users').doc(user.uid);
    await userRef.set({
      'uid': user.uid,
      'email': email,
      'displayName': user.displayName?.trim(),
      'lastSignInAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    if (email != null && email.isNotEmpty) {
      final userSnap = await userRef.get();
      final userData = userSnap.data();
      final username =
          ((userData?['usernameLower'] as String?) ??
                  (userData?['username'] as String?))
              ?.trim();
      final photoUrl = (userData?['photoUrl'] as String?)?.trim();
      await _firestore.collection('userDirectory').doc(user.uid).set({
        'uid': user.uid,
        'displayName': user.displayName?.trim(),
        if (username != null && username.isNotEmpty) 'username': username,
        if (username != null && username.isNotEmpty) 'usernameLower': username,
        if (photoUrl != null && photoUrl.isNotEmpty) 'photoUrl': photoUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
  }

  Future<void> _confirmWomenOnlyEligibility(User user) async {
    if (_isConfirmingEligibility) {
      return;
    }
    setState(() {
      _isConfirmingEligibility = true;
      _eligibilityMessage = null;
    });
    try {
      await _firestore.collection('users').doc(user.uid).set({
        'isWomanConfirmed': true,
        'womenOnlyConfirmedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } on FirebaseException catch (error) {
      if (mounted) {
        setState(() {
          _eligibilityMessage =
              error.message ??
              'Could not save your confirmation. Please try again.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _eligibilityMessage =
              'Could not save your confirmation. Please check your connection and try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isConfirmingEligibility = false);
      }
    }
  }

  String _friendlyAuthError(String? message) {
    if (message == null) return 'Authentication failed.';
    final lower = message.toLowerCase();
    if (lower.contains('keychain') || lower.contains('nserror') || lower.contains('nslocalizedfailure')) {
      return 'Sign-in failed. Please try again or use a different method.';
    }
    return message;
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _authMessage = message;
    });
  }

  void _clearMessage() {
    if (!mounted) {
      return;
    }
    setState(() {
      _authMessage = null;
    });
  }

  String _userNameFor(User user) {
    final displayName = user.displayName?.trim();
    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }
    final email = user.email?.trim();
    if (email != null && email.isNotEmpty) {
      return email;
    }
    return 'HelpHer User';
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.firebaseState.isReady) {
      return _buildAuthScreen(
        configurationMessage: widget.firebaseState.message,
      );
    }

    return StreamBuilder<User?>(
      stream: _firebaseAuth.authStateChanges(),
      builder: (context, snapshot) {
        final user = snapshot.data;
        if (user != null) {
          // Gate email/password users until they verify their address.
          // Google users are always verified, so this branch never triggers for them.
          final liveUser = _firebaseAuth.currentUser;
          final isEmailProvider =
              liveUser?.providerData.any((p) => p.providerId == 'password') ??
              false;
          if (isEmailProvider && !(liveUser?.emailVerified ?? false)) {
            return VerifyEmailScreen(
              email: liveUser?.email ?? '',
              onResend: () async =>
                  liveUser?.sendEmailVerification(),
              onContinue: _refreshUser,
              onSignOut: _signOut,
            );
          }
          if (_lastSyncedUserUid != user.uid) {
            _lastSyncedUserUid = user.uid;
            _syncUserProfileDoc(user);
          }
          return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: _firestore.collection('users').doc(user.uid).snapshots(),
            builder: (context, userDocSnapshot) {
              if (userDocSnapshot.hasError) {
                return WomenOnlyEligibilityScreen(
                  onConfirm: () => _confirmWomenOnlyEligibility(user),
                  onSignOut: _signOut,
                  isSaving: _isConfirmingEligibility,
                  message:
                      'Could not load your profile right now. Please try again.',
                );
              }
              final userData = userDocSnapshot.data?.data();
              final isWomanConfirmed = userData?['isWomanConfirmed'] == true;
              final canManageArticles = userData?['isEditor'] == true;
              final isAdmin = userData?['isAdmin'] == true;
              if (!isWomanConfirmed) {
                return WomenOnlyEligibilityScreen(
                  onConfirm: () => _confirmWomenOnlyEligibility(user),
                  onSignOut: _signOut,
                  isSaving: _isConfirmingEligibility,
                  message: _eligibilityMessage,
                );
              }
              // After eligibility confirmation, require a username before entering the app.
              final existingUsername = (userData?['usernameLower'] as String?)
                  ?.trim();
              if (existingUsername == null || existingUsername.isEmpty) {
                return ChooseUsernameScreen(
                  currentUserUid: user.uid,
                  onSignOut: _signOut,
                );
              }
              return MainShell(
                initialUserName: _userNameFor(user),
                currentUsername: existingUsername,
                canManageArticles: canManageArticles,
                currentUserUid: user.uid,
                isAdmin: isAdmin,
                onSignOut: _signOut,
              );
            },
          );
        }
        _lastSyncedUserUid = null;
        return _buildAuthScreen();
      },
    );
  }

  Widget _buildAuthScreen({String? configurationMessage}) {
    final isCreateAccount = _authMode == AuthMode.signUp;
    final isConfigured = widget.firebaseState.isReady;
    final isBusy = _isSigningIn;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.favorite, color: AppColors.brand, size: 56),
                  const SizedBox(height: 12),
                  Text(
                    'Welcome to HelpHer',
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isCreateAccount
                        ? 'Create a Firebase account or continue with Google.'
                        : 'Sign in with Firebase email/password or Google.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.text2),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: isBusy || !isConfigured
                          ? null
                          : _submitEmailAuth,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brand,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Text(
                        isBusy
                            ? 'Please wait...'
                            : isCreateAccount
                            ? 'Create account'
                            : 'Sign in',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: isBusy
                        ? null
                        : () {
                            setState(() {
                              _authMode = isCreateAccount
                                  ? AuthMode.signIn
                                  : AuthMode.signUp;
                              _authMessage = null;
                            });
                          },
                    child: Text(
                      isCreateAccount
                          ? 'Already have an account? Sign in'
                          : 'Need an account? Create one',
                    ),
                  ),
                  if (!isCreateAccount)
                    TextButton(
                      onPressed: isBusy ? null : _resetPassword,
                      child: const Text('Forgot password?'),
                    ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: isBusy || !isConfigured
                          ? null
                          : _signInWithGoogle,
                      icon: const Icon(Icons.login),
                      label: const Text('Continue with Google'),
                    ),
                  ),
                  if (_authMessage != null || configurationMessage != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.brandLight,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _authMessage ?? configurationMessage!,
                        style: const TextStyle(color: AppColors.brandDark),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class VerifyEmailScreen extends StatefulWidget {
  final String email;
  final Future<void> Function() onResend;
  final Future<void> Function() onContinue;
  final Future<void> Function() onSignOut;

  const VerifyEmailScreen({
    super.key,
    required this.email,
    required this.onResend,
    required this.onContinue,
    required this.onSignOut,
  });

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  bool _resent = false;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.mark_email_unread_outlined,
                      size: 64, color: AppColors.brand),
                  const SizedBox(height: 16),
                  const Text(
                    'Verify your email',
                    style: TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'We sent a verification link to\n${widget.email}\n\nOpen it, then come back and tap Continue.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.text2, height: 1.5),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              setState(() => _busy = true);
                              await widget.onContinue();
                              if (mounted) setState(() => _busy = false);
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brand,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('I\'ve verified — Continue'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _resent
                        ? null
                        : () async {
                            await widget.onResend();
                            if (mounted) setState(() => _resent = true);
                          },
                    child: Text(
                      _resent ? 'Email sent!' : 'Resend verification email',
                      style: TextStyle(
                          color: _resent ? AppColors.text2 : AppColors.brand),
                    ),
                  ),
                  TextButton(
                    onPressed: widget.onSignOut,
                    child: const Text('Sign out',
                        style: TextStyle(color: AppColors.text2)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class WomenOnlyEligibilityScreen extends StatefulWidget {
  final Future<void> Function() onConfirm;
  final Future<void> Function() onSignOut;
  final bool isSaving;
  final String? message;

  const WomenOnlyEligibilityScreen({
    super.key,
    required this.onConfirm,
    required this.onSignOut,
    required this.isSaving,
    this.message,
  });

  @override
  State<WomenOnlyEligibilityScreen> createState() =>
      _WomenOnlyEligibilityScreenState();
}

class _WomenOnlyEligibilityScreenState
    extends State<WomenOnlyEligibilityScreen> {
  bool _accepted = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Card(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Women-only confirmation',
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          color: AppColors.text,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'HelpHer is designed as a women-only support space. '
                        'To continue, please confirm you identify as a woman '
                        'and agree to respect this community policy.',
                        style: TextStyle(color: AppColors.text2, height: 1.45),
                      ),
                      const SizedBox(height: 16),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _accepted,
                        onChanged: widget.isSaving
                            ? null
                            : (value) =>
                                  setState(() => _accepted = value == true),
                        title: const Text(
                          'I confirm that I identify as a woman.',
                        ),
                        subtitle: const Text(
                          'False confirmation may result in account removal.',
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                      const SizedBox(height: 12),
                      if (widget.message != null) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.brandLight,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            widget.message!,
                            style: const TextStyle(color: AppColors.brandDark),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: (!_accepted || widget.isSaving)
                              ? null
                              : widget.onConfirm,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.brand,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: widget.isSaving
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Confirm and continue'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: TextButton(
                          onPressed: widget.isSaving ? null : widget.onSignOut,
                          child: const Text('Sign out'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppColors {
  static const brand = Color(0xFFC1244A);
  static const brandDark = Color(0xFF8C1535);
  static const brandLight = Color(0xFFF9E8EC);
  static const brandMid = Color(0xFFE8547A);
  static const text = Color(0xFF1A1A1A);
  static const text2 = Color(0xFF6B6B6B);
  static const surface = Colors.white;
}

class ChooseUsernameScreen extends StatefulWidget {
  final String currentUserUid;
  final Future<void> Function() onSignOut;

  const ChooseUsernameScreen({
    super.key,
    required this.currentUserUid,
    required this.onSignOut,
  });

  @override
  State<ChooseUsernameScreen> createState() => _ChooseUsernameScreenState();
}

class _ChooseUsernameScreenState extends State<ChooseUsernameScreen> {
  final TextEditingController _controller = TextEditingController();
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final raw = _controller.text.trim();
    final key = normalizeHelpherUsernameKey(raw);
    if (key == null) {
      setState(
        () => _errorMessage =
            'Usernames must be 3–30 characters: lowercase letters, numbers, or underscores.',
      );
      return;
    }
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      final unameRef = _firestore.collection('usernames').doc(key);
      final userRef = _firestore.collection('users').doc(widget.currentUserUid);

      // Check availability atomically via Firestore transaction.
      await _firestore.runTransaction((tx) async {
        final unameSnap = await tx.get(unameRef);
        if (unameSnap.exists) {
          final owner = (unameSnap.data()?['uid'] as String?)?.trim();
          if (owner != widget.currentUserUid) {
            throw FirebaseException(
              plugin: 'firestore',
              code: 'already-exists',
              message: 'That username is already taken.',
            );
          }
        }
        final userSnap = await tx.get(userRef);
        final displayName =
            ((userSnap.data()?['displayName'] as String?)?.trim()) ?? '';
        tx.set(unameRef, {
          'uid': widget.currentUserUid,
          'usernameLower': key,
          if (displayName.isNotEmpty) 'displayName': displayName,
        });
        tx.set(userRef, {
          'username': key,
          'usernameLower': key,
        }, SetOptions(merge: true));
      });
      await _firestore
          .collection('userDirectory')
          .doc(widget.currentUserUid)
          .set({
            'uid': widget.currentUserUid,
            'username': key,
            'usernameLower': key,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
      // AuthGate's StreamBuilder on the users doc will now see usernameLower
      // and automatically transition to MainShell — no manual navigation needed.
    } on FirebaseException catch (e) {
      if (mounted) {
        setState(
          () => _errorMessage =
              e.message ?? 'Could not save username. Please try another.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _errorMessage = 'Something went wrong. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.alternate_email,
                    color: AppColors.brand,
                    size: 48,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Choose your username',
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Pick a unique handle. Others will use this to find you in chats. '
                    'Choose carefully — your username cannot be changed once set.',
                    style: TextStyle(color: AppColors.text2, height: 1.45),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _controller,
                    autofocus: true,
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _isSaving ? null : _save(),
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      hintText: 'your_handle',
                      prefixText: '@',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.brandLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: AppColors.brandDark),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brand,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Continue'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: TextButton(
                      onPressed: _isSaving ? null : widget.onSignOut,
                      child: const Text('Sign out'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MainShell extends StatefulWidget {
  final String initialUserName;
  final String currentUsername;
  final bool canManageArticles;
  final String currentUserUid;
  final bool isAdmin;
  final VoidCallback onSignOut;

  const MainShell({
    super.key,
    required this.initialUserName,
    required this.currentUsername,
    required this.canManageArticles,
    required this.currentUserUid,
    required this.isAdmin,
    required this.onSignOut,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  List<HelpHerArticle> _articles = [];
  late UserProfileData _profile;
  late final PageController _pageController;
  late final AnimationController _tabEntranceController;
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _notificationsStream;
  late final Stream<QuerySnapshot<Map<String, dynamic>>>
  _notificationReadsStream;
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _chatRoomsStream;
  int _tabSlideDirection = 1;
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _articlesRef =>
      _firestore.collection('articles');

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _currentIndex);
    _tabEntranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: 1,
    );
    _profile = UserProfileData(
      name: widget.initialUserName,
      username: widget.currentUsername.trim().isNotEmpty
          ? widget.currentUsername.trim()
          : null,
      emergencyContacts: const [],
    );
    _notificationsStream = _firestore
        .collection('notifications')
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots();
    _notificationReadsStream = _firestore
        .collection('users')
        .doc(widget.currentUserUid)
        .collection('notificationReads')
        .snapshots();
    _chatRoomsStream = _firestore
        .collection('chatRooms')
        .where('members', arrayContains: widget.currentUserUid)
        .snapshots();
    _loadArticles();
    _loadProfile();
    _initE2eeSetup();
    if (kIsWeb && kWebAppCheckRecaptchaSiteKey.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              'Web App Check is not configured. Run with '
              '--dart-define=RECAPTCHA_SITE_KEY=YOUR_KEY.',
            ),
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _tabEntranceController.dispose();
    super.dispose();
  }

  void _switchTab(int index, {bool animated = false}) {
    if (_currentIndex == index) {
      return;
    }
    final previousIndex = _currentIndex;
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      HapticFeedback.selectionClick();
    }
    setState(() => _currentIndex = index);
    final distance = (index - previousIndex).abs();
    _tabSlideDirection = index > previousIndex ? 1 : -1;
    if (animated && distance == 1) {
      _tabEntranceController.value = 1;
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 230),
        curve: Curves.easeOutQuart,
      );
      return;
    }
    _pageController.jumpToPage(index);
    if (animated && distance > 1) {
      _tabEntranceController
        ..value = 0
        ..forward();
      return;
    }
    _tabEntranceController.value = 1;
  }

  void _openArticlesScreen(BuildContext context) {
    Navigator.of(context).push(
      buildSlideRoute<void>(
        page: ArticlesScreen(
          articles: _articles,
          canManageArticles: widget.canManageArticles,
          onArticleAdded: _addArticle,
          onArticleUpdated: _updateArticle,
          onArticleDeleted: _deleteArticle,
        ),
      ),
    );
  }

  static const _secureStorage = FlutterSecureStorage();

  String get _contactsStorageKey =>
      'emergency_contacts_${widget.currentUserUid}';

  Future<List<EmergencyContact>> _loadContactsLocally() async {
    try {
      final raw = await _secureStorage.read(key: _contactsStorageKey);
      if (raw == null) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((item) {
        final m = item as Map<String, dynamic>;
        return EmergencyContact(
          name: (m['name'] as String?) ?? '',
          phone: (m['phone'] as String?) ?? '',
        );
      }).where((c) => c.name.isNotEmpty || c.phone.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveContacts(List<EmergencyContact> contacts) async {
    try {
      final encoded = jsonEncode(
        contacts.map((c) => {'name': c.name, 'phone': c.phone}).toList(),
      );
      await _secureStorage.write(key: _contactsStorageKey, value: encoded);
    } catch (_) {
      // Silently ignore — local state already updated.
    }
  }

  Future<void> _loadProfile() async {
    try {
      final doc = await _firestore
          .collection('users')
          .doc(widget.currentUserUid)
          .get();
      final data = doc.data();
      if (!mounted || data == null) return;

      // Migrate contacts from Firestore to local secure storage if present.
      var contacts = await _loadContactsLocally();
      if (contacts.isEmpty && data.containsKey('emergencyContacts')) {
        final rawContacts = data['emergencyContacts'];
        if (rawContacts is List) {
          for (final item in rawContacts) {
            if (item is Map) {
              final name = (item['name'] as String?) ?? '';
              final phone = (item['phone'] as String?) ?? '';
              if (name.isNotEmpty || phone.isNotEmpty) {
                contacts.add(EmergencyContact(name: name, phone: phone));
              }
            }
          }
        }
        // Save to local storage and remove from Firestore.
        await _saveContacts(contacts);
        await _firestore
            .collection('users')
            .doc(widget.currentUserUid)
            .update({'emergencyContacts': FieldValue.delete()});
      }

      final usernameRaw = (data['username'] as String?)?.trim();
      final usernameLowerRaw = (data['usernameLower'] as String?)?.trim();
      final usernameLoaded = usernameRaw != null && usernameRaw.isNotEmpty
          ? usernameRaw
          : (usernameLowerRaw != null && usernameLowerRaw.isNotEmpty
                ? usernameLowerRaw
                : null);
      if (!mounted) return;
      setState(() {
        _profile = UserProfileData(
          name: (data['displayName'] as String?)?.trim().isNotEmpty == true
              ? (data['displayName'] as String).trim()
              : _profile.name,
          photoUrl: (data['photoUrl'] as String?)?.trim().isNotEmpty == true
              ? (data['photoUrl'] as String).trim()
              : _profile.photoUrl,
          username: usernameLoaded ?? _profile.username,
          emergencyContacts: contacts,
        );
      });
    } catch (_) {
      // Keep in-memory defaults if load fails.
    }
  }

  void _updateName(String name) {
    setState(() {
      _profile = UserProfileData(
        name: name,
        photoUrl: _profile.photoUrl,
        username: _profile.username,
        emergencyContacts: _profile.emergencyContacts,
      );
    });
  }

  void _updateUsername(String? username) {
    setState(() {
      _profile = UserProfileData(
        name: _profile.name,
        photoUrl: _profile.photoUrl,
        username: username,
        emergencyContacts: _profile.emergencyContacts,
      );
    });
  }

  void _updatePhotoUrl(String url) {
    setState(() {
      _profile = UserProfileData(
        name: _profile.name,
        photoUrl: url,
        username: _profile.username,
        emergencyContacts: _profile.emergencyContacts,
      );
    });
  }

  void _addEmergencyContact(EmergencyContact contact) {
    final updated = [..._profile.emergencyContacts, contact];
    setState(() {
      _profile = UserProfileData(
        name: _profile.name,
        photoUrl: _profile.photoUrl,
        username: _profile.username,
        emergencyContacts: updated,
      );
    });
    _saveContacts(updated);
  }

  void _removeEmergencyContact(int index) {
    final updated = [..._profile.emergencyContacts]..removeAt(index);
    setState(() {
      _profile = UserProfileData(
        name: _profile.name,
        photoUrl: _profile.photoUrl,
        username: _profile.username,
        emergencyContacts: updated,
      );
    });
    _saveContacts(updated);
  }

  Future<void> _initE2eeSetup() async {
    final status = await _E2eeManager.ensureKeypair(
      widget.currentUserUid,
      _firestore,
    );
    if (!mounted) return;
    if (status == _E2eeStatus.newKeypair) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showBackupSetupDialog();
      });
    } else if (status == _E2eeStatus.backupAvailable) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showKeyRecoveryDialog();
      });
    }
  }

  Future<void> _showBackupSetupDialog() async {
    final passphraseController = TextEditingController();
    final confirmController = TextEditingController();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        String? error;
        bool saving = false;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('Protect your messages'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Set a recovery passphrase to restore your encrypted messages if you reinstall or switch devices. '
                      'If you skip this, messages on new devices will start fresh.',
                      style: TextStyle(color: AppColors.text2, height: 1.5),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: passphraseController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Recovery passphrase',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: confirmController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Confirm passphrase',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      Text(error!,
                          style: const TextStyle(color: Colors.red, fontSize: 13)),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Skip for now'),
                ),
                ElevatedButton(
                  onPressed: saving
                      ? null
                      : () async {
                          final p = passphraseController.text;
                          final c = confirmController.text;
                          if (p.length < 8) {
                            setDialogState(() =>
                                error = 'Passphrase must be at least 8 characters.');
                            return;
                          }
                          if (p != c) {
                            setDialogState(() => error = 'Passphrases do not match.');
                            return;
                          }
                          setDialogState(() => saving = true);
                          await _E2eeManager.backupPrivateKey(
                            widget.currentUserUid,
                            p,
                            _firestore,
                          );
                          if (ctx.mounted) Navigator.of(ctx).pop();
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brand,
                    foregroundColor: Colors.white,
                  ),
                  child: saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Save backup'),
                ),
              ],
            );
          },
        );
      },
    );
    passphraseController.dispose();
    confirmController.dispose();
  }

  Future<void> _showKeyRecoveryDialog() async {
    final passphraseController = TextEditingController();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        String? error;
        bool restoring = false;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('Restore your messages'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'A message backup was found for this account. '
                      'Enter your recovery passphrase to restore your encrypted messages on this device.',
                      style: TextStyle(color: AppColors.text2, height: 1.5),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: passphraseController,
                      obscureText: true,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Recovery passphrase',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      Text(error!,
                          style: const TextStyle(color: Colors.red, fontSize: 13)),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Skip — start fresh'),
                ),
                ElevatedButton(
                  onPressed: restoring
                      ? null
                      : () async {
                          setDialogState(() => restoring = true);
                          final ok = await _E2eeManager.restoreFromBackup(
                            widget.currentUserUid,
                            passphraseController.text,
                            _firestore,
                          );
                          if (!ok) {
                            setDialogState(() {
                              restoring = false;
                              error = 'Wrong passphrase. Please try again.';
                            });
                            return;
                          }
                          if (ctx.mounted) Navigator.of(ctx).pop();
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brand,
                    foregroundColor: Colors.white,
                  ),
                  child: restoring
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Restore'),
                ),
              ],
            );
          },
        );
      },
    );
    passphraseController.dispose();
  }

  Future<void> _loadArticles() async {
    try {
      final snapshot = await _articlesRef
          .orderBy('createdAt', descending: true)
          .get();
      if (!mounted) {
        return;
      }
      setState(() {
        _articles = snapshot.docs
            .map((doc) => HelpHerArticle.fromFirestoreData(doc.id, doc.data()))
            .toList();
      });
    } catch (_) {
      // Keep current in-memory list if remote load fails.
    }
  }

  Future<void> _addArticle(HelpHerArticle article) async {
    setState(() {
      _articles = [article, ..._articles];
    });
    await _articlesRef.doc(article.id).set({
      ...article.toFirestoreData(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    _publishNotification(
      type: AppNotificationType.article,
      title: 'New article published',
      body: article.title,
    );
  }

  void _handleCommunityPostCreated(CommunityPost post) {
    _publishNotification(
      type: AppNotificationType.message,
      title: 'New community message',
      body: '${post.author}: ${post.content}',
    );
  }

  void _handleCommentAdded({
    required String postAuthorUid,
    required String commentAuthorName,
    required String commentText,
  }) {
    _publishNotification(
      type: AppNotificationType.comment,
      title: 'New comment on your post',
      body: '$commentAuthorName: $commentText',
      targetUid: postAuthorUid,
    );
  }

  Future<void> _publishNotification({
    required AppNotificationType type,
    required String title,
    required String body,
    String? targetUid,
  }) async {
    final payload = <String, dynamic>{
      'type': type.name,
      'title': title,
      'body': body,
      'createdAt': FieldValue.serverTimestamp(),
      'createdByUid': widget.currentUserUid,
    };
    final normalizedTargetUid = targetUid?.trim();
    if (normalizedTargetUid != null && normalizedTargetUid.isNotEmpty) {
      payload['targetUid'] = normalizedTargetUid;
    }
    await _firestore.collection('notifications').add(payload);
  }

  Future<void> _markNotificationRead(String notificationId) async {
    await _firestore
        .collection('users')
        .doc(widget.currentUserUid)
        .collection('notificationReads')
        .doc(notificationId)
        .set({'readAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
  }

  Future<void> _markAllNotificationsRead(
    List<AppNotificationItem> notifications,
  ) async {
    if (notifications.isEmpty) {
      return;
    }
    final batch = _firestore.batch();
    final readsRef = _firestore
        .collection('users')
        .doc(widget.currentUserUid)
        .collection('notificationReads');
    for (final notification in notifications) {
      batch.set(readsRef.doc(notification.id), {
        'readAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
    await batch.commit();
  }

  Future<void> _deleteNotification(String notificationId) async {
    await _firestore
        .collection('users')
        .doc(widget.currentUserUid)
        .collection('notificationReads')
        .doc(notificationId)
        .set({
          'dismissedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  Future<void> _restoreNotification(String notificationId) async {
    await _firestore
        .collection('users')
        .doc(widget.currentUserUid)
        .collection('notificationReads')
        .doc(notificationId)
        .set({'dismissedAt': FieldValue.delete()}, SetOptions(merge: true));
  }

  Future<void> _openNotificationsScreen(
    BuildContext context,
    List<AppNotificationItem> notifications,
  ) async {
    await Navigator.of(context).push(
      buildSlideRoute<void>(
        beginOffset: const Offset(0, 1),
        withDimOverlay: true,
        page: NotificationsScreen(
          notifications: notifications,
          onMarkRead: _markNotificationRead,
          onMarkAllRead: _markAllNotificationsRead,
          onDelete: _deleteNotification,
          onRestore: _restoreNotification,
        ),
      ),
    );
  }

  Future<void> _updateArticle(HelpHerArticle updatedArticle) async {
    setState(() {
      _articles = _articles
          .map(
            (article) =>
                article.id == updatedArticle.id ? updatedArticle : article,
          )
          .toList();
    });
    await _articlesRef.doc(updatedArticle.id).set({
      ...updatedArticle.toFirestoreData(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> _deleteArticle(String articleId) async {
    setState(() {
      _articles = _articles
          .where((article) => article.id != articleId)
          .toList();
    });
    await _articlesRef.doc(articleId).delete();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _notificationsStream,
      builder: (context, notificationsSnapshot) {
        final notificationDocs = notificationsSnapshot.data?.docs ?? const [];
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _notificationReadsStream,
          builder: (context, readsSnapshot) {
            final readIds =
                readsSnapshot.data?.docs
                    .where((doc) => doc.data()['readAt'] != null)
                    .map((doc) => doc.id)
                    .toSet() ??
                <String>{};
            final dismissedIds =
                readsSnapshot.data?.docs
                    .where((doc) => doc.data()['dismissedAt'] != null)
                    .map((doc) => doc.id)
                    .toSet() ??
                <String>{};
            final notifications = notificationDocs
                .where((doc) {
                  final data = doc.data();
                  final typeRaw = (data['type'] as String?) ?? 'message';
                  final createdByUid = data['createdByUid'] as String?;
                  final targetUid = (data['targetUid'] as String?)?.trim();
                  if (targetUid != null &&
                      targetUid.isNotEmpty &&
                      targetUid != widget.currentUserUid) {
                    return false;
                  }
                  return typeRaw != AppNotificationType.message.name ||
                      createdByUid != widget.currentUserUid;
                })
                .where((doc) => !dismissedIds.contains(doc.id))
                .map((doc) {
                  final data = doc.data();
                  final timestamp = data['createdAt'];
                  final createdAt = timestamp is Timestamp
                      ? timestamp.toDate()
                      : DateTime.now();
                  final typeRaw = (data['type'] as String?) ?? 'message';
                  final type = typeRaw == AppNotificationType.article.name
                      ? AppNotificationType.article
                      : typeRaw == AppNotificationType.comment.name
                      ? AppNotificationType.comment
                      : AppNotificationType.message;
                  return AppNotificationItem(
                    id: doc.id,
                    type: type,
                    title: (data['title'] as String?) ?? 'Notification',
                    body: (data['body'] as String?) ?? '',
                    createdAt: createdAt,
                    isRead: readIds.contains(doc.id),
                    createdByUid: data['createdByUid'] as String?,
                  );
                })
                .toList();
            final unreadNotificationCount = notifications
                .where((notification) => !notification.isRead)
                .length;
            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _chatRoomsStream,
              builder: (context, chatsSnapshot) {
                final chatDocs = chatsSnapshot.data?.docs ?? const [];
                var unreadChatsCount = 0;
                for (final doc in chatDocs) {
                  final data = doc.data();
                  final lastBy = (data['lastMessageBy'] as String?) ?? '';
                  final lastAtRaw = data['lastMessageAt'];
                  final lastAt = lastAtRaw is Timestamp ? lastAtRaw : null;
                  final readBy = data['lastReadBy'];
                  Timestamp? myReadAt;
                  if (readBy is Map<String, dynamic>) {
                    final value = readBy[widget.currentUserUid];
                    if (value is Timestamp) {
                      myReadAt = value;
                    }
                  }
                  final hasUnread =
                      lastAt != null &&
                      lastBy.isNotEmpty &&
                      lastBy != widget.currentUserUid &&
                      (myReadAt == null ||
                          lastAt.toDate().isAfter(myReadAt.toDate()));
                  if (hasUnread) {
                    unreadChatsCount += 1;
                  }
                }

                final screens = [
                  HomeScreen(
                    userName: _profile.username ?? _profile.name,
                    featuredArticles: _articles.take(2).toList(),
                    onOpenSafety: () => _switchTab(3, animated: true),
                    onOpenCommunity: () => _switchTab(1, animated: true),
                    onOpenArticles: () => _openArticlesScreen(context),
                    onOpenNotifications: () =>
                        _openNotificationsScreen(context, notifications),
                    unreadNotifications: unreadNotificationCount,
                  ),
                  CommunityScreen(
                    currentUserUid: widget.currentUserUid,
                    currentUserName: _profile.username != null
                        ? '@${_profile.username}'
                        : widget.currentUsername,
                    currentUserPhotoUrl: _profile.photoUrl,
                    onOpenArticles: () => _openArticlesScreen(context),
                    onPostCreated: _handleCommunityPostCreated,
                    onCommentAdded: _handleCommentAdded,
                  ),
                  ChatsScreen(
                    currentUserUid: widget.currentUserUid,
                    currentUserName: _profile.username != null
                        ? '@${_profile.username}'
                        : widget.currentUsername,
                  ),
                  EmergencyScreen(
                    profile: _profile,
                    onOpenProfile: () => _switchTab(4, animated: true),
                  ),
                  ProfileScreen(
                    profile: _profile,
                    currentUserUid: widget.currentUserUid,
                    isAdmin: widget.isAdmin,
                    onNameSaved: _updateName,
                    onUsernameSaved: _updateUsername,
                    onPhotoUrlSaved: _updatePhotoUrl,
                    onContactAdded: _addEmergencyContact,
                    onContactRemoved: _removeEmergencyContact,
                    onSignOut: widget.onSignOut,
                  ),
                ];
                final isIOS = Theme.of(context).platform == TargetPlatform.iOS;
                final bottomNav = BottomNavigationBar(
                  currentIndex: _currentIndex,
                  onTap: (index) => _switchTab(index, animated: true),
                  type: BottomNavigationBarType.fixed,
                  enableFeedback: !isIOS,
                  selectedItemColor: AppColors.brand,
                  unselectedItemColor: AppColors.text2,
                  selectedLabelStyle: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 10,
                  ),
                  unselectedLabelStyle: const TextStyle(fontSize: 10),
                  items: [
                    BottomNavigationBarItem(
                      icon: Icon(Icons.home_outlined),
                      label: 'Home',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.people_outline),
                      label: 'Community',
                    ),
                    BottomNavigationBarItem(
                      icon: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          const Icon(Icons.chat_bubble_outline),
                          if (unreadChatsCount > 0)
                            Positioned(
                              right: -6,
                              top: -4,
                              child: Container(
                                constraints: const BoxConstraints(
                                  minWidth: 14,
                                  minHeight: 14,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.brand,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  unreadChatsCount > 9
                                      ? '9+'
                                      : '$unreadChatsCount',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      label: 'Chats',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.bolt),
                      label: 'Safety',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.person_outline),
                      label: 'Profile',
                    ),
                  ],
                );

                final isComputer = isComputerPlatform(Theme.of(context).platform);
                final isWideComputer =
                    isComputer && MediaQuery.of(context).size.width >= 980;

                Widget buildContent({required bool constrain}) {
                  final content = AnimatedBuilder(
                    animation: _tabEntranceController,
                    child: PageView(
                      controller: _pageController,
                      physics: isComputer
                          ? const NeverScrollableScrollPhysics()
                          : const ClampingScrollPhysics(),
                      onPageChanged: (index) {
                        if (_currentIndex != index) {
                          setState(() => _currentIndex = index);
                        }
                      },
                      children: screens,
                    ),
                    builder: (context, child) {
                      final progress = _tabEntranceController.value;
                      final offsetX = (1 - progress) * 34 * _tabSlideDirection;
                      return Opacity(
                        opacity: 0.9 + (progress * 0.1),
                        child: Transform.translate(
                          offset: Offset(offsetX, 0),
                          child: child,
                        ),
                      );
                    },
                  );

                  if (!constrain) {
                    return content;
                  }

                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1120),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: content,
                      ),
                    ),
                  );
                }

                NavigationRailDestination railDestination({
                  required IconData icon,
                  required IconData selectedIcon,
                  required String label,
                  Widget? badge,
                }) {
                  final baseIcon = Icon(icon);
                  final baseSelectedIcon = Icon(selectedIcon);
                  Widget withBadge(Widget iconWidget) {
                    if (badge == null) return iconWidget;
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        iconWidget,
                        Positioned(right: -6, top: -4, child: badge),
                      ],
                    );
                  }

                  return NavigationRailDestination(
                    icon: withBadge(baseIcon),
                    selectedIcon: withBadge(baseSelectedIcon),
                    label: Text(label),
                  );
                }

                final chatBadge = unreadChatsCount > 0
                    ? Container(
                        constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: AppColors.brand,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          unreadChatsCount > 9 ? '9+' : '$unreadChatsCount',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    : null;

                return Scaffold(
                  body: isWideComputer
                      ? Row(
                          children: [
                            NavigationRail(
                              selectedIndex: _currentIndex,
                              onDestinationSelected: (index) =>
                                  _switchTab(index, animated: true),
                              labelType: NavigationRailLabelType.all,
                              backgroundColor: Colors.white,
                              selectedIconTheme: const IconThemeData(
                                color: AppColors.brand,
                              ),
                              selectedLabelTextStyle: const TextStyle(
                                color: AppColors.brand,
                                fontWeight: FontWeight.w700,
                              ),
                              unselectedIconTheme: const IconThemeData(
                                color: AppColors.text2,
                              ),
                              unselectedLabelTextStyle: const TextStyle(
                                color: AppColors.text2,
                              ),
                              destinations: [
                                railDestination(
                                  icon: Icons.home_outlined,
                                  selectedIcon: Icons.home,
                                  label: 'Home',
                                ),
                                railDestination(
                                  icon: Icons.people_outline,
                                  selectedIcon: Icons.people,
                                  label: 'Community',
                                ),
                                railDestination(
                                  icon: Icons.chat_bubble_outline,
                                  selectedIcon: Icons.chat_bubble,
                                  label: 'Chats',
                                  badge: chatBadge,
                                ),
                                railDestination(
                                  icon: Icons.bolt,
                                  selectedIcon: Icons.bolt,
                                  label: 'Safety',
                                ),
                                railDestination(
                                  icon: Icons.person_outline,
                                  selectedIcon: Icons.person,
                                  label: 'Profile',
                                ),
                              ],
                            ),
                            const VerticalDivider(width: 1, thickness: 1),
                            Expanded(child: buildContent(constrain: true)),
                          ],
                        )
                      : buildContent(constrain: isComputer),
                  bottomNavigationBar: (isWideComputer)
                      ? null
                      : (isIOS
                          ? Theme(
                              data: Theme.of(context).copyWith(
                                splashFactory: NoSplash.splashFactory,
                                highlightColor: Colors.transparent,
                                splashColor: Colors.transparent,
                              ),
                              child: bottomNav,
                            )
                          : bottomNav),
                );
              },
            );
          },
        );
      },
    );
  }
}

class HomeScreen extends StatelessWidget {
  final String userName;
  final List<HelpHerArticle> featuredArticles;
  final VoidCallback onOpenSafety;
  final VoidCallback onOpenCommunity;
  final VoidCallback onOpenArticles;
  final VoidCallback onOpenNotifications;
  final int unreadNotifications;

  const HomeScreen({
    super.key,
    required this.userName,
    required this.featuredArticles,
    required this.onOpenSafety,
    required this.onOpenCommunity,
    required this.onOpenArticles,
    required this.onOpenNotifications,
    required this.unreadNotifications,
  });

  @override
  Widget build(BuildContext context) {
    final isComputer = isComputerPlatform(Theme.of(context).platform);
    return SingleChildScrollView(
      child: Column(
        children: [
          _buildHeader(),
          if (isComputer) _buildLandingBanner(context),
          _buildSectionTitle('Quick Functions', top: 20),
          _buildQuickActions(context),
          _buildSectionTitle('Featured Articles'),
          ...featuredArticles.map(
            (article) => ArticleCard(
              title: article.title,
              author: article.author,
              readTime: article.readTime,
              color: article.accent,
              icon: article.icon,
              onTap: () {
                Navigator.of(context).push(
                  buildSlideRoute<void>(
                    page: ArticleDetailScreen(article: article),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandingBanner(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.shield_outlined, color: AppColors.brand),
              SizedBox(width: 8),
              Text(
                'Safety Dashboard',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Need help right now? Open Emergency SOS for instant support and trusted contacts.',
            style: TextStyle(color: AppColors.text2, height: 1.35),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: onOpenSafety,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brand,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.warning_amber_rounded),
                  label: const Text('Open Emergency SOS'),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                onPressed: onOpenCommunity,
                icon: const Icon(Icons.forum_outlined),
                tooltip: 'Open community',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 60, 20, 40),
      decoration: const BoxDecoration(
        color: AppColors.brand,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              RichText(
                text: TextSpan(
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                  children: const [
                    TextSpan(text: 'Help'),
                    TextSpan(
                      text: 'Her',
                      style: TextStyle(color: Color(0xFFFFB3C6)),
                    ),
                  ],
                ),
              ),
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onOpenNotifications,
                      borderRadius: BorderRadius.circular(20),
                      child: const CircleAvatar(
                        backgroundColor: Colors.white24,
                        child: Icon(
                          Icons.notifications_none,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  if (unreadNotifications > 0)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          unreadNotifications > 99
                              ? '99+'
                              : '$unreadNotifications',
                          style: const TextStyle(
                            color: AppColors.brand,
                            fontWeight: FontWeight.w700,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            '${_timeOfDayGreeting(DateTime.now())},',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          Text(
            userName,
            style: GoogleFonts.playfairDisplay(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  String _timeOfDayGreeting(DateTime now) {
    final hour = now.hour;
    if (hour < 5) return 'Good night';
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    if (hour < 21) return 'Good evening';
    return 'Good night';
  }

  Widget _buildQuickActions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: isComputerPlatform(Theme.of(context).platform)
          ? _buildQuickActionsWeb()
          : _buildQuickActionsDefault(),
    );
  }

  Widget _buildQuickActionsWeb() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width:
                  wide
                      ? (constraints.maxWidth - 24) / 3
                      : (constraints.maxWidth - 12) / 2,
              child: _actionCard(
                'Emergency SOS',
                'Quick access',
                AppColors.brand,
                Colors.white,
                Icons.bolt,
                onTap: onOpenSafety,
              ),
            ),
            SizedBox(
              width:
                  wide
                      ? (constraints.maxWidth - 24) / 3
                      : (constraints.maxWidth - 12) / 2,
              child: _actionCard(
                'Community',
                'Join chat',
                AppColors.surface,
                AppColors.brand,
                Icons.people,
                onTap: onOpenCommunity,
              ),
            ),
            SizedBox(
              width:
                  wide
                      ? (constraints.maxWidth - 24) / 3
                      : (constraints.maxWidth - 12) / 2,
              child: _actionCard(
                'Articles',
                'Read & learn',
                AppColors.surface,
                AppColors.brand,
                Icons.menu_book,
                onTap: onOpenArticles,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildQuickActionsDefault() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _actionCard(
                'Emergency SOS',
                'Quick access',
                AppColors.brand,
                Colors.white,
                Icons.bolt,
                onTap: onOpenSafety,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _actionCard(
                'Community',
                'Join chat',
                AppColors.surface,
                AppColors.brand,
                Icons.people,
                onTap: onOpenCommunity,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _actionCard(
                'Articles',
                'Read & learn',
                AppColors.surface,
                AppColors.brand,
                Icons.menu_book,
                onTap: onOpenArticles,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(child: SizedBox()),
          ],
        ),
      ],
    );
  }

  Widget _actionCard(
    String title,
    String sub,
    Color bg,
    Color text,
    IconData icon, {
    required VoidCallback onTap,
  }) {
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.black12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: text, size: 28),
              const SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(
                  color: text,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              Text(
                sub,
                style: TextStyle(
                  color: text.withValues(alpha: 0.7),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(
    String title, {
    double top = 10,
    double bottom = 10,
  }) {
    return Container(
      alignment: Alignment.centerLeft,
      padding: EdgeInsets.fromLTRB(20, top, 20, bottom),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppColors.text2,
          letterSpacing: 1.2,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class ArticleCard extends StatelessWidget {
  final String title;
  final String author;
  final String readTime;
  final Color color;
  final IconData icon;
  final VoidCallback? onTap;

  const ArticleCard({
    super.key,
    required this.title,
    required this.author,
    required this.readTime,
    required this.color,
    required this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black12),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Column(
            children: [
              Container(
                height: 100,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16),
                  ),
                ),
                child: Icon(icon, size: 40, color: AppColors.brand),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$author • $readTime',
                      style: const TextStyle(
                        color: AppColors.text2,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class EmergencyScreen extends StatefulWidget {
  final UserProfileData profile;
  final VoidCallback onOpenProfile;

  const EmergencyScreen({
    super.key,
    required this.profile,
    required this.onOpenProfile,
  });

  @override
  State<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends State<EmergencyScreen> {
  bool _isHolding = false;
  Timer? _safetyCheckTimer;
  int _safetyCountdownSeconds = 0;
  bool _isSafetyCheckActive = false;
  bool _isEscalating = false;

  List<String> get _emergencyRecipientPhones => widget.profile.emergencyContacts
      .map((contact) => contact.phone.trim())
      .where((phone) => phone.isNotEmpty)
      .toSet()
      .toList();

  Future<void> _callContact(EmergencyContact contact) async {
    final phone = contact.phone.trim();
    if (phone.isEmpty) {
      _showMessage('Missing phone number for ${contact.name}.');
      return;
    }
    final launched = await launchUrl(Uri(scheme: 'tel', path: phone));
    if (!launched && mounted) {
      _showMessage('Could not start a call to ${contact.name}.');
    }
  }

  Future<String?> _getLocationLink() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 3),
        ),
      );
      return 'https://maps.google.com/?q=${position.latitude},${position.longitude}';
    } catch (_) {
      return null;
    }
  }

  Future<void> _sendAlertSmsToAll() async {
    final platform = Theme.of(context).platform;
    final locationLink = await _getLocationLink();
    final locationSuffix = locationLink != null ? ' My location: $locationLink' : '';
    if (!supportsNativeSms(platform)) {
      final text =
          'SOS alert from HelpHer user ${widget.profile.name}. Please check on me immediately.$locationSuffix';
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        _showMessage(
          'SMS sending is not supported on this device. '
          'We copied the alert text to your clipboard so you can paste it into your messaging app.',
        );
      }
      _startSafetyCheckCountdown();
      return;
    }
    final recipients = _emergencyRecipientPhones;
    if (recipients.isEmpty) {
      _showMessage('No valid emergency contact numbers found.');
      return;
    }
    final text =
        'SOS alert from HelpHer user ${widget.profile.name}. Please check on me immediately.$locationSuffix';
    try {
      await sendSMS(message: text, recipients: recipients);
      if (!mounted) {
        return;
      }
      _showMessage('Emergency SMS sent to ${recipients.length} contacts.');
      _startSafetyCheckCountdown();
    } catch (_) {
      final smsUri = Uri(
        scheme: 'sms',
        path: recipients.join(','),
        queryParameters: {'body': text},
      );
      final launched = await launchUrl(smsUri);
      if (!mounted) {
        return;
      }
      if (!launched) {
        _showMessage('Could not send the alert SMS on this device.');
        return;
      }
      _showMessage('Opened SMS app for emergency alert.');
      _startSafetyCheckCountdown();
    }
  }

  Future<void> _sendStatusSmsToAll({
    required String text,
    required String successMessage,
    required String failureMessage,
  }) async {
    final platform = Theme.of(context).platform;
    if (!supportsNativeSms(platform)) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        _showMessage(
          'SMS sending is not supported on this device. '
          'We copied the message to your clipboard so you can paste it into your messaging app.',
        );
      }
      return;
    }
    final recipients = _emergencyRecipientPhones;
    if (recipients.isEmpty) {
      _showMessage('No valid emergency contact numbers found.');
      return;
    }
    try {
      await sendSMS(message: text, recipients: recipients);
      if (mounted) {
        _showMessage(successMessage);
      }
    } catch (_) {
      final smsUri = Uri(
        scheme: 'sms',
        path: recipients.join(','),
        queryParameters: {'body': text},
      );
      final launched = await launchUrl(smsUri);
      if (!mounted) {
        return;
      }
      if (!launched) {
        _showMessage(failureMessage);
        return;
      }
      _showMessage('Opened SMS app with prefilled message.');
    }
  }

  void _startSafetyCheckCountdown({int seconds = 120}) {
    _safetyCheckTimer?.cancel();
    setState(() {
      _safetyCountdownSeconds = seconds;
      _isSafetyCheckActive = true;
      _isEscalating = false;
    });
    _safetyCheckTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_safetyCountdownSeconds <= 1) {
        timer.cancel();
        _handleNoResponseEscalation();
        return;
      }
      setState(() {
        _safetyCountdownSeconds -= 1;
      });
    });
  }

  Future<void> _markUserSafe() async {
    _safetyCheckTimer?.cancel();
    setState(() {
      _isSafetyCheckActive = false;
      _safetyCountdownSeconds = 0;
      _isEscalating = false;
    });
    await _sendStatusSmsToAll(
      text:
          'Update from ${widget.profile.name}: I am okay now. Thank you for checking on me.',
      successMessage: 'Safety update sent to your contacts.',
      failureMessage: 'Could not send your safety update.',
    );
  }

  Future<void> _handleNoResponseEscalation() async {
    if (_isEscalating) {
      return;
    }
    setState(() {
      _isEscalating = true;
      _isSafetyCheckActive = true;
      _safetyCountdownSeconds = 0;
    });
    final locationLink = await _getLocationLink();
    final locationSuffix = locationLink != null ? ' Last known location: $locationLink' : '';
    await _sendStatusSmsToAll(
      text:
          'No response from ${widget.profile.name} after an SOS alert. Please contact them urgently.$locationSuffix',
      successMessage: 'Escalation alert sent to your contacts.',
      failureMessage: 'Could not send escalation alert.',
    );
    if (mounted) {
      setState(() => _isEscalating = false);
    }
  }

  void _showActionSheet() {
    if (widget.profile.emergencyContacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add at least one emergency contact in Profile first.'),
        ),
      );
      return;
    }

    final firstContact = widget.profile.emergencyContacts.first;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Emergency actions',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: const Icon(Icons.phone, color: AppColors.brand),
                  title: Text('Call ${firstContact.name}'),
                  subtitle: Text(firstContact.phone),
                  onTap: () async {
                    Navigator.pop(context);
                    await _callContact(firstContact);
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.sms_outlined,
                    color: AppColors.brand,
                  ),
                  title: const Text('Send alert SMS to all contacts'),
                  subtitle: Text(
                    '${widget.profile.emergencyContacts.length} recipients',
                  ),
                  onTap: () async {
                    Navigator.pop(context);
                    await _sendAlertSmsToAll();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _openEmergencyLine() async {
    final emergencyNumber = Uri(scheme: 'tel', path: '112');
    final launched = await launchUrl(emergencyNumber);
    if (!launched && mounted) {
      _showMessage('Could not open the emergency line on this device.');
    }
  }

  @override
  void dispose() {
    _safetyCheckTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 60),
          color: AppColors.brand,
          child: Column(
            children: [
              GestureDetector(
                onLongPressStart: (_) => setState(() => _isHolding = true),
                onLongPressEnd: (_) {
                  setState(() => _isHolding = false);
                  _showActionSheet();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: _isHolding ? 150 : 140,
                  height: _isHolding ? 150 : 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.2),
                        spreadRadius: _isHolding ? 20 : 10,
                      ),
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.1),
                        spreadRadius: _isHolding ? 30 : 20,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      'SOS',
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 40,
                        fontWeight: FontWeight.w900,
                        color: AppColors.brand,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 30),
              const Text(
                'Press & hold to open emergency actions',
                style: TextStyle(color: Colors.white70),
              ),
              if (_isSafetyCheckActive) ...[
                const SizedBox(height: 20),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      Text(
                        _isEscalating
                            ? 'Escalation in progress...'
                            : 'Safety check: are you okay?',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _isEscalating
                            ? 'Please call emergency services if needed.'
                            : 'Auto-escalates in ${(_safetyCountdownSeconds ~/ 60).toString().padLeft(2, '0')}:${(_safetyCountdownSeconds % 60).toString().padLeft(2, '0')}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _isEscalating ? null : _markUserSafe,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: const BorderSide(color: Colors.white70),
                              ),
                              child: const Text("I'm okay"),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _isEscalating
                                  ? null
                                  : _handleNoResponseEscalation,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: AppColors.brand,
                              ),
                              child: const Text('Need help'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'EMERGENCY CONTACTS',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: AppColors.text2,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 10),
              if (widget.profile.emergencyContacts.isEmpty)
                _buildResourceTile(
                  'No contacts yet',
                  'Add contacts from Profile',
                  Icons.person_add_alt,
                  AppColors.brandLight,
                  onTap: widget.onOpenProfile,
                )
              else
                ...widget.profile.emergencyContacts.map(
                  (contact) => _buildResourceTile(
                    contact.name,
                    contact.phone,
                    Icons.phone,
                    AppColors.brandLight,
                    onTap: () => _callContact(contact),
                  ),
                ),
              _buildResourceTile(
                'Emergency Line',
                'Use your local police emergency line',
                Icons.local_police_outlined,
                const Color(0xFFE8EAF6),
                onTap: () => _openEmergencyLine(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildResourceTile(
    String title,
    String sub,
    IconData icon,
    Color bg, {
    VoidCallback? onTap,
  }) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Colors.black12),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: AppColors.brand),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(sub),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class ChatsScreen extends StatefulWidget {
  final String currentUserUid;
  final String currentUserName;

  const ChatsScreen({
    super.key,
    required this.currentUserUid,
    required this.currentUserName,
  });

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  FirebaseStorage get _storage => FirebaseStorage.instance;
  CollectionReference<Map<String, dynamic>> get _roomsCollection =>
      _firestore.collection('chatRooms');

  Widget _chatAvatar(String? photoUrl, bool isDirect) {
    if (photoUrl != null && photoUrl.isNotEmpty) {
      return CircleAvatar(
        backgroundImage: NetworkImage(photoUrl),
        backgroundColor: AppColors.brandLight,
      );
    }
    return CircleAvatar(
      backgroundColor: AppColors.brandLight,
      child: Icon(
        isDirect ? Icons.person : Icons.group,
        color: AppColors.brand,
      ),
    );
  }

  Future<void> _changeGroupPhoto(BuildContext ctx, String roomId) async {
    final platform = Theme.of(ctx).platform;
    try {
      Uint8List? bytes;
      if (kIsWeb ||
          platform == TargetPlatform.android ||
          platform == TargetPlatform.iOS) {
        final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          imageQuality: 82,
          maxWidth: 800,
        );
        if (picked == null) return;
        bytes = await picked.readAsBytes();
      } else {
        const group = XTypeGroup(
          label: 'Images',
          extensions: <String>['jpg', 'jpeg', 'png', 'webp'],
        );
        final file = await openFile(acceptedTypeGroups: [group]);
        if (file == null) return;
        bytes = await file.readAsBytes();
      }
      if (bytes.isEmpty) return;
      final ref = _storage
          .ref()
          .child('chatRooms')
          .child(roomId)
          .child('photo.jpg');
      await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      final url =
          '${await ref.getDownloadURL()}?v=${DateTime.now().millisecondsSinceEpoch}';
      await _roomsCollection.doc(roomId).update({'photoUrl': url});
    } catch (e) {
      if (mounted) _showChatSnack('Failed to update photo: $e');
    }
  }

  String _directKeyFor(String a, String b) {
    final sorted = [a, b]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }

  void _showChatSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  /// Resolves comma-separated HelpHer usernames to Firebase Auth UIDs.
  Future<List<String>?> _resolveMemberIds(List<String> tokens) async {
    final resolved = <String>{};
    for (final raw in tokens) {
      final t = raw.trim();
      if (t.isEmpty) {
        continue;
      }
      final key = normalizeHelpherUsernameKey(t);
      if (key == null) {
        _showChatSnack(
          'Invalid username "$t". Use 3–30 characters: letters, numbers, or underscores.',
        );
        return null;
      }
      final found = await lookupHelpherUidByUsername(_firestore, key);
      if (found == null) {
        _showChatSnack(
          'No user "@$key". They need to set a username in Profile.',
        );
        return null;
      }
      resolved.add(found['uid']!);
    }
    return resolved.toList();
  }

  Future<void> _openCreateDirectDialog() async {
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Start private chat'),
          content: TextField(
            controller: controller,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Their HelpHer username',
              hintText: 'e.g. river_song',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final input = controller.text.trim();
                if (input.isEmpty) {
                  return;
                }
                final key = normalizeHelpherUsernameKey(input);
                if (key == null) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Invalid username. Use 3–30 letters, numbers, or underscores.',
                        ),
                      ),
                    );
                  }
                  return;
                }
                final found = await lookupHelpherUidByUsername(_firestore, key);
                if (found == null) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'No user "@$key". They need to set a username in Profile.',
                        ),
                      ),
                    );
                  }
                  return;
                }
                final targetUid = found['uid']!;
                final targetName = '@$key';
                if (targetUid == widget.currentUserUid) {
                  return;
                }
                try {
                  final directKey = _directKeyFor(
                    widget.currentUserUid,
                    targetUid,
                  );
                  final existing = await _roomsCollection
                      .where('type', isEqualTo: 'direct')
                      .where('directKey', isEqualTo: directKey)
                      .limit(1)
                      .get();
                  String roomId;
                  if (existing.docs.isNotEmpty) {
                    roomId = existing.docs.first.id;
                  } else {
                    final members = <String>{
                      widget.currentUserUid,
                      targetUid,
                    }.toList();
                    final roomRef = await _roomsCollection.add({
                      'type': 'direct',
                      'name': targetName,
                      'members': members,
                      'directKey': directKey,
                      'createdBy': widget.currentUserUid,
                      'createdAt': FieldValue.serverTimestamp(),
                      'updatedAt': FieldValue.serverTimestamp(),
                      'lastMessage': '',
                      'lastMessageAt': FieldValue.serverTimestamp(),
                      'lastMessageBy': '',
                      'lastReadBy': {widget.currentUserUid: Timestamp.now()},
                    });
                    roomId = roomRef.id;
                  }
                  if (!mounted) {
                    return;
                  }
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                  _openRoom(
                    roomId,
                    targetName,
                    type: 'direct',
                    members: [widget.currentUserUid, targetUid],
                  );
                } on FirebaseException catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          e.message ??
                              'Could not open chat (${e.code}). '
                                  'If this persists, deploy Firestore indexes.',
                        ),
                      ),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Could not open chat: $e')),
                    );
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brand,
                foregroundColor: Colors.white,
              ),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
    controller.dispose();
  }

  Future<void> _openCreateGroupSheet() async {
    final nameController = TextEditingController();
    final membersController = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Create group chat',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Group name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: membersController,
                minLines: 2,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Member usernames (comma separated)',
                  hintText: 'river_song, clara_o',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    final name = nameController.text.trim();
                    if (name.isEmpty) {
                      _showChatSnack('Enter a group name.');
                      return;
                    }
                    final parsed = membersController.text
                        .split(',')
                        .map((value) => value.trim())
                        .where((value) => value.isNotEmpty)
                        .toList();
                    final resolvedOthers = await _resolveMemberIds(parsed);
                    if (resolvedOthers == null) {
                      return;
                    }
                    final members = <String>{
                      widget.currentUserUid,
                      ...resolvedOthers,
                    }.toList();
                    if (members.length < 2) {
                      _showChatSnack(
                        'Add at least one other member by username.',
                      );
                      return;
                    }
                    try {
                      final roomRef = await _roomsCollection.add({
                        'type': 'group',
                        'name': name,
                        'members': members,
                        'createdBy': widget.currentUserUid,
                        'createdAt': FieldValue.serverTimestamp(),
                        'updatedAt': FieldValue.serverTimestamp(),
                        'lastMessage': '',
                        'lastMessageAt': FieldValue.serverTimestamp(),
                        'lastMessageBy': '',
                        'lastReadBy': {widget.currentUserUid: Timestamp.now()},
                      });
                      if (!context.mounted) {
                        return;
                      }
                      Navigator.of(context).pop();
                      _openRoom(
                        roomRef.id,
                        name,
                        type: 'group',
                        members: members,
                      );
                    } on FirebaseException catch (e) {
                      _showChatSnack(
                        e.message ?? 'Could not create group (${e.code}).',
                      );
                    } catch (e) {
                      _showChatSnack('Could not create group: $e');
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brand,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Create group'),
                ),
              ),
            ],
          ),
        );
      },
    );
    nameController.dispose();
    membersController.dispose();
  }

  Future<void> _deleteDirectChat(String roomId) async {
    try {
      await _roomsCollection.doc(roomId).update({
        'members': FieldValue.arrayRemove([widget.currentUserUid]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      _showChatSnack('Could not delete chat: $e');
    }
  }

  Future<void> _leaveGroup(String roomId) async {
    try {
      await _roomsCollection.doc(roomId).update({
        'members': FieldValue.arrayRemove([widget.currentUserUid]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      _showChatSnack('Could not leave group: $e');
    }
  }

  void _openRoom(
    String roomId,
    String roomName, {
    String type = 'group',
    List<String> members = const [],
  }) {
    Navigator.of(context).push(
      buildSlideRoute<void>(
        page: ChatRoomScreen(
          roomId: roomId,
          roomName: roomName,
          currentUserUid: widget.currentUserUid,
          currentUserName: widget.currentUserName,
          roomType: type,
          roomMembers: members,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Chats',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Private chat',
                  onPressed: _openCreateDirectDialog,
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                ),
                IconButton(
                  tooltip: 'Create group',
                  onPressed: _openCreateGroupSheet,
                  icon: const Icon(Icons.group_add_outlined),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _roomsCollection
                  .where('members', arrayContains: widget.currentUserUid)
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final myUid = widget.currentUserUid;
                final rooms = snapshot.data!.docs.toList()
                  ..sort((a, b) {
                    final aAt = a.data()['lastMessageAt'];
                    final bAt = b.data()['lastMessageAt'];
                    final aTime = aAt is Timestamp
                        ? aAt.toDate()
                        : DateTime.fromMillisecondsSinceEpoch(0);
                    final bTime = bAt is Timestamp
                        ? bAt.toDate()
                        : DateTime.fromMillisecondsSinceEpoch(0);
                    return bTime.compareTo(aTime);
                  });
                if (rooms.isEmpty) {
                  return const Center(
                    child: Text(
                      'No chats yet. Start a private or group chat.',
                      style: TextStyle(color: AppColors.text2),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: rooms.length,
                  itemBuilder: (context, index) {
                    final roomDoc = rooms[index];
                    final data = roomDoc.data();
                    final roomName =
                        (data['name'] as String?)?.trim().isNotEmpty == true
                        ? (data['name'] as String).trim()
                        : 'Chat';
                    final lastMessage =
                        (data['lastMessage'] as String?)?.trim() ?? '';
                    final type = (data['type'] as String?) ?? 'group';
                    final roomMembers = (data['members'] as List?) ?? const [];
                    final groupPhotoUrl = data['photoUrl'] as String?;
                    final lastBy = (data['lastMessageBy'] as String?) ?? '';
                    final lastAtRaw = data['lastMessageAt'];
                    final lastAt = lastAtRaw is Timestamp ? lastAtRaw : null;
                    final readBy = data['lastReadBy'];
                    Timestamp? myReadAt;
                    if (readBy is Map<String, dynamic>) {
                      final value = readBy[myUid];
                      if (value is Timestamp) {
                        myReadAt = value;
                      }
                    }
                    final hasUnread =
                        lastAt != null &&
                        lastBy.isNotEmpty &&
                        lastBy != myUid &&
                        (myReadAt == null ||
                            lastAt.toDate().isAfter(myReadAt.toDate()));
                    Widget buildCard(Widget avatar) => Card(
                      child: ListTile(
                        leading: avatar,
                        title: Text(roomName),
                        subtitle: Text(
                          lastMessage.isEmpty
                              ? '${roomMembers.length} members'
                              : lastMessage,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: hasUnread
                            ? Container(
                                width: 10,
                                height: 10,
                                decoration: const BoxDecoration(
                                  color: AppColors.brand,
                                  shape: BoxShape.circle,
                                ),
                              )
                            : null,
                        onTap: () => _openRoom(
                          roomDoc.id,
                          roomName,
                          type: type,
                          members: roomMembers.whereType<String>().toList(),
                        ),
                      ),
                    );
                    if (type == 'direct') {
                      final otherUid = roomMembers
                          .whereType<String>()
                          .firstWhere((m) => m != myUid, orElse: () => '');
                      return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                        stream: otherUid.isNotEmpty
                            ? _firestore
                                .collection('userDirectory')
                                .doc(otherUid)
                                .snapshots()
                            : const Stream.empty(),
                        builder: (ctx, dirSnap) {
                          final photoUrl = dirSnap.data?.data()?['photoUrl'] as String?;
                          return Dismissible(
                        key: Key(roomDoc.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          decoration: BoxDecoration(
                            color: AppColors.brand,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.delete_outline,
                            color: Colors.white,
                          ),
                        ),
                        confirmDismiss: (_) async {
                          return await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Delete chat?'),
                                  content: const Text(
                                    'This chat will be removed from your list.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(context).pop(false),
                                      child: const Text('Cancel'),
                                    ),
                                    ElevatedButton(
                                      onPressed: () =>
                                          Navigator.of(context).pop(true),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.brand,
                                        foregroundColor: Colors.white,
                                      ),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              ) ??
                              false;
                        },
                        onDismissed: (_) => _deleteDirectChat(roomDoc.id),
                        child: buildCard(_chatAvatar(photoUrl, true)),
                      );
                        },
                      );
                    }
                    return PopupMenuButton<String>(
                      onSelected: (value) async {
                        if (value == 'photo') {
                          await _changeGroupPhoto(context, roomDoc.id);
                        } else if (value == 'leave') {
                          final confirmed =
                              await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Leave group?'),
                                  content: Text(
                                    'You will leave "$roomName" and it will be removed from your list.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(context).pop(false),
                                      child: const Text('Cancel'),
                                    ),
                                    ElevatedButton(
                                      onPressed: () =>
                                          Navigator.of(context).pop(true),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.brand,
                                        foregroundColor: Colors.white,
                                      ),
                                      child: const Text('Leave'),
                                    ),
                                  ],
                                ),
                              ) ??
                              false;
                          if (confirmed) await _leaveGroup(roomDoc.id);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'photo',
                          child: Row(
                            children: [
                              Icon(
                                Icons.photo_camera,
                                color: AppColors.brand,
                                size: 18,
                              ),
                              SizedBox(width: 8),
                              Text('Change photo'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'leave',
                          child: Row(
                            children: [
                              Icon(
                                Icons.exit_to_app,
                                color: AppColors.brand,
                                size: 18,
                              ),
                              SizedBox(width: 8),
                              Text('Leave group'),
                            ],
                          ),
                        ),
                      ],
                      child: buildCard(_chatAvatar(groupPhotoUrl, false)),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ChatRoomScreen extends StatefulWidget {
  final String roomId;
  final String roomName;
  final String currentUserUid;
  final String currentUserName;
  final String roomType;
  final List<String> roomMembers;

  const ChatRoomScreen({
    super.key,
    required this.roomId,
    required this.roomName,
    required this.currentUserUid,
    required this.currentUserName,
    this.roomType = 'group',
    this.roomMembers = const [],
  });

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  late final TextEditingController _messageController;
  Timer? _typingDebounce;
  bool _isTyping = false;

  // E2EE state — only used for direct (1:1) chats.
  Uint8List? _sharedSecret;
  bool _e2eeReady = false;

  DocumentReference<Map<String, dynamic>> get _roomRef =>
      _firestore.collection('chatRooms').doc(widget.roomId);

  CollectionReference<Map<String, dynamic>> get _messagesRef =>
      _roomRef.collection('messages');

  @override
  void initState() {
    super.initState();
    _messageController = TextEditingController();
    _markAsRead();
    if (widget.roomType == 'direct') _initE2ee();
  }

  Future<void> _initE2ee() async {
    final otherUid = widget.roomMembers.firstWhere(
      (uid) => uid != widget.currentUserUid,
      orElse: () => '',
    );
    if (otherUid.isEmpty) return;
    try {
      final snap = await _firestore.collection('users').doc(otherUid).get();
      final theirKey = (snap.data()?['e2eePublicKey'] as String?);
      if (theirKey == null) return;
      final secret = await _E2eeManager.deriveSharedSecret(
        widget.currentUserUid,
        theirKey,
      );
      if (secret != null && mounted) {
        setState(() {
          _sharedSecret = secret;
          _e2eeReady = true;
        });
      }
    } catch (_) {
      // Fall back to unencrypted gracefully.
    }
  }

  @override
  void dispose() {
    _typingDebounce?.cancel();
    if (_isTyping) {
      _roomRef.set({
        'typingBy': {widget.currentUserUid: false},
      }, SetOptions(merge: true));
    }
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _markAsRead() async {
    await _roomRef.set({
      'lastReadBy': {widget.currentUserUid: FieldValue.serverTimestamp()},
    }, SetOptions(merge: true));
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _messageController.clear();

    final batch = _firestore.batch();
    final messageRef = _messagesRef.doc();

    if (_e2eeReady && _sharedSecret != null) {
      final enc = await _E2eeManager.encrypt(text, _sharedSecret!);
      batch.set(messageRef, {
        'senderUid': widget.currentUserUid,
        'senderName': widget.currentUserName,
        'enc': true,
        'iv': enc.iv,
        'ct': enc.ct,
        'createdAt': FieldValue.serverTimestamp(),
      });
      batch.update(_roomRef, {
        'lastMessage': '🔒 Encrypted message',
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastMessageBy': widget.currentUserUid,
        'updatedAt': FieldValue.serverTimestamp(),
        'lastReadBy': {widget.currentUserUid: FieldValue.serverTimestamp()},
      });
    } else {
      batch.set(messageRef, {
        'senderUid': widget.currentUserUid,
        'senderName': widget.currentUserName,
        'text': text,
        'createdAt': FieldValue.serverTimestamp(),
      });
      batch.update(_roomRef, {
        'lastMessage': text,
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastMessageBy': widget.currentUserUid,
        'updatedAt': FieldValue.serverTimestamp(),
        'lastReadBy': {widget.currentUserUid: FieldValue.serverTimestamp()},
      });
    }
    await batch.commit();
    await _setTyping(false);
  }

  Future<void> _addMemberDialog() async {
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add member'),
        content: TextField(
          controller: controller,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'HelpHer username',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final input = controller.text.trim();
              if (input.isEmpty) return;
              final key = normalizeHelpherUsernameKey(input);
              if (key == null) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Invalid username. Use 3–30 letters, numbers, or underscores.',
                      ),
                    ),
                  );
                }
                return;
              }
              final found = await lookupHelpherUidByUsername(_firestore, key);
              if (found == null) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'No user "@$key". They need a username in Profile.',
                      ),
                    ),
                  );
                }
                return;
              }
              final uid = found['uid']!;
              if (uid.isEmpty) return;
              await _roomRef.set({
                'members': FieldValue.arrayUnion([uid]),
                'updatedAt': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  Future<void> _setTyping(bool value) async {
    if (_isTyping == value) {
      return;
    }
    _isTyping = value;
    await _roomRef.set({
      'typingBy': {widget.currentUserUid: value},
    }, SetOptions(merge: true));
  }

  void _onTypingChanged(String value) {
    final hasText = value.trim().isNotEmpty;
    _setTyping(hasText);
    _typingDebounce?.cancel();
    _typingDebounce = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      if (_messageController.text.trim().isEmpty) {
        _setTyping(false);
      }
    });
  }

  Future<void> _removeMember(String uid) async {
    if (uid == widget.currentUserUid) return;
    await _roomRef.set({
      'members': FieldValue.arrayRemove([uid]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _roomRef.snapshots(),
      builder: (context, roomSnapshot) {
        final room = roomSnapshot.data?.data();
        final roomType = (room?['type'] as String?) ?? 'group';
        final members = ((room?['members'] as List?) ?? const [])
            .whereType<String>()
            .toList();
        final typingByMap = room?['typingBy'];
        final typingUids = <String>[];
        if (typingByMap is Map<String, dynamic>) {
          typingByMap.forEach((uid, isTyping) {
            if (uid != widget.currentUserUid && isTyping == true) {
              typingUids.add(uid);
            }
          });
        }
        return Scaffold(
          appBar: AppBar(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.roomName),
                if (_e2eeReady) ...[
                  const SizedBox(width: 6),
                  const Tooltip(
                    message: 'End-to-end encrypted',
                    child: Icon(Icons.lock, size: 16, color: Colors.white70),
                  ),
                ],
              ],
            ),
            actions: [
              if (roomType == 'group') ...[
                IconButton(
                  tooltip: 'Add member',
                  onPressed: _addMemberDialog,
                  icon: const Icon(Icons.person_add_alt_1),
                ),
                IconButton(
                  tooltip: 'Leave group',
                  icon: const Icon(Icons.exit_to_app),
                  onPressed: () async {
                    final confirmed =
                        await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Leave group?'),
                            content: Text(
                              'You will leave "${widget.roomName}" and it will be removed from your list.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(false),
                                child: const Text('Cancel'),
                              ),
                              ElevatedButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(true),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.brand,
                                  foregroundColor: Colors.white,
                                ),
                                child: const Text('Leave'),
                              ),
                            ],
                          ),
                        ) ??
                        false;
                    if (!confirmed) return;
                    await _roomRef.set({
                      'members': FieldValue.arrayRemove([
                        widget.currentUserUid,
                      ]),
                      'updatedAt': FieldValue.serverTimestamp(),
                    }, SetOptions(merge: true));
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
              ],
            ],
          ),
          body: Column(
            children: [
              if (roomType == 'group')
                SizedBox(
                  height: 52,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    children: members.map((uid) {
                      final isMe = uid == widget.currentUserUid;
                      if (isMe) {
                        return Container(
                          margin: const EdgeInsets.only(right: 8),
                          child: const Chip(label: Text('You')),
                        );
                      }
                      return FutureBuilder<
                        DocumentSnapshot<Map<String, dynamic>>
                      >(
                        future: _firestore.collection('users').doc(uid).get(),
                        builder: (context, snap) {
                          if (!snap.hasData) {
                            return Container(
                              margin: const EdgeInsets.only(right: 8),
                              child: const Chip(label: Text('...')),
                            );
                          }
                          final data = snap.data?.data();
                          final uname = (data?['usernameLower'] as String?)
                              ?.trim();
                          final label = (uname != null && uname.isNotEmpty)
                              ? '@$uname'
                              : '?';
                          return Container(
                            margin: const EdgeInsets.only(right: 8),
                            child: Chip(
                              label: Text(label),
                              deleteIcon: const Icon(Icons.close),
                              onDeleted: () => _removeMember(uid),
                            ),
                          );
                        },
                      );
                    }).toList(),
                  ),
                ),
              if (typingUids.isNotEmpty)
                FutureBuilder<String?>(
                  future: typingUids.length == 1
                      ? _firestore
                            .collection('users')
                            .doc(typingUids.first)
                            .get()
                            .then((snap) {
                              final name =
                                  (snap.data()?['usernameLower'] as String?)
                                      ?.trim();
                              return (name != null && name.isNotEmpty)
                                  ? '@$name'
                                  : 'Someone';
                            })
                      : Future.value(null),
                  builder: (context, snap) {
                    final label = typingUids.length == 1
                        ? '${snap.data ?? 'Someone'} is typing...'
                        : '${typingUids.length} people are typing...';
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          label,
                          style: const TextStyle(
                            color: AppColors.text2,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              Expanded(
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _messagesRef
                      .orderBy('createdAt', descending: false)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final messages = snapshot.data!.docs;
                    if (messages.isNotEmpty) {
                      _markAsRead();
                    }
                    if (messages.isEmpty) {
                      return const Center(
                        child: Text(
                          'No messages yet.',
                          style: TextStyle(color: AppColors.text2),
                        ),
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final data = messages[index].data();
                        final senderUid = (data['senderUid'] as String?) ?? '';
                        final senderName =
                            (data['senderName'] as String?) ?? 'User';
                        final isMe = senderUid == widget.currentUserUid;
                        final isEnc = data['enc'] == true;
                        return Align(
                          alignment: isMe
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.all(10),
                            constraints: const BoxConstraints(maxWidth: 300),
                            decoration: BoxDecoration(
                              color: isMe
                                  ? AppColors.brand
                                  : AppColors.brandLight,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (!isMe)
                                  Text(
                                    senderName,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: AppColors.text2,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                if (isEnc && _e2eeReady && _sharedSecret != null)
                                  FutureBuilder<String?>(
                                    future: _E2eeManager.decrypt(
                                      (data['iv'] as String?) ?? '',
                                      (data['ct'] as String?) ?? '',
                                      _sharedSecret!,
                                    ),
                                    builder: (context, snap) {
                                      final display = snap.data ??
                                          (snap.connectionState ==
                                                  ConnectionState.done
                                              ? '🔒 Unable to decrypt'
                                              : '');
                                      return Text(
                                        display,
                                        style: TextStyle(
                                          color: isMe
                                              ? Colors.white
                                              : AppColors.text,
                                        ),
                                      );
                                    },
                                  )
                                else
                                  Text(
                                    isEnc
                                        ? '🔒 Encrypted message'
                                        : (data['text'] as String?) ?? '',
                                    style: TextStyle(
                                      color: isMe ? Colors.white : AppColors.text,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _messageController,
                          minLines: 1,
                          maxLines: 4,
                          onChanged: _onTypingChanged,
                          decoration: const InputDecoration(
                            hintText: 'Type a message',
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _sendMessage(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _sendMessage,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.brand,
                          foregroundColor: Colors.white,
                        ),
                        child: const Icon(Icons.send_outlined),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class ArticlesScreen extends StatefulWidget {
  final List<HelpHerArticle> articles;
  final bool canManageArticles;
  final FutureOr<void> Function(HelpHerArticle) onArticleAdded;
  final FutureOr<void> Function(HelpHerArticle) onArticleUpdated;
  final FutureOr<void> Function(String) onArticleDeleted;

  const ArticlesScreen({
    super.key,
    required this.articles,
    required this.canManageArticles,
    required this.onArticleAdded,
    required this.onArticleUpdated,
    required this.onArticleDeleted,
  });

  @override
  State<ArticlesScreen> createState() => _ArticlesScreenState();
}

class _ArticlesScreenState extends State<ArticlesScreen> {
  static const List<String> _categories = [
    'All',
    'Safety',
    'Legal',
    'Community',
  ];
  String _selectedCategory = 'All';
  String _query = '';

  List<HelpHerArticle> get _filteredArticles {
    return widget.articles.where((article) {
      final categoryMatch =
          _selectedCategory == 'All' || article.category == _selectedCategory;
      if (!categoryMatch) {
        return false;
      }

      final normalized = _query.trim().toLowerCase();
      if (normalized.isEmpty) {
        return true;
      }

      return article.title.toLowerCase().contains(normalized) ||
          article.summary.toLowerCase().contains(normalized) ||
          article.author.toLowerCase().contains(normalized);
    }).toList();
  }

  Future<void> _openArticleSheet({HelpHerArticle? initialArticle}) async {
    final isEditing = initialArticle != null;
    final titleController = TextEditingController(text: initialArticle?.title);
    final authorController = TextEditingController(
      text: initialArticle?.author,
    );
    final summaryController = TextEditingController(
      text: initialArticle?.summary,
    );
    final contentController = TextEditingController(
      text: initialArticle?.content,
    );
    String selectedCategory = initialArticle?.category ?? 'Safety';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isEditing ? 'Edit Article' : 'Add New Article',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: 'Title',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: authorController,
                      decoration: const InputDecoration(
                        labelText: 'Author',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: selectedCategory,
                      decoration: const InputDecoration(
                        labelText: 'Category',
                        border: OutlineInputBorder(),
                      ),
                      items: _categories
                          .where((c) => c != 'All')
                          .map(
                            (category) => DropdownMenuItem<String>(
                              value: category,
                              child: Text(category),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setModalState(() => selectedCategory = value);
                      },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: summaryController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Short summary',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: contentController,
                      minLines: 5,
                      maxLines: 8,
                      decoration: const InputDecoration(
                        labelText: 'Article content',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          final article = _buildArticleFromInput(
                            id: initialArticle?.id,
                            title: titleController.text,
                            author: authorController.text,
                            category: selectedCategory,
                            summary: summaryController.text,
                            content: contentController.text,
                          );
                          if (article == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Please fill all fields before saving.',
                                ),
                              ),
                            );
                            return;
                          }
                          if (isEditing) {
                            widget.onArticleUpdated(article);
                          } else {
                            widget.onArticleAdded(article);
                          }
                          Navigator.of(context).pop();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.brand,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.save_outlined),
                        label: Text(
                          isEditing ? 'Update article' : 'Save article',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    titleController.dispose();
    authorController.dispose();
    summaryController.dispose();
    contentController.dispose();
  }

  HelpHerArticle? _buildArticleFromInput({
    String? id,
    required String title,
    required String author,
    required String category,
    required String summary,
    required String content,
  }) {
    final safeTitle = title.trim();
    final safeAuthor = author.trim();
    final safeSummary = summary.trim();
    final safeContent = content.trim();
    if (safeTitle.isEmpty ||
        safeAuthor.isEmpty ||
        safeSummary.isEmpty ||
        safeContent.isEmpty) {
      return null;
    }

    return HelpHerArticle(
      id: id ?? 'user-${DateTime.now().microsecondsSinceEpoch}',
      title: safeTitle,
      author: safeAuthor,
      readTime: _estimateReadTime(safeContent),
      category: category,
      summary: safeSummary,
      content: safeContent,
      icon: _iconForCategory(category),
      accent: _accentForCategory(category),
    );
  }

  String _estimateReadTime(String text) {
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    final minutes = (words / 180).ceil().clamp(1, 30);
    return '$minutes min';
  }

  IconData _iconForCategory(String category) {
    switch (category) {
      case 'Legal':
        return Icons.gavel_outlined;
      case 'Community':
        return Icons.people_alt_outlined;
      case 'Safety':
      default:
        return Icons.shield_outlined;
    }
  }

  Color _accentForCategory(String category) {
    switch (category) {
      case 'Legal':
        return const Color(0xFFEDE7F6);
      case 'Community':
        return const Color(0xFFE8F5E9);
      case 'Safety':
      default:
        return const Color(0xFFFFEBEE);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isComputer = isComputerPlatform(Theme.of(context).platform);
    return Scaffold(
      appBar: isComputer
          ? AppBar(
              title: const Text('Articles'),
              surfaceTintColor: Colors.transparent,
              leading: BackButton(
                onPressed: () => Navigator.of(context).pop(),
              ),
            )
          : null,
      floatingActionButton: widget.canManageArticles
          ? FloatingActionButton.extended(
              onPressed: () => _openArticleSheet(),
              backgroundColor: AppColors.brand,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('Add Article'),
            )
          : null,
      body: SafeArea(
        top: !isComputer,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: 'Search articles...',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Colors.black12),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Colors.black12),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                itemBuilder: (context, index) {
                  final category = _categories[index];
                  final selected = category == _selectedCategory;
                  return ChoiceChip(
                    label: Text(category),
                    selected: selected,
                    selectedColor: AppColors.brandLight,
                    labelStyle: TextStyle(
                      color: selected ? AppColors.brand : AppColors.text2,
                      fontWeight: FontWeight.w600,
                    ),
                    onSelected: (_) =>
                        setState(() => _selectedCategory = category),
                  );
                },
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemCount: _categories.length,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _filteredArticles.isEmpty
                  ? const Center(
                      child: Text(
                        'No articles match your search yet.',
                        style: TextStyle(color: AppColors.text2),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      itemCount: _filteredArticles.length,
                      itemBuilder: (context, index) {
                        final article = _filteredArticles[index];
                        return _ArticleFeedCard(
                          article: article,
                          onEdit: widget.canManageArticles
                              ? () => _openArticleSheet(initialArticle: article)
                              : null,
                          onDelete: widget.canManageArticles
                              ? () => widget.onArticleDeleted(article.id)
                              : null,
                          onTap: () {
                            Navigator.of(context).push(
                              buildSlideRoute<void>(
                                page: ArticleDetailScreen(article: article),
                              ),
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArticleFeedCard extends StatelessWidget {
  final HelpHerArticle article;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _ArticleFeedCard({
    required this.article,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Colors.black12),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: article.accent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(article.icon, color: AppColors.brand),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      article.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      article.summary,
                      style: const TextStyle(color: AppColors.text2),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${article.category} • ${article.author} • ${article.readTime}',
                      style: const TextStyle(
                        color: AppColors.text2,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              if (onEdit != null && onDelete != null)
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') {
                      onEdit!();
                    } else if (value == 'delete') {
                      onDelete!();
                    }
                  },
                  icon: const Icon(Icons.more_horiz, color: AppColors.text2),
                  itemBuilder: (context) => const [
                    PopupMenuItem<String>(value: 'edit', child: Text('Edit')),
                    PopupMenuItem<String>(
                      value: 'delete',
                      child: Text('Delete'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class ArticleDetailScreen extends StatelessWidget {
  final HelpHerArticle article;

  const ArticleDetailScreen({super.key, required this.article});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(article.category),
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            height: 120,
            decoration: BoxDecoration(
              color: article.accent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(article.icon, size: 44, color: AppColors.brand),
          ),
          const SizedBox(height: 16),
          Text(
            article.title,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            '${article.author} • ${article.readTime}',
            style: const TextStyle(color: AppColors.text2),
          ),
          const SizedBox(height: 16),
          Text(
            article.content,
            style: const TextStyle(height: 1.6, fontSize: 16),
          ),
        ],
      ),
    );
  }
}

class NotificationsScreen extends StatefulWidget {
  final List<AppNotificationItem> notifications;
  final Future<void> Function(String notificationId) onMarkRead;
  final Future<void> Function(List<AppNotificationItem> notifications)
  onMarkAllRead;
  final Future<void> Function(String notificationId) onDelete;
  final Future<void> Function(String notificationId) onRestore;

  const NotificationsScreen({
    super.key,
    required this.notifications,
    required this.onMarkRead,
    required this.onMarkAllRead,
    required this.onDelete,
    required this.onRestore,
  });

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  late List<AppNotificationItem> _notifications;

  @override
  void initState() {
    super.initState();
    _notifications = [...widget.notifications];
  }

  String _timeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) {
      return 'Just now';
    }
    if (diff.inHours < 1) {
      return '${diff.inMinutes}m ago';
    }
    if (diff.inDays < 1) {
      return '${diff.inHours}h ago';
    }
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: _notifications.isEmpty
                ? null
                : () async {
                    await widget.onMarkAllRead(_notifications);
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      _notifications = _notifications
                          .map((item) => item.copyWith(isRead: true))
                          .toList();
                    });
                  },
            child: const Text('Mark all read'),
          ),
        ],
      ),
      body: _notifications.isEmpty
          ? const Center(
              child: Text(
                'No notifications yet.',
                style: TextStyle(color: AppColors.text2),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _notifications.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final notification = _notifications[index];
                final icon = notification.type == AppNotificationType.article
                    ? Icons.menu_book_outlined
                    : notification.type == AppNotificationType.comment
                    ? Icons.mode_comment_outlined
                    : Icons.chat_bubble_outline;
                final card = Card(
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                      color: notification.isRead
                          ? Colors.black12
                          : AppColors.brand.withValues(alpha: 0.35),
                    ),
                  ),
                  child: ListTile(
                    onTap: () async {
                      if (!notification.isRead) {
                        await widget.onMarkRead(notification.id);
                        if (!mounted) {
                          return;
                        }
                        setState(() {
                          _notifications[index] = notification.copyWith(
                            isRead: true,
                          );
                        });
                      }
                    },
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: notification.isRead
                            ? const Color(0xFFF1F1F1)
                            : AppColors.brandLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        icon,
                        color: notification.isRead
                            ? AppColors.text2
                            : AppColors.brand,
                      ),
                    ),
                    title: Text(
                      notification.title,
                      style: TextStyle(
                        fontWeight: notification.isRead
                            ? FontWeight.w500
                            : FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      '${notification.body}\n${_timeAgo(notification.createdAt)}',
                    ),
                    isThreeLine: true,
                    trailing: notification.isRead
                        ? const Icon(Icons.done, color: AppColors.text2)
                        : const Icon(Icons.fiber_manual_record, size: 12),
                  ),
                );
                return Dismissible(
                  key: ValueKey('notification-${notification.id}'),
                  direction: DismissDirection.endToStart,
                  dismissThresholds: const {DismissDirection.endToStart: 0.36},
                  movementDuration: const Duration(milliseconds: 260),
                  resizeDuration: const Duration(milliseconds: 220),
                  background: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFD92D20),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    alignment: Alignment.centerRight,
                    child: const Icon(
                      Icons.delete_outline,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                  onDismissed: (_) async {
                    final removed = notification;
                    final messenger = ScaffoldMessenger.of(context);
                    setState(() => _notifications.removeAt(index));
                    try {
                      await widget.onDelete(removed.id);
                      if (!mounted) {
                        return;
                      }
                      messenger.clearSnackBars();
                      final result = await messenger
                          .showSnackBar(
                            SnackBar(
                              content: const Text('Notification dismissed'),
                              action: SnackBarAction(
                                label: 'Undo',
                                onPressed: () {},
                              ),
                              duration: const Duration(seconds: 4),
                            ),
                          )
                          .closed;
                      if (!mounted || result != SnackBarClosedReason.action) {
                        return;
                      }
                      final restoreAt = index.clamp(0, _notifications.length);
                      setState(() => _notifications.insert(restoreAt, removed));
                      await widget.onRestore(removed.id);
                    } catch (_) {
                      if (!mounted) {
                        return;
                      }
                      final restoreAt = index.clamp(0, _notifications.length);
                      setState(() => _notifications.insert(restoreAt, removed));
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Could not delete notification. Please try again.',
                          ),
                        ),
                      );
                    }
                  },
                  child: card,
                );
              },
            ),
    );
  }
}

class CommunityScreen extends StatefulWidget {
  final String currentUserUid;
  final String currentUserName;
  final String? currentUserPhotoUrl;
  final VoidCallback onOpenArticles;
  final ValueChanged<CommunityPost> onPostCreated;
  final void Function({
    required String postAuthorUid,
    required String commentAuthorName,
    required String commentText,
  })
  onCommentAdded;

  const CommunityScreen({
    super.key,
    required this.currentUserUid,
    required this.currentUserName,
    this.currentUserPhotoUrl,
    required this.onOpenArticles,
    required this.onPostCreated,
    required this.onCommentAdded,
  });

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _postsCollection =>
      _firestore.collection('communityPosts');
  CollectionReference<Map<String, dynamic>> get _userDirectoryCollection =>
      _firestore.collection('userDirectory');

  String _publicAuthorName(String storedAuthor, Map<String, dynamic>? data) {
    final username =
        ((data?['usernameLower'] as String?) ?? (data?['username'] as String?))
            ?.trim();
    if (username != null && username.isNotEmpty) {
      return '@$username';
    }
    final trimmedAuthor = storedAuthor.trim();
    if (trimmedAuthor.startsWith('@')) {
      return trimmedAuthor;
    }
    if (trimmedAuthor.contains('@')) {
      return 'Member';
    }
    return trimmedAuthor.isNotEmpty ? trimmedAuthor : 'Member';
  }

  String? _publicAuthorPhotoUrl(
    String? storedPhotoUrl,
    Map<String, dynamic>? data,
  ) {
    final directoryPhotoUrl = (data?['photoUrl'] as String?)?.trim();
    if (directoryPhotoUrl != null && directoryPhotoUrl.isNotEmpty) {
      return directoryPhotoUrl;
    }
    final trimmedStoredPhotoUrl = storedPhotoUrl?.trim();
    return trimmedStoredPhotoUrl != null && trimmedStoredPhotoUrl.isNotEmpty
        ? trimmedStoredPhotoUrl
        : null;
  }

  Future<void> _openCreatePostSheet() async {
    final controller = TextEditingController();
    String selectedTag = 'Support';
    const tags = ['Support', 'Wellbeing', 'Question', 'Update'];

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Create Post',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: selectedTag,
                    decoration: const InputDecoration(
                      labelText: 'Tag',
                      border: OutlineInputBorder(),
                    ),
                    items: tags
                        .map(
                          (tag) =>
                              DropdownMenuItem(value: tag, child: Text(tag)),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setModalState(() => selectedTag = value);
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: controller,
                    minLines: 4,
                    maxLines: 7,
                    decoration: const InputDecoration(
                      labelText: 'Share with community',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final content = controller.text.trim();
                        if (content.isEmpty) {
                          return;
                        }
                        final postRef = await _postsCollection.add({
                          'author': widget.currentUserName,
                          'authorUid': widget.currentUserUid,
                          'authorPhotoUrl': widget.currentUserPhotoUrl,
                          'role': 'Member',
                          'content': content,
                          'tag': selectedTag,
                          'likesCount': 0,
                          'commentsCount': 0,
                          'createdAt': FieldValue.serverTimestamp(),
                        });
                        widget.onPostCreated(
                          CommunityPost(
                            id: postRef.id,
                            author: widget.currentUserName,
                            authorUid: widget.currentUserUid,
                            authorPhotoUrl: widget.currentUserPhotoUrl,
                            role: 'Member',
                            content: content,
                            likes: 0,
                            comments: 0,
                            tag: selectedTag,
                            createdAt: DateTime.now(),
                          ),
                        );
                        if (context.mounted) {
                          Navigator.of(context).pop();
                        }
                      },
                      icon: const Icon(Icons.send_outlined),
                      label: const Text('Publish'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brand,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String _timeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) {
      return 'Now';
    }
    if (diff.inHours < 1) {
      return '${diff.inMinutes}m ago';
    }
    if (diff.inDays < 1) {
      return '${diff.inHours}h ago';
    }
    return '${diff.inDays}d ago';
  }

  Future<void> _toggleLike(CommunityPost post, bool currentlyLiked) async {
    final postRef = _postsCollection.doc(post.id);
    final likeRef = postRef.collection('likes').doc(widget.currentUserUid);
    await _firestore.runTransaction((transaction) async {
      final postSnap = await transaction.get(postRef);
      if (!postSnap.exists) {
        return;
      }
      final data = postSnap.data() ?? <String, dynamic>{};
      final currentLikes = (data['likesCount'] as num?)?.toInt() ?? 0;
      if (currentlyLiked) {
        transaction.delete(likeRef);
        transaction.update(postRef, {
          'likesCount': (currentLikes - 1).clamp(0, 1 << 30),
        });
      } else {
        transaction.set(likeRef, {
          'uid': widget.currentUserUid,
          'createdAt': FieldValue.serverTimestamp(),
        });
        transaction.update(postRef, {'likesCount': currentLikes + 1});
      }
    });
  }

  Future<void> _addComment(String postId, String comment) async {
    final trimmed = comment.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final postRef = _postsCollection.doc(postId);
    final commentsRef = postRef.collection('comments');
    final newCommentRef = commentsRef.doc();
    String? postAuthorUid;
    await _firestore.runTransaction((transaction) async {
      final postSnap = await transaction.get(postRef);
      if (!postSnap.exists) {
        return;
      }
      final data = postSnap.data() ?? <String, dynamic>{};
      postAuthorUid = (data['authorUid'] as String?)?.trim();
      final currentComments = (data['commentsCount'] as num?)?.toInt() ?? 0;
      transaction.set(newCommentRef, {
        'author': widget.currentUserName,
        'authorUid': widget.currentUserUid,
        'content': trimmed,
        'createdAt': FieldValue.serverTimestamp(),
      });
      transaction.update(postRef, {'commentsCount': currentComments + 1});
    });
    if (postAuthorUid != null &&
        postAuthorUid!.isNotEmpty &&
        postAuthorUid != widget.currentUserUid) {
      widget.onCommentAdded(
        postAuthorUid: postAuthorUid!,
        commentAuthorName: widget.currentUserName,
        commentText: trimmed,
      );
    }
  }

  Future<void> _deleteComment(String postId, String commentId) async {
    final postRef = _postsCollection.doc(postId);
    final commentRef = postRef.collection('comments').doc(commentId);
    await _firestore.runTransaction((transaction) async {
      final postSnap = await transaction.get(postRef);
      final commentSnap = await transaction.get(commentRef);
      if (!postSnap.exists || !commentSnap.exists) {
        return;
      }
      final postData = postSnap.data() ?? <String, dynamic>{};
      final currentComments = (postData['commentsCount'] as num?)?.toInt() ?? 0;
      transaction.delete(commentRef);
      transaction.update(postRef, {
        'commentsCount': (currentComments - 1).clamp(0, 1 << 30),
      });
    });
  }

  Future<bool> _confirmDelete({
    required String title,
    required String message,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brand,
                foregroundColor: Colors.white,
              ),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _openEditPostSheet(CommunityPost post) async {
    final contentController = TextEditingController(text: post.content);
    String selectedTag = post.tag;
    const tags = ['Support', 'Wellbeing', 'Question', 'Update'];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Edit Post',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: selectedTag,
                    decoration: const InputDecoration(
                      labelText: 'Tag',
                      border: OutlineInputBorder(),
                    ),
                    items: tags
                        .map(
                          (tag) =>
                              DropdownMenuItem(value: tag, child: Text(tag)),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setModalState(() => selectedTag = value);
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: contentController,
                    minLines: 4,
                    maxLines: 7,
                    decoration: const InputDecoration(
                      labelText: 'Post content',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final nextContent = contentController.text.trim();
                        if (nextContent.isEmpty) {
                          return;
                        }
                        await _postsCollection.doc(post.id).update({
                          'content': nextContent,
                          'tag': selectedTag,
                        });
                        if (context.mounted) {
                          Navigator.of(context).pop();
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brand,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save changes'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    contentController.dispose();
  }

  Future<void> _deletePost(String postId) async {
    await _postsCollection.doc(postId).delete();
  }

  Future<void> _openCommentsSheet(CommunityPost post) async {
    final controller = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              MediaQuery.of(context).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Comments',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 260,
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _postsCollection
                        .doc(post.id)
                        .collection('comments')
                        .orderBy('createdAt', descending: true)
                        .snapshots(),
                    builder: (context, snapshot) {
                      final docs = snapshot.data?.docs ?? const [];
                      if (docs.isEmpty) {
                        return const Center(
                          child: Text(
                            'No comments yet.',
                            style: TextStyle(color: AppColors.text2),
                          ),
                        );
                      }
                      return ListView.separated(
                        itemCount: docs.length,
                        separatorBuilder: (_, _) => const Divider(height: 10),
                        itemBuilder: (context, index) {
                          final data = docs[index].data();
                          final author =
                              (data['author'] as String?) ?? 'Member';
                          final authorUid =
                              (data['authorUid'] as String?) ?? '';
                          final content = (data['content'] as String?) ?? '';
                          final canDeleteComment =
                              authorUid == widget.currentUserUid;
                          return StreamBuilder<
                            DocumentSnapshot<Map<String, dynamic>>
                          >(
                            stream: _userDirectoryCollection
                                .doc(authorUid)
                                .snapshots(),
                            builder: (context, directorySnapshot) {
                              final authorName = _publicAuthorName(
                                author,
                                directorySnapshot.data?.data(),
                              );
                              return ListTile(
                                dense: true,
                                title: Text(
                                  authorName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Text(content),
                                trailing: canDeleteComment
                                    ? IconButton(
                                        onPressed: () async {
                                          final confirmed = await _confirmDelete(
                                            title: 'Delete comment?',
                                            message:
                                                'This comment will be removed permanently.',
                                          );
                                          if (!confirmed) {
                                            return;
                                          }
                                          await _deleteComment(
                                            post.id,
                                            docs[index].id,
                                          );
                                        },
                                        tooltip: 'Delete comment',
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          color: AppColors.brand,
                                        ),
                                      )
                                    : null,
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    labelText: 'Add a comment',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      await _addComment(post.id, controller.text);
                      controller.clear();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brand,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.send_outlined),
                    label: const Text('Send comment'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    controller.dispose();
  }

  Widget _buildPostCard(CommunityPost post) {
    final canManagePost = post.authorUid == widget.currentUserUid;
    final likeDocStream = _postsCollection
        .doc(post.id)
        .collection('likes')
        .doc(widget.currentUserUid)
        .snapshots();
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _userDirectoryCollection.doc(post.authorUid).snapshots(),
      builder: (context, directorySnapshot) {
        final directoryData = directorySnapshot.data?.data();
        final authorName = _publicAuthorName(post.author, directoryData);
        final authorPhotoUrl = _publicAuthorPhotoUrl(
          post.authorPhotoUrl,
          directoryData,
        );
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: likeDocStream,
          builder: (context, likeSnapshot) {
            final isLiked = likeSnapshot.data?.exists ?? false;
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: Colors.black12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.brandLight,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: authorPhotoUrl != null
                              ? Image.network(
                                  authorPhotoUrl,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return _ProfileInitialsAvatar(
                                      name: authorName,
                                      fontSize: 20,
                                    );
                                  },
                                )
                              : _ProfileInitialsAvatar(
                                  name: authorName,
                                  fontSize: 20,
                                ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                authorName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                '${post.role} • ${_timeAgo(post.createdAt)}',
                                style: const TextStyle(
                                  color: AppColors.text2,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.brandLight,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            post.tag,
                            style: const TextStyle(
                              color: AppColors.brand,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (canManagePost)
                          PopupMenuButton<String>(
                            onSelected: (value) async {
                              if (value == 'edit') {
                                _openEditPostSheet(post);
                              } else if (value == 'delete') {
                                final confirmed = await _confirmDelete(
                                  title: 'Delete post?',
                                  message:
                                      'Your post and its comments will be removed permanently.',
                                );
                                if (!confirmed) {
                                  return;
                                }
                                await _deletePost(post.id);
                              }
                            },
                            icon: const Icon(
                              Icons.more_horiz,
                              color: AppColors.text2,
                            ),
                            itemBuilder: (context) => const [
                              PopupMenuItem<String>(
                                value: 'edit',
                                child: Text('Edit'),
                              ),
                              PopupMenuItem<String>(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(post.content),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        InkWell(
                          onTap: () => _toggleLike(post, isLiked),
                          borderRadius: BorderRadius.circular(16),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  isLiked
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  size: 18,
                                  color: isLiked
                                      ? AppColors.brand
                                      : AppColors.text2,
                                ),
                                const SizedBox(width: 6),
                                Text('${post.likes}'),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 18),
                        InkWell(
                          onTap: () => _openCommentsSheet(post),
                          borderRadius: BorderRadius.circular(16),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.mode_comment_outlined,
                                  size: 18,
                                  color: AppColors.text2,
                                ),
                                const SizedBox(width: 6),
                                Text('${post.comments}'),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreatePostSheet,
        backgroundColor: AppColors.brand,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Post'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Community Forum',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: widget.onOpenArticles,
                    icon: const Icon(Icons.menu_book_outlined),
                    label: const Text('Articles'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _postsCollection
                    .orderBy('createdAt', descending: true)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = snapshot.data!.docs;
                  if (docs.isEmpty) {
                    return const Center(
                      child: Text(
                        'No posts yet. Be the first to share.',
                        style: TextStyle(color: AppColors.text2),
                      ),
                    );
                  }
                  final posts = docs.map((doc) {
                    final data = doc.data();
                    final createdAtValue = data['createdAt'];
                    final createdAt = createdAtValue is Timestamp
                        ? createdAtValue.toDate()
                        : DateTime.now();
                    return CommunityPost(
                      id: doc.id,
                      author: (data['author'] as String?) ?? 'Member',
                      authorUid: (data['authorUid'] as String?) ?? '',
                      authorPhotoUrl: (data['authorPhotoUrl'] as String?)
                          ?.trim(),
                      role: (data['role'] as String?) ?? 'Member',
                      content: (data['content'] as String?) ?? '',
                      likes: (data['likesCount'] as num?)?.toInt() ?? 0,
                      comments: (data['commentsCount'] as num?)?.toInt() ?? 0,
                      tag: (data['tag'] as String?) ?? 'Support',
                      createdAt: createdAt,
                    );
                  }).toList();
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: posts.length,
                    itemBuilder: (context, index) =>
                        _buildPostCard(posts[index]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  final UserProfileData profile;
  final String currentUserUid;
  final bool isAdmin;
  final ValueChanged<String> onNameSaved;
  final ValueChanged<String?> onUsernameSaved;
  final ValueChanged<String> onPhotoUrlSaved;
  final ValueChanged<EmergencyContact> onContactAdded;
  final ValueChanged<int> onContactRemoved;
  final VoidCallback onSignOut;

  const ProfileScreen({
    super.key,
    required this.profile,
    required this.currentUserUid,
    required this.isAdmin,
    required this.onNameSaved,
    required this.onUsernameSaved,
    required this.onPhotoUrlSaved,
    required this.onContactAdded,
    required this.onContactRemoved,
    required this.onSignOut,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  FirebaseStorage get _storage => FirebaseStorage.instance;
  final ImagePicker _imagePicker = ImagePicker();
  late final TextEditingController _nameController;
  late final TextEditingController _usernameController;
  final TextEditingController _contactNameController = TextEditingController();
  final TextEditingController _contactPhoneController = TextEditingController();
  final TextEditingController _editorEmailController = TextEditingController();
  final TextEditingController _editorUidController = TextEditingController();
  final TextEditingController _userSearchController = TextEditingController();
  bool _isLookingUpEditor = false;
  bool _isUploadingPhoto = false;
  String _userSearchQuery = '';

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile.name);
    _usernameController = TextEditingController(
      text: widget.profile.username ?? '',
    );
  }

  @override
  void didUpdateWidget(covariant ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.name != widget.profile.name) {
      _nameController.text = widget.profile.name;
    }
    if (oldWidget.profile.username != widget.profile.username) {
      _usernameController.text = widget.profile.username ?? '';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    _contactNameController.dispose();
    _contactPhoneController.dispose();
    _editorEmailController.dispose();
    _editorUidController.dispose();
    _userSearchController.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    FocusScope.of(context).unfocus();
    final next = _nameController.text.trim();
    if (next.isEmpty) {
      _showSnack('Name cannot be empty.');
      return;
    }
    try {
      await _firestore.collection('users').doc(widget.currentUserUid).set({
        'displayName': next,
      }, SetOptions(merge: true));
      await _firestore
          .collection('userDirectory')
          .doc(widget.currentUserUid)
          .set({
            'uid': widget.currentUserUid,
            'displayName': next,
            if (widget.profile.username != null)
              'username': widget.profile.username,
            if (widget.profile.username != null)
              'usernameLower': widget.profile.username,
            if (widget.profile.photoUrl != null)
              'photoUrl': widget.profile.photoUrl,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
      widget.onNameSaved(next);
      _showSnack('Profile updated.');
    } catch (error) {
      _showSnack('Failed to save profile: $error');
    }
  }

  // ignore: unused_element
  Future<void> _saveUsername() async {
    FocusScope.of(context).unfocus();
    final raw = _usernameController.text.trim();
    final displayName = _nameController.text.trim();
    final email = FirebaseAuth.instance.currentUser?.email
        ?.trim()
        .toLowerCase();
    try {
      final userRef = _firestore.collection('users').doc(widget.currentUserUid);
      final userSnap = await userRef.get();
      final prevLower = (userSnap.data()?['usernameLower'] as String?)?.trim();

      if (raw.isEmpty) {
        if (prevLower == null || prevLower.isEmpty) {
          _showSnack('You do not have a username set.');
          return;
        }
        final batch = _firestore.batch();
        batch.delete(_firestore.collection('usernames').doc(prevLower));
        batch.update(userRef, {
          'username': FieldValue.delete(),
          'usernameLower': FieldValue.delete(),
        });
        if (email != null && email.isNotEmpty) {
          batch.set(
            _firestore.collection('userDirectory').doc(widget.currentUserUid),
            {
              'uid': widget.currentUserUid,
              'email': email,
              if (displayName.isNotEmpty) 'displayName': displayName,
              'username': FieldValue.delete(),
              'usernameLower': FieldValue.delete(),
              if (widget.profile.photoUrl != null)
                'photoUrl': widget.profile.photoUrl,
              'updatedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          );
        }
        await batch.commit();
        widget.onUsernameSaved(null);
        _showSnack(
          'Username removed. Others can no longer find you by @handle.',
        );
        return;
      }

      final key = normalizeHelpherUsernameKey(raw);
      if (key == null) {
        _showSnack(
          'Usernames must be 3–30 characters: lowercase letters, numbers, or underscores.',
        );
        return;
      }

      if (key == prevLower) {
        await userRef.set({
          'username': key,
          'usernameLower': key,
        }, SetOptions(merge: true));
        await _firestore
            .collection('userDirectory')
            .doc(widget.currentUserUid)
            .set({
              'uid': widget.currentUserUid,
              if (displayName.isNotEmpty) 'displayName': displayName,
              'username': key,
              'usernameLower': key,
              if (widget.profile.photoUrl != null)
                'photoUrl': widget.profile.photoUrl,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
        final unameRef = _firestore.collection('usernames').doc(key);
        final unameSnap = await unameRef.get();
        if (unameSnap.exists) {
          if (displayName.isNotEmpty) {
            await unameRef.update({'displayName': displayName});
          }
        } else {
          await unameRef.set({
            'uid': widget.currentUserUid,
            'usernameLower': key,
            if (displayName.isNotEmpty) 'displayName': displayName,
          });
        }
        widget.onUsernameSaved(key);
        _showSnack('Username saved.');
        return;
      }

      final batch = _firestore.batch();
      if (prevLower != null && prevLower.isNotEmpty) {
        batch.delete(_firestore.collection('usernames').doc(prevLower));
      }
      batch.set(_firestore.collection('usernames').doc(key), {
        'uid': widget.currentUserUid,
        'usernameLower': key,
        if (displayName.isNotEmpty) 'displayName': displayName,
      });
      batch.set(userRef, {
        'username': key,
        'usernameLower': key,
      }, SetOptions(merge: true));
      if (email != null && email.isNotEmpty) {
        batch.set(
          _firestore.collection('userDirectory').doc(widget.currentUserUid),
          {
            'uid': widget.currentUserUid,
            'email': email,
            if (displayName.isNotEmpty) 'displayName': displayName,
            'username': key,
            'usernameLower': key,
            if (widget.profile.photoUrl != null)
              'photoUrl': widget.profile.photoUrl,
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      }
      await batch.commit();
      widget.onUsernameSaved(key);
      _showSnack('Username saved. Others can message you as @$key.');
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        _showSnack(
          'That username is taken or could not be saved. Try another.',
        );
        return;
      }
      _showSnack('Failed to save username: ${e.message ?? e.code}');
    } catch (error) {
      _showSnack('Failed to save username: $error');
    }
  }

  Future<void> _pickAndUploadPhoto() async {
    if (_isUploadingPhoto) {
      return;
    }
    final platform = Theme.of(context).platform;
    if (!supportsProfilePhotoPicker(platform)) {
      _showSnack(
        'Profile photo picking is not supported on this platform yet.',
      );
      return;
    }
    final signedInUid = FirebaseAuth.instance.currentUser?.uid;
    if (signedInUid == null || signedInUid != widget.currentUserUid) {
      _showSnack('Please sign in again before uploading a profile picture.');
      return;
    }
    try {
      Uint8List? bytes;
      if (kIsWeb ||
          platform == TargetPlatform.android ||
          platform == TargetPlatform.iOS) {
        final picked = await _imagePicker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 82,
          maxWidth: 1200,
        );
        if (picked == null) {
          return;
        }
        bytes = await picked.readAsBytes();
      } else {
        const group = XTypeGroup(
          label: 'Images',
          extensions: <String>['jpg', 'jpeg', 'png', 'webp'],
        );
        final file = await openFile(acceptedTypeGroups: [group]);
        if (file == null) {
          return;
        }
        bytes = await file.readAsBytes();
      }

      if (bytes.isEmpty) {
        _showSnack('Selected image was empty.');
        return;
      }
      setState(() => _isUploadingPhoto = true);
      final ref = _storage
          .ref()
          .child('users')
          .child(widget.currentUserUid)
          .child('profile.jpg');
      await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      final downloadUrl = _versionedPhotoUrl(
        await ref.getDownloadURL(),
        DateTime.now().millisecondsSinceEpoch,
      );
      await _firestore.collection('users').doc(widget.currentUserUid).set({
        'photoUrl': downloadUrl,
      }, SetOptions(merge: true));
      await _firestore
          .collection('userDirectory')
          .doc(widget.currentUserUid)
          .set({
            'uid': widget.currentUserUid,
            if (widget.profile.username != null)
              'username': widget.profile.username,
            if (widget.profile.username != null)
              'usernameLower': widget.profile.username,
            'photoUrl': downloadUrl,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
      widget.onPhotoUrlSaved(downloadUrl);
      _showSnack('Profile picture updated.');
    } on FirebaseException catch (error) {
      final message = error.message ?? error.code;
      if (error.code == 'unauthorized' || error.code == 'permission-denied') {
        _showSnack(
          'Upload blocked by Firebase Storage rules. '
          'Please deploy storage rules and try again.\n$message',
        );
        return;
      }
      _showSnack('Failed to upload photo: $message');
    } catch (error) {
      _showSnack('Failed to upload photo: $error');
    } finally {
      if (mounted) {
        setState(() => _isUploadingPhoto = false);
      }
    }
  }

  String _versionedPhotoUrl(String downloadUrl, int version) {
    final uri = Uri.parse(downloadUrl);
    return uri
        .replace(
          queryParameters: {...uri.queryParameters, 'v': version.toString()},
        )
        .toString();
  }

  void _addContact() {
    FocusScope.of(context).unfocus();
    final name = _contactNameController.text.trim();
    final phone = _contactPhoneController.text.trim();
    if (name.isEmpty || phone.isEmpty) {
      _showSnack('Enter both contact name and phone.');
      return;
    }
    widget.onContactAdded(EmergencyContact(name: name, phone: phone));
    _contactNameController.clear();
    _contactPhoneController.clear();
    _showSnack('Emergency contact added.');
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _setEditorStatusForUid({
    required String targetUid,
    required bool isEditor,
  }) async {
    if (targetUid.isEmpty) {
      _showSnack('Enter a UID first.');
      return;
    }
    try {
      await _firestore.collection('users').doc(targetUid).set({
        'isEditor': isEditor,
      }, SetOptions(merge: true));
      _showSnack(
        isEditor
            ? 'Editor access granted for $targetUid'
            : 'Editor access removed for $targetUid',
      );
    } catch (error) {
      _showSnack('Failed to update role: $error');
    }
  }

  Future<void> _setEditorStatus(bool isEditor) async {
    final targetUid = _editorUidController.text.trim();
    await _setEditorStatusForUid(targetUid: targetUid, isEditor: isEditor);
  }

  Future<void> _lookupUidByEmail() async {
    final email = _editorEmailController.text.trim().toLowerCase();
    if (email.isEmpty) {
      _showSnack('Enter an email first.');
      return;
    }
    setState(() => _isLookingUpEditor = true);
    try {
      final result = await _firestore
          .collection('users')
          .where('email', isEqualTo: email)
          .limit(1)
          .get();
      if (result.docs.isEmpty) {
        _showSnack('No user found for $email');
        return;
      }
      final doc = result.docs.first;
      _editorUidController.text = doc.id;
      _showSnack('Found UID for $email');
    } catch (error) {
      _showSnack('Lookup failed: $error');
    } finally {
      if (mounted) {
        setState(() => _isLookingUpEditor = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Profile',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          Center(
            child: Column(
              children: [
                Container(
                  width: 136,
                  height: 136,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.brandLight,
                    border: Border.all(color: Colors.white, width: 4),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x1A000000),
                        blurRadius: 16,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child:
                      widget.profile.photoUrl != null &&
                          widget.profile.photoUrl!.isNotEmpty
                      ? Image.network(
                          widget.profile.photoUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return _ProfileInitialsAvatar(
                              name: widget.profile.name,
                              fontSize: 36,
                            );
                          },
                        )
                      : _ProfileInitialsAvatar(
                          name: widget.profile.name,
                          fontSize: 36,
                        ),
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: _isUploadingPhoto ? null : _pickAndUploadPhoto,
                  icon: _isUploadingPhoto
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.photo_camera_outlined),
                  label: Text(
                    _isUploadingPhoto
                        ? 'Uploading...'
                        : 'Change profile picture',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _nameController,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Display name',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) {
              _saveName();
            },
          ),
          const SizedBox(height: 10),
          ElevatedButton(
            onPressed: _saveName,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.brand,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save profile'),
          ),
          const SizedBox(height: 18),
          const Text(
            'Public username',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Your username is permanent and cannot be changed.',
            style: TextStyle(fontSize: 13, color: AppColors.text2),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.brandLight,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.black12),
            ),
            child: Text(
              widget.profile.username != null &&
                      widget.profile.username!.isNotEmpty
                  ? '@${widget.profile.username}'
                  : 'No username set',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: widget.profile.username != null
                    ? AppColors.brand
                    : AppColors.text2,
              ),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: widget.onSignOut,
            icon: const Icon(Icons.logout),
            label: const Text('Sign out from Google'),
          ),
          if (widget.isAdmin) ...[
            const SizedBox(height: 24),
            const Text(
              'Editor Access (Admin)',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Text(
              'Your UID: ${widget.currentUserUid}',
              style: const TextStyle(color: AppColors.text2, fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _editorEmailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Target user email',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _isLookingUpEditor ? null : _lookupUidByEmail,
                icon: const Icon(Icons.search),
                label: Text(
                  _isLookingUpEditor ? 'Looking up...' : 'Find UID from email',
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _editorUidController,
              decoration: const InputDecoration(
                labelText: 'Target user UID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _setEditorStatus(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brand,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Grant editor'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _setEditorStatus(false),
                    icon: const Icon(Icons.remove_circle_outline),
                    label: const Text('Revoke editor'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              'Recent users',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _userSearchController,
              onChanged: (value) {
                setState(() => _userSearchQuery = value.trim().toLowerCase());
              },
              decoration: const InputDecoration(
                labelText: 'Search by email, name, or UID',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _firestore
                  .collection('users')
                  .orderBy('lastSignInAt', descending: true)
                  .limit(10)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Text(
                    'Could not load users right now.',
                    style: TextStyle(color: AppColors.text2),
                  );
                }
                if (!snapshot.hasData) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(minHeight: 2),
                  );
                }

                final allDocs = snapshot.data!.docs;
                final docs = allDocs.where((doc) {
                  if (_userSearchQuery.isEmpty) {
                    return true;
                  }
                  final data = doc.data();
                  final uid = doc.id.toLowerCase();
                  final email = ((data['email'] as String?) ?? '')
                      .toLowerCase();
                  final displayName = ((data['displayName'] as String?) ?? '')
                      .toLowerCase();
                  return uid.contains(_userSearchQuery) ||
                      email.contains(_userSearchQuery) ||
                      displayName.contains(_userSearchQuery);
                }).toList();
                if (docs.isEmpty) {
                  if (allDocs.isEmpty) {
                    return const Text(
                      'No synced users yet. Users appear after signing in once.',
                      style: TextStyle(color: AppColors.text2),
                    );
                  }
                  return const Text(
                    'No users match your search.',
                    style: TextStyle(color: AppColors.text2),
                  );
                }

                return Column(
                  children: docs.map((doc) {
                    final data = doc.data();
                    final uid = doc.id;
                    final email = (data['email'] as String?) ?? 'No email';
                    final displayName = (data['displayName'] as String?) ?? '';
                    final isEditor = data['isEditor'] == true;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        onTap: () => _editorUidController.text = uid,
                        title: Text(email),
                        subtitle: Text(
                          '${displayName.isEmpty ? 'Unknown user' : displayName}\n$uid',
                        ),
                        isThreeLine: true,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isEditor
                                  ? Icons.verified_user
                                  : Icons.person_outline,
                              color: isEditor
                                  ? AppColors.brand
                                  : AppColors.text2,
                            ),
                            const SizedBox(width: 6),
                            TextButton(
                              onPressed: () => _setEditorStatusForUid(
                                targetUid: uid,
                                isEditor: !isEditor,
                              ),
                              child: Text(
                                isEditor ? 'Revoke' : 'Grant',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
          const SizedBox(height: 24),
          const Text(
            'Emergency contacts',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          ...widget.profile.emergencyContacts.asMap().entries.map((entry) {
            final index = entry.key;
            final contact = entry.value;
            return Card(
              child: ListTile(
                title: Text(contact.name),
                subtitle: Text(contact.phone),
                trailing: IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    color: AppColors.brand,
                  ),
                  tooltip: 'Remove contact',
                  onPressed: () => widget.onContactRemoved(index),
                ),
              ),
            );
          }),
          const SizedBox(height: 12),
          TextField(
            controller: _contactNameController,
            decoration: const InputDecoration(
              labelText: 'Contact name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _contactPhoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Contact phone',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _addContact,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('Add emergency contact'),
          ),
        ],
      ),
    );
  }
}
