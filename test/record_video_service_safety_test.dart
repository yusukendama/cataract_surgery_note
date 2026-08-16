import 'dart:async';
import 'dart:io';

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/record_mutation_coordinator.dart';
import 'package:cataract_surgery_note/src/data/record_video_service.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/video_import_test_support.dart';

class _BackupExclusion implements BackupExclusionRepository {
  const _BackupExclusion({this.shouldThrow = false});

  final bool shouldThrow;

  @override
  Future<void> excludeFromBackup(String path) async {
    if (shouldThrow) {
      throw const FileSystemException('バックアップ除外失敗');
    }
  }
}

class _PlaybackVerifier implements VideoPlaybackVerifier {
  const _PlaybackVerifier();

  @override
  Future<VideoPlaybackEvidence> verify(
    File file, {
    VideoImportCancellationToken? cancellationToken,
  }) async => testVideoPlaybackEvidence;
}

class _RecordingBackupExclusion implements BackupExclusionRepository {
  final List<String> paths = <String>[];

  @override
  Future<void> excludeFromBackup(String path) async {
    paths.add(path);
  }
}

void main() {
  late Directory temporaryDirectory;
  late Directory supportDirectory;
  late AppDatabase database;
  late SurgeryRepository surgeryRepository;
  late LocalVideoStorageRepository videoStorageRepository;
  late RecordVideoService service;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'record_video_safety_',
    );
    supportDirectory = Directory(p.join(temporaryDirectory.path, 'support'));
    database = AppDatabase.memory();
    surgeryRepository = SurgeryRepository(database);
    videoStorageRepository = _storage(supportDirectory);
    service = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: videoStorageRepository,
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );
  });

  tearDown(() async {
    await surgeryRepository.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('新規症例のDB insert失敗時は症例と新規動画を残さない', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final candidate = await verifiedVideoCandidateForFile(source);
    await database.customStatement('''
CREATE TRIGGER fail_record_creation
BEFORE INSERT ON surgery_records
BEGIN SELECT RAISE(ABORT, 'injected record failure'); END
''');

    await expectLater(
      service.createRecordWithVideo(
        surgeryDate: DateTime(2026, 8, 15),
        eyeSide: EyeSide.right,
        candidate: candidate,
      ),
      throwsA(anything),
    );

    expect(await surgeryRepository.watchableListSnapshot(), isEmpty);
    expect(await source.exists(), isTrue);
    final root = Directory(p.join(supportDirectory.path, 'videos'));
    if (await root.exists()) {
      expect(
        await root.list(recursive: true).where((e) => e is File).toList(),
        isEmpty,
      );
    }
  });

  test('バックアップ除外失敗で症例を作成せず外部原本を保持する', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final failingService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: _storage(
        supportDirectory,
        backup: const _BackupExclusion(shouldThrow: true),
      ),
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );

    await expectLater(
      failingService.createRecordWithVideo(
        surgeryDate: DateTime(2026, 8, 15),
        eyeSide: EyeSide.left,
        candidate: await verifiedVideoCandidateForFile(source),
      ),
      throwsA(
        isA<VideoImportException>().having(
          (error) => error.code,
          'code',
          VideoImportErrorCode.backupExclusionFailed,
        ),
      ),
    );

    expect(await surgeryRepository.watchableListSnapshot(), isEmpty);
    expect(await source.exists(), isTrue);
  });

  test('旧schema症例の旧絶対path移行は時刻・skip・schema未移行を保持する', () async {
    final source = await _source(temporaryDirectory, 'legacy.mp4');
    final record = await _legacyRecordWithTimingAndSkipped(
      surgeryRepository,
      database,
    );
    await surgeryRepository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: source.path,
      videoDisplayName: 'legacy.mp4',
    );
    final beforeRecord = (await surgeryRepository.getRecord(record.id))!;
    final beforeRows = await _stepRows(database, record.id);
    expect(beforeRecord.reviewSchemaVersion, isNull);

    final migrated = await service.migrateLegacyVideoForRecord(beforeRecord);

    expect(
      classifyVideoPath(
        recordId: record.id,
        videoPath: migrated.videoPath,
      ).kind,
      VideoPathKind.managed,
    );
    expect(await source.exists(), isTrue);
    expect(await _stepRows(database, record.id), beforeRows);
    expect(migrated.surgeryDate, beforeRecord.surgeryDate);
    expect(migrated.eyeSide, beforeRecord.eyeSide);
    expect(migrated.caseMemo, beforeRecord.caseMemo);
    expect(migrated.reviewStatus, beforeRecord.reviewStatus);
    expect(migrated.reviewSchemaVersion, isNull);
    await _expectLegacyTimingAndSkipPreserved(surgeryRepository, record.id);

    final review = await surgeryRepository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    final savedTiming = await surgeryRepository.saveStepTiming(
      review: review!.copyWith(startMilliseconds: 200, endMilliseconds: 800),
      expectedVideoPath: migrated.videoPath,
    );
    expect(savedTiming.startMilliseconds, 200);
    expect(savedTiming.endMilliseconds, 800);
  });

  test('旧path移行失敗時は外部原本を再生対象とし記録を保持する', () async {
    final source = await _source(temporaryDirectory, 'legacy.mp4');
    final record = await _recordWithReview(surgeryRepository);
    await surgeryRepository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: source.path,
      videoDisplayName: 'legacy.mp4',
    );
    final withLegacyPath = (await surgeryRepository.getRecord(record.id))!;
    final beforeRows = await _stepRows(database, record.id);
    final failingService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: _storage(
        supportDirectory,
        backup: const _BackupExclusion(shouldThrow: true),
      ),
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );

    final resolved = await failingService.resolveVideoForRecord(withLegacyPath);

    expect(resolved!.path, source.path);
    expect(
      (await surgeryRepository.getRecord(record.id))!.videoPath,
      source.path,
    );
    expect(await _stepRows(database, record.id), beforeRows);
  });

  test('旧path移行のDB失敗は外部原本と全記録を保持する', () async {
    final source = await _source(temporaryDirectory, 'legacy.mp4');
    final record = await _recordWithReview(surgeryRepository);
    await surgeryRepository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: source.path,
      videoDisplayName: 'legacy.mp4',
    );
    final withLegacyPath = (await surgeryRepository.getRecord(record.id))!;
    final beforeRows = await _stepRows(database, record.id);
    await database.customStatement('''
CREATE TRIGGER fail_legacy_video_update
BEFORE UPDATE OF video_path ON surgery_records
BEGIN SELECT RAISE(ABORT, 'injected migration DB failure'); END
''');

    await expectLater(
      service.migrateLegacyVideoForRecord(withLegacyPath),
      throwsA(anything),
    );

    expect(await source.exists(), isTrue);
    expect(
      (await surgeryRepository.getRecord(record.id))!.videoPath,
      source.path,
    );
    expect(await _stepRows(database, record.id), beforeRows);
    expect(await _managedFiles(supportDirectory), isEmpty);
  });

  test('旧schema症例の初回添付は時刻・skip・schema未移行を保持する', () async {
    final source = await _source(temporaryDirectory, 'first.mp4');
    final record = await _legacyRecordWithTimingAndSkipped(
      surgeryRepository,
      database,
    );
    final beforeRows = await _stepRows(database, record.id);

    final attached = (await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(source),
    )).value;

    expect(await _stepRows(database, record.id), beforeRows);
    expect(attached.reviewSchemaVersion, isNull);
    expect(attached.caseMemo, record.caseMemo);
    expect(attached.reviewStatus, record.reviewStatus);
    await _expectLegacyTimingAndSkipPreserved(surgeryRepository, record.id);
  });

  test('保存済み工程時刻を満たさない初回添付は型付きduration conflictにする', () async {
    final source = await _source(temporaryDirectory, 'short.mp4');
    final record = await _recordWithReview(surgeryRepository);
    final review = await surgeryRepository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    await surgeryRepository.saveStepTiming(
      review: review!.copyWith(startMilliseconds: 100, endMilliseconds: 13000),
      expectedVideoPath: null,
    );
    final beforeRows = await _stepRows(database, record.id);

    await expectLater(
      service.attachVideoToRecord(
        surgeryRecordId: record.id,
        candidate: await verifiedVideoCandidateForFile(source),
      ),
      throwsA(
        isA<VideoImportException>()
            .having(
              (error) => error.code,
              'code',
              VideoImportErrorCode.durationConflict,
            )
            .having(
              (error) => error.internalReason,
              'internalReason',
              VideoImportInternalReasonV1.durationBelowRecordedTiming,
            )
            .having(
              (error) => error.primaryRecoveryAction,
              'primaryRecoveryAction',
              VideoImportRecoveryAction.resetTimingsAndAttach,
            ),
      ),
    );

    expect((await surgeryRepository.getRecord(record.id))!.videoPath, isNull);
    expect(await _stepRows(database, record.id), beforeRows);
    expect(await _managedFiles(supportDirectory), isEmpty);
    expect(await source.exists(), isTrue);
  });

  test('工程時刻なし確認後に時刻が追加された場合はcommitせずstaged動画を補償削除する', () async {
    final source = await _source(temporaryDirectory, 'race.mp4');
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 8, 16),
      eyeSide: EyeSide.left,
    );
    final review = await surgeryRepository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    final racingStorage = _AfterImportStorage(
      videoStorageRepository,
      afterImport: () => surgeryRepository.saveStepTiming(
        review: review.copyWith(startMilliseconds: 100, endMilliseconds: 900),
        expectedVideoPath: null,
      ),
    );
    final racingService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: racingStorage,
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );

    await expectLater(
      racingService.attachVideoToRecord(
        surgeryRecordId: record.id,
        candidate: await verifiedVideoCandidateForFile(source),
        timelineIdentityDeclaration:
            VideoTimelineIdentityDeclaration.noRecordedTimingsObserved,
      ),
      throwsA(
        isA<VideoImportException>()
            .having(
              (error) => error.code,
              'code',
              VideoImportErrorCode.videoReferenceConflict,
            )
            .having(
              (error) => error.internalReason,
              'internalReason',
              VideoImportInternalReasonV1.referenceCasMismatch,
            ),
      ),
    );

    final persistedRecord = await surgeryRepository.getRecord(record.id);
    final persistedReview = await surgeryRepository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    expect(persistedRecord!.videoPath, isNull);
    expect(persistedReview!.startMilliseconds, 100);
    expect(persistedReview.endMilliseconds, 900);
    expect(await _managedFiles(supportDirectory), isEmpty);
    expect(await source.exists(), isTrue);
  });

  test('record mutation lock待機中のcancelはDB更新前に停止してstaged動画を補償削除する', () async {
    final source = await _source(temporaryDirectory, 'cancel-at-lock.mp4');
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 8, 16),
      eyeSide: EyeSide.right,
    );
    final lockAcquired = Completer<void>();
    final releaseLock = Completer<void>();
    final heldMutation = surgeryRepository.runRecordMutation(
      record.id,
      () async {
        lockAcquired.complete();
        await releaseLock.future;
      },
    );
    await lockAcquired.future;

    final reachedCommit = Completer<void>();
    final cancellationToken = VideoImportCancellationToken();
    final operation = service.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(source),
      timelineIdentityDeclaration:
          VideoTimelineIdentityDeclaration.noRecordedTimingsObserved,
      cancellationToken: cancellationToken,
      onProgress: (progress) {
        if (progress.phase == VideoImportPhase.databaseCommit &&
            !reachedCommit.isCompleted) {
          reachedCommit.complete();
        }
      },
    );
    await reachedCommit.future;
    cancellationToken.cancel();
    releaseLock.complete();

    await expectLater(
      operation,
      throwsA(
        isA<VideoImportException>().having(
          (error) => error.code,
          'code',
          VideoImportErrorCode.userCanceled,
        ),
      ),
    );
    await heldMutation;

    expect((await surgeryRepository.getRecord(record.id))!.videoPath, isNull);
    expect(await _managedFiles(supportDirectory), isEmpty);
    expect(await source.exists(), isTrue);
  });

  test('DB commit後の遅いcancelは論理成功を失敗へ反転しない', () async {
    final source = await _source(temporaryDirectory, 'late-cancel.mp4');
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 8, 16),
      eyeSide: EyeSide.left,
    );
    final cancellationToken = VideoImportCancellationToken();
    final finishHookStorage = _AfterImportStorage(
      videoStorageRepository,
      onFinish: () async => cancellationToken.cancel(),
    );
    final finishHookService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: finishHookStorage,
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );

    final outcome = await finishHookService.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(source),
      timelineIdentityDeclaration:
          VideoTimelineIdentityDeclaration.noRecordedTimingsObserved,
      cancellationToken: cancellationToken,
    );

    expect(cancellationToken.isCancelled, isTrue);
    expect(outcome.value.videoPath, isNotNull);
    expect(
      (await surgeryRepository.getRecord(record.id))!.videoPath,
      outcome.value.videoPath,
    );
    expect(
      await videoStorageRepository.resolveVideo(outcome.value.videoPath!),
      isNotNull,
    );
  });

  test('attachWithTimingResetは時刻だけをリセットして初回添付する', () async {
    final source = await _source(temporaryDirectory, 'short.mp4');
    final record = await _recordWithReview(surgeryRepository);
    final review = await surgeryRepository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    await surgeryRepository.saveStepTiming(
      review: review!.copyWith(startMilliseconds: 100, endMilliseconds: 13000),
      expectedVideoPath: null,
    );

    final outcome = await service.attachWithTimingReset(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(source),
    );
    final attached = outcome.value;
    final persistedReview = await surgeryRepository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );

    expect(outcome.maintenanceOutcome, VideoMaintenanceOutcome.complete);
    expect(attached.videoPath, isNotNull);
    expect(attached.caseMemo, record.caseMemo);
    expect(attached.reviewStatus, record.reviewStatus);
    expect(persistedReview!.startMilliseconds, isNull);
    expect(persistedReview.endMilliseconds, isNull);
    expect(persistedReview.rating, StepRating.good);
    expect(persistedReview.reflection, '保持する反省点');
  });

  test('旧schema症例の同一動画再登録は時刻・skip・schema未移行を保持する', () async {
    final firstSource = await _source(temporaryDirectory, 'first.mp4');
    final sameSource = await _source(temporaryDirectory, 'same.mp4');
    final record = await _legacyRecordWithTimingAndSkipped(
      surgeryRepository,
      database,
    );
    final attached = (await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(firstSource),
    )).value;
    final beforeRows = await _stepRows(database, record.id);

    final relinked = (await service.relinkSameVideo(
      surgeryRecordId: record.id,
      expectedVideoPath: attached.videoPath!,
      candidate: await verifiedVideoCandidateForFile(sameSource),
    )).value;

    expect(relinked.videoPath, isNot(attached.videoPath));
    expect(await _stepRows(database, record.id), beforeRows);
    expect(relinked.reviewSchemaVersion, isNull);
    expect(relinked.caseMemo, record.caseMemo);
    expect(relinked.reviewStatus, record.reviewStatus);
    await _expectLegacyTimingAndSkipPreserved(surgeryRepository, record.id);
  });

  test('同一動画再登録のDB失敗は旧参照・記録・旧動画だけを保持する', () async {
    final firstSource = await _source(temporaryDirectory, 'first.mp4');
    final sameSource = await _source(temporaryDirectory, 'same.mp4');
    final record = await _recordWithReview(surgeryRepository);
    final attached = (await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(firstSource),
    )).value;
    final beforeRows = await _stepRows(database, record.id);
    final beforeFiles = await _managedFiles(supportDirectory);
    await database.customStatement('''
CREATE TRIGGER fail_relink_video_update
BEFORE UPDATE OF video_path ON surgery_records
BEGIN SELECT RAISE(ABORT, 'injected relink DB failure'); END
''');

    await expectLater(
      service.relinkSameVideo(
        surgeryRecordId: record.id,
        expectedVideoPath: attached.videoPath!,
        candidate: await verifiedVideoCandidateForFile(sameSource),
      ),
      throwsA(anything),
    );

    expect(
      (await surgeryRepository.getRecord(record.id))!.videoPath,
      attached.videoPath,
    );
    expect(await _stepRows(database, record.id), beforeRows);
    expect(await _managedFiles(supportDirectory), beforeFiles);
    expect(await sameSource.exists(), isTrue);
  });

  test('別動画差し替えだけが全工程時刻を消去する', () async {
    final firstSource = await _source(temporaryDirectory, 'first.mp4');
    final replacementSource = await _source(
      temporaryDirectory,
      'replacement.mp4',
    );
    final record = await _recordWithReview(surgeryRepository);
    final attached = (await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(firstSource),
    )).value;

    final replaced = (await service.replaceVideoForRecord(
      surgeryRecordId: record.id,
      expectedVideoPath: attached.videoPath!,
      candidate: await verifiedVideoCandidateForFile(replacementSource),
    )).value;

    final rows = await _stepRows(database, record.id);
    expect(rows.every((row) => row['start_milliseconds'] == null), isTrue);
    expect(rows.every((row) => row['end_milliseconds'] == null), isTrue);
    expect(rows.any((row) => row['reflection'] == '保持する反省点'), isTrue);
    expect(replaced.caseMemo, record.caseMemo);
    expect(replaced.reviewStatus, record.reviewStatus);
  });

  test('同サイズstaged破損は差し替えcommit前に拒否し旧状態を保持する', () async {
    final firstSource = await _source(temporaryDirectory, 'first.mp4');
    final replacementSource = await _source(
      temporaryDirectory,
      'replacement.mp4',
    );
    final record = await _recordWithReview(surgeryRepository);
    final attached = (await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(firstSource),
    )).value;
    final beforeRows = await _stepRows(database, record.id);
    final beforeFiles = await _managedFiles(supportDirectory);
    final replacementLength = await replacementSource.length();
    final corruptingService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: _storage(
        supportDirectory,
        postCopyFaultInjector: (source, staged) async {
          await staged.writeAsBytes(
            List<int>.filled(replacementLength, 0x5a),
            flush: true,
          );
        },
      ),
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );

    await expectLater(
      corruptingService.replaceVideoForRecord(
        surgeryRecordId: record.id,
        expectedVideoPath: attached.videoPath!,
        candidate: await verifiedVideoCandidateForFile(replacementSource),
      ),
      throwsA(
        isA<VideoImportException>().having(
          (error) => error.code,
          'code',
          VideoImportErrorCode.copyIntegrityFailed,
        ),
      ),
    );

    expect(
      (await surgeryRepository.getRecord(record.id))!.videoPath,
      attached.videoPath,
    );
    expect(await _stepRows(database, record.id), beforeRows);
    expect(await _managedFiles(supportDirectory), beforeFiles);
    expect(
      await videoStorageRepository.resolveVideo(attached.videoPath!),
      isNotNull,
    );
  });

  test('選択中に参照が変更された差し替えはcopy前に競合とする', () async {
    final firstSource = await _source(temporaryDirectory, 'first.mp4');
    final replacementSource = await _source(
      temporaryDirectory,
      'replacement.mp4',
    );
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final attached = (await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(firstSource),
    )).value;
    final newerPath = 'videos/${record.id}/newer.mp4';
    await surgeryRepository.updateVideoReferenceIfCurrent(
      surgeryRecordId: record.id,
      expectedVideoPath: attached.videoPath,
      videoPath: newerPath,
      videoDisplayName: 'newer.mp4',
    );
    final filesBefore = await _managedFiles(supportDirectory);

    await expectLater(
      service.replaceVideoForRecord(
        surgeryRecordId: record.id,
        expectedVideoPath: attached.videoPath!,
        candidate: await verifiedVideoCandidateForFile(replacementSource),
      ),
      throwsA(
        isA<VideoImportException>().having(
          (error) => error.code,
          'code',
          VideoImportErrorCode.videoReferenceConflict,
        ),
      ),
    );

    expect(await _managedFiles(supportDirectory), filesBefore);
    expect(
      (await surgeryRepository.getRecord(record.id))!.videoPath,
      newerPath,
    );
  });

  test('barrier競合で差し替え後に旧動画由来の時刻をcommitしない', () async {
    final firstSource = await _source(temporaryDirectory, 'first.mp4');
    final replacementSource = await _source(
      temporaryDirectory,
      'replacement.mp4',
    );
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final review = await surgeryRepository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    final attached = (await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(firstSource),
    )).value;
    final replacementCandidate = await verifiedVideoCandidateForFile(
      replacementSource,
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    final replacement = surgeryRepository.runRecordMutation(
      record.id,
      () async {
        entered.complete();
        await release.future;
        return service.replaceVideoForRecord(
          surgeryRecordId: record.id,
          expectedVideoPath: attached.videoPath!,
          candidate: replacementCandidate,
        );
      },
    );
    await entered.future;
    final staleTiming = surgeryRepository.saveStepTiming(
      review: review.copyWith(startMilliseconds: 10, endMilliseconds: 20),
      expectedVideoPath: attached.videoPath,
    );
    final staleExpectation = expectLater(
      staleTiming,
      throwsA(isA<VideoReferenceConflictException>()),
    );

    release.complete();
    final replaced = (await replacement).value;
    await staleExpectation;

    expect(replaced.videoPath, isNot(attached.videoPath));
    final persisted = await surgeryRepository.getStepReview(
      surgeryRecordId: record.id,
      step: review.step,
    );
    expect(persisted!.startMilliseconds, isNull);
    expect(persisted.endMilliseconds, isNull);
  });

  test('barrier競合で動画削除後に旧動画由来の時刻をcommitしない', () async {
    final source = await _source(temporaryDirectory, 'managed.mp4');
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.left,
    );
    final review = await surgeryRepository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    final attached = (await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(source),
    )).value;
    final entered = Completer<void>();
    final release = Completer<void>();
    final removal = surgeryRepository.runRecordMutation(record.id, () async {
      entered.complete();
      await release.future;
      return service.removeVideoForRecord(
        record.id,
        expectedVideoPath: attached.videoPath!,
      );
    });
    await entered.future;
    final staleTiming = surgeryRepository.saveStepTiming(
      review: review.copyWith(startMilliseconds: 10, endMilliseconds: 20),
      expectedVideoPath: attached.videoPath,
    );
    final staleExpectation = expectLater(
      staleTiming,
      throwsA(isA<VideoReferenceConflictException>()),
    );

    release.complete();
    final removed = await removal;
    await staleExpectation;

    expect(removed.videoPath, isNull);
    final persisted = await surgeryRepository.getStepReview(
      surgeryRecordId: record.id,
      step: review.step,
    );
    expect(persisted!.startMilliseconds, isNull);
    expect(persisted.endMilliseconds, isNull);
  });

  test('barrier競合で症例削除後の時刻UPDATEを成功扱いせず復活させない', () async {
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final review = await surgeryRepository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    final deletion = surgeryRepository.runRecordMutation(record.id, () async {
      entered.complete();
      await release.future;
      return service.deleteRecordAndManagedVideos(record.id);
    });
    await entered.future;
    final staleTiming = surgeryRepository.saveStepTiming(
      review: review.copyWith(startMilliseconds: 10, endMilliseconds: 20),
      expectedVideoPath: null,
    );
    final staleExpectation = expectLater(
      staleTiming,
      throwsA(isA<SurgeryRecordNotFoundException>()),
    );

    release.complete();
    await deletion;
    await staleExpectation;

    expect(await surgeryRepository.getRecord(record.id), isNull);
    expect(await _stepRows(database, record.id), isEmpty);
  });

  test('動画削除はDB commit後も旧外部原本を削除しない', () async {
    final source = await _source(temporaryDirectory, 'legacy.mp4');
    final record = await _recordWithReview(surgeryRepository);
    await surgeryRepository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: source.path,
      videoDisplayName: 'legacy.mp4',
    );

    final removed = await service.removeVideoForRecord(
      record.id,
      expectedVideoPath: source.path,
    );

    expect(removed.videoPath, isNull);
    expect(await source.exists(), isTrue);
    final rows = await _stepRows(database, record.id);
    expect(rows.every((row) => row['start_milliseconds'] == null), isTrue);
    expect(rows.any((row) => row['reflection'] == '保持する反省点'), isTrue);
  });

  test('動画削除のDB失敗は参照・時刻・管理動画を保持する', () async {
    final source = await _source(temporaryDirectory, 'managed.mp4');
    final record = await _recordWithReview(surgeryRepository);
    final attached = (await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(source),
    )).value;
    final beforeRows = await _stepRows(database, record.id);
    final beforeFiles = await _managedFiles(supportDirectory);
    await database.customStatement('''
CREATE TRIGGER fail_video_removal
BEFORE UPDATE OF video_path ON surgery_records
BEGIN SELECT RAISE(ABORT, 'injected remove DB failure'); END
''');

    await expectLater(
      service.removeVideoForRecord(
        record.id,
        expectedVideoPath: attached.videoPath!,
      ),
      throwsA(anything),
    );

    expect(
      (await surgeryRepository.getRecord(record.id))!.videoPath,
      attached.videoPath,
    );
    expect(await _stepRows(database, record.id), beforeRows);
    expect(await _managedFiles(supportDirectory), beforeFiles);
  });

  test('動画削除のcleanup失敗は次回初期化で再試行する', () async {
    final source = await _source(temporaryDirectory, 'managed.mp4');
    final record = await _recordWithReview(surgeryRepository);
    final attached = (await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(source),
    )).value;
    final failingStorage = _storage(
      supportDirectory,
      deleteFile: (file) async => throw const FileSystemException('削除失敗'),
    );
    final failingService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: failingStorage,
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );

    final removed = await failingService.removeVideoForRecord(
      record.id,
      expectedVideoPath: attached.videoPath!,
    );

    expect(removed.videoPath, isNull);
    expect(failingService.hasPendingCleanup, isTrue);
    expect(await failingStorage.resolveVideo(attached.videoPath!), isNotNull);

    final retryStorage = _storage(supportDirectory);
    final retryService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: retryStorage,
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );
    final report = await retryService.initialize();
    expect(report!.hasPendingCleanup, isFalse);
    expect(await retryStorage.resolveVideo(attached.videoPath!), isNull);
  });

  test('症例DB削除失敗は症例・工程・管理動画を保持する', () async {
    final source = await _source(temporaryDirectory, 'managed.mp4');
    final record = await _recordWithReview(surgeryRepository);
    final attached = (await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(source),
    )).value;
    final beforeRows = await _stepRows(database, record.id);
    await database.customStatement('''
CREATE TRIGGER fail_record_delete
BEFORE DELETE ON surgery_records
BEGIN SELECT RAISE(ABORT, 'injected record delete failure'); END
''');

    await expectLater(
      service.deleteRecordAndManagedVideos(record.id),
      throwsA(anything),
    );

    expect(await surgeryRepository.getRecord(record.id), isNotNull);
    expect(await _stepRows(database, record.id), beforeRows);
    expect(
      await videoStorageRepository.resolveVideo(attached.videoPath!),
      isNotNull,
    );
  });

  test('症例削除とmaintenanceは旧外部原本へ属性設定も削除もしない', () async {
    final source = await _source(temporaryDirectory, 'legacy.mp4');
    final record = await _recordWithReview(surgeryRepository);
    await surgeryRepository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: source.path,
      videoDisplayName: 'legacy.mp4',
    );
    final backup = _RecordingBackupExclusion();
    final externalSafeService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: _storage(supportDirectory, backup: backup),
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );

    final report = await externalSafeService.initialize();
    expect(report!.snapshotComplete, isTrue);
    expect(backup.paths, isNot(contains(source.path)));
    expect(await source.exists(), isTrue);

    await externalSafeService.deleteRecordAndManagedVideos(record.id);

    expect(await surgeryRepository.getRecord(record.id), isNull);
    expect(await source.exists(), isTrue);
    expect(backup.paths, isNot(contains(source.path)));
  });

  test('症例cleanup失敗はDB削除を戻さず次回初期化で再試行する', () async {
    final source = await _source(temporaryDirectory, 'managed.mp4');
    final record = await _recordWithReview(surgeryRepository);
    final attached = (await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(source),
    )).value;
    final failingStorage = _storage(
      supportDirectory,
      deleteFile: (file) async => throw const FileSystemException('削除失敗'),
    );
    final failingService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: failingStorage,
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );

    await failingService.deleteRecordAndManagedVideos(record.id);

    expect(await surgeryRepository.getRecord(record.id), isNull);
    expect(await _stepRows(database, record.id), isEmpty);
    expect(failingService.hasPendingCleanup, isTrue);
    expect(await failingStorage.resolveVideo(attached.videoPath!), isNotNull);

    final retryStorage = _storage(supportDirectory);
    final retryService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: retryStorage,
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );
    final report = await retryService.initialize();
    expect(report!.hasPendingCleanup, isFalse);
    expect(await retryStorage.resolveVideo(attached.videoPath!), isNull);
  });

  test('存在しない症例の0件DELETEでは全管理fileを保持する', () async {
    final sentinel = File(
      p.join(supportDirectory.path, 'videos', 'other-record', 'sentinel.mp4'),
    );
    await sentinel.parent.create(recursive: true);
    final originalBytes = <int>[1, 3, 5, 7];
    await sentinel.writeAsBytes(originalBytes);

    await expectLater(
      service.deleteRecordAndManagedVideos('missing-record'),
      throwsA(isA<SurgeryRecordNotFoundException>()),
    );

    expect(await sentinel.readAsBytes(), originalBytes);
  });

  test('不正recordIdの症例削除はfilesystemへ到達せず全fileを保持する', () async {
    final sentinel = File(
      p.join(supportDirectory.path, 'videos', 'other-record', 'sentinel.mp4'),
    );
    await sentinel.parent.create(recursive: true);
    final originalBytes = <int>[2, 4, 6, 8];
    await sentinel.writeAsBytes(originalBytes);

    for (final invalidId in <String>[
      '',
      '.',
      '..',
      'bad/id',
      r'bad\id',
      'bad\u0000id',
    ]) {
      expect(
        () => service.deleteRecordAndManagedVideos(invalidId),
        throwsA(isA<InvalidRecordIdentifierException>()),
        reason: invalidId,
      );
      expect(await sentinel.readAsBytes(), originalBytes, reason: invalidId);
    }
  });

  test('後処理削除失敗でもDB新状態と新動画は利用可能', () async {
    final failingCleanupStorage = _storage(
      supportDirectory,
      deleteFile: (file) async => throw const FileSystemException('削除失敗'),
    );
    final cleanupService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: failingCleanupStorage,
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );
    final firstSource = await _source(temporaryDirectory, 'first.mp4');
    final replacementSource = await _source(
      temporaryDirectory,
      'replacement.mp4',
    );
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.left,
    );
    final attached = (await cleanupService.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(firstSource),
    )).value;

    final replacementOutcome = await cleanupService.replaceVideoForRecord(
      surgeryRecordId: record.id,
      expectedVideoPath: attached.videoPath!,
      candidate: await verifiedVideoCandidateForFile(replacementSource),
    );
    final replaced = replacementOutcome.value;

    expect(
      (await surgeryRepository.getRecord(record.id))!.videoPath,
      replaced.videoPath,
    );
    expect(
      await failingCleanupStorage.resolveVideo(replaced.videoPath!),
      isNotNull,
    );
    expect(
      await failingCleanupStorage.resolveVideo(attached.videoPath!),
      isNotNull,
    );
    expect(cleanupService.hasPendingCleanup, isTrue);
    expect(
      replacementOutcome.maintenanceOutcome,
      VideoMaintenanceOutcome.pending,
    );

    final retryStorage = _storage(supportDirectory);
    final retryService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: retryStorage,
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );
    final retryReport = await retryService.initialize();

    expect(retryReport!.snapshotComplete, isTrue);
    expect(retryReport.hasPendingCleanup, isFalse);
    expect(await retryStorage.resolveVideo(replaced.videoPath!), isNotNull);
    expect(await retryStorage.resolveVideo(attached.videoPath!), isNull);
  });

  test('不完全snapshotはcleanup保留として公開する', () async {
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    await surgeryRepository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: 'videos/../outside.mp4',
      videoDisplayName: 'outside.mp4',
    );

    final report = await service.initialize();

    expect(report, isNotNull);
    expect(report!.snapshotComplete, isFalse);
    expect(report.backupExclusionVerified, isFalse);
    expect(report.hasPendingCleanup, isTrue);
    expect(service.hasPendingCleanup, isTrue);
  });

  test('commit後にmaintenance自体がthrowしても成功とcleanup保留を分離する', () async {
    final source = await _source(temporaryDirectory, 'managed.mp4');
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final throwingStorage = _ThrowingMaintenanceStorage(videoStorageRepository);
    final throwingService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: throwingStorage,
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );

    final outcome = await throwingService.attachVideoToRecord(
      surgeryRecordId: record.id,
      candidate: await verifiedVideoCandidateForFile(source),
    );
    final attached = outcome.value;

    expect(attached.videoPath, isNotNull);
    expect(outcome.maintenanceOutcome, VideoMaintenanceOutcome.pending);
    expect(
      (await surgeryRepository.getRecord(record.id))!.videoPath,
      attached.videoPath,
    );
    expect(throwingService.lastMaintenanceReport, isNotNull);
    expect(throwingService.lastMaintenanceReport!.snapshotComplete, isFalse);
    expect(throwingService.hasPendingCleanup, isTrue);
    expect(
      await videoStorageRepository.resolveVideo(attached.videoPath!),
      isNotNull,
    );
  });

  test('commit失敗後の補償削除失敗は主エラーとmaintenance保留を両方保持する', () async {
    final source = await _source(temporaryDirectory, 'managed.mp4');
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final failingStorage = _storage(
      supportDirectory,
      deleteFile: (file) async => throw const FileSystemException('削除失敗'),
    );
    final failingService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: failingStorage,
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );
    await database.customStatement('''
CREATE TRIGGER fail_video_attach
BEFORE UPDATE OF video_path ON surgery_records
BEGIN SELECT RAISE(ABORT, 'injected attach DB failure'); END
''');

    await expectLater(
      failingService.attachVideoToRecord(
        surgeryRecordId: record.id,
        candidate: await verifiedVideoCandidateForFile(source),
      ),
      throwsA(
        isA<VideoImportFailure>()
            .having(
              (failure) => failure.error.code,
              'code',
              VideoImportErrorCode.commitFailed,
            )
            .having(
              (failure) => failure.maintenanceOutcome,
              'maintenanceOutcome',
              VideoMaintenanceOutcome.pending,
            ),
      ),
    );

    expect((await surgeryRepository.getRecord(record.id))!.videoPath, isNull);
    expect(failingService.hasPendingCleanup, isTrue);
    expect(await _managedFiles(supportDirectory), hasLength(1));
    expect(await source.exists(), isTrue);
  });

  test('不正参照はfilesystemを触らず不正状態と判定する', () async {
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    await surgeryRepository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: 'videos/../outside.mp4',
      videoDisplayName: 'outside.mp4',
    );
    final invalid = (await surgeryRepository.getRecord(record.id))!;

    final state = await service.inspectVideoState(invalid);

    expect(state.kind, RecordVideoStateKind.invalidReference);
    expect(await supportDirectory.exists(), isFalse);
  });

  test('管理動画の実体なしとunsafe symlinkをmissing/checkFailedに分離する', () async {
    final missingRecord = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final missingPath = 'videos/${missingRecord.id}/missing.mp4';
    await surgeryRepository.updateVideoReference(
      surgeryRecordId: missingRecord.id,
      videoPath: missingPath,
      videoDisplayName: 'missing.mp4',
    );

    final missingState = await service.inspectVideoState(
      (await surgeryRepository.getRecord(missingRecord.id))!,
    );

    expect(missingState.kind, RecordVideoStateKind.missing);
    expect(missingState.error, isNull);

    final unsafeRecord = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 8, 16),
      eyeSide: EyeSide.left,
    );
    final recordDirectory = Directory(
      p.join(supportDirectory.path, 'videos', unsafeRecord.id),
    );
    await recordDirectory.create(recursive: true);
    final outsideFile = File(p.join(temporaryDirectory.path, 'outside.mp4'));
    await outsideFile.writeAsBytes(<int>[1, 2, 3]);
    final managedLink = Link(p.join(recordDirectory.path, 'managed.mp4'));
    await managedLink.create(outsideFile.path);
    await surgeryRepository.updateVideoReference(
      surgeryRecordId: unsafeRecord.id,
      videoPath: 'videos/${unsafeRecord.id}/managed.mp4',
      videoDisplayName: 'managed.mp4',
    );

    final unsafeState = await service.inspectVideoState(
      (await surgeryRepository.getRecord(unsafeRecord.id))!,
    );

    expect(unsafeState.kind, RecordVideoStateKind.checkFailed);
    expect(unsafeState.error, isA<FileSystemException>());
    expect(await outsideFile.readAsBytes(), <int>[1, 2, 3]);
    expect(await managedLink.exists(), isTrue);
  });
}

class _ThrowingMaintenanceStorage implements ManagedVideoStorageRepository {
  _ThrowingMaintenanceStorage(this.delegate);

  final ManagedVideoStorageRepository delegate;

  @override
  Future<void> deleteVideo(String relativePath) =>
      delegate.deleteVideo(relativePath);

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) =>
      delegate.deleteVideosForRecord(surgeryRecordId);

  @override
  Future<void> finishImport(String relativePath) =>
      delegate.finishImport(relativePath);

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) => delegate.importVideo(
    surgeryRecordId: surgeryRecordId,
    candidate: candidate,
    cancellationToken: cancellationToken,
    onProgress: onProgress,
  );

  @override
  Future<VideoStorageMaintenanceReport> maintainManagedStorage(
    Future<RecordVideoReferenceSnapshot> Function() loadReferences,
  ) => throw const FileSystemException('maintenance失敗');

  @override
  Future<File?> resolveVideo(String relativePath) =>
      delegate.resolveVideo(relativePath);

  @override
  Future<T> runStorageTransaction<T>(Future<T> Function() action) =>
      delegate.runStorageTransaction(action);
}

class _AfterImportStorage implements ManagedVideoStorageRepository {
  _AfterImportStorage(this.delegate, {this.afterImport, this.onFinish});

  final ManagedVideoStorageRepository delegate;
  final Future<void> Function()? afterImport;
  final Future<void> Function()? onFinish;

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    final stored = await delegate.importVideo(
      surgeryRecordId: surgeryRecordId,
      candidate: candidate,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
    await afterImport?.call();
    return stored;
  }

  @override
  Future<void> deleteVideo(String relativePath) =>
      delegate.deleteVideo(relativePath);

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) =>
      delegate.deleteVideosForRecord(surgeryRecordId);

  @override
  Future<void> finishImport(String relativePath) async {
    await delegate.finishImport(relativePath);
    await onFinish?.call();
  }

  @override
  Future<VideoStorageMaintenanceReport> maintainManagedStorage(
    Future<RecordVideoReferenceSnapshot> Function() loadReferences,
  ) => delegate.maintainManagedStorage(loadReferences);

  @override
  Future<File?> resolveVideo(String relativePath) =>
      delegate.resolveVideo(relativePath);

  @override
  Future<T> runStorageTransaction<T>(Future<T> Function() action) =>
      delegate.runStorageTransaction(action);
}

LocalVideoStorageRepository _storage(
  Directory supportDirectory, {
  BackupExclusionRepository backup = const _BackupExclusion(),
  Future<void> Function(File file)? deleteFile,
  Future<void> Function(File source, File staged)? postCopyFaultInjector,
}) {
  return LocalVideoStorageRepository(
    applicationSupportDirectory: supportDirectory,
    backupExclusionRepository: backup,
    playbackVerifier: const _PlaybackVerifier(),
    deleteFile: deleteFile,
    postCopyFaultInjector: postCopyFaultInjector,
  );
}

Future<SurgeryRecord> _recordWithReview(SurgeryRepository repository) async {
  final record = await repository.createRecord(
    surgeryDate: DateTime(2026, 8, 15),
    eyeSide: EyeSide.right,
  );
  final review = await repository.ensureStepReview(
    surgeryRecordId: record.id,
    step: SurgicalStep.capsulorhexis,
  );
  await repository.saveStepReview(
    review.copyWith(
      startMilliseconds: 100,
      endMilliseconds: 900,
      rating: StepRating.good,
      reflection: '保持する反省点',
    ),
  );
  await repository.updateCaseMemo(
    surgeryRecordId: record.id,
    caseMemo: '保持するメモ',
  );
  return (await repository.getRecord(record.id))!;
}

Future<SurgeryRecord> _legacyRecordWithTimingAndSkipped(
  SurgeryRepository repository,
  AppDatabase database,
) async {
  final record = await _recordWithReview(repository);
  final skippedReview = await repository.ensureStepReview(
    surgeryRecordId: record.id,
    step: SurgicalStep.sidePortCreation,
  );
  await repository.saveStepSkipped(
    review: skippedReview,
    isSkipped: true,
    expectedVideoPath: null,
  );
  await database.customStatement(
    '''
UPDATE surgery_records
SET review_schema_version = NULL
WHERE id = ?
''',
    <Object?>[record.id],
  );
  return (await repository.getRecord(record.id))!;
}

Future<void> _expectLegacyTimingAndSkipPreserved(
  SurgeryRepository repository,
  String recordId,
) async {
  final persistedRecord = await repository.getRecord(recordId);
  final timedReview = await repository.getStepReview(
    surgeryRecordId: recordId,
    step: SurgicalStep.capsulorhexis,
  );
  final skippedReview = await repository.getStepReview(
    surgeryRecordId: recordId,
    step: SurgicalStep.sidePortCreation,
  );

  expect(persistedRecord, isNotNull);
  expect(persistedRecord!.reviewSchemaVersion, isNull);
  expect(timedReview, isNotNull);
  expect(timedReview!.startMilliseconds, 100);
  expect(timedReview.endMilliseconds, 900);
  expect(timedReview.isSkipped, isFalse);
  expect(skippedReview, isNotNull);
  expect(skippedReview!.startMilliseconds, isNull);
  expect(skippedReview.endMilliseconds, isNull);
  expect(skippedReview.isSkipped, isTrue);
}

Future<File> _source(Directory directory, String name) async {
  final file = File(p.join(directory.path, name));
  await file.writeAsBytes(
    List<int>.generate(2048, (index) => (index * 17) % 256),
  );
  return file;
}

Future<List<Map<String, Object?>>> _stepRows(
  AppDatabase database,
  String recordId,
) async {
  final rows = await database
      .customSelect(
        '''
SELECT id, step, start_milliseconds, end_milliseconds, rating, reflection,
       is_skipped, created_at, updated_at
FROM surgical_step_reviews
WHERE surgery_record_id = ?
ORDER BY id
''',
        variables: <Variable<Object>>[Variable<String>(recordId)],
      )
      .get();
  return rows
      .map((row) => Map<String, Object?>.from(row.data))
      .toList(growable: false);
}

Future<List<String>> _managedFiles(Directory supportDirectory) async {
  final root = Directory(p.join(supportDirectory.path, 'videos'));
  if (!await root.exists()) {
    return const <String>[];
  }
  final files = await root
      .list(recursive: true, followLinks: false)
      .where((entity) => entity is File)
      .map((entity) => entity.path)
      .toList();
  files.sort();
  return files;
}
