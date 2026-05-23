import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../app.dart';
import '../models/article.dart';
import '../models/community_post.dart';
import '../models/notification_item.dart';
import '../models/user_profile.dart';
import '../services/e2ee_manager.dart';
import '../screens/home/home_screen.dart';
import '../screens/community/community_screen.dart';
import '../screens/chat/chats_screen.dart';
import '../screens/emergency/emergency_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/notifications/notifications_screen.dart';
import '../widgets/desktop_sidebar.dart';

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
  int _switchToArticlesSerial = 0;

  // ── Windows local notifications ────────────────────────────────────────────
  FlutterLocalNotificationsPlugin? _localNotifs;
  int _windowsNotifId = 0;
  DateTime? _windowsNotifStartTime;
  // Tracks the last-seen lastMessageAt per chat room to detect new messages.
  final Map<String, Timestamp?> _lastSeenChatAt = {};
  // Deduplicates notification and SOS document IDs we've already toasted.
  final Set<String> _shownWindowsNotifIds = {};
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _windowsChatSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _windowsNotifSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _windowsSosSub;
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
    _initFcm();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      _initWindowsNotifications();
    }
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
    _windowsChatSub?.cancel();
    _windowsNotifSub?.cancel();
    _windowsSosSub?.cancel();
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

  void _openArticlesInCommunity() {
    _switchTab(1, animated: true);
    setState(() => _switchToArticlesSerial++);
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

  Future<void> _initFcm() async {
    // FCM background push is unsupported on Windows; skip token registration.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) return;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      // Android 8+ requires a notification channel to exist before the OS
      // can display any notification. Create it here so background / terminated
      // messages from FCM are guaranteed to have a valid channel to land on.
      if (defaultTargetPlatform == TargetPlatform.android) {
        const channel = AndroidNotificationChannel(
          'default_channel',
          'General Notifications',
          description:
              'Notifications for chat messages, comments, and SOS alerts',
          importance: Importance.high,
          showBadge: true,
        );
        final plugin = FlutterLocalNotificationsPlugin();
        await plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.createNotificationChannel(channel);
        // Initialise the plugin for Android so it can be used to display
        // foreground notifications as proper heads-up alerts.
        const androidSettings =
            AndroidInitializationSettings('@mipmap/ic_launcher');
        await plugin.initialize(
          settings: const InitializationSettings(android: androidSettings),
        );
        // Tell FCM to use our channel for high-priority messages so they
        // appear as heads-up notifications even when the app is foregrounded.
        await FirebaseMessaging.instance
            .setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
      }

      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        await _firestore
            .collection('users')
            .doc(widget.currentUserUid)
            .collection('fcmTokens')
            .doc(token)
            .set({
          'token': token,
          'platform': defaultTargetPlatform.name,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      // All users subscribe to the SOS broadcast topic.
      await messaging.subscribeToTopic('sos_alerts');
      // Show a snackbar for messages that arrive while the app is in the
      // foreground (the OS tray handles background / terminated delivery).
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        if (!mounted) return;
        final n = message.notification;
        if (n == null) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (n.title != null)
                  Text(
                    n.title!,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                if (n.body != null) Text(n.body!),
              ],
            ),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      });
    } catch (_) {
      // Non-critical — push notifications may not be available on this device.
    }
  }

  // ── Windows local notification methods ───────────────────────────────────

  Future<void> _initWindowsNotifications() async {
    const settings = InitializationSettings(
      windows: WindowsInitializationSettings(
        appName: 'HelpHer',
        appUserModelId: 'Com.HelpHer.App',
        // Stable GUID — do not change; it identifies HelpHer in the OS.
        guid: 'd49b0314-ee7a-4626-bf79-97cdb8a991bb',
      ),
    );
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(settings: settings);
    _localNotifs = plugin;
    _windowsNotifStartTime = DateTime.now();

    // Reuse the existing broadcast streams; Firestore streams support multiple
    // listeners so this doesn't create additional network connections.
    _windowsChatSub = _chatRoomsStream.listen(_onWindowsChatRoomChange);
    _windowsNotifSub = _notificationsStream.listen(_onWindowsNotifChange);
    _windowsSosSub = _firestore
        .collection('sosAlerts')
        .orderBy('createdAt', descending: true)
        .limit(20)
        .snapshots()
        .listen(_onWindowsSosChange);
  }

  void _showWindowsToast(String title, String body) {
    _localNotifs?.show(
      id: _windowsNotifId++,
      title: title,
      body: body,
      notificationDetails:
          const NotificationDetails(windows: WindowsNotificationDetails()),
    );
  }

  void _onWindowsChatRoomChange(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final startTime = _windowsNotifStartTime;
    if (startTime == null) return;

    for (final change in snapshot.docChanges) {
      if (change.type != DocumentChangeType.modified &&
          change.type != DocumentChangeType.added) {
        continue;
      }

      final data = change.doc.data() ?? {};
      final lastMsgAt = data['lastMessageAt'] as Timestamp?;
      final lastMsgBy = (data['lastMessageBy'] as String?)?.trim();
      final roomId = change.doc.id;

      // Cache the latest timestamp before any early returns.
      final prevAt = _lastSeenChatAt[roomId];
      _lastSeenChatAt[roomId] = lastMsgAt;

      if (lastMsgBy == widget.currentUserUid) continue;
      if (lastMsgAt == null) continue;
      if (!lastMsgAt.toDate().isAfter(startTime)) continue;
      if (prevAt != null && lastMsgAt.compareTo(prevAt) <= 0) continue;

      final msg = (data['lastMessage'] as String?) ?? 'New message';
      final roomName = data['name'] as String?;
      _showWindowsToast('💬 ${roomName ?? 'New message'}', msg);
    }
  }

  void _onWindowsNotifChange(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final startTime = _windowsNotifStartTime;
    if (startTime == null) return;

    for (final change in snapshot.docChanges) {
      if (change.type != DocumentChangeType.added) continue;

      final docId = change.doc.id;
      if (_shownWindowsNotifIds.contains(docId)) continue;

      final data = change.doc.data() ?? {};

      // Don't toast for events the current user triggered.
      final createdBy = (data['createdByUid'] as String?)?.trim();
      if (createdBy == widget.currentUserUid) continue;

      final ts = data['createdAt'] as Timestamp?;
      if (ts == null || !ts.toDate().isAfter(startTime)) continue;

      final type = data['type'] as String?;
      final targetUid = (data['targetUid'] as String?)?.trim();

      // Comments: only notify the post author.
      if (type == 'comment' && targetUid != widget.currentUserUid) continue;

      final title = (data['title'] as String?) ?? '';
      final body = (data['body'] as String?) ?? '';
      final icon = type == 'article'
          ? '📖'
          : type == 'comment'
          ? '💬'
          : '🔔';

      _shownWindowsNotifIds.add(docId);
      _showWindowsToast('$icon $title', body);
    }
  }

  void _onWindowsSosChange(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final startTime = _windowsNotifStartTime;
    if (startTime == null) return;

    for (final change in snapshot.docChanges) {
      if (change.type != DocumentChangeType.added) continue;

      final docId = change.doc.id;
      if (_shownWindowsNotifIds.contains(docId)) continue;

      final data = change.doc.data() ?? {};
      final senderUid = (data['senderUid'] as String?)?.trim();
      if (senderUid == widget.currentUserUid) continue;

      final ts = data['createdAt'] as Timestamp?;
      if (ts == null || !ts.toDate().isAfter(startTime)) continue;

      final senderName = (data['senderName'] as String?) ?? 'A HelpHer user';
      _shownWindowsNotifIds.add(docId);
      _showWindowsToast(
        '🚨 SOS Alert',
        '$senderName needs help! Open HelpHer immediately.',
      );
    }
  }

  Future<void> _initE2eeSetup() async {
    final status = await E2eeManager.ensureKeypair(
      widget.currentUserUid,
      _firestore,
    );
    if (!mounted) return;
    if (status == E2eeStatus.newKeypair) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showBackupSetupDialog();
      });
    } else if (status == E2eeStatus.backupAvailable) {
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
                          await E2eeManager.backupPrivateKey(
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
                          final ok = await E2eeManager.restoreFromBackup(
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
                    currentUserUid: widget.currentUserUid,
                    currentUserName: _profile.username != null
                        ? '@${_profile.username}'
                        : widget.currentUsername,
                    featuredArticles: _articles.take(2).toList(),
                    onOpenSafety: () => _switchTab(3, animated: true),
                    onOpenCommunity: () => _switchTab(1, animated: true),
                    onOpenArticles: _openArticlesInCommunity,
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
                    onPostCreated: _handleCommunityPostCreated,
                    onCommentAdded: _handleCommentAdded,
                    canManageArticles: widget.canManageArticles,
                    onArticleAdded: _addArticle,
                    onArticleUpdated: _updateArticle,
                    onArticleDeleted: _deleteArticle,
                    switchToArticlesSerial: _switchToArticlesSerial,
                  ),
                  ChatsScreen(
                    currentUserUid: widget.currentUserUid,
                    currentUserName: _profile.username != null
                        ? '@${_profile.username}'
                        : widget.currentUsername,
                  ),
                  EmergencyScreen(
                    profile: _profile,
                    currentUserUid: widget.currentUserUid,
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

                final pageView = AnimatedBuilder(
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

                return Scaffold(
                  body: isComputer
                      ? Row(
                          children: [
                            DesktopSidebar(
                              selectedIndex: _currentIndex,
                              onDestinationSelected: (index) =>
                                  _switchTab(index, animated: true),
                              profile: _profile,
                              unreadChatsCount: unreadChatsCount,
                            ),
                            const VerticalDivider(width: 1, thickness: 1),
                            Expanded(child: pageView),
                          ],
                        )
                      : pageView,
                  bottomNavigationBar: isComputer
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
