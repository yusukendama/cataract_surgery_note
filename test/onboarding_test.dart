import 'package:cataract_surgery_note/src/data/onboarding_state_repository.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/features/onboarding/onboarding_entry_gate.dart';
import 'package:cataract_surgery_note/src/features/onboarding/onboarding_screen.dart';
import 'package:cataract_surgery_note/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakeOnboardingStateRepository
    implements OnboardingStateRepository {
  _FakeOnboardingStateRepository({
    this.completedVersion,
    this.readError,
    this.writeError,
  });

  int? completedVersion;
  Object? readError;
  Object? writeError;
  int readCount = 0;
  final List<int> writes = <int>[];

  @override
  Future<int?> readCompletedVersion() async {
    readCount++;
    if (readError case final error?) {
      throw error;
    }
    return completedVersion;
  }

  @override
  Future<void> writeCompletedVersion(int version) async {
    writes.add(version);
    if (writeError case final error?) {
      throw error;
    }
    completedVersion = version;
  }
}

void main() {
  Future<void> pumpGate(
    WidgetTester tester, {
    required _FakeOnboardingStateRepository repository,
    bool hasRecords = false,
    Object? recordExistsError,
    void Function()? onRecordExists,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          onboardingStateRepositoryProvider.overrideWithValue(repository),
          onboardingRecordExistsProvider.overrideWith((ref) async {
            onRecordExists?.call();
            if (recordExistsError case final error?) {
              throw error;
            }
            return hasRecords;
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          home: const OnboardingEntryGate(
            child: Scaffold(body: Center(child: Text('症例一覧'))),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('未完了かつ症例0件ではオンボーディングを表示する', (tester) async {
    final repository = _FakeOnboardingStateRepository();

    await pumpGate(tester, repository: repository);

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.text('手術を、振り返りにつなげる'), findsOneWidget);
    expect(repository.writes, isEmpty);
  });

  testWidgets('現行版を完了済みなら症例確認を行わず一覧を表示する', (tester) async {
    final repository = _FakeOnboardingStateRepository(
      completedVersion: currentOnboardingVersion,
    );
    var recordExistsCalls = 0;

    await pumpGate(
      tester,
      repository: repository,
      onRecordExists: () => recordExistsCalls++,
    );

    expect(find.text('症例一覧'), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(recordExistsCalls, 0);
    expect(repository.writes, isEmpty);
  });

  testWidgets('既存症例があれば一覧を先に表示して完了版を補完する', (tester) async {
    final repository = _FakeOnboardingStateRepository();

    await pumpGate(tester, repository: repository, hasRecords: true);

    expect(find.text('症例一覧'), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(repository.writes, [currentOnboardingVersion]);
  });

  testWidgets('完了状態の読込み失敗では症例確認を行わず一覧へ進む', (tester) async {
    final repository = _FakeOnboardingStateRepository(
      readError: StateError('preference read failed'),
    );
    var recordExistsCalls = 0;

    await pumpGate(
      tester,
      repository: repository,
      onRecordExists: () => recordExistsCalls++,
    );

    expect(find.text('症例一覧'), findsOneWidget);
    expect(recordExistsCalls, 0);
    expect(repository.writes, isEmpty);
  });

  testWidgets('症例存在判定の失敗ではオンボーディングで遮断しない', (tester) async {
    final repository = _FakeOnboardingStateRepository();

    await pumpGate(
      tester,
      repository: repository,
      recordExistsError: StateError('record query failed'),
    );

    expect(find.text('症例一覧'), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(repository.writes, isEmpty);
  });

  testWidgets('3ページを完了すると版番号を1回保存して一覧へ進む', (tester) async {
    final repository = _FakeOnboardingStateRepository();
    await pumpGate(tester, repository: repository);

    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('動画を選んで症例を記録'), findsOneWidget);

    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('医療情報を安全に取り扱う'), findsOneWidget);

    await tester.tap(find.byKey(const Key('onboarding-finish')));
    await tester.tap(find.byKey(const Key('onboarding-finish')));
    await tester.pumpAndSettle();

    expect(repository.writes, [currentOnboardingVersion]);
    expect(find.text('症例一覧'), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
  });

  testWidgets('スキップは最終ページへ移動するだけで保存せず戻る先は2ページ目', (tester) async {
    final repository = _FakeOnboardingStateRepository();
    await pumpGate(tester, repository: repository);

    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pumpAndSettle();

    expect(find.text('医療情報を安全に取り扱う'), findsOneWidget);
    expect(repository.writes, isEmpty);

    await tester.tap(find.byKey(const Key('onboarding-back')));
    await tester.pumpAndSettle();

    expect(find.text('動画を選んで症例を記録'), findsOneWidget);
    expect(repository.writes, isEmpty);
  });

  testWidgets('左右スワイプと初回表示のシステム戻るでページ移動できる', (tester) async {
    final repository = _FakeOnboardingStateRepository();
    await pumpGate(tester, repository: repository);

    await tester.drag(
      find.byKey(const Key('onboarding-pages')),
      const Offset(-800, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('動画を選んで症例を記録'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('手術を、振り返りにつなげる'), findsOneWidget);
    expect(repository.writes, isEmpty);
  });

  testWidgets('完了版の保存に失敗してもそのセッションでは一覧へ進む', (tester) async {
    final repository = _FakeOnboardingStateRepository(
      writeError: StateError('preference write failed'),
    );
    await pumpGate(tester, repository: repository);

    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding-finish')));
    await tester.pumpAndSettle();

    expect(repository.writes, [currentOnboardingVersion]);
    expect(repository.completedVersion, isNull);
    expect(find.text('症例一覧'), findsOneWidget);
  });

  testWidgets('ページ位置をSemanticsで通知する', (tester) async {
    final semantics = tester.ensureSemantics();
    final repository = _FakeOnboardingStateRepository();
    await pumpGate(tester, repository: repository);

    expect(
      tester
          .getSemantics(find.byKey(const Key('onboarding-page-indicator')))
          .label,
      '3ページ中1ページ目',
    );

    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();

    expect(
      tester
          .getSemantics(find.byKey(const Key('onboarding-page-indicator')))
          .label,
      '3ページ中2ページ目',
    );
    semantics.dispose();
  });

  testWidgets('狭い画面とテキスト倍率2.0でもoverflowしない', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) {
          return MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          );
        },
        home: OnboardingScreen.initial(onComplete: () async {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('onboarding-next')), findsOneWidget);

    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('onboarding-finish')), findsOneWidget);
  });

  testWidgets('再表示モードはシステム戻るで全体を閉じる', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: FilledButton(
                onPressed: () => openOnboardingGuide(context),
                child: const Text('使い方を開く'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('使い方を開く'));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingScreen), findsNothing);
    expect(find.text('使い方を開く'), findsOneWidget);
  });
}
