import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_selector/file_selector.dart';

import '../../app.dart';
import '../../utils.dart';
import 'chat_room_screen.dart';

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

  // Desktop master-detail state
  String? _selectedRoomId;
  String _selectedRoomName = '';
  String _selectedRoomType = 'group';
  List<String> _selectedRoomMembers = const [];

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
                      .where('members', arrayContains: widget.currentUserUid)
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
    final isComputer = isComputerPlatform(Theme.of(context).platform);

    Future<void> createGroup(BuildContext ctx) async {
      final name = nameController.text.trim();
      if (name.isEmpty) {
        _showChatSnack('Enter a group name.');
        return;
      }
      final parsed = membersController.text
          .split(',')
          .map((v) => v.trim())
          .where((v) => v.isNotEmpty)
          .toList();
      final resolvedOthers = await _resolveMemberIds(parsed);
      if (resolvedOthers == null) return;
      final members = <String>{
        widget.currentUserUid,
        ...resolvedOthers,
      }.toList();
      if (members.length < 2) {
        _showChatSnack('Add at least one other member by username.');
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
        if (!ctx.mounted) return;
        Navigator.of(ctx).pop();
        _openRoom(roomRef.id, name, type: 'group', members: members);
      } on FirebaseException catch (e) {
        _showChatSnack(e.message ?? 'Could not create group (${e.code}).');
      } catch (e) {
        _showChatSnack('Could not create group: $e');
      }
    }

    Widget formFields() => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
          ],
        );

    if (isComputer) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Create group chat'),
          content: SizedBox(width: 420, child: formFields()),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => createGroup(ctx),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brand,
                foregroundColor: Colors.white,
              ),
              child: const Text('Create group'),
            ),
          ],
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Create group chat',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              formFields(),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => createGroup(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brand,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Create group'),
                ),
              ),
            ],
          ),
        ),
      );
    }
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
    if (isComputerPlatform(Theme.of(context).platform)) {
      setState(() {
        _selectedRoomId = roomId;
        _selectedRoomName = roomName;
        _selectedRoomType = type;
        _selectedRoomMembers = members;
      });
    } else {
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
  }

  Widget _buildChatList() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Chats',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
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
                  final roomMembers =
                      (data['members'] as List?) ?? const [];
                  final groupPhotoUrl = data['photoUrl'] as String?;
                  final lastBy =
                      (data['lastMessageBy'] as String?) ?? '';
                  final lastAtRaw = data['lastMessageAt'];
                  final lastAt =
                      lastAtRaw is Timestamp ? lastAtRaw : null;
                  final readBy = data['lastReadBy'];
                  Timestamp? myReadAt;
                  if (readBy is Map<String, dynamic>) {
                    final value = readBy[myUid];
                    if (value is Timestamp) {
                      myReadAt = value;
                    }
                  }
                  final isSelected = _selectedRoomId == roomDoc.id;
                  final hasUnread =
                      !isSelected &&
                      lastAt != null &&
                      lastBy.isNotEmpty &&
                      lastBy != myUid &&
                      (myReadAt == null ||
                          lastAt.toDate().isAfter(myReadAt.toDate()));
                  Widget buildCard(Widget avatar, {Widget? trailingMenu}) {
                    // Unread dot widget, reused below.
                    const unreadDot = SizedBox(
                      width: 10,
                      height: 10,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.brand,
                          shape: BoxShape.circle,
                        ),
                      ),
                    );
                    // Reduce right contentPadding when there is a menu icon so
                    // it sits close to the card edge (mirrors article three-dot).
                    final rightPad = trailingMenu != null ? 4.0 : 16.0;
                    Widget? trailing;
                    if (hasUnread && trailingMenu != null) {
                      trailing = Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [unreadDot, const SizedBox(width: 6), trailingMenu],
                      );
                    } else if (hasUnread) {
                      trailing = unreadDot;
                    } else if (trailingMenu != null) {
                      trailing = trailingMenu;
                    }
                    return Card(
                      color: isSelected ? AppColors.brandLight : null,
                      child: ListTile(
                        // Rounded shape ensures the ink/hover highlight
                        // matches the card's corners instead of a rectangle.
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                        ),
                        contentPadding: EdgeInsets.only(left: 16, right: rightPad),
                        leading: avatar,
                        title: Text(roomName),
                        subtitle: Text(
                          lastMessage.isEmpty
                              ? '${roomMembers.length} members'
                              : lastMessage,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: trailing,
                        onTap: () => _openRoom(
                          roomDoc.id,
                          roomName,
                          type: type,
                          members: roomMembers.whereType<String>().toList(),
                        ),
                      ),
                    );
                  }
                  if (type == 'direct') {
                    final otherUid = roomMembers
                        .whereType<String>()
                        .firstWhere(
                          (m) => m != myUid,
                          orElse: () => '',
                        );
                    return StreamBuilder<
                      DocumentSnapshot<Map<String, dynamic>>
                    >(
                      stream: otherUid.isNotEmpty
                          ? _firestore
                                .collection('userDirectory')
                                .doc(otherUid)
                                .snapshots()
                          : const Stream.empty(),
                      builder: (ctx, dirSnap) {
                        final photoUrl =
                            dirSnap.data?.data()?['photoUrl']
                                as String?;
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
                                            Navigator.of(context)
                                                .pop(false),
                                        child: const Text('Cancel'),
                                      ),
                                      ElevatedButton(
                                        onPressed: () =>
                                            Navigator.of(context)
                                                .pop(true),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor:
                                              AppColors.brand,
                                          foregroundColor: Colors.white,
                                        ),
                                        child: const Text('Delete'),
                                      ),
                                    ],
                                  ),
                                ) ??
                                false;
                          },
                          onDismissed: (_) =>
                              _deleteDirectChat(roomDoc.id),
                          child: buildCard(_chatAvatar(photoUrl, true)),
                        );
                      },
                    );
                  }
                  return buildCard(
                    _chatAvatar(groupPhotoUrl, false),
                    trailingMenu: PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      // Use child: instead of icon: to avoid the IconButton
                      // 48px minimum tap-target, which pushed the icon left.
                      child: const Icon(
                        Icons.more_vert,
                        size: 20,
                        color: AppColors.text2,
                      ),
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
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isComputer = isComputerPlatform(Theme.of(context).platform);
    if (isComputer) {
      return SafeArea(
        child: Row(
          children: [
            // Left panel — chat list (300px)
            SizedBox(
              width: 300,
              child: _buildChatList(),
            ),
            const VerticalDivider(width: 1),
            // Right panel — selected room or placeholder
            Expanded(
              child: _selectedRoomId != null
                  ? ChatRoomScreen(
                      key: ValueKey(_selectedRoomId),
                      roomId: _selectedRoomId!,
                      roomName: _selectedRoomName,
                      currentUserUid: widget.currentUserUid,
                      currentUserName: widget.currentUserName,
                      roomType: _selectedRoomType,
                      roomMembers: _selectedRoomMembers,
                      isEmbedded: true,
                    )
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline,
                            size: 64,
                            color: AppColors.brandLight,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Select a conversation',
                            style: TextStyle(color: AppColors.text2),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      );
    }
    return SafeArea(child: _buildChatList());
  }
}
