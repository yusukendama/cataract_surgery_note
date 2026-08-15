import 'dart:async';
import 'dart:io';

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/record_video_service.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/surgery_video_picker.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/features/review/step_review_screen.dart';
import 'package:cataract_surgery_note/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
    RecordVideoService? recordVideoService,
    SuccessHapticFeedback? successHapticFeedback,
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

  testWidgets('videoPath nullで既存時刻がある初回添付は選択前後に同一動画を確認する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
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
    await pumpScreen(tester, database, record.id, surgeryVideoPicker: picker);

    await tester.tap(find.text('動画を登録'));
    await tester.pumpAndSettle();
    expect(picker.calls, 0);
    expect(find.text('記録済み位置に対応する動画を選択'), findsOneWidget);
    expect(find.textContaining('同じ手術動画を選択'), findsOneWidget);

    await tester.tap(find.text('動画を選ぶ'));
    await tester.pumpAndSettle();
    expect(picker.calls, 1);
    expect(find.text('記録済み位置を保持して動画を登録'), findsOneWidget);
    expect(find.textContaining('同じ手術動画を選択したことを確認'), findsOneWidget);

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
  });

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
      await repository.saveStepTiming(
        review: total.copyWith(startMilliseconds: 100, endMilliseconds: 900),
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
}

TextButton _saveButton(WidgetTester tester) {
  return tester.widget<TextButton>(find.byKey(const Key('review-save-button')));
}

PopScope<void> _popScope(WidgetTester tester) {
  return tester.widget<PopScope<void>>(
    find.byKey(const Key('review-pop-scope')),
  );
}

Future<void> _openCaseMemoTab(WidgetTester tester) async {
  await _openTab(tester, '症例メモ');
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
    required String sourcePath,
    required String originalFileName,
  }) async {
    return StoredVideo(
      relativePath: relativePathFor(surgeryRecordId),
      originalFileName: originalFileName,
      sizeBytes: await videoFile.length(),
      sha256: 'test-sha256',
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
  const _ReviewStateVideoStorage({this.resolveError});

  final Object? resolveError;

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required String sourcePath,
    required String originalFileName,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<File?> resolveVideo(String relativePath) async {
    final error = resolveError;
    if (error != null) {
      throw error;
    }
    return null;
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
      );

  final SurgeryRepository repository;

  @override
  bool get hasPendingCleanup => true;

  @override
  Future<SurgeryRecord> attachVideoToRecord({
    required String surgeryRecordId,
    required String sourcePath,
    required String originalFileName,
  }) async {
    final relativePath = 'videos/$surgeryRecordId/pending-cleanup.mp4';
    await repository.updateVideoReferenceIfCurrent(
      surgeryRecordId: surgeryRecordId,
      expectedVideoPath: null,
      videoPath: relativePath,
      videoDisplayName: originalFileName,
    );
    return (await repository.getRecord(surgeryRecordId))!;
  }
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
