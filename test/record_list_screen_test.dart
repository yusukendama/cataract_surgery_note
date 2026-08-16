import 'dart:async';
import 'dart:ui' show SemanticsAction, Tristate;

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

typedef _VideoStateLoader = Future<RecordVideoState> Function();
typedef _ProgressLoader = Future<List<SurgeryRecordProgress>> Function();

void main() {
  SurgeryRecord record({
    required String id,
    required DateTime surgeryDate,
    DateTime? createdAt,
    EyeSide eyeSide = EyeSide.right,
    ReviewStatus reviewStatus = ReviewStatus.draft,
    int? reviewSchemaVersion = 1,
    String? videoPath = 'videos/record/video.mp4',
  }) {
    final creationDate = createdAt ?? surgeryDate;
    return SurgeryRecord(
      id: id,
      surgeryDate: surgeryDate,
      eyeSide: eyeSide,
      reviewStatus: reviewStatus,
      reviewSchemaVersion: reviewSchemaVersion,
      videoPath: videoPath,
      createdAt: creationDate,
      updatedAt: creationDate,
    );
  }

  SurgeryRecordProgress progressFor(
    SurgeryRecord item, {
    CaseTimingReviewStatus? timingReviewStatus,
    Duration? totalDuration = const Duration(minutes: 10),
    int completedStepCount = 10,
    bool hasRunningStep = false,
  }) {
    return SurgeryRecordProgress(
      record: item,
      completedStepCount: completedStepCount,
      hasRunningStep: hasRunningStep,
      totalSurgeryDuration: totalDuration,
      timingReviewStatus:
          timingReviewStatus ??
          (item.reviewSchemaVersion == 1
              ? CaseTimingReviewStatus.completed
              : null),
    );
  }

  void configureView(WidgetTester tester, {Size size = const Size(800, 600)}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<ProviderContainer> pumpList(
    WidgetTester tester,
    List<SurgeryRecord> records, {
    Size size = const Size(800, 600),
    SurgeryRecord? detailRecord,
    List<SurgeryRecordProgress>? progress,
    _ProgressLoader? progressLoader,
    Map<String, RecordVideoState> videoStates = const {},
    Map<String, _VideoStateLoader> videoLoaders = const {},
    bool settle = true,
  }) async {
    configureView(tester, size: size);
    final container = ProviderContainer(
      overrides: [
        surgeryRecordsProvider.overrideWith((ref) async => records),
        surgeryRecordProgressProvider.overrideWith((ref) {
          final loader = progressLoader;
          if (loader != null) {
            return loader();
          }
          return Future.value(
            progress ?? records.map(progressFor).toList(growable: false),
          );
        }),
        for (final item in records)
          recordVideoStateByReferenceProvider(
            RecordVideoStateRequest(item),
          ).overrideWith((ref) {
            final loader = videoLoaders[item.id];
            if (loader != null) {
              return loader();
            }
            return Future.value(
              videoStates[item.id] ??
                  const RecordVideoState(RecordVideoStateKind.availableManaged),
            );
          }),
        if (detailRecord != null) ...[
          surgeryRecordProvider(
            detailRecord.id,
          ).overrideWith((ref) async => detailRecord),
          recordVideoFileProvider(
            detailRecord.id,
          ).overrideWith((ref) async => null),
        ],
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: RecordListScreen()),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
    return container;
  }

  test('手術日の年月と作成日時で降順にし、IDを最終tie-breakerにする', () {
    final sameDate = DateTime(2026, 8, 8);
    final source = [
      record(id: 'z-record', surgeryDate: sameDate, createdAt: sameDate),
      record(id: 'july', surgeryDate: DateTime(2026, 7, 31)),
      record(id: 'a-record', surgeryDate: sameDate, createdAt: sameDate),
      record(id: 'previous-year', surgeryDate: DateTime(2025, 12, 31)),
      record(
        id: 'newest',
        surgeryDate: DateTime(2026, 8, 9),
        createdAt: DateTime(2026, 8, 9),
      ),
    ];
    final groups = groupRecordsByMonth(source);
    final reversedGroups = groupRecordsByMonth(source.reversed);

    expect(groups.map((group) => group.month.label), [
      '2026年8月',
      '2026年7月',
      '2025年12月',
    ]);
    expect(groups.first.records.map((item) => item.id), [
      'newest',
      'a-record',
      'z-record',
    ]);
    expect(
      reversedGroups.expand((group) => group.records).map((item) => item.id),
      groups.expand((group) => group.records).map((item) => item.id),
    );
  });

  test('UTCの手術日もローカル変換せずyearとmonthを使う', () {
    final groups = groupRecordsByMonth([
      record(id: 'utc-august', surgeryDate: DateTime.utc(2026, 8, 31, 16)),
      record(id: 'utc-september', surgeryDate: DateTime.utc(2026, 9, 1)),
    ]);

    expect(groups.map((group) => group.month.label), ['2026年9月', '2026年8月']);
    expect(groups.last.records.single.id, 'utc-august');
  });

  testWidgets('0件では件数とフィルターを出さず登録CTAを表示する', (tester) async {
    await pumpList(tester, const []);

    expect(find.byKey(const Key('record-total-count')), findsNothing);
    expect(
      find.byKey(const Key('record-needs-attention-filter')),
      findsNothing,
    );
    expect(find.text('まだ症例がありません'), findsOneWidget);
    expect(find.text('最初の症例を登録'), findsOneWidget);
    expect(find.byType(SliverPersistentHeader), findsNothing);
  });

  testWidgets('工程数と正常動画を除き、レビュー3状態と総時間を表示する', (tester) async {
    final notStarted = record(
      id: 'not-started',
      surgeryDate: DateTime(2026, 8, 8),
    );
    final inProgress = record(
      id: 'in-progress',
      surgeryDate: DateTime(2026, 8, 7),
    );
    final completed = record(
      id: 'completed',
      surgeryDate: DateTime(2026, 8, 6),
    );
    final legacy = record(
      id: 'legacy',
      surgeryDate: DateTime(2026, 8, 5),
      reviewSchemaVersion: null,
    );

    await pumpList(
      tester,
      [notStarted, inProgress, completed, legacy],
      size: const Size(800, 1200),
      progress: [
        progressFor(
          notStarted,
          timingReviewStatus: CaseTimingReviewStatus.notStarted,
          totalDuration: null,
          completedStepCount: 0,
        ),
        progressFor(
          inProgress,
          timingReviewStatus: CaseTimingReviewStatus.inProgress,
          totalDuration: null,
          completedStepCount: 4,
          hasRunningStep: true,
        ),
        progressFor(
          completed,
          totalDuration: const Duration(minutes: 12, seconds: 34),
        ),
        progressFor(
          legacy,
          totalDuration: const Duration(minutes: 9, seconds: 2),
        ),
      ],
      videoStates: const {
        'not-started': RecordVideoState(RecordVideoStateKind.availableManaged),
        'in-progress': RecordVideoState(RecordVideoStateKind.availableLegacy),
        'completed': RecordVideoState(RecordVideoStateKind.availableManaged),
        'legacy': RecordVideoState(RecordVideoStateKind.availableLegacy),
      },
    );

    expect(find.text('未レビュー'), findsOneWidget);
    expect(find.text('レビュー中'), findsOneWidget);
    expect(find.text('レビュー完了'), findsNothing);
    expect(find.text('総手術時間 未登録'), findsNWidgets(2));
    expect(find.text('総手術時間 12分34秒'), findsOneWidget);
    expect(find.text('総手術時間 9分02秒'), findsOneWidget);
    expect(find.textContaining('/10'), findsNothing);
    expect(find.text('動画あり'), findsNothing);
    expect(find.text('旧形式動画あり'), findsNothing);
    expect(find.byIcon(Icons.fact_check_outlined), findsNothing);
  });

  testWidgets('動画4問題状態だけを表示し、確認失敗を再試行できる', (tester) async {
    final records = <SurgeryRecord>[
      record(
        id: 'unregistered',
        surgeryDate: DateTime(2026, 8, 8),
        videoPath: null,
      ),
      record(id: 'missing', surgeryDate: DateTime(2026, 8, 7)),
      record(id: 'invalid', surgeryDate: DateTime(2026, 8, 6)),
      record(id: 'check-failed', surgeryDate: DateTime(2026, 8, 5)),
      record(id: 'normal', surgeryDate: DateTime(2026, 8, 4)),
    ];
    var failedStateLoadCount = 0;

    await pumpList(
      tester,
      records,
      size: const Size(800, 1200),
      videoStates: const {
        'unregistered': RecordVideoState(RecordVideoStateKind.unregistered),
        'missing': RecordVideoState(RecordVideoStateKind.missing),
        'invalid': RecordVideoState(RecordVideoStateKind.invalidReference),
        'normal': RecordVideoState(RecordVideoStateKind.availableManaged),
      },
      videoLoaders: {
        'check-failed': () async {
          failedStateLoadCount++;
          return RecordVideoState(
            failedStateLoadCount == 1
                ? RecordVideoStateKind.checkFailed
                : RecordVideoStateKind.availableManaged,
          );
        },
      },
    );

    expect(find.text('動画なし'), findsOneWidget);
    expect(find.text('動画を開けません'), findsNWidgets(2));
    expect(find.text('動画状態を確認できません'), findsOneWidget);
    expect(find.text('動画あり'), findsNothing);
    expect(failedStateLoadCount, 1);

    await tester.tap(
      find.byKey(const Key('record-video-state-retry-check-failed')),
    );
    await tester.pumpAndSettle();

    expect(failedStateLoadCount, 2);
    expect(find.text('動画状態を確認できません'), findsNothing);
  });

  testWidgets('同一症例のレビュー中と動画問題を複数Chipで表示する', (tester) async {
    final item = record(
      id: 'multiple-issues',
      surgeryDate: DateTime(2026, 8, 8),
    );

    await pumpList(
      tester,
      [item],
      progress: [
        progressFor(
          item,
          timingReviewStatus: CaseTimingReviewStatus.inProgress,
        ),
      ],
      videoStates: const {
        'multiple-issues': RecordVideoState(RecordVideoStateKind.checkFailed),
      },
    );

    final card = find.byKey(const Key('record-list-item-multiple-issues'));
    expect(
      find.descendant(of: card, matching: find.text('レビュー中')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('動画状態を確認できません')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.widgetWithText(Chip, 'レビュー中')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.widgetWithText(ActionChip, '動画状態を確認できません'),
      ),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.text('レビュー中')).dy,
      closeTo(tester.getTopLeft(find.text('動画状態を確認できません')).dy, 1),
    );
  });

  testWidgets('動画ProviderのAsyncErrorを要対応に含め再試行で復旧する', (tester) async {
    final item = record(
      id: 'provider-error',
      surgeryDate: DateTime(2026, 8, 8),
    );
    var loadCount = 0;
    await pumpList(
      tester,
      [item],
      videoLoaders: {
        'provider-error': () async {
          loadCount++;
          if (loadCount == 1) {
            throw StateError('controlled video provider failure');
          }
          return const RecordVideoState(RecordVideoStateKind.availableManaged);
        },
      },
    );

    expect(find.text('動画状態を確認できません'), findsOneWidget);
    expect(loadCount, 1);

    await tester.tap(find.byKey(const Key('record-needs-attention-filter')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('record-list-item-provider-error')),
      findsOneWidget,
    );
    expect(find.text('要対応の症例はありません'), findsNothing);

    await tester.tap(
      find.byKey(const Key('record-video-state-retry-provider-error')),
    );
    await tester.pumpAndSettle();

    expect(loadCount, 2);
    expect(find.text('動画状態を確認できません'), findsNothing);
    expect(
      find.byKey(const Key('record-list-item-provider-error')),
      findsNothing,
    );
    expect(find.text('要対応の症例はありません'), findsOneWidget);
  });

  testWidgets('最新月だけを初期展開し、月を独立して開閉できる', (tester) async {
    final august = record(id: 'august', surgeryDate: DateTime(2026, 8, 8));
    final july = record(id: 'july', surgeryDate: DateTime(2026, 7, 8));
    final june = record(id: 'june', surgeryDate: DateTime(2026, 6, 8));
    await pumpList(tester, [june, august, july], size: const Size(800, 1200));

    expect(find.byKey(const Key('record-list-item-august')), findsOneWidget);
    expect(find.byKey(const Key('record-list-item-july')), findsNothing);
    expect(find.byKey(const Key('record-list-item-june')), findsNothing);

    await tester.tap(find.byKey(const Key('record-month-header-2026-7')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-list-item-august')), findsOneWidget);
    expect(find.byKey(const Key('record-list-item-july')), findsOneWidget);

    await tester.tap(find.byKey(const Key('record-month-header-2026-8')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-list-item-august')), findsNothing);
    expect(find.byKey(const Key('record-list-item-july')), findsOneWidget);

    await tester.tap(find.byKey(const Key('record-month-header-2026-6')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-list-item-july')), findsOneWidget);
    expect(find.byKey(const Key('record-list-item-june')), findsOneWidget);
  });

  testWidgets('再描画で展開状態を保ち、新しい最新月だけを追加展開する', (tester) async {
    configureView(tester, size: const Size(800, 1200));
    final august = record(id: 'august', surgeryDate: DateTime(2026, 8, 8));
    final july = record(id: 'july', surgeryDate: DateTime(2026, 7, 8));
    final september = record(
      id: 'september',
      surgeryDate: DateTime(2026, 9, 8),
    );
    var currentRecords = <SurgeryRecord>[august, july];
    final container = ProviderContainer(
      overrides: [
        surgeryRecordsProvider.overrideWith((ref) async => currentRecords),
        surgeryRecordProgressProvider.overrideWith(
          (ref) async =>
              currentRecords.map(progressFor).toList(growable: false),
        ),
        for (final item in <SurgeryRecord>[august, july, september])
          recordVideoStateByReferenceProvider(
            RecordVideoStateRequest(item),
          ).overrideWith(
            (ref) async =>
                const RecordVideoState(RecordVideoStateKind.availableManaged),
          ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: RecordListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('record-month-header-2026-7')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-list-item-july')), findsOneWidget);

    container.invalidate(surgeryRecordProgressProvider);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-list-item-august')), findsOneWidget);
    expect(find.byKey(const Key('record-list-item-july')), findsOneWidget);

    currentRecords = [september, august, july];
    container.invalidate(surgeryRecordsProvider);
    container.invalidate(surgeryRecordProgressProvider);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('record-list-item-september')), findsOneWidget);
    expect(find.byKey(const Key('record-list-item-august')), findsOneWidget);
    expect(find.byKey(const Key('record-list-item-july')), findsOneWidget);
  });

  testWidgets('一覧の一時的な再取得失敗でもフィルターと月展開を保持する', (tester) async {
    configureView(tester, size: const Size(800, 1200));
    final august = record(id: 'august', surgeryDate: DateTime(2026, 8, 8));
    final july = record(id: 'july', surgeryDate: DateTime(2026, 7, 8));
    var failRecordRefresh = false;
    var recordLoadCount = 0;
    final container = ProviderContainer(
      overrides: [
        surgeryRecordsProvider.overrideWith((ref) async {
          recordLoadCount++;
          if (failRecordRefresh) {
            throw StateError('controlled record refresh failure');
          }
          return <SurgeryRecord>[august, july];
        }),
        surgeryRecordProgressProvider.overrideWith(
          (ref) async => <SurgeryRecordProgress>[
            progressFor(
              august,
              timingReviewStatus: CaseTimingReviewStatus.inProgress,
            ),
            progressFor(july),
          ],
        ),
        for (final item in <SurgeryRecord>[august, july])
          recordVideoStateByReferenceProvider(
            RecordVideoStateRequest(item),
          ).overrideWith(
            (ref) async =>
                const RecordVideoState(RecordVideoStateKind.availableManaged),
          ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: RecordListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('record-month-header-2026-7')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('record-needs-attention-filter')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilterChip>(
            find.byKey(const Key('record-needs-attention-filter')),
          )
          .selected,
      isTrue,
    );

    failRecordRefresh = true;
    container.invalidate(surgeryRecordsProvider);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('record-list-load-warning')), findsOneWidget);
    expect(find.byKey(const Key('record-list-item-august')), findsOneWidget);
    expect(
      tester
          .widget<FilterChip>(
            find.byKey(const Key('record-needs-attention-filter')),
          )
          .selected,
      isTrue,
    );

    failRecordRefresh = false;
    await tester.tap(find.text('再読み込み'));
    await tester.pumpAndSettle();
    expect(recordLoadCount, 3);
    expect(find.byKey(const Key('record-list-load-warning')), findsNothing);

    await tester.tap(find.byKey(const Key('record-needs-attention-filter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-list-item-july')), findsOneWidget);
  });

  testWidgets('要対応のみは状態を統合し、旧schemaをレビュー理由では含めない', (tester) async {
    final completed = record(
      id: 'completed',
      surgeryDate: DateTime(2026, 8, 8),
    );
    final reviewing = record(
      id: 'reviewing',
      surgeryDate: DateTime(2026, 8, 7),
    );
    final legacyNormal = record(
      id: 'legacy-normal',
      surgeryDate: DateTime(2026, 7, 8),
      reviewSchemaVersion: null,
    );
    final legacyMissing = record(
      id: 'legacy-missing',
      surgeryDate: DateTime(2026, 7, 7),
      reviewSchemaVersion: null,
    );
    final notStarted = record(
      id: 'not-started',
      surgeryDate: DateTime(2026, 6, 8),
    );

    await pumpList(
      tester,
      [completed, reviewing, legacyNormal, legacyMissing, notStarted],
      size: const Size(800, 1200),
      progress: [
        progressFor(completed),
        progressFor(
          reviewing,
          timingReviewStatus: CaseTimingReviewStatus.inProgress,
        ),
        progressFor(legacyNormal),
        progressFor(legacyMissing),
        progressFor(
          notStarted,
          timingReviewStatus: CaseTimingReviewStatus.notStarted,
          totalDuration: null,
          completedStepCount: 0,
        ),
      ],
      videoStates: const {
        'legacy-missing': RecordVideoState(RecordVideoStateKind.missing),
      },
    );

    await tester.tap(find.byKey(const Key('record-needs-attention-filter')));
    await tester.pumpAndSettle();

    expect(find.text('5件'), findsOneWidget);
    expect(find.text('2026年8月　1件'), findsOneWidget);
    expect(find.text('2026年7月　1件'), findsOneWidget);
    expect(find.text('2026年6月　1件'), findsOneWidget);
    expect(find.byKey(const Key('record-list-item-reviewing')), findsOneWidget);
    expect(find.byKey(const Key('record-list-item-completed')), findsNothing);

    await tester.tap(find.byKey(const Key('record-month-header-2026-7')));
    await tester.tap(find.byKey(const Key('record-month-header-2026-6')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('record-list-item-legacy-missing')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('record-list-item-legacy-normal')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('record-list-item-not-started')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('record-needs-attention-filter')));
    await tester.pumpAndSettle();
    expect(find.text('2026年8月　2件'), findsOneWidget);
    expect(find.text('2026年7月　2件'), findsOneWidget);
    expect(
      find.byKey(const Key('record-list-item-legacy-normal')),
      findsOneWidget,
    );
  });

  testWidgets('フィルターで月が非表示になってもOFF時に事前の展開状態を復元する', (tester) async {
    final august = record(
      id: 'august-issue',
      surgeryDate: DateTime(2026, 8, 8),
    );
    final july = record(id: 'july-normal', surgeryDate: DateTime(2026, 7, 8));
    await pumpList(
      tester,
      [august, july],
      size: const Size(800, 1000),
      progress: [
        progressFor(
          august,
          timingReviewStatus: CaseTimingReviewStatus.inProgress,
        ),
        progressFor(july),
      ],
    );

    await tester.tap(find.byKey(const Key('record-month-header-2026-7')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('record-list-item-august-issue')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('record-list-item-july-normal')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('record-needs-attention-filter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-month-header-2026-7')), findsNothing);
    expect(find.byKey(const Key('record-list-item-july-normal')), findsNothing);

    await tester.tap(find.byKey(const Key('record-needs-attention-filter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-month-header-2026-7')), findsOneWidget);
    expect(
      find.byKey(const Key('record-list-item-august-issue')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('record-list-item-july-normal')),
      findsOneWidget,
    );
  });

  testWidgets('動画判定中は空表示を確定せず、完了後に空状態へ切り替える', (tester) async {
    final item = record(id: 'pending', surgeryDate: DateTime(2026, 8, 8));
    final videoCompleter = Completer<RecordVideoState>();
    await pumpList(
      tester,
      [item],
      videoLoaders: {'pending': () => videoCompleter.future},
    );

    await tester.tap(find.byKey(const Key('record-needs-attention-filter')));
    await tester.pump();

    expect(find.text('要対応の症例を確認しています…'), findsOneWidget);
    expect(find.text('要対応の症例はありません'), findsNothing);

    videoCompleter.complete(
      const RecordVideoState(RecordVideoStateKind.availableManaged),
    );
    await tester.pumpAndSettle();

    expect(find.text('要対応の症例を確認しています…'), findsNothing);
    expect(find.text('要対応の症例はありません'), findsOneWidget);
  });

  testWidgets('レビュー要対応が確定した症例は動画判定中でも表示する', (tester) async {
    final item = record(id: 'known-issue', surgeryDate: DateTime(2026, 8, 8));
    final videoCompleter = Completer<RecordVideoState>();
    await pumpList(
      tester,
      [item],
      progress: [
        progressFor(
          item,
          timingReviewStatus: CaseTimingReviewStatus.inProgress,
        ),
      ],
      videoLoaders: {'known-issue': () => videoCompleter.future},
    );

    await tester.tap(find.byKey(const Key('record-needs-attention-filter')));
    await tester.pump();

    expect(
      find.byKey(const Key('record-list-item-known-issue')),
      findsOneWidget,
    );
    expect(find.text('要対応の症例はありません'), findsNothing);

    videoCompleter.complete(
      const RecordVideoState(RecordVideoStateKind.availableManaged),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('工程状態取得失敗時は空表示せず、再読込後に確定する', (tester) async {
    final item = record(
      id: 'progress-error',
      surgeryDate: DateTime(2026, 8, 8),
    );
    var progressLoadCount = 0;
    await pumpList(
      tester,
      [item],
      progressLoader: () async {
        progressLoadCount++;
        if (progressLoadCount == 1) {
          throw StateError('controlled progress failure');
        }
        return [progressFor(item)];
      },
    );

    await tester.tap(find.byKey(const Key('record-needs-attention-filter')));
    await tester.pumpAndSettle();

    expect(find.text('工程情報を読み込めませんでした。'), findsOneWidget);
    expect(find.text('要対応状態を確認できませんでした。再読み込みしてください。'), findsOneWidget);
    expect(find.text('要対応の症例はありません'), findsNothing);

    await tester.tap(find.text('再読み込み'));
    await tester.pumpAndSettle();

    expect(progressLoadCount, 2);
    expect(find.text('工程情報を読み込めませんでした。'), findsNothing);
    expect(find.text('要対応の症例はありません'), findsOneWidget);
  });

  testWidgets('月見出しと要対応フィルターのSemanticsが状態に追従する', (tester) async {
    final semantics = tester.ensureSemantics();
    final august = record(id: 'august', surgeryDate: DateTime(2026, 8, 8));
    final july = record(id: 'july', surgeryDate: DateTime(2026, 7, 8));
    await pumpList(
      tester,
      [august, july],
      size: const Size(800, 1000),
      progress: [
        progressFor(
          august,
          timingReviewStatus: CaseTimingReviewStatus.inProgress,
        ),
        progressFor(july),
      ],
    );

    var augustNode = tester.getSemantics(
      find.byKey(const Key('record-month-header-2026-8')),
    );
    var julyNode = tester.getSemantics(
      find.byKey(const Key('record-month-header-2026-7')),
    );
    expect(augustNode.label, contains('展開中'));
    expect(julyNode.label, contains('折りたたみ中'));
    expect(julyNode.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    julyNode.owner!.performAction(julyNode.id, SemanticsAction.tap);
    await tester.pumpAndSettle();
    julyNode = tester.getSemantics(
      find.byKey(const Key('record-month-header-2026-7')),
    );
    expect(julyNode.label, contains('展開中'));

    var filterNode = tester.getSemantics(find.bySemanticsLabel('要対応のみ'));
    expect(
      filterNode.getSemanticsData().flagsCollection.isSelected,
      Tristate.isFalse,
    );
    expect(
      filterNode.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
    );

    filterNode.owner!.performAction(filterNode.id, SemanticsAction.tap);
    await tester.pumpAndSettle();
    filterNode = tester.getSemantics(find.bySemanticsLabel('要対応のみ'));
    expect(
      filterNode.getSemanticsData().flagsCollection.isSelected,
      Tristate.isTrue,
    );
    augustNode = tester.getSemantics(
      find.byKey(const Key('record-month-header-2026-8')),
    );
    expect(augustNode.label, contains('展開中'));
    semantics.dispose();
  });

  testWidgets('症例カードのタップで詳細画面へ遷移する', (tester) async {
    final item = record(id: 'tap-target', surgeryDate: DateTime(2026, 8, 8));
    await pumpList(tester, [item], detailRecord: item);

    await tester.tap(find.byKey(Key('record-list-item-${item.id}')));
    await tester.pumpAndSettle();

    expect(find.byType(RecordDetailScreen), findsOneWidget);
    expect(find.text('症例詳細'), findsOneWidget);
  });

  testWidgets('詳細画面から戻っても複数月の展開状態を保持する', (tester) async {
    final august = record(id: 'august', surgeryDate: DateTime(2026, 8, 8));
    final july = record(id: 'july', surgeryDate: DateTime(2026, 7, 8));
    await pumpList(
      tester,
      [august, july],
      size: const Size(800, 1000),
      detailRecord: july,
    );

    await tester.tap(find.byKey(const Key('record-month-header-2026-7')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-list-item-august')), findsOneWidget);
    expect(find.byKey(const Key('record-list-item-july')), findsOneWidget);

    await tester.tap(find.byKey(const Key('record-list-item-july')));
    await tester.pumpAndSettle();
    expect(find.byType(RecordDetailScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(RecordListScreen), findsOneWidget);
    expect(find.byKey(const Key('record-list-item-august')), findsOneWidget);
    expect(find.byKey(const Key('record-list-item-july')), findsOneWidget);
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
    expect(node.label, contains('総手術時間'));

    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pumpAndSettle();

    expect(find.byType(RecordDetailScreen), findsOneWidget);
    semantics.dispose();
  });
}
