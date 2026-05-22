import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../app.dart';
import '../../services/e2ee_manager.dart';
import '../../utils.dart';

class ChatRoomScreen extends StatefulWidget {
  final String roomId;
  final String roomName;
  final String currentUserUid;
  final String currentUserName;
  final String roomType;
  final List<String> roomMembers;
  /// When true the widget is embedded in a desktop master-detail layout
  /// and should not render its own Scaffold / AppBar.
  final bool isEmbedded;

  const ChatRoomScreen({
    super.key,
    required this.roomId,
    required this.roomName,
    required this.currentUserUid,
    required this.currentUserName,
    this.roomType = 'group',
    this.roomMembers = const [],
    this.isEmbedded = false,
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
      final secret = await E2eeManager.deriveSharedSecret(
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
      final enc = await E2eeManager.encrypt(text, _sharedSecret!);
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
        final bodyColumn = Column(
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
                                    future: E2eeManager.decrypt(
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
          );
        if (widget.isEmbedded) {
          return Column(
            children: [
              // Embedded header replaces AppBar
              Container(
                height: 56,
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Colors.black12),
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.roomName,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (_e2eeReady) ...[
                            const SizedBox(width: 6),
                            const Tooltip(
                              message: 'End-to-end encrypted',
                              child: Icon(
                                Icons.lock,
                                size: 14,
                                color: AppColors.text2,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (roomType == 'group') ...[
                      IconButton(
                        tooltip: 'Add member',
                        onPressed: _addMemberDialog,
                        icon: const Icon(Icons.person_add_alt_1),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(child: bodyColumn),
            ],
          );
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
          body: bodyColumn,
        );
      },
    );
  }
}

