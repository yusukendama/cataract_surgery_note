import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// Theme-independent dark surface for video and its playback controls.
class VideoSurface extends StatelessWidget {
  const VideoSurface({
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = const BorderRadius.all(
      Radius.circular(AppRadii.medium),
    ),
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle.merge(
      style: const TextStyle(color: AppColors.onVideoSurface),
      child: IconTheme.merge(
        data: const IconThemeData(color: AppColors.onVideoSurface),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: ColoredBox(
            color: AppColors.videoSurface,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}
