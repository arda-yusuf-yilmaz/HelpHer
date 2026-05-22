import 'package:flutter/material.dart';
import '../../app.dart';

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
