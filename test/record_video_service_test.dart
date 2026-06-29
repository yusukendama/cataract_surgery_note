import 'dart:io';

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/record_video_service.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _NoopBackupExclusionRepository implements BackupExclusionRepository {
  @override
  Future<void> excludeFromBackup(String path) async {}
}

void main() {
  late Directory tempDirectory;
  late Directory supportDirectory;
  late SurgeryRepository surgeryRepository;
  late LocalVideoStorageRepository videoStorageRepository;
  late RecordVideoService service;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('record_video_test_');
    supportDirectory = Directory(p.join(tempDirectory.path, 'support'));
    surgeryRepository = SurgeryRepository(AppDatabase.memory());
    videoStorageRepository = LocalVideoStorageRepository(
      applicationSupportDirectory: supportDirectory,
      backupExclusionRepository: _NoopBackupExclusionRepository(),
    );
    service = RecordVideoService(
      surgeryRepository: surgeryRepository,
      videoStorageRepository: videoStorageRepository,
    );
  });

  tearDown(() async {
    await surgeryRepository.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('コピー失敗時に既存パスが維持される', () async {
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 6, 29),
      eyeSide: EyeSide.right,
    );
    final source = await _writeSourceVideo(tempDirectory, 'first.mp4', 512);
    final first = await service.importVideoForRecord(
      surgeryRecordId: record.id,
      sourcePath: source.path,
      originalFileName: 'first.mp4',
    );
    final oldPath = first.videoPath;

    await expectLater(
      () => service.importVideoForRecord(
        surgeryRecordId: record.id,
        sourcePath: p.join(tempDirectory.path, 'missing.mp4'),
        originalFileName: 'missing.mp4',
      ),
      throwsA(isA<FileSystemException>()),
    );
    final restored = await surgeryRepository.getRecord(record.id);

    expect(restored!.videoPath, oldPath);
    expect(await videoStorageRepository.resolveVideo(oldPath!), isNotNull);
  });

  test('動画再選択成功後に旧動画が削除される', () async {
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 6, 29),
      eyeSide: EyeSide.left,
    );
    final firstSource = await _writeSourceVideo(
      tempDirectory,
      'first.mp4',
      512,
    );
    final secondSource = await _writeSourceVideo(
      tempDirectory,
      'second.mov',
      1024,
    );
    final first = await service.importVideoForRecord(
      surgeryRecordId: record.id,
      sourcePath: firstSource.path,
      originalFileName: 'first.mp4',
    );
    final oldPath = first.videoPath!;

    final second = await service.importVideoForRecord(
      surgeryRecordId: record.id,
      sourcePath: secondSource.path,
      originalFileName: 'second.mov',
    );

    expect(second.videoPath, isNot(oldPath));
    expect(await videoStorageRepository.resolveVideo(oldPath), isNull);
    expect(
      await videoStorageRepository.resolveVideo(second.videoPath!),
      isNotNull,
    );
  });

  test('動画再選択失敗時に旧動画が残る', () async {
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 6, 29),
      eyeSide: EyeSide.right,
    );
    final source = await _writeSourceVideo(tempDirectory, 'first.mp4', 512);
    final first = await service.importVideoForRecord(
      surgeryRecordId: record.id,
      sourcePath: source.path,
      originalFileName: 'first.mp4',
    );

    await expectLater(
      () => service.importVideoForRecord(
        surgeryRecordId: record.id,
        sourcePath: source.path,
        originalFileName: 'invalid.avi',
      ),
      throwsA(isA<ArgumentError>()),
    );

    expect(
      await videoStorageRepository.resolveVideo(first.videoPath!),
      isNotNull,
    );
  });

  test('症例削除時に管理動画が削除される', () async {
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 6, 29),
      eyeSide: EyeSide.left,
    );
    final source = await _writeSourceVideo(tempDirectory, 'first.mp4', 512);
    final imported = await service.importVideoForRecord(
      surgeryRecordId: record.id,
      sourcePath: source.path,
      originalFileName: 'first.mp4',
    );

    await service.deleteRecordAndManagedVideos(record.id);

    expect(await surgeryRepository.getRecord(record.id), isNull);
    expect(
      await videoStorageRepository.resolveVideo(imported.videoPath!),
      isNull,
    );
  });

  test('CCCレビューが動画再選択後も維持される', () async {
    final record = await surgeryRepository.createRecord(
      surgeryDate: DateTime(2026, 6, 29),
      eyeSide: EyeSide.right,
    );
    final review = await surgeryRepository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    await surgeryRepository.saveStepReview(
      review.copyWith(
        startMilliseconds: 1000,
        endMilliseconds: 3000,
        rating: StepRating.good,
        reflection: '安定していた。',
      ),
    );
    final firstSource = await _writeSourceVideo(
      tempDirectory,
      'first.mp4',
      512,
    );
    final secondSource = await _writeSourceVideo(
      tempDirectory,
      'second.mp4',
      1024,
    );

    await service.importVideoForRecord(
      surgeryRecordId: record.id,
      sourcePath: firstSource.path,
      originalFileName: 'first.mp4',
    );
    await service.importVideoForRecord(
      surgeryRecordId: record.id,
      sourcePath: secondSource.path,
      originalFileName: 'second.mp4',
    );
    final restored = await surgeryRepository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );

    expect(restored!.startMilliseconds, 1000);
    expect(restored.endMilliseconds, 3000);
    expect(restored.rating, StepRating.good);
    expect(restored.reflection, '安定していた。');
  });
}

Future<File> _writeSourceVideo(
  Directory directory,
  String fileName,
  int sizeBytes,
) async {
  final file = File(p.join(directory.path, fileName));
  await file.writeAsBytes(
    List<int>.generate(sizeBytes, (index) => index % 256),
  );
  return file;
}
