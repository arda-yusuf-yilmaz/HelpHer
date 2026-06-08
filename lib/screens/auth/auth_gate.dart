import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../app.dart';
import '../../models/user_profile.dart';
import '../../shell/main_shell.dart';
import 'verify_email_screen.dart';
import 'women_only_eligibility_screen.dart';
import 'choose_username_screen.dart';
import 'onboarding_screen.dart';

// Imported from firebase_options via main.dart at runtime — resolved at compile
// time via the generated DefaultFirebaseOptions class.
import '../../firebase_options.dart';

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
  bool _agreedToPolicy = false;
  bool _isSigningIn = false;
  String? _authMessage;
  String? _eligibilityMessage;

  FirebaseAuth get _firebaseAuth => FirebaseAuth.instance;
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  String? _lastSyncedUserUid;
  bool _isConfirmingEligibility = false;
  // Tracks whether onboarding has been shown for the current session.
  // Firestore is the source of truth; this caches the result to avoid
  // re-showing it on every stream rebuild.
  final Set<String> _onboardingShownForUid = {};

  // ── 2FA state ──────────────────────────────────────────────────────────────
  static const _secureStorage = FlutterSecureStorage();
  // UIDs for which 2FA has been satisfied in this app session.
  final Set<String> _session2faVerified = {};
  // Guards against triggering the async 2FA check more than once per UID.
  String? _initiating2faForUid;
  bool _is2faSending = false;   // OTP is being sent
  bool _is2faPending = false;   // OTP sent, waiting for user input
  bool _is2faVerifying = false; // OTP is being verified
  String? _twoFaMessage;
  final TextEditingController _otpController = TextEditingController();

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
    // Platform / keychain errors (macOS/iOS)
    if (lower.contains('keychain') ||
        lower.contains('nserror') ||
        lower.contains('nslocalizedfailure')) {
      return 'Sign-in failed. Please try again or use a different method.';
    }
    // Wrong email or password — Firebase unified this into one opaque message
    // in newer SDK versions to prevent email enumeration.
    if (lower.contains('malformed or has expired') ||
        lower.contains('invalid-credential') ||
        lower.contains('invalid credential') ||
        lower.contains('password is invalid') ||
        lower.contains('no user record')) {
      return 'Incorrect email or password.';
    }
    if (lower.contains('email address is already in use')) {
      return 'An account with this email already exists.';
    }
    if (lower.contains('badly formatted') || lower.contains('invalid email')) {
      return 'Please enter a valid email address.';
    }
    if (lower.contains('too many requests') || lower.contains('unusual activity')) {
      return 'Too many attempts. Please wait a moment and try again.';
    }
    if (lower.contains('network') || lower.contains('connection')) {
      return 'Connection error. Please check your internet and try again.';
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

  // ── 2FA helpers ────────────────────────────────────────────────────────────

  static String _twoFaStorageKey(String uid) => '2fa_verified_$uid';

  /// Checks device cache; if not fresh, sends an OTP and shows the 2FA screen.
  /// Called via addPostFrameCallback so it never runs inside build().
  Future<void> _initiate2fa(User user) async {
    if (_is2faSending || _is2faPending) return;

    // Check whether this device has already been verified within the last 30 days.
    final stored = await _secureStorage.read(key: _twoFaStorageKey(user.uid));
    if (stored != null) {
      final verifiedAt = DateTime.tryParse(stored);
      if (verifiedAt != null &&
          DateTime.now().difference(verifiedAt).inDays < 30) {
        if (mounted) {
          setState(() => _session2faVerified.add(user.uid));
        }
        return;
      }
    }

    // Send OTP to the account email.
    if (!mounted) return;
    setState(() {
      _is2faSending = true;
      _twoFaMessage = null;
    });
    try {
      await FirebaseFunctions.instance
          .httpsCallable('send2faOtp')
          .call<Map<String, dynamic>>();
      if (mounted) {
        setState(() {
          _is2faSending = false;
          _is2faPending = true;
        });
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() {
          _is2faSending = false;
          _twoFaMessage = _friendly2faError(e);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _is2faSending = false;
          _twoFaMessage = 'Could not send the verification code. Please check your connection.';
        });
      }
    }
  }

  Future<void> _resend2faOtp(User user) async {
    // Reset so _initiate2fa will re-send (cooldown is enforced server-side).
    setState(() {
      _is2faPending = false;
      _initiating2faForUid = null;
      _twoFaMessage = null;
      _otpController.clear();
    });
    _initiating2faForUid = user.uid;
    await _initiate2fa(user);
  }

  Future<void> _submit2fa(User user) async {
    final code = _otpController.text.trim();
    if (code.length != 6) {
      setState(() => _twoFaMessage = 'Enter the 6-digit code.');
      return;
    }
    setState(() {
      _is2faVerifying = true;
      _twoFaMessage = null;
    });
    try {
      await FirebaseFunctions.instance
          .httpsCallable('verify2fa')
          .call<Map<String, dynamic>>({'code': code});
      // Success — persist device verification and continue.
      await _secureStorage.write(
        key: _twoFaStorageKey(user.uid),
        value: DateTime.now().toIso8601String(),
      );
      if (mounted) {
        setState(() {
          _is2faVerifying = false;
          _is2faPending = false;
          _session2faVerified.add(user.uid);
          _otpController.clear();
        });
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() {
          _is2faVerifying = false;
          _twoFaMessage = _friendly2faError(e);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _is2faVerifying = false;
          _twoFaMessage = 'Verification failed. Please try again.';
        });
      }
    }
  }

  String _friendly2faError(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'resource-exhausted':
        return e.message ?? 'Too many attempts. Please wait.';
      case 'deadline-exceeded':
      case 'not-found':
        return 'Code expired or not found. Request a new one.';
      case 'unauthenticated':
        return 'Incorrect code. Please try again.';
      default:
        return e.message ?? 'Verification failed. Please try again.';
    }
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
              final isAdmin = userData?['isAdmin'] == true;
              final canManageArticles =
                  userData?['isEditor'] == true || isAdmin;
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
              // First-time users see onboarding before the main app.
              final onboardingDone =
                  userData?['onboardingCompleted'] == true ||
                  _onboardingShownForUid.contains(user.uid);
              if (!onboardingDone) {
                return OnboardingScreen(
                  onComplete: () async {
                    _onboardingShownForUid.add(user.uid);
                    await _firestore
                        .collection('users')
                        .doc(user.uid)
                        .set({'onboardingCompleted': true},
                            SetOptions(merge: true));
                  },
                );
              }
              // Email/password users must pass 2FA before reaching the main app.
              // Google users are excluded — their provider handles its own security.
              if (isEmailProvider &&
                  !_session2faVerified.contains(user.uid)) {
                if (_initiating2faForUid != user.uid) {
                  _initiating2faForUid = user.uid;
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _initiate2fa(user),
                  );
                }
                return _build2faScreen(user);
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

  // ── 2FA screen ─────────────────────────────────────────────────────────────

  Widget _build2faScreen(User user) {
    final email = user.email ?? '';
    final isBusy = _is2faSending || _is2faVerifying;

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
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: AppColors.brand,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Center(
                      child: Icon(Icons.lock_outline,
                          color: Colors.white, size: 28),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Two-step verification',
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _is2faSending
                        ? 'Sending a code to $email…'
                        : 'Enter the 6-digit code sent to $email.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.text2),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _otpController,
                    enabled: _is2faPending && !isBusy,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 12,
                    ),
                    decoration: const InputDecoration(
                      counterText: '',
                      border: OutlineInputBorder(),
                      hintText: '······',
                      hintStyle: TextStyle(letterSpacing: 8),
                    ),
                    onSubmitted: (_) {
                      if (_is2faPending && !isBusy) _submit2fa(user);
                    },
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed:
                          _is2faPending && !isBusy ? () => _submit2fa(user) : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brand,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: isBusy
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Verify'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: isBusy ? null : () => _resend2faOtp(user),
                    child: const Text('Resend code'),
                  ),
                  TextButton(
                    onPressed: isBusy ? null : _signOut,
                    child: const Text('Sign out'),
                  ),
                  if (_twoFaMessage != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.brandLight,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _twoFaMessage!,
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
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: AppColors.brand,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Center(
                      child: Text(
                        'HH',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                  ),
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
                        ? 'Create an account or continue with Google.'
                        : 'Sign in with email/password or Google.',
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
                  if (isCreateAccount) ...[
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Checkbox(
                          value: _agreedToPolicy,
                          onChanged: (v) =>
                              setState(() => _agreedToPolicy = v ?? false),
                          activeColor: AppColors.brand,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                        Expanded(
                          child: RichText(
                            text: TextSpan(
                              style: const TextStyle(
                                  color: AppColors.text2, fontSize: 13),
                              children: [
                                const TextSpan(
                                    text: 'I agree to the '),
                                TextSpan(
                                  text: 'Terms of Service',
                                  style: const TextStyle(
                                    color: AppColors.brand,
                                    decoration: TextDecoration.underline,
                                  ),
                                  recognizer: TapGestureRecognizer()
                                    ..onTap = () => launchUrl(
                                          Uri.parse(
                                              'https://arda-yusuf-yilmaz.github.io/HelpHer/terms/'),
                                          mode: LaunchMode.externalApplication,
                                        ),
                                ),
                                const TextSpan(text: ' and '),
                                TextSpan(
                                  text: 'Privacy Policy',
                                  style: const TextStyle(
                                    color: AppColors.brand,
                                    decoration: TextDecoration.underline,
                                  ),
                                  recognizer: TapGestureRecognizer()
                                    ..onTap = () => launchUrl(
                                          Uri.parse(
                                              'https://arda-yusuf-yilmaz.github.io/HelpHer/privacy/'),
                                          mode: LaunchMode.externalApplication,
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: isBusy ||
                              !isConfigured ||
                              (isCreateAccount && !_agreedToPolicy)
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
                              _agreedToPolicy = false;
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
                      onPressed: isBusy ||
                              !isConfigured ||
                              (isCreateAccount && !_agreedToPolicy)
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
