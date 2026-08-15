import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/data/providers.dart';
import 'src/features/records/record_list_screen.dart';
import 'src/theme/app_localization.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/app_tokens.dart';

void main() {
  runApp(const ProviderScope(child: MainApp()));
}

class MainApp extends ConsumerWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // App-level maintenance is deliberately separate from list/detail reads:
    // it verifies backup exclusion and safely reconciles unreferenced videos
    // without making basic record display wait for supporting storage work.
    ref.watch(videoStorageMaintenanceProvider);
    final platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final initialLaunchColor = platformBrightness == Brightness.dark
        ? AppColors.launchDark
        : AppColors.launchLight;
    return MaterialApp(
      title: '白内障執刀ノート',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: appSupportedLocales,
      localeResolutionCallback: resolveAppLocale,
      color: initialLaunchColor,
      builder: (context, child) {
        final launchColor = Theme.of(context).brightness == Brightness.dark
            ? AppColors.launchDark
            : AppColors.launchLight;
        return ColoredBox(color: launchColor, child: child ?? const SizedBox());
      },
      home: const RecordListScreen(),
    );
  }
}
