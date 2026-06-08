import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../app.dart';
import '../../models/article.dart';

class ArticleDetailScreen extends StatefulWidget {
  final HelpHerArticle article;
  final String currentUserUid;
  final String currentUserName;

  const ArticleDetailScreen({
    super.key,
    required this.article,
    required this.currentUserUid,
    required this.currentUserName,
  });

  @override
  State<ArticleDetailScreen> createState() => _ArticleDetailScreenState();
}

class _ArticleDetailScreenState extends State<ArticleDetailScreen> {
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _commentsRef => _firestore
      .collection('articles')
      .doc(widget.article.id)
      .collection('comments');

  final _commentController = TextEditingController();

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _addComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    await _commentsRef.add({
      'author': widget.currentUserName,
      'authorUid': widget.currentUserUid,
      'content': text,
      'createdAt': FieldValue.serverTimestamp(),
    });
    _commentController.clear();
  }

  Future<void> _deleteComment(String commentId) async {
    await _commentsRef.doc(commentId).delete();
  }

  @override
  Widget build(BuildContext context) {
    final isComputer = isComputerPlatform(Theme.of(context).platform);
    // On macOS the title bar is hidden and traffic-light buttons overlay
    // Flutter content — push the AppBar down to clear them.
    // Windows uses a custom title bar rendered inside the sidebar so no inset needed.
    final isMacOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    const macOSInset = 28.0;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: isMacOS ? kToolbarHeight + macOSInset : kToolbarHeight,
        leading: isMacOS
            ? Padding(
                padding: const EdgeInsets.only(top: macOSInset),
                child: const BackButton(),
              )
            : null,
        title: Padding(
          padding: EdgeInsets.only(top: isMacOS ? macOSInset : 0),
          child: Text(widget.article.category),
        ),
        surfaceTintColor: Colors.transparent,
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: isComputer ? 780 : double.infinity,
          ),
          child: ListView(
            padding: EdgeInsets.symmetric(
              horizontal: isComputer ? 32 : 16,
              vertical: 16,
            ),
            children: [
              Container(
                height: 120,
                decoration: BoxDecoration(
                  color: widget.article.accent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  widget.article.icon,
                  size: 44,
                  color: AppColors.brand,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.article.title,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${widget.article.author} • ${widget.article.readTime}',
                style: const TextStyle(color: AppColors.text2),
              ),
              const SizedBox(height: 16),
              Text(
                widget.article.content,
                style: const TextStyle(height: 1.6, fontSize: 16),
              ),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 8),
              const Text(
                'Comments',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _commentsRef
                    .orderBy('createdAt', descending: false)
                    .snapshots(),
                builder: (context, snapshot) {
                  final docs = snapshot.data?.docs ?? const [];
                  if (docs.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No comments yet. Be the first to comment.',
                        style: TextStyle(color: AppColors.text2),
                      ),
                    );
                  }
                  return Column(
                    children: docs.map((doc) {
                      final data = doc.data();
                      final author =
                          (data['author'] as String?) ?? 'Member';
                      final authorUid =
                          (data['authorUid'] as String?) ?? '';
                      final content =
                          (data['content'] as String?) ?? '';
                      final canDelete =
                          authorUid == widget.currentUserUid;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          author,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(content),
                        trailing: canDelete
                            ? IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: AppColors.brand,
                                ),
                                onPressed: () =>
                                    _deleteComment(doc.id),
                              )
                            : null,
                      );
                    }).toList(),
                  );
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _commentController,
                decoration: const InputDecoration(
                  labelText: 'Add a comment',
                  border: OutlineInputBorder(),
                ),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _addComment,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brand,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.send_outlined),
                  label: const Text('Post comment'),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
