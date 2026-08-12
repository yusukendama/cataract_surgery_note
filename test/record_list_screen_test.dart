import 'package:cataract_surgery_note/src/data/providers.dart';
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
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          surgeryRecordsProvider.overrideWith((ref) async => records),
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
    ]);

    expect(find.text('総手術件数'), findsOneWidget);
    expect(find.text('4件'), findsOneWidget);
    expect(find.text('2026年8月　2件'), findsOneWidget);
    expect(find.text('2026年7月　1件'), findsOneWidget);
    expect(find.text('2025年12月　1件'), findsOneWidget);
    expect(find.text('8月8日 右眼'), findsOneWidget);
    expect(find.text('8月6日 左眼'), findsOneWidget);
    expect(find.textContaining('2026/'), findsNothing);
  });

  testWidgets('0件でも総件数と既存の空状態を表示する', (tester) async {
    await pumpList(tester, []);

    expect(find.text('総手術件数'), findsOneWidget);
    expect(find.text('0件'), findsOneWidget);
    expect(find.text('症例がありません'), findsOneWidget);
    expect(find.byType(SliverPersistentHeader), findsNothing);
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
    expect(find.text('0件'), findsOneWidget);

    records = [record(id: 'added', surgeryDate: DateTime(2026, 8, 8))];
    container.invalidate(surgeryRecordsProvider);
    await tester.pumpAndSettle();

    expect(find.text('1件'), findsOneWidget);
    expect(find.text('2026年8月　1件'), findsOneWidget);

    records = [];
    container.invalidate(surgeryRecordsProvider);
    await tester.pumpAndSettle();

    expect(find.text('0件'), findsOneWidget);
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

    await tester.drag(
      find.byKey(const Key('record-list-scroll')),
      const Offset(0, -800),
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
}
