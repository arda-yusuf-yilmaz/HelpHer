import 'package:flutter/material.dart';
import '../app.dart';

class ProfileInitialsAvatar extends StatelessWidget {
  final String name;
  final double fontSize;

  const ProfileInitialsAvatar({super.key, required this.name, required this.fontSize});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.brandLight,
      child: Center(
        child: Text(
          name.isNotEmpty ? name.substring(0, 1).toUpperCase() : 'U',
          style: TextStyle(
            color: AppColors.brand,
            fontWeight: FontWeight.w700,
            fontSize: fontSize,
          ),
        ),
      ),
    );
  }
}
