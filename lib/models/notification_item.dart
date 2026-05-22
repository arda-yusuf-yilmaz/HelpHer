enum AppNotificationType { article, message, comment }

class AppNotificationItem {
  final String id;
  final AppNotificationType type;
  final String title;
  final String body;
  final DateTime createdAt;
  final bool isRead;
  final String? createdByUid;

  const AppNotificationItem({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.isRead,
    this.createdByUid,
  });

  AppNotificationItem copyWith({bool? isRead}) {
    return AppNotificationItem(
      id: id,
      type: type,
      title: title,
      body: body,
      createdAt: createdAt,
      isRead: isRead ?? this.isRead,
      createdByUid: createdByUid,
    );
  }
}
