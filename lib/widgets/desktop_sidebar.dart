import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../app.dart';
import '../models/user_profile.dart';
import 'profile_initials_avatar.dart';

// Extra top padding on macOS so the HelpHer branding clears the traffic-light
// buttons, which sit at ≈ y 8–24 pt from the top of the window.
const double _kMacTrafficLightClearance = 38.0;

const _kHoverBg = Color(0xFFEFEBEC);

class DesktopSidebar extends StatefulWidget {
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

  @override
  State<DesktopSidebar> createState() => _DesktopSidebarState();
}

class _DesktopSidebarState extends State<DesktopSidebar> {
  // -1 = nothing hovered, 0-3 = nav items, 5 = footer
  int _hoveredIndex = -1;

  static const _sidebarBg = Color(0xFFF9F5F6);

  @override
  Widget build(BuildContext context) {
    final displayName = widget.profile.username != null
        ? '@${widget.profile.username}'
        : widget.profile.name;

    return Container(
      width: 220,
      color: _sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── App branding (also the window drag zone) ───────────────────
          DragToMoveArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                18,
                // On macOS the traffic-light buttons overlap the top-left of
                // the sidebar; push the branding below them.
                (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS)
                    ? _kMacTrafficLightClearance
                    : 22,
                18,
                18,
              ),
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
                  const Expanded(
                    child: Text(
                      'HelpHer',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  // Windows: render min / max / close since the system title
                  // bar is hidden.
                  if (!kIsWeb &&
                      defaultTargetPlatform == TargetPlatform.windows)
                    const _WindowsControls(),
                ],
              ),
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
            selected: widget.selectedIndex == 0,
            hovered: _hoveredIndex == 0,
            onTap: widget.onDestinationSelected,
            onHoverChanged: (v) => setState(() => _hoveredIndex = v ? 0 : -1),
          ),
          _SidebarItem(
            icon: Icons.people_outline,
            selectedIcon: Icons.people_rounded,
            label: 'Community',
            index: 1,
            selected: widget.selectedIndex == 1,
            hovered: _hoveredIndex == 1,
            onTap: widget.onDestinationSelected,
            onHoverChanged: (v) => setState(() => _hoveredIndex = v ? 1 : -1),
          ),
          _SidebarItem(
            icon: Icons.chat_bubble_outline_rounded,
            selectedIcon: Icons.chat_bubble_rounded,
            label: 'Chats',
            index: 2,
            selected: widget.selectedIndex == 2,
            hovered: _hoveredIndex == 2,
            onTap: widget.onDestinationSelected,
            onHoverChanged: (v) => setState(() => _hoveredIndex = v ? 2 : -1),
            badge: widget.unreadChatsCount,
          ),
          _SidebarItem(
            icon: Icons.shield_outlined,
            selectedIcon: Icons.shield_rounded,
            label: 'Safety',
            index: 3,
            selected: widget.selectedIndex == 3,
            hovered: _hoveredIndex == 3,
            onTap: widget.onDestinationSelected,
            onHoverChanged: (v) => setState(() => _hoveredIndex = v ? 3 : -1),
          ),
          const Spacer(),
          // ── User footer (also navigates to Profile) ────────────────────
          const _Divider(),
          _UserFooter(
            profile: widget.profile,
            displayName: displayName,
            selected: widget.selectedIndex == 4,
            hovered: _hoveredIndex == 5,
            onHoverChanged: (v) => setState(() => _hoveredIndex = v ? 5 : -1),
            onTap: () => widget.onDestinationSelected(4),
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

class _SidebarItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final int index;
  final bool selected;
  final bool hovered;
  final ValueChanged<int> onTap;
  final ValueChanged<bool> onHoverChanged;
  final int badge;

  const _SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.index,
    required this.selected,
    required this.hovered,
    required this.onTap,
    required this.onHoverChanged,
    this.badge = 0,
  });

  @override
  Widget build(BuildContext context) {
    final Color iconColor;
    final Color labelColor;
    final Color bg;

    if (selected) {
      iconColor = AppColors.brand;
      labelColor = AppColors.brand;
      bg = AppColors.brandLight;
    } else if (hovered) {
      iconColor = AppColors.text;
      labelColor = AppColors.text;
      bg = _kHoverBg;
    } else {
      iconColor = AppColors.text2;
      labelColor = AppColors.text2;
      bg = Colors.transparent;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: MouseRegion(
        onEnter: (_) => onHoverChanged(true),
        onExit: (_) => onHoverChanged(false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => onTap(index),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  selected ? selectedIcon : icon,
                  size: 20,
                  color: iconColor,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                      color: labelColor,
                    ),
                  ),
                ),
                if (badge > 0)
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
                      badge > 9 ? '9+' : '$badge',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        height: 1.0,
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

// ── Windows caption controls ──────────────────────────────────────────────────

class _WindowsControls extends StatelessWidget {
  const _WindowsControls();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WinBtn(
          icon: Icons.remove,
          tooltip: 'Minimise',
          onTap: () => windowManager.minimize(),
        ),
        _WinBtn(
          icon: Icons.crop_square_outlined,
          tooltip: 'Maximise',
          onTap: () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
        ),
        _WinBtn(
          icon: Icons.close,
          tooltip: 'Close',
          onTap: () => windowManager.close(),
          isClose: true,
        ),
      ],
    );
  }
}

class _WinBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool isClose;

  const _WinBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.isClose = false,
  });

  @override
  State<_WinBtn> createState() => _WinBtnState();
}

class _WinBtnState extends State<_WinBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = _hovered
        ? (widget.isClose
            ? const Color(0xFFE81123) // Windows close-button red
            : AppColors.brandLight)
        : Colors.transparent;
    final iconColor = (_hovered && widget.isClose) ? Colors.white : AppColors.text2;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 32,
            height: 32,
            color: bg,
            child: Icon(widget.icon, size: 14, color: iconColor),
          ),
        ),
      ),
    );
  }
}

// ── User footer ───────────────────────────────────────────────────────────────

class _UserFooter extends StatelessWidget {
  final UserProfileData profile;
  final String displayName;
  final bool selected;
  final bool hovered;
  final ValueChanged<bool> onHoverChanged;
  final VoidCallback onTap;

  const _UserFooter({
    required this.profile,
    required this.displayName,
    required this.selected,
    required this.hovered,
    required this.onHoverChanged,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected
        ? AppColors.brandLight
        : hovered
        ? _kHoverBg
        : Colors.transparent;

    return MouseRegion(
      onEnter: (_) => onHoverChanged(true),
      onExit: (_) => onHoverChanged(false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              SizedBox(
                width: 34,
                height: 34,
                child: ClipOval(
                  child: profile.photoUrl != null
                      ? Image.network(
                          profile.photoUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stack) =>
                              ProfileInitialsAvatar(
                            name: displayName,
                            fontSize: 13,
                          ),
                        )
                      : ProfileInitialsAvatar(
                          name: displayName,
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
                      displayName,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: selected ? AppColors.brand : AppColors.text,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (profile.username != null)
                      Text(
                        profile.name,
                        style: TextStyle(
                          fontSize: 11,
                          color: selected ? AppColors.brand : AppColors.text2,
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
