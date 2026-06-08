import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../../app.dart';
import '../../models/user_profile.dart';
import '../../utils.dart';
import '../../widgets/profile_initials_avatar.dart';
import '../admin/reports_screen.dart';

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
  bool _isDeletingAccount = false;
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
              // email is intentionally excluded — userDirectory is readable by
              // all eligible users; email is only stored in users/{uid} which
              // is restricted to the owner and admins.
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
            // email excluded — see comment above
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

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This permanently deletes your account and all associated data. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isDeletingAccount = true);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('deleteAccount')
          .call<Map<String, dynamic>>();
      // Auth session is invalidated server-side; sign out locally to clear state.
      if (mounted) widget.onSignOut();
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() => _isDeletingAccount = false);
        _showSnack(e.message ?? 'Could not delete account. Please try again.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isDeletingAccount = false);
        _showSnack('Could not delete account. Please check your connection.');
      }
    }
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
    final isComputer = isComputerPlatform(Theme.of(context).platform);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isComputer ? 680 : double.infinity,
        ),
        child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
          const Text(
            'Profile',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 20),
          // ── Avatar row ──────────────────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.brandLight,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1A000000),
                      blurRadius: 12,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: widget.profile.photoUrl != null &&
                        widget.profile.photoUrl!.isNotEmpty
                    ? Image.network(
                        widget.profile.photoUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            ProfileInitialsAvatar(
                          name: widget.profile.name,
                          fontSize: 26,
                        ),
                      )
                    : ProfileInitialsAvatar(
                        name: widget.profile.name,
                        fontSize: 26,
                      ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.profile.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                      ),
                    ),
                    if (widget.profile.username != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        '@${widget.profile.username}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.brand,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed:
                          _isUploadingPhoto ? null : _pickAndUploadPhoto,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        textStyle: const TextStyle(fontSize: 13),
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: _isUploadingPhoto
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.photo_camera_outlined, size: 16),
                      label: Text(
                        _isUploadingPhoto ? 'Uploading…' : 'Change photo',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
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
            label: const Text('Sign out'),
          ),
          if (widget.isAdmin) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 8),
            const Text(
              'ADMIN',
              style: TextStyle(
                color: AppColors.text2,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.brandLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.flag_outlined, color: AppColors.brand),
              ),
              title: const Text('Community Reports',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Review and action flagged posts'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ReportsScreen(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Editor Access',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
          // ── Legal ─────────────────────────────────────────────────────────
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.gavel_outlined, color: AppColors.brand),
            title: const Text('Terms of Service'),
            subtitle: const Text('Rules and limitations of use'),
            trailing: const Icon(Icons.open_in_new,
                size: 16, color: AppColors.text2),
            onTap: () => launchUrl(
              Uri.parse(
                  'https://arda-yusuf-yilmaz.github.io/HelpHer/terms/'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.privacy_tip_outlined,
                color: AppColors.brand),
            title: const Text('Privacy Policy'),
            subtitle: const Text('How we collect and use your data'),
            trailing: const Icon(Icons.open_in_new,
                size: 16, color: AppColors.text2),
            onTap: () => launchUrl(
              Uri.parse(
                  'https://arda-yusuf-yilmaz.github.io/HelpHer/privacy/'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          // ── Danger zone ───────────────────────────────────────────────────
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 8),
          const Text(
            'DANGER ZONE',
            style: TextStyle(
              color: Colors.red,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isDeletingAccount ? null : _deleteAccount,
              icon: _isDeletingAccount
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.red),
                    )
                  : const Icon(Icons.delete_forever_outlined),
              label: Text(
                  _isDeletingAccount ? 'Deleting…' : 'Delete my account'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
      ),
    );
  }
}
