import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/data/app_database.dart';
import 'src/data/protected_storage.dart';
import 'src/data/providers.dart';
import 'src/features/records/record_list_screen.dart';
import 'src/theme/app_localization.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/app_tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProtectedAppBootstrap());
}

typedef ProtectedDatabaseOpener =
    Future<AppDatabase> Function({
      required String databasePath,
      required ProtectedDataRepository protectedDataRepository,
      required FileProtectionRepository fileProtectionRepository,
    });

Future<AppDatabase> _openProtectedDatabase({
  required String databasePath,
  required ProtectedDataRepository protectedDataRepository,
  required FileProtectionRepository fileProtectionRepository,
}) {
  return AppDatabase.openProtected(
    databasePath: databasePath,
    protectedDataRepository: protectedDataRepository,
    fileProtectionRepository: fileProtectionRepository,
  );
}

/// Keeps every database-backed provider out of the tree until iOS has applied
/// and read back NSFileProtectionComplete for the app-owned storage family.
/// A protected-data loss removes that ProviderScope and closes Drift; becoming
/// available again never resumes automatically and requires an explicit retry.
class ProtectedAppBootstrap extends StatefulWidget {
  const ProtectedAppBootstrap({
    this.protectedStorageRepository,
    this.databaseOpener = _openProtectedDatabase,
    super.key,
  });

  final ProtectedStorageRepository? protectedStorageRepository;
  final ProtectedDatabaseOpener databaseOpener;

  @override
  State<ProtectedAppBootstrap> createState() => _ProtectedAppBootstrapState();
}

enum _BootstrapState { loading, ready, locked, failed }

class _ProtectedAppBootstrapState extends State<ProtectedAppBootstrap> {
  late final ProtectedStorageRepository _protectedStorage;

  AppDatabase? _database;
  StreamSubscription<bool>? _availabilitySubscription;
  StreamSubscription<DatabaseProtectionFatalEvent>?
  _databaseProtectionSubscription;
  _BootstrapState _state = _BootstrapState.loading;
  bool _initializationActive = false;
  bool _deactivationActive = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _protectedStorage =
        widget.protectedStorageRepository ??
        MethodChannelProtectedStorageRepository();
    _availabilitySubscription = _protectedStorage.availabilityChanges.listen(
      _handleAvailabilityChanged,
      onError: (_) => _deactivate(_BootstrapState.failed),
    );
    unawaited(_initialize());
  }

  @override
  void dispose() {
    unawaited(_availabilitySubscription?.cancel());
    unawaited(_databaseProtectionSubscription?.cancel());
    unawaited(_database?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final database = _database;
    if (_state == _BootstrapState.ready && database != null) {
      return ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          protectedStorageRepositoryProvider.overrideWithValue(
            _protectedStorage,
          ),
        ],
        child: const MainApp(),
      );
    }
    return _ProtectedStorageStartupScreen(
      state: _state,
      onRetry: _state == _BootstrapState.loading || _deactivationActive
          ? null
          : _initialize,
    );
  }

  Future<void> _initialize() async {
    if (_initializationActive) {
      return;
    }
    _initializationActive = true;
    final generation = ++_generation;
    final staleDatabase = _database;
    final staleProtectionSubscription = _databaseProtectionSubscription;
    _database = null;
    _databaseProtectionSubscription = null;
    if (mounted) {
      setState(() => _state = _BootstrapState.loading);
    }
    await staleProtectionSubscription?.cancel();
    await staleDatabase?.close();
    try {
      final paths = await _protectedStorage.prepareAppStorage();
      final database = await widget.databaseOpener(
        databasePath: paths.databasePath,
        protectedDataRepository: _protectedStorage,
        fileProtectionRepository: _protectedStorage,
      );
      if (!mounted ||
          generation != _generation ||
          !await _protectedStorage.isAvailable) {
        await database.close();
        if (mounted && generation == _generation) {
          setState(() => _state = _BootstrapState.locked);
        }
        return;
      }
      final protectionSubscription = database.protectionFatalEvents.listen(
        (event) => _handleDatabaseProtectionFatal(
          database: database,
          generation: generation,
          event: event,
        ),
      );
      if (database.hasFatalProtectionFailure) {
        await protectionSubscription.cancel();
        await database.close();
        if (mounted && generation == _generation) {
          setState(() => _state = _BootstrapState.failed);
        }
        return;
      }
      setState(() {
        _database = database;
        _databaseProtectionSubscription = protectionSubscription;
        _state = _BootstrapState.ready;
      });
    } on ProtectedDataUnavailableException {
      if (mounted) {
        setState(() => _state = _BootstrapState.locked);
      }
    } on Object {
      if (mounted) {
        setState(() => _state = _BootstrapState.failed);
      }
    } finally {
      _initializationActive = false;
    }
  }

  void _handleAvailabilityChanged(bool isAvailable) {
    if (!isAvailable) {
      unawaited(_deactivate(_BootstrapState.locked));
    }
    // Availability returning to true deliberately does not reopen the DB.
  }

  void _handleDatabaseProtectionFatal({
    required AppDatabase database,
    required int generation,
    required DatabaseProtectionFatalEvent event,
  }) {
    // Let the already-committed caller receive its logical success before the
    // provider tree is removed and the underlying connection is closed.
    unawaited(
      Future<void>.delayed(Duration.zero, () async {
        if (!mounted ||
            generation != _generation ||
            !identical(_database, database)) {
          return;
        }
        await _deactivate(
          event.reason == DatabaseProtectionFatalReason.protectedDataUnavailable
              ? _BootstrapState.locked
              : _BootstrapState.failed,
        );
      }),
    );
  }

  Future<void> _deactivate(_BootstrapState nextState) async {
    final generation = ++_generation;
    final database = _database;
    final protectionSubscription = _databaseProtectionSubscription;
    _databaseProtectionSubscription = null;
    if (mounted) {
      setState(() {
        _database = null;
        _state = nextState;
        _deactivationActive = true;
      });
    } else {
      _database = null;
    }
    await protectionSubscription?.cancel();
    await database?.close();
    if (mounted && generation == _generation) {
      setState(() => _deactivationActive = false);
    }
  }
}

class _ProtectedStorageStartupScreen extends StatelessWidget {
  const _ProtectedStorageStartupScreen({
    required this.state,
    required this.onRetry,
  });

  final _BootstrapState state;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final locked = state == _BootstrapState.locked;
    return MaterialApp(
      title: '白内障執刀ノート',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: appSupportedLocales,
      localeResolutionCallback: resolveAppLocale,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    locked ? Icons.lock_outline : Icons.shield_outlined,
                    size: 48,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    state == _BootstrapState.loading
                        ? '保護されたデータを確認しています…'
                        : locked
                        ? '端末のロックを解除してください'
                        : '保護されたデータを利用できません',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (state != _BootstrapState.loading) ...[
                    const SizedBox(height: 12),
                    Text(
                      locked
                          ? '保護された動画と症例データを利用できません。端末のロックを解除して、もう一度お試しください。'
                          : '動画と症例データの安全な保護を確認できませんでした。もう一度お試しください。',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: onRetry == null
                          ? null
                          : () => unawaited(onRetry!()),
                      child: const Text('もう一度試す'),
                    ),
                  ] else ...[
                    const SizedBox(height: 24),
                    const CircularProgressIndicator(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
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
