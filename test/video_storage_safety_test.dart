import 'dart:async';
import 'dart:io';

import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _RecordingBackupExclusion implements BackupExclusionRepository {
  _RecordingBackupExclusion({this.throwOnCall});

  final int? throwOnCall;
  final List<String> paths = <String>[];

  @override
  Future<void> excludeFromBackup(String path) async {
    paths.add(path);
    if (paths.length == throwOnCall) {
      throw const FileSystemException('除外属性の確認失敗');
    }
  }
}

class _PlaybackVerifier implements VideoPlaybackVerifier {
  const _PlaybackVerifier({this.shouldThrow = false});

  final bool shouldThrow;

  @override
  Future<void> verify(File file) async {
    if (shouldThrow) {
      throw const FileSystemException('再生不能');
    }
  }
}

void main() {
  late Directory temporaryDirectory;
  late Directory supportDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'video_storage_safety_',
    );
    supportDirectory = Directory(p.join(temporaryDirectory.path, 'support'));
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  LocalVideoStorageRepository repository() {
    return LocalVideoStorageRepository(
      applicationSupportDirectory: supportDirectory,
      backupExclusionRepository: _RecordingBackupExclusion(),
      playbackVerifier: const _PlaybackVerifier(),
    );
  }

  test('root除外属性のread-back失敗時は最初の動画byteを書かない', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final repository = LocalVideoStorageRepository(
      applicationSupportDirectory: supportDirectory,
      backupExclusionRepository: _RecordingBackupExclusion(throwOnCall: 1),
      playbackVerifier: const _PlaybackVerifier(),
    );

    await expectLater(
      repository.importVideo(
        surgeryRecordId: 'record-1',
        sourcePath: source.path,
        originalFileName: 'source.mp4',
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(
      await Directory(
        p.join(supportDirectory.path, 'videos', 'record-1'),
      ).exists(),
      isFalse,
    );
    expect(await source.exists(), isTrue);
  });

  test('final fileの除外属性確認失敗で新規コピーを消去する', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final backup = _RecordingBackupExclusion(throwOnCall: 2);
    final repository = LocalVideoStorageRepository(
      applicationSupportDirectory: supportDirectory,
      backupExclusionRepository: backup,
      playbackVerifier: const _PlaybackVerifier(),
    );

    await expectLater(
      repository.importVideo(
        surgeryRecordId: 'record-1',
        sourcePath: source.path,
        originalFileName: 'source.mp4',
      ),
      throwsA(isA<FileSystemException>()),
    );

    final recordDirectory = Directory(
      p.join(supportDirectory.path, 'videos', 'record-1'),
    );
    expect(await recordDirectory.list().toList(), isEmpty);
    expect(backup.paths.first, endsWith('/support/videos'));
    expect(await source.exists(), isTrue);
  });

  test('再生probe失敗でDB候補にできるfinalを残さない', () async {
    final source = await _source(temporaryDirectory, 'source.mov');
    final repository = LocalVideoStorageRepository(
      applicationSupportDirectory: supportDirectory,
      backupExclusionRepository: _RecordingBackupExclusion(),
      playbackVerifier: const _PlaybackVerifier(shouldThrow: true),
    );

    await expectLater(
      repository.importVideo(
        surgeryRecordId: 'record-1',
        sourcePath: source.path,
        originalFileName: 'source.mov',
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      await Directory(
        p.join(supportDirectory.path, 'videos', 'record-1'),
      ).list().toList(),
      isEmpty,
    );
  });

  test('同サイズで内容が異なるstaged fileをSHA-256不一致で拒否する', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final sourceBytes = await source.readAsBytes();
    final storage = LocalVideoStorageRepository(
      applicationSupportDirectory: supportDirectory,
      backupExclusionRepository: _RecordingBackupExclusion(),
      playbackVerifier: const _PlaybackVerifier(),
      postCopyFaultInjector: (source, staged) async {
        await staged.writeAsBytes(
          List<int>.filled(sourceBytes.length, 0x5a),
          flush: true,
        );
      },
    );

    await expectLater(
      storage.importVideo(
        surgeryRecordId: 'record-1',
        sourcePath: source.path,
        originalFileName: 'source.mp4',
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await source.readAsBytes(), sourceBytes);
    expect(
      await Directory(
        p.join(supportDirectory.path, 'videos', 'record-1'),
      ).list().toList(),
      isEmpty,
    );
  });

  test('copy中に同サイズのsourceへ差し替わった場合も拒否する', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final sourceLength = await source.length();
    final storage = LocalVideoStorageRepository(
      applicationSupportDirectory: supportDirectory,
      backupExclusionRepository: _RecordingBackupExclusion(),
      playbackVerifier: const _PlaybackVerifier(),
      postCopyFaultInjector: (source, staged) async {
        await source.writeAsBytes(
          List<int>.filled(sourceLength, 0xa5),
          flush: true,
        );
      },
    );

    await expectLater(
      storage.importVideo(
        surgeryRecordId: 'record-1',
        sourcePath: source.path,
        originalFileName: 'source.mp4',
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await source.length(), sourceLength);
    expect(
      await Directory(
        p.join(supportDirectory.path, 'videos', 'record-1'),
      ).list().toList(),
      isEmpty,
    );
  });

  test('final filename衝突時は既存fileを保持して別名へ保存する', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final recordDirectory = Directory(
      p.join(supportDirectory.path, 'videos', 'record-1'),
    );
    await recordDirectory.create(recursive: true);
    final collision = File(p.join(recordDirectory.path, 'collision.mp4'));
    final originalBytes = <int>[9, 8, 7, 6, 5];
    await collision.writeAsBytes(originalBytes);
    final generatedIds = <String>[
      'collision',
      'unused-temp-id',
      'fresh',
      'fresh-temp-id',
    ];
    final storage = LocalVideoStorageRepository(
      applicationSupportDirectory: supportDirectory,
      backupExclusionRepository: _RecordingBackupExclusion(),
      playbackVerifier: const _PlaybackVerifier(),
      idGenerator: () => generatedIds.removeAt(0),
    );

    final stored = await storage.importVideo(
      surgeryRecordId: 'record-1',
      sourcePath: source.path,
      originalFileName: 'source.mp4',
    );

    expect(stored.relativePath, 'videos/record-1/fresh.mp4');
    expect(await collision.readAsBytes(), originalBytes);
    expect(await collision.exists(), isTrue);
    expect(
      await File(p.join(recordDirectory.path, 'fresh.mp4')).exists(),
      isTrue,
    );
    expect(
      (await recordDirectory.list().toList()).whereType<File>().map(
        (file) => p.basename(file.path),
      ),
      isNot(contains(endsWith('.tmp'))),
    );
    await storage.finishImport(stored.relativePath);
  });

  test('DB commit待ちfinalは並行reconciliationから保護する', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final storage = repository();
    final stored = await storage.importVideo(
      surgeryRecordId: 'record-1',
      sourcePath: source.path,
      originalFileName: 'source.mp4',
    );

    await storage.maintainManagedStorage(
      () async =>
          const RecordVideoReferenceSnapshot.complete(<RecordVideoReference>[]),
    );
    expect(await storage.resolveVideo(stored.relativePath), isNotNull);

    await storage.finishImport(stored.relativePath);
    await storage.maintainManagedStorage(
      () async =>
          const RecordVideoReferenceSnapshot.complete(<RecordVideoReference>[]),
    );
    expect(await storage.resolveVideo(stored.relativePath), isNull);
  });

  test('copy中のreconciliationはstorage lock後まで待ちcommit予定finalを保持する', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final copyReached = Completer<void>();
    final releaseCopy = Completer<void>();
    final storage = LocalVideoStorageRepository(
      applicationSupportDirectory: supportDirectory,
      backupExclusionRepository: _RecordingBackupExclusion(),
      playbackVerifier: const _PlaybackVerifier(),
      postCopyFaultInjector: (source, staged) async {
        copyReached.complete();
        await releaseCopy.future;
      },
    );

    final import = storage.importVideo(
      surgeryRecordId: 'record-1',
      sourcePath: source.path,
      originalFileName: 'source.mp4',
    );
    await copyReached.future;
    var maintenanceCompleted = false;
    final maintenance = storage
        .maintainManagedStorage(
          () async => const RecordVideoReferenceSnapshot.complete(
            <RecordVideoReference>[],
          ),
        )
        .then((report) {
          maintenanceCompleted = true;
          return report;
        });
    await Future<void>.delayed(Duration.zero);
    expect(maintenanceCompleted, isFalse);

    releaseCopy.complete();
    final stored = await import;
    final report = await maintenance;

    expect(report.snapshotComplete, isTrue);
    expect(await storage.resolveVideo(stored.relativePath), isNotNull);
    await storage.finishImport(stored.relativePath);
  });

  test('reconciliationは参照中finalと24時間以内tmpを保護する', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final storage = repository();
    final stored = await storage.importVideo(
      surgeryRecordId: 'record-1',
      sourcePath: source.path,
      originalFileName: 'source.mp4',
    );
    await storage.finishImport(stored.relativePath);
    final recordDirectory = Directory(
      p.join(supportDirectory.path, 'videos', 'record-1'),
    );
    final oldTemporary = File(p.join(recordDirectory.path, 'old.tmp'));
    final recentTemporary = File(p.join(recordDirectory.path, 'recent.tmp'));
    await oldTemporary.writeAsBytes(<int>[1]);
    await recentTemporary.writeAsBytes(<int>[2]);
    await oldTemporary.setLastModified(
      DateTime.now().subtract(const Duration(hours: 25)),
    );

    final report = await storage.maintainManagedStorage(
      () async => RecordVideoReferenceSnapshot.complete(<RecordVideoReference>[
        RecordVideoReference(
          recordId: 'record-1',
          videoPath: stored.relativePath,
        ),
      ]),
    );

    expect(report.snapshotComplete, isTrue);
    expect(await storage.resolveVideo(stored.relativePath), isNotNull);
    expect(await oldTemporary.exists(), isFalse);
    expect(await recentTemporary.exists(), isTrue);
  });

  test('DB参照snapshotが例外ならfail closedで一切削除しない', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final storage = repository();
    final stored = await storage.importVideo(
      surgeryRecordId: 'record-1',
      sourcePath: source.path,
      originalFileName: 'source.mp4',
    );
    await storage.finishImport(stored.relativePath);

    final report = await storage.maintainManagedStorage(
      () async => throw StateError('DB unavailable'),
    );

    expect(report.snapshotComplete, isFalse);
    expect(await storage.resolveVideo(stored.relativePath), isNotNull);
  });

  test('DB参照snapshotが部分結果なら両読込時点でfail closedにする', () async {
    final recordDirectory = Directory(
      p.join(supportDirectory.path, 'videos', 'record-1'),
    );
    await recordDirectory.create(recursive: true);
    final finalFile = File(p.join(recordDirectory.path, 'orphan.mp4'));
    final oldTemporary = File(p.join(recordDirectory.path, 'orphan.tmp'));
    await finalFile.writeAsBytes(<int>[1, 2, 3]);
    await oldTemporary.writeAsBytes(<int>[4, 5, 6]);
    await oldTemporary.setLastModified(
      DateTime.now().subtract(const Duration(hours: 25)),
    );
    final backup = _RecordingBackupExclusion();
    final storage = LocalVideoStorageRepository(
      applicationSupportDirectory: supportDirectory,
      backupExclusionRepository: backup,
      playbackVerifier: const _PlaybackVerifier(),
    );

    final firstReadIncomplete = await storage.maintainManagedStorage(
      () async => const RecordVideoReferenceSnapshot.incomplete(),
    );
    expect(firstReadIncomplete.snapshotComplete, isFalse);
    expect(backup.paths, isEmpty);
    expect(await finalFile.exists(), isTrue);
    expect(await oldTemporary.exists(), isTrue);

    var readCount = 0;
    final secondReadIncomplete = await storage.maintainManagedStorage(() async {
      readCount++;
      if (readCount == 1) {
        return const RecordVideoReferenceSnapshot.complete(
          <RecordVideoReference>[],
        );
      }
      return const RecordVideoReferenceSnapshot.incomplete();
    });
    expect(secondReadIncomplete.snapshotComplete, isFalse);
    expect(readCount, 2);
    expect(await finalFile.exists(), isTrue);
    expect(await oldTemporary.exists(), isTrue);
  });

  test('不正参照がある場合もfail closedで孤児を保持する', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final storage = repository();
    final stored = await storage.importVideo(
      surgeryRecordId: 'record-1',
      sourcePath: source.path,
      originalFileName: 'source.mp4',
    );
    await storage.finishImport(stored.relativePath);

    final report = await storage.maintainManagedStorage(
      () async =>
          const RecordVideoReferenceSnapshot.complete(<RecordVideoReference>[
            RecordVideoReference(
              recordId: 'record-2',
              videoPath: 'videos/record-1/source.mp4',
            ),
          ]),
    );

    expect(report.snapshotComplete, isFalse);
    expect(await storage.resolveVideo(stored.relativePath), isNotNull);
  });

  test('管理root内の実体を指す旧絶対pathを保護する', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final storage = repository();
    final stored = await storage.importVideo(
      surgeryRecordId: 'record-1',
      sourcePath: source.path,
      originalFileName: 'source.mp4',
    );
    await storage.finishImport(stored.relativePath);
    final file = await storage.resolveVideo(stored.relativePath);

    await storage.maintainManagedStorage(
      () async => RecordVideoReferenceSnapshot.complete(<RecordVideoReference>[
        RecordVideoReference(recordId: 'record-2', videoPath: file!.path),
      ]),
    );

    expect(await file!.exists(), isTrue);
  });

  test('管理root内fileを指す旧symlink絶対pathも保護する', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final storage = repository();
    final stored = await storage.importVideo(
      surgeryRecordId: 'record-1',
      sourcePath: source.path,
      originalFileName: 'source.mp4',
    );
    await storage.finishImport(stored.relativePath);
    final file = await storage.resolveVideo(stored.relativePath);
    final legacyLink = Link(p.join(temporaryDirectory.path, 'legacy.mp4'));
    await legacyLink.create(file!.path);

    final report = await storage.maintainManagedStorage(
      () async => RecordVideoReferenceSnapshot.complete(<RecordVideoReference>[
        RecordVideoReference(recordId: 'record-2', videoPath: legacyLink.path),
      ]),
    );

    expect(report.snapshotComplete, isTrue);
    expect(await file.exists(), isTrue);
    expect(await legacyLink.exists(), isTrue);
  });

  test('record directory symlinkでは全管理I/Oを拒否してlink先を保持する', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final videosRoot = Directory(p.join(supportDirectory.path, 'videos'));
    await videosRoot.create(recursive: true);
    final outside = Directory(
      p.join(temporaryDirectory.path, 'outside-record'),
    );
    await outside.create();
    final outsideFile = File(p.join(outside.path, 'managed.mp4'));
    final originalBytes = <int>[7, 7, 7];
    await outsideFile.writeAsBytes(originalBytes);
    final recordLink = Link(p.join(videosRoot.path, 'record-1'));
    await recordLink.create(outside.path);
    final backup = _RecordingBackupExclusion();
    final storage = LocalVideoStorageRepository(
      applicationSupportDirectory: supportDirectory,
      backupExclusionRepository: backup,
      playbackVerifier: const _PlaybackVerifier(),
    );

    await expectLater(
      storage.resolveVideo('videos/record-1/managed.mp4'),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      storage.importVideo(
        surgeryRecordId: 'record-1',
        sourcePath: source.path,
        originalFileName: 'source.mp4',
      ),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      storage.deleteVideo('videos/record-1/managed.mp4'),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      storage.deleteVideosForRecord('record-1'),
      throwsA(isA<FileSystemException>()),
    );
    final backupCallsBeforeMaintenance = backup.paths.length;
    final report = await storage.maintainManagedStorage(
      () async =>
          const RecordVideoReferenceSnapshot.complete(<RecordVideoReference>[
            RecordVideoReference(
              recordId: 'record-1',
              videoPath: 'videos/record-1/managed.mp4',
            ),
          ]),
    );

    expect(report.snapshotComplete, isFalse);
    expect(backup.paths, hasLength(backupCallsBeforeMaintenance));
    expect(await outsideFile.readAsBytes(), originalBytes);
    expect(await recordLink.exists(), isTrue);
    expect(await source.exists(), isTrue);
  });

  test('managed file symlinkではresolve・削除・属性設定を拒否する', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final recordDirectory = Directory(
      p.join(supportDirectory.path, 'videos', 'record-1'),
    );
    await recordDirectory.create(recursive: true);
    final outsideFile = File(p.join(temporaryDirectory.path, 'outside.mp4'));
    final originalBytes = <int>[6, 5, 4, 3];
    await outsideFile.writeAsBytes(originalBytes);
    final fileLink = Link(p.join(recordDirectory.path, 'managed.mp4'));
    await fileLink.create(outsideFile.path);
    final backup = _RecordingBackupExclusion();
    final storage = LocalVideoStorageRepository(
      applicationSupportDirectory: supportDirectory,
      backupExclusionRepository: backup,
      playbackVerifier: const _PlaybackVerifier(),
      idGenerator: () => 'managed',
    );

    await expectLater(
      storage.resolveVideo('videos/record-1/managed.mp4'),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      storage.importVideo(
        surgeryRecordId: 'record-1',
        sourcePath: source.path,
        originalFileName: 'source.mp4',
      ),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      storage.deleteVideo('videos/record-1/managed.mp4'),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      storage.deleteVideosForRecord('record-1'),
      throwsA(isA<FileSystemException>()),
    );
    final backupCallsBeforeMaintenance = backup.paths.length;
    final report = await storage.maintainManagedStorage(
      () async =>
          const RecordVideoReferenceSnapshot.complete(<RecordVideoReference>[
            RecordVideoReference(
              recordId: 'record-1',
              videoPath: 'videos/record-1/managed.mp4',
            ),
          ]),
    );

    expect(report.snapshotComplete, isFalse);
    expect(backup.paths, hasLength(backupCallsBeforeMaintenance));
    expect(await outsideFile.readAsBytes(), originalBytes);
    expect(await fileLink.exists(), isTrue);
    expect(await source.exists(), isTrue);
  });

  test('videos rootがsymlinkならI/Oを拒否しlink先を保持する', () async {
    final source = await _source(temporaryDirectory, 'source.mp4');
    final outside = Directory(p.join(temporaryDirectory.path, 'outside'));
    await outside.create();
    await supportDirectory.create();
    await Link(p.join(supportDirectory.path, 'videos')).create(outside.path);
    final storage = repository();

    await expectLater(
      storage.importVideo(
        surgeryRecordId: 'record-1',
        sourcePath: source.path,
        originalFileName: 'source.mp4',
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await outside.list().toList(), isEmpty);
    expect(await source.exists(), isTrue);
  });
}

Future<File> _source(Directory directory, String name) async {
  final file = File(p.join(directory.path, name));
  await file.writeAsBytes(
    List<int>.generate(4096, (index) => (index * 31) % 256),
  );
  return file;
}
