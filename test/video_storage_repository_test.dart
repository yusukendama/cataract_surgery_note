import 'dart:io';

import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _NoopBackupExclusionRepository implements BackupExclusionRepository {
  @override
  Future<void> excludeFromBackup(String path) async {}
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
      sourcePath: source.path,
      originalFileName: 'source.mp4',
    );

    expect(stored.relativePath, startsWith('videos/record-1/'));
    expect(stored.relativePath, endsWith('.mp4'));
    expect(stored.originalFileName, 'source.mp4');
    expect(stored.sizeBytes, 4096);
    expect(await repository.resolveVideo(stored.relativePath), isNotNull);
  });

  test('コピー元が存在しない場合は失敗する', () async {
    expect(
      () => repository.importVideo(
        surgeryRecordId: 'record-1',
        sourcePath: p.join(tempDirectory.path, 'missing.mp4'),
        originalFileName: 'missing.mp4',
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('コピー先ディレクトリを作成する', () async {
    final source = await _writeSourceVideo(tempDirectory, 'source.mov', 128);

    await repository.importVideo(
      surgeryRecordId: 'record-1',
      sourcePath: source.path,
      originalFileName: 'source.mov',
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
      sourcePath: source.path,
      originalFileName: 'source.m4v',
    );
    final resolved = await repository.resolveVideo(stored.relativePath);

    expect(await resolved!.length(), await source.length());
  });

  test('相対パスから内部ファイルを解決できる', () async {
    final source = await _writeSourceVideo(tempDirectory, 'source.mp4', 256);
    final stored = await repository.importVideo(
      surgeryRecordId: 'record-1',
      sourcePath: source.path,
      originalFileName: 'source.mp4',
    );

    final resolved = await repository.resolveVideo(stored.relativePath);

    expect(resolved, isNotNull);
    expect(await resolved!.exists(), isTrue);
  });

  test('元動画は削除されない', () async {
    final source = await _writeSourceVideo(tempDirectory, 'source.mp4', 256);

    await repository.importVideo(
      surgeryRecordId: 'record-1',
      sourcePath: source.path,
      originalFileName: 'source.mp4',
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
