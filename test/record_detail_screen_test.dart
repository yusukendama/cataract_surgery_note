import 'dart:io';

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

  testWidgets('管理動画と除外read-backの両方が成功したときだけ確認済みと表示する', (tester) async {
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
    expect(find.byKey(const Key('backup-exclusion-verified')), findsOneWidget);
    expect(find.text('バックアップ除外を確認済みです。選択元の動画も別途保管してください。'), findsOneWidget);
    expect(find.byKey(const Key('backup-exclusion-warning')), findsNothing);
    expect(find.text('別の動画に差し替え'), findsOneWidget);
    expect(
      find.text('保存した動画が見つかりません。機種変更や端末の復元後は、元の動画を選び直してください。'),
      findsNothing,
    );
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
              backupExclusionFailures: <String>[
                'videos/root-record/present.mp4',
              ],
            ),
          ),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('backup-exclusion-warning')), findsOneWidget);
    expect(find.text('再確認'), findsOneWidget);
    expect(find.byKey(const Key('backup-exclusion-verified')), findsNothing);
    expect(find.textContaining('バックアップ対象外です'), findsNothing);
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

  testWidgets('4セクションを表示しreviewStatusに依存しない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(tester, database, record.id);

    expect(find.text('症例情報'), findsOneWidget);
    expect(find.text('動画'), findsOneWidget);
    expect(find.text('工程記録'), findsOneWidget);
    expect(find.byTooltip('再登録できる動画の目安'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('危険操作'), findsOneWidget);
    expect(find.textContaining('状態:'), findsNothing);
    expect(find.text(record.reviewStatus.label), findsNothing);
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

    expect(find.text('再登録できる動画の目安を見る'), findsOneWidget);
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
}
