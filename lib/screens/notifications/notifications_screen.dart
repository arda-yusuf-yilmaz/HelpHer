import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/notification_item.dart';

class NotificationsScreen extends StatefulWidget {
  final List<AppNotificationItem> notifications;
  final Future<void> Function(String notificationId) onMarkRead;
  final Future<void> Function(List<AppNotificationItem> notifications)
  onMarkAllRead;
  final Future<void> Function(String notificationId) onDelete;
  final Future<void> Function(String notificationId) onRestore;

  const NotificationsScreen({
    super.key,
    required this.notifications,
    required this.onMarkRead,
    required this.onMarkAllRead,
    required this.onDelete,
    required this.onRestore,
  });

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  late List<AppNotificationItem> _notifications;

  @override
  void initState() {
    super.initState();
    _notifications = [...widget.notifications];
  }

  String _timeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) {
      return 'Just now';
    }
    if (diff.inHours < 1) {
      return '${diff.inMinutes}m ago';
    }
    if (diff.inDays < 1) {
      return '${diff.inHours}h ago';
    }
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: _notifications.isEmpty
                ? null
                : () async {
                    await widget.onMarkAllRead(_notifications);
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      _notifications = _notifications
                          .map((item) => item.copyWith(isRead: true))
                          .toList();
                    });
                  },
            child: const Text('Mark all read'),
          ),
        ],
      ),
      body: _notifications.isEmpty
          ? const Center(
              child: Text(
                'No notifications yet.',
                style: TextStyle(color: AppColors.text2),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _notifications.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final notification = _notifications[index];
                final icon = notification.type == AppNotificationType.article
                    ? Icons.menu_book_outlined
                    : notification.type == AppNotificationType.comment
                    ? Icons.mode_comment_outlined
                    : Icons.chat_bubble_outline;
                final card = Card(
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                      color: notification.isRead
                          ? Colors.black12
                          : AppColors.brand.withValues(alpha: 0.35),
                    ),
                  ),
                  child: ListTile(
                    onTap: () async {
                      if (!notification.isRead) {
                        await widget.onMarkRead(notification.id);
                        if (!mounted) {
                          return;
                        }
                        setState(() {
                          _notifications[index] = notification.copyWith(
                            isRead: true,
                          );
                        });
                      }
                    },
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: notification.isRead
                            ? const Color(0xFFF1F1F1)
                            : AppColors.brandLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        icon,
                        color: notification.isRead
                            ? AppColors.text2
                            : AppColors.brand,
                      ),
                    ),
                    title: Text(
                      notification.title,
                      style: TextStyle(
                        fontWeight: notification.isRead
                            ? FontWeight.w500
                            : FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      '${notification.body}\n${_timeAgo(notification.createdAt)}',
                    ),
                    isThreeLine: true,
                    trailing: notification.isRead
                        ? const Icon(Icons.done, color: AppColors.text2)
                        : const Icon(Icons.fiber_manual_record, size: 12),
                  ),
                );
                return Dismissible(
                  key: ValueKey('notification-${notification.id}'),
                  direction: DismissDirection.endToStart,
                  dismissThresholds: const {DismissDirection.endToStart: 0.36},
                  movementDuration: const Duration(milliseconds: 260),
                  resizeDuration: const Duration(milliseconds: 220),
                  background: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFD92D20),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    alignment: Alignment.centerRight,
                    child: const Icon(
                      Icons.delete_outline,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                  onDismissed: (_) async {
                    final removed = notification;
                    final messenger = ScaffoldMessenger.of(context);
                    setState(() => _notifications.removeAt(index));
                    try {
                      await widget.onDelete(removed.id);
                      if (!mounted) {
                        return;
                      }
                      messenger.clearSnackBars();
                      final result = await messenger
                          .showSnackBar(
                            SnackBar(
                              content: const Text('Notification dismissed'),
                              action: SnackBarAction(
                                label: 'Undo',
                                onPressed: () {},
                              ),
                              duration: const Duration(seconds: 4),
                            ),
                          )
                          .closed;
                      if (!mounted || result != SnackBarClosedReason.action) {
                        return;
                      }
                      final restoreAt = index.clamp(0, _notifications.length);
                      setState(() => _notifications.insert(restoreAt, removed));
                      await widget.onRestore(removed.id);
                    } catch (_) {
                      if (!mounted) {
                        return;
                      }
                      final restoreAt = index.clamp(0, _notifications.length);
                      setState(() => _notifications.insert(restoreAt, removed));
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Could not delete notification. Please try again.',
                          ),
                        ),
                      );
                    }
                  },
                  child: card,
                );
              },
            ),
    );
  }
}
