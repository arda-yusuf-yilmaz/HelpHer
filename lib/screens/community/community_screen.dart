import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../app.dart';
import '../../models/article.dart';
import '../../models/community_post.dart';
import '../../widgets/article_card.dart';
import '../../widgets/profile_initials_avatar.dart';
import '../articles/article_detail_screen.dart';

class CommunityScreen extends StatefulWidget {
  final String currentUserUid;
  final String currentUserName;
  final String? currentUserPhotoUrl;
  final ValueChanged<CommunityPost> onPostCreated;
  final void Function({
    required String postAuthorUid,
    required String commentAuthorName,
    required String commentText,
  })
  onCommentAdded;

  const CommunityScreen({
    super.key,
    required this.currentUserUid,
    required this.currentUserName,
    this.currentUserPhotoUrl,
    required this.onPostCreated,
    required this.onCommentAdded,
  });

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen>
    with SingleTickerProviderStateMixin {
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _postsCollection =>
      _firestore.collection('communityPosts');
  CollectionReference<Map<String, dynamic>> get _userDirectoryCollection =>
      _firestore.collection('userDirectory');
  CollectionReference<Map<String, dynamic>> get _articlesCollection =>
      _firestore.collection('articles');

  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String _publicAuthorName(String storedAuthor, Map<String, dynamic>? data) {
    final username =
        ((data?['usernameLower'] as String?) ?? (data?['username'] as String?))
            ?.trim();
    if (username != null && username.isNotEmpty) {
      return '@$username';
    }
    final trimmedAuthor = storedAuthor.trim();
    if (trimmedAuthor.startsWith('@')) {
      return trimmedAuthor;
    }
    if (trimmedAuthor.contains('@')) {
      return 'Member';
    }
    return trimmedAuthor.isNotEmpty ? trimmedAuthor : 'Member';
  }

  String? _publicAuthorPhotoUrl(
    String? storedPhotoUrl,
    Map<String, dynamic>? data,
  ) {
    final directoryPhotoUrl = (data?['photoUrl'] as String?)?.trim();
    if (directoryPhotoUrl != null && directoryPhotoUrl.isNotEmpty) {
      return directoryPhotoUrl;
    }
    final trimmedStoredPhotoUrl = storedPhotoUrl?.trim();
    return trimmedStoredPhotoUrl != null && trimmedStoredPhotoUrl.isNotEmpty
        ? trimmedStoredPhotoUrl
        : null;
  }

  Future<void> _openCreatePostSheet() async {
    final controller = TextEditingController();
    String selectedTag = 'Support';
    const tags = ['Support', 'Wellbeing', 'Question', 'Update'];
    final isComputer = isComputerPlatform(Theme.of(context).platform);

    Future<void> publish(BuildContext ctx, StateSetter? _) async {
      final content = controller.text.trim();
      if (content.isEmpty) return;
      final postRef = await _postsCollection.add({
        'author': widget.currentUserName,
        'authorUid': widget.currentUserUid,
        if (widget.currentUserPhotoUrl != null)
          'authorPhotoUrl': widget.currentUserPhotoUrl,
        'role': 'Member',
        'content': content,
        'tag': selectedTag,
        'likesCount': 0,
        'commentsCount': 0,
        'createdAt': FieldValue.serverTimestamp(),
      });
      widget.onPostCreated(
        CommunityPost(
          id: postRef.id,
          author: widget.currentUserName,
          authorUid: widget.currentUserUid,
          authorPhotoUrl: widget.currentUserPhotoUrl,
          role: 'Member',
          content: content,
          likes: 0,
          comments: 0,
          tag: selectedTag,
          createdAt: DateTime.now(),
        ),
      );
      if (ctx.mounted) Navigator.of(ctx).pop();
    }

    Widget formFields(StateSetter setS) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: selectedTag,
              decoration: const InputDecoration(
                labelText: 'Tag',
                border: OutlineInputBorder(),
              ),
              items: tags
                  .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                  .toList(),
              onChanged: (v) {
                if (v != null) setS(() => selectedTag = v);
              },
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              minLines: 4,
              maxLines: 7,
              decoration: const InputDecoration(
                labelText: 'Share with community',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        );

    if (isComputer) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setS) => AlertDialog(
            title: const Text('Create Post'),
            content: SizedBox(width: 480, child: formFields(setS)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton.icon(
                onPressed: () => publish(ctx, setS),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brand,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.send_outlined),
                label: const Text('Publish'),
              ),
            ],
          ),
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setS) => Padding(
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
                  'Create Post',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                formFields(setS),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => publish(ctx, setS),
                    icon: const Icon(Icons.send_outlined),
                    label: const Text('Publish'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brand,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    controller.dispose();
  }

  String _timeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) {
      return 'Now';
    }
    if (diff.inHours < 1) {
      return '${diff.inMinutes}m ago';
    }
    if (diff.inDays < 1) {
      return '${diff.inHours}h ago';
    }
    return '${diff.inDays}d ago';
  }

  Future<void> _toggleLike(CommunityPost post, bool currentlyLiked) async {
    final postRef = _postsCollection.doc(post.id);
    final likeRef = postRef.collection('likes').doc(widget.currentUserUid);
    await _firestore.runTransaction((transaction) async {
      final postSnap = await transaction.get(postRef);
      if (!postSnap.exists) {
        return;
      }
      final data = postSnap.data() ?? <String, dynamic>{};
      final currentLikes = (data['likesCount'] as num?)?.toInt() ?? 0;
      if (currentlyLiked) {
        transaction.delete(likeRef);
        transaction.update(postRef, {
          'likesCount': (currentLikes - 1).clamp(0, 1 << 30),
        });
      } else {
        transaction.set(likeRef, {
          'uid': widget.currentUserUid,
          'createdAt': FieldValue.serverTimestamp(),
        });
        transaction.update(postRef, {'likesCount': currentLikes + 1});
      }
    });
  }

  Future<void> _addComment(String postId, String comment) async {
    final trimmed = comment.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final postRef = _postsCollection.doc(postId);
    final commentsRef = postRef.collection('comments');
    final newCommentRef = commentsRef.doc();
    String? postAuthorUid;
    await _firestore.runTransaction((transaction) async {
      final postSnap = await transaction.get(postRef);
      if (!postSnap.exists) {
        return;
      }
      final data = postSnap.data() ?? <String, dynamic>{};
      postAuthorUid = (data['authorUid'] as String?)?.trim();
      final currentComments = (data['commentsCount'] as num?)?.toInt() ?? 0;
      transaction.set(newCommentRef, {
        'author': widget.currentUserName,
        'authorUid': widget.currentUserUid,
        'content': trimmed,
        'createdAt': FieldValue.serverTimestamp(),
      });
      transaction.update(postRef, {'commentsCount': currentComments + 1});
    });
    if (postAuthorUid != null &&
        postAuthorUid!.isNotEmpty &&
        postAuthorUid != widget.currentUserUid) {
      widget.onCommentAdded(
        postAuthorUid: postAuthorUid!,
        commentAuthorName: widget.currentUserName,
        commentText: trimmed,
      );
    }
  }

  Future<void> _deleteComment(String postId, String commentId) async {
    final postRef = _postsCollection.doc(postId);
    final commentRef = postRef.collection('comments').doc(commentId);
    await _firestore.runTransaction((transaction) async {
      final postSnap = await transaction.get(postRef);
      final commentSnap = await transaction.get(commentRef);
      if (!postSnap.exists || !commentSnap.exists) {
        return;
      }
      final postData = postSnap.data() ?? <String, dynamic>{};
      final currentComments = (postData['commentsCount'] as num?)?.toInt() ?? 0;
      transaction.delete(commentRef);
      transaction.update(postRef, {
        'commentsCount': (currentComments - 1).clamp(0, 1 << 30),
      });
    });
  }

  Future<bool> _confirmDelete({
    required String title,
    required String message,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brand,
                foregroundColor: Colors.white,
              ),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _openEditPostSheet(CommunityPost post) async {
    final contentController = TextEditingController(text: post.content);
    String selectedTag = post.tag;
    const tags = ['Support', 'Wellbeing', 'Question', 'Update'];
    final isComputer = isComputerPlatform(Theme.of(context).platform);

    Future<void> save(BuildContext ctx) async {
      final nextContent = contentController.text.trim();
      if (nextContent.isEmpty) return;
      await _postsCollection.doc(post.id).update({
        'content': nextContent,
        'tag': selectedTag,
      });
      if (ctx.mounted) Navigator.of(ctx).pop();
    }

    Widget formFields(StateSetter setS) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: selectedTag,
              decoration: const InputDecoration(
                labelText: 'Tag',
                border: OutlineInputBorder(),
              ),
              items: tags
                  .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                  .toList(),
              onChanged: (v) {
                if (v != null) setS(() => selectedTag = v);
              },
            ),
            const SizedBox(height: 10),
            TextField(
              controller: contentController,
              minLines: 4,
              maxLines: 7,
              decoration: const InputDecoration(
                labelText: 'Post content',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        );

    if (isComputer) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setS) => AlertDialog(
            title: const Text('Edit Post'),
            content: SizedBox(width: 480, child: formFields(setS)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton.icon(
                onPressed: () => save(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brand,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save changes'),
              ),
            ],
          ),
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setS) => Padding(
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
                  'Edit Post',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                formFields(setS),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => save(ctx),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brand,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save changes'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    contentController.dispose();
  }

  Future<void> _deletePost(String postId) async {
    await _postsCollection.doc(postId).delete();
  }

  Future<void> _openCommentsSheet(CommunityPost post) async {
    final controller = TextEditingController();
    final isComputer = isComputerPlatform(Theme.of(context).platform);

    Widget commentsList() => SizedBox(
          height: 320,
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _postsCollection
                .doc(post.id)
                .collection('comments')
                .orderBy('createdAt', descending: true)
                .snapshots(),
            builder: (context, snapshot) {
              final docs = snapshot.data?.docs ?? const [];
              if (docs.isEmpty) {
                return const Center(
                  child: Text(
                    'No comments yet.',
                    style: TextStyle(color: AppColors.text2),
                  ),
                );
              }
              return ListView.separated(
                itemCount: docs.length,
                separatorBuilder: (_, _) => const Divider(height: 10),
                itemBuilder: (context, index) {
                  final data = docs[index].data();
                  final author = (data['author'] as String?) ?? 'Member';
                  final authorUid = (data['authorUid'] as String?) ?? '';
                  final content = (data['content'] as String?) ?? '';
                  final canDeleteComment =
                      authorUid == widget.currentUserUid;
                  return StreamBuilder<
                    DocumentSnapshot<Map<String, dynamic>>
                  >(
                    stream: _userDirectoryCollection
                        .doc(authorUid)
                        .snapshots(),
                    builder: (context, directorySnapshot) {
                      final authorName = _publicAuthorName(
                        author,
                        directorySnapshot.data?.data(),
                      );
                      return ListTile(
                        dense: true,
                        title: Text(
                          authorName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(content),
                        trailing: canDeleteComment
                            ? IconButton(
                                onPressed: () async {
                                  final confirmed = await _confirmDelete(
                                    title: 'Delete comment?',
                                    message:
                                        'This comment will be removed permanently.',
                                  );
                                  if (!confirmed) return;
                                  await _deleteComment(
                                    post.id,
                                    docs[index].id,
                                  );
                                },
                                tooltip: 'Delete comment',
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: AppColors.brand,
                                ),
                              )
                            : null,
                      );
                    },
                  );
                },
              );
            },
          ),
        );

    Widget commentInput(BuildContext ctx) => Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Add a comment',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: () async {
                await _addComment(post.id, controller.text);
                controller.clear();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brand,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.send_outlined),
              label: const Text('Send'),
            ),
          ],
        );

    if (isComputer) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Comments'),
          contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                commentsList(),
                const SizedBox(height: 12),
                commentInput(ctx),
                const SizedBox(height: 8),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Padding(
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
                  'Comments',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                commentsList(),
                const SizedBox(height: 8),
                commentInput(ctx),
              ],
            ),
          ),
        ),
      );
    }
    controller.dispose();
  }

  Widget _buildPostCard(CommunityPost post) {
    final canManagePost = post.authorUid == widget.currentUserUid;
    final likeDocStream = _postsCollection
        .doc(post.id)
        .collection('likes')
        .doc(widget.currentUserUid)
        .snapshots();
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _userDirectoryCollection.doc(post.authorUid).snapshots(),
      builder: (context, directorySnapshot) {
        final directoryData = directorySnapshot.data?.data();
        final authorName = _publicAuthorName(post.author, directoryData);
        final authorPhotoUrl = _publicAuthorPhotoUrl(
          post.authorPhotoUrl,
          directoryData,
        );
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: likeDocStream,
          builder: (context, likeSnapshot) {
            final isLiked = likeSnapshot.data?.exists ?? false;
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: Colors.black12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.brandLight,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: authorPhotoUrl != null
                              ? Image.network(
                                  authorPhotoUrl,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return ProfileInitialsAvatar(
                                      name: authorName,
                                      fontSize: 20,
                                    );
                                  },
                                )
                              : ProfileInitialsAvatar(
                                  name: authorName,
                                  fontSize: 20,
                                ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                authorName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                '${post.role} • ${_timeAgo(post.createdAt)}',
                                style: const TextStyle(
                                  color: AppColors.text2,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.brandLight,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            post.tag,
                            style: const TextStyle(
                              color: AppColors.brand,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (canManagePost)
                          PopupMenuButton<String>(
                            onSelected: (value) async {
                              if (value == 'edit') {
                                _openEditPostSheet(post);
                              } else if (value == 'delete') {
                                final confirmed = await _confirmDelete(
                                  title: 'Delete post?',
                                  message:
                                      'Your post and its comments will be removed permanently.',
                                );
                                if (!confirmed) {
                                  return;
                                }
                                await _deletePost(post.id);
                              }
                            },
                            icon: const Icon(
                              Icons.more_horiz,
                              color: AppColors.text2,
                            ),
                            itemBuilder: (context) => const [
                              PopupMenuItem<String>(
                                value: 'edit',
                                child: Text('Edit'),
                              ),
                              PopupMenuItem<String>(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(post.content),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        InkWell(
                          onTap: () => _toggleLike(post, isLiked),
                          borderRadius: BorderRadius.circular(16),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  isLiked
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  size: 18,
                                  color: isLiked
                                      ? AppColors.brand
                                      : AppColors.text2,
                                ),
                                const SizedBox(width: 6),
                                Text('${post.likes}'),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 18),
                        InkWell(
                          onTap: () => _openCommentsSheet(post),
                          borderRadius: BorderRadius.circular(16),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.mode_comment_outlined,
                                  size: 18,
                                  color: AppColors.text2,
                                ),
                                const SizedBox(width: 6),
                                Text('${post.comments}'),
                              ],
                            ),
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
    );
  }

  Widget _buildArticlesTab(bool isComputer) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _articlesCollection
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snapshot.data!.docs;
        if (docs.isEmpty) {
          return const Center(
            child: Text(
              'No articles yet.',
              style: TextStyle(color: AppColors.text2),
            ),
          );
        }
        final articles = docs
            .map((doc) => HelpHerArticle.fromFirestoreData(doc.id, doc.data()))
            .toList();

        Widget cardFor(HelpHerArticle article) => ArticleCard(
              title: article.title,
              author: article.author,
              readTime: article.readTime,
              color: article.accent,
              icon: article.icon,
              onTap: () => Navigator.of(context).push(
                buildSlideRoute<void>(
                  page: ArticleDetailScreen(
                    article: article,
                    currentUserUid: widget.currentUserUid,
                    currentUserName: widget.currentUserName,
                  ),
                ),
              ),
            );

        if (isComputer) {
          // Two-column grid on desktop
          final rows = <Widget>[];
          for (var i = 0; i < articles.length; i += 2) {
            rows.add(
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: cardFor(articles[i])),
                  if (i + 1 < articles.length)
                    Expanded(child: cardFor(articles[i + 1]))
                  else
                    const Expanded(child: SizedBox()),
                ],
              ),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            child: Column(children: rows),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: articles.length,
          itemBuilder: (_, i) => cardFor(articles[i]),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isComputer = isComputerPlatform(Theme.of(context).platform);
    final isPostsTab = _tabController.index == 0;
    return Scaffold(
      // Hide FAB on desktop — we show a button in the header instead
      floatingActionButton: isComputer || !isPostsTab
          ? null
          : FloatingActionButton.extended(
              onPressed: _openCreatePostSheet,
              backgroundColor: AppColors.brand,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Post'),
            ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Community',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  // On desktop show New Post button in header (only on Posts tab)
                  if (isComputer && isPostsTab)
                    FilledButton.icon(
                      onPressed: _openCreatePostSheet,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.brand,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('New Post'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TabBar(
              controller: _tabController,
              labelColor: AppColors.brand,
              unselectedLabelColor: AppColors.text2,
              indicatorColor: AppColors.brand,
              tabs: const [
                Tab(text: 'Posts'),
                Tab(text: 'Articles'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  // ── Posts tab ──────────────────────────────────────────
                  Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: isComputer ? 860 : double.infinity,
                      ),
                      child: StreamBuilder<
                        QuerySnapshot<Map<String, dynamic>>
                      >(
                        stream: _postsCollection
                            .orderBy('createdAt', descending: true)
                            .snapshots(),
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          final docs = snapshot.data!.docs;
                          if (docs.isEmpty) {
                            return const Center(
                              child: Text(
                                'No posts yet. Be the first to share.',
                                style: TextStyle(color: AppColors.text2),
                              ),
                            );
                          }
                          final posts = docs.map((doc) {
                            final data = doc.data();
                            final createdAtValue = data['createdAt'];
                            final createdAt = createdAtValue is Timestamp
                                ? createdAtValue.toDate()
                                : DateTime.now();
                            return CommunityPost(
                              id: doc.id,
                              author:
                                  (data['author'] as String?) ?? 'Member',
                              authorUid:
                                  (data['authorUid'] as String?) ?? '',
                              authorPhotoUrl: (data['authorPhotoUrl']
                                      as String?)
                                  ?.trim(),
                              role: (data['role'] as String?) ?? 'Member',
                              content: (data['content'] as String?) ?? '',
                              likes: (data['likesCount'] as num?)
                                      ?.toInt() ??
                                  0,
                              comments: (data['commentsCount'] as num?)
                                      ?.toInt() ??
                                  0,
                              tag: (data['tag'] as String?) ?? 'Support',
                              createdAt: createdAt,
                            );
                          }).toList();
                          return ListView.builder(
                            padding: const EdgeInsets.fromLTRB(
                              16,
                              8,
                              16,
                              16,
                            ),
                            itemCount: posts.length,
                            itemBuilder: (context, index) =>
                                _buildPostCard(posts[index]),
                          );
                        },
                      ),
                    ),
                  ),
                  // ── Articles tab ───────────────────────────────────────
                  _buildArticlesTab(isComputer),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
