import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../app.dart';

class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  Future<void> _dismissReport(BuildContext context, String reportId) async {
    await _firestore.collection('reports').doc(reportId).delete();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Report dismissed.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _deletePostAndReport(
    BuildContext context,
    String reportId,
    String postId,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete post?'),
        content: const Text(
          'This will permanently delete the post and all its comments. '
          'The report will also be dismissed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete post'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final batch = _firestore.batch();
    // Delete the post (subcollections — comments, likes — are not deleted by
    // this batch but become inaccessible once the parent doc is gone).
    batch.delete(_firestore.collection('communityPosts').doc(postId));
    // Dismiss the report.
    batch.delete(_firestore.collection('reports').doc(reportId));
    await batch.commit();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Post deleted and report dismissed.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F4FA),
      body: Column(
        children: [
          // ── Header ────────────────────────────────────────────────────────
          Container(
            color: AppColors.brand,
            padding: EdgeInsets.fromLTRB(20, topPad + 14, 4, 14),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Reports',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          // ── Reports list ──────────────────────────────────────────────────
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _firestore
                  .collection('reports')
                  .where('status', isEqualTo: 'open')
                  .orderBy('createdAt', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      'Error loading reports.',
                      style: TextStyle(color: AppColors.text2),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snapshot.data!.docs;
                if (docs.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle_outline,
                            size: 48, color: AppColors.brand),
                        SizedBox(height: 12),
                        Text(
                          'No open reports.',
                          style: TextStyle(
                            color: AppColors.text2,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data();
                    final reportId = doc.id;
                    final postId = (data['postId'] as String?) ?? '';
                    final postAuthor =
                        (data['postAuthorName'] as String?) ?? 'Unknown';
                    final postPreview =
                        (data['postContentPreview'] as String?) ?? '';
                    final reason = (data['reason'] as String?) ?? '';
                    final createdAt =
                        (data['createdAt'] as Timestamp?)?.toDate();

                    return Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: const BorderSide(color: Colors.black12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // ── Reason chip + timestamp ─────────────────────
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppColors.brandLight,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    reason,
                                    style: const TextStyle(
                                      color: AppColors.brand,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                if (createdAt != null)
                                  Text(
                                    _formatDate(createdAt),
                                    style: const TextStyle(
                                      color: AppColors.text2,
                                      fontSize: 12,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            // ── Post preview ────────────────────────────────
                            Text(
                              'By $postAuthor',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 4),
                            if (postPreview.isNotEmpty)
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF1F1F1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  postPreview,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppColors.text,
                                  ),
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            const SizedBox(height: 12),
                            // ── Actions ─────────────────────────────────────
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () =>
                                        _dismissReport(context, reportId),
                                    child: const Text('Dismiss'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: postId.isEmpty
                                        ? null
                                        : () => _deletePostAndReport(
                                              context,
                                              reportId,
                                              postId,
                                            ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red,
                                      foregroundColor: Colors.white,
                                    ),
                                    child: const Text('Delete post'),
                                  ),
                                ),
                              ],
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
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
