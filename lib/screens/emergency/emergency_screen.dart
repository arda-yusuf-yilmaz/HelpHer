import 'dart:async';
import 'dart:math' show pi;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_sms/flutter_sms.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../app.dart';
import '../../models/user_profile.dart';
import '../../utils.dart';

class EmergencyScreen extends StatefulWidget {
  final UserProfileData profile;
  final VoidCallback onOpenProfile;
  final String currentUserUid;

  const EmergencyScreen({
    super.key,
    required this.profile,
    required this.onOpenProfile,
    required this.currentUserUid,
  });

  @override
  State<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends State<EmergencyScreen>
    with TickerProviderStateMixin {
  // ── State ─────────────────────────────────────────────────────────────────
  bool _isHolding = false;
  Timer? _safetyCheckTimer;
  int _safetyCountdownSeconds = 0;
  int _safetyTotalSeconds = 120;
  bool _isSafetyCheckActive = false;
  bool _isEscalating = false;

  // ── Animation controllers ─────────────────────────────────────────────────
  // Idle rings: two expanding/fading concentric circles, looping.
  late final AnimationController _pulseController;
  // Hold-to-activate: fills a progress ring while the user holds.
  late final AnimationController _holdController;
  // Urgency pulse: drives the red ↔ orange flicker at ≤ 10 s.
  late final AnimationController _urgencyController;

  List<String> get _emergencyRecipientPhones =>
      widget.profile.emergencyContacts
          .map((c) => c.phone.trim())
          .where((p) => p.isNotEmpty)
          .toSet()
          .toList();

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();

    _holdController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          setState(() => _isHolding = false);
          _showActionSheet();
        }
      });

    _urgencyController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
  }

  @override
  void dispose() {
    _safetyCheckTimer?.cancel();
    _pulseController.dispose();
    _holdController.dispose();
    _urgencyController.dispose();
    super.dispose();
  }

  // ── Hold gesture ──────────────────────────────────────────────────────────

  void _startHold() {
    setState(() => _isHolding = true);
    _holdController.forward(from: 0);
  }

  void _cancelHold() {
    if (_holdController.isCompleted) return; // action already fired
    setState(() => _isHolding = false);
    _holdController.reverse();
  }

  // ── Emergency action helpers ──────────────────────────────────────────────

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

  void _writeSosAlert(String? locationLink) {
    Future(() async {
      final payload = <String, dynamic>{
        'senderUid': widget.currentUserUid,
        'senderName': widget.profile.name,
        'createdAt': FieldValue.serverTimestamp(),
      };
      if (locationLink != null) payload['locationLink'] = locationLink;
      await FirebaseFirestore.instance.collection('sosAlerts').add(payload);
    }).catchError((_) {});
  }

  Future<void> _sendAlertSmsToAll() async {
    final platform = Theme.of(context).platform;
    final locationLink = await _getLocationLink();
    _writeSosAlert(locationLink);
    final locationSuffix =
        locationLink != null ? ' My location: $locationLink' : '';
    if (!supportsNativeSms(platform)) {
      final text =
          'SOS alert from HelpHer user ${widget.profile.name}. '
          'Please check on me immediately.$locationSuffix';
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        _showMessage(
          'SMS sending is not supported on this device. '
          'We copied the alert text to your clipboard so you can paste it '
          'into your messaging app.',
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
        'SOS alert from HelpHer user ${widget.profile.name}. '
        'Please check on me immediately.$locationSuffix';
    try {
      await sendSMS(message: text, recipients: recipients);
      if (!mounted) return;
      _showMessage('Emergency SMS sent to ${recipients.length} contacts.');
      _startSafetyCheckCountdown();
    } catch (_) {
      final smsUri = Uri(
        scheme: 'sms',
        path: recipients.join(','),
        queryParameters: {'body': text},
      );
      final launched = await launchUrl(smsUri);
      if (!mounted) return;
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
          'We copied the message to your clipboard so you can paste it '
          'into your messaging app.',
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
      if (mounted) _showMessage(successMessage);
    } catch (_) {
      final smsUri = Uri(
        scheme: 'sms',
        path: recipients.join(','),
        queryParameters: {'body': text},
      );
      final launched = await launchUrl(smsUri);
      if (!mounted) return;
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
      _safetyTotalSeconds = seconds;
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
      setState(() => _safetyCountdownSeconds -= 1);
      // Start the urgency flicker at ≤ 10 s remaining.
      if (_safetyCountdownSeconds <= 10 && !_urgencyController.isAnimating) {
        _urgencyController.repeat(reverse: true);
      }
    });
  }

  Future<void> _markUserSafe() async {
    _safetyCheckTimer?.cancel();
    _urgencyController
      ..stop()
      ..reset();
    setState(() {
      _isSafetyCheckActive = false;
      _safetyCountdownSeconds = 0;
      _isEscalating = false;
    });
    await _sendStatusSmsToAll(
      text:
          'Update from ${widget.profile.name}: I am okay now. '
          'Thank you for checking on me.',
      successMessage: 'Safety update sent to your contacts.',
      failureMessage: 'Could not send your safety update.',
    );
  }

  Future<void> _handleNoResponseEscalation() async {
    if (_isEscalating) return;
    _urgencyController
      ..stop()
      ..reset();
    setState(() {
      _isEscalating = true;
      _isSafetyCheckActive = true;
      _safetyCountdownSeconds = 0;
    });
    final locationLink = await _getLocationLink();
    final locationSuffix =
        locationLink != null ? ' Last known location: $locationLink' : '';
    await _sendStatusSmsToAll(
      text:
          'No response from ${widget.profile.name} after an SOS alert. '
          'Please contact them urgently.$locationSuffix',
      successMessage: 'Escalation alert sent to your contacts.',
      failureMessage: 'Could not send escalation alert.',
    );
    if (mounted) setState(() => _isEscalating = false);
  }

  void _showActionSheet() {
    if (widget.profile.emergencyContacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Add at least one emergency contact in Profile first.',
          ),
        ),
      );
      return;
    }
    final firstContact = widget.profile.emergencyContacts.first;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
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
      ),
    );
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  String get _localEmergencyNumber {
    if (kIsWeb) return '112';
    final country = PlatformDispatcher.instance.locale.countryCode?.toUpperCase() ?? '';
    return switch (country) {
      'US' || 'CA' || 'MX' => '911',
      'GB' || 'IE' => '999',
      'AU' => '000',
      'NZ' => '111',
      'JP' || 'KR' => '119',
      'CN' => '120',
      'BR' => '190',
      _ => '112', // EU standard, also works in most other countries
    };
  }

  Future<void> _openEmergencyLine() async {
    final number = _localEmergencyNumber;
    final launched = await launchUrl(Uri(scheme: 'tel', path: number));
    if (!launched && mounted) {
      _showMessage('Could not open the emergency line on this device.');
    }
  }

  // ── UI helpers ────────────────────────────────────────────────────────────

  /// Single expanding/fading ring for the idle pulse effect.
  Widget _pulseRing(double diameter, double opacity) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: (opacity * 0.2).clamp(0, 1)),
        border: Border.all(
          color: Colors.white.withValues(alpha: opacity.clamp(0, 1)),
          width: 1.5,
        ),
      ),
    );
  }

  /// SOS button with idle pulse rings and hold-progress ring layered below.
  Widget _buildSosButton() {
    return SizedBox(
      width: 240,
      height: 240,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // ── Idle pulse rings ─────────────────────────────────────────
          AnimatedBuilder(
            animation: _pulseController,
            builder: (_, _) {
              final t1 = _pulseController.value;
              final t2 = (_pulseController.value + 0.5) % 1.0;
              return Stack(
                alignment: Alignment.center,
                children: [
                  _pulseRing(140.0 + 80.0 * t1, 0.40 * (1.0 - t1)),
                  _pulseRing(140.0 + 80.0 * t2, 0.40 * (1.0 - t2)),
                ],
              );
            },
          ),
          // ── Hold-to-activate progress ring ───────────────────────────
          // Shown while animating forward (holding) or reversing (cancelled).
          AnimatedBuilder(
            animation: _holdController,
            builder: (_, _) {
              final visible = _holdController.isAnimating ||
                  (_holdController.value > 0 &&
                      !_holdController.isCompleted);
              if (!visible) return const SizedBox.shrink();
              return SizedBox(
                width: 172,
                height: 172,
                child: CustomPaint(
                  painter: _ArcPainter(
                    progress: _holdController.value,
                    color: Colors.white,
                    trackColor: Colors.white.withValues(alpha: 0.25),
                    strokeWidth: 4.5,
                  ),
                ),
              );
            },
          ),
          // ── SOS button ────────────────────────────────────────────────
          GestureDetector(
            onLongPressStart: (_) => _startHold(),
            onLongPressEnd: (_) => _cancelHold(),
            onLongPressCancel: () => _cancelHold(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: _isHolding ? 150 : 140,
              height: _isHolding ? 150 : 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.white.withValues(
                      alpha: _isHolding ? 0.35 : 0.20,
                    ),
                    spreadRadius: _isHolding ? 20 : 10,
                  ),
                  BoxShadow(
                    color: Colors.white.withValues(
                      alpha: _isHolding ? 0.20 : 0.10,
                    ),
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
        ],
      ),
    );
  }

  /// Circular arc countdown timer shown after an SOS alert is sent.
  Widget _buildSafetyCheckArc() {
    final progress = _safetyTotalSeconds > 0
        ? (_safetyCountdownSeconds / _safetyTotalSeconds).clamp(0.0, 1.0)
        : 0.0;
    final minutes = _safetyCountdownSeconds ~/ 60;
    final secs = _safetyCountdownSeconds % 60;
    final timeText =
        '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';

    return Column(
      children: [
        // Arc ring + centre label — rebuilt every urgency-controller tick so
        // the colour can interpolate smoothly.
        AnimatedBuilder(
          animation: _urgencyController,
          builder: (_, _) {
            final Color arcColor;
            if (_isEscalating) {
              arcColor = Colors.orange.shade300;
            } else if (_safetyCountdownSeconds <= 10) {
              arcColor = Color.lerp(
                Colors.red.shade400,
                Colors.orange.shade300,
                _urgencyController.value,
              )!;
            } else if (_safetyCountdownSeconds <= 30) {
              arcColor = Colors.orange.shade300;
            } else {
              arcColor = Colors.white;
            }

            return SizedBox(
              width: 116,
              height: 116,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CustomPaint(
                    size: const Size(116, 116),
                    painter: _ArcPainter(
                      progress: progress,
                      color: arcColor,
                      trackColor: Colors.white.withValues(alpha: 0.2),
                      strokeWidth: 7,
                    ),
                  ),
                  if (_isEscalating)
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.orange,
                      size: 30,
                    )
                  else
                    Text(
                      timeText,
                      style: TextStyle(
                        color: arcColor,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        Text(
          _isEscalating
              ? 'Sending escalation alert…'
              : 'Auto-escalates if no response',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 14),
        // "I'm okay" / "Need help" buttons.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
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
                  onPressed:
                      _isEscalating ? null : _handleNoResponseEscalation,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.brand,
                  ),
                  child: const Text('Need help'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        // ── Brand header (SOS button + optional countdown) ─────────────────
        SliverToBoxAdapter(
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(
              0,
              60,
              0,
              _isSafetyCheckActive ? 24 : 40,
            ),
            color: AppColors.brand,
            child: Column(
              children: [
                _buildSosButton(),
                const SizedBox(height: 20),
                const Text(
                  'Hold to activate emergency actions',
                  style: TextStyle(color: Colors.white70),
                ),
                if (_isSafetyCheckActive) ...[
                  const SizedBox(height: 24),
                  _buildSafetyCheckArc(),
                  const SizedBox(height: 4),
                ],
              ],
            ),
          ),
        ),
        // ── Contacts + emergency line ──────────────────────────────────────
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
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
                'Emergency Line ($_localEmergencyNumber)',
                'Calls your local emergency services',
                Icons.local_police_outlined,
                const Color(0xFFE8EAF6),
                onTap: _openEmergencyLine,
              ),
            ]),
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

// ── Arc painter ──────────────────────────────────────────────────────────────

class _ArcPainter extends CustomPainter {
  final double progress; // 0.0 → empty, 1.0 → full circle
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  const _ArcPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - strokeWidth / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Background track (full circle, dim).
    canvas.drawArc(
      rect,
      -pi / 2,
      2 * pi,
      false,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );

    // Foreground arc (clockwise from 12 o'clock).
    if (progress > 0) {
      canvas.drawArc(
        rect,
        -pi / 2,
        2 * pi * progress,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      progress != old.progress ||
      color != old.color ||
      trackColor != old.trackColor ||
      strokeWidth != old.strokeWidth;
}
