class FirebaseBootstrapState {
  final bool isReady;
  final String? message;

  const FirebaseBootstrapState._({required this.isReady, this.message});

  const FirebaseBootstrapState.ready() : this._(isReady: true);

  const FirebaseBootstrapState.failed(String message)
    : this._(isReady: false, message: message);
}

class EmergencyContact {
  final String name;
  final String phone;

  const EmergencyContact({required this.name, required this.phone});
}

class UserProfileData {
  final String name;
  final String? photoUrl;

  /// Lowercase public handle; others use this to start DMs / groups.
  final String? username;
  final List<EmergencyContact> emergencyContacts;

  const UserProfileData({
    required this.name,
    this.photoUrl,
    this.username,
    required this.emergencyContacts,
  });
}
