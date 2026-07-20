import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/domain/surgery_trend.dart';
import 'package:cataract_surgery_note/src/features/analysis/analysis_screen.dart';
import 'package:cataract_surgery_note/src/features/records/record_detail_screen.dart';
import 'package:cataract_surgery_note/src/features/records/record_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoopVideoStorage implements VideoStorageRepository {
  @override
  Future<void> deleteVideo(String relativePath) async {}

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) async {}

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required String sourcePath,
    required String originalFileName,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<Never> resolveVideo(String relativePath) async {
    throw UnimplementedError();
  }
}

void main() {
  SurgeryAnalysisMeasurement measurement({
    required String id,
    required DateTime date,
    SurgicalStep step = SurgicalStep.totalSurgeryTime,
    int start = 0,
    int end = 60000,
    EyeSide eyeSide = EyeSide.right,
  }) {
    return SurgeryAnalysisMeasurement(
      recordId: id,
      surgeryDate: date,
      createdAt: date,
      eyeSide: eyeSide,
      step: step,
      startMilliseconds: start,
      endMilliseconds: end,
    );
  }

  Future<void> pumpAnalysis(
    WidgetTester tester,
    SurgeryAnalysisSnapshot snapshot, {
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          surgeryAnalysisProvider.overrideWith((ref) async => snapshot),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: const AnalysisScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('症例0件の空状態を表示する', (tester) async {
    await pumpAnalysis(
      tester,
      const SurgeryAnalysisSnapshot(recordCount: 0, measurements: []),
    );

    expect(find.text('まだ症例がありません'), findsOneWidget);
    expect(find.textContaining('症例を登録すると'), findsOneWidget);
  });

  testWidgets('1件では最新値と点だけを表示して追加記録を案内する', (tester) async {
    await pumpAnalysis(
      tester,
      SurgeryAnalysisSnapshot(
        recordCount: 1,
        measurements: [measurement(id: 'one', date: DateTime(2026, 7, 20))],
      ),
    );

    expect(find.text('総手術時間'), findsOneWidget);
    expect(find.text('最新'), findsOneWidget);
    expect(find.text('1:00'), findsOneWidget);
    expect(find.text('比較できる過去データがありません'), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('analysis-content')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(find.text('あと1件記録すると推移を確認できます'), findsOneWidget);
    expect(find.byKey(const Key('analysis-point-one')), findsOneWidget);
  });

  testWidgets('指標切り替えでグラフと比較サマリーを更新する', (tester) async {
    final firstDate = DateTime(2026, 7, 19);
    final secondDate = DateTime(2026, 7, 20);
    await pumpAnalysis(
      tester,
      SurgeryAnalysisSnapshot(
        recordCount: 2,
        measurements: [
          measurement(id: 'first', date: firstDate, end: 60000),
          measurement(id: 'second', date: secondDate, end: 50000),
          measurement(
            id: 'first',
            date: firstDate,
            step: SurgicalStep.capsulorhexis,
            end: 120000,
          ),
          measurement(
            id: 'second',
            date: secondDate,
            step: SurgicalStep.capsulorhexis,
            end: 90000,
          ),
        ],
      ),
    );

    expect(find.text('0:50'), findsOneWidget);
    expect(find.text('-0:10'), findsOneWidget);

    await tester.tap(find.byKey(const Key('analysis-metric-selector')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('テノン嚢下麻酔'), findsNothing);
    expect(find.text('デキサート結膜下注射'), findsNothing);
    await tester.tap(find.byKey(const Key('analysis-metric-capsulorhexis')));
    await tester.pumpAndSettle();

    expect(find.text('CCC'), findsOneWidget);
    expect(find.text('1:30'), findsOneWidget);
    expect(find.text('-0:30'), findsOneWidget);
  });

  testWidgets('点を選択すると完全な日付、左右、時間、詳細導線を表示する', (tester) async {
    await pumpAnalysis(
      tester,
      SurgeryAnalysisSnapshot(
        recordCount: 1,
        measurements: [
          measurement(
            id: 'selected',
            date: DateTime(2026, 7, 20),
            end: 65000,
            eyeSide: EyeSide.left,
          ),
        ],
      ),
    );

    await tester.tap(find.byKey(const Key('analysis-point-selected')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('analysis-content')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('analysis-selected-point')), findsOneWidget);
    expect(find.text('2026年7月20日 左眼'), findsOneWidget);
    expect(find.text('総手術時間：1分05秒'), findsOneWidget);
    expect(find.text('症例詳細を見る'), findsOneWidget);
  });

  testWidgets('大きな文字でも指標選択と主要情報へアクセスできる', (tester) async {
    await pumpAnalysis(
      tester,
      SurgeryAnalysisSnapshot(
        recordCount: 1,
        measurements: [
          measurement(id: 'large-text', date: DateTime(2026, 7, 20)),
        ],
      ),
      textScale: 2,
    );

    expect(find.byKey(const Key('analysis-metric-selector')), findsOneWidget);
    expect(find.text('最新'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('症例一覧AppBarの分析アイコンから分析画面を開く', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          surgeryRecordsProvider.overrideWith((ref) async => []),
          surgeryAnalysisProvider.overrideWith(
            (ref) async =>
                const SurgeryAnalysisSnapshot(recordCount: 0, measurements: []),
          ),
        ],
        child: const MaterialApp(home: RecordListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('分析'), findsOneWidget);
    await tester.tap(find.byTooltip('分析'));
    await tester.pumpAndSettle();

    expect(find.byType(AnalysisScreen), findsOneWidget);
    expect(find.widgetWithText(AppBar, '分析'), findsOneWidget);
  });

  testWidgets('選択点から既存の症例詳細画面へ遷移する', (tester) async {
    final database = AppDatabase.memory();
    addTearDown(database.close);
    late SurgeryRecord record;
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      record = await repository.createRecord(
        surgeryDate: DateTime(2026, 7, 20),
        eyeSide: EyeSide.right,
      );
      final total = await repository.ensureStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
      await repository.saveStepReview(
        total.copyWith(startMilliseconds: 0, endMilliseconds: 60000),
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWith((ref) => database)],
        child: const MaterialApp(home: AnalysisScreen()),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('analysis-point-${record.id}')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('analysis-content')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('症例詳細を見る'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RecordDetailScreen), findsOneWidget);
    expect(find.text('症例詳細'), findsOneWidget);

    await tester.pageBack();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AnalysisScreen), findsOneWidget);
    expect(find.byKey(const Key('analysis-selected-point')), findsOneWidget);
  });

  testWidgets('詳細画面で症例を削除すると選択点を解除して空状態を表示する', (tester) async {
    final database = AppDatabase.memory();
    addTearDown(database.close);
    late SurgeryRecord record;
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      record = await repository.createRecord(
        surgeryDate: DateTime(2026, 7, 20),
        eyeSide: EyeSide.right,
      );
      final total = await repository.ensureStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
      await repository.saveStepReview(
        total.copyWith(startMilliseconds: 0, endMilliseconds: 60000),
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoStorageRepositoryProvider.overrideWithValue(_NoopVideoStorage()),
        ],
        child: const MaterialApp(home: AnalysisScreen()),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('analysis-point-${record.id}')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('analysis-content')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('症例詳細を見る'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('症例を削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '削除'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AnalysisScreen), findsOneWidget);
    expect(find.byKey(const Key('analysis-selected-point')), findsNothing);
    expect(find.text('まだ症例がありません'), findsOneWidget);
  });
}
