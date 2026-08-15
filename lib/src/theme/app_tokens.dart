import 'package:flutter/material.dart';

/// Shared design tokens used by more than one feature.
///
/// Values that describe a feature's geometry (for example chart dimensions or
/// a video's aspect ratio) should stay next to that feature instead of being
/// added here.
abstract final class AppColors {
  static const brand = Color(0xFF006D77);

  /// Fixed launch colors must match the iOS `LaunchBackground` color asset.
  static const launchLight = brand;
  static const launchDark = Color(0xFF003F45);

  /// Video is intentionally presented on the same dark surface in both themes.
  static const videoSurface = Color(0xFF090F10);
  static const onVideoSurface = Color(0xFFF1F7F7);
}

abstract final class AppSpacing {
  static const xSmall = 4.0;
  static const small = 8.0;
  static const medium = 16.0;
  static const large = 24.0;
  static const xLarge = 32.0;

  static const screen = EdgeInsets.all(medium);
  static const card = EdgeInsets.all(medium);
}

abstract final class AppRadii {
  static const small = 8.0;
  static const medium = 12.0;
  static const large = 20.0;
}

abstract final class AppMotion {
  static const standard = Duration(milliseconds: 200);
}

@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
  });

  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color onSuccessContainer;
  final Color warning;
  final Color onWarning;
  final Color warningContainer;
  final Color onWarningContainer;

  static const light = AppSemanticColors(
    success: Color(0xFF176B35),
    onSuccess: Colors.white,
    successContainer: Color(0xFFB6F2C7),
    onSuccessContainer: Color(0xFF00210B),
    warning: Color(0xFF765A00),
    onWarning: Colors.white,
    warningContainer: Color(0xFFFFE17B),
    onWarningContainer: Color(0xFF241A00),
  );

  static const dark = AppSemanticColors(
    success: Color(0xFF9BD5AA),
    onSuccess: Color(0xFF003918),
    successContainer: Color(0xFF005226),
    onSuccessContainer: Color(0xFFB6F2C7),
    warning: Color(0xFFE9C349),
    onWarning: Color(0xFF3D2F00),
    warningContainer: Color(0xFF584400),
    onWarningContainer: Color(0xFFFFE17B),
  );

  @override
  AppSemanticColors copyWith({
    Color? success,
    Color? onSuccess,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? onWarning,
    Color? warningContainer,
    Color? onWarningContainer,
  }) {
    return AppSemanticColors(
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
    );
  }

  @override
  AppSemanticColors lerp(
    covariant ThemeExtension<AppSemanticColors>? other,
    double t,
  ) {
    if (other is! AppSemanticColors) {
      return this;
    }
    return AppSemanticColors(
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      successContainer: Color.lerp(
        successContainer,
        other.successContainer,
        t,
      )!,
      onSuccessContainer: Color.lerp(
        onSuccessContainer,
        other.onSuccessContainer,
        t,
      )!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      warningContainer: Color.lerp(
        warningContainer,
        other.warningContainer,
        t,
      )!,
      onWarningContainer: Color.lerp(
        onWarningContainer,
        other.onWarningContainer,
        t,
      )!,
    );
  }
}

extension AppThemeContext on BuildContext {
  AppSemanticColors get semanticColors =>
      Theme.of(this).extension<AppSemanticColors>() ??
      (Theme.of(this).brightness == Brightness.dark
          ? AppSemanticColors.dark
          : AppSemanticColors.light);
}
