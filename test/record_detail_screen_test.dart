import 'dart:async';
import 'dart:io';
import 'dart:ui' show SemanticsAction, Tristate;

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/record_video_service.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/surgery_video_picker.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/features/records/record_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/video_import_test_support.dart';

/// Resolves every managed path to a real (non-null) file, standing in for a
/// case whose video is present without touching the platform file system.
class _PresentVideoStorage implements VideoStorageRepository {
  @override
  Future<File?> resolveVideo(String relativePath) async => File(relativePath);

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async => throw UnimplementedError();

  @override
  Future<void> deleteVideo(String relativePath) async {}

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) async {}
}

/// Resolves every managed path to null, standing in for a case whose video
/// file is gone (e.g. after an iCloud restore that dropped the videos).
class _MissingVideoStorage implements VideoStorageRepository {
  @override
  Future<File?> resolveVideo(String relativePath) async => null;

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async => throw UnimplementedError();

  @override
  Future<void> deleteVideo(String relativePath) async {}

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) async {}
}

class _QueueVideoPicker implements SurgeryVideoPicker {
  _QueueVideoPicker(this.values);

  final List<SelectedSurgeryVideo?> values;

  @override
  Future<SelectedSurgeryVideo?> pickVideo() async => values.removeAt(0);
}

class _ImportingVideoStorage implements VideoStorageRepository {
  var importCount = 0;

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    importCount++;
    return StoredVideo(
      relativePath: 'videos/$surgeryRecordId/import-$importCount.mp4',
      originalFileName: candidate.displayName,
      sizeBytes: 1,
      sha256: 'fixture',
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

class _PendingCleanupVideoStorage extends _ImportingVideoStorage
    implements ManagedVideoStorageRepository {
  @override
  Future<T> runStorageTransaction<T>(Future<T> Function() action) => action();

  @override
  Future<void> finishImport(String relativePath) async {}

  @override
  Future<VideoStorageMaintenanceReport> maintainManagedStorage(
    Future<RecordVideoReferenceSnapshot> Function() loadReferences,
  ) async {
    await loadReferences();
    return const VideoStorageMaintenanceReport(
      snapshotComplete: true,
      deletedPaths: <String>[],
      backupExclusionFailures: <String>[],
      cleanupFailures: <String>['videos/fixture/old.mp4'],
    );
  }
}

class _PendingDeleteRecordVideoService extends RecordVideoService {
  _PendingDeleteRecordVideoService(SurgeryRepository repository)
    : super(
        surgeryRepository: repository,
        videoStorageRepository: _PresentVideoStorage(),
        videoImportPreflight: const _SyntheticVideoImportPreflight(),
      );

  final deletionStarted = Completer<void>();
  final releaseDeletion = Completer<void>();
  int deleteCalls = 0;

  @override
  Future<void> deleteRecordAndManagedVideos(String surgeryRecordId) async {
    deleteCalls++;
    if (!deletionStarted.isCompleted) {
      deletionStarted.complete();
    }
    await releaseDeletion.future;
  }
}

class _SyntheticVideoImportPreflight extends PassThroughVideoImportPreflight {
  const _SyntheticVideoImportPreflight();

  @override
  Future<VideoSelectionPreflightResult> inspectSelection(
    SelectedSurgeryVideo selection, {
    required int selectionGeneration,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    final policy = const VideoSelectionPolicy();
    final normalizedExtension = policy.normalizeExtension(
      selection.displayName,
    );
    if (policy.classify(selection.displayName) ==
        VideoSelectionPolicyKind.nonCandidate) {
      return VideoSelectionNonCandidate(
        normalizedExtension: normalizedExtension,
      );
    }
    return VideoSelectionReady(
      VerifiedVideoCandidate(
        path: selection.path,
        displayName: selection.displayName,
        normalizedExtension: normalizedExtension,
        selectionGeneration: selectionGeneration,
        sourceSize: 2048,
        sourceModifiedAt: DateTime.utc(2026, 8, 15),
        sha256: 'synthetic-detail-video-sha256',
        playbackEvidence: testVideoPlaybackEvidence,
      ),
    );
  }
}

void main() {
  Future<void> pumpUntilVisible(
    WidgetTester tester,
    Finder finder, {
    int attempts = 50,
  }) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (finder.evaluate().isNotEmpty) {
        return;
      }
    }
    fail('Widget did not become visible: $finder');
  }

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

  Future<void> pumpScreen(
    WidgetTester tester,
    AppDatabase database,
    String recordId, {
    RecordVideoState? videoState,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoImportPreflightProvider.overrideWithValue(
            const _SyntheticVideoImportPreflight(),
          ),
          if (videoState != null)
            recordVideoStateProvider(
              recordId,
            ).overrideWith((ref) async => videoState),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: recordId)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('編集ダイアログで左右眼を修正するとタイトルへ反映される', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(tester, database, record.id);

    expect(find.text('2026/07/18 右眼'), findsOneWidget);

    await tester.tap(find.byTooltip('手術日・左右眼を変更'));
    await tester.pumpAndSettle();
    expect(find.text('手術日'), findsOneWidget);

    await tester.tap(find.text('左眼'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('2026/07/18 左眼'), findsOneWidget);
    expect(find.text('2026/07/18 右眼'), findsNothing);
  });

  testWidgets('編集ダイアログをキャンセルするとタイトルは変わらない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(tester, database, record.id);

    await tester.tap(find.byTooltip('手術日・左右眼を変更'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('左眼'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('キャンセル'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('2026/07/18 右眼'), findsOneWidget);
  });

  testWidgets('管理動画の除外read-back成功時はバックアップ案内を表示しない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      await SurgeryRepository(database).updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: 'videos/${record.id}/present.mp4',
        videoDisplayName: 'present.mp4',
      );
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoStorageRepositoryProvider.overrideWithValue(
            _PresentVideoStorage(),
          ),
          videoStorageMaintenanceProvider.overrideWith(
            (ref) async => const VideoStorageMaintenanceReport(
              snapshotComplete: true,
              deletedPaths: <String>[],
              backupExclusionFailures: <String>[],
            ),
          ),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('present.mp4'), findsOneWidget);
    expect(find.byKey(const Key('backup-exclusion-hidden')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('backup-exclusion-hidden'))).height,
      0,
    );
    expect(find.textContaining('バックアップ除外を確認済みです'), findsNothing);
    expect(find.textContaining('選択元の動画も別途保管してください'), findsNothing);
    expect(find.byKey(const Key('backup-exclusion-warning')), findsNothing);
    expect(find.text('別の動画に差し替え'), findsOneWidget);
    final videoCard = find.ancestor(
      of: find.text('present.mp4'),
      matching: find.byType(Card),
    );
    final replaceButton = find.ancestor(
      of: find.text('別の動画に差し替え'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    expect(
      tester.getTopLeft(replaceButton).dy - tester.getBottomLeft(videoCard).dy,
      12,
    );
    expect(
      find.text('保存した動画が見つかりません。機種変更や端末の復元後は、元の動画を選び直してください。'),
      findsNothing,
    );
  });

  testWidgets('管理動画の除外read-back確認中は専用表示と余白を出さない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      await SurgeryRepository(database).updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: 'videos/${record.id}/present.mp4',
        videoDisplayName: 'present.mp4',
      );
    });
    final maintenance = Completer<VideoStorageMaintenanceReport?>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoStorageRepositoryProvider.overrideWithValue(
            _PresentVideoStorage(),
          ),
          recordVideoStateProvider(record.id).overrideWith(
            (ref) =>
                const RecordVideoState(RecordVideoStateKind.availableManaged),
          ),
          videoStorageMaintenanceProvider.overrideWith(
            (ref) => maintenance.future,
          ),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('present.mp4'), findsOneWidget);
    expect(find.text('バックアップ除外を確認しています…'), findsNothing);
    expect(find.byKey(const Key('backup-exclusion-checking')), findsNothing);
    expect(find.byKey(const Key('backup-exclusion-hidden')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('backup-exclusion-hidden'))).height,
      0,
    );
    expect(find.byKey(const Key('backup-exclusion-warning')), findsNothing);

    maintenance.complete(
      const VideoStorageMaintenanceReport(
        snapshotComplete: true,
        deletedPaths: <String>[],
        backupExclusionFailures: <String>[],
      ),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('除外read-backを確認できない管理動画では断定せず再確認を出す', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      await SurgeryRepository(database).updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: 'videos/${record.id}/present.mp4',
        videoDisplayName: 'present.mp4',
      );
    });

    var maintenanceCalls = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoStorageRepositoryProvider.overrideWithValue(
            _PresentVideoStorage(),
          ),
          videoStorageMaintenanceProvider.overrideWith((ref) async {
            maintenanceCalls++;
            return const VideoStorageMaintenanceReport(
              snapshotComplete: true,
              deletedPaths: <String>[],
              backupExclusionFailures: <String>[
                'videos/root-record/present.mp4',
              ],
            );
          }),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('backup-exclusion-warning')), findsOneWidget);
    expect(find.text('再確認'), findsOneWidget);
    expect(find.byKey(const Key('backup-exclusion-verified')), findsNothing);
    expect(find.textContaining('バックアップ対象外です'), findsNothing);
    expect(maintenanceCalls, 1);

    await tester.tap(find.text('再確認'));
    await tester.pumpAndSettle();

    expect(maintenanceCalls, 2);
    expect(find.byKey(const Key('backup-exclusion-warning')), findsOneWidget);
  });

  testWidgets('DBにパスがあり実ファイルが無いときは再選択を促す', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      await SurgeryRepository(database).updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: 'videos/${record.id}/gone.mp4',
        videoDisplayName: 'gone.mp4',
      );
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoStorageRepositoryProvider.overrideWithValue(
            _MissingVideoStorage(),
          ),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('保存した動画の実体が見つかりません。工程記録は保持されています。'), findsOneWidget);
    expect(find.text('同じ動画を再登録'), findsOneWidget);
    expect(find.text('別の動画に差し替え'), findsOneWidget);
    expect(find.text('登録済みの動画'), findsNothing);
  });

  testWidgets('3セクションと控えめな削除導線を表示しreviewStatusに依存しない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(tester, database, record.id);

    expect(find.text('症例情報'), findsOneWidget);
    expect(find.text('動画'), findsOneWidget);
    expect(find.text('工程記録'), findsOneWidget);
    expect(find.byTooltip('登録できる動画の目安'), findsOneWidget);
    final deleteButtonFinder = find.byKey(const Key('delete-record-button'));
    expect(deleteButtonFinder, findsNothing);
    await tester.dragUntilVisible(
      deleteButtonFinder,
      find.byType(ListView),
      const Offset(0, -300),
    );

    expect(find.text('危険操作'), findsNothing);
    expect(deleteButtonFinder, findsOneWidget);
    expect(
      find.descendant(
        of: deleteButtonFinder,
        matching: find.byIcon(Icons.delete_outline),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<TextButton>(deleteButtonFinder).style?.backgroundColor,
      isNull,
    );
    expect(tester.widget<TextButton>(deleteButtonFinder).style?.side, isNull);
    final buttonSize = tester.getSize(deleteButtonFinder);
    expect(buttonSize.height, greaterThanOrEqualTo(48));
    expect(
      buttonSize.width,
      lessThan(tester.getSize(find.byType(Scaffold)).width),
    );

    final context = tester.element(deleteButtonFinder);
    expect(
      tester
          .widget<TextButton>(deleteButtonFinder)
          .style
          ?.foregroundColor
          ?.resolve(<WidgetState>{}),
      Theme.of(context).colorScheme.error,
    );
    final semantics = tester.ensureSemantics();
    final deleteNode = tester.getSemantics(deleteButtonFinder);
    expect(deleteNode.label, '症例を削除');
    expect(
      deleteNode.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
    );
    semantics.dispose();

    expect(find.textContaining('状態:'), findsNothing);
    expect(find.text(record.reviewStatus.label), findsNothing);
  });

  testWidgets('狭い画面の文字倍率2.0でも削除導線へ到達できる', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWith((ref) => database)],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 568),
              textScaler: TextScaler.linear(2),
            ),
            child: RecordDetailScreen(recordId: record.id),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    final deleteButtonFinder = find.byKey(const Key('delete-record-button'));
    await tester.dragUntilVisible(
      deleteButtonFinder,
      find.byType(ListView),
      const Offset(0, -240),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('症例を削除'), findsOneWidget);
    final buttonSize = tester.getSize(deleteButtonFinder);
    expect(buttonSize.height, greaterThanOrEqualTo(48));
    expect(buttonSize.width, lessThan(320));
  });

  testWidgets('症例削除ダイアログを閉じると記録と動画参照を保持する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    late SurgicalStepReview ccc;
    await tester.runAsync(() async {
      await repository.updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: 'videos/${record.id}/present.mp4',
        videoDisplayName: 'present.mp4',
      );
      ccc = await repository.ensureStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      );
      await repository.saveStepReview(
        ccc.copyWith(
          startMilliseconds: 100,
          endMilliseconds: 500,
          rating: StepRating.good,
          reflection: '保持する記録',
        ),
      );
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoStorageRepositoryProvider.overrideWithValue(
            _PresentVideoStorage(),
          ),
          videoStorageMaintenanceProvider.overrideWith(
            (ref) async => const VideoStorageMaintenanceReport(
              snapshotComplete: true,
              deletedPaths: <String>[],
              backupExclusionFailures: <String>[],
            ),
          ),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    final deleteButtonFinder = find.byKey(const Key('delete-record-button'));
    await tester.dragUntilVisible(
      deleteButtonFinder,
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.tap(deleteButtonFinder);
    await tester.pumpAndSettle();

    expect(find.text('この症例を削除しますか？'), findsOneWidget);
    expect(
      find.text(
        'この症例の記録（総手術時間、工程記録、自己評価、反省点、症例メモ）と、アプリ内に保存された動画を削除します。アプリ外の元動画は削除されません。この操作は元に戻せません。',
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, 'キャンセル'), findsOneWidget);
    final confirmFinder = find.widgetWithText(FilledButton, '削除');
    expect(confirmFinder, findsOneWidget);
    final confirmContext = tester.element(confirmFinder);
    expect(
      tester
          .widget<FilledButton>(confirmFinder)
          .style
          ?.backgroundColor
          ?.resolve(<WidgetState>{}),
      Theme.of(confirmContext).colorScheme.error,
    );

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text('この症例を削除しますか？'), findsNothing);

    await tester.tap(deleteButtonFinder);
    await tester.pumpAndSettle();
    expect(find.text('この症例を削除しますか？'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('この症例を削除しますか？'), findsNothing);

    await tester.tap(deleteButtonFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'キャンセル'));
    await tester.pumpAndSettle();

    late SurgeryRecord? unchangedRecord;
    late SurgicalStepReview? unchangedCcc;
    await tester.runAsync(() async {
      unchangedRecord = await repository.getRecord(record.id);
      unchangedCcc = await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      );
    });
    expect(unchangedRecord, isNotNull);
    expect(unchangedRecord!.videoPath, 'videos/${record.id}/present.mp4');
    expect(unchangedCcc!.startMilliseconds, 100);
    expect(unchangedCcc!.endMilliseconds, 500);
    expect(unchangedCcc!.rating, StepRating.good);
    expect(unchangedCcc!.reflection, '保持する記録');
  });

  testWidgets('症例削除後は症例と到着時刻snapshotの保持cacheを破棄する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    final service = RecordVideoService(
      surgeryRepository: repository,
      videoStorageRepository: _PresentVideoStorage(),
      videoImportPreflight: const _SyntheticVideoImportPreflight(),
    );
    late RecordProcedureTimingSnapshot beforeDeletion;
    await tester.runAsync(() async {
      beforeDeletion = await repository.fetchRecordProcedureTimingSnapshot(
        record.id,
      );
    });
    final emptySnapshot = RecordProcedureTimingSnapshot(
      surgeryRecordId: record.id,
      reviewsByStep: const {},
    );
    var snapshotReads = 0;
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => database),
        recordVideoServiceProvider.overrideWithValue(service),
        recordProcedureTimingSnapshotProvider(record.id).overrideWith((ref) {
          snapshotReads++;
          return Future.value(
            snapshotReads == 1 ? beforeDeletion : emptySnapshot,
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      beforeDeletion = await container.read(
        recordProcedureTimingSnapshotProvider(record.id).future,
      );
    });
    expect(snapshotReads, 1);
    expect(beforeDeletion.reviewsByStep, isNotEmpty);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.pumpAndSettle();

    final deleteButtonFinder = find.byKey(const Key('delete-record-button'));
    await tester.dragUntilVisible(
      deleteButtonFinder,
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.tap(deleteButtonFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '削除'));
    await pumpUntilVisible(tester, find.text('症例を削除しました'));
    await tester.pump();

    late SurgeryRecord? deletedRecord;
    late SurgeryRecord? invalidatedRecord;
    await tester.runAsync(() async {
      deletedRecord = await repository
          .getRecord(record.id)
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => throw StateError('repository read timed out'),
          );
      invalidatedRecord = await container
          .read(surgeryRecordProvider(record.id).future)
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => throw StateError('provider read timed out'),
          );
    });
    container.read(recordProcedureTimingSnapshotProvider(record.id));

    expect(deletedRecord, isNull);
    expect(invalidatedRecord, isNull);
    expect(snapshotReads, 2);
  });

  testWidgets('症例削除中は進行表示、多重実行防止、離脱抑止を維持する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final service = _PendingDeleteRecordVideoService(
      SurgeryRepository(database),
    );
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          recordVideoServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    final deleteButtonFinder = find.byKey(const Key('delete-record-button'));
    await tester.dragUntilVisible(
      deleteButtonFinder,
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.tap(deleteButtonFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '削除'));
    await tester.pump();

    expect(service.deletionStarted.isCompleted, isTrue);
    expect(service.deleteCalls, 1);
    expect(tester.widget<TextButton>(deleteButtonFinder).onPressed, isNull);
    expect(
      find.descendant(
        of: deleteButtonFinder,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .getSemantics(deleteButtonFinder)
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isFalse,
    );
    expect(
      tester
          .widget<PopScope<void>>(
            find.byKey(const Key('record-detail-pop-scope')),
          )
          .canPop,
      isFalse,
    );

    await tester.tap(deleteButtonFinder, warnIfMissed: false);
    await tester.pump();
    expect(service.deleteCalls, 1);

    service.releaseDeletion.complete();
    await tester.pumpAndSettle();
    semantics.dispose();
  });

  testWidgets('不正参照を開かず、同じ動画再登録と別動画差し替えを分ける', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      await SurgeryRepository(database).updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: '../unsafe.mp4',
        videoDisplayName: 'unsafe.mp4',
      );
    });

    await pumpScreen(
      tester,
      database,
      record.id,
      videoState: const RecordVideoState(RecordVideoStateKind.invalidReference),
    );

    expect(find.textContaining('動画参照が不正'), findsOneWidget);
    expect(find.text('同じ動画を再登録'), findsOneWidget);
    expect(find.text('別の動画に差し替え'), findsOneWidget);
  });

  testWidgets('同じ動画の再登録は詳細画面から工程時刻を保持して参照だけ更新する', (tester) async {
    final (database, created) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    late SurgeryRecord record;
    late SurgicalStepReview ccc;
    await tester.runAsync(() async {
      await repository.updateVideoReference(
        surgeryRecordId: created.id,
        videoPath: 'videos/${created.id}/missing.mp4',
        videoDisplayName: 'missing.mp4',
      );
      ccc = (await repository.ensureStepReviews(
        created.id,
      )).singleWhere((review) => review.step == SurgicalStep.capsulorhexis);
      await repository.saveStepReview(
        ccc.copyWith(
          startMilliseconds: 100,
          endMilliseconds: 500,
          rating: StepRating.good,
          reflection: '保持する記録',
        ),
      );
      record = (await repository.getRecord(created.id))!;
    });
    final storage = _ImportingVideoStorage();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoImportPreflightProvider.overrideWithValue(
            const _SyntheticVideoImportPreflight(),
          ),
          videoStorageRepositoryProvider.overrideWithValue(storage),
          surgeryVideoPickerProvider.overrideWithValue(
            _QueueVideoPicker([
              const SelectedSurgeryVideo(
                path: '/fixture/same.mp4',
                displayName: 'same.mp4',
              ),
            ]),
          ),
          recordVideoStateProvider(created.id).overrideWith(
            (ref) async => const RecordVideoState(RecordVideoStateKind.missing),
          ),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('同じ動画を再登録'));
    await pumpUntilVisible(tester, find.text('選択した動画について確認してください'));
    expect(find.text('選択した動画について確認してください'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('continue-with-timeline-identity')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('timeline-identity-same-unchanged')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('continue-with-timeline-identity')));
    await pumpUntilVisible(tester, find.text('同じ動画として再登録'));
    await tester.tap(find.text('同じ動画として再登録'));
    await pumpUntilVisible(tester, find.text('動画を登録し、記録済みの内容を保持しました'));

    late SurgeryRecord? updated;
    late SurgicalStepReview? updatedCcc;
    await tester.runAsync(() async {
      updated = await repository.getRecord(created.id);
      updatedCcc = await repository.getStepReview(
        surgeryRecordId: created.id,
        step: SurgicalStep.capsulorhexis,
      );
    });
    expect(updated!.videoPath, 'videos/${created.id}/import-1.mp4');
    expect(updatedCcc!.startMilliseconds, 100);
    expect(updatedCcc!.endMilliseconds, 500);
    expect(updatedCcc!.rating, StepRating.good);
    expect(updatedCcc!.reflection, '保持する記録');
    expect(storage.importCount, 1);
  });

  testWidgets('動画未登録で変換・編集済みまたは不明を選ぶと工程時刻を消去して登録する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    await tester.runAsync(() async {
      final ccc = await repository.ensureStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      );
      await repository.saveStepReview(
        ccc.copyWith(
          startMilliseconds: 100,
          endMilliseconds: 500,
          rating: StepRating.good,
          reflection: '保持するレビュー',
        ),
      );
    });
    final storage = _ImportingVideoStorage();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoImportPreflightProvider.overrideWithValue(
            const _SyntheticVideoImportPreflight(),
          ),
          videoStorageRepositoryProvider.overrideWithValue(storage),
          surgeryVideoPickerProvider.overrideWithValue(
            _QueueVideoPicker([
              const SelectedSurgeryVideo(
                path: '/fixture/converted.mp4',
                displayName: 'converted.mp4',
              ),
            ]),
          ),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('動画を登録'));
    await pumpUntilVisible(tester, find.text('選択した動画について確認してください'));
    await tester.tap(
      find.byKey(const Key('timeline-identity-changed-or-unknown')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('continue-with-timeline-identity')));
    await pumpUntilVisible(tester, find.text('工程位置を消去して動画を登録'));
    await tester.tap(find.text('登録'));
    await pumpUntilVisible(tester, find.text('動画を登録し、工程位置を削除しました'));

    late SurgeryRecord? updated;
    late SurgicalStepReview? updatedCcc;
    await tester.runAsync(() async {
      updated = await repository.getRecord(record.id);
      updatedCcc = await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      );
    });
    expect(updated!.videoPath, 'videos/${record.id}/import-1.mp4');
    expect(updatedCcc!.startMilliseconds, isNull);
    expect(updatedCcc!.endMilliseconds, isNull);
    expect(updatedCcc!.rating, StepRating.good);
    expect(updatedCcc!.reflection, '保持するレビュー');
    expect(storage.importCount, 1);
  });

  testWidgets('工程時刻がある再リンクで同一性確認をキャンセルすると何も変更しない', (tester) async {
    final (database, created) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    late SurgeryRecord record;
    await tester.runAsync(() async {
      await repository.updateVideoReference(
        surgeryRecordId: created.id,
        videoPath: 'videos/${created.id}/missing.mp4',
        videoDisplayName: 'missing.mp4',
      );
      final ccc = await repository.ensureStepReview(
        surgeryRecordId: created.id,
        step: SurgicalStep.capsulorhexis,
      );
      await repository.saveStepReview(
        ccc.copyWith(startMilliseconds: 100, endMilliseconds: 500),
      );
      record = (await repository.getRecord(created.id))!;
    });
    final storage = _ImportingVideoStorage();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoImportPreflightProvider.overrideWithValue(
            const _SyntheticVideoImportPreflight(),
          ),
          videoStorageRepositoryProvider.overrideWithValue(storage),
          surgeryVideoPickerProvider.overrideWithValue(
            _QueueVideoPicker([
              const SelectedSurgeryVideo(
                path: '/fixture/same.mp4',
                displayName: 'same.mp4',
              ),
            ]),
          ),
          recordVideoStateProvider(created.id).overrideWith(
            (ref) async => const RecordVideoState(RecordVideoStateKind.missing),
          ),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('同じ動画を再登録'));
    await pumpUntilVisible(tester, find.text('選択した動画について確認してください'));
    await tester.tap(find.text('キャンセル'));
    await tester.pump(const Duration(milliseconds: 300));

    late SurgeryRecord? unchanged;
    late SurgicalStepReview? unchangedCcc;
    await tester.runAsync(() async {
      unchanged = await repository.getRecord(created.id);
      unchangedCcc = await repository.getStepReview(
        surgeryRecordId: created.id,
        step: SurgicalStep.capsulorhexis,
      );
    });
    expect(unchanged!.videoPath, 'videos/${created.id}/missing.mp4');
    expect(unchangedCcc!.startMilliseconds, 100);
    expect(unchangedCcc!.endMilliseconds, 500);
    expect(storage.importCount, 0);
  });

  testWidgets('表示名が非候補拡張子なら内容を開かず共通案内とヘルプを表示する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final storage = _ImportingVideoStorage();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoImportPreflightProvider.overrideWithValue(
            const _SyntheticVideoImportPreflight(),
          ),
          videoStorageRepositoryProvider.overrideWithValue(storage),
          surgeryVideoPickerProvider.overrideWithValue(
            _QueueVideoPicker([
              const SelectedSurgeryVideo(
                path: '/fixture/path-looks-supported.mp4',
                displayName: 'exported-video.avi',
              ),
            ]),
          ),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('動画を登録'));
    await pumpUntilVisible(tester, find.text('この拡張子のファイルは登録対象外です'));

    expect(find.text('登録できる動画の目安を見る'), findsOneWidget);
    expect(find.textContaining('元のファイルは変更されていません'), findsOneWidget);
    expect(find.textContaining('写真へのアクセス権限'), findsNothing);
    expect(storage.importCount, 0);
    await tester.tap(find.text('閉じる'));
    await tester.pump(const Duration(milliseconds: 300));

    late SurgeryRecord? unchanged;
    await tester.runAsync(() async {
      unchanged = await SurgeryRepository(database).getRecord(record.id);
    });
    expect(unchanged!.videoPath, isNull);
  });

  testWidgets('別動画への差し替えは確認後だけ全工程時刻を消去しレビューを保持する', (tester) async {
    final (database, created) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    late SurgeryRecord record;
    await tester.runAsync(() async {
      await repository.updateVideoReference(
        surgeryRecordId: created.id,
        videoPath: 'videos/${created.id}/missing.mp4',
        videoDisplayName: 'missing.mp4',
      );
      final ccc = (await repository.ensureStepReviews(
        created.id,
      )).singleWhere((review) => review.step == SurgicalStep.capsulorhexis);
      await repository.saveStepReview(
        ccc.copyWith(
          startMilliseconds: 100,
          endMilliseconds: 500,
          rating: StepRating.good,
          reflection: '保持する記録',
        ),
      );
      record = (await repository.getRecord(created.id))!;
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoImportPreflightProvider.overrideWithValue(
            const _SyntheticVideoImportPreflight(),
          ),
          videoStorageRepositoryProvider.overrideWithValue(
            _ImportingVideoStorage(),
          ),
          surgeryVideoPickerProvider.overrideWithValue(
            _QueueVideoPicker([
              const SelectedSurgeryVideo(
                path: '/fixture/replacement.mp4',
                displayName: 'replacement.mp4',
              ),
            ]),
          ),
          recordVideoStateProvider(created.id).overrideWith(
            (ref) async => const RecordVideoState(RecordVideoStateKind.missing),
          ),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('別の動画に差し替え'));
    await pumpUntilVisible(tester, find.text('工程位置を消去して動画を差し替え'));
    expect(
      find.byKey(const Key('timeline-identity-same-unchanged')),
      findsNothing,
    );
    expect(find.textContaining('総手術時間を含む全工程の開始・終了位置が削除されます'), findsOneWidget);
    await tester.tap(find.text('差し替え'));
    await pumpUntilVisible(tester, find.text('動画を差し替え、工程位置を削除しました'));

    late SurgicalStepReview? updatedCcc;
    await tester.runAsync(() async {
      updatedCcc = await repository.getStepReview(
        surgeryRecordId: created.id,
        step: SurgicalStep.capsulorhexis,
      );
    });
    expect(updatedCcc!.startMilliseconds, isNull);
    expect(updatedCcc!.endMilliseconds, isNull);
    expect(updatedCcc!.rating, StepRating.good);
    expect(updatedCcc!.reflection, '保持する記録');
  });

  testWidgets('動画操作commit後のcleanup失敗を後処理保留として表示する', (tester) async {
    final (database, created) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    await tester.runAsync(() async {
      await repository.updateVideoReference(
        surgeryRecordId: created.id,
        videoPath: 'videos/${created.id}/missing.mp4',
        videoDisplayName: 'missing.mp4',
      );
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoImportPreflightProvider.overrideWithValue(
            const _SyntheticVideoImportPreflight(),
          ),
          videoStorageRepositoryProvider.overrideWithValue(
            _PendingCleanupVideoStorage(),
          ),
          surgeryVideoPickerProvider.overrideWithValue(
            _QueueVideoPicker([
              const SelectedSurgeryVideo(
                path: '/fixture/replacement.mp4',
                displayName: 'replacement.mp4',
              ),
            ]),
          ),
          recordVideoStateProvider(created.id).overrideWith(
            (ref) async => const RecordVideoState(RecordVideoStateKind.missing),
          ),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: created.id)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('別の動画に差し替え'));
    await pumpUntilVisible(tester, find.text('工程位置を消去して動画を差し替え'));
    await tester.tap(find.text('差し替え'));
    await pumpUntilVisible(tester, find.text('保存は完了しました。動画の後処理は次回起動時に再試行します。'));

    expect(find.text('保存は完了しました。動画の後処理は次回起動時に再試行します。'), findsOneWidget);
  });

  testWidgets('確認失敗を実体なしと誤表示せず再試行を出す', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(
      tester,
      database,
      record.id,
      videoState: const RecordVideoState(RecordVideoStateKind.checkFailed),
    );

    expect(find.textContaining('実体なしとは判定していません'), findsOneWidget);
    expect(find.text('もう一度確認'), findsOneWidget);
    expect(find.textContaining('動画の実体が見つかりません'), findsNothing);
  });

  testWidgets('10工程進捗と独立した総手術時間を表示する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final ccc = await repository.ensureStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      );
      await repository.saveStepTiming(
        review: ccc.copyWith(startMilliseconds: 1000, endMilliseconds: 61000),
        expectedVideoPath: null,
      );
      final total = await repository.ensureStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
      await repository.saveStepTiming(
        review: total.copyWith(startMilliseconds: 0, endMilliseconds: 754000),
        expectedVideoPath: null,
      );
    });

    await pumpScreen(tester, database, record.id);

    expect(find.text('工程 1/10'), findsOneWidget);
    expect(find.text('総手術時間：12分34秒'), findsOneWidget);
  });

  testWidgets('工程別時間は初期折りたたみで展開しても不足行を作らない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final semantics = tester.ensureSemantics();
    final before = await tester.runAsync(() async {
      return database
          .customSelect('SELECT * FROM surgical_step_reviews ORDER BY id')
          .get();
    });

    await pumpScreen(tester, database, record.id);

    final toggle = find.byKey(const Key('procedure-times-expansion-toggle'));
    expect(toggle, findsOneWidget);
    expect(find.byKey(const Key('procedure-times-list')), findsNothing);
    expect(
      tester.getSemantics(toggle).getSemanticsData().flagsCollection.isExpanded,
      isNot(Tristate.isTrue),
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('procedure-times-list')), findsOneWidget);
    expect(
      tester.getSemantics(toggle).getSemanticsData().flagsCollection.isExpanded,
      Tristate.isTrue,
    );
    for (final step in activeIndividualSurgicalSteps) {
      expect(
        find.byKey(ValueKey('procedure-time-row-${step.name}')),
        findsOneWidget,
      );
    }
    expect(
      find.byKey(const ValueKey('procedure-time-row-totalSurgeryTime')),
      findsNothing,
    );
    expect(find.text('開始まで：未登録'), findsNWidgets(10));

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final after = await tester.runAsync(() async {
      return database
          .customSelect('SELECT * FROM surgical_step_reviews ORDER BY id')
          .get();
    });
    expect(
      after!.map((row) => row.data).toList(),
      before!.map((row) => row.data).toList(),
    );
    semantics.dispose();
  });

  testWidgets('10工程の所要時間と到達時間を状態別に表示する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final semantics = tester.ensureSemantics();
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final reviews = await repository.ensureStepReviews(record.id);
      String idFor(SurgicalStep step) =>
          reviews.singleWhere((review) => review.step == step).id;
      Future<void> set(
        SurgicalStep step, {
        int? start,
        int? end,
        bool skipped = false,
      }) {
        return database.customStatement(
          '''
UPDATE surgical_step_reviews
SET start_milliseconds = ?, end_milliseconds = ?, is_skipped = ?
WHERE id = ?
''',
          <Object?>[start, end, skipped ? 1 : 0, idFor(step)],
        );
      }

      await set(SurgicalStep.totalSurgeryTime, start: 30000, end: 500000);
      await set(SurgicalStep.sidePortCreation, start: 45000, end: 75000);
      await set(SurgicalStep.ovdInjection, start: 80000);
      await set(SurgicalStep.capsulorhexis, skipped: true);
      await set(SurgicalStep.nucleusRemoval, start: 20000, end: 25000);
      await set(
        SurgicalStep.corticalIrrigationAspiration,
        start: 500001,
        end: 510000,
      );
      await set(SurgicalStep.iolInsertion, end: 200000);
      await set(
        SurgicalStep.ovdRemovalIrrigationAspiration,
        start: 250000,
        end: 250000,
      );
      await set(
        SurgicalStep.woundClosureAndPressureAdjustment,
        start: 300000,
        end: 290000,
      );
    });

    await pumpScreen(tester, database, record.id);
    await tester.tap(find.byKey(const Key('procedure-times-expansion-toggle')));
    await tester.pumpAndSettle();

    Finder row(SurgicalStep step) =>
        find.byKey(ValueKey('procedure-time-row-${step.name}'));
    Finder textIn(SurgicalStep step, String text) =>
        find.descendant(of: row(step), matching: find.text(text));

    expect(textIn(SurgicalStep.sidePortCreation, '所要時間：30秒'), findsOneWidget);
    expect(textIn(SurgicalStep.sidePortCreation, '開始まで：15秒'), findsOneWidget);
    expect(
      tester.getSemantics(row(SurgicalStep.sidePortCreation)).label,
      'サイドポート作成。手術開始から15秒で開始。所要時間30秒。',
    );
    expect(textIn(SurgicalStep.ovdInjection, '所要時間：計測中'), findsOneWidget);
    expect(textIn(SurgicalStep.ovdInjection, '開始まで：50秒'), findsOneWidget);
    expect(textIn(SurgicalStep.capsulorhexis, '所要時間：時間記録なし'), findsOneWidget);
    expect(textIn(SurgicalStep.capsulorhexis, '開始まで：時間記録なし'), findsOneWidget);
    expect(textIn(SurgicalStep.mainPortCreation, '開始まで：未登録'), findsOneWidget);
    expect(textIn(SurgicalStep.nucleusRemoval, '開始まで：要確認'), findsOneWidget);
    expect(
      textIn(SurgicalStep.nucleusRemoval, '工程開始位置を確認してください'),
      findsOneWidget,
    );
    expect(
      textIn(SurgicalStep.corticalIrrigationAspiration, '開始まで：要確認'),
      findsOneWidget,
    );
    expect(textIn(SurgicalStep.iolInsertion, '所要時間：要再設定'), findsOneWidget);
    expect(textIn(SurgicalStep.iolInsertion, '開始まで：要確認'), findsOneWidget);
    expect(
      textIn(SurgicalStep.ovdRemovalIrrigationAspiration, '所要時間：要再設定'),
      findsOneWidget,
    );
    expect(
      textIn(SurgicalStep.ovdRemovalIrrigationAspiration, '開始まで：3分40秒'),
      findsOneWidget,
    );
    expect(
      textIn(SurgicalStep.woundClosureAndPressureAdjustment, '所要時間：要再設定'),
      findsOneWidget,
    );
    expect(
      textIn(SurgicalStep.woundClosureAndPressureAdjustment, '開始まで：4分30秒'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('総手術開始未登録の説明を一覧近傍へ一度だけ表示する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final ccc = await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      );
      await database.customStatement(
        '''
UPDATE surgical_step_reviews
SET start_milliseconds = ?, end_milliseconds = ?
WHERE id = ?
''',
        <Object?>[250000, 300000, ccc!.id],
      );
    });

    await pumpScreen(tester, database, record.id);
    await tester.tap(find.byKey(const Key('procedure-times-expansion-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('開始まで：—'), findsOneWidget);
    expect(find.text('「総手術時間」の開始位置を登録すると「開始まで」が表示されます。'), findsOneWidget);
    expect(find.text('開始まで：未登録'), findsNWidgets(9));
  });

  testWidgets('snapshot失敗を工程カード内へ分離し再試行で一覧へ復帰する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    var attempts = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          recordProcedureTimingSnapshotProvider(record.id).overrideWith((
            ref,
          ) async {
            attempts++;
            if (attempts == 1) {
              throw StateError('fixture read failure');
            }
            return repository.fetchRecordProcedureTimingSnapshot(record.id);
          }),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('procedure-times-expansion-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('工程別時間を読み込めませんでした。'), findsOneWidget);
    expect(find.textContaining('総手術時間：'), findsOneWidget);
    expect(find.text('工程記録を開く'), findsOneWidget);

    final retry = find.byKey(const Key('procedure-times-retry'));
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.byKey(const Key('procedure-times-list')), findsOneWidget);
    expect(find.text('工程別時間を読み込めませんでした。'), findsNothing);
  });

  testWidgets('snapshot再読込中は古い到達時間を隠してloadingを表示する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    await tester.runAsync(() async {
      final total = await repository.ensureStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
      final ccc = await repository.ensureStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
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
        <Object?>[250000, 300000, ccc.id],
      );
    });

    final pendingRefresh = Completer<RecordProcedureTimingSnapshot>();
    var attempts = 0;
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => database),
        recordProcedureTimingSnapshotProvider(record.id).overrideWith((ref) {
          attempts++;
          if (attempts == 1) {
            return repository.fetchRecordProcedureTimingSnapshot(record.id);
          }
          return pendingRefresh.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('procedure-times-expansion-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('開始まで：3分40秒'), findsOneWidget);

    late RecordProcedureTimingSnapshot refreshedSnapshot;
    await tester.runAsync(() async {
      await database.customStatement(
        '''
UPDATE surgical_step_reviews
SET start_milliseconds = NULL, end_milliseconds = NULL
WHERE surgery_record_id = ?
''',
        <Object?>[record.id],
      );
      refreshedSnapshot = await repository.fetchRecordProcedureTimingSnapshot(
        record.id,
      );
    });
    container.invalidate(recordProcedureTimingSnapshotProvider(record.id));
    await tester.pump();

    expect(attempts, 2);
    expect(find.text('工程別時間を読み込んでいます…'), findsOneWidget);
    expect(find.byKey(const Key('procedure-times-list')), findsNothing);
    expect(find.text('開始まで：3分40秒'), findsNothing);

    pendingRefresh.complete(refreshedSnapshot);
    await tester.pumpAndSettle();
    expect(find.text('工程別時間を読み込んでいます…'), findsNothing);
    expect(find.byKey(const Key('procedure-times-list')), findsOneWidget);
    expect(find.text('開始まで：未登録'), findsNWidgets(10));
  });

  testWidgets('動画実体なしでも保存位置だけから到達時間を表示する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      final total = await repository.ensureStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
      final ccc = await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      );
      await database.customStatement(
        'UPDATE surgical_step_reviews SET start_milliseconds = ? WHERE id = ?',
        <Object?>[30000, total.id],
      );
      await database.customStatement(
        'UPDATE surgical_step_reviews SET start_milliseconds = ? WHERE id = ?',
        <Object?>[250000, ccc!.id],
      );
    });

    await pumpScreen(
      tester,
      database,
      record.id,
      videoState: const RecordVideoState(RecordVideoStateKind.missing),
    );
    await tester.tap(find.byKey(const Key('procedure-times-expansion-toggle')));
    await tester.pumpAndSettle();

    expect(find.textContaining('動画の実体が見つかりません'), findsOneWidget);
    expect(find.text('開始まで：3分40秒'), findsOneWidget);
  });

  testWidgets('320x568・文字倍率2.0で最長工程と既存導線へスクロール到達できる', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWith((ref) => database)],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 568),
              textScaler: TextScaler.linear(2),
            ),
            child: RecordDetailScreen(recordId: record.id),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    final list = find.byType(ListView);
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)),
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('procedure-times-expansion-toggle'));
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    final longest = find.text('I/A（粘弾性物質除去）');
    await tester.ensureVisible(longest);
    await tester.pumpAndSettle();
    expect(longest, findsOneWidget);
    final reviewButton = find.text('工程記録を開く');
    await tester.ensureVisible(reviewButton);
    await tester.pumpAndSettle();

    expect(reviewButton, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
