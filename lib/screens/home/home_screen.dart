import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../app.dart';
import '../../models/article.dart';
import '../../widgets/article_card.dart';
import '../articles/article_detail_screen.dart';

class HomeScreen extends StatelessWidget {
  final String userName;
  final String currentUserUid;
  final String currentUserName;
  final List<HelpHerArticle> featuredArticles;
  final VoidCallback onOpenSafety;
  final VoidCallback onOpenCommunity;
  final VoidCallback onOpenArticles;
  final VoidCallback onOpenNotifications;
  final int unreadNotifications;

  const HomeScreen({
    super.key,
    required this.userName,
    required this.currentUserUid,
    required this.currentUserName,
    required this.featuredArticles,
    required this.onOpenSafety,
    required this.onOpenCommunity,
    required this.onOpenArticles,
    required this.onOpenNotifications,
    required this.unreadNotifications,
  });

  @override
  Widget build(BuildContext context) {
    final isComputer = isComputerPlatform(Theme.of(context).platform);
    return SingleChildScrollView(
      child: Column(
        children: [
          _buildHeader(),
          if (isComputer) _buildLandingBanner(context),
          _buildSectionTitle('Quick Functions', top: 20),
          _buildQuickActions(context),
          _buildSectionTitle('Featured Articles'),
          ...featuredArticles.map(
            (article) => ArticleCard(
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
                      currentUserUid: currentUserUid,
                      currentUserName: currentUserName,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandingBanner(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.shield_outlined, color: AppColors.brand),
              SizedBox(width: 8),
              Text(
                'Safety Dashboard',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Need help right now? Open Emergency SOS for instant support and trusted contacts.',
            style: TextStyle(color: AppColors.text2, height: 1.35),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: onOpenSafety,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brand,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.warning_amber_rounded),
                  label: const Text('Open Emergency SOS'),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                onPressed: onOpenCommunity,
                icon: const Icon(Icons.forum_outlined),
                tooltip: 'Open community',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 60, 20, 40),
      decoration: const BoxDecoration(
        color: AppColors.brand,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              RichText(
                text: TextSpan(
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                  children: const [
                    TextSpan(text: 'Help'),
                    TextSpan(
                      text: 'Her',
                      style: TextStyle(color: Color(0xFFFFB3C6)),
                    ),
                  ],
                ),
              ),
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onOpenNotifications,
                      borderRadius: BorderRadius.circular(20),
                      child: const CircleAvatar(
                        backgroundColor: Colors.white24,
                        child: Icon(
                          Icons.notifications_none,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  if (unreadNotifications > 0)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          unreadNotifications > 99
                              ? '99+'
                              : '$unreadNotifications',
                          style: const TextStyle(
                            color: AppColors.brand,
                            fontWeight: FontWeight.w700,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            '${_timeOfDayGreeting(DateTime.now())},',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          Text(
            userName,
            style: GoogleFonts.playfairDisplay(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  String _timeOfDayGreeting(DateTime now) {
    final hour = now.hour;
    if (hour < 5) return 'Good night';
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    if (hour < 21) return 'Good evening';
    return 'Good night';
  }

  Widget _buildQuickActions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: isComputerPlatform(Theme.of(context).platform)
          ? _buildQuickActionsWeb()
          : _buildQuickActionsDefault(),
    );
  }

  Widget _buildQuickActionsWeb() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width:
                  wide
                      ? (constraints.maxWidth - 24) / 3
                      : (constraints.maxWidth - 12) / 2,
              child: _actionCard(
                'Emergency SOS',
                'Quick access',
                AppColors.brand,
                Colors.white,
                Icons.bolt,
                onTap: onOpenSafety,
              ),
            ),
            SizedBox(
              width:
                  wide
                      ? (constraints.maxWidth - 24) / 3
                      : (constraints.maxWidth - 12) / 2,
              child: _actionCard(
                'Community',
                'Join chat',
                AppColors.surface,
                AppColors.brand,
                Icons.people,
                onTap: onOpenCommunity,
              ),
            ),
            SizedBox(
              width:
                  wide
                      ? (constraints.maxWidth - 24) / 3
                      : (constraints.maxWidth - 12) / 2,
              child: _actionCard(
                'Articles',
                'Read & learn',
                AppColors.surface,
                AppColors.brand,
                Icons.menu_book,
                onTap: onOpenArticles,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildQuickActionsDefault() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _actionCard(
                'Emergency SOS',
                'Quick access',
                AppColors.brand,
                Colors.white,
                Icons.bolt,
                onTap: onOpenSafety,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _actionCard(
                'Community',
                'Join chat',
                AppColors.surface,
                AppColors.brand,
                Icons.people,
                onTap: onOpenCommunity,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _actionCard(
                'Articles',
                'Read & learn',
                AppColors.surface,
                AppColors.brand,
                Icons.menu_book,
                onTap: onOpenArticles,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(child: SizedBox()),
          ],
        ),
      ],
    );
  }

  Widget _actionCard(
    String title,
    String sub,
    Color bg,
    Color text,
    IconData icon, {
    required VoidCallback onTap,
  }) {
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.black12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: text, size: 28),
              const SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(
                  color: text,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              Text(
                sub,
                style: TextStyle(
                  color: text.withValues(alpha: 0.7),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(
    String title, {
    double top = 10,
    double bottom = 10,
  }) {
    return Container(
      alignment: Alignment.centerLeft,
      padding: EdgeInsets.fromLTRB(20, top, 20, bottom),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppColors.text2,
          letterSpacing: 1.2,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
