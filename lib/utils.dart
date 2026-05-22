import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

bool supportsNativeSms(TargetPlatform platform) {
  return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
}

bool supportsProfilePhotoPicker(TargetPlatform platform) {
  // With file selector, desktop can pick images too.
  if (kIsWeb) return true;
  return platform == TargetPlatform.android ||
      platform == TargetPlatform.iOS ||
      platform == TargetPlatform.macOS ||
      platform == TargetPlatform.windows ||
      platform == TargetPlatform.linux;
}

/// Normalizes a HelpHer username: trim, optional leading `@`, lowercase, [a-z0-9_]{3,30}.
String? normalizeHelpherUsernameKey(String raw) {
  var s = raw.trim().toLowerCase();
  if (s.startsWith('@')) {
    s = s.substring(1);
  }
  if (s.isEmpty) {
    return null;
  }
  if (!RegExp(r'^[a-z0-9_]{3,30}$').hasMatch(s)) {
    return null;
  }
  return s;
}

/// Resolves a public username to a uid via [usernames] (see Firestore rules).
Future<Map<String, String>?> lookupHelpherUidByUsername(
  FirebaseFirestore firestore,
  String rawUsername,
) async {
  final key = normalizeHelpherUsernameKey(rawUsername);
  if (key == null) {
    return null;
  }
  final doc = await firestore.collection('usernames').doc(key).get();
  if (!doc.exists) {
    return null;
  }
  final data = doc.data();
  final uid = (data?['uid'] as String?)?.trim();
  if (uid == null || uid.isEmpty) {
    return null;
  }
  final displayName = (data?['displayName'] as String?)?.trim();
  return {
    'uid': uid,
    if (displayName != null && displayName.isNotEmpty)
      'displayName': displayName,
  };
}
