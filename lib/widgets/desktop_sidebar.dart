import 'package:flutter/material.dart';
import '../app.dart';
import '../models/user_profile.dart';
import 'profile_initials_avatar.dart';

class DesktopSidebar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final UserProfileData profile;
  final int unreadChatsCount;

  const DesktopSidebar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.profile,
    this.unreadChatsCount = 0,
  });

  static const _sidebarBg = Color(0xFFF9F5F6);

  @override
  Widget build(BuildContext context) {
    final displayName = profile.username != null
        ? '@${profile.username}'
        : profile.name;

    return Container(
      width: 220,
      color: _sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── App branding ───────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: AppColors.brand,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Icon(
                    Icons.favorite_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'HelpHer',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                    letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
          ),
          const _Divider(),
          const SizedBox(height: 6),
          // ── Nav items ──────────────────────────────────────────────────
          _SidebarItem(
            icon: Icons.home_outlined,
            selectedIcon: Icons.home_rounded,
            label: 'Home',
            index: 0,
            selected: selectedIndex == 0,
            onTap: onDestinationSelected,
          ),
          _SidebarItem(
            icon: Icons.people_outline,
            selectedIcon: Icons.people_rounded,
            label: 'Community',
            index: 1,
            selected: selectedIndex == 1,
            onTap: onDestinationSelected,
          ),
          _SidebarItem(
            icon: Icons.chat_bubble_outline_rounded,
            selectedIcon: Icons.chat_bubble_rounded,
            label: 'Chats',
            index: 2,
            selected: selectedIndex == 2,
            onTap: onDestinationSelected,
            badge: unreadChatsCount,
          ),
          _SidebarItem(
            icon: Icons.shield_outlined,
            selectedIcon: Icons.shield_rounded,
            label: 'Safety',
            index: 3,
            selected: selectedIndex == 3,
            onTap: onDestinationSelected,
          ),
          _SidebarItem(
            icon: Icons.person_outline_rounded,
            selectedIcon: Icons.person_rounded,
            label: 'Profile',
            index: 4,
            selected: selectedIndex == 4,
            onTap: onDestinationSelected,
          ),
          const Spacer(),
          // ── User footer ────────────────────────────────────────────────
          const _Divider(),
          _UserFooter(
            profile: profile,
            displayName: displayName,
            onTap: () => onDestinationSelected(4),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => const Divider(
        height: 1,
        thickness: 1,
        color: Color(0xFFEDE8E9),
      );
}

// ── Nav item ──────────────────────────────────────────────────────────────────

class _SidebarItem extends StatefulWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final int index;
  final bool selected;
  final ValueChanged<int> onTap;
  final int badge;

  const _SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.index,
    required this.selected,
    required this.onTap,
    this.badge = 0,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Color iconColor;
    final Color labelColor;
    final Color bg;

    if (widget.selected) {
      iconColor = AppColors.brand;
      labelColor = AppColors.brand;
      bg = AppColors.brandLight;
    } else if (_hovered) {
      iconColor = AppColors.text;
      labelColor = AppColors.text;
      bg = const Color(0xFFEFEBEC);
    } else {
      iconColor = AppColors.text2;
      labelColor = AppColors.text2;
      bg = Colors.transparent;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => widget.onTap(widget.index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  widget.selected ? widget.selectedIcon : widget.icon,
                  size: 20,
                  color: iconColor,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: widget.selected
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: labelColor,
                    ),
                  ),
                ),
                if (widget.badge > 0)
                  Container(
                    constraints: const BoxConstraints(
                      minWidth: 18,
                      minHeight: 18,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(
                      color: AppColors.brand,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      widget.badge > 9 ? '9+' : '${widget.badge}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── User footer ───────────────────────────────────────────────────────────────

class _UserFooter extends StatefulWidget {
  final UserProfileData profile;
  final String displayName;
  final VoidCallback onTap;

  const _UserFooter({
    required this.profile,
    required this.displayName,
    required this.onTap,
  });

  @override
  State<_UserFooter> createState() => _UserFooterState();
}

class _UserFooterState extends State<_UserFooter> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          color: _hovered ? const Color(0xFFEFEBEC) : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              SizedBox(
                width: 34,
                height: 34,
                child: ClipOval(
                  child: widget.profile.photoUrl != null
                      ? Image.network(
                          widget.profile.photoUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stack) => ProfileInitialsAvatar(
                            name: widget.displayName,
                            fontSize: 13,
                          ),
                        )
                      : ProfileInitialsAvatar(
                          name: widget.displayName,
                          fontSize: 13,
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.displayName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppColors.text,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.profile.username != null)
                      Text(
                        widget.profile.name,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.text2,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
