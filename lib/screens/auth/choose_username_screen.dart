import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../app.dart';
import '../../utils.dart';

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
