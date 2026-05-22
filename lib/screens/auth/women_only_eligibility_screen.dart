import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../app.dart';

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
