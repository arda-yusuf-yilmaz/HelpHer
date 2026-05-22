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

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Create Post',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: selectedTag,
                    decoration: const InputDecoration(
                      labelText: 'Tag',
                      border: OutlineInputBorder(),
                    ),
                    items: tags
                        .map(
                          (tag) =>
                              DropdownMenuItem(value: tag, child: Text(tag)),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setModalState(() => selectedTag = value);
                      }
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
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final content = controller.text.trim();
                        if (content.isEmpty) {
                          return;
                        }
                        final postRef = await _postsCollection.add({
                          'author': widget.currentUserName,
                          'authorUid': widget.currentUserUid,
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
                        if (context.mounted) {
                          Navigator.of(context).pop();
                        }
                      },
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
            );
          },
        );
      },
    );
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
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Edit Post',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: selectedTag,
                    decoration: const InputDecoration(
                      labelText: 'Tag',
                      border: OutlineInputBorder(),
                    ),
                    items: tags
                        .map(
                          (tag) =>
                              DropdownMenuItem(value: tag, child: Text(tag)),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setModalState(() => selectedTag = value);
                      }
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
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final nextContent = contentController.text.trim();
                        if (nextContent.isEmpty) {
                          return;
                        }
                        await _postsCollection.doc(post.id).update({
                          'content': nextContent,
                          'tag': selectedTag,
                        });
                        if (context.mounted) {
                          Navigator.of(context).pop();
                        }
                      },
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
            );
          },
        );
      },
    );
    contentController.dispose();
  }

  Future<void> _deletePost(String postId) async {
    await _postsCollection.doc(postId).delete();
  }

  Future<void> _openCommentsSheet(CommunityPost post) async {
    final controller = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              MediaQuery.of(context).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Comments',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 260,
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
                          final author =
                              (data['author'] as String?) ?? 'Member';
                          final authorUid =
                              (data['authorUid'] as String?) ?? '';
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
                                          if (!confirmed) {
                                            return;
                                          }
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
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    labelText: 'Add a comment',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      await _addComment(post.id, controller.text);
                      controller.clear();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brand,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.send_outlined),
                    label: const Text('Send comment'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
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

  Widget _buildArticlesTab() {
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
        final articles = docs.map((doc) {
          return HelpHerArticle.fromFirestoreData(doc.id, doc.data());
        }).toList();
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: articles.length,
          itemBuilder: (context, index) {
            final article = articles[index];
            return ArticleCard(
              title: article.title,
              author: article.author,
              readTime: article.readTime,
              color: article.accent,
              icon: article.icon,
              onTap: () {
                Navigator.of(context).push(
                  buildSlideRoute<void>(
                    page: ArticleDetailScreen(
                      article: article,
                      currentUserUid: widget.currentUserUid,
                      currentUserName: widget.currentUserName,
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isPostsTab = _tabController.index == 0;
    return Scaffold(
      floatingActionButton: isPostsTab
          ? FloatingActionButton.extended(
              onPressed: _openCreatePostSheet,
              backgroundColor: AppColors.brand,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Post'),
            )
          : null,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Community',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _postsCollection
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
                          author: (data['author'] as String?) ?? 'Member',
                          authorUid: (data['authorUid'] as String?) ?? '',
                          authorPhotoUrl:
                              (data['authorPhotoUrl'] as String?)?.trim(),
                          role: (data['role'] as String?) ?? 'Member',
                          content: (data['content'] as String?) ?? '',
                          likes: (data['likesCount'] as num?)?.toInt() ?? 0,
                          comments:
                              (data['commentsCount'] as num?)?.toInt() ?? 0,
                          tag: (data['tag'] as String?) ?? 'Support',
                          createdAt: createdAt,
                        );
                      }).toList();
                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        itemCount: posts.length,
                        itemBuilder: (context, index) =>
                            _buildPostCard(posts[index]),
                      );
                    },
                  ),
                  // ── Articles tab ───────────────────────────────────────
                  _buildArticlesTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
