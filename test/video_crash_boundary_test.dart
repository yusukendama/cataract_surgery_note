import 'dart:io';

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/record_video_service.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/video_import_test_support.dart';

class _BackupExclusion implements BackupExclusionRepository {
  const _BackupExclusion();

  @override
  Future<void> excludeFromBackup(String path) async {}
}

class _PlaybackVerifier implements VideoPlaybackVerifier {
  const _PlaybackVerifier();

  @override
  Future<VideoPlaybackEvidence> verify(
    File file, {
    VideoImportCancellationToken? cancellationToken,
  }) async => testVideoPlaybackEvidence;
}

void main() {
  test('commit前後のcrash境界をfile-backed DB再openと次回reconciliationで回復する', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'video-crash-boundary-',
    );
    final databaseFile = File(
      p.join(temporaryDirectory.path, 'database.sqlite'),
    );
    final supportDirectory = Directory(
      p.join(temporaryDirectory.path, 'support'),
    );
    final storage = LocalVideoStorageRepository(
      applicationSupportDirectory: supportDirectory,
      backupExclusionRepository: const _BackupExclusion(),
      playbackVerifier: const _PlaybackVerifier(),
    );
    SurgeryRepository? repository;
    try {
      repository = SurgeryRepository(
        AppDatabase.forExecutor(NativeDatabase(databaseFile)),
      );
      final record = await repository.createRecord(
        surgeryDate: DateTime(2026, 8, 15),
        eyeSide: EyeSide.right,
      );
      final review = await repository.ensureStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      );
      await repository.saveStepTiming(
        review: review.copyWith(startMilliseconds: 100, endMilliseconds: 900),
        expectedVideoPath: null,
      );
      final oldSource = await _source(temporaryDirectory, 'old.mp4', 17);
      final oldStored = await storage.importVideo(
        surgeryRecordId: record.id,
        candidate: await verifiedVideoCandidateForFile(oldSource),
      );
      await repository.updateVideoReferenceIfCurrent(
        surgeryRecordId: record.id,
        expectedVideoPath: null,
        videoPath: oldStored.relativePath,
        videoDisplayName: oldStored.originalFileName,
      );
      await storage.finishImport(oldStored.relativePath);

      // Simulates a process ending after a new final file is staged but before
      // its DB reference transaction commits.
      final uncommittedFinal = File(
        p.join(supportDirectory.path, 'videos', record.id, 'uncommitted.mp4'),
      );
      await uncommittedFinal.writeAsBytes(<int>[9, 9, 9]);
      await repository.close();
      repository = null;

      repository = SurgeryRepository(
        AppDatabase.forExecutor(NativeDatabase(databaseFile)),
      );
      final beforeCommitRecord = await repository.getRecord(record.id);
      final beforeCommitReview = await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      );
      expect(beforeCommitRecord!.videoPath, oldStored.relativePath);
      expect(beforeCommitReview!.startMilliseconds, 100);
      expect(beforeCommitReview.endMilliseconds, 900);
      expect(await storage.resolveVideo(oldStored.relativePath), isNotNull);
      expect(await uncommittedFinal.exists(), isTrue);

      // Simulates COMMIT succeeding and the process ending before old-file
      // cleanup. The new reference must survive the next open.
      final newSource = await _source(temporaryDirectory, 'new.mp4', 31);
      final newStored = await storage.importVideo(
        surgeryRecordId: record.id,
        candidate: await verifiedVideoCandidateForFile(newSource),
      );
      await repository.replaceVideoReferenceAndClearTimings(
        surgeryRecordId: record.id,
        expectedVideoPath: oldStored.relativePath,
        videoPath: newStored.relativePath,
        videoDisplayName: newStored.originalFileName,
      );
      await storage.finishImport(newStored.relativePath);
      await repository.close();
      repository = null;

      repository = SurgeryRepository(
        AppDatabase.forExecutor(NativeDatabase(databaseFile)),
      );
      final afterCommitRecord = await repository.getRecord(record.id);
      final afterCommitReview = await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      );
      expect(afterCommitRecord!.videoPath, newStored.relativePath);
      expect(afterCommitReview!.startMilliseconds, isNull);
      expect(afterCommitReview.endMilliseconds, isNull);
      expect(await storage.resolveVideo(newStored.relativePath), isNotNull);
      expect(await storage.resolveVideo(oldStored.relativePath), isNotNull);

      final service = RecordVideoService(
        surgeryRepository: repository,
        videoStorageRepository: storage,
        videoImportPreflight: const PassThroughVideoImportPreflight(),
      );
      final report = await service.initialize();
      expect(report!.snapshotComplete, isTrue);
      expect(await storage.resolveVideo(newStored.relativePath), isNotNull);
      expect(await storage.resolveVideo(oldStored.relativePath), isNull);
      expect(await uncommittedFinal.exists(), isFalse);
    } finally {
      await repository?.close();
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    }
  });
}

Future<File> _source(Directory directory, String name, int salt) async {
  final file = File(p.join(directory.path, name));
  await file.writeAsBytes(
    List<int>.generate(4096, (index) => (index * salt) % 256),
  );
  return file;
}
