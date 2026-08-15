import 'dart:async';
import 'dart:io';

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/record_mutation_coordinator.dart';
import 'package:cataract_surgery_note/src/data/record_video_service.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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
  Future<void> verify(File file) async {}
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
    await database.customStatement('''
CREATE TRIGGER fail_record_creation
BEFORE INSERT ON surgery_records
BEGIN SELECT RAISE(ABORT, 'injected record failure'); END
''');

    await expectLater(
      service.createRecordWithVideo(
        surgeryDate: DateTime(2026, 8, 15),
        eyeSide: EyeSide.right,
        sourcePath: source.path,
        originalFileName: 'source.mp4',
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
    );

    await expectLater(
      failingService.createRecordWithVideo(
        surgeryDate: DateTime(2026, 8, 15),
        eyeSide: EyeSide.left,
        sourcePath: source.path,
        originalFileName: 'source.mp4',
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await surgeryRepository.watchableListSnapshot(), isEmpty);
    expect(await source.exists(), isTrue);
  });

  test('旧絶対path移行は動画参照以外の全記録を保持する', () async {
    final source = await _source(temporaryDirectory, 'legacy.mp4');
    final record = await _recordWithReview(surgeryRepository);
    await surgeryRepository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: source.path,
      videoDisplayName: 'legacy.mp4',
    );
    final beforeRecord = (await surgeryRepository.getRecord(record.id))!;
    final beforeRows = await _stepRows(database, record.id);

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

  test('初回添付と同一動画再登録は時刻・評価・メモを保持する', () async {
    final firstSource = await _source(temporaryDirectory, 'first.mp4');
    final sameSource = await _source(temporaryDirectory, 'same.mp4');
    final record = await _recordWithReview(surgeryRepository);
    final beforeRows = await _stepRows(database, record.id);

    final attached = await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      sourcePath: firstSource.path,
      originalFileName: 'first.mp4',
    );
    expect(await _stepRows(database, record.id), beforeRows);

    final relinked = await service.relinkSameVideo(
      surgeryRecordId: record.id,
      expectedVideoPath: attached.videoPath!,
      sourcePath: sameSource.path,
      originalFileName: 'same.mp4',
    );

    expect(relinked.videoPath, isNot(attached.videoPath));
    expect(await _stepRows(database, record.id), beforeRows);
    expect(relinked.caseMemo, record.caseMemo);
    expect(relinked.reviewStatus, record.reviewStatus);
  });

  test('同一動画再登録のDB失敗は旧参照・記録・旧動画だけを保持する', () async {
    final firstSource = await _source(temporaryDirectory, 'first.mp4');
    final sameSource = await _source(temporaryDirectory, 'same.mp4');
    final record = await _recordWithReview(surgeryRepository);
    final attached = await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      sourcePath: firstSource.path,
      originalFileName: 'first.mp4',
    );
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
        sourcePath: sameSource.path,
        originalFileName: 'same.mp4',
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
    final attached = await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      sourcePath: firstSource.path,
      originalFileName: 'first.mp4',
    );

    final replaced = await service.replaceVideoForRecord(
      surgeryRecordId: record.id,
      expectedVideoPath: attached.videoPath!,
      sourcePath: replacementSource.path,
      originalFileName: 'replacement.mp4',
    );

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
    final attached = await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      sourcePath: firstSource.path,
      originalFileName: 'first.mp4',
    );
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
    );

    await expectLater(
      corruptingService.replaceVideoForRecord(
        surgeryRecordId: record.id,
        expectedVideoPath: attached.videoPath!,
        sourcePath: replacementSource.path,
        originalFileName: 'replacement.mp4',
      ),
      throwsA(isA<FileSystemException>()),
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
    final attached = await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      sourcePath: firstSource.path,
      originalFileName: 'first.mp4',
    );
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
        sourcePath: replacementSource.path,
        originalFileName: 'replacement.mp4',
      ),
      throwsA(isA<VideoReferenceConflictException>()),
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
    final attached = await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      sourcePath: firstSource.path,
      originalFileName: 'first.mp4',
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
          sourcePath: replacementSource.path,
          originalFileName: 'replacement.mp4',
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
    final replaced = await replacement;
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
    final attached = await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      sourcePath: source.path,
      originalFileName: 'managed.mp4',
    );
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
    final attached = await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      sourcePath: source.path,
      originalFileName: 'managed.mp4',
    );
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
    final attached = await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      sourcePath: source.path,
      originalFileName: 'managed.mp4',
    );
    final failingStorage = _storage(
      supportDirectory,
      deleteFile: (file) async => throw const FileSystemException('削除失敗'),
    );
    final failingService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: failingStorage,
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
    );
    final report = await retryService.initialize();
    expect(report!.hasPendingCleanup, isFalse);
    expect(await retryStorage.resolveVideo(attached.videoPath!), isNull);
  });

  test('症例DB削除失敗は症例・工程・管理動画を保持する', () async {
    final source = await _source(temporaryDirectory, 'managed.mp4');
    final record = await _recordWithReview(surgeryRepository);
    final attached = await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      sourcePath: source.path,
      originalFileName: 'managed.mp4',
    );
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
    final attached = await service.attachVideoToRecord(
      surgeryRecordId: record.id,
      sourcePath: source.path,
      originalFileName: 'managed.mp4',
    );
    final failingStorage = _storage(
      supportDirectory,
      deleteFile: (file) async => throw const FileSystemException('削除失敗'),
    );
    final failingService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: failingStorage,
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
    final attached = await cleanupService.attachVideoToRecord(
      surgeryRecordId: record.id,
      sourcePath: firstSource.path,
      originalFileName: 'first.mp4',
    );

    final replaced = await cleanupService.replaceVideoForRecord(
      surgeryRecordId: record.id,
      expectedVideoPath: attached.videoPath!,
      sourcePath: replacementSource.path,
      originalFileName: 'replacement.mp4',
    );

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

    final retryStorage = _storage(supportDirectory);
    final retryService = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: retryStorage,
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
    );

    final attached = await throwingService.attachVideoToRecord(
      surgeryRecordId: record.id,
      sourcePath: source.path,
      originalFileName: 'managed.mp4',
    );

    expect(attached.videoPath, isNotNull);
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
    required String sourcePath,
    required String originalFileName,
  }) => delegate.importVideo(
    surgeryRecordId: surgeryRecordId,
    sourcePath: sourcePath,
    originalFileName: originalFileName,
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
       created_at, updated_at
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
