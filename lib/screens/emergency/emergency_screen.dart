import 'dart:async';
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

  /// Fire-and-forget: write an SOS event to Firestore so Cloud Functions can
  /// broadcast a push notification to all subscribed users.
  void _writeSosAlert(String? locationLink) {
    Future(() async {
      final payload = <String, dynamic>{
        'senderUid': widget.currentUserUid,
        'senderName': widget.profile.name,
        'createdAt': FieldValue.serverTimestamp(),
      };
      if (locationLink != null) payload['locationLink'] = locationLink;
      await FirebaseFirestore.instance.collection('sosAlerts').add(payload);
    }).catchError((_) {
      // Non-critical: push alert may not reach users, but SMS is still sent.
    });
  }

  Future<void> _sendAlertSmsToAll() async {
    final platform = Theme.of(context).platform;
    final locationLink = await _getLocationLink();
    // Trigger push notifications to all app users via Cloud Function.
    _writeSosAlert(locationLink);
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
