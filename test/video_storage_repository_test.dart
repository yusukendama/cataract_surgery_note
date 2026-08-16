import 'dart:io';

import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/video_import_test_support.dart';

class _NoopBackupExclusionRepository implements BackupExclusionRepository {
  @override
  Future<void> excludeFromBackup(String path) async {}
}

class _NoopPlaybackVerifier implements VideoPlaybackVerifier {
  @override
  Future<VideoPlaybackEvidence> verify(
    File file, {
    VideoImportCancellationToken? cancellationToken,
  }) async => testVideoPlaybackEvidence;
}

void main() {
  late Directory tempDirectory;
  late Directory supportDirectory;
  late LocalVideoStorageRepository repository;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'video_storage_test_',
    );
    supportDirectory = Directory(p.join(tempDirectory.path, 'support'));
    repository = LocalVideoStorageRepository(
      applicationSupportDirectory: supportDirectory,
      backupExclusionRepository: _NoopBackupExclusionRepository(),
      playbackVerifier: _NoopPlaybackVerifier(),
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('動画コピー成功', () async {
    final source = await _writeSourceVideo(tempDirectory, 'source.mp4', 4096);

    final stored = await repository.importVideo(
      surgeryRecordId: 'record-1',
      candidate: await verifiedVideoCandidateForFile(source),
    );

    expect(stored.relativePath, startsWith('videos/record-1/'));
    expect(stored.relativePath, endsWith('.mp4'));
    expect(stored.originalFileName, 'source.mp4');
    expect(stored.sizeBytes, 4096);
    expect(stored.playbackEvidence.duration, const Duration(seconds: 12));
    expect(stored.playbackEvidence.width, 1920);
    expect(stored.playbackEvidence.height, 1080);
    expect(stored.playbackEvidence.aspectRatio, closeTo(16 / 9, 0.000001));
    expect(await repository.resolveVideo(stored.relativePath), isNotNull);
  });

  test('コピー元が存在しない場合は失敗する', () async {
    final source = await _writeSourceVideo(tempDirectory, 'missing.mp4', 128);
    final candidate = await verifiedVideoCandidateForFile(source);
    await source.delete();

    expect(
      () => repository.importVideo(
        surgeryRecordId: 'record-1',
        candidate: candidate,
      ),
      throwsA(
        isA<VideoImportException>().having(
          (error) => error.code,
          'code',
          VideoImportErrorCode.sourceChanged,
        ),
      ),
    );
  });

  test('コピー先ディレクトリを作成する', () async {
    final source = await _writeSourceVideo(tempDirectory, 'source.mov', 128);

    await repository.importVideo(
      surgeryRecordId: 'record-1',
      candidate: await verifiedVideoCandidateForFile(source),
    );

    expect(
      await Directory(
        p.join(supportDirectory.path, 'videos', 'record-1'),
      ).exists(),
      isTrue,
    );
  });

  test('コピー後のサイズが一致する', () async {
    final source = await _writeSourceVideo(tempDirectory, 'source.m4v', 8192);

    final stored = await repository.importVideo(
      surgeryRecordId: 'record-1',
      candidate: await verifiedVideoCandidateForFile(source),
    );
    final resolved = await repository.resolveVideo(stored.relativePath);

    expect(await resolved!.length(), await source.length());
  });

  test('相対パスから内部ファイルを解決できる', () async {
    final source = await _writeSourceVideo(tempDirectory, 'source.mp4', 256);
    final stored = await repository.importVideo(
      surgeryRecordId: 'record-1',
      candidate: await verifiedVideoCandidateForFile(source),
    );

    final resolved = await repository.resolveVideo(stored.relativePath);

    expect(resolved, isNotNull);
    expect(await resolved!.exists(), isTrue);
  });

  test('元動画は削除されない', () async {
    final source = await _writeSourceVideo(tempDirectory, 'source.mp4', 256);

    await repository.importVideo(
      surgeryRecordId: 'record-1',
      candidate: await verifiedVideoCandidateForFile(source),
    );

    expect(await source.exists(), isTrue);
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
