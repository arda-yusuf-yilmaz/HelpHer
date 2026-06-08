import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../app.dart';

class _OnboardingPage {
  final IconData icon;
  final String title;
  final String body;
  const _OnboardingPage({
    required this.icon,
    required this.title,
    required this.body,
  });
}

const _pages = [
  _OnboardingPage(
    icon: Icons.favorite,
    title: 'Welcome to HelpHer',
    body:
        'A safe, women-only space for community, support, and safety tools — '
        'all in one place.',
  ),
  _OnboardingPage(
    icon: Icons.bolt,
    title: 'Emergency SOS',
    body:
        'Hold the SOS button to instantly alert your trusted contacts and '
        'share your location. A safety check timer escalates automatically '
        'if you don\'t respond.',
  ),
  _OnboardingPage(
    icon: Icons.people,
    title: 'Community',
    body:
        'Share experiences, ask for advice, and support other women. '
        'Everything stays within the community — only verified members can see it.',
  ),
  _OnboardingPage(
    icon: Icons.menu_book,
    title: 'Resources & Articles',
    body:
        'Expert-written guides on personal safety, legal rights, digital '
        'privacy, and more. Knowledge is power.',
  ),
];

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const OnboardingScreen({super.key, required this.onComplete});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _currentPage = 0;

  void _next() {
    if (_currentPage < _pages.length - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      widget.onComplete();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _currentPage == _pages.length - 1;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // ── Skip ──────────────────────────────────────────────────────
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: widget.onComplete,
                child: const Text('Skip'),
              ),
            ),
            // ── Pages ─────────────────────────────────────────────────────
            Expanded(
              child: PageView.builder(
                controller: _controller,
                onPageChanged: (i) => setState(() => _currentPage = i),
                itemCount: _pages.length,
                itemBuilder: (context, index) {
                  final page = _pages[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 96,
                          height: 96,
                          decoration: const BoxDecoration(
                            color: AppColors.brandLight,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            page.icon,
                            color: AppColors.brand,
                            size: 48,
                          ),
                        ),
                        const SizedBox(height: 32),
                        Text(
                          page.title,
                          style: GoogleFonts.playfairDisplay(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            color: AppColors.text,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          page.body,
                          style: const TextStyle(
                            fontSize: 16,
                            color: AppColors.text2,
                            height: 1.6,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            // ── Dots ──────────────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pages.length, (i) {
                final active = i == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: active ? 20 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: active ? AppColors.brand : AppColors.brandLight,
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
            const SizedBox(height: 32),
            // ── Button ────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _next,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brand,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    isLast ? 'Get started' : 'Next',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
