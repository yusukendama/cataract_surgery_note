import 'dart:ui' show SemanticsAction;

import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/record_video_service.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/features/records/record_detail_screen.dart';
import 'package:cataract_surgery_note/src/features/records/record_list_screen.dart';
import 'package:cataract_surgery_note/src/features/records/record_month_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SurgeryRecord record({
    required String id,
    required DateTime surgeryDate,
    DateTime? createdAt,
    EyeSide eyeSide = EyeSide.right,
    ReviewStatus reviewStatus = ReviewStatus.draft,
    String? videoPath,
  }) {
    final creationDate = createdAt ?? surgeryDate;
    return SurgeryRecord(
      id: id,
      surgeryDate: surgeryDate,
      eyeSide: eyeSide,
      reviewStatus: reviewStatus,
      videoPath: videoPath,
      createdAt: creationDate,
      updatedAt: creationDate,
    );
  }

  Future<void> pumpList(
    WidgetTester tester,
    List<SurgeryRecord> records, {
    Size size = const Size(800, 600),
    SurgeryRecord? detailRecord,
    List<SurgeryRecordProgress>? progress,
    Map<String, RecordVideoState>? videoStates,
    bool progressFails = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          surgeryRecordsProvider.overrideWith((ref) async => records),
          surgeryRecordProgressProvider.overrideWith((ref) async {
            if (progressFails) {
              throw StateError('supporting data failure');
            }
            return progress ??
                records
                    .map(
                      (record) => SurgeryRecordProgress(
                        record: record,
                        completedStepCount: 0,
                        hasRunningStep: false,
                        totalSurgeryDuration: null,
                      ),
                    )
                    .toList();
          }),
          for (final record in records)
            recordVideoStateProvider(record.id).overrideWith(
              (ref) async =>
                  videoStates?[record.id] ??
                  const RecordVideoState(RecordVideoStateKind.unregistered),
            ),
          if (detailRecord != null) ...[
            surgeryRecordProvider(
              detailRecord.id,
            ).overrideWith((ref) async => detailRecord),
            recordVideoFileProvider(
              detailRecord.id,
            ).overrideWith((ref) async => null),
          ],
        ],
        child: const MaterialApp(home: RecordListScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('年月と症例日・作成日時の降順でグループ化する', () {
    final olderAugustRecord = record(
      id: 'august-older',
      surgeryDate: DateTime(2026, 8, 8),
      createdAt: DateTime(2026, 8, 8, 9),
    );
    final newerAugustRecord = record(
      id: 'august-newer',
      surgeryDate: DateTime(2026, 8, 8),
      createdAt: DateTime(2026, 8, 8, 10),
    );
    final groups = groupRecordsByMonth([
      record(id: 'july', surgeryDate: DateTime(2026, 7, 31)),
      olderAugustRecord,
      record(id: 'previous-year', surgeryDate: DateTime(2025, 12, 31)),
      newerAugustRecord,
    ]);

    expect(groups.map((group) => group.month.label), [
      '2026年8月',
      '2026年7月',
      '2025年12月',
    ]);
    expect(groups.first.records.map((item) => item.id), [
      'august-newer',
      'august-older',
    ]);
  });

  test('日付と作成日時が同じ症例は入力順を維持する', () {
    final date = DateTime(2026, 8, 8);
    final groups = groupRecordsByMonth([
      record(id: 'first', surgeryDate: date, createdAt: date),
      record(id: 'second', surgeryDate: date, createdAt: date),
    ]);

    expect(groups.single.records.map((item) => item.id), ['first', 'second']);
  });

  testWidgets('総件数と年月別件数を表示し、カードの日付から年を省略する', (tester) async {
    await pumpList(tester, [
      record(id: 'draft-without-video', surgeryDate: DateTime(2026, 8, 8)),
      record(
        id: 'reviewed-with-missing-video',
        surgeryDate: DateTime(2026, 8, 6),
        eyeSide: EyeSide.left,
        reviewStatus: ReviewStatus.reviewed,
        videoPath: 'videos/missing.mp4',
      ),
      record(id: 'july', surgeryDate: DateTime(2026, 7, 30)),
      record(id: 'previous-year', surgeryDate: DateTime(2025, 12, 31)),
    ], size: const Size(800, 1200));

    expect(find.text('総手術件数'), findsOneWidget);
    expect(find.text('4件'), findsOneWidget);
    expect(find.text('2026年8月　2件'), findsOneWidget);
    expect(find.text('2026年7月　1件'), findsOneWidget);
    expect(find.text('2025年12月　1件'), findsOneWidget);
    expect(find.text('8月8日（土）'), findsOneWidget);
    expect(find.text('8月6日（木）'), findsOneWidget);
    expect(find.text('右眼'), findsNWidgets(3));
    expect(find.text('左眼'), findsOneWidget);
    expect(find.textContaining('2026/'), findsNothing);
  });

  testWidgets('0件では件数カードを出さず用途説明と登録CTAを表示する', (tester) async {
    await pumpList(tester, []);

    expect(find.text('総手術件数'), findsNothing);
    expect(find.byKey(const Key('record-total-count')), findsNothing);
    expect(find.text('まだ症例がありません'), findsOneWidget);
    expect(find.text('最初の症例を登録'), findsOneWidget);
    expect(find.byType(SliverPersistentHeader), findsNothing);
  });

  testWidgets('工程進捗、独立した総手術時間、動画状態を表示する', (tester) async {
    final unstarted = record(
      id: 'unstarted',
      surgeryDate: DateTime(2026, 8, 8),
    );
    final partial = record(id: 'partial', surgeryDate: DateTime(2026, 8, 7));
    final complete = record(id: 'complete', surgeryDate: DateTime(2026, 8, 6));
    final runningOnly = record(
      id: 'running-only',
      surgeryDate: DateTime(2026, 8, 5),
    );
    await pumpList(
      tester,
      [unstarted, partial, complete, runningOnly],
      size: const Size(800, 1200),
      progress: [
        SurgeryRecordProgress(
          record: unstarted,
          completedStepCount: 0,
          hasRunningStep: false,
          totalSurgeryDuration: null,
        ),
        SurgeryRecordProgress(
          record: partial,
          completedStepCount: 4,
          hasRunningStep: true,
          totalSurgeryDuration: null,
        ),
        SurgeryRecordProgress(
          record: complete,
          completedStepCount: 10,
          hasRunningStep: false,
          totalSurgeryDuration: const Duration(minutes: 12, seconds: 34),
        ),
        SurgeryRecordProgress(
          record: runningOnly,
          completedStepCount: 0,
          hasRunningStep: true,
          totalSurgeryDuration: null,
        ),
      ],
      videoStates: const {
        'unstarted': RecordVideoState(RecordVideoStateKind.unregistered),
        'partial': RecordVideoState(RecordVideoStateKind.availableLegacy),
        'complete': RecordVideoState(RecordVideoStateKind.missing),
        'running-only': RecordVideoState(RecordVideoStateKind.checkFailed),
      },
    );

    expect(find.text('未記録'), findsOneWidget);
    expect(find.text('工程 4/10・計測中'), findsOneWidget);
    expect(find.text('工程 10/10'), findsOneWidget);
    expect(find.text('未記録・計測中'), findsOneWidget);
    expect(find.text('工程 0/10・計測中'), findsNothing);
    expect(find.text('総手術時間 12分34秒'), findsOneWidget);
    expect(find.text('動画未登録'), findsOneWidget);
    expect(find.text('旧形式動画あり'), findsOneWidget);
    expect(find.text('動画の実体なし'), findsOneWidget);
  });

  testWidgets('補助情報の取得失敗でも基本症例を表示し再読み込みを提供する', (tester) async {
    final item = record(id: 'visible', surgeryDate: DateTime(2026, 8, 8));
    await pumpList(tester, [item], progressFails: true);

    expect(find.text('8月8日（土）'), findsOneWidget);
    expect(find.text('工程情報を確認できません'), findsOneWidget);
    expect(find.text('工程情報を読み込めませんでした。'), findsOneWidget);
    expect(find.text('再読み込み'), findsOneWidget);
  });

  testWidgets('一覧の再読込で総件数と月見出しを即時更新する', (tester) async {
    var records = <SurgeryRecord>[];
    final container = ProviderContainer(
      overrides: [surgeryRecordsProvider.overrideWith((ref) async => records)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: RecordListScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-total-count')), findsNothing);
    expect(find.text('まだ症例がありません'), findsOneWidget);

    records = [record(id: 'added', surgeryDate: DateTime(2026, 8, 8))];
    container.invalidate(surgeryRecordsProvider);
    await tester.pumpAndSettle();

    expect(find.text('1件'), findsOneWidget);
    expect(find.text('2026年8月　1件'), findsOneWidget);

    records = [];
    container.invalidate(surgeryRecordsProvider);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('record-total-count')), findsNothing);
    expect(find.text('2026年8月　1件'), findsNothing);
  });

  testWidgets('月見出しを固定し、次の月へスクロールすると切り替える', (tester) async {
    final records = [
      for (var day = 20; day >= 9; day--)
        record(id: 'august-$day', surgeryDate: DateTime(2026, 8, day)),
      for (var day = 20; day >= 9; day--)
        record(id: 'july-$day', surgeryDate: DateTime(2026, 7, day)),
    ];
    await pumpList(tester, records, size: const Size(400, 500));
    final appBarBottom = tester.getBottomLeft(find.byType(AppBar)).dy;

    await tester.drag(
      find.byKey(const Key('record-list-scroll')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    final augustHeader = find
        .byKey(const Key('record-month-header-2026-8'))
        .hitTestable();
    expect(augustHeader, findsOneWidget);
    expect(tester.getTopLeft(augustHeader).dy, closeTo(appBarBottom, 1));
    expect(
      find.byKey(const Key('record-total-count')).hitTestable(),
      findsNothing,
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('record-list-item-july-9')),
      500,
    );
    await tester.pumpAndSettle();

    final julyHeader = find
        .byKey(const Key('record-month-header-2026-7'))
        .hitTestable();
    expect(julyHeader, findsOneWidget);
    expect(tester.getTopLeft(julyHeader).dy, closeTo(appBarBottom, 1));
  });

  testWidgets('症例カードのタップで既存の詳細画面へ遷移する', (tester) async {
    final item = record(id: 'tap-target', surgeryDate: DateTime(2026, 8, 8));
    await pumpList(tester, [item], detailRecord: item);

    await tester.tap(find.byKey(Key('record-list-item-${item.id}')));
    await tester.pumpAndSettle();

    expect(find.byType(RecordDetailScreen), findsOneWidget);
    expect(find.text('症例詳細'), findsOneWidget);
  });

  testWidgets('症例カードをVoiceOverのactivate操作で詳細へ開ける', (tester) async {
    final semantics = tester.ensureSemantics();
    final item = record(
      id: 'semantics-target',
      surgeryDate: DateTime(2026, 8, 8),
    );
    await pumpList(tester, [item], detailRecord: item);

    final node = tester.getSemantics(
      find.byKey(Key('record-list-semantics-${item.id}')),
    );
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(node.label, contains('8月8日（土）'));
    expect(node.label, contains('右眼'));

    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pumpAndSettle();

    expect(find.byType(RecordDetailScreen), findsOneWidget);
    semantics.dispose();
  });
}
