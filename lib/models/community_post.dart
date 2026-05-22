class CommunityPost {
  final String id;
  final String author;
  final String authorUid;
  final String? authorPhotoUrl;
  final String role;
  final String content;
  final int likes;
  final int comments;
  final String tag;
  final DateTime createdAt;

  const CommunityPost({
    required this.id,
    required this.author,
    required this.authorUid,
    this.authorPhotoUrl,
    required this.role,
    required this.content,
    required this.likes,
    required this.comments,
    required this.tag,
    required this.createdAt,
  });
}
