import 'dart:async';

import 'package:cataract_surgery_note/main.dart';
import 'package:cataract_surgery_note/src/data/onboarding_state_repository.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/theme/app_localization.dart';
import 'package:cataract_surgery_note/src/theme/app_theme.dart';
import 'package:cataract_surgery_note/src/theme/app_tokens.dart';
import 'package:cataract_surgery_note/src/widgets/video_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('light and dark themes expose the shared design tokens', () {
    final light = AppTheme.light;
    final dark = AppTheme.dark;

    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
    expect(light.colorScheme.primary, AppColors.brand);
    expect(light.extension<AppSemanticColors>(), AppSemanticColors.light);
    expect(dark.extension<AppSemanticColors>(), AppSemanticColors.dark);
    expect(light.snackBarTheme.behavior, SnackBarBehavior.floating);
    expect(dark.snackBarTheme.behavior, SnackBarBehavior.floating);
  });

  test('fixed and semantic foreground pairs meet normal-text contrast', () {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      final scheme = theme.colorScheme;
      final semantic = theme.extension<AppSemanticColors>()!;
      expect(
        _contrast(scheme.primary, scheme.onPrimary),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(scheme.surface, scheme.onSurface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(scheme.surface, scheme.onSurfaceVariant),
        greaterThanOrEqualTo(4.5),
        reason: 'Graph labels must meet normal-text contrast.',
      );
      expect(
        _contrast(scheme.surface, scheme.primary),
        greaterThanOrEqualTo(3),
        reason: 'Graph lines and point rings must meet component contrast.',
      );
      expect(
        _contrast(scheme.error, scheme.onError),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(semantic.success, semantic.onSuccess),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(semantic.warning, semantic.onWarning),
        greaterThanOrEqualTo(4.5),
      );
    }
    expect(
      _contrast(AppColors.videoSurface, AppColors.onVideoSurface),
      greaterThanOrEqualTo(4.5),
    );
  });

  test('trend chart paint pairs meet text and component contrast', () {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      final scheme = theme.colorScheme;

      // Axis labels are normal-sized text painted directly on the surface.
      expect(
        _contrast(scheme.surface, scheme.onSurfaceVariant),
        greaterThanOrEqualTo(4.5),
      );

      // Grid, line, and point rings are meaningful non-text graph elements.
      expect(
        _contrast(scheme.surface, scheme.outline),
        greaterThanOrEqualTo(3),
      );
      expect(
        _contrast(scheme.surface, scheme.primary),
        greaterThanOrEqualTo(3),
      );

      // The selected point fill is fully enclosed by its primary ring, so its
      // adjacent paint pair is primaryContainer against primary. Unselected
      // points use the surface fill enclosed by the same primary ring.
      expect(
        _contrast(scheme.primaryContainer, scheme.primary),
        greaterThanOrEqualTo(3),
      );
    }
  });

  test('locale resolution always falls back to Japanese', () {
    expect(
      resolveAppLocale(const Locale('en'), appSupportedLocales),
      const Locale('ja'),
    );
    expect(resolveAppLocale(null, appSupportedLocales), const Locale('ja'));
  });

  testWidgets('Material localization and dark video surface are available', (
    tester,
  ) async {
    late Locale locale;
    late MaterialLocalizations materialLocalizations;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: resolveAppLocale(const Locale('en'), appSupportedLocales),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Builder(
          builder: (context) {
            locale = Localizations.localeOf(context);
            materialLocalizations = MaterialLocalizations.of(context);
            return const Scaffold(body: VideoSurface(child: Text('動画')));
          },
        ),
      ),
    );

    expect(locale.languageCode, 'ja');
    expect(materialLocalizations.cancelButtonLabel, 'キャンセル');
    final coloredBox = tester.widget<ColoredBox>(find.byType(ColoredBox).last);
    expect(coloredBox.color, AppColors.videoSurface);
  });

  testWidgets('system appearance changes theme without replacing input state', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(const _SystemThemeStateProbe());
    await tester.enterText(find.byKey(const Key('stateful-input')), '未保存メモ');
    await tester.tap(find.byKey(const Key('stateful-switch')));
    await tester.pump();

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();

    final probeContext = tester.element(find.byKey(const Key('theme-probe')));
    expect(Theme.of(probeContext).brightness, Brightness.dark);
    expect(find.text('未保存メモ'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('English device still opens a Japanese Material date picker', (
    tester,
  ) async {
    tester.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        localeResolutionCallback: resolveAppLocale,
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showDatePicker(
                context: context,
                initialDate: DateTime(2026, 8, 15),
                firstDate: DateTime(2020),
                lastDate: DateTime(2030),
              ),
              child: const Text('日付を選ぶ'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('日付を選ぶ'));
    await tester.pumpAndSettle();

    expect(
      Localizations.localeOf(
        tester.element(find.byType(DatePickerDialog)),
      ).languageCode,
      'ja',
    );
    expect(find.text('キャンセル'), findsOneWidget);
  });

  testWidgets('app bootstrap maintenance never blocks the record list', (
    tester,
  ) async {
    final pendingMaintenance = Completer<VideoStorageMaintenanceReport?>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          onboardingStateRepositoryProvider.overrideWithValue(
            const _CompletedOnboardingStateRepository(),
          ),
          videoStorageMaintenanceProvider.overrideWith(
            (ref) => pendingMaintenance.future,
          ),
          surgeryRecordsProvider.overrideWith((ref) async => []),
        ],
        child: const MainApp(),
      ),
    );
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
    expect(app.supportedLocales, appSupportedLocales);
    expect(find.text('まだ症例がありません'), findsOneWidget);
  });
}

final class _CompletedOnboardingStateRepository
    implements OnboardingStateRepository {
  const _CompletedOnboardingStateRepository();

  @override
  Future<int?> readCompletedVersion() async => currentOnboardingVersion;

  @override
  Future<void> writeCompletedVersion(int version) async {}
}

class _SystemThemeStateProbe extends StatefulWidget {
  const _SystemThemeStateProbe();

  @override
  State<_SystemThemeStateProbe> createState() => _SystemThemeStateProbeState();
}

class _SystemThemeStateProbeState extends State<_SystemThemeStateProbe> {
  bool _selected = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      home: Scaffold(
        key: const Key('theme-probe'),
        body: Column(
          children: [
            const TextField(key: Key('stateful-input')),
            Switch(
              key: const Key('stateful-switch'),
              value: _selected,
              onChanged: (value) => setState(() => _selected = value),
            ),
          ],
        ),
      ),
    );
  }
}

double _contrast(Color first, Color second) {
  final lighter = first.computeLuminance() > second.computeLuminance()
      ? first
      : second;
  final darker = identical(lighter, first) ? second : first;
  return (lighter.computeLuminance() + 0.05) /
      (darker.computeLuminance() + 0.05);
}
