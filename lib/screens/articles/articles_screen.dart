import 'dart:async';
import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/article.dart';
import 'article_detail_screen.dart';

class ArticlesScreen extends StatefulWidget {
  final List<HelpHerArticle> articles;
  final bool canManageArticles;
  final String currentUserUid;
  final String currentUserName;
  final FutureOr<void> Function(HelpHerArticle) onArticleAdded;
  final FutureOr<void> Function(HelpHerArticle) onArticleUpdated;
  final FutureOr<void> Function(String) onArticleDeleted;

  const ArticlesScreen({
    super.key,
    required this.articles,
    required this.canManageArticles,
    required this.currentUserUid,
    required this.currentUserName,
    required this.onArticleAdded,
    required this.onArticleUpdated,
    required this.onArticleDeleted,
  });

  @override
  State<ArticlesScreen> createState() => _ArticlesScreenState();
}

class _ArticlesScreenState extends State<ArticlesScreen> {
  static const List<String> _categories = [
    'All',
    'Safety',
    'Legal',
    'Community',
  ];
  String _selectedCategory = 'All';
  String _query = '';

  List<HelpHerArticle> get _filteredArticles {
    return widget.articles.where((article) {
      final categoryMatch =
          _selectedCategory == 'All' || article.category == _selectedCategory;
      if (!categoryMatch) {
        return false;
      }

      final normalized = _query.trim().toLowerCase();
      if (normalized.isEmpty) {
        return true;
      }

      return article.title.toLowerCase().contains(normalized) ||
          article.summary.toLowerCase().contains(normalized) ||
          article.author.toLowerCase().contains(normalized);
    }).toList();
  }

  Future<void> _openArticleSheet({HelpHerArticle? initialArticle}) async {
    final isEditing = initialArticle != null;
    final titleController = TextEditingController(text: initialArticle?.title);
    final authorController = TextEditingController(
      text: initialArticle?.author,
    );
    final summaryController = TextEditingController(
      text: initialArticle?.summary,
    );
    final contentController = TextEditingController(
      text: initialArticle?.content,
    );
    String selectedCategory = initialArticle?.category ?? 'Safety';

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
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isEditing ? 'Edit Article' : 'Add New Article',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: 'Title',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: authorController,
                      decoration: const InputDecoration(
                        labelText: 'Author',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: selectedCategory,
                      decoration: const InputDecoration(
                        labelText: 'Category',
                        border: OutlineInputBorder(),
                      ),
                      items: _categories
                          .where((c) => c != 'All')
                          .map(
                            (category) => DropdownMenuItem<String>(
                              value: category,
                              child: Text(category),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setModalState(() => selectedCategory = value);
                      },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: summaryController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Short summary',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: contentController,
                      minLines: 5,
                      maxLines: 8,
                      decoration: const InputDecoration(
                        labelText: 'Article content',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          final article = _buildArticleFromInput(
                            id: initialArticle?.id,
                            title: titleController.text,
                            author: authorController.text,
                            category: selectedCategory,
                            summary: summaryController.text,
                            content: contentController.text,
                          );
                          if (article == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Please fill all fields before saving.',
                                ),
                              ),
                            );
                            return;
                          }
                          if (isEditing) {
                            widget.onArticleUpdated(article);
                          } else {
                            widget.onArticleAdded(article);
                          }
                          Navigator.of(context).pop();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.brand,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.save_outlined),
                        label: Text(
                          isEditing ? 'Update article' : 'Save article',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    titleController.dispose();
    authorController.dispose();
    summaryController.dispose();
    contentController.dispose();
  }

  HelpHerArticle? _buildArticleFromInput({
    String? id,
    required String title,
    required String author,
    required String category,
    required String summary,
    required String content,
  }) {
    final safeTitle = title.trim();
    final safeAuthor = author.trim();
    final safeSummary = summary.trim();
    final safeContent = content.trim();
    if (safeTitle.isEmpty ||
        safeAuthor.isEmpty ||
        safeSummary.isEmpty ||
        safeContent.isEmpty) {
      return null;
    }

    return HelpHerArticle(
      id: id ?? 'user-${DateTime.now().microsecondsSinceEpoch}',
      title: safeTitle,
      author: safeAuthor,
      readTime: _estimateReadTime(safeContent),
      category: category,
      summary: safeSummary,
      content: safeContent,
      icon: _iconForCategory(category),
      accent: _accentForCategory(category),
    );
  }

  String _estimateReadTime(String text) {
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    final minutes = (words / 180).ceil().clamp(1, 30);
    return '$minutes min';
  }

  IconData _iconForCategory(String category) {
    switch (category) {
      case 'Legal':
        return Icons.gavel_outlined;
      case 'Community':
        return Icons.people_alt_outlined;
      case 'Safety':
      default:
        return Icons.shield_outlined;
    }
  }

  Color _accentForCategory(String category) {
    switch (category) {
      case 'Legal':
        return const Color(0xFFEDE7F6);
      case 'Community':
        return const Color(0xFFE8F5E9);
      case 'Safety':
      default:
        return const Color(0xFFFFEBEE);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isComputer = isComputerPlatform(Theme.of(context).platform);
    return Scaffold(
      appBar: isComputer
          ? AppBar(
              title: const Text('Articles'),
              surfaceTintColor: Colors.transparent,
              leading: BackButton(
                onPressed: () => Navigator.of(context).pop(),
              ),
            )
          : null,
      floatingActionButton: widget.canManageArticles
          ? FloatingActionButton.extended(
              onPressed: () => _openArticleSheet(),
              backgroundColor: AppColors.brand,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('Add Article'),
            )
          : null,
      body: SafeArea(
        top: !isComputer,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: 'Search articles...',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Colors.black12),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Colors.black12),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                itemBuilder: (context, index) {
                  final category = _categories[index];
                  final selected = category == _selectedCategory;
                  return ChoiceChip(
                    label: Text(category),
                    selected: selected,
                    selectedColor: AppColors.brandLight,
                    labelStyle: TextStyle(
                      color: selected ? AppColors.brand : AppColors.text2,
                      fontWeight: FontWeight.w600,
                    ),
                    onSelected: (_) =>
                        setState(() => _selectedCategory = category),
                  );
                },
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemCount: _categories.length,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _filteredArticles.isEmpty
                  ? const Center(
                      child: Text(
                        'No articles match your search yet.',
                        style: TextStyle(color: AppColors.text2),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      itemCount: _filteredArticles.length,
                      itemBuilder: (context, index) {
                        final article = _filteredArticles[index];
                        return _ArticleFeedCard(
                          article: article,
                          onEdit: widget.canManageArticles
                              ? () => _openArticleSheet(initialArticle: article)
                              : null,
                          onDelete: widget.canManageArticles
                              ? () => widget.onArticleDeleted(article.id)
                              : null,
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
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArticleFeedCard extends StatelessWidget {
  final HelpHerArticle article;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _ArticleFeedCard({
    required this.article,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Colors.black12),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: article.accent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(article.icon, color: AppColors.brand),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      article.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      article.summary,
                      style: const TextStyle(color: AppColors.text2),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${article.category} • ${article.author} • ${article.readTime}',
                      style: const TextStyle(
                        color: AppColors.text2,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              if (onEdit != null && onDelete != null)
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') {
                      onEdit!();
                    } else if (value == 'delete') {
                      onDelete!();
                    }
                  },
                  icon: const Icon(Icons.more_horiz, color: AppColors.text2),
                  itemBuilder: (context) => const [
                    PopupMenuItem<String>(value: 'edit', child: Text('Edit')),
                    PopupMenuItem<String>(
                      value: 'delete',
                      child: Text('Delete'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
