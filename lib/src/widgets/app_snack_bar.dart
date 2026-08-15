import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

enum AppFeedbackTone { neutral, success, warning, failure }

void showAppSnackBar(
  BuildContext context, {
  required String message,
  AppFeedbackTone tone = AppFeedbackTone.neutral,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  assert(
    (actionLabel == null) == (onAction == null),
    'actionLabel and onAction must be provided together.',
  );
  final theme = Theme.of(context);
  final semantics = context.semanticColors;
  final (backgroundColor, foregroundColor, icon) = switch (tone) {
    AppFeedbackTone.neutral => (
      theme.colorScheme.inverseSurface,
      theme.colorScheme.onInverseSurface,
      Icons.info_outline,
    ),
    AppFeedbackTone.success => (
      semantics.success,
      semantics.onSuccess,
      Icons.check_circle_outline,
    ),
    AppFeedbackTone.warning => (
      semantics.warning,
      semantics.onWarning,
      Icons.warning_amber_rounded,
    ),
    AppFeedbackTone.failure => (
      theme.colorScheme.error,
      theme.colorScheme.onError,
      Icons.error_outline,
    ),
  };
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        backgroundColor: backgroundColor,
        content: Row(
          children: [
            Icon(icon, color: foregroundColor),
            const SizedBox(width: AppSpacing.small),
            Expanded(
              child: Text(message, style: TextStyle(color: foregroundColor)),
            ),
          ],
        ),
        action: onAction == null
            ? null
            : SnackBarAction(
                label: actionLabel!,
                textColor: foregroundColor,
                onPressed: onAction,
              ),
      ),
    );
}
