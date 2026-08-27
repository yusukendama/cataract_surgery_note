import 'dart:async';
import 'dart:io';

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/record_video_service.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/surgery_video_picker.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_import_preflight.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/features/review/step_review_screen.dart';
import 'package:cataract_surgery_note/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/video_import_test_support.dart';

void main() {
  Future<(AppDatabase, SurgeryRecord)> createRecord(WidgetTester tester) async {
    late AppDatabase database;
    late SurgeryRecord record;
    await tester.runAsync(() async {
      database = AppDatabase.memory();
      record = await SurgeryRepository(database).createRecord(
        surgeryDate: DateTime(2026, 7, 18),
        eyeSide: EyeSide.right,
      );
    });
    return (database, record);
  }

  Future<ProviderContainer> pumpScreen(
    WidgetTester tester,
    AppDatabase database,
    String recordId, {
    SurgeryRepository? repository,
    VideoStorageRepository? videoStorageRepository,
    SurgeryVideoPicker? surgeryVideoPicker,
    VideoImportPreflight? videoImportPreflight,
    RecordVideoService? recordVideoService,
    SuccessHapticFeedback? successHapticFeedback,
    String? initialStepStorageId,
    MediaQueryData? mediaQueryData,
    bool settle = true,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => database),
        if (repository != null)
          surgeryRepositoryProvider.overrideWithValue(repository),
        if (videoStorageRepository != null)
          videoStorageRepositoryProvider.overrideWithValue(
            videoStorageRepository,
          ),
        if (surgeryVideoPicker != null)
          surgeryVideoPickerProvider.overrideWithValue(surgeryVideoPicker),
        if (videoImportPreflight != null)
          videoImportPreflightProvider.overrideWithValue(videoImportPreflight),
        if (recordVideoService != null)
          recordVideoServiceProvider.overrideWithValue(recordVideoService),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          initialRoute: '/review',
          routes: {
            '/': (_) => const Scaffold(body: Text('症例一覧')),
            '/review': (_) {
              final screen = StepReviewScreen(
                recordId: recordId,
                initialStepStorageId: initialStepStorageId,
                successHapticFeedback: successHapticFeedback,
              );
              return mediaQueryData == null
                  ? screen
                  : MediaQuery(data: mediaQueryData, child: screen);
            },
          },
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
    return container;
  }

  testWidgets('11項目と症例メモの12タブと保存ボタンが表示される', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(tester, database, record.id);

    for (final step in surgicalStepsInDisplayOrder) {
      expect(find.widgetWithText(Tab, step.label), findsOneWidget);
    }
    expect(find.widgetWithText(Tab, '症例メモ'), findsOneWidget);
    expect(find.widgetWithText(Tab, '総手術時間'), findsOneWidget);
    expect(find.text('テノン嚢下麻酔'), findsNothing);
    expect(find.text('デキサート結膜下注射'), findsNothing);
    expect(find.text('保存'), findsOneWidget);
    expect(find.byType(ProcedureTimingCard), findsOneWidget);
  });

  testWidgets('動画が未初期化の場合は再生操作を表示しない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(tester, database, record.id);

    expect(find.byType(VideoTransportControls), findsNothing);
  });

  testWidgets('タブ切替で該当工程のカードと症例メモ欄が表示される', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(tester, database, record.id);

    expect(
      find.descendant(
        of: find.byType(ProcedureTimingCard),
        matching: find.text('総手術時間'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(Tab, 'CCC'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(ProcedureTimingCard),
        matching: find.text('CCC'),
      ),
      findsOneWidget,
    );
    await _scrollToStepNotes(tester, SurgicalStep.capsulorhexis);
    expect(find.text('自己評価・反省点'), findsOneWidget);
    expect(find.text('任意'), findsOneWidget);
    expect(find.widgetWithText(TextField, '反省点'), findsNothing);

    await tester.tap(find.text('自己評価・反省点'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '反省点'), findsOneWidget);

    await tester.ensureVisible(find.widgetWithText(Tab, '症例メモ'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '症例メモ'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '症例全体のメモ'), findsOneWidget);
  });

  testWidgets('個別工程カードに同一snapshotの到達時間を表示し総手術カードには表示しない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final semantics = tester.ensureSemantics();
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final reviews = await repository.ensureStepReviews(record.id);
      final total = reviews.singleWhere(
        (review) => review.step == SurgicalStep.totalSurgeryTime,
      );
      final nucleus = reviews.singleWhere(
        (review) => review.step == SurgicalStep.nucleusRemoval,
      );
      await repository.saveStepTiming(
        review: total.copyWith(
          startMilliseconds: 30000,
          endMilliseconds: 500000,
        ),
        expectedVideoPath: null,
      );
      await repository.saveStepTiming(
        review: nucleus.copyWith(
          startMilliseconds: 250000,
          endMilliseconds: 380000,
        ),
        expectedVideoPath: null,
      );
    });

    await pumpScreen(tester, database, record.id);
    await _openTab(tester, '総手術時間');
    expect(find.textContaining('開始まで'), findsNothing);

    await _openTab(tester, '核処理');
    expect(find.text('所要時間：2分10秒'), findsOneWidget);
    expect(find.text('開始まで：3分40秒'), findsOneWidget);
    expect(find.bySemanticsLabel('手術開始から3分40秒で開始'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('工程所要時間が逆転しても有効な開始位置から到達時間を表示する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final reviews = await repository.ensureStepReviews(record.id);
      final total = reviews.singleWhere(
        (review) => review.step == SurgicalStep.totalSurgeryTime,
      );
      final nucleus = reviews.singleWhere(
        (review) => review.step == SurgicalStep.nucleusRemoval,
      );
      await database.customStatement(
        '''
UPDATE surgical_step_reviews
SET start_milliseconds = ?, end_milliseconds = ?
WHERE id = ?
''',
        <Object?>[30000, 500000, total.id],
      );
      await database.customStatement(
        '''
UPDATE surgical_step_reviews
SET start_milliseconds = ?, end_milliseconds = ?
WHERE id = ?
''',
        <Object?>[250000, 200000, nucleus.id],
      );
    });

    await pumpScreen(tester, database, record.id);
    await _openTab(tester, '核処理');

    expect(find.text('要再設定'), findsOneWidget);
    expect(find.text('開始まで：3分40秒'), findsOneWidget);
    expect(find.textContaining('所要時間：'), findsNothing);
  });

  testWidgets('動画なしでは開始を無効化し、既存時刻の再設定は保存する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    late SurgicalStepReview total;
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      await repository.ensureStepReviews(record.id);
      final initial = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      ))!;
      total = await repository.saveStepTiming(
        review: initial.copyWith(
          startMilliseconds: 1000,
          endMilliseconds: 2000,
        ),
        expectedVideoPath: null,
      );
    });
    expect(total.isCompleted, isTrue);

    var hapticCount = 0;
    await pumpScreen(
      tester,
      database,
      record.id,
      successHapticFeedback: () async {
        hapticCount++;
        throw StateError('ハプティクス利用不可');
      },
    );

    await _openTab(tester, '総手術時間');
    await tester.tap(find.text('再設定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(hapticCount, 0);

    await tester.tap(find.text('再設定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('再設定').last);
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      total = (await SurgeryRepository(database).getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      ))!;
    });
    expect(total.isNotStarted, isTrue);
    expect(hapticCount, 1);
    final startButton = tester.widget<FilledButton>(
      find.byKey(const Key('procedure-start-button')),
    );
    expect(startButton.onPressed, isNull);
    expect(_saveButton(tester).onPressed, isNull);
  });

  testWidgets('空白正規化後の保存基準値でdirtyを判定する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(tester, database, record.id);
    await _openCaseMemoTab(tester);
    expect(_popScope(tester).canPop, isTrue);

    final memo = find.widgetWithText(TextField, '症例全体のメモ');
    await tester.enterText(memo, '  振り返り  ');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNotNull);
    expect(_popScope(tester).canPop, isFalse);

    await tester.enterText(memo, '   ');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNull);
    expect(_popScope(tester).canPop, isTrue);
  });

  testWidgets('実体なし参照は同じ動画の再登録と別動画差し替えを分ける', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      await SurgeryRepository(database).updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: '../invalid.mp4',
        videoDisplayName: 'missing.mp4',
      );
    });

    await pumpScreen(tester, database, record.id);

    expect(find.textContaining('動画参照が不正'), findsOneWidget);
    expect(find.text('同じ動画を再登録'), findsOneWidget);
    expect(find.text('別の動画に差し替え'), findsOneWidget);
    expect(find.textContaining('既存の工程記録は保持'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('procedure-start-button')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('実体なしを工程記録を保持して表示する', (tester) async {
    final (missingDatabase, missingRecord) = await createRecord(tester);
    addTearDown(missingDatabase.close);
    await tester.runAsync(() async {
      await SurgeryRepository(missingDatabase).updateVideoReference(
        surgeryRecordId: missingRecord.id,
        videoPath: 'videos/${missingRecord.id}/missing.mp4',
        videoDisplayName: 'missing.mp4',
      );
    });
    await pumpScreen(
      tester,
      missingDatabase,
      missingRecord.id,
      videoStorageRepository: const _ReviewStateVideoStorage(),
    );

    expect(find.textContaining('動画の実体が見つかりません'), findsOneWidget);
    expect(find.textContaining('実体なしとは判定していません'), findsNothing);
    expect(find.text('同じ動画を再登録'), findsOneWidget);
  });

  testWidgets('確認失敗を実体なしと誤表示せず再試行できる', (tester) async {
    final (failedDatabase, failedRecord) = await createRecord(tester);
    addTearDown(failedDatabase.close);
    await tester.runAsync(() async {
      await SurgeryRepository(failedDatabase).updateVideoReference(
        surgeryRecordId: failedRecord.id,
        videoPath: 'videos/${failedRecord.id}/unreadable.mp4',
        videoDisplayName: 'unreadable.mp4',
      );
    });
    await pumpScreen(
      tester,
      failedDatabase,
      failedRecord.id,
      videoStorageRepository: const _ReviewStateVideoStorage(
        resolveError: FileSystemException('制御可能な確認失敗'),
      ),
    );

    expect(find.textContaining('実体なしとは判定していません'), findsOneWidget);
    expect(find.text('動画を再確認'), findsOneWidget);
    expect(find.text('同じ動画を再登録'), findsNothing);
  });

  testWidgets('工程時刻がある初回添付は未選択・キャンセル・同一動画保持を分ける', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    await tester.runAsync(() async {
      final reviews = await repository.ensureStepReviews(record.id);
      final total = reviews.singleWhere(
        (review) => review.step == SurgicalStep.totalSurgeryTime,
      );
      await repository.saveStepTiming(
        review: total.copyWith(startMilliseconds: 100, endMilliseconds: 900),
        expectedVideoPath: null,
      );
    });
    final picker = _CountingVideoPicker(
      const SelectedSurgeryVideo(
        path: '/tmp/review-selected.mp4',
        displayName: 'review-selected.mp4',
      ),
    );
    final preflight = const _ReadyVideoImportPreflight();
    final storage = _RecordingReviewVideoStorage();
    final service = _RecordingReviewVideoService(
      repository,
      storage,
      preflight,
    );
    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      videoStorageRepository: storage,
      surgeryVideoPicker: picker,
      videoImportPreflight: preflight,
      recordVideoService: service,
    );

    await tester.tap(find.text('動画を登録'));
    await tester.pumpAndSettle();
    expect(picker.calls, 0);
    expect(find.text('工程位置が記録されています'), findsOneWidget);
    expect(find.textContaining('同じ動画として工程位置を保持するか'), findsOneWidget);

    await tester.tap(find.text('動画を選ぶ'));
    await _pumpAsyncWork(tester);
    expect(picker.calls, 1);
    expect(find.text('選択した動画について確認してください'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('continue-with-timeline-identity')),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    late SurgeryRecord? unchangedRecord;
    late SurgicalStepReview? unchangedTiming;
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      unchangedRecord = await repository.getRecord(record.id);
      unchangedTiming = await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
    });
    expect(unchangedRecord!.videoPath, isNull);
    expect(unchangedTiming!.startMilliseconds, 100);
    expect(unchangedTiming!.endMilliseconds, 900);
    expect(service.totalMutationCalls, 0);
    expect(storage.importCalls, 0);

    await tester.tap(find.text('動画を登録'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('動画を選ぶ'));
    await _pumpAsyncWork(tester);
    await _chooseTimelineIdentity(
      tester,
      const Key('timeline-identity-same-unchanged'),
    );
    expect(find.text('記録済み位置を保持して動画を登録'), findsOneWidget);
    await tester.tap(find.text('この動画を登録'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    late SurgicalStepReview? preservedTiming;
    await tester.runAsync(() async {
      preservedTiming = await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
    });
    expect(picker.calls, 2);
    expect(service.attachCalls, 1);
    expect(service.attachWithTimingResetCalls, 0);
    expect(storage.importCalls, 1);
    expect(preservedTiming!.startMilliseconds, 100);
    expect(preservedTiming!.endMilliseconds, 900);
  });

  testWidgets('直接ジャンプ準備時に動画なしへ変わっても登録後はplayerを復旧し再seekしない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    await tester.runAsync(() async {
      await repository.ensureStepReviews(record.id);
      final ccc = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      await repository.saveStepTiming(
        review: ccc.copyWith(startMilliseconds: 8200, endMilliseconds: 9100),
        expectedVideoPath: null,
      );
    });
    final picker = _CountingVideoPicker(
      const SelectedSurgeryVideo(
        path: '/tmp/direct-jump-late-registration.mp4',
        displayName: 'direct-jump-late-registration.mp4',
      ),
    );
    final preflight = const _ReadyVideoImportPreflight();
    final resolvedFile = File('/tmp/direct-jump-late-registration-managed.mp4');
    final storage = _RecordingReviewVideoStorage(resolvedFile: resolvedFile);
    final service = _RecordingReviewVideoService(
      repository,
      storage,
      preflight,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      videoStorageRepository: storage,
      surgeryVideoPicker: picker,
      videoImportPreflight: preflight,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
    );

    expect(find.textContaining('動画を利用できないため'), findsOneWidget);
    expect(find.text('動画を登録'), findsOneWidget);
    expect(videoPlatform.createCount, 0);
    expect(find.byKey(const Key('review-video-player')), findsNothing);
    expect(videoPlatform.seekRequests, isEmpty);

    await tester.tap(find.text('動画を登録'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('動画を選ぶ'));
    await _pumpAsyncWork(tester);
    await _chooseTimelineIdentity(
      tester,
      const Key('timeline-identity-same-unchanged'),
    );
    await tester.tap(find.text('この動画を登録'));
    await _pumpUntil(tester, () => videoPlatform.createCount == 1);
    await _pumpAsyncWork(tester);

    late SurgeryRecord? committedRecord;
    await tester.runAsync(() async {
      committedRecord = await repository.getRecord(record.id);
    });
    expect(committedRecord!.videoPath, isNotNull);
    expect(find.byKey(const Key('review-video-player')), findsOneWidget);
    expect(videoPlatform.activePlayerIds, hasLength(1));
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('動画なしでabandoned後に外部登録されたらresolverを開始し手動playerを復旧する', (
    tester,
  ) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    await tester.runAsync(() async {
      await repository.ensureStepReviews(record.id);
      final ccc = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      await repository.saveStepTiming(
        review: ccc.copyWith(startMilliseconds: 8250),
        expectedVideoPath: null,
      );
    });
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );
    final resolvedFile = File('/tmp/direct-jump-external-registration.mp4');

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: resolvedFile,
      ),
    );

    expect(find.textContaining('動画を利用できないため'), findsOneWidget);
    expect(videoPlatform.createCount, 0);
    expect(videoPlatform.seekRequests, isEmpty);

    await tester.runAsync(
      () => repository.updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: 'videos/${record.id}/external-registration.mp4',
        videoDisplayName: 'external-registration.mp4',
      ),
    );
    container.invalidate(surgeryRecordProvider(record.id));
    await _pumpUntil(
      tester,
      () =>
          videoPlatform.createCount == 1 &&
          find.byType(VideoTransportControls).evaluate().isNotEmpty,
    );

    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    expect(
      tester
          .widget<VideoTransportControls>(find.byType(VideoTransportControls))
          .onTogglePlayback,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('changed/unknownの初回添付は時刻を消去し未保存入力を保持する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    await tester.runAsync(() async {
      final reviews = await repository.ensureStepReviews(record.id);
      final total = reviews.singleWhere(
        (review) => review.step == SurgicalStep.totalSurgeryTime,
      );
      await repository.saveStepTiming(
        review: total.copyWith(startMilliseconds: 100, endMilliseconds: 900),
        expectedVideoPath: null,
      );
    });
    final preflight = const _ReadyVideoImportPreflight();
    final storage = _RecordingReviewVideoStorage();
    final service = _RecordingReviewVideoService(
      repository,
      storage,
      preflight,
    );
    final picker = _CountingVideoPicker(
      const SelectedSurgeryVideo(
        path: '/tmp/changed-attach.mp4',
        displayName: 'changed-attach.mp4',
      ),
    );
    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      videoStorageRepository: storage,
      surgeryVideoPicker: picker,
      videoImportPreflight: preflight,
      recordVideoService: service,
    );

    await _openTab(tester, 'CCC');
    await _scrollToStepNotes(tester, SurgicalStep.capsulorhexis);
    await tester.tap(find.text('自己評価・反省点'));
    await tester.pumpAndSettle();
    final rating = find.byType(DropdownButtonFormField<StepRating>);
    await tester.ensureVisible(rating);
    await tester.pumpAndSettle();
    await tester.tap(rating);
    await tester.pumpAndSettle();
    await tester.tap(find.text(StepRating.good.label).last);
    await tester.pumpAndSettle();
    final reflection = find.widgetWithText(TextField, '反省点');
    await tester.ensureVisible(reflection);
    await tester.pumpAndSettle();
    await tester.enterText(reflection, '未保存の反省点');
    await _openCaseMemoTab(tester);
    final memo = find.widgetWithText(TextField, '症例全体のメモ');
    await tester.enterText(memo, '未保存の症例メモ');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNotNull);

    await tester.tap(find.text('動画を登録'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('動画を選ぶ'));
    await _pumpAsyncWork(tester);
    await _chooseTimelineIdentity(
      tester,
      const Key('timeline-identity-changed-or-unknown'),
    );
    expect(find.text('工程位置を消去して動画を登録'), findsOneWidget);
    expect(find.textContaining('未保存の入力内容は残ります'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '登録'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(service.attachCalls, 0);
    expect(service.attachWithTimingResetCalls, 1);
    expect(service.replaceCalls, 0);
    expect(storage.importCalls, 1);
    expect(tester.widget<TextField>(memo).controller!.text, '未保存の症例メモ');
    expect(_saveButton(tester).onPressed, isNotNull);

    await _openTab(tester, 'CCC');
    if (find.widgetWithText(TextField, '反省点').evaluate().isEmpty) {
      await _scrollToStepNotes(tester, SurgicalStep.capsulorhexis);
      await tester.tap(find.text('自己評価・反省点'));
      await tester.pumpAndSettle();
    }
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '反省点'))
          .controller!
          .text,
      '未保存の反省点',
    );
    expect(
      tester
          .widget<DropdownButtonFormField<StepRating>>(
            find.byType(DropdownButtonFormField<StepRating>),
          )
          .initialValue,
      StepRating.good,
    );

    late SurgeryRecord? persistedRecord;
    late SurgicalStepReview? persistedTotal;
    late SurgicalStepReview? persistedCcc;
    await tester.runAsync(() async {
      persistedRecord = await repository.getRecord(record.id);
      persistedTotal = await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
      persistedCcc = await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      );
    });
    expect(persistedTotal!.startMilliseconds, isNull);
    expect(persistedTotal!.endMilliseconds, isNull);
    expect(persistedRecord!.caseMemo, isEmpty);
    expect(persistedCcc!.rating, StepRating.unreviewed);
    expect(persistedCcc!.reflection, isEmpty);
  });

  testWidgets('工程時刻がある同一動画再登録は未選択・キャンセル・same保持を分ける', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    final oldPath = 'videos/${record.id}/missing.mp4';
    await tester.runAsync(() async {
      final reviews = await repository.ensureStepReviews(record.id);
      final total = reviews.singleWhere(
        (review) => review.step == SurgicalStep.totalSurgeryTime,
      );
      await repository.saveStepTiming(
        review: total.copyWith(startMilliseconds: 100, endMilliseconds: 900),
        expectedVideoPath: null,
      );
      await repository.updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: oldPath,
        videoDisplayName: 'missing.mp4',
      );
    });
    final preflight = const _ReadyVideoImportPreflight();
    final storage = _RecordingReviewVideoStorage();
    final service = _RecordingReviewVideoService(
      repository,
      storage,
      preflight,
    );
    final picker = _CountingVideoPicker(
      const SelectedSurgeryVideo(
        path: '/tmp/same-relink.mp4',
        displayName: 'same-relink.mp4',
      ),
    );
    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      videoStorageRepository: storage,
      surgeryVideoPicker: picker,
      videoImportPreflight: preflight,
      recordVideoService: service,
    );

    await tester.tap(find.text('同じ動画を再登録'));
    await _pumpAsyncWork(tester);
    expect(find.text('選択した動画について確認してください'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('continue-with-timeline-identity')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();

    late SurgeryRecord? unchangedRecord;
    late SurgicalStepReview? unchangedTiming;
    await tester.runAsync(() async {
      unchangedRecord = await repository.getRecord(record.id);
      unchangedTiming = await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
    });
    expect(unchangedRecord!.videoPath, oldPath);
    expect(unchangedTiming!.startMilliseconds, 100);
    expect(unchangedTiming!.endMilliseconds, 900);
    expect(service.totalMutationCalls, 0);
    expect(storage.importCalls, 0);

    await tester.tap(find.text('同じ動画を再登録'));
    await _pumpAsyncWork(tester);
    await _chooseTimelineIdentity(
      tester,
      const Key('timeline-identity-same-unchanged'),
    );
    expect(find.text('同じ動画を再登録'), findsOneWidget);
    await tester.tap(find.text('同じ動画として再登録'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    late SurgeryRecord? relinkedRecord;
    late SurgicalStepReview? preservedTiming;
    await tester.runAsync(() async {
      relinkedRecord = await repository.getRecord(record.id);
      preservedTiming = await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
    });
    expect(picker.calls, 2);
    expect(service.relinkCalls, 1);
    expect(service.replaceCalls, 0);
    expect(storage.importCalls, 1);
    expect(relinkedRecord!.videoPath, isNot(oldPath));
    expect(preservedTiming!.startMilliseconds, 100);
    expect(preservedTiming!.endMilliseconds, 900);
  });

  testWidgets('changed/unknownの同一動画再登録はreplaceとして工程時刻を消去する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    final oldPath = 'videos/${record.id}/missing.mp4';
    await tester.runAsync(() async {
      final reviews = await repository.ensureStepReviews(record.id);
      final total = reviews.singleWhere(
        (review) => review.step == SurgicalStep.totalSurgeryTime,
      );
      await repository.saveStepTiming(
        review: total.copyWith(startMilliseconds: 100, endMilliseconds: 900),
        expectedVideoPath: null,
      );
      await repository.updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: oldPath,
        videoDisplayName: 'missing.mp4',
      );
    });
    final preflight = const _ReadyVideoImportPreflight();
    final storage = _RecordingReviewVideoStorage();
    final service = _RecordingReviewVideoService(
      repository,
      storage,
      preflight,
    );
    final picker = _CountingVideoPicker(
      const SelectedSurgeryVideo(
        path: '/tmp/changed-relink.mp4',
        displayName: 'changed-relink.mp4',
      ),
    );
    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      videoStorageRepository: storage,
      surgeryVideoPicker: picker,
      videoImportPreflight: preflight,
      recordVideoService: service,
    );

    await tester.tap(find.text('同じ動画を再登録'));
    await _pumpAsyncWork(tester);
    await _chooseTimelineIdentity(
      tester,
      const Key('timeline-identity-changed-or-unknown'),
    );
    expect(find.text('工程位置を消去して動画を差し替え'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '差し替え'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    late SurgeryRecord? replacedRecord;
    late SurgicalStepReview? clearedTiming;
    await tester.runAsync(() async {
      replacedRecord = await repository.getRecord(record.id);
      clearedTiming = await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
    });
    expect(service.relinkCalls, 0);
    expect(service.replaceCalls, 1);
    expect(storage.importCalls, 1);
    expect(replacedRecord!.videoPath, isNot(oldPath));
    expect(clearedTiming!.startMilliseconds, isNull);
    expect(clearedTiming!.endMilliseconds, isNull);
  });

  for (final scenario
      in <
        ({
          String name,
          String fileName,
          String expectedTitle,
          VideoImportPreflight preflight,
        })
      >[
        (
          name: 'noncandidate',
          fileName: 'selected.avi',
          expectedTitle: 'この拡張子のファイルは登録対象外です',
          preflight: const _NonCandidateVideoImportPreflight(),
        ),
        (
          name: 'preflight失敗',
          fileName: 'selected.mp4',
          expectedTitle: 'この動画は使用できません',
          preflight: const _FailingVideoImportPreflight(),
        ),
      ]) {
    testWidgets('${scenario.name}でstorageとDBを変更しない', (tester) async {
      final (database, record) = await createRecord(tester);
      addTearDown(database.close);
      final repository = SurgeryRepository(database);
      await tester.runAsync(() async {
        final reviews = await repository.ensureStepReviews(record.id);
        final total = reviews.singleWhere(
          (review) => review.step == SurgicalStep.totalSurgeryTime,
        );
        await repository.saveStepTiming(
          review: total.copyWith(startMilliseconds: 100, endMilliseconds: 900),
          expectedVideoPath: null,
        );
      });
      final storage = _RecordingReviewVideoStorage();
      final service = _RecordingReviewVideoService(
        repository,
        storage,
        scenario.preflight,
      );
      final picker = _CountingVideoPicker(
        SelectedSurgeryVideo(
          path: '/tmp/${scenario.fileName}',
          displayName: scenario.fileName,
        ),
      );
      await pumpScreen(
        tester,
        database,
        record.id,
        repository: repository,
        videoStorageRepository: storage,
        surgeryVideoPicker: picker,
        videoImportPreflight: scenario.preflight,
        recordVideoService: service,
      );

      await tester.tap(find.text('動画を登録'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('動画を選ぶ'));
      await _pumpAsyncWork(tester);

      expect(find.text(scenario.expectedTitle), findsOneWidget);
      expect(storage.importCalls, 0);
      expect(service.totalMutationCalls, 0);
      late SurgeryRecord? unchangedRecord;
      late SurgicalStepReview? unchangedTiming;
      await tester.runAsync(() async {
        unchangedRecord = await repository.getRecord(record.id);
        unchangedTiming = await repository.getStepReview(
          surgeryRecordId: record.id,
          step: SurgicalStep.totalSurgeryTime,
        );
      });
      expect(unchangedRecord!.videoPath, isNull);
      expect(unchangedTiming!.startMilliseconds, 100);
      expect(unchangedTiming!.endMilliseconds, 900);

      await tester.tap(find.text('閉じる'));
      await tester.pumpAndSettle();
      expect(find.text('動画を登録'), findsOneWidget);
    });
  }

  testWidgets('動画commit後の後処理保留を成功ではなくwarning表示する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    final service = _PendingCleanupVideoService(repository);
    final picker = _CountingVideoPicker(
      const SelectedSurgeryVideo(
        path: '/tmp/pending-cleanup.mp4',
        displayName: 'pending-cleanup.mp4',
      ),
    );
    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      surgeryVideoPicker: picker,
      videoImportPreflight: const _ReadyVideoImportPreflight(),
      recordVideoService: service,
    );

    await tester.tap(find.text('動画を登録'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(picker.calls, 1);
    expect(find.text('保存は完了しました。動画の後処理は次回起動時に再試行します。'), findsOneWidget);
  });

  testWidgets('legacy動画移行後のcommit済み参照で時刻を保存する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    late Directory temporaryDirectory;
    late File legacyVideo;
    late _MigratingVideoStorage storage;
    await tester.runAsync(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'review_legacy_video_',
      );
      legacyVideo = File('${temporaryDirectory.path}/legacy.mp4');
      await legacyVideo.writeAsBytes(const <int>[0, 1, 2, 3]);
      storage = _MigratingVideoStorage(legacyVideo);
      final repository = SurgeryRepository(database);
      final reviews = await repository.ensureStepReviews(record.id);
      final total = reviews.singleWhere(
        (review) => review.step == SurgicalStep.totalSurgeryTime,
      );
      await repository.saveStepTiming(
        review: total.copyWith(startMilliseconds: 100, endMilliseconds: 900),
        expectedVideoPath: null,
      );
      await repository.updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: legacyVideo.path,
        videoDisplayName: 'legacy.mp4',
      );
      final legacyRecord = (await repository.getRecord(record.id))!;
      await RecordVideoService(
        surgeryRepository: repository,
        videoStorageRepository: storage,
        videoImportPreflight: const PassThroughVideoImportPreflight(),
      ).resolveVideoForRecord(legacyRecord);
    });
    addTearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    await pumpScreen(
      tester,
      database,
      record.id,
      videoStorageRepository: storage,
    );
    late SurgeryRecord? migratedRecord;
    await tester.runAsync(() async {
      migratedRecord = await SurgeryRepository(database).getRecord(record.id);
    });
    expect(migratedRecord!.videoPath, storage.relativePathFor(record.id));

    await _openTab(tester, '総手術時間');
    await tester.tap(find.text('再設定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('再設定').last);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    late SurgicalStepReview? committed;
    await tester.runAsync(() async {
      committed = await SurgeryRepository(database).getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
    });
    expect(committed!.isNotStarted, isTrue);
    expect(find.textContaining('動画が変更されたため'), findsNothing);
  });

  testWidgets('通常保存は正規化値をControllerとDBの基準にする', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(tester, database, record.id);
    await _openCaseMemoTab(tester);
    final memo = find.widgetWithText(TextField, '症例全体のメモ');
    await tester.enterText(memo, '  正規化するメモ  ');
    await tester.pump();
    await tester.tap(find.byKey(const Key('review-save-button')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(memo).controller!.text, '正規化するメモ');
    expect(_saveButton(tester).onPressed, isNull);
    late SurgeryRecord? saved;
    await tester.runAsync(() async {
      saved = await SurgeryRepository(database).getRecord(record.id);
    });
    expect(saved!.caseMemo, '正規化するメモ');
  });

  testWidgets('レビューcommit後のProvider再読込失敗で保存済み基準を巻き戻さない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = _CommitThenFailReadsRepository(
      database,
      failAfterReviewSave: true,
    );
    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
    );
    await _openCaseMemoTab(tester);
    final memo = find.widgetWithText(TextField, '症例全体のメモ');
    await tester.enterText(memo, '  commit済みメモ  ');
    await tester.pump();
    await tester.tap(find.byKey(const Key('review-save-button')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('保存済み・表示更新失敗'), findsOneWidget);
    expect(tester.widget<TextField>(memo).controller!.text, 'commit済みメモ');
    expect(_saveButton(tester).onPressed, isNull);
    expect(_popScope(tester).canPop, isTrue);
    late SurgeryRecord? committed;
    await tester.runAsync(() async {
      committed = await SurgeryRepository(database).getRecord(record.id);
    });
    expect(committed!.caseMemo, 'commit済みメモ');

    repository.failReads = false;
    container.invalidate(surgeryRecordProvider(record.id));
    container.invalidate(stepReviewsProvider(record.id));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('保存済み・表示更新失敗'), findsNothing);
    expect(tester.widget<TextField>(memo).controller!.text, 'commit済みメモ');
  });

  testWidgets('時刻commit後のProvider再読込失敗で新時刻と成功ハプティクスを保持する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final reviews = await repository.ensureStepReviews(record.id);
      final total = reviews.singleWhere(
        (review) => review.step == SurgicalStep.totalSurgeryTime,
      );
      final ccc = reviews.singleWhere(
        (review) => review.step == SurgicalStep.capsulorhexis,
      );
      await repository.saveStepTiming(
        review: total.copyWith(startMilliseconds: 100, endMilliseconds: 900),
        expectedVideoPath: null,
      );
      await repository.saveStepTiming(
        review: ccc.copyWith(startMilliseconds: 300, endMilliseconds: 600),
        expectedVideoPath: null,
      );
    });
    final repository = _CommitThenFailReadsRepository(
      database,
      failAfterTimingSave: true,
    );
    var hapticCount = 0;
    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      successHapticFeedback: () async => hapticCount++,
    );

    await _openTab(tester, '総手術時間');
    await tester.tap(find.text('再設定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('再設定').last);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(hapticCount, 1);
    expect(find.textContaining('保存済み・表示更新失敗'), findsOneWidget);
    expect(
      tester
          .widget<ProcedureTimingCard>(find.byType(ProcedureTimingCard))
          .timing
          .isNotStarted,
      isTrue,
    );
    await _openTab(tester, 'CCC');
    expect(find.text('開始まで：—'), findsOneWidget);
    expect(find.text('「総手術時間」の開始位置を登録すると「開始まで」が表示されます。'), findsOneWidget);
    late SurgicalStepReview? committed;
    await tester.runAsync(() async {
      committed = await SurgeryRepository(database).getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
    });
    expect(committed!.isNotStarted, isTrue);
  });

  testWidgets('時刻保存の完了前はレビュー保存、他工程の時刻操作、離脱を開始しない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final reviews = await repository.ensureStepReviews(record.id);
      for (final step in <SurgicalStep>[
        SurgicalStep.totalSurgeryTime,
        SurgicalStep.sidePortCreation,
      ]) {
        final review = reviews.singleWhere((item) => item.step == step);
        await repository.saveStepTiming(
          review: review.copyWith(startMilliseconds: 100, endMilliseconds: 900),
          expectedVideoPath: null,
        );
      }
    });
    final repository = _ControlledTimingRepository(database);
    var hapticCount = 0;
    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      successHapticFeedback: () async => hapticCount++,
    );
    await _openCaseMemoTab(tester);
    await tester.enterText(
      find.widgetWithText(TextField, '症例全体のメモ'),
      '保存すべきドラフト',
    );
    await _openTab(tester, '総手術時間');

    await tester.tap(find.text('再設定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('再設定').last);
    await tester.runAsync(() => repository.started.future);
    await tester.pump();

    expect(repository.saveCalls, 1);
    expect(_saveButton(tester).onPressed, isNull);
    expect(_popScope(tester).canPop, isFalse);

    tester.widget<TabBar>(find.byType(TabBar)).controller!.index = 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final sidePortCard = tester
        .widgetList<ProcedureTimingCard>(
          find.byType(ProcedureTimingCard, skipOffstage: false),
        )
        .singleWhere((card) => card.step == SurgicalStep.sidePortCreation);
    expect(sidePortCard.onReset, isNull);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(StepReviewScreen), findsOneWidget);
    expect(find.text('保存していない変更があります'), findsNothing);

    repository.release.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(repository.saveCalls, 1);
    expect(hapticCount, 1);
    expect(_saveButton(tester).onPressed, isNotNull);
  });

  testWidgets('変更を破棄しても即時保存済み時刻はDBに残る', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final reviews = await repository.ensureStepReviews(record.id);
      final total = reviews.singleWhere(
        (review) => review.step == SurgicalStep.totalSurgeryTime,
      );
      await repository.saveStepTiming(
        review: total.copyWith(startMilliseconds: 250, endMilliseconds: 1250),
        expectedVideoPath: null,
      );
    });
    await pumpScreen(tester, database, record.id);
    await _openCaseMemoTab(tester);
    await tester.enterText(
      find.widgetWithText(TextField, '症例全体のメモ'),
      '破棄するドラフト',
    );
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('変更を破棄'));
    await tester.pumpAndSettle();

    expect(find.byType(StepReviewScreen), findsNothing);
    late SurgeryRecord? savedRecord;
    late SurgicalStepReview? savedTiming;
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      savedRecord = await repository.getRecord(record.id);
      savedTiming = await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
    });
    expect(savedRecord!.caseMemo, isEmpty);
    expect(savedTiming!.startMilliseconds, 250);
    expect(savedTiming!.endMilliseconds, 1250);
  });

  testWidgets('dirty中のProvider更新はドラフトを保持して時刻だけ更新する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final container = await pumpScreen(tester, database, record.id);
    await _openCaseMemoTab(tester);
    final memo = find.widgetWithText(TextField, '症例全体のメモ');
    await tester.enterText(memo, '入力中のドラフト');

    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final total = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      ))!;
      await repository.saveStepTiming(
        review: total.copyWith(startMilliseconds: 1200),
        expectedVideoPath: null,
      );
      container.invalidate(stepReviewsProvider(record.id));
    });
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(memo).controller!.text, '入力中のドラフト');
    await _openTab(tester, '総手術時間');
    expect(find.text('開始時刻：0:01.2'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNotNull);
  });

  testWidgets('dirty入力中のProvider失敗と再読込で編集状態を保持する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = _CommitThenFailReadsRepository(database);
    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
    );
    await _openTab(tester, 'CCC');
    await _scrollToStepNotes(tester, SurgicalStep.capsulorhexis);
    await tester.tap(find.text('自己評価・反省点'));
    await tester.pumpAndSettle();
    final reflection = find.widgetWithText(TextField, '反省点');
    await tester.ensureVisible(reflection);
    await tester.pumpAndSettle();
    await tester.tap(reflection);
    final controller = tester.widget<TextField>(reflection).controller!;
    controller.value = const TextEditingValue(
      text: '入力中のドラフト',
      selection: TextSelection(baseOffset: 1, extentOffset: 5),
      composing: TextRange(start: 0, end: 5),
    );
    await tester.pump();
    final beforeRefresh = controller.value;
    expect(_saveButton(tester).onPressed, isNotNull);

    repository.failReads = true;
    container.invalidate(surgeryRecordProvider(record.id));
    container.invalidate(stepReviewsProvider(record.id));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(controller.value, beforeRefresh);
    expect(_saveButton(tester).onPressed, isNotNull);
    expect(
      tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
      surgicalStepsInDisplayOrder.indexOf(SurgicalStep.capsulorhexis),
    );
    expect(find.textContaining('入力中の内容は保持'), findsOneWidget);
    expect(find.text('再読み込み'), findsOneWidget);

    repository.failReads = false;
    await tester.runAsync(() async {
      final dataRepository = SurgeryRepository(database);
      final total = (await dataRepository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      ))!;
      await dataRepository.saveStepTiming(
        review: total.copyWith(startMilliseconds: 1200),
        expectedVideoPath: null,
      );
      container.invalidate(surgeryRecordProvider(record.id));
      container.invalidate(stepReviewsProvider(record.id));
    });
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(controller.value, beforeRefresh);
    expect(_saveButton(tester).onPressed, isNotNull);
    expect(find.textContaining('入力中の内容は保持'), findsNothing);
    expect(
      tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
      surgicalStepsInDisplayOrder.indexOf(SurgicalStep.capsulorhexis),
    );
    await _openTab(tester, '総手術時間');
    expect(find.text('開始時刻：0:01.2'), findsOneWidget);
  });

  testWidgets('clean中のProvider更新は最新レビューを表示と基準値へ反映する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final container = await pumpScreen(tester, database, record.id);
    await _openTab(tester, 'CCC');
    await _scrollToStepNotes(tester, SurgicalStep.capsulorhexis);
    await tester.tap(find.text('自己評価・反省点'));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final ccc = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      await repository.saveReviewContent(
        surgeryRecordId: record.id,
        reviews: <SurgicalStepReview>[
          ccc.copyWith(rating: StepRating.good, reflection: '最新の反省点'),
        ],
        caseMemo: '最新の症例メモ',
      );
      container.invalidate(surgeryRecordProvider(record.id));
      container.invalidate(stepReviewsProvider(record.id));
    });
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    final reflection = find.widgetWithText(TextField, '反省点');
    expect(tester.widget<TextField>(reflection).controller!.text, '最新の反省点');
    expect(
      tester
          .widget<DropdownButtonFormField<StepRating>>(
            find.byType(DropdownButtonFormField<StepRating>),
          )
          .initialValue,
      StepRating.good,
    );
    expect(_saveButton(tester).onPressed, isNull);

    await _openCaseMemoTab(tester);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '症例全体のメモ'))
          .controller!
          .text,
      '最新の症例メモ',
    );
    expect(_saveButton(tester).onPressed, isNull);
  });

  testWidgets('保存して閉じるは失敗時に画面とdirty入力を保持する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = _FailingReviewRepository(database);
    await pumpScreen(tester, database, record.id, repository: repository);
    await _openCaseMemoTab(tester);
    final memo = find.widgetWithText(TextField, '症例全体のメモ');
    await tester.enterText(memo, '消してはいけない入力');
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存して閉じる'));
    await tester.pumpAndSettle();

    expect(repository.saveCalls, 1);
    expect(find.byType(StepReviewScreen), findsOneWidget);
    expect(tester.widget<TextField>(memo).controller!.text, '消してはいけない入力');
    expect(_saveButton(tester).onPressed, isNotNull);
  });

  testWidgets('保存して閉じるは一括保存を1回だけ実行し成功後に閉じる', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = _CountingReviewRepository(database);
    await pumpScreen(tester, database, record.id, repository: repository);
    await _openCaseMemoTab(tester);
    await tester.enterText(find.widgetWithText(TextField, '症例全体のメモ'), '保存して戻る');
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存して閉じる'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(repository.saveCalls, 1);
    expect(find.byType(StepReviewScreen), findsNothing);
    expect(find.text('症例一覧'), findsOneWidget);
  });

  testWidgets('レビュー保存中は入力、多重保存、離脱を無効化する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = _ControlledReviewRepository(database);
    await pumpScreen(tester, database, record.id, repository: repository);
    await _openCaseMemoTab(tester);
    final memo = find.widgetWithText(TextField, '症例全体のメモ');
    await tester.enterText(memo, '保存中の入力');
    await tester.pump();
    await tester.tap(find.byKey(const Key('review-save-button')));
    await tester.runAsync(() => repository.started.future);
    await tester.pump();

    expect(repository.saveCalls, 1);
    expect(_saveButton(tester).onPressed, isNull);
    expect(tester.widget<TextField>(memo).readOnly, isTrue);
    expect(_popScope(tester).canPop, isFalse);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(StepReviewScreen), findsOneWidget);
    expect(find.text('保存していない変更があります'), findsNothing);

    repository.release.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(repository.saveCalls, 1);
    expect(_saveButton(tester).onPressed, isNull);
    expect(tester.widget<TextField>(memo).readOnly, isFalse);
    expect(_popScope(tester).canPop, isTrue);
  });

  testWidgets('症例削除を検知したら入力をread-onlyで保持する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final container = await pumpScreen(tester, database, record.id);
    await _openCaseMemoTab(tester);
    final memo = find.widgetWithText(TextField, '症例全体のメモ');
    await tester.enterText(memo, '退避すべきドラフト');
    await tester.pump();

    await tester.runAsync(() async {
      await SurgeryRepository(database).deleteRecord(record.id);
      container.invalidate(surgeryRecordProvider(record.id));
    });
    await tester.pumpAndSettle();

    expect(find.textContaining('別画面で削除'), findsOneWidget);
    expect(tester.widget<TextField>(memo).readOnly, isTrue);
    expect(tester.widget<TextField>(memo).controller!.text, '退避すべきドラフト');
    expect(find.text('ドラフトをコピー'), findsOneWidget);
    expect(find.text('破棄して一覧へ戻る'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);
  });

  testWidgets('動画がなくても時間記録なしを保存して未着手に戻せる', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    final container = await pumpScreen(tester, database, record.id);
    await tester.runAsync(
      () => container.read(
        recordProcedureTimingSnapshotProvider(record.id).future,
      ),
    );
    await _openTab(tester, 'CCC');

    final skipButton = find
        .byKey(const Key('procedure-skip-button'))
        .hitTestable();
    await tester.ensureVisible(skipButton);
    await tester.pumpAndSettle();
    await tester.tap(skipButton);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('時間記録なし'), findsOneWidget);
    expect(find.text('開始まで：時間記録なし'), findsOneWidget);
    late SurgicalStepReview skipped;
    late SurgeryRecord savedRecord;
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      skipped = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      savedRecord = (await repository.getRecord(record.id))!;
    });
    expect(skipped.recordingStatus, StepRecordingStatus.skipped);
    expect(skipped.startMilliseconds, isNull);
    expect(skipped.endMilliseconds, isNull);
    expect(savedRecord.reviewSchemaVersion, 1);
    expect(savedRecord.reviewStatus, ReviewStatus.reviewed);
    late RecordProcedureTimingSnapshot detailSnapshot;
    await tester.runAsync(() async {
      detailSnapshot = await container.read(
        recordProcedureTimingSnapshotProvider(record.id).future,
      );
    });
    expect(
      detailSnapshot.reviewFor(SurgicalStep.capsulorhexis)?.recordingStatus,
      StepRecordingStatus.skipped,
    );

    final resetButton = find
        .byKey(const Key('procedure-reset-button'))
        .hitTestable();
    await tester.ensureVisible(resetButton);
    await tester.pumpAndSettle();
    await tester.tap(resetButton);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    late SurgicalStepReview restored;
    await tester.runAsync(() async {
      restored = (await SurgeryRepository(database).getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
    });
    expect(restored.recordingStatus, StepRecordingStatus.unprocessed);
    expect(restored.isSkipped, isFalse);
    expect(find.text('時間記録なし'), findsNothing);
    expect(find.text('開始まで：未登録'), findsOneWidget);
    expect(
      find.byKey(const Key('procedure-start-button')).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('入力中の時刻を時間記録なしにする前に確認し、確定時だけ時刻を削除する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final ccc = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      await repository.saveStepTiming(
        review: ccc.copyWith(startMilliseconds: 1000),
        expectedVideoPath: null,
      );
    });

    await pumpScreen(tester, database, record.id);
    await _openTab(tester, 'CCC');
    final skipButton = find.byKey(const Key('procedure-skip-button'));
    await tester.dragUntilVisible(
      skipButton,
      find.byKey(const ValueKey('review-step-content-capsulorhexis')),
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();
    expect(skipButton.hitTestable(), findsOneWidget);
    await tester.tap(skipButton);
    await tester.pumpAndSettle();

    expect(find.text('時間記録なしにする'), findsNWidgets(2));
    expect(find.text('入力中の時刻を削除して、この工程を「時間記録なし」にしますか？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'キャンセル'));
    await tester.pumpAndSettle();

    late SurgicalStepReview afterCancel;
    await tester.runAsync(() async {
      afterCancel = (await SurgeryRepository(database).getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
    });
    expect(afterCancel.startMilliseconds, 1000);
    expect(afterCancel.isSkipped, isFalse);

    await tester.tap(skipButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '時間記録なしにする'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    late SurgicalStepReview committed;
    await tester.runAsync(() async {
      committed = (await SurgeryRepository(database).getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
    });
    expect(committed.recordingStatus, StepRecordingStatus.skipped);
    expect(committed.startMilliseconds, isNull);
    expect(committed.endMilliseconds, isNull);
  });

  testWidgets('時間記録なしの保存失敗時は表示とDBを未着手のまま保つ', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = _FailingSkippedRepository(database);

    await pumpScreen(tester, database, record.id, repository: repository);
    await _openTab(tester, 'CCC');
    final skipButton = find
        .byKey(const Key('procedure-skip-button'))
        .hitTestable();
    await tester.ensureVisible(skipButton);
    await tester.pumpAndSettle();
    await tester.tap(skipButton);
    await tester.pumpAndSettle();

    expect(repository.saveCalls, 1);
    expect(find.text('工程状態を保存できませんでした。もう一度お試しください。'), findsOneWidget);
    expect(find.text('時間記録なし'), findsNothing);
    expect(find.text('開始まで：未登録'), findsOneWidget);

    late SurgicalStepReview persisted;
    await tester.runAsync(() async {
      persisted = (await SurgeryRepository(database).getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
    });
    expect(persisted.recordingStatus, StepRecordingStatus.unprocessed);
    expect(persisted.isSkipped, isFalse);
  });

  testWidgets('skip保存中の動画参照競合でskippedにせず最新工程を再読込する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final oldPath = 'videos/${record.id}/old.mp4';
    final newPath = 'videos/${record.id}/new.mp4';
    await tester.runAsync(() async {
      await SurgeryRepository(database).updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: oldPath,
        videoDisplayName: 'old.mp4',
      );
    });
    final repository = _ControlledSkippedRepository(database);

    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      videoStorageRepository: const _ReviewStateVideoStorage(),
    );
    await _openTab(tester, 'CCC');
    final skipButton = find
        .byKey(const Key('procedure-skip-button'))
        .hitTestable();
    await tester.ensureVisible(skipButton);
    await tester.pumpAndSettle();
    await tester.tap(skipButton);
    await tester.runAsync(() => repository.started.future);
    await tester.pump();

    await tester.runAsync(() async {
      final concurrentRepository = SurgeryRepository(database);
      await concurrentRepository.updateVideoReferenceIfCurrent(
        surgeryRecordId: record.id,
        expectedVideoPath: oldPath,
        videoPath: newPath,
        videoDisplayName: 'new.mp4',
      );
      final latest = (await concurrentRepository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      await concurrentRepository.saveStepTiming(
        review: latest.copyWith(startMilliseconds: 1200),
        expectedVideoPath: newPath,
      );
    });
    repository.release.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(repository.saveCalls, 1);
    expect(
      find.text('動画が変更されたため工程状態を保存しませんでした。最新状態を再確認してください。'),
      findsOneWidget,
    );
    expect(find.text('時間記録なし'), findsNothing);
    final timingCard = tester.widget<ProcedureTimingCard>(
      find.byType(ProcedureTimingCard),
    );
    expect(timingCard.timing.recordingStatus, StepRecordingStatus.unprocessed);
    expect(timingCard.timing.startMilliseconds, 1200);
    expect(timingCard.timing.isRunning, isTrue);
    expect(find.text('開始時刻：0:01.2'), findsOneWidget);

    late SurgeryRecord latestRecord;
    late SurgicalStepReview latestReview;
    await tester.runAsync(() async {
      final dataRepository = SurgeryRepository(database);
      latestRecord = (await dataRepository.getRecord(record.id))!;
      latestReview = (await dataRepository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
    });
    expect(latestRecord.videoPath, newPath);
    expect(latestReview.startMilliseconds, 1200);
    expect(latestReview.isSkipped, isFalse);
  });

  for (final videoKind in const <RecordVideoStateKind>[
    RecordVideoStateKind.missing,
    RecordVideoStateKind.invalidReference,
    RecordVideoStateKind.checkFailed,
  ]) {
    testWidgets('動画${videoKind.name}でもskipとskipped再設定を保存できる', (tester) async {
      final (database, record) = await createRecord(tester);
      addTearDown(database.close);
      final videoPath = videoKind == RecordVideoStateKind.invalidReference
          ? '../invalid.mp4'
          : 'videos/${record.id}/${videoKind.name}.mp4';
      await tester.runAsync(() async {
        await SurgeryRepository(database).updateVideoReference(
          surgeryRecordId: record.id,
          videoPath: videoPath,
          videoDisplayName: '${videoKind.name}.mp4',
        );
      });
      final storage = videoKind == RecordVideoStateKind.checkFailed
          ? const _ReviewStateVideoStorage(
              resolveError: FileSystemException('制御可能な確認失敗'),
            )
          : const _ReviewStateVideoStorage();

      await pumpScreen(
        tester,
        database,
        record.id,
        videoStorageRepository: storage,
      );
      expect(switch (videoKind) {
        RecordVideoStateKind.missing => find.textContaining('動画の実体が見つかりません'),
        RecordVideoStateKind.invalidReference => find.textContaining('動画参照が不正'),
        RecordVideoStateKind.checkFailed => find.textContaining(
          '動画を確認できませんでした',
        ),
        _ => throw StateError('対象外の動画状態です。'),
      }, findsOneWidget);

      await _openTab(tester, 'CCC');
      final skipButton = find
          .byKey(const Key('procedure-skip-button'))
          .hitTestable();
      await tester.ensureVisible(skipButton);
      await tester.pumpAndSettle();
      expect(tester.widget<TextButton>(skipButton).onPressed, isNotNull);
      await tester.tap(skipButton);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      expect(find.text('時間記録なし'), findsOneWidget);
      final resetButton = find
          .byKey(const Key('procedure-reset-button'))
          .hitTestable();
      await tester.ensureVisible(resetButton);
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(resetButton).onPressed, isNotNull);
      await tester.tap(resetButton);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      late SurgicalStepReview persisted;
      await tester.runAsync(() async {
        persisted = (await SurgeryRepository(database).getStepReview(
          surgeryRecordId: record.id,
          step: SurgicalStep.capsulorhexis,
        ))!;
      });
      expect(persisted.recordingStatus, StepRecordingStatus.unprocessed);
      expect(persisted.isSkipped, isFalse);
      expect(find.text('時間記録なし'), findsNothing);
      expect(
        find.byKey(const Key('procedure-start-button')).hitTestable(),
        findsOneWidget,
      );
    });
  }

  for (var index = 0; index < activeIndividualSurgicalSteps.length; index++) {
    final step = activeIndividualSurgicalSteps[index];
    testWidgets('直接ジャンプは${step.label}を選び保存済みmsへ一度だけpaused seekする', (
      tester,
    ) async {
      final (database, record) = await createRecord(tester);
      addTearDown(database.close);
      final startMilliseconds = index == 0 ? 0 : 1234 + (index * 1000);
      await _configureDirectJumpRecord(
        tester,
        database,
        record.id,
        step: step,
        startMilliseconds: startMilliseconds,
      );
      final videoPlatform = _installDirectJumpVideoPlatform(
        _DirectJumpVideoPlatform(),
      );

      final container = await pumpScreen(
        tester,
        database,
        record.id,
        initialStepStorageId: step.storageId,
        videoStorageRepository: _ReviewStateVideoStorage(
          resolvedFile: File('/tmp/direct-jump-$index.mp4'),
        ),
      );

      final timingCard = tester.widget<ProcedureTimingCard>(
        find.byType(ProcedureTimingCard),
      );
      expect(timingCard.step, step);
      final tabBarRect = tester.getRect(find.byType(TabBar));
      final selectedTabLabel = find.descendant(
        of: find.byType(TabBar),
        matching: find.text(step.label),
      );
      expect(selectedTabLabel, findsOneWidget);
      final selectedTabLabelRect = tester.getRect(selectedTabLabel);
      expect(
        selectedTabLabelRect.left,
        greaterThanOrEqualTo(tabBarRect.left - 0.5),
      );
      expect(
        selectedTabLabelRect.right,
        lessThanOrEqualTo(tabBarRect.right + 0.5),
      );
      expect(videoPlatform.seekRequests, <Duration>[
        Duration(milliseconds: startMilliseconds),
      ]);
      expect(videoPlatform.pauseCount, greaterThanOrEqualTo(1));
      expect(videoPlatform.playCount, 0);
      expect(videoPlatform.createCount, 1);
      expect(_saveButton(tester).onPressed, isNull);
      expect(_popScope(tester).canPop, isTrue);

      container.invalidate(surgeryRecordProvider(record.id));
      container.invalidate(stepReviewsProvider(record.id));
      await _pumpAsyncWork(tester);
      await tester.pumpAndSettle();

      expect(videoPlatform.seekRequests, hasLength(1));
      expect(videoPlatform.createCount, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('同一症例のCCCとI/Aは各工程の異なる保存位置を開く', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final path = 'videos/${record.id}/same-record-multiple-steps.mp4';
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      await repository.ensureStepReviews(record.id);
      await repository.updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: path,
        videoDisplayName: 'same-record-multiple-steps.mp4',
      );
      final ccc = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      await repository.saveStepTiming(
        review: ccc.copyWith(startMilliseconds: 2100, endMilliseconds: 3100),
        expectedVideoPath: path,
      );
      final irrigationAspiration = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.corticalIrrigationAspiration,
      ))!;
      await repository.saveStepTiming(
        review: irrigationAspiration.copyWith(
          startMilliseconds: 9100,
          endMilliseconds: 10100,
        ),
        expectedVideoPath: path,
      );
    });
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );
    final storage = _ReviewStateVideoStorage(
      resolvedFile: File('/tmp/same-record-multiple-steps.mp4'),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: storage,
    );
    expect(
      tester.widget<ProcedureTimingCard>(find.byType(ProcedureTimingCard)).step,
      SurgicalStep.capsulorhexis,
    );
    expect(videoPlatform.seekRequests, <Duration>[
      const Duration(milliseconds: 2100),
    ]);

    // Model the real route lifecycle: the first review screen is popped before
    // the same record is opened for a different stable step id.
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpUntil(tester, () => videoPlatform.activePlayerIds.isEmpty);

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.corticalIrrigationAspiration.storageId,
      videoStorageRepository: storage,
    );
    expect(
      tester.widget<ProcedureTimingCard>(find.byType(ProcedureTimingCard)).step,
      SurgicalStep.corticalIrrigationAspiration,
    );
    expect(videoPlatform.seekRequests, <Duration>[
      const Duration(milliseconds: 2100),
      const Duration(milliseconds: 9100),
    ]);
    expect(videoPlatform.createCount, 2);
    expect(videoPlatform.activePlayerIds, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('通常導線は既存の最初の未完了タブを選び初期seekしない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final path = 'videos/${record.id}/normal-route.mp4';
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final reviews = await repository.ensureStepReviews(record.id);
      await repository.updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: path,
        videoDisplayName: 'normal-route.mp4',
      );
      final total = reviews.singleWhere(
        (review) => review.step == SurgicalStep.totalSurgeryTime,
      );
      await repository.saveStepTiming(
        review: total.copyWith(startMilliseconds: 100, endMilliseconds: 900),
        expectedVideoPath: path,
      );
      final sidePort = reviews.singleWhere(
        (review) => review.step == SurgicalStep.sidePortCreation,
      );
      await repository.saveStepSkipped(
        review: sidePort,
        isSkipped: true,
        expectedVideoPath: path,
      );
    });
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/normal-route.mp4'),
      ),
    );

    expect(
      tester.widget<ProcedureTimingCard>(find.byType(ProcedureTimingCard)).step,
      SurgicalStep.ovdInjection,
    );
    expect(videoPlatform.seekRequests, isEmpty);
    expect(videoPlatform.createCount, 1);
  });

  testWidgets('通常導線で全工程完了済みなら総手術時間タブを保ち初期seekしない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureRichDirectJumpRecord(tester, database, record.id);
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/normal-route-all-processed.mp4'),
      ),
    );

    expect(
      tester.widget<ProcedureTimingCard>(find.byType(ProcedureTimingCard)).step,
      SurgicalStep.totalSurgeryTime,
    );
    expect(videoPlatform.seekRequests, isEmpty);
    expect(videoPlatform.createCount, 1);
    expect(tester.takeException(), isNull);
  });

  for (final persistenceCase
      in const <
        ({
          String label,
          Duration duration,
          bool failInitialization,
          bool failSeek,
          int expectedSeekCount,
        })
      >[
        (
          label: '正常direct',
          duration: Duration(minutes: 2),
          failInitialization: false,
          failSeek: false,
          expectedSeekCount: 1,
        ),
        (
          label: '範囲外',
          duration: Duration(seconds: 4),
          failInitialization: false,
          failSeek: false,
          expectedSeekCount: 0,
        ),
        (
          label: '初期化失敗',
          duration: Duration(minutes: 2),
          failInitialization: true,
          failSeek: false,
          expectedSeekCount: 0,
        ),
        (
          label: 'seek失敗',
          duration: Duration(minutes: 2),
          failInitialization: false,
          failSeek: true,
          expectedSeekCount: 1,
        ),
      ]) {
    testWidgets('${persistenceCase.label}の前後で症例と全工程の永続データを変更しない', (
      tester,
    ) async {
      final (database, record) = await createRecord(tester);
      addTearDown(database.close);
      final targetStart = await _configureRichDirectJumpRecord(
        tester,
        database,
        record.id,
      );
      final before = await _capturePersistentReviewSnapshot(
        tester,
        database,
        record.id,
      );
      final videoPlatform = _installDirectJumpVideoPlatform(
        _DirectJumpVideoPlatform(
          duration: persistenceCase.duration,
          failingPlayerIds: persistenceCase.failInitialization
              ? const <int>{1}
              : const <int>{},
          failSeek: persistenceCase.failSeek,
        ),
      );

      await pumpScreen(
        tester,
        database,
        record.id,
        initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
        videoStorageRepository: _ReviewStateVideoStorage(
          resolvedFile: File('/tmp/persistence-${persistenceCase.label}.mp4'),
        ),
      );

      final after = await _capturePersistentReviewSnapshot(
        tester,
        database,
        record.id,
      );
      expect(after, equals(before));
      expect(
        videoPlatform.seekRequests,
        hasLength(persistenceCase.expectedSeekCount),
      );
      if (persistenceCase.expectedSeekCount == 1) {
        expect(videoPlatform.seekRequests.single.inMilliseconds, targetStart);
      }
      expect(_saveButton(tester).onPressed, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('旧DBの欠落工程は遷移前fresh readで作らずStepReviewを開いた後だけ補完する', (
    tester,
  ) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    late Map<String, Object?> recordBefore;
    late Map<String, Object?> cccBefore;
    await tester.runAsync(() async {
      await repository.updateCaseMemo(
        surgeryRecordId: record.id,
        caseMemo: '旧DBの症例メモ',
      );
      final ccc = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      final timed = await repository.saveStepTiming(
        review: ccc.copyWith(startMilliseconds: 1200, endMilliseconds: 2400),
        expectedVideoPath: null,
      );
      await repository.saveReviewContent(
        surgeryRecordId: record.id,
        reviews: <SurgicalStepReview>[
          timed.copyWith(
            rating: StepRating.needsImprovement,
            reflection: '旧DBで保持するCCCの反省',
          ),
        ],
        caseMemo: '旧DBの症例メモ',
      );
      recordBefore = _persistentRecordFields(
        (await repository.getRecord(record.id))!,
      );
      cccBefore = _persistentReviewFields(
        (await repository.getStepReview(
          surgeryRecordId: record.id,
          step: SurgicalStep.capsulorhexis,
        ))!,
      );
    });
    expect(await _countPersistedStepRows(tester, database, record.id), 1);

    // These are the read-only calls used before accepting a graph jump.
    await tester.runAsync(() async {
      final analysis = await repository.fetchAnalysisSnapshot();
      expect(analysis.measurements, hasLength(1));
      expect((await repository.getRecord(record.id))?.id, record.id);
      expect(
        await repository.getStepReview(
          surgeryRecordId: record.id,
          step: SurgicalStep.capsulorhexis,
        ),
        isNotNull,
      );
    });
    expect(await _countPersistedStepRows(tester, database, record.id), 1);

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
    );

    expect(
      await _countPersistedStepRows(tester, database, record.id),
      surgicalStepsInDisplayOrder.length,
    );
    late Map<String, Object?> recordAfter;
    late Map<String, Object?> cccAfter;
    await tester.runAsync(() async {
      recordAfter = _persistentRecordFields(
        (await repository.getRecord(record.id))!,
      );
      cccAfter = _persistentReviewFields(
        (await repository.getStepReview(
          surgeryRecordId: record.id,
          step: SurgicalStep.capsulorhexis,
        ))!,
      );
    });
    expect(recordAfter, equals(recordBefore));
    expect(cccAfter, equals(cccBefore));
    expect(tester.takeException(), isNull);
  });

  for (final videoBeforeDraft in const <bool>[false, true]) {
    testWidgets(
      'direct fresh read後に${videoBeforeDraft ? 'video init→draft同期' : 'draft同期→video init'}の全条件成立後だけ1回seekする',
      (tester) async {
        final (database, record) = await createRecord(tester);
        addTearDown(database.close);
        await _configureDirectJumpRecord(
          tester,
          database,
          record.id,
          step: SurgicalStep.capsulorhexis,
          startMilliseconds: 4321,
        );
        final repository = _DirectJumpOrderingRepository(database);
        final initializationGate = Completer<void>();
        final videoPlatform = _installDirectJumpVideoPlatform(
          _DirectJumpVideoPlatform(initializationGate: initializationGate),
        );

        await pumpScreen(
          tester,
          database,
          record.id,
          repository: repository,
          initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
          videoStorageRepository: _ReviewStateVideoStorage(
            resolvedFile: File(
              '/tmp/direct-order-${videoBeforeDraft ? 'video-first' : 'draft-first'}.mp4',
            ),
          ),
          settle: false,
        );
        await _pumpUntil(
          tester,
          () => repository.firstFreshRecordReadStarted.isCompleted,
        );
        expect(repository.initialFreshReadsCompleted.isCompleted, isFalse);
        expect(repository.draftReviewsReadStarted.isCompleted, isFalse);
        expect(videoPlatform.createCount, 0);
        expect(videoPlatform.seekRequests, isEmpty);

        repository.releaseFirstFreshRecordRead.complete();
        await _pumpUntil(
          tester,
          () =>
              repository.initialFreshReadsCompleted.isCompleted &&
              repository.draftReviewsReadStarted.isCompleted &&
              videoPlatform.createCount == 1,
          maximumPumps: 100,
        );
        expect(videoPlatform.seekRequests, isEmpty);

        if (videoBeforeDraft) {
          initializationGate.complete();
          await _pumpUntil(
            tester,
            () => videoPlatform.initializedPlayerIds.contains(1),
          );
          expect(find.byType(ProcedureTimingCard), findsNothing);
          expect(videoPlatform.seekRequests, isEmpty);
          repository.releaseDraftReviewsRead.complete();
        } else {
          repository.releaseDraftReviewsRead.complete();
          await _pumpUntil(
            tester,
            () => find.byType(ProcedureTimingCard).evaluate().isNotEmpty,
          );
          expect(videoPlatform.initializedPlayerIds, isEmpty);
          expect(videoPlatform.seekRequests, isEmpty);
          initializationGate.complete();
        }

        await _pumpUntil(tester, () => videoPlatform.seekRequests.length == 1);
        expect(videoPlatform.seekRequests, <Duration>[
          const Duration(milliseconds: 4321),
        ]);
        expect(videoPlatform.pauseCount, greaterThanOrEqualTo(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final rangeCase in const <({Duration duration, int start})>[
    (duration: Duration(seconds: 10), start: 10000),
    (duration: Duration(seconds: 10), start: 9223372036854775806),
    (duration: Duration(seconds: 10), start: 9223372036854775807),
    (duration: Duration.zero, start: 0),
  ]) {
    testWidgets(
      '範囲外${rangeCase.start}ms／${rangeCase.duration.inMilliseconds}msはseekへ渡さない',
      (tester) async {
        final (database, record) = await createRecord(tester);
        addTearDown(database.close);
        await _configureDirectJumpRecord(
          tester,
          database,
          record.id,
          step: SurgicalStep.capsulorhexis,
          startMilliseconds: rangeCase.start,
        );
        final videoPlatform = _installDirectJumpVideoPlatform(
          _DirectJumpVideoPlatform(duration: rangeCase.duration),
        );

        await pumpScreen(
          tester,
          database,
          record.id,
          initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
          videoStorageRepository: _ReviewStateVideoStorage(
            resolvedFile: File('/tmp/range-${rangeCase.start}.mp4'),
          ),
        );

        expect(videoPlatform.seekRequests, isEmpty);
        expect(find.textContaining('記録位置が動画の範囲外'), findsOneWidget);
        expect(_saveButton(tester).onPressed, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('初期化eventで動画長を取得不能ならpendingを終了しseekしない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 1200,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(duration: null),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/unavailable-duration.mp4'),
      ),
    );

    expect(videoPlatform.createCount, 1);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('動画の長さを取得できないため'), findsOneWidget);
    expect(find.textContaining('動画の長さを取得できませんでした'), findsOneWidget);
    expect(find.text('動画を再確認'), findsWidgets);
    expect(find.textContaining('CCCを開いています'), findsNothing);
    expect(find.byKey(const Key('review-video-player')), findsNothing);

    container.invalidate(surgeryRecordProvider(record.id));
    container.invalidate(stepReviewsProvider(record.id));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpAsyncWork(tester);
    expect(videoPlatform.createCount, 1);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('CCCを開いています'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final invalidStart in const <int?>[null, -1, -9223372036854775808]) {
    testWidgets('開始位置${invalidStart ?? 'null'}は動画resolverとcontrollerを起動しない', (
      tester,
    ) async {
      final (database, record) = await createRecord(tester);
      addTearDown(database.close);
      final path = 'videos/${record.id}/invalid-start.mp4';
      await tester.runAsync(() async {
        final repository = SurgeryRepository(database);
        await repository.ensureStepReviews(record.id);
        await repository.updateVideoReference(
          surgeryRecordId: record.id,
          videoPath: path,
          videoDisplayName: 'invalid-start.mp4',
        );
        if (invalidStart != null) {
          await database.customStatement(
            '''
UPDATE surgical_step_reviews
SET start_milliseconds = ?
WHERE surgery_record_id = ? AND step = ?
''',
            <Object?>[
              invalidStart,
              record.id,
              SurgicalStep.capsulorhexis.storageId,
            ],
          );
        }
      });
      final storage = _CountingResolvedVideoStorage(
        File('/tmp/invalid-start.mp4'),
      );
      final videoPlatform = _installDirectJumpVideoPlatform(
        _DirectJumpVideoPlatform(),
      );

      await pumpScreen(
        tester,
        database,
        record.id,
        initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
        videoStorageRepository: storage,
      );

      expect(storage.resolveCalls, 0);
      expect(videoPlatform.createCount, 0);
      expect(videoPlatform.seekRequests, isEmpty);
      expect(
        find.textContaining(
          invalidStart == null ? '工程の記録位置が削除' : '記録位置が動画の範囲外',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final invalidStart in const <int?>[null, -1]) {
    testWidgets('開始位置${invalidStart ?? 'null'}は明示再確認後だけ通常動画を復旧し自動seekしない', (
      tester,
    ) async {
      final (database, record) = await createRecord(tester);
      addTearDown(database.close);
      final path = 'videos/${record.id}/invalid-start-recovery.mp4';
      await tester.runAsync(() async {
        final repository = SurgeryRepository(database);
        await repository.ensureStepReviews(record.id);
        await repository.updateVideoReference(
          surgeryRecordId: record.id,
          videoPath: path,
          videoDisplayName: 'invalid-start-recovery.mp4',
        );
        if (invalidStart != null) {
          await database.customStatement(
            '''
UPDATE surgical_step_reviews
SET start_milliseconds = ?
WHERE surgery_record_id = ? AND step = ?
''',
            <Object?>[
              invalidStart,
              record.id,
              SurgicalStep.capsulorhexis.storageId,
            ],
          );
        }
      });
      final storage = _CountingResolvedVideoStorage(
        File('/tmp/invalid-start-recovery.mp4'),
      );
      final videoPlatform = _installDirectJumpVideoPlatform(
        _DirectJumpVideoPlatform(),
      );

      await pumpScreen(
        tester,
        database,
        record.id,
        initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
        videoStorageRepository: storage,
      );

      expect(storage.resolveCalls, 0);
      expect(videoPlatform.createCount, 0);
      expect(videoPlatform.seekRequests, isEmpty);
      expect(
        find.textContaining(
          invalidStart == null ? '工程の記録位置が削除' : '記録位置が動画の範囲外',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('動画を再確認').first);
      await _pumpUntil(
        tester,
        () =>
            videoPlatform.createCount == 1 &&
            find.byType(VideoTransportControls).evaluate().isNotEmpty,
      );

      expect(storage.resolveCalls, greaterThanOrEqualTo(1));
      expect(videoPlatform.seekRequests, isEmpty);
      expect(find.byKey(const Key('review-video-player')), findsOneWidget);
      final timingCard = tester.widget<ProcedureTimingCard>(
        find.byType(ProcedureTimingCard),
      );
      expect(timingCard.onStart, isNotNull);
      expect(timingCard.onEnd, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('アニメーション無効・文字倍率2.0では準備中を静的表示する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final semantics = tester.ensureSemantics();
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 1800,
    );
    final initializationGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(initializationGate: initializationGate),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/static-preparing.mp4'),
      ),
      mediaQueryData: const MediaQueryData(
        size: Size(320, 568),
        textScaler: TextScaler.linear(2),
        disableAnimations: true,
      ),
      settle: false,
    );
    await _pumpUntil(
      tester,
      () =>
          videoPlatform.createCount == 1 &&
          find
              .byKey(const Key('direct-jump-static-progress'))
              .evaluate()
              .isNotEmpty,
    );

    expect(find.textContaining('CCCを開いています'), findsWidgets);
    final preparingAnnouncement = find.bySemanticsLabel('CCCを開いています');
    expect(preparingAnnouncement, findsOneWidget);
    expect(tester.getSemantics(preparingAnnouncement).label, 'CCCを開いています');
    expect(
      find.byKey(const Key('direct-jump-static-progress')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('direct-jump-animated-progress')),
      findsNothing,
    );
    expect(videoPlatform.seekRequests, isEmpty);
    expect(tester.takeException(), isNull);

    initializationGate.complete();
    await _pumpAsyncWork(tester);
    semantics.dispose();
  });

  testWidgets('直接ジャンプ準備中はreset・skip・動画ヘルプを無効にする', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 1900,
    );
    final initializationGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(initializationGate: initializationGate),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/disabled-while-preparing.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(
      tester,
      () =>
          videoPlatform.createCount == 1 &&
          find.byType(ProcedureTimingCard).evaluate().isNotEmpty,
    );

    final timingCard = tester.widget<ProcedureTimingCard>(
      find.byType(ProcedureTimingCard),
    );
    expect(timingCard.onReset, isNull);
    expect(timingCard.onSkip, isNull);
    final helpButton = tester.widget<IconButton>(
      find
          .ancestor(
            of: find.byTooltip('再登録できる動画の目安'),
            matching: find.byType(IconButton),
          )
          .first,
    );
    expect(helpButton.onPressed, isNull);
    expect(videoPlatform.seekRequests, isEmpty);

    initializationGate.complete();
    await _pumpAsyncWork(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('controller初期化後の最終validation中は全動画・時刻操作を無効にする', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 1950,
    );
    final repository = _ControlledFinalReviewReadRepository(
      database,
      targetStep: SurgicalStep.capsulorhexis,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/disabled-during-final-validation.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => repository.finalReadStarted.isCompleted);

    expect(videoPlatform.createCount, 1);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(
      tester
          .widget<Slider>(find.byKey(const Key('review-video-slider')))
          .onChanged,
      isNull,
    );
    final controls = tester.widget<VideoTransportControls>(
      find.byType(VideoTransportControls),
    );
    expect(controls.onTogglePlayback, isNull);
    expect(controls.onSeekBackward5, isNull);
    expect(controls.onSeekForward5, isNull);
    expect(controls.onSeekBackward15, isNull);
    expect(controls.onSeekForward15, isNull);
    final timingCard = tester.widget<ProcedureTimingCard>(
      find.byType(ProcedureTimingCard),
    );
    expect(timingCard.onReset, isNull);
    expect(timingCard.onSkip, isNull);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('procedure-skip-button')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find
                .ancestor(
                  of: find.byTooltip('再登録できる動画の目安'),
                  matching: find.byType(IconButton),
                )
                .first,
          )
          .onPressed,
      isNull,
    );

    repository.releaseFinalRead.complete();
    await _pumpAsyncWork(tester);
    expect(videoPlatform.seekRequests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final firstReadFails in <bool>[false, true]) {
    testWidgets(
      '初期prepareの${firstReadFails ? '例外' : 'data'}を非currentへ反映せず復帰後に通常表示する',
      (tester) async {
        final (database, record) = await createRecord(tester);
        addTearDown(database.close);
        await _configureDirectJumpRecord(
          tester,
          database,
          record.id,
          step: SurgicalStep.capsulorhexis,
          startMilliseconds: 1975,
        );
        final repository = _ControlledInitialRecordReadRepository(
          database,
          firstReadError: firstReadFails
              ? StateError('制御可能な初期prepare read失敗')
              : null,
        );
        final resolvedFile = File(
          '/tmp/inactive-initial-prepare-${firstReadFails ? 'error' : 'data'}.mp4',
        );
        final videoPlatform = _installDirectJumpVideoPlatform(
          _DirectJumpVideoPlatform(),
        );

        await pumpScreen(
          tester,
          database,
          record.id,
          repository: repository,
          initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
          videoStorageRepository: _ReviewStateVideoStorage(
            resolvedFile: resolvedFile,
          ),
          settle: false,
        );
        await _pumpUntil(tester, () => repository.firstReadStarted.isCompleted);

        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        final foregroundRoute = navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('初期prepare中の前面画面')),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        repository.releaseFirstRead.complete();
        await _pumpAsyncWork(tester);

        expect(videoPlatform.createCount, 0);
        expect(videoPlatform.seekRequests, isEmpty);
        navigator.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await foregroundRoute;
        await _pumpUntil(
          tester,
          () => find.byType(ProcedureTimingCard).evaluate().isNotEmpty,
        );

        expect(find.textContaining('別の画面が開かれたため'), findsOneWidget);
        expect(
          find.byKey(const Key('direct-jump-preparing-notice')),
          findsNothing,
        );
        expect(videoPlatform.createCount, 0);
        expect(videoPlatform.seekRequests, isEmpty);
        await tester.tap(find.text('動画を再確認'));
        await _pumpUntil(tester, () => videoPlatform.createCount == 1);
        expect(videoPlatform.seekRequests, isEmpty);
        expect(find.textContaining('開始位置へ移動しました'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('still-mountedだが非currentのrouteではseekと成功通知を行わない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 2000,
    );
    final initializationGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(initializationGate: initializationGate),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/inactive-route.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => videoPlatform.createCount == 1);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('前面の画面')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('前面の画面'), findsOneWidget);
    expect(find.byType(StepReviewScreen), findsOneWidget);

    initializationGate.complete();
    await _pumpAsyncWork(tester);

    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('別の画面が開かれたため'), findsOneWidget);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('duration取得不能がroute pushと同一frameで完了しても非currentへ反映しない', (
    tester,
  ) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 2025,
    );
    final initializationGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(
        duration: null,
        initializationGate: initializationGate,
      ),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/inactive-route-null-duration.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => videoPlatform.createCount == 1);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final foreground = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('duration完了前の前面画面')),
    );
    final foregroundRoute = navigator.push<void>(foreground);
    expect(foreground.isCurrent, isTrue);
    initializationGate.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );

    expect(videoPlatform.seekRequests, isEmpty);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('duration完了前の前面画面'), findsOneWidget);
    await _pumpUntil(tester, () => videoPlatform.activePlayerIds.isEmpty);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await foregroundRoute;

    expect(find.textContaining('別の画面が開かれたため'), findsOneWidget);
    expect(find.textContaining('動画の長さを取得できませんでした'), findsNothing);
    expect(videoPlatform.activePlayerIds, isEmpty);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('initialize errorがroute pushと同一frameで完了しても非currentへ反映しない', (
    tester,
  ) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 2050,
    );
    final initializationGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(
        failingPlayerIds: const <int>{1},
        initializationGate: initializationGate,
      ),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/inactive-route-initialize-error.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => videoPlatform.createCount == 1);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final foreground = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('initialize完了前の前面画面')),
    );
    final foregroundRoute = navigator.push<void>(foreground);
    expect(foreground.isCurrent, isTrue);
    initializationGate.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );

    expect(videoPlatform.seekRequests, isEmpty);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('initialize完了前の前面画面'), findsOneWidget);
    await _pumpUntil(tester, () => videoPlatform.activePlayerIds.isEmpty);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await foregroundRoute;

    expect(find.textContaining('別の画面が開かれたため'), findsOneWidget);
    expect(find.textContaining('動画を再生できませんでした'), findsNothing);
    expect(find.textContaining('動画の再生中にエラー'), findsNothing);
    expect(videoPlatform.activePlayerIds, isEmpty);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('runtime errorがroute pushと同一frameで完了しても非currentへ反映しない', (
    tester,
  ) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 2075,
    );
    final repository = _ControlledFinalReviewReadRepository(
      database,
      targetStep: SurgicalStep.capsulorhexis,
    );
    final runtimeErrorGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(runtimeErrorGate: runtimeErrorGate),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/inactive-route-runtime-error.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => repository.finalReadStarted.isCompleted);
    expect(videoPlatform.seekRequests, isEmpty);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final foreground = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('runtime error前の前面画面')),
    );
    final foregroundRoute = navigator.push<void>(foreground);
    expect(foreground.isCurrent, isTrue);
    runtimeErrorGate.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    repository.releaseFinalRead.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );

    expect(videoPlatform.seekRequests, isEmpty);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('runtime error前の前面画面'), findsOneWidget);
    await _pumpUntil(tester, () => videoPlatform.activePlayerIds.isEmpty);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await foregroundRoute;

    expect(find.textContaining('別の画面が開かれたため'), findsOneWidget);
    expect(find.textContaining('動画の再生中にエラー'), findsNothing);
    expect(find.textContaining('動画を準備できませんでした'), findsNothing);
    expect(videoPlatform.activePlayerIds, isEmpty);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('seek待機中のruntime errorがroute pushと同一frameで完了しても状態を反映しない', (
    tester,
  ) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 2090,
    );
    final runtimeErrorGate = Completer<void>();
    final seekGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(
        runtimeErrorGate: runtimeErrorGate,
        seekGate: seekGate,
      ),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/inactive-route-runtime-error-during-seek.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => videoPlatform.seekRequests.isNotEmpty);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final foreground = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('seek待機中の前面画面')),
    );
    final foregroundRoute = navigator.push<void>(foreground);
    expect(foreground.isCurrent, isTrue);
    runtimeErrorGate.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    seekGate.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );

    expect(videoPlatform.seekRequests, hasLength(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('seek待機中の前面画面'), findsOneWidget);
    await _pumpUntil(tester, () => videoPlatform.activePlayerIds.isEmpty);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await foregroundRoute;

    expect(find.textContaining('完了結果を破棄'), findsOneWidget);
    expect(find.textContaining('開始位置へ移動できませんでした'), findsNothing);
    expect(find.textContaining('動画を再生できない状態'), findsNothing);
    expect(videoPlatform.activePlayerIds, isEmpty);
    expect(videoPlatform.seekRequests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('seek完了後のruntime errorは非current中に反映せずroute復帰後に回復UIを表示する', (
    tester,
  ) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 2095,
    );
    final runtimeErrorGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(runtimeErrorGate: runtimeErrorGate),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/inactive-route-runtime-error-after-seek.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(
      tester,
      () =>
          videoPlatform.seekRequests.length == 1 &&
          find.textContaining('開始位置へ移動しました').evaluate().isNotEmpty,
    );

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final foreground = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('seek完了後の前面画面')),
    );
    final foregroundRoute = navigator.push<void>(foreground);
    expect(foreground.isCurrent, isTrue);
    runtimeErrorGate.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('seek完了後の前面画面'), findsOneWidget);
    expect(
      find.textContaining('動画の再生中にエラー', skipOffstage: false),
      findsNothing,
    );
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await foregroundRoute;

    expect(find.textContaining('動画の再生中にエラー'), findsOneWidget);
    expect(find.textContaining('完了結果を破棄'), findsNothing);
    expect(find.text('動画を再確認'), findsWidgets);
    expect(videoPlatform.seekRequests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('route pushと同一frameのrecord Provider結果は復帰後の再取得で最新化する', (
    tester,
  ) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 2065,
    );
    final repository = _GateNextResolutionRecordRepository(database);
    final initializationGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(initializationGate: initializationGate),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/provider-error-same-frame-route.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => videoPlatform.createCount == 1);
    repository.gateNextRead();
    container.invalidate(surgeryRecordProvider(record.id));
    await _pumpUntil(tester, () => repository.capturedRead.isCompleted);
    await tester.runAsync(
      () => database.customStatement(
        'UPDATE surgery_records SET case_memo = ? WHERE id = ?',
        <Object?>['前面route中に更新された症例メモ', record.id],
      ),
    );

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final foregroundRoute = navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Provider結果と同一frameの前面画面')),
      ),
    );
    repository.releaseRead.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('前面route中に更新された症例メモ', skipOffstage: false), findsNothing);
    expect(videoPlatform.seekRequests, isEmpty);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await foregroundRoute;
    expect(find.textContaining('別の画面が開かれたため'), findsOneWidget);
    await _openCaseMemoTab(tester);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '症例全体のメモ'))
          .controller!
          .text,
      '前面route中に更新された症例メモ',
    );
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resolver適用直前のfresh read待機中に非currentならcontrollerを生成しない', (
    tester,
  ) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 2050,
    );
    final repository = _GateNextResolutionRecordRepository(database);
    final releaseInspection = Completer<void>()..complete();
    final resolvedFile = File('/tmp/inactive-route-before-apply.mp4');
    final service = _ArmingInspectionVideoService(
      repository: repository,
      file: resolvedFile,
      releaseInspection: releaseInspection,
      readsBeforeGate: 2,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: resolvedFile,
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => repository.capturedRead.isCompleted);
    expect(videoPlatform.createCount, 0);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final foregroundRoute = navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('fresh read中の前面画面')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('fresh read中の前面画面'), findsOneWidget);

    repository.releaseRead.complete();
    await _pumpAsyncWork(tester);

    expect(videoPlatform.createCount, 0);
    expect(videoPlatform.createdVideoUris, isEmpty);
    expect(videoPlatform.seekRequests, isEmpty);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await foregroundRoute;
    expect(find.textContaining('別の画面が開かれたため'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resolver適用直前のfresh read例外も非current routeへ反映しない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 2075,
    );
    final repository = _GateNextResolutionRecordRepository(
      database,
      gatedReadError: StateError('制御可能な適用直前read失敗'),
    );
    final releaseInspection = Completer<void>()..complete();
    final resolvedFile = File('/tmp/inactive-route-before-error.mp4');
    final service = _ArmingInspectionVideoService(
      repository: repository,
      file: resolvedFile,
      releaseInspection: releaseInspection,
      readsBeforeGate: 2,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: resolvedFile,
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => repository.capturedRead.isCompleted);
    expect(videoPlatform.createCount, 0);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final foregroundRoute = navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('fresh read例外中の前面画面')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    repository.releaseRead.complete();
    await _pumpAsyncWork(tester);

    expect(videoPlatform.createCount, 0);
    expect(videoPlatform.createdVideoUris, isEmpty);
    expect(videoPlatform.seekRequests, isEmpty);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await foregroundRoute;
    expect(find.textContaining('別の画面が開かれたため'), findsOneWidget);
    expect(find.textContaining('動画を準備できませんでした'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fresh read中にProvider A→C→Aを観測後の例外は旧intentを再開しない', (
    tester,
  ) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final pathA = await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 2085,
    );
    final pathC = 'videos/${record.id}/fresh-read-error-c.mp4';
    final repository = _GateNextResolutionRecordRepository(
      database,
      gatedReadError: StateError('制御可能な適用直前read失敗'),
    );
    final releaseInspection = Completer<void>()..complete();
    final fileA = File('/tmp/fresh-read-error-observed-aba-a.mp4');
    final service = _ArmingInspectionVideoService(
      repository: repository,
      file: fileA,
      releaseInspection: releaseInspection,
      readsBeforeGate: 2,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(resolvedFile: fileA),
      settle: false,
    );
    await _pumpUntil(tester, () => repository.capturedRead.isCompleted);
    for (final path in <String>[pathC, pathA]) {
      await tester.runAsync(
        () => SurgeryRepository(database).updateVideoReference(
          surgeryRecordId: record.id,
          videoPath: path,
          videoDisplayName: path == pathA
              ? 'direct-jump.mp4'
              : 'fresh-read-error-c.mp4',
        ),
      );
      container.invalidate(surgeryRecordProvider(record.id));
      await tester.runAsync(
        () => container.read(surgeryRecordProvider(record.id).future),
      );
      await tester.pump();
    }

    repository.releaseRead.complete();
    await _pumpUntil(
      tester,
      () => find.textContaining('動画が更新されたため').evaluate().isNotEmpty,
    );
    expect(videoPlatform.createCount, 0);
    expect(videoPlatform.seekRequests, isEmpty);

    await tester.tap(find.text('動画を再確認'));
    await _pumpUntil(tester, () => videoPlatform.createCount == 1);
    expect(videoPlatform.createdVideoUris, <String?>[
      Uri.file(fileA.absolute.path).toString(),
    ]);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('seek待機中に非currentになると遅延成功と状態反映を破棄する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 2100,
    );
    final seekGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(seekGate: seekGate),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/inactive-route-during-seek.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => videoPlatform.seekRequests.isNotEmpty);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final foregroundRoute = navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('前面の画面・seek中')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('前面の画面・seek中'), findsOneWidget);

    final pauseCountBeforeCompletion = videoPlatform.pauseCount;
    seekGate.complete();
    await _pumpUntil(tester, () => videoPlatform.activePlayerIds.isEmpty);
    expect(videoPlatform.seekRequests, hasLength(1));
    expect(videoPlatform.pauseCount, pauseCountBeforeCompletion);
    expect(
      find.textContaining('開始位置へ移動しました', skipOffstage: false),
      findsNothing,
    );

    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await foregroundRoute;
    expect(find.textContaining('完了結果を破棄'), findsOneWidget);
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    expect(videoPlatform.seekRequests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('初期化待ちに開始位置が変わると旧位置へseekせずintentを破棄する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final path = await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 2200,
    );
    final initializationGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(initializationGate: initializationGate),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/start-race.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(
      tester,
      () =>
          videoPlatform.createCount == 1 &&
          find.byType(ProcedureTimingCard).evaluate().isNotEmpty,
    );
    expect(find.textContaining('CCCを開いています'), findsWidgets);
    expect(videoPlatform.seekRequests, isEmpty);

    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final review = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      await repository.saveStepTiming(
        review: review.copyWith(startMilliseconds: 3300),
        expectedVideoPath: path,
      );
    });
    container.invalidate(stepReviewsProvider(record.id));
    await _pumpAsyncWork(tester);
    initializationGate.complete();
    await tester.pumpAndSettle();

    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('工程位置が更新'), findsOneWidget);
    expect(
      tester
          .widget<ProcedureTimingCard>(find.byType(ProcedureTimingCard))
          .timing
          .startMilliseconds,
      3300,
    );
    expect(tester.takeException(), isNull);
  });

  for (final mutation in _InitialProviderTimingMutation.values) {
    testWidgets('fresh read後のprovider ${mutation.label}を旧工程値で上書きしない', (
      tester,
    ) async {
      final (database, record) = await createRecord(tester);
      addTearDown(database.close);
      final path = await _configureDirectJumpRecord(
        tester,
        database,
        record.id,
        step: SurgicalStep.capsulorhexis,
        startMilliseconds: 2250,
      );
      final repository = _MutatingInitialReviewsRepository(
        database,
        targetStep: SurgicalStep.capsulorhexis,
        mutation: mutation,
        changedStartMilliseconds: 9250,
        expectedVideoPath: path,
      );
      final videoPlatform = _installDirectJumpVideoPlatform(
        _DirectJumpVideoPlatform(failingPlayerIds: const <int>{1}),
      );

      await pumpScreen(
        tester,
        database,
        record.id,
        repository: repository,
        initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
        videoStorageRepository: _ReviewStateVideoStorage(
          resolvedFile: File('/tmp/provider-newer-${mutation.name}.mp4'),
        ),
      );

      expect(repository.didMutate, isTrue);
      expect(videoPlatform.seekRequests, isEmpty);
      expect(
        tester
            .widget<ProcedureTimingCard>(find.byType(ProcedureTimingCard))
            .timing
            .startMilliseconds,
        mutation == _InitialProviderTimingMutation.change ? 9250 : isNull,
      );
      expect(
        find.textContaining(
          mutation == _InitialProviderTimingMutation.change
              ? '工程位置が更新'
              : '工程の記録位置が削除',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('開始位置へ移動しました'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('工程read中の動画変更は最終record再readで検出し旧controllerへseekしない', (
    tester,
  ) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 4200,
    );
    final replacementPath = 'videos/${record.id}/replacement.mp4';
    final repository = _RecordMutationDuringFinalValidationRepository(
      database,
      targetStep: SurgicalStep.capsulorhexis,
      replacementVideoPath: replacementPath,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/final-record-reread.mp4'),
      ),
    );

    expect(repository.didMutateVideo, isTrue);
    expect(repository.targetReviewReadCount, greaterThanOrEqualTo(2));
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('動画が更新されたため'), findsOneWidget);
    await _pumpUntil(tester, () => videoPlatform.activePlayerIds.isEmpty);
    expect(videoPlatform.activePlayerIds, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final mutation in _FinalTimingMutation.values) {
    testWidgets('最終record read中の${mutation.label}を最終工程再readで検出する', (
      tester,
    ) async {
      final (database, record) = await createRecord(tester);
      addTearDown(database.close);
      await _configureDirectJumpRecord(
        tester,
        database,
        record.id,
        step: SurgicalStep.capsulorhexis,
        startMilliseconds: 4300,
      );
      final repository = _TimingMutationDuringFinalRecordReadRepository(
        database,
        targetStep: SurgicalStep.capsulorhexis,
        mutation: mutation,
        changedStartMilliseconds: 9300,
      );
      final videoPlatform = _installDirectJumpVideoPlatform(
        _DirectJumpVideoPlatform(),
      );

      await pumpScreen(
        tester,
        database,
        record.id,
        repository: repository,
        initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
        videoStorageRepository: _ReviewStateVideoStorage(
          resolvedFile: File('/tmp/final-timing-${mutation.name}.mp4'),
        ),
      );

      expect(repository.didMutate, isTrue);
      expect(repository.targetReviewReadCount, greaterThanOrEqualTo(3));
      expect(videoPlatform.seekRequests, isEmpty);
      expect(
        tester
            .widget<ProcedureTimingCard>(find.byType(ProcedureTimingCard))
            .timing
            .startMilliseconds,
        mutation == _FinalTimingMutation.change ? 9300 : isNull,
      );
      expect(
        find.textContaining(
          mutation == _FinalTimingMutation.change ? '工程位置が更新' : '工程の記録位置が削除',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final abaKind in _ObservedFreshReadAbaKind.values) {
    testWidgets('最終fresh readで観測した${abaKind.label} ABAは最終値が戻ってもseekしない', (
      tester,
    ) async {
      final (database, record) = await createRecord(tester);
      addTearDown(database.close);
      await _configureDirectJumpRecord(
        tester,
        database,
        record.id,
        step: SurgicalStep.capsulorhexis,
        startMilliseconds: 4400,
      );
      final repository = _ObservedFreshReadAbaRepository(
        database,
        kind: abaKind,
        armOnFinalTransaction: true,
      );
      final videoPlatform = _installDirectJumpVideoPlatform(
        _DirectJumpVideoPlatform(),
      );

      await pumpScreen(
        tester,
        database,
        record.id,
        repository: repository,
        initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
        videoStorageRepository: _ReviewStateVideoStorage(
          resolvedFile: File('/tmp/final-observed-aba-${abaKind.name}.mp4'),
        ),
      );

      expect(repository.didEmitAlternateValue, isTrue);
      expect(videoPlatform.seekRequests, isEmpty);
      expect(
        find.textContaining(
          abaKind == _ObservedFreshReadAbaKind.videoPath
              ? '動画が更新されたため'
              : '工程位置が更新',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('開始位置へ移動しました'), findsNothing);
      if (abaKind == _ObservedFreshReadAbaKind.videoPath) {
        await _pumpUntil(tester, () => videoPlatform.activePlayerIds.isEmpty);
        expect(videoPlatform.activePlayerIds, isEmpty);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('最終再検証待ちにcontrollerがerrorになるとseekせずretryableにする', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 4700,
    );
    final repository = _ControlledFinalReviewReadRepository(
      database,
      targetStep: SurgicalStep.capsulorhexis,
    );
    final runtimeErrorGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(runtimeErrorGate: runtimeErrorGate),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/runtime-controller-error.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => repository.finalReadStarted.isCompleted);
    expect(videoPlatform.seekRequests, isEmpty);

    runtimeErrorGate.complete();
    await _pumpAsyncWork(tester);
    repository.releaseFinalRead.complete();
    await _pumpAsyncWork(tester);

    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('動画を準備できませんでした'), findsOneWidget);
    expect(find.text('動画を再確認'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  for (final directJump in <bool>[false, true]) {
    testWidgets(
      '${directJump ? '直接ジャンプ完了後' : '通常導線'}のruntime errorはplayerを回復UIへ置換する',
      (tester) async {
        final (database, record) = await createRecord(tester);
        addTearDown(database.close);
        await _configureDirectJumpRecord(
          tester,
          database,
          record.id,
          step: SurgicalStep.capsulorhexis,
          startMilliseconds: 4900,
        );
        final runtimeErrorGate = Completer<void>();
        final videoPlatform = _installDirectJumpVideoPlatform(
          _DirectJumpVideoPlatform(runtimeErrorGate: runtimeErrorGate),
        );

        await pumpScreen(
          tester,
          database,
          record.id,
          initialStepStorageId: directJump
              ? SurgicalStep.capsulorhexis.storageId
              : null,
          videoStorageRepository: _ReviewStateVideoStorage(
            resolvedFile: File(
              '/tmp/runtime-error-${directJump ? 'direct' : 'normal'}.mp4',
            ),
          ),
          settle: false,
        );
        await _pumpUntil(tester, () {
          final controls = find.byType(VideoTransportControls);
          final expectedSeekCount = directJump ? 1 : 0;
          return videoPlatform.seekRequests.length == expectedSeekCount &&
              controls.evaluate().isNotEmpty &&
              tester
                      .widget<VideoTransportControls>(controls)
                      .onTogglePlayback !=
                  null &&
              (!directJump ||
                  find.textContaining('開始位置へ移動しました').evaluate().isNotEmpty);
        });

        runtimeErrorGate.complete();
        await _pumpUntil(
          tester,
          () => find.textContaining('動画の再生中にエラーが発生しました').evaluate().isNotEmpty,
        );

        expect(find.byKey(const Key('review-video-player')), findsNothing);
        expect(find.byType(VideoTransportControls), findsNothing);
        expect(find.byKey(const Key('review-video-slider')), findsNothing);
        expect(find.text('動画を再確認'), findsWidgets);
        final timingCard = tester.widget<ProcedureTimingCard>(
          find.byType(ProcedureTimingCard),
        );
        expect(timingCard.onStart, isNull);
        expect(timingCard.onEnd, isNull);
        expect(timingCard.onTapStart, isNull);
        expect(timingCard.onTapEnd, isNull);
        expect(videoPlatform.createCount, 1);

        await tester.tap(find.text('動画を再確認').first);
        await _pumpUntil(tester, () => videoPlatform.createCount == 2);
        await _pumpUntil(
          tester,
          () => videoPlatform.disposedPlayerIds.contains(1),
        );
        expect(videoPlatform.disposedPlayerIds, contains(1));
        expect(videoPlatform.seekRequests, hasLength(directJump ? 1 : 0));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('直接ジャンプのresolver例外を一度だけ通知し明示再確認後だけ復旧する', (tester) async {
    final semantics = tester.ensureSemantics();
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 5100,
    );
    final repository = SurgeryRepository(database);
    final service = _SwitchableInspectionVideoService(
      repository: repository,
      file: File('/tmp/retryable-resolver.mp4'),
      inspectError: FileSystemException('制御可能なresolver例外'),
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: service.file,
      ),
      settle: false,
    );
    const failureMessage = '動画を準備できませんでした。動画を再確認してください。';
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('direct-jump-primary-message'))
          .evaluate()
          .isNotEmpty,
    );

    final failureAnnouncement = find.byKey(
      const Key('direct-jump-primary-message'),
    );
    final originalNodeId = tester.getSemantics(failureAnnouncement).id;
    expect(tester.getSemantics(failureAnnouncement).label, failureMessage);
    expect(videoPlatform.createCount, 0);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.text('動画を再確認'), findsOneWidget);

    container.invalidate(surgeryRecordProvider(record.id));
    container.invalidate(stepReviewsProvider(record.id));
    tester.element(find.byType(StepReviewScreen)).markNeedsBuild();
    await _pumpAsyncWork(tester);
    expect(tester.getSemantics(failureAnnouncement).id, originalNodeId);
    expect(videoPlatform.createCount, 0);
    expect(videoPlatform.seekRequests, isEmpty);

    service.inspectError = null;
    await tester.tap(find.text('動画を再確認'));
    await _pumpUntil(
      tester,
      () =>
          videoPlatform.seekRequests.length == 1 &&
          videoPlatform.pauseCount >= 1 &&
          find.textContaining('開始位置へ移動しました').evaluate().isNotEmpty,
    );

    expect(videoPlatform.createCount, 1);
    expect(videoPlatform.seekRequests, <Duration>[
      const Duration(milliseconds: 5100),
    ]);
    expect(find.bySemanticsLabel(failureMessage), findsNothing);
    expect(find.textContaining('開始位置へ移動しました'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('resolver中にProvider A→C→Aを観測後の例外は再確認でも旧intentを再開しない', (
    tester,
  ) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final pathA = await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 5125,
    );
    final pathC = 'videos/${record.id}/resolver-error-c.mp4';
    final repository = _GateNextResolutionRecordRepository(database);
    final releaseInspection = Completer<void>();
    final fileA = File('/tmp/resolver-error-observed-aba-a.mp4');
    final service = _ArmingInspectionVideoService(
      repository: repository,
      file: fileA,
      releaseInspection: releaseInspection,
      inspectError: StateError('制御可能なresolver失敗'),
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(resolvedFile: fileA),
      settle: false,
    );
    await _pumpUntil(tester, () => service.inspectionStarted.isCompleted);
    for (final path in <String>[pathC, pathA]) {
      await tester.runAsync(
        () => SurgeryRepository(database).updateVideoReference(
          surgeryRecordId: record.id,
          videoPath: path,
          videoDisplayName: path == pathA
              ? 'direct-jump.mp4'
              : 'resolver-error-c.mp4',
        ),
      );
      container.invalidate(surgeryRecordProvider(record.id));
      await tester.runAsync(
        () => container.read(surgeryRecordProvider(record.id).future),
      );
      await tester.pump();
    }

    releaseInspection.complete();
    await _pumpUntil(
      tester,
      () => find.textContaining('動画が更新されたため').evaluate().isNotEmpty,
    );
    expect(videoPlatform.createCount, 0);
    expect(videoPlatform.seekRequests, isEmpty);

    service.inspectError = null;
    await tester.tap(find.text('動画を再確認'));
    await _pumpUntil(tester, () => videoPlatform.createCount == 1);

    expect(videoPlatform.createdVideoUris, <String?>[
      Uri.file(fileA.absolute.path).toString(),
    ]);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry fresh read待機中に非currentなら旧intentを再開しない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 5150,
    );
    final repository = _GateNextResolutionRecordRepository(database);
    final resolvedFile = File('/tmp/inactive-direct-retry.mp4');
    final service = _SwitchableInspectionVideoService(
      repository: repository,
      file: resolvedFile,
      inspectError: StateError('制御可能な初回resolver失敗'),
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: resolvedFile,
      ),
      settle: false,
    );
    await _pumpUntil(
      tester,
      () => find.textContaining('動画を準備できませんでした').evaluate().isNotEmpty,
    );

    service.inspectError = null;
    repository.gateNextRead();
    await tester.tap(find.text('動画を再確認'));
    await _pumpUntil(tester, () => repository.capturedRead.isCompleted);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final foregroundRoute = navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('retry read中の前面画面')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    repository.releaseRead.complete();
    await _pumpAsyncWork(tester);

    expect(videoPlatform.createCount, 0);
    expect(videoPlatform.seekRequests, isEmpty);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await foregroundRoute;
    expect(find.textContaining('別の画面が開かれたため'), findsOneWidget);

    await tester.tap(find.text('動画を再確認'));
    await _pumpUntil(tester, () => videoPlatform.createCount == 1);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('安定retryable中に動画ヘルプを開いて戻っても明示再確認権を保持する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 5175,
    );
    final repository = SurgeryRepository(database);
    final resolvedFile = File('/tmp/retryable-help-route.mp4');
    final service = _SwitchableInspectionVideoService(
      repository: repository,
      file: resolvedFile,
      inspectError: StateError('制御可能な初回resolver失敗'),
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: resolvedFile,
      ),
      settle: false,
    );
    await _pumpUntil(
      tester,
      () => find.textContaining('動画を準備できませんでした').evaluate().isNotEmpty,
    );

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await tester.tap(find.byTooltip('再登録できる動画の目安'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('再登録できる動画の目安'), findsWidgets);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.textContaining('動画を準備できませんでした'), findsOneWidget);

    service.inspectError = null;
    await tester.ensureVisible(find.text('動画を再確認'));
    await tester.tap(find.text('動画を再確認'));
    await _pumpUntil(tester, () => videoPlatform.seekRequests.length == 1);
    await _pumpAsyncWork(tester);
    expect(videoPlatform.seekRequests, <Duration>[
      const Duration(milliseconds: 5175),
    ]);
    expect(find.textContaining('開始位置へ移動しました'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('初期化失敗はProvider再通知で再開せず明示再確認だけで新controllerを生成する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 5200,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(failingPlayerIds: const <int>{1}),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/retryable-init.mp4'),
      ),
    );
    expect(videoPlatform.createCount, 1);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('動画を再生できませんでした'), findsOneWidget);

    container.invalidate(surgeryRecordProvider(record.id));
    container.invalidate(stepReviewsProvider(record.id));
    await _pumpAsyncWork(tester);
    await tester.pumpAndSettle();
    expect(videoPlatform.createCount, 1);
    expect(videoPlatform.seekRequests, isEmpty);

    await tester.tap(find.text('動画を再確認').first);
    await _pumpUntil(tester, () => videoPlatform.seekRequests.isNotEmpty);
    await tester.pumpAndSettle();
    await _pumpUntil(tester, () => videoPlatform.disposedPlayerIds.contains(1));

    expect(videoPlatform.createCount, 2);
    expect(videoPlatform.disposedPlayerIds, contains(1));
    expect(videoPlatform.activePlayerIds, <int>{2});
    expect(videoPlatform.seekRequests, <Duration>[
      const Duration(milliseconds: 5200),
    ]);
    expect(videoPlatform.pauseCount, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('retryable中の開始位置変更は明示再確認でも旧intentを再開しない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final path = await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 5400,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(failingPlayerIds: const <int>{1}),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/retryable-start-change.mp4'),
      ),
    );
    expect(find.textContaining('動画を再生できませんでした'), findsOneWidget);

    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final review = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      await repository.saveStepTiming(
        review: review.copyWith(startMilliseconds: 6400),
        expectedVideoPath: path,
      );
    });
    await tester.tap(find.text('動画を再確認').first);
    await _pumpUntil(
      tester,
      () => find.textContaining('工程位置が更新').evaluate().isNotEmpty,
    );

    expect(videoPlatform.createCount, 1);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(
      tester
          .widget<ProcedureTimingCard>(find.byType(ProcedureTimingCard))
          .timing
          .startMilliseconds,
      6400,
    );
    expect(tester.takeException(), isNull);
  });

  for (final abaKind in _ObservedFreshReadAbaKind.values) {
    testWidgets('retry fresh readで観測した${abaKind.label} ABAは旧intentを再開しない', (
      tester,
    ) async {
      final (database, record) = await createRecord(tester);
      addTearDown(database.close);
      await _configureDirectJumpRecord(
        tester,
        database,
        record.id,
        step: SurgicalStep.capsulorhexis,
        startMilliseconds: 5450,
      );
      final repository = _ObservedFreshReadAbaRepository(
        database,
        kind: abaKind,
      );
      final videoPlatform = _installDirectJumpVideoPlatform(
        _DirectJumpVideoPlatform(failingPlayerIds: const <int>{1}),
      );

      await pumpScreen(
        tester,
        database,
        record.id,
        repository: repository,
        initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
        videoStorageRepository: _ReviewStateVideoStorage(
          resolvedFile: File('/tmp/retry-observed-aba-${abaKind.name}.mp4'),
        ),
      );
      expect(find.textContaining('動画を再生できませんでした'), findsOneWidget);

      repository.arm();
      await tester.tap(find.text('動画を再確認').first);
      await _pumpUntil(
        tester,
        () => find
            .textContaining(
              abaKind == _ObservedFreshReadAbaKind.videoPath
                  ? '動画が更新されたため'
                  : '工程位置が更新',
            )
            .evaluate()
            .isNotEmpty,
      );

      expect(repository.didEmitAlternateValue, isTrue);
      expect(videoPlatform.createCount, 1);
      expect(videoPlatform.seekRequests, isEmpty);
      expect(find.textContaining('開始位置へ移動しました'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('初期seek失敗は明示再確認でcontrollerだけ再生成し自動seekを繰り返さない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 6200,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(failSeek: true),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/failing-seek.mp4'),
      ),
    );

    expect(videoPlatform.seekRequests, <Duration>[
      const Duration(milliseconds: 6200),
    ]);
    expect(find.textContaining('開始位置へ移動できませんでした'), findsOneWidget);
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    expect(
      tester
          .widget<VideoTransportControls>(find.byType(VideoTransportControls))
          .onTogglePlayback,
      isNotNull,
    );
    expect(find.byKey(const Key('direct-seek-video-recheck')), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const Key('direct-seek-video-recheck')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('direct-seek-video-recheck')));
    await _pumpUntil(
      tester,
      () =>
          videoPlatform.createCount == 2 &&
          videoPlatform.activePlayerIds.length == 1 &&
          find.byType(VideoTransportControls).evaluate().isNotEmpty,
    );

    expect(videoPlatform.disposedPlayerIds, contains(1));
    expect(videoPlatform.seekRequests, hasLength(1));
    expect(
      tester
          .widget<VideoTransportControls>(find.byType(VideoTransportControls))
          .onTogglePlayback,
      isNotNull,
    );

    container.invalidate(surgeryRecordProvider(record.id));
    container.invalidate(stepReviewsProvider(record.id));
    await _pumpAsyncWork(tester);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpAsyncWork(tester);
    expect(videoPlatform.seekRequests, hasLength(1));
    expect(videoPlatform.createCount, 2);
    expect(tester.takeException(), isNull);
  });

  for (final timingChangeBeforeSeekFailure in <bool>[true, false]) {
    testWidgets(
      '工程位置更新がseek失敗の${timingChangeBeforeSeekFailure ? '前' : '後'}でも両方を案内する',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final (database, record) = await createRecord(tester);
        addTearDown(database.close);
        final path = await _configureDirectJumpRecord(
          tester,
          database,
          record.id,
          step: SurgicalStep.capsulorhexis,
          startMilliseconds: 6250,
        );
        final seekGate = Completer<void>();
        final videoPlatform = _installDirectJumpVideoPlatform(
          _DirectJumpVideoPlatform(seekGate: seekGate, failSeek: true),
        );

        final container = await pumpScreen(
          tester,
          database,
          record.id,
          initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
          videoStorageRepository: _ReviewStateVideoStorage(
            resolvedFile: File('/tmp/timing-change-and-seek-failure.mp4'),
          ),
          settle: false,
        );
        await _pumpUntil(tester, () => videoPlatform.seekRequests.isNotEmpty);

        Future<void> changeTiming() async {
          await tester.runAsync(() async {
            final repository = SurgeryRepository(database);
            final review = (await repository.getStepReview(
              surgeryRecordId: record.id,
              step: SurgicalStep.capsulorhexis,
            ))!;
            await repository.saveStepTiming(
              review: review.copyWith(startMilliseconds: 9350),
              expectedVideoPath: path,
            );
          });
          container.invalidate(stepReviewsProvider(record.id));
          await _pumpUntil(tester, () {
            final cards = find.byType(ProcedureTimingCard);
            return cards.evaluate().isNotEmpty &&
                tester
                        .widget<ProcedureTimingCard>(cards)
                        .timing
                        .startMilliseconds ==
                    9350;
          });
        }

        int? originalSeekFailureNodeId;
        if (timingChangeBeforeSeekFailure) {
          await changeTiming();
          seekGate.complete();
          await _pumpAsyncWork(tester);
        } else {
          seekGate.complete();
          await _pumpUntil(
            tester,
            () => find.textContaining('開始位置へ移動できませんでした').evaluate().isNotEmpty,
          );
          originalSeekFailureNodeId = tester
              .getSemantics(
                find.byKey(const Key('direct-jump-seek-failure-message')),
              )
              .id;
          await changeTiming();
          await _pumpAsyncWork(tester);
        }

        expect(videoPlatform.seekRequests, hasLength(1));
        expect(find.textContaining('工程位置が更新'), findsOneWidget);
        expect(find.textContaining('開始位置へ移動できませんでした'), findsOneWidget);
        expect(find.textContaining('開始位置へ移動しました'), findsNothing);
        final primaryAnnouncement = find.byKey(
          const Key('direct-jump-primary-message'),
        );
        final seekFailureAnnouncement = find.byKey(
          const Key('direct-jump-seek-failure-message'),
        );
        expect(primaryAnnouncement, findsOneWidget);
        expect(seekFailureAnnouncement, findsOneWidget);
        expect(
          tester.getSemantics(primaryAnnouncement).label,
          contains('工程位置が更新'),
        );
        expect(
          tester.getSemantics(seekFailureAnnouncement).label,
          contains('開始位置へ移動できませんでした'),
        );
        expect(
          tester.getSemantics(primaryAnnouncement).label,
          isNot(contains('開始位置へ移動できませんでした')),
        );
        expect(
          tester.getSemantics(seekFailureAnnouncement).label,
          isNot(contains('工程位置が更新')),
        );
        if (originalSeekFailureNodeId != null) {
          expect(
            tester.getSemantics(seekFailureAnnouncement).id,
            originalSeekFailureNodeId,
          );
        }
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
    );
  }

  testWidgets('seek要求後にcontrollerがerrorなら成功扱いせず再確認へ遷移する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 6300,
    );
    final runtimeErrorGate = Completer<void>();
    final seekGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(
        runtimeErrorGate: runtimeErrorGate,
        seekGate: seekGate,
      ),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/runtime-error-after-seek-request.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => videoPlatform.seekRequests.isNotEmpty);

    runtimeErrorGate.complete();
    await _pumpUntil(
      tester,
      () => find.textContaining('開始位置へ移動できませんでした').evaluate().isNotEmpty,
    );

    expect(videoPlatform.seekRequests, hasLength(1));
    expect(find.byKey(const Key('direct-jump-preparing-notice')), findsNothing);
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    expect(find.textContaining('動画を再生できない状態'), findsOneWidget);
    expect(find.text('動画を再確認'), findsWidgets);

    container.invalidate(surgeryRecordProvider(record.id));
    container.invalidate(stepReviewsProvider(record.id));
    await _pumpAsyncWork(tester);
    expect(videoPlatform.seekRequests, hasLength(1));

    seekGate.complete();
    await _pumpAsyncWork(tester);
    expect(videoPlatform.seekRequests, hasLength(1));
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('seek要求後の症例削除は遅延完了を破棄し未保存draftを保持する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 7200,
    );
    final seekGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(seekGate: seekGate),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/deleted-during-seek.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => videoPlatform.seekRequests.isNotEmpty);
    await tester.drag(
      find.byKey(const ValueKey('review-step-content-capsulorhexis')),
      const Offset(0, -500),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('自己評価・反省点'));
    await tester.pump();
    final reflection = find.widgetWithText(TextField, '反省点');
    await tester.enterText(reflection, '削除後も保持する未保存ドラフト');
    await tester.pump();
    expect(_popScope(tester).canPop, isFalse);

    await tester.runAsync(
      () => SurgeryRepository(database).deleteRecord(record.id),
    );
    container.invalidate(surgeryRecordProvider(record.id));
    await _pumpUntil(tester, () => find.text('ドラフトをコピー').evaluate().isNotEmpty);

    expect(find.textContaining('症例が別画面で削除'), findsOneWidget);
    expect(
      tester.widget<TextField>(reflection).controller!.text,
      '削除後も保持する未保存ドラフト',
    );
    expect(videoPlatform.seekRequests, hasLength(1));
    await _pumpUntil(tester, () => videoPlatform.activePlayerIds.isEmpty);
    expect(videoPlatform.activePlayerIds, isEmpty);

    seekGate.complete();
    await _pumpAsyncWork(tester);
    expect(videoPlatform.seekRequests, hasLength(1));
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('seek Future待機中のbackは遅延完了と成功通知を破棄する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 7300,
    );
    final seekGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(seekGate: seekGate),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/back-during-seek.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => videoPlatform.seekRequests.isNotEmpty);

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('症例一覧'), findsOneWidget);
    expect(videoPlatform.seekRequests, hasLength(1));

    seekGate.complete();
    await _pumpUntil(
      tester,
      () =>
          videoPlatform.activePlayerIds.isEmpty &&
          find.text('動画を再確認').evaluate().isNotEmpty,
    );
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    expect(videoPlatform.seekRequests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final mutation in _DelayedSeekMutation.values) {
    testWidgets('seek Future待機中の${mutation.label}は旧完了通知と追加seekを抑止する', (
      tester,
    ) async {
      final (database, record) = await createRecord(tester);
      addTearDown(database.close);
      final path = await _configureDirectJumpRecord(
        tester,
        database,
        record.id,
        step: SurgicalStep.capsulorhexis,
        startMilliseconds: 7350,
      );
      final seekGate = Completer<void>();
      final videoPlatform = _installDirectJumpVideoPlatform(
        _DirectJumpVideoPlatform(seekGate: seekGate),
      );

      final container = await pumpScreen(
        tester,
        database,
        record.id,
        initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
        videoStorageRepository: _ReviewStateVideoStorage(
          resolvedFile: File('/tmp/delayed-seek-${mutation.name}.mp4'),
        ),
        settle: false,
      );
      await _pumpUntil(tester, () => videoPlatform.seekRequests.isNotEmpty);

      await tester.runAsync(() async {
        final repository = SurgeryRepository(database);
        switch (mutation) {
          case _DelayedSeekMutation.changeStart:
            final review = (await repository.getStepReview(
              surgeryRecordId: record.id,
              step: SurgicalStep.capsulorhexis,
            ))!;
            await repository.saveStepTiming(
              review: review.copyWith(startMilliseconds: 9350),
              expectedVideoPath: path,
            );
          case _DelayedSeekMutation.clearStart:
            await database.customStatement(
              '''
UPDATE surgical_step_reviews
SET start_milliseconds = NULL,
    end_milliseconds = NULL,
    is_skipped = 0
WHERE surgery_record_id = ? AND step = ?
''',
              <Object?>[record.id, SurgicalStep.capsulorhexis.storageId],
            );
          case _DelayedSeekMutation.deleteRow:
            await database.customStatement(
              '''
DELETE FROM surgical_step_reviews
WHERE surgery_record_id = ? AND step = ?
''',
              <Object?>[record.id, SurgicalStep.capsulorhexis.storageId],
            );
          case _DelayedSeekMutation.changeVideo:
            await repository.updateVideoReference(
              surgeryRecordId: record.id,
              videoPath: 'videos/${record.id}/changed-during-seek.mp4',
              videoDisplayName: 'changed-during-seek.mp4',
            );
        }
      });
      if (mutation == _DelayedSeekMutation.changeVideo) {
        container.invalidate(surgeryRecordProvider(record.id));
        await _pumpUntil(
          tester,
          () => find.byKey(const Key('review-video-player')).evaluate().isEmpty,
        );
      } else {
        container.invalidate(stepReviewsProvider(record.id));
        await _pumpUntil(tester, () {
          final cards = find.byType(ProcedureTimingCard).evaluate();
          if (cards.isEmpty) {
            return false;
          }
          final startMilliseconds = tester
              .widget<ProcedureTimingCard>(find.byType(ProcedureTimingCard))
              .timing
              .startMilliseconds;
          return mutation == _DelayedSeekMutation.changeStart
              ? startMilliseconds == 9350
              : startMilliseconds == null;
        });
      }

      expect(videoPlatform.seekRequests, <Duration>[
        const Duration(milliseconds: 7350),
      ]);
      expect(find.textContaining('開始位置へ移動しました'), findsNothing);
      seekGate.complete();
      await _pumpAsyncWork(tester);

      expect(videoPlatform.seekRequests, hasLength(1));
      expect(find.textContaining('開始位置へ移動しました'), findsNothing);
      expect(find.textContaining(mutation.expectedMessage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('seek後の開始位置・動画変更は表示を更新して追加seekしない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final path = await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 7400,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/changed-after-seek.mp4'),
      ),
    );
    expect(videoPlatform.seekRequests, <Duration>[
      const Duration(milliseconds: 7400),
    ]);

    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final review = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      await repository.saveStepTiming(
        review: review.copyWith(startMilliseconds: 8400),
        expectedVideoPath: path,
      );
    });
    container.invalidate(stepReviewsProvider(record.id));
    await _pumpAsyncWork(tester);

    expect(videoPlatform.seekRequests, hasLength(1));
    expect(
      tester
          .widget<ProcedureTimingCard>(find.byType(ProcedureTimingCard))
          .timing
          .startMilliseconds,
      8400,
    );
    expect(find.textContaining('工程位置が更新'), findsOneWidget);

    final replacementPath = 'videos/${record.id}/after-seek-replacement.mp4';
    await tester.runAsync(
      () => SurgeryRepository(database).updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: replacementPath,
        videoDisplayName: 'after-seek-replacement.mp4',
      ),
    );
    container.invalidate(surgeryRecordProvider(record.id));
    await _pumpUntil(
      tester,
      () =>
          videoPlatform.activePlayerIds.isEmpty &&
          find.text('動画を再確認').evaluate().isNotEmpty,
    );

    expect(videoPlatform.seekRequests, hasLength(1));
    expect(videoPlatform.activePlayerIds, isEmpty);
    expect(find.textContaining('動画が更新されました'), findsOneWidget);
    expect(find.text('動画を再確認'), findsOneWidget);

    await tester.tap(find.text('動画を再確認'));
    await _pumpUntil(
      tester,
      () =>
          videoPlatform.createCount == 2 &&
          videoPlatform.activePlayerIds.length == 1 &&
          find.byType(VideoTransportControls).evaluate().isNotEmpty,
    );

    expect(videoPlatform.disposedPlayerIds, contains(1));
    expect(videoPlatform.seekRequests, hasLength(1));
    expect(
      tester
          .widget<VideoTransportControls>(find.byType(VideoTransportControls))
          .onTogglePlayback,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('lifecycle復帰と明示的rebuildでも初期seekを追加しない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 7500,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/lifecycle-rebuild.mp4'),
      ),
    );
    expect(videoPlatform.seekRequests, hasLength(1));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    tester.element(find.byType(StepReviewScreen)).markNeedsBuild();
    await tester.pump();

    expect(videoPlatform.seekRequests, hasLength(1));
    expect(videoPlatform.createCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('動画位置通知10回では工程カードを再構築せず再生表示だけを更新する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 7525,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/video-only-rebuild-boundary.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () {
      final controls = find.byType(VideoTransportControls);
      return videoPlatform.seekRequests.length == 1 &&
          controls.evaluate().isNotEmpty &&
          tester.widget<VideoTransportControls>(controls).onTogglePlayback !=
              null;
    });
    await _pumpAsyncWork(tester);

    await tester.drag(
      find.byKey(const ValueKey('review-step-content-capsulorhexis')),
      const Offset(0, -500),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final timingCardFinder = find.byType(ProcedureTimingCard);
    final originalTimingCard = tester.widget<ProcedureTimingCard>(
      timingCardFinder,
    );
    final tabBarFinder = find.byType(TabBar);
    final originalTabBar = tester.widget<TabBar>(tabBarFinder);
    await tester.tap(find.text('自己評価・反省点'));
    await tester.pump();
    final reflectionFinder = find.widgetWithText(TextField, '反省点');
    final ratingFinder = find.byType(DropdownButtonFormField<StepRating>);
    final originalReflectionField = tester.widget<TextField>(reflectionFinder);
    final originalRatingField = tester
        .widget<DropdownButtonFormField<StepRating>>(ratingFinder);
    final controls = tester.widget<VideoTransportControls>(
      find.byType(VideoTransportControls),
    );
    controls.onTogglePlayback!();
    await tester.pump();
    final positionReadsBeforeUpdates = videoPlatform.getPositionCount;

    for (var update = 1; update <= 10; update++) {
      videoPlatform.setActivePosition(Duration(milliseconds: update * 700));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(
        identical(
          tester.widget<ProcedureTimingCard>(timingCardFinder),
          originalTimingCard,
        ),
        isTrue,
      );
      expect(
        identical(tester.widget<TabBar>(tabBarFinder), originalTabBar),
        isTrue,
      );
      expect(
        identical(
          tester.widget<TextField>(reflectionFinder),
          originalReflectionField,
        ),
        isTrue,
      );
      expect(
        identical(
          tester.widget<DropdownButtonFormField<StepRating>>(ratingFinder),
          originalRatingField,
        ),
        isTrue,
      );
    }

    expect(
      videoPlatform.getPositionCount - positionReadsBeforeUpdates,
      greaterThanOrEqualTo(10),
    );
    expect(videoPlatform.playCount, 1);
    expect(videoPlatform.seekRequests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('open/backを20連続しても各画面でseekは1回だけでcontrollerを残さない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 7550,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/repeated-open-back.mp4'),
      ),
      settle: false,
    );

    for (var cycle = 0; cycle < 20; cycle++) {
      if (cycle > 0) {
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        unawaited(navigator.pushNamed<void>('/review'));
        await tester.pump();
      }
      await _pumpUntil(tester, () {
        final transportControls = find.byType(VideoTransportControls);
        return videoPlatform.seekRequests.length == cycle + 1 &&
            transportControls.evaluate().isNotEmpty &&
            tester
                    .widget<VideoTransportControls>(transportControls)
                    .onTogglePlayback !=
                null;
      });
      await _pumpAsyncWork(tester);
      expect(find.byType(StepReviewScreen), findsOneWidget);
      expect(videoPlatform.createCount, cycle + 1);
      expect(videoPlatform.seekRequests, hasLength(cycle + 1));
      expect(videoPlatform.activePlayerIds, hasLength(1));
      expect(_popScope(tester).canPop, isTrue);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('症例一覧'), findsOneWidget);
      expect(find.byType(StepReviewScreen), findsNothing);
      await _pumpUntil(tester, () => videoPlatform.activePlayerIds.isEmpty);
      expect(videoPlatform.disposedPlayerIds, hasLength(cycle + 1));
      expect(videoPlatform.seekRequests, hasLength(cycle + 1));
      expect(tester.takeException(), isNull);
    }

    expect(videoPlatform.createCount, 20);
    expect(videoPlatform.seekPlayerIds.toSet(), hasLength(20));
    expect(videoPlatform.disposedPlayerIds, hasLength(20));
    expect(videoPlatform.activePlayerIds, isEmpty);
    expect(
      videoPlatform.seekRequests,
      everyElement(const Duration(milliseconds: 7550)),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('初期化待ちで戻るとcontrollerを即時無効化しdispose遅延失敗を処理する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 7600,
    );
    final initializationGate = Completer<void>();
    final disposeGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(
        initializationGate: initializationGate,
        disposeGate: disposeGate,
        failDispose: true,
      ),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/dispose-race.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => videoPlatform.createCount == 1);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('症例一覧'), findsOneWidget);
    expect(videoPlatform.seekRequests, isEmpty);

    initializationGate.complete();
    await _pumpUntil(tester, () => videoPlatform.disposedPlayerIds.contains(1));
    expect(videoPlatform.activePlayerIds, isEmpty);
    disposeGate.complete();
    await _pumpAsyncWork(tester);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('画面破棄のcleanup描画でlistener解除とcontroller disposeを開始する', (
    tester,
  ) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 7625,
    );
    final initializationGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(
        initializationGate: initializationGate,
        trackEventCancellation: true,
      ),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/dispose-start-frame.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => videoPlatform.createCount == 1);
    expect(videoPlatform.eventCancellationStartedPlayerIds, isEmpty);
    expect(videoPlatform.disposedPlayerIds, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());

    expect(videoPlatform.eventCancellationStartedPlayerIds, <int>{1});
    expect(videoPlatform.disposedPlayerIds, isEmpty);
    expect(videoPlatform.seekRequests, isEmpty);
    initializationGate.complete();
    await _pumpUntil(tester, () => videoPlatform.disposedPlayerIds.contains(1));
    expect(videoPlatform.activePlayerIds, isEmpty);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('seek前・draft初期化後の症例削除はcontrollerを無効化し入力を保持する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 7750,
    );
    final initializationGate = Completer<void>();
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(initializationGate: initializationGate),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/deleted-after-draft-before-seek.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(
      tester,
      () =>
          videoPlatform.createCount == 1 &&
          find.byType(ProcedureTimingCard).evaluate().isNotEmpty,
    );
    await tester.drag(
      find.byKey(const ValueKey('review-step-content-capsulorhexis')),
      const Offset(0, -500),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('自己評価・反省点'));
    await tester.pump();
    final reflection = find.widgetWithText(TextField, '反省点');
    await tester.enterText(reflection, 'seek前削除でも保持するドラフト');
    await tester.pump();

    await tester.runAsync(
      () => SurgeryRepository(database).deleteRecord(record.id),
    );
    container.invalidate(surgeryRecordProvider(record.id));
    await _pumpUntil(tester, () => find.text('ドラフトをコピー').evaluate().isNotEmpty);

    expect(find.textContaining('症例が別画面で削除'), findsOneWidget);
    expect(find.textContaining('症例が削除されたため工程動画を開けませんでした'), findsOneWidget);
    expect(
      tester.widget<TextField>(reflection).controller!.text,
      'seek前削除でも保持するドラフト',
    );
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.byType(VideoTransportControls), findsNothing);

    initializationGate.complete();
    await _pumpUntil(tester, () => videoPlatform.activePlayerIds.isEmpty);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('draft初期化前の症例削除理由をlive regionとして公開する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 7800,
    );
    final repository = _ControlledInitialRecordReadRepository(database);
    _installDirectJumpVideoPlatform(_DirectJumpVideoPlatform());

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/deleted-before-draft.mp4'),
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => repository.firstReadStarted.isCompleted);

    await tester.runAsync(
      () => SurgeryRepository(database).deleteRecord(record.id),
    );
    repository.releaseFirstRead.complete();
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('direct-jump-initial-failure-announcement'))
          .evaluate()
          .isNotEmpty,
    );

    const deletionAnnouncement = '症例が削除されたため工程動画を開けませんでした。';
    final failureAnnouncement = find.byKey(
      const Key('direct-jump-initial-failure-announcement'),
    );
    final semantics = tester.ensureSemantics();
    final node = tester.getSemantics(failureAnnouncement);
    final originalNodeId = node.id;
    expect(node.flagsCollection.isLiveRegion, isTrue);
    expect(node.label, deletionAnnouncement);
    expect(failureAnnouncement, findsOneWidget);
    expect(find.bySemanticsLabel(deletionAnnouncement), findsOneWidget);

    tester.element(find.byType(StepReviewScreen)).markNeedsBuild();
    await tester.pump();
    expect(failureAnnouncement, findsOneWidget);
    expect(tester.getSemantics(failureAnnouncement).id, originalNodeId);
    expect(find.bySemanticsLabel(deletionAnnouncement), findsOneWidget);

    container.invalidate(surgeryRecordProvider(record.id));
    container.invalidate(stepReviewsProvider(record.id));
    await _pumpAsyncWork(tester);
    expect(failureAnnouncement, findsOneWidget);
    expect(tester.getSemantics(failureAnnouncement).id, originalNodeId);
    expect(find.bySemanticsLabel(deletionAnnouncement), findsOneWidget);

    semantics.dispose();
    expect(find.text('症例が見つかりません'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump();
  });

  testWidgets('resolver最終read後の症例削除通知を旧結果で復活させない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 7900,
    );
    final repository = _GateNextResolutionRecordRepository(database);
    final releaseInspection = Completer<void>();
    final service = _ArmingInspectionVideoService(
      repository: repository,
      file: File('/tmp/stale-resolution-after-delete.mp4'),
      releaseInspection: releaseInspection,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: service.file,
      ),
      settle: false,
    );
    await _pumpUntil(
      tester,
      () =>
          service.inspectionStarted.isCompleted &&
          find.byType(ProcedureTimingCard).evaluate().isNotEmpty,
    );
    releaseInspection.complete();
    await _pumpUntil(tester, () => repository.capturedRead.isCompleted);

    await tester.runAsync(
      () => SurgeryRepository(database).deleteRecord(record.id),
    );
    container.invalidate(surgeryRecordProvider(record.id));
    await _pumpUntil(
      tester,
      () =>
          find.text('ドラフトをコピー').evaluate().isNotEmpty ||
          find.text('症例が見つかりません').evaluate().isNotEmpty,
    );

    repository.releaseRead.complete();
    await _pumpAsyncWork(tester);

    expect(videoPlatform.createCount, 0);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.byType(VideoTransportControls), findsNothing);
    expect(
      find.text('ドラフトをコピー').evaluate().isNotEmpty ||
          find.text('症例が見つかりません').evaluate().isNotEmpty,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('resolver最終read後の同一参照metadata更新を旧recordで巻き戻さない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 7950,
    );
    final repository = _GateNextResolutionRecordRepository(database);
    final releaseInspection = Completer<void>();
    final service = _ArmingInspectionVideoService(
      repository: repository,
      file: File('/tmp/stale-resolution-after-memo.mp4'),
      releaseInspection: releaseInspection,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: service.file,
      ),
      settle: false,
    );
    await _pumpUntil(
      tester,
      () =>
          service.inspectionStarted.isCompleted &&
          find.byType(ProcedureTimingCard).evaluate().isNotEmpty,
    );
    releaseInspection.complete();
    await _pumpUntil(tester, () => repository.capturedRead.isCompleted);

    await tester.runAsync(
      () => SurgeryRepository(database).updateCaseMemo(
        surgeryRecordId: record.id,
        caseMemo: 'resolverより新しい症例メモ',
      ),
    );
    container.invalidate(surgeryRecordProvider(record.id));
    late SurgeryRecord? providerRecord;
    await tester.runAsync(() async {
      providerRecord = await container.read(
        surgeryRecordProvider(record.id).future,
      );
    });
    expect(providerRecord!.caseMemo, 'resolverより新しい症例メモ');
    await tester.pump();
    await _openTab(tester, '症例メモ', settle: false);
    await _pumpAsyncWork(tester);
    final freshMemo = find.widgetWithText(TextField, '症例全体のメモ');
    expect(freshMemo, findsOneWidget);
    expect(
      tester.widget<TextField>(freshMemo).controller!.text,
      'resolverより新しい症例メモ',
    );

    repository.releaseRead.complete();
    await _pumpUntil(tester, () {
      final memo = find.widgetWithText(TextField, '症例全体のメモ');
      return videoPlatform.createCount == 1 &&
          memo.evaluate().isNotEmpty &&
          tester.widget<TextField>(memo).controller!.text ==
              'resolverより新しい症例メモ';
    }, maximumPumps: 100);

    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.byType(VideoTransportControls), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未来timestampのresolver BでもProviderのA→B→AをABA上書きしない', (
    tester,
  ) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final pathA = await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 7975,
    );
    final pathB = 'videos/${record.id}/aba-b.mp4';
    final repository = _GateNextResolutionRecordRepository(database);
    final releaseInspection = Completer<void>();
    final fileA = File('/tmp/aba-a.mp4');
    final fileB = File('/tmp/aba-b.mp4');
    final service = _ArmingInspectionVideoService(
      repository: repository,
      file: fileA,
      releaseInspection: releaseInspection,
      filesByVideoPath: <String?, File>{pathA: fileA, pathB: fileB},
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      videoStorageRepository: _ReviewStateVideoStorage(resolvedFile: fileA),
      settle: false,
    );
    await _pumpUntil(
      tester,
      () =>
          service.inspectionStarted.isCompleted &&
          find.byType(ProcedureTimingCard).evaluate().isNotEmpty,
    );

    await tester.runAsync(() async {
      await SurgeryRepository(database).updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: pathB,
        videoDisplayName: 'aba-b.mp4',
      );
      // A migrated/future clock value must not outweigh an observed
      // provider generation. DateTime is not a monotonic concurrency token.
      await database.customStatement(
        'UPDATE surgery_records SET updated_at = ? WHERE id = ?',
        <Object?>[DateTime.utc(2100).millisecondsSinceEpoch, record.id],
      );
    });
    releaseInspection.complete();
    await _pumpUntil(tester, () => repository.capturedRead.isCompleted);

    await tester.runAsync(
      () => SurgeryRepository(database).updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: pathA,
        videoDisplayName: 'direct-jump.mp4',
      ),
    );
    container.invalidate(surgeryRecordProvider(record.id));
    await tester.runAsync(
      () => container.read(surgeryRecordProvider(record.id).future),
    );
    await tester.pump();

    repository.releaseRead.complete();
    await _pumpUntil(
      tester,
      () =>
          videoPlatform.createCount == 1 &&
          find.byType(VideoTransportControls).evaluate().isNotEmpty,
      maximumPumps: 100,
    );
    await _pumpAsyncWork(tester);

    late SurgeryRecord? persisted;
    await tester.runAsync(() async {
      persisted = await SurgeryRepository(database).getRecord(record.id);
    });
    expect(persisted!.videoPath, pathA);
    expect(videoPlatform.createCount, 1);
    expect(videoPlatform.createdVideoUris, <String?>[
      Uri.file(fileA.absolute.path).toString(),
    ]);
    expect(
      videoPlatform.createdVideoUris,
      isNot(contains(Uri.file(fileB.absolute.path).toString())),
    );
    expect(videoPlatform.seekRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resolver中にProviderがA→C→Aを観測したら元参照へ戻ってもseekしない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final pathA = await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 7990,
    );
    final pathC = 'videos/${record.id}/observed-aba-c.mp4';
    final repository = _GateNextResolutionRecordRepository(database);
    final releaseInspection = Completer<void>();
    final fileA = File('/tmp/observed-aba-a.mp4');
    final service = _ArmingInspectionVideoService(
      repository: repository,
      file: fileA,
      releaseInspection: releaseInspection,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      videoStorageRepository: _ReviewStateVideoStorage(resolvedFile: fileA),
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      settle: false,
    );
    await _pumpUntil(tester, () => service.inspectionStarted.isCompleted);

    for (final path in <String>[pathC, pathA]) {
      await tester.runAsync(
        () => SurgeryRepository(database).updateVideoReference(
          surgeryRecordId: record.id,
          videoPath: path,
          videoDisplayName: path == pathA
              ? 'direct-jump.mp4'
              : 'observed-aba-c.mp4',
        ),
      );
      container.invalidate(surgeryRecordProvider(record.id));
      await tester.runAsync(
        () => container.read(surgeryRecordProvider(record.id).future),
      );
      await tester.pump();
    }

    releaseInspection.complete();
    await _pumpUntil(tester, () => repository.capturedRead.isCompleted);
    repository.releaseRead.complete();
    await _pumpAsyncWork(tester);

    expect(videoPlatform.createCount, 0);
    expect(videoPlatform.createdVideoUris, isEmpty);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('動画が更新されたため'), findsOneWidget);
    expect(find.text('動画を再確認'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy移行直後に別動画へ差し替わったら移行先へrebindせずseekしない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final legacyPath = '/tmp/${record.id}-legacy-race.mp4';
    final migratedPath = 'videos/${record.id}/migrated-race.mp4';
    final replacementPath = 'videos/${record.id}/replacement-race.mp4';
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 8100,
      videoPath: legacyPath,
    );
    final repository = SurgeryRepository(database);
    final service = _MutatingLegacyResolutionService(
      repository: repository,
      legacyPath: legacyPath,
      legacyFile: File(legacyPath),
      migratedPath: migratedPath,
      migratedFile: File('/tmp/${record.id}-migrated-race.mp4'),
      replacementPath: replacementPath,
      replacementFile: File('/tmp/${record.id}-replacement-race.mp4'),
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/${record.id}-replacement-race.mp4'),
      ),
    );

    late SurgeryRecord? persisted;
    await tester.runAsync(() async {
      persisted = await repository.getRecord(record.id);
    });
    expect(persisted!.videoPath, replacementPath);
    expect(videoPlatform.createCount, 0);
    expect(find.byKey(const Key('review-video-player')), findsNothing);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('動画が更新されたため'), findsOneWidget);
    expect(find.text('動画を再確認'), findsOneWidget);

    await tester.tap(find.text('動画を再確認'));
    await _pumpUntil(
      tester,
      () =>
          videoPlatform.createCount == 1 &&
          find.byKey(const Key('review-video-player')).evaluate().isNotEmpty,
    );
    container.invalidate(surgeryRecordProvider(record.id));
    await _pumpAsyncWork(tester);

    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy解決中に症例が削除されたら旧recordへ戻さずcontrollerを生成しない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final legacyPath = '/tmp/${record.id}-legacy-delete-race.mp4';
    final migratedPath = 'videos/${record.id}/migrated-delete-race.mp4';
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 8150,
      videoPath: legacyPath,
    );
    final repository = SurgeryRepository(database);
    final service = _MutatingLegacyResolutionService(
      repository: repository,
      legacyPath: legacyPath,
      legacyFile: File(legacyPath),
      migratedPath: migratedPath,
      migratedFile: File('/tmp/${record.id}-migrated-delete-race.mp4'),
      deleteDuringResolution: true,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File('/tmp/${record.id}-migrated-delete-race.mp4'),
      ),
    );

    late SurgeryRecord? persisted;
    await tester.runAsync(() async {
      persisted = await repository.getRecord(record.id);
    });
    expect(persisted, isNull);
    expect(videoPlatform.createCount, 0);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('症例が削除されたため'), findsOneWidget);
    expect(find.textContaining('開始位置へ移動しました'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy移行のrecord通知がmetadataより先でも同一動画へ一度だけseekする', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final legacyPath = '/tmp/${record.id}-legacy-notification-order.mp4';
    final managedPath = 'videos/${record.id}/managed-notification-order.mp4';
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 8180,
      videoPath: legacyPath,
    );
    final repository = SurgeryRepository(database);
    final migrationCommitted = Completer<void>();
    final releaseResolution = Completer<void>();
    final managedFile = File(
      '/tmp/${record.id}-managed-notification-order.mp4',
    );
    final service = _NormalizingLegacyVideoService(
      repository: repository,
      legacyPath: legacyPath,
      legacyFile: File(legacyPath),
      managedPath: managedPath,
      managedFile: managedFile,
      migrationCommitted: migrationCommitted,
      releaseResolution: releaseResolution,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: managedFile,
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => migrationCommitted.isCompleted);

    container.invalidate(surgeryRecordProvider(record.id));
    await _pumpAsyncWork(tester);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(
      find.byKey(const Key('direct-jump-preparing-notice')),
      findsOneWidget,
    );

    releaseResolution.complete();
    await _pumpUntil(tester, () => videoPlatform.seekRequests.length == 1);

    expect(videoPlatform.createCount, 1);
    expect(videoPlatform.seekRequests, <Duration>[
      const Duration(milliseconds: 8180),
    ]);
    expect(videoPlatform.pauseCount, greaterThanOrEqualTo(1));
    expect(find.textContaining('動画が更新されたため'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy移行前の旧参照Provider通知を競合と誤認せず同一動画へseekする', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final legacyPath = '/tmp/${record.id}-legacy-source-notification.mp4';
    final managedPath = 'videos/${record.id}/managed-source-notification.mp4';
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 8185,
      videoPath: legacyPath,
    );
    final repository = SurgeryRepository(database);
    final beforeMigrationStarted = Completer<void>();
    final releaseBeforeMigration = Completer<void>();
    final managedFile = File(
      '/tmp/${record.id}-managed-source-notification.mp4',
    );
    final service = _NormalizingLegacyVideoService(
      repository: repository,
      legacyPath: legacyPath,
      legacyFile: File(legacyPath),
      managedPath: managedPath,
      managedFile: managedFile,
      beforeMigrationStarted: beforeMigrationStarted,
      releaseBeforeMigration: releaseBeforeMigration,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: managedFile,
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => beforeMigrationStarted.isCompleted);

    // Deliver the unchanged legacy A reference while its A -> managed-B
    // normalization is still blocked. This is provider synchronization, not
    // an observed A -> C -> A replacement sequence.
    container.invalidate(surgeryRecordProvider(record.id));
    await tester.runAsync(
      () => container.read(surgeryRecordProvider(record.id).future),
    );
    await tester.pump();
    expect(videoPlatform.createCount, 0);
    expect(
      find.byKey(const Key('direct-jump-preparing-notice')),
      findsOneWidget,
    );

    releaseBeforeMigration.complete();
    await _pumpUntil(tester, () => videoPlatform.seekRequests.length == 1);

    expect(videoPlatform.createCount, 1);
    expect(videoPlatform.seekRequests, <Duration>[
      const Duration(milliseconds: 8185),
    ]);
    expect(videoPlatform.pauseCount, greaterThanOrEqualTo(1));
    expect(find.textContaining('動画が更新されたため'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy移行B後にfinal readがAならB fileをA参照へbindしない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final legacyPath = '/tmp/${record.id}-legacy-before-final-read-aba.mp4';
    final managedPath = 'videos/${record.id}/managed-before-final-read-aba.mp4';
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 8186,
      videoPath: legacyPath,
    );
    final repository = SurgeryRepository(database);
    final migrationCommitted = Completer<void>();
    final releaseResolution = Completer<void>();
    final managedFile = File(
      '/tmp/${record.id}-managed-before-final-read-aba.mp4',
    );
    final service = _NormalizingLegacyVideoService(
      repository: repository,
      legacyPath: legacyPath,
      legacyFile: File(legacyPath),
      managedPath: managedPath,
      managedFile: managedFile,
      migrationCommitted: migrationCommitted,
      releaseResolution: releaseResolution,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: managedFile,
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => migrationCommitted.isCompleted);
    await tester.runAsync(
      () => repository.updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: legacyPath,
        videoDisplayName: 'legacy-before-final-read-aba.mp4',
      ),
    );
    releaseResolution.complete();
    await _pumpAsyncWork(tester);

    late SurgeryRecord? persisted;
    await tester.runAsync(() async {
      persisted = await repository.getRecord(record.id);
    });
    expect(persisted!.videoPath, legacyPath);
    expect(videoPlatform.createCount, 0);
    expect(videoPlatform.createdVideoUris, isEmpty);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('動画が更新されたため'), findsOneWidget);
    expect(find.text('動画を再確認'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy移行中にA→C→A→Bを観測したらexact metadataでもseekしない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final legacyPath = '/tmp/${record.id}-legacy-observed-c.mp4';
    final managedPath = 'videos/${record.id}/managed-observed-c.mp4';
    final pathC = 'videos/${record.id}/replacement-observed-c.mp4';
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 8186,
      videoPath: legacyPath,
    );
    final repository = SurgeryRepository(database);
    final beforeMigrationStarted = Completer<void>();
    final releaseBeforeMigration = Completer<void>();
    final migrationCommitted = Completer<void>();
    final releaseResolution = Completer<void>();
    final managedFile = File('/tmp/${record.id}-managed-observed-c.mp4');
    final service = _NormalizingLegacyVideoService(
      repository: repository,
      legacyPath: legacyPath,
      legacyFile: File(legacyPath),
      managedPath: managedPath,
      managedFile: managedFile,
      beforeMigrationStarted: beforeMigrationStarted,
      releaseBeforeMigration: releaseBeforeMigration,
      migrationCommitted: migrationCommitted,
      releaseResolution: releaseResolution,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: managedFile,
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => beforeMigrationStarted.isCompleted);
    for (final path in <String>[pathC, legacyPath]) {
      await tester.runAsync(
        () => repository.updateVideoReference(
          surgeryRecordId: record.id,
          videoPath: path,
          videoDisplayName: path == legacyPath
              ? 'legacy-observed-c.mp4'
              : 'replacement-observed-c.mp4',
        ),
      );
      container.invalidate(surgeryRecordProvider(record.id));
      await tester.runAsync(
        () => container.read(surgeryRecordProvider(record.id).future),
      );
      await tester.pump();
    }
    releaseBeforeMigration.complete();
    await _pumpUntil(tester, () => migrationCommitted.isCompleted);
    container.invalidate(surgeryRecordProvider(record.id));
    await tester.runAsync(
      () => container.read(surgeryRecordProvider(record.id).future),
    );
    await tester.pump();
    releaseResolution.complete();
    await _pumpAsyncWork(tester);

    late SurgeryRecord? persisted;
    await tester.runAsync(() async {
      persisted = await repository.getRecord(record.id);
    });
    expect(persisted!.videoPath, managedPath);
    expect(videoPlatform.createCount, 0);
    expect(videoPlatform.createdVideoUris, isEmpty);
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('動画が更新されたため'), findsOneWidget);
    expect(find.text('動画を再確認'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy最終B read後にDBがAへ戻ったら旧B controllerを生成しない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final legacyPath = '/tmp/${record.id}-legacy-final-read-aba.mp4';
    final managedPath = 'videos/${record.id}/managed-final-read-aba.mp4';
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 8187,
      videoPath: legacyPath,
    );
    final repository = _GateNextResolutionRecordRepository(database);
    final managedFile = File('/tmp/${record.id}-managed-final-read-aba.mp4');
    final service = _NormalizingLegacyVideoService(
      repository: repository,
      legacyPath: legacyPath,
      legacyFile: File(legacyPath),
      managedPath: managedPath,
      managedFile: managedFile,
      beforeResolutionReturn: repository.gateNextRead,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    final container = await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: managedFile,
      ),
      settle: false,
    );
    await _pumpUntil(tester, () => repository.capturedRead.isCompleted);

    await tester.runAsync(
      () => SurgeryRepository(database).updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: legacyPath,
        videoDisplayName: 'legacy-final-read-aba.mp4',
      ),
    );
    container.invalidate(surgeryRecordProvider(record.id));
    await tester.runAsync(
      () => container.read(surgeryRecordProvider(record.id).future),
    );
    await tester.pump();

    repository.releaseRead.complete();
    await _pumpAsyncWork(tester);

    late SurgeryRecord? persisted;
    await tester.runAsync(() async {
      persisted = await SurgeryRepository(database).getRecord(record.id);
    });
    expect(persisted!.videoPath, legacyPath);
    expect(videoPlatform.createCount, 0);
    expect(videoPlatform.createdVideoUris, isEmpty);
    expect(
      videoPlatform.createdVideoUris,
      isNot(contains(Uri.file(managedFile.absolute.path).toString())),
    );
    expect(videoPlatform.seekRequests, isEmpty);
    expect(find.textContaining('動画が更新されたため'), findsOneWidget);
    expect(find.text('動画を再確認'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final unavailable in <(RecordVideoStateKind, String)>[
    (RecordVideoStateKind.missing, '登録された動画の実体が見つかりません'),
    (RecordVideoStateKind.checkFailed, '動画を確認できませんでした'),
  ]) {
    testWidgets('通常導線のlegacy解決中に別参照が${unavailable.$1.name}なら旧fileを再利用しない', (
      tester,
    ) async {
      final (database, record) = await createRecord(tester);
      addTearDown(database.close);
      final legacyPath = '/tmp/${record.id}-legacy-${unavailable.$1.name}.mp4';
      final migratedPath =
          'videos/${record.id}/migrated-${unavailable.$1.name}.mp4';
      final replacementPath =
          'videos/${record.id}/replacement-${unavailable.$1.name}.mp4';
      await _configureDirectJumpRecord(
        tester,
        database,
        record.id,
        step: SurgicalStep.capsulorhexis,
        startMilliseconds: 8190,
        videoPath: legacyPath,
      );
      final repository = SurgeryRepository(database);
      final service = _MutatingLegacyResolutionService(
        repository: repository,
        legacyPath: legacyPath,
        legacyFile: File(legacyPath),
        migratedPath: migratedPath,
        migratedFile: File(
          '/tmp/${record.id}-migrated-${unavailable.$1.name}.mp4',
        ),
        replacementPath: replacementPath,
        replacementStateKind: unavailable.$1,
      );
      final videoPlatform = _installDirectJumpVideoPlatform(
        _DirectJumpVideoPlatform(),
      );

      await pumpScreen(
        tester,
        database,
        record.id,
        repository: repository,
        recordVideoService: service,
        videoStorageRepository: const _ReviewStateVideoStorage(),
      );

      late SurgeryRecord? persisted;
      await tester.runAsync(() async {
        persisted = await repository.getRecord(record.id);
      });
      expect(persisted!.videoPath, replacementPath);
      expect(videoPlatform.createCount, 0);
      expect(videoPlatform.seekRequests, isEmpty);
      expect(find.byType(VideoTransportControls), findsNothing);
      expect(find.textContaining(unavailable.$2), findsOneWidget);
      expect(find.text('動画を再確認'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('legacy同一動画の管理参照正規化はintentを維持して一度だけseekする', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final legacyPath = '/tmp/${record.id}-legacy.mp4';
    final managedPath = 'videos/${record.id}/managed.mp4';
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 8200,
      videoPath: legacyPath,
    );
    final repository = SurgeryRepository(database);
    final managedFile = File('/tmp/${record.id}-managed.mp4');
    final service = _NormalizingLegacyVideoService(
      repository: repository,
      legacyPath: legacyPath,
      legacyFile: File(legacyPath),
      managedPath: managedPath,
      managedFile: managedFile,
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: managedFile,
      ),
    );

    late SurgeryRecord? migrated;
    await tester.runAsync(() async {
      migrated = await repository.getRecord(record.id);
    });
    expect(migrated!.videoPath, managedPath);
    expect(videoPlatform.createCount, 1);
    expect(videoPlatform.seekRequests, <Duration>[
      const Duration(milliseconds: 8200),
    ]);
    expect(videoPlatform.pauseCount, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy移行失敗時は外部原本の参照を維持して一度だけseekする', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final legacyPath = '/tmp/${record.id}-legacy-fallback.mp4';
    await _configureDirectJumpRecord(
      tester,
      database,
      record.id,
      step: SurgicalStep.capsulorhexis,
      startMilliseconds: 8600,
      videoPath: legacyPath,
    );
    final repository = SurgeryRepository(database);
    final service = _LegacyFallbackVideoService(
      repository: repository,
      legacyPath: legacyPath,
      legacyFile: File(legacyPath),
    );
    final videoPlatform = _installDirectJumpVideoPlatform(
      _DirectJumpVideoPlatform(),
    );

    await pumpScreen(
      tester,
      database,
      record.id,
      repository: repository,
      recordVideoService: service,
      initialStepStorageId: SurgicalStep.capsulorhexis.storageId,
      videoStorageRepository: _ReviewStateVideoStorage(
        resolvedFile: File(legacyPath),
      ),
    );

    late SurgeryRecord? persisted;
    await tester.runAsync(() async {
      persisted = await repository.getRecord(record.id);
    });
    expect(persisted!.videoPath, legacyPath);
    expect(videoPlatform.createCount, 1);
    expect(videoPlatform.seekRequests, <Duration>[
      const Duration(milliseconds: 8600),
    ]);
    expect(videoPlatform.pauseCount, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });
}

TextButton _saveButton(WidgetTester tester) {
  return tester.widget<TextButton>(find.byKey(const Key('review-save-button')));
}

Future<String> _configureDirectJumpRecord(
  WidgetTester tester,
  AppDatabase database,
  String recordId, {
  required SurgicalStep step,
  required int startMilliseconds,
  String? videoPath,
}) async {
  final path = videoPath ?? 'videos/$recordId/direct-jump.mp4';
  await tester.runAsync(() async {
    final repository = SurgeryRepository(database);
    await repository.ensureStepReviews(recordId);
    await repository.updateVideoReference(
      surgeryRecordId: recordId,
      videoPath: path,
      videoDisplayName: 'direct-jump.mp4',
    );
    final review = (await repository.getStepReview(
      surgeryRecordId: recordId,
      step: step,
    ))!;
    await repository.saveStepTiming(
      review: review.copyWith(startMilliseconds: startMilliseconds),
      expectedVideoPath: path,
    );
  });
  return path;
}

Future<int> _configureRichDirectJumpRecord(
  WidgetTester tester,
  AppDatabase database,
  String recordId,
) async {
  const targetStep = SurgicalStep.capsulorhexis;
  final targetStart =
      (surgicalStepsInDisplayOrder.indexOf(targetStep) + 1) * 1000;
  await tester.runAsync(() async {
    final repository = SurgeryRepository(database);
    final path = 'videos/$recordId/rich-direct-jump.mp4';
    final reviews = await repository.ensureStepReviews(recordId);
    await repository.updateVideoReference(
      surgeryRecordId: recordId,
      videoPath: path,
      videoDisplayName: 'rich-direct-jump-original.mp4',
    );
    final persistedTimings = <SurgicalStepReview>[];
    for (var index = 0; index < reviews.length; index++) {
      final review = reviews[index];
      if (review.step == SurgicalStep.sidePortCreation) {
        persistedTimings.add(
          await repository.saveStepSkipped(
            review: review,
            isSkipped: true,
            expectedVideoPath: path,
          ),
        );
        continue;
      }
      final startMilliseconds = (index + 1) * 1000;
      persistedTimings.add(
        await repository.saveStepTiming(
          review: review.copyWith(
            startMilliseconds: startMilliseconds,
            endMilliseconds: startMilliseconds + 600,
          ),
          expectedVideoPath: path,
        ),
      );
    }
    await repository.saveReviewContent(
      surgeryRecordId: recordId,
      reviews: <SurgicalStepReview>[
        for (var index = 0; index < persistedTimings.length; index++)
          persistedTimings[index].copyWith(
            rating:
                StepRating.values[(index % (StepRating.values.length - 1)) + 1],
            reflection: '保持対象 ${persistedTimings[index].step.storageId} $index',
          ),
      ],
      caseMemo: '直接ジャンプで変更しない症例メモ',
    );
  });
  return targetStart;
}

Future<Map<String, Object?>> _capturePersistentReviewSnapshot(
  WidgetTester tester,
  AppDatabase database,
  String recordId,
) async {
  late Map<String, Object?> snapshot;
  await tester.runAsync(() async {
    final repository = SurgeryRepository(database);
    final record = (await repository.getRecord(recordId))!;
    final reviews = <SurgicalStepReview>[];
    for (final step in surgicalStepsInDisplayOrder) {
      reviews.add(
        (await repository.getStepReview(
          surgeryRecordId: recordId,
          step: step,
        ))!,
      );
    }
    snapshot = <String, Object?>{
      'record': _persistentRecordFields(record),
      'reviews': <Map<String, Object?>>[
        for (final review in reviews) _persistentReviewFields(review),
      ],
    };
  });
  return snapshot;
}

Map<String, Object?> _persistentRecordFields(SurgeryRecord record) {
  return <String, Object?>{
    'id': record.id,
    'surgeryDate': record.surgeryDate.millisecondsSinceEpoch,
    'eyeSide': record.eyeSide.name,
    'reviewStatus': record.reviewStatus.name,
    'reviewSchemaVersion': record.reviewSchemaVersion,
    'videoPath': record.videoPath,
    'videoDisplayName': record.videoDisplayName,
    'caseMemo': record.caseMemo,
    'createdAt': record.createdAt.millisecondsSinceEpoch,
    'updatedAt': record.updatedAt.millisecondsSinceEpoch,
  };
}

Map<String, Object?> _persistentReviewFields(SurgicalStepReview review) {
  return <String, Object?>{
    'id': review.id,
    'surgeryRecordId': review.surgeryRecordId,
    'step': review.step.storageId,
    'startMilliseconds': review.startMilliseconds,
    'endMilliseconds': review.endMilliseconds,
    'isSkipped': review.isSkipped,
    'rating': review.rating.name,
    'reflection': review.reflection,
    'createdAt': review.createdAt.millisecondsSinceEpoch,
    'updatedAt': review.updatedAt.millisecondsSinceEpoch,
  };
}

Future<int> _countPersistedStepRows(
  WidgetTester tester,
  AppDatabase database,
  String recordId,
) async {
  var count = 0;
  await tester.runAsync(() async {
    final rows = await database
        .customSelect('SELECT surgery_record_id FROM surgical_step_reviews')
        .get();
    count = rows
        .where((row) => row.read<String>('surgery_record_id') == recordId)
        .length;
  });
  return count;
}

_DirectJumpVideoPlatform _installDirectJumpVideoPlatform(
  _DirectJumpVideoPlatform platform,
) {
  final original = VideoPlayerPlatform.instance;
  VideoPlayerPlatform.instance = platform;
  addTearDown(() => VideoPlayerPlatform.instance = original);
  return platform;
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maximumPumps = 30,
}) async {
  for (var attempt = 0; attempt < maximumPumps && !condition(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(condition(), isTrue, reason: '非同期条件が期限内に成立しませんでした。');
}

PopScope<void> _popScope(WidgetTester tester) {
  return tester.widget<PopScope<void>>(
    find.byKey(const Key('review-pop-scope')),
  );
}

Future<void> _pumpAsyncWork(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _chooseTimelineIdentity(WidgetTester tester, Key choiceKey) async {
  await tester.tap(find.byKey(choiceKey));
  await tester.pump();
  await tester.tap(find.byKey(const Key('continue-with-timeline-identity')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _openCaseMemoTab(WidgetTester tester) async {
  await _openTab(tester, '症例メモ');
}

Future<void> _scrollToStepNotes(WidgetTester tester, SurgicalStep step) async {
  await tester.dragUntilVisible(
    find.text('自己評価・反省点'),
    find.byKey(ValueKey('review-step-content-${step.name}')),
    const Offset(0, -240),
  );
  await tester.pumpAndSettle();
}

Future<void> _openTab(
  WidgetTester tester,
  String label, {
  bool settle = true,
}) async {
  await tester.ensureVisible(find.widgetWithText(Tab, label));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
  await tester.tap(find.widgetWithText(Tab, label));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

class _DirectJumpOrderingRepository extends SurgeryRepository {
  _DirectJumpOrderingRepository(super.database)
    : delegate = SurgeryRepository(database);

  final SurgeryRepository delegate;
  final Completer<void> firstFreshRecordReadStarted = Completer<void>();
  final Completer<void> releaseFirstFreshRecordRead = Completer<void>();
  final Completer<void> initialFreshReadsCompleted = Completer<void>();
  final Completer<void> draftReviewsReadStarted = Completer<void>();
  final Completer<void> releaseDraftReviewsRead = Completer<void>();
  var _recordReadCount = 0;

  @override
  Future<SurgeryRecord?> getRecord(String id) async {
    _recordReadCount++;
    if (_recordReadCount == 1) {
      firstFreshRecordReadStarted.complete();
      await releaseFirstFreshRecordRead.future;
    }
    final record = await delegate.getRecord(id);
    if (_recordReadCount == 2 && !initialFreshReadsCompleted.isCompleted) {
      initialFreshReadsCompleted.complete();
    }
    return record;
  }

  @override
  Future<SurgicalStepReview?> getStepReview({
    required String surgeryRecordId,
    required SurgicalStep step,
  }) {
    return delegate.getStepReview(surgeryRecordId: surgeryRecordId, step: step);
  }

  @override
  Future<List<SurgicalStepReview>> ensureStepReviews(
    String surgeryRecordId,
  ) async {
    if (!draftReviewsReadStarted.isCompleted) {
      draftReviewsReadStarted.complete();
    }
    await releaseDraftReviewsRead.future;
    return delegate.ensureStepReviews(surgeryRecordId);
  }
}

class _FailingReviewRepository extends SurgeryRepository {
  _FailingReviewRepository(super.database);

  int saveCalls = 0;

  @override
  Future<ReviewSaveResult> saveReviewContent({
    required String surgeryRecordId,
    required List<SurgicalStepReview> reviews,
    required String caseMemo,
  }) async {
    saveCalls++;
    throw StateError('制御可能な保存失敗');
  }
}

class _ControlledReviewRepository extends SurgeryRepository {
  _ControlledReviewRepository(super.database);

  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int saveCalls = 0;

  @override
  Future<ReviewSaveResult> saveReviewContent({
    required String surgeryRecordId,
    required List<SurgicalStepReview> reviews,
    required String caseMemo,
  }) async {
    saveCalls++;
    if (!started.isCompleted) {
      started.complete();
    }
    await release.future;
    return super.saveReviewContent(
      surgeryRecordId: surgeryRecordId,
      reviews: reviews,
      caseMemo: caseMemo,
    );
  }
}

class _ControlledTimingRepository extends SurgeryRepository {
  _ControlledTimingRepository(super.database);

  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int saveCalls = 0;

  @override
  Future<SurgicalStepReview> saveStepTiming({
    required SurgicalStepReview review,
    required String? expectedVideoPath,
  }) async {
    saveCalls++;
    if (!started.isCompleted) {
      started.complete();
    }
    await release.future;
    return super.saveStepTiming(
      review: review,
      expectedVideoPath: expectedVideoPath,
    );
  }
}

class _FailingSkippedRepository extends SurgeryRepository {
  _FailingSkippedRepository(super.database);

  int saveCalls = 0;

  @override
  Future<SurgicalStepReview> saveStepSkipped({
    required SurgicalStepReview review,
    required bool isSkipped,
    required String? expectedVideoPath,
  }) async {
    saveCalls++;
    throw StateError('制御可能なskip保存失敗');
  }
}

class _ControlledSkippedRepository extends SurgeryRepository {
  _ControlledSkippedRepository(super.database);

  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int saveCalls = 0;

  @override
  Future<SurgicalStepReview> saveStepSkipped({
    required SurgicalStepReview review,
    required bool isSkipped,
    required String? expectedVideoPath,
  }) async {
    saveCalls++;
    if (!started.isCompleted) {
      started.complete();
    }
    await release.future;
    return super.saveStepSkipped(
      review: review,
      isSkipped: isSkipped,
      expectedVideoPath: expectedVideoPath,
    );
  }
}

class _CountingReviewRepository extends SurgeryRepository {
  _CountingReviewRepository(super.database);

  int saveCalls = 0;

  @override
  Future<ReviewSaveResult> saveReviewContent({
    required String surgeryRecordId,
    required List<SurgicalStepReview> reviews,
    required String caseMemo,
  }) {
    saveCalls++;
    return super.saveReviewContent(
      surgeryRecordId: surgeryRecordId,
      reviews: reviews,
      caseMemo: caseMemo,
    );
  }
}

class _CommitThenFailReadsRepository extends SurgeryRepository {
  _CommitThenFailReadsRepository(
    super.database, {
    this.failAfterReviewSave = false,
    this.failAfterTimingSave = false,
  });

  final bool failAfterReviewSave;
  final bool failAfterTimingSave;
  bool failReads = false;

  @override
  Future<SurgeryRecord?> getRecord(String id) {
    if (failReads) {
      return Future<SurgeryRecord?>.error(StateError('制御可能な症例再読込失敗'));
    }
    return super.getRecord(id);
  }

  @override
  Future<List<SurgicalStepReview>> ensureStepReviews(String surgeryRecordId) {
    if (failReads) {
      return Future<List<SurgicalStepReview>>.error(StateError('制御可能な工程再読込失敗'));
    }
    return super.ensureStepReviews(surgeryRecordId);
  }

  @override
  Future<ReviewSaveResult> saveReviewContent({
    required String surgeryRecordId,
    required List<SurgicalStepReview> reviews,
    required String caseMemo,
  }) async {
    final result = await super.saveReviewContent(
      surgeryRecordId: surgeryRecordId,
      reviews: reviews,
      caseMemo: caseMemo,
    );
    if (failAfterReviewSave) {
      failReads = true;
    }
    return result;
  }

  @override
  Future<SurgicalStepReview> saveStepTiming({
    required SurgicalStepReview review,
    required String? expectedVideoPath,
  }) async {
    final result = await super.saveStepTiming(
      review: review,
      expectedVideoPath: expectedVideoPath,
    );
    if (failAfterTimingSave) {
      failReads = true;
    }
    return result;
  }
}

class _MigratingVideoStorage implements VideoStorageRepository {
  _MigratingVideoStorage(this.videoFile);

  final File videoFile;

  String relativePathFor(String recordId) => 'videos/$recordId/migrated.mp4';

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    return StoredVideo(
      relativePath: relativePathFor(surgeryRecordId),
      originalFileName: candidate.displayName,
      sizeBytes: await videoFile.length(),
      sha256: 'test-sha256',
      playbackEvidence: candidate.playbackEvidence,
    );
  }

  @override
  Future<File?> resolveVideo(String relativePath) async => null;

  @override
  Future<void> deleteVideo(String relativePath) async {}

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) async {}
}

class _ReviewStateVideoStorage implements VideoStorageRepository {
  const _ReviewStateVideoStorage({this.resolveError, this.resolvedFile});

  final Object? resolveError;
  final File? resolvedFile;

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<File?> resolveVideo(String relativePath) async {
    final error = resolveError;
    if (error != null) {
      throw error;
    }
    return resolvedFile;
  }

  @override
  Future<void> deleteVideo(String relativePath) async {}

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) async {}
}

class _SwitchableInspectionVideoService extends RecordVideoService {
  _SwitchableInspectionVideoService({
    required SurgeryRepository repository,
    required this.file,
    this.inspectError,
  }) : super(
         surgeryRepository: repository,
         videoStorageRepository: _ReviewStateVideoStorage(resolvedFile: file),
         videoImportPreflight: const _ReadyVideoImportPreflight(),
       );

  final File file;
  Object? inspectError;

  @override
  Future<RecordVideoState> inspectVideoState(SurgeryRecord record) async {
    final error = inspectError;
    if (error != null) {
      throw error;
    }
    return RecordVideoState(RecordVideoStateKind.availableManaged, file: file);
  }
}

class _GateNextResolutionRecordRepository extends SurgeryRepository {
  _GateNextResolutionRecordRepository(super.database, {this.gatedReadError});

  final Object? gatedReadError;
  final Completer<void> capturedRead = Completer<void>();
  final Completer<void> releaseRead = Completer<void>();
  var _gateArmed = false;
  var _readsUntilGate = 0;

  void gateNextRead() => gateAfterReads(1);

  void gateAfterReads(int readCount) {
    assert(readCount > 0);
    _gateArmed = true;
    _readsUntilGate = readCount;
  }

  @override
  Future<SurgeryRecord?> getRecord(String id) async {
    final captured = await super.getRecord(id);
    if (_gateArmed && _readsUntilGate > 0) {
      _readsUntilGate--;
    }
    if (_gateArmed && _readsUntilGate == 0) {
      _gateArmed = false;
      capturedRead.complete();
      await releaseRead.future;
      final error = gatedReadError;
      if (error != null) {
        throw error;
      }
    }
    return captured;
  }
}

class _ArmingInspectionVideoService extends RecordVideoService {
  _ArmingInspectionVideoService({
    required this.repository,
    required this.file,
    required this.releaseInspection,
    this.filesByVideoPath = const <String?, File>{},
    this.readsBeforeGate = 1,
    this.inspectError,
  }) : super(
         surgeryRepository: repository,
         videoStorageRepository: _ReviewStateVideoStorage(resolvedFile: file),
         videoImportPreflight: const _ReadyVideoImportPreflight(),
       );

  final _GateNextResolutionRecordRepository repository;
  final File file;
  final Map<String?, File> filesByVideoPath;
  final int readsBeforeGate;
  Object? inspectError;
  final Completer<void> inspectionStarted = Completer<void>();
  final Completer<void> releaseInspection;
  bool _didArm = false;

  @override
  Future<RecordVideoState> inspectVideoState(SurgeryRecord record) async {
    if (!_didArm) {
      _didArm = true;
      inspectionStarted.complete();
      await releaseInspection.future;
      final error = inspectError;
      if (error != null) {
        throw error;
      }
      repository.gateAfterReads(readsBeforeGate);
    }
    return RecordVideoState(
      RecordVideoStateKind.availableManaged,
      file: filesByVideoPath[record.videoPath] ?? file,
    );
  }
}

class _CountingResolvedVideoStorage implements VideoStorageRepository {
  _CountingResolvedVideoStorage(this.file);

  final File file;
  var resolveCalls = 0;

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<File?> resolveVideo(String relativePath) async {
    resolveCalls++;
    return file;
  }

  @override
  Future<void> deleteVideo(String relativePath) async {}

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) async {}
}

class _PendingCleanupVideoService extends RecordVideoService {
  _PendingCleanupVideoService(this.repository)
    : super(
        surgeryRepository: repository,
        videoStorageRepository: const _ReviewStateVideoStorage(),
        videoImportPreflight: const _ReadyVideoImportPreflight(),
      );

  final SurgeryRepository repository;

  @override
  Future<VideoImportOutcome<SurgeryRecord>> attachVideoToRecord({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoTimelineIdentityDeclaration timelineIdentityDeclaration =
        VideoTimelineIdentityDeclaration.noRecordedTimingsObserved,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    final relativePath = 'videos/$surgeryRecordId/pending-cleanup.mp4';
    await repository.updateVideoReferenceIfCurrent(
      surgeryRecordId: surgeryRecordId,
      expectedVideoPath: null,
      videoPath: relativePath,
      videoDisplayName: candidate.displayName,
    );
    return VideoImportOutcome(
      value: (await repository.getRecord(surgeryRecordId))!,
      maintenanceOutcome: VideoMaintenanceOutcome.pending,
    );
  }
}

class _RecordingReviewVideoStorage implements VideoStorageRepository {
  _RecordingReviewVideoStorage({this.resolvedFile});

  final File? resolvedFile;
  int importCalls = 0;

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    importCalls++;
    cancellationToken?.throwIfCancelled(VideoImportPhase.copy);
    return StoredVideo(
      relativePath:
          'videos/$surgeryRecordId/review-import-$importCalls.${candidate.normalizedExtension}',
      originalFileName: candidate.displayName,
      sizeBytes: candidate.sourceSize,
      sha256: candidate.sha256,
      playbackEvidence: candidate.playbackEvidence,
    );
  }

  @override
  Future<File?> resolveVideo(String relativePath) async => resolvedFile;

  @override
  Future<void> deleteVideo(String relativePath) async {}

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) async {}
}

class _RecordingReviewVideoService extends RecordVideoService {
  _RecordingReviewVideoService(
    SurgeryRepository repository,
    _RecordingReviewVideoStorage storage,
    VideoImportPreflight preflight,
  ) : super(
        surgeryRepository: repository,
        videoStorageRepository: storage,
        videoImportPreflight: preflight,
      );

  int attachCalls = 0;
  int attachWithTimingResetCalls = 0;
  int relinkCalls = 0;
  int replaceCalls = 0;

  int get totalMutationCalls =>
      attachCalls + attachWithTimingResetCalls + relinkCalls + replaceCalls;

  @override
  Future<VideoImportOutcome<SurgeryRecord>> attachVideoToRecord({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoTimelineIdentityDeclaration timelineIdentityDeclaration =
        VideoTimelineIdentityDeclaration.noRecordedTimingsObserved,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    attachCalls++;
    return super.attachVideoToRecord(
      surgeryRecordId: surgeryRecordId,
      candidate: candidate,
      timelineIdentityDeclaration: timelineIdentityDeclaration,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  @override
  Future<VideoImportOutcome<SurgeryRecord>> attachWithTimingReset({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    attachWithTimingResetCalls++;
    return super.attachWithTimingReset(
      surgeryRecordId: surgeryRecordId,
      candidate: candidate,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  @override
  Future<VideoImportOutcome<SurgeryRecord>> relinkSameVideo({
    required String surgeryRecordId,
    required String expectedVideoPath,
    required VerifiedVideoCandidate candidate,
    VideoTimelineIdentityDeclaration timelineIdentityDeclaration =
        VideoTimelineIdentityDeclaration.noRecordedTimingsObserved,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    relinkCalls++;
    return super.relinkSameVideo(
      surgeryRecordId: surgeryRecordId,
      expectedVideoPath: expectedVideoPath,
      candidate: candidate,
      timelineIdentityDeclaration: timelineIdentityDeclaration,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  @override
  Future<VideoImportOutcome<SurgeryRecord>> replaceVideoForRecord({
    required String surgeryRecordId,
    required String expectedVideoPath,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    replaceCalls++;
    return super.replaceVideoForRecord(
      surgeryRecordId: surgeryRecordId,
      expectedVideoPath: expectedVideoPath,
      candidate: candidate,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }
}

class _ReadyVideoImportPreflight extends PassThroughVideoImportPreflight {
  const _ReadyVideoImportPreflight();

  @override
  Future<VideoSelectionPreflightResult> inspectSelection(
    SelectedSurgeryVideo selection, {
    required int selectionGeneration,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    return VideoSelectionReady(
      _candidateForSelection(selection, selectionGeneration),
    );
  }
}

class _NonCandidateVideoImportPreflight
    extends PassThroughVideoImportPreflight {
  const _NonCandidateVideoImportPreflight();

  @override
  Future<VideoSelectionPreflightResult> inspectSelection(
    SelectedSurgeryVideo selection, {
    required int selectionGeneration,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    return const VideoSelectionNonCandidate(normalizedExtension: 'avi');
  }
}

class _FailingVideoImportPreflight extends PassThroughVideoImportPreflight {
  const _FailingVideoImportPreflight();

  @override
  Future<VideoSelectionPreflightResult> inspectSelection(
    SelectedSurgeryVideo selection, {
    required int selectionGeneration,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    throw const VideoImportException(
      code: VideoImportErrorCode.unplayableMedia,
      phase: VideoImportPhase.sourcePlayback,
      internalReason: VideoImportInternalReasonV1.playerInitFailed,
      primaryRecoveryAction: VideoImportRecoveryAction.dismiss,
    );
  }
}

VerifiedVideoCandidate _candidateForSelection(
  SelectedSurgeryVideo selection,
  int selectionGeneration,
) {
  return VerifiedVideoCandidate(
    path: selection.path,
    displayName: selection.displayName,
    normalizedExtension: const VideoSelectionPolicy().normalizeExtension(
      selection.displayName,
    ),
    selectionGeneration: selectionGeneration,
    sourceSize: 2048,
    sourceModifiedAt: DateTime.utc(2026, 8, 15),
    sha256: 'synthetic-review-video-sha256',
    playbackEvidence: testVideoPlaybackEvidence,
  );
}

class _CountingVideoPicker implements SurgeryVideoPicker {
  _CountingVideoPicker(this.result);

  final SelectedSurgeryVideo? result;
  int calls = 0;

  @override
  Future<SelectedSurgeryVideo?> pickVideo() async {
    calls++;
    return result;
  }
}

class _DirectJumpVideoPlatform extends VideoPlayerPlatform {
  _DirectJumpVideoPlatform({
    this.duration = const Duration(minutes: 2),
    this.failingPlayerIds = const <int>{},
    this.initializationGate,
    this.runtimeErrorGate,
    this.seekGate,
    this.disposeGate,
    this.failSeek = false,
    this.failDispose = false,
    this.trackEventCancellation = false,
  });

  final Duration? duration;
  final Set<int> failingPlayerIds;
  final Completer<void>? initializationGate;
  final Completer<void>? runtimeErrorGate;
  final Completer<void>? seekGate;
  final Completer<void>? disposeGate;
  final bool failSeek;
  final bool failDispose;
  final bool trackEventCancellation;
  final Set<int> activePlayerIds = <int>{};
  final Set<int> disposedPlayerIds = <int>{};
  final Set<int> eventCancellationStartedPlayerIds = <int>{};
  final Set<int> initializedPlayerIds = <int>{};
  final List<String?> createdVideoUris = <String?>[];
  final List<Duration> seekRequests = <Duration>[];
  final List<int> seekPlayerIds = <int>[];
  final Map<int, Duration> _positions = <int, Duration>{};
  var _nextPlayerId = 1;
  var createCount = 0;
  var getPositionCount = 0;
  var playCount = 0;
  var pauseCount = 0;

  void setActivePosition(Duration position) {
    for (final playerId in activePlayerIds) {
      _positions[playerId] = position;
    }
  }

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final playerId = _nextPlayerId++;
    createCount++;
    createdVideoUris.add(options.dataSource.uri);
    activePlayerIds.add(playerId);
    _positions[playerId] = Duration.zero;
    return playerId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    final events = _videoEventsFor(playerId);
    if (!trackEventCancellation) {
      return events;
    }
    late final StreamController<VideoEvent> controller;
    StreamSubscription<VideoEvent>? subscription;
    controller = StreamController<VideoEvent>(
      onListen: () {
        subscription = events.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onCancel: () {
        eventCancellationStartedPlayerIds.add(playerId);
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  Stream<VideoEvent> _videoEventsFor(int playerId) async* {
    final gate = initializationGate;
    if (gate != null) {
      await gate.future;
    }
    if (failingPlayerIds.contains(playerId)) {
      throw PlatformException(
        code: 'controlled_video_initialization_failure',
        message: '制御可能な動画初期化失敗',
      );
    }
    initializedPlayerIds.add(playerId);
    yield VideoEvent(
      eventType: VideoEventType.initialized,
      duration: duration,
      size: const Size(1920, 1080),
    );
    final errorGate = runtimeErrorGate;
    if (errorGate != null) {
      await errorGate.future;
      throw PlatformException(
        code: 'controlled_runtime_video_error',
        message: '制御可能な初期化後エラー',
      );
    }
  }

  @override
  Future<void> dispose(int playerId) async {
    disposedPlayerIds.add(playerId);
    activePlayerIds.remove(playerId);
    _positions.remove(playerId);
    final gate = disposeGate;
    if (gate != null) {
      await gate.future;
    }
    if (failDispose) {
      throw StateError('制御可能なdispose失敗');
    }
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> play(int playerId) async {
    playCount++;
  }

  @override
  Future<void> pause(int playerId) async {
    pauseCount++;
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seekPlayerIds.add(playerId);
    seekRequests.add(position);
    final gate = seekGate;
    if (gate != null) {
      await gate.future;
    }
    if (failSeek) {
      throw StateError('制御可能な初期シーク失敗');
    }
    _positions[playerId] = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    getPositionCount++;
    return _positions[playerId] ?? Duration.zero;
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) {
    return const ColoredBox(color: Colors.black, child: SizedBox.expand());
  }
}

enum _InitialProviderTimingMutation {
  change('開始位置変更'),
  delete('工程行削除');

  const _InitialProviderTimingMutation(this.label);

  final String label;
}

class _MutatingInitialReviewsRepository extends SurgeryRepository {
  _MutatingInitialReviewsRepository(
    super.database, {
    required this.targetStep,
    required this.mutation,
    required this.changedStartMilliseconds,
    required this.expectedVideoPath,
  }) : _database = database,
       _delegate = SurgeryRepository(database);

  final AppDatabase _database;
  final SurgeryRepository _delegate;
  final SurgicalStep targetStep;
  final _InitialProviderTimingMutation mutation;
  final int changedStartMilliseconds;
  final String expectedVideoPath;
  var didMutate = false;

  @override
  Future<List<SurgicalStepReview>> ensureStepReviews(
    String surgeryRecordId,
  ) async {
    if (!didMutate) {
      didMutate = true;
      switch (mutation) {
        case _InitialProviderTimingMutation.change:
          final review = (await _delegate.getStepReview(
            surgeryRecordId: surgeryRecordId,
            step: targetStep,
          ))!;
          await _delegate.saveStepTiming(
            review: review.copyWith(
              startMilliseconds: changedStartMilliseconds,
            ),
            expectedVideoPath: expectedVideoPath,
          );
        case _InitialProviderTimingMutation.delete:
          await _database.customStatement(
            '''
DELETE FROM surgical_step_reviews
WHERE surgery_record_id = ? AND step = ?
''',
            <Object?>[surgeryRecordId, targetStep.storageId],
          );
      }
    }
    return _delegate.ensureStepReviews(surgeryRecordId);
  }
}

enum _FinalTimingMutation {
  change('開始位置変更'),
  clear('開始位置消去'),
  delete('工程行削除');

  const _FinalTimingMutation(this.label);

  final String label;
}

enum _ObservedFreshReadAbaKind {
  videoPath('動画参照A→C→A'),
  startMilliseconds('開始位置X→Y→X');

  const _ObservedFreshReadAbaKind(this.label);

  final String label;
}

class _ObservedFreshReadAbaRepository extends SurgeryRepository {
  _ObservedFreshReadAbaRepository(
    super.database, {
    required this.kind,
    this.armOnFinalTransaction = false,
  });

  final _ObservedFreshReadAbaKind kind;
  final bool armOnFinalTransaction;
  var _armed = false;
  var _didAutomaticallyArm = false;
  var _recordReadsWhileArmed = 0;
  var _reviewReadsWhileArmed = 0;
  var didEmitAlternateValue = false;

  void arm() {
    _armed = true;
    _recordReadsWhileArmed = 0;
    _reviewReadsWhileArmed = 0;
  }

  @override
  Future<T> runRecordTransaction<T>(
    String surgeryRecordId,
    Future<T> Function() action,
  ) {
    return super.runRecordTransaction(surgeryRecordId, () async {
      if (armOnFinalTransaction && !_didAutomaticallyArm) {
        _didAutomaticallyArm = true;
        arm();
      }
      return action();
    });
  }

  @override
  Future<SurgeryRecord?> getRecord(String id) async {
    final record = await super.getRecord(id);
    if (!_armed || record == null) {
      return record;
    }
    _recordReadsWhileArmed++;
    if (kind == _ObservedFreshReadAbaKind.videoPath &&
        _recordReadsWhileArmed == 1) {
      didEmitAlternateValue = true;
      return record.copyWith(
        videoPath: 'videos/$id/observed-intermediate-c.mp4',
        videoDisplayName: 'observed-intermediate-c.mp4',
      );
    }
    return record;
  }

  @override
  Future<SurgicalStepReview?> getStepReview({
    required String surgeryRecordId,
    required SurgicalStep step,
  }) async {
    final review = await super.getStepReview(
      surgeryRecordId: surgeryRecordId,
      step: step,
    );
    if (!_armed || review == null) {
      return review;
    }
    _reviewReadsWhileArmed++;
    if (kind == _ObservedFreshReadAbaKind.startMilliseconds &&
        _reviewReadsWhileArmed == 1) {
      didEmitAlternateValue = true;
      return review.copyWith(
        startMilliseconds: (review.startMilliseconds ?? 0) + 1000,
      );
    }
    if (_recordReadsWhileArmed >= 2 && _reviewReadsWhileArmed >= 2) {
      _armed = false;
    }
    return review;
  }
}

enum _DelayedSeekMutation {
  changeStart('開始位置変更', '工程位置が更新'),
  clearStart('開始位置消去', '工程の記録位置が削除'),
  deleteRow('工程行削除', '工程の記録位置が削除'),
  changeVideo('動画変更', '動画が更新');

  const _DelayedSeekMutation(this.label, this.expectedMessage);

  final String label;
  final String expectedMessage;
}

class _TimingMutationDuringFinalRecordReadRepository extends SurgeryRepository {
  _TimingMutationDuringFinalRecordReadRepository(
    super.database, {
    required this.targetStep,
    required this.mutation,
    required this.changedStartMilliseconds,
  }) : _database = database,
       delegate = SurgeryRepository(database);

  final AppDatabase _database;
  final SurgeryRepository delegate;
  final SurgicalStep targetStep;
  final _FinalTimingMutation mutation;
  final int changedStartMilliseconds;
  var _insideFinalTransaction = false;
  var _recordReadsInsideTransaction = 0;
  var targetReviewReadCount = 0;
  var didMutate = false;

  @override
  Future<T> runRecordTransaction<T>(
    String surgeryRecordId,
    Future<T> Function() action,
  ) {
    return super.runRecordTransaction(surgeryRecordId, () async {
      _insideFinalTransaction = true;
      try {
        return await action();
      } finally {
        _insideFinalTransaction = false;
      }
    });
  }

  @override
  Future<List<SurgicalStepReview>> ensureStepReviews(String surgeryRecordId) {
    return delegate.ensureStepReviews(surgeryRecordId);
  }

  @override
  Future<SurgicalStepReview?> getStepReview({
    required String surgeryRecordId,
    required SurgicalStep step,
  }) async {
    final review = await delegate.getStepReview(
      surgeryRecordId: surgeryRecordId,
      step: step,
    );
    if (step == targetStep) {
      targetReviewReadCount++;
    }
    return review;
  }

  @override
  Future<SurgeryRecord?> getRecord(String id) async {
    final record = await delegate.getRecord(id);
    if (!_insideFinalTransaction) {
      return record;
    }
    _recordReadsInsideTransaction++;
    if (_recordReadsInsideTransaction == 2 && !didMutate) {
      didMutate = true;
      switch (mutation) {
        case _FinalTimingMutation.change:
          await _database.customStatement(
            '''
UPDATE surgical_step_reviews
SET start_milliseconds = ?
WHERE surgery_record_id = ? AND step = ?
''',
            <Object?>[changedStartMilliseconds, id, targetStep.storageId],
          );
        case _FinalTimingMutation.clear:
          await _database.customStatement(
            '''
UPDATE surgical_step_reviews
SET start_milliseconds = NULL,
    end_milliseconds = NULL,
    is_skipped = 0
WHERE surgery_record_id = ? AND step = ?
''',
            <Object?>[id, targetStep.storageId],
          );
        case _FinalTimingMutation.delete:
          await _database.customStatement(
            '''
DELETE FROM surgical_step_reviews
WHERE surgery_record_id = ? AND step = ?
''',
            <Object?>[id, targetStep.storageId],
          );
      }
    }
    return record;
  }
}

class _ControlledFinalReviewReadRepository extends SurgeryRepository {
  _ControlledFinalReviewReadRepository(
    super.database, {
    required this.targetStep,
  }) : delegate = SurgeryRepository(database);

  final SurgeryRepository delegate;
  final SurgicalStep targetStep;
  final Completer<void> finalReadStarted = Completer<void>();
  final Completer<void> releaseFinalRead = Completer<void>();
  var _insideFinalTransaction = false;
  var _transactionTargetReadCount = 0;

  @override
  Future<T> runRecordTransaction<T>(
    String surgeryRecordId,
    Future<T> Function() action,
  ) {
    return super.runRecordTransaction(surgeryRecordId, () async {
      _insideFinalTransaction = true;
      _transactionTargetReadCount = 0;
      try {
        return await action();
      } finally {
        _insideFinalTransaction = false;
      }
    });
  }

  @override
  Future<List<SurgicalStepReview>> ensureStepReviews(String surgeryRecordId) {
    return delegate.ensureStepReviews(surgeryRecordId);
  }

  @override
  Future<SurgeryRecord?> getRecord(String id) => delegate.getRecord(id);

  @override
  Future<SurgicalStepReview?> getStepReview({
    required String surgeryRecordId,
    required SurgicalStep step,
  }) async {
    final review = await delegate.getStepReview(
      surgeryRecordId: surgeryRecordId,
      step: step,
    );
    if (_insideFinalTransaction && step == targetStep) {
      _transactionTargetReadCount++;
      if (_transactionTargetReadCount == 2 && !finalReadStarted.isCompleted) {
        finalReadStarted.complete();
        await releaseFinalRead.future;
      }
    }
    return review;
  }
}

class _ControlledInitialRecordReadRepository extends SurgeryRepository {
  _ControlledInitialRecordReadRepository(super.database, {this.firstReadError})
    : delegate = SurgeryRepository(database);

  final SurgeryRepository delegate;
  final Object? firstReadError;
  final Completer<void> firstReadStarted = Completer<void>();
  final Completer<void> releaseFirstRead = Completer<void>();
  var _didControlFirstRead = false;

  @override
  Future<SurgeryRecord?> getRecord(String id) async {
    if (!_didControlFirstRead) {
      _didControlFirstRead = true;
      firstReadStarted.complete();
      await releaseFirstRead.future;
      final error = firstReadError;
      if (error != null) {
        throw error;
      }
    }
    return delegate.getRecord(id);
  }

  @override
  Future<List<SurgicalStepReview>> ensureStepReviews(String surgeryRecordId) {
    return delegate.ensureStepReviews(surgeryRecordId);
  }

  @override
  Future<SurgicalStepReview?> getStepReview({
    required String surgeryRecordId,
    required SurgicalStep step,
  }) {
    return delegate.getStepReview(surgeryRecordId: surgeryRecordId, step: step);
  }
}

class _RecordMutationDuringFinalValidationRepository extends SurgeryRepository {
  _RecordMutationDuringFinalValidationRepository(
    super.database, {
    required this.targetStep,
    required this.replacementVideoPath,
  }) : delegate = SurgeryRepository(database);

  final SurgeryRepository delegate;
  final SurgicalStep targetStep;
  final String replacementVideoPath;
  var targetReviewReadCount = 0;
  var didMutateVideo = false;

  @override
  Future<List<SurgicalStepReview>> ensureStepReviews(String surgeryRecordId) {
    return delegate.ensureStepReviews(surgeryRecordId);
  }

  @override
  Future<SurgicalStepReview?> getStepReview({
    required String surgeryRecordId,
    required SurgicalStep step,
  }) async {
    final review = await delegate.getStepReview(
      surgeryRecordId: surgeryRecordId,
      step: step,
    );
    if (step == targetStep) {
      targetReviewReadCount++;
      if (targetReviewReadCount == 2 && !didMutateVideo) {
        didMutateVideo = true;
        await delegate.updateVideoReference(
          surgeryRecordId: surgeryRecordId,
          videoPath: replacementVideoPath,
          videoDisplayName: 'replacement.mp4',
        );
      }
    }
    return review;
  }
}

class _NormalizingLegacyVideoService extends RecordVideoService {
  _NormalizingLegacyVideoService({
    required this.repository,
    required this.legacyPath,
    required this.legacyFile,
    required this.managedPath,
    required this.managedFile,
    this.migrationCommitted,
    this.releaseResolution,
    this.beforeMigrationStarted,
    this.releaseBeforeMigration,
    this.beforeResolutionReturn,
  }) : super(
         surgeryRepository: repository,
         videoStorageRepository: _ReviewStateVideoStorage(
           resolvedFile: managedFile,
         ),
         videoImportPreflight: const _ReadyVideoImportPreflight(),
       );

  final SurgeryRepository repository;
  final String legacyPath;
  final File legacyFile;
  final String managedPath;
  final File managedFile;
  final Completer<void>? migrationCommitted;
  final Completer<void>? releaseResolution;
  final Completer<void>? beforeMigrationStarted;
  final Completer<void>? releaseBeforeMigration;
  final void Function()? beforeResolutionReturn;

  @override
  Future<RecordVideoState> inspectVideoState(SurgeryRecord record) async {
    if (record.videoPath == legacyPath) {
      return RecordVideoState(
        RecordVideoStateKind.availableLegacy,
        file: legacyFile,
      );
    }
    if (record.videoPath == managedPath) {
      return RecordVideoState(
        RecordVideoStateKind.availableManaged,
        file: managedFile,
      );
    }
    return const RecordVideoState(RecordVideoStateKind.missing);
  }

  @override
  Future<ResolvedRecordVideo> resolveVideoForRecordWithMetadata(
    SurgeryRecord record,
  ) async {
    final started = beforeMigrationStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    final beforeMigration = releaseBeforeMigration;
    if (beforeMigration != null) {
      await beforeMigration.future;
    }
    await repository.updateVideoReferenceIfCurrent(
      surgeryRecordId: record.id,
      expectedVideoPath: legacyPath,
      videoPath: managedPath,
      videoDisplayName: 'managed.mp4',
    );
    final committed = migrationCommitted;
    if (committed != null && !committed.isCompleted) {
      committed.complete();
    }
    final release = releaseResolution;
    if (release != null) {
      await release.future;
    }
    beforeResolutionReturn?.call();
    return ResolvedRecordVideo(
      file: managedFile,
      normalizedLegacyVideoPath: managedPath,
    );
  }
}

class _MutatingLegacyResolutionService extends RecordVideoService {
  _MutatingLegacyResolutionService({
    required this.repository,
    required this.legacyPath,
    required this.legacyFile,
    required this.migratedPath,
    required this.migratedFile,
    this.replacementPath,
    this.replacementFile,
    this.replacementStateKind = RecordVideoStateKind.availableManaged,
    this.deleteDuringResolution = false,
  }) : assert(deleteDuringResolution || replacementPath != null),
       super(
         surgeryRepository: repository,
         videoStorageRepository: _ReviewStateVideoStorage(
           resolvedFile: migratedFile,
         ),
         videoImportPreflight: const _ReadyVideoImportPreflight(),
       );

  final SurgeryRepository repository;
  final String legacyPath;
  final File legacyFile;
  final String migratedPath;
  final File migratedFile;
  final String? replacementPath;
  final File? replacementFile;
  final RecordVideoStateKind replacementStateKind;
  final bool deleteDuringResolution;

  @override
  Future<RecordVideoState> inspectVideoState(SurgeryRecord record) async {
    if (record.videoPath == legacyPath) {
      return RecordVideoState(
        RecordVideoStateKind.availableLegacy,
        file: legacyFile,
      );
    }
    if (record.videoPath == migratedPath) {
      return RecordVideoState(
        RecordVideoStateKind.availableManaged,
        file: migratedFile,
      );
    }
    if (record.videoPath == replacementPath) {
      return RecordVideoState(replacementStateKind, file: replacementFile);
    }
    return const RecordVideoState(RecordVideoStateKind.missing);
  }

  @override
  Future<ResolvedRecordVideo> resolveVideoForRecordWithMetadata(
    SurgeryRecord record,
  ) async {
    await repository.updateVideoReferenceIfCurrent(
      surgeryRecordId: record.id,
      expectedVideoPath: legacyPath,
      videoPath: migratedPath,
      videoDisplayName: 'migrated.mp4',
    );
    if (deleteDuringResolution) {
      await repository.deleteRecord(record.id);
    } else {
      await repository.updateVideoReferenceIfCurrent(
        surgeryRecordId: record.id,
        expectedVideoPath: migratedPath,
        videoPath: replacementPath,
        videoDisplayName: 'replacement.mp4',
      );
    }
    return ResolvedRecordVideo(
      file: migratedFile,
      normalizedLegacyVideoPath: migratedPath,
    );
  }
}

class _LegacyFallbackVideoService extends RecordVideoService {
  _LegacyFallbackVideoService({
    required SurgeryRepository repository,
    required this.legacyPath,
    required this.legacyFile,
  }) : super(
         surgeryRepository: repository,
         videoStorageRepository: _ReviewStateVideoStorage(
           resolvedFile: legacyFile,
         ),
         videoImportPreflight: const _ReadyVideoImportPreflight(),
       );

  final String legacyPath;
  final File legacyFile;

  @override
  Future<RecordVideoState> inspectVideoState(SurgeryRecord record) async {
    return record.videoPath == legacyPath
        ? RecordVideoState(
            RecordVideoStateKind.availableLegacy,
            file: legacyFile,
          )
        : const RecordVideoState(RecordVideoStateKind.missing);
  }

  @override
  Future<ResolvedRecordVideo> resolveVideoForRecordWithMetadata(
    SurgeryRecord record,
  ) async => ResolvedRecordVideo(file: legacyFile);
}
