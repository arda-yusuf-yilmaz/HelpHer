import 'package:flutter/material.dart';

class HelpHerArticle {
  final String id;
  final String title;
  final String author;
  final String readTime;
  final String category;
  final String summary;
  final String content;
  final IconData icon;
  final Color accent;

  const HelpHerArticle({
    required this.id,
    required this.title,
    required this.author,
    required this.readTime,
    required this.category,
    required this.summary,
    required this.content,
    required this.icon,
    required this.accent,
  });

  Map<String, dynamic> toFirestoreData() {
    return {
      'title': title,
      'author': author,
      'readTime': readTime,
      'category': category,
      'summary': summary,
      'content': content,
    };
  }

  factory HelpHerArticle.fromFirestoreData(
    String id,
    Map<String, dynamic> data,
  ) {
    final category = (data['category'] as String?) ?? 'Safety';
    return HelpHerArticle(
      id: id,
      title: (data['title'] as String?) ?? '',
      author: (data['author'] as String?) ?? 'HelpHer Team',
      readTime: (data['readTime'] as String?) ?? '1 min',
      category: category,
      summary: (data['summary'] as String?) ?? '',
      content: (data['content'] as String?) ?? '',
      icon: _iconForCategory(category),
      accent: _accentForCategory(category),
    );
  }

  static IconData _iconForCategory(String category) {
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

  static Color _accentForCategory(String category) {
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
}
