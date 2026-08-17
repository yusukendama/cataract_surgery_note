import 'dart:io';

import 'package:cataract_surgery_note/src/data/protected_storage.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/video_import_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporaryDirectory;
  late Directory supportDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'video-storage-error-classification-',
    );
    supportDirectory = Directory(p.join(temporaryDirectory.path, 'support'));
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'native backup-exclusion signal remains distinct from file protection',
    () async {
      const methodChannel = MethodChannel(
        'test/protected-storage-error-classification',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        throw PlatformException(code: 'backup_exclusion_failed');
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(methodChannel, null),
      );
      final repository = MethodChannelProtectedStorageRepository(
        methodChannel: methodChannel,
      );

      await expectLater(
        repository.protectFileAndVerify(
          '/managed/video.mp4',
          excludeFromBackup: true,
        ),
        throwsA(isA<BackupExclusionException>()),
      );
    },
  );

  test(
    'native protection stage maps to a non-sensitive diagnostic code',
    () async {
      const methodChannel = MethodChannel(
        'test/protected-storage-stage-classification',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        throw PlatformException(
          code: 'file_protection_failed',
          details: 'database_sidecar',
        );
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(methodChannel, null),
      );
      final repository = MethodChannelProtectedStorageRepository(
        methodChannel: methodChannel,
      );

      await expectLater(
        repository.verifyDatabaseFiles(),
        throwsA(
          isA<FileProtectionException>()
              .having(
                (error) => error.stage,
                'stage',
                FileProtectionFailureStage.databaseSidecar,
              )
              .having(
                (error) => error.diagnosticCode,
                'diagnosticCode',
                'PS-DB-SIDECAR',
              ),
        ),
      );
    },
  );

  test(
    'native backup-exclusion failure maps to backupExclusionFailed',
    () async {
      final source = await _source(temporaryDirectory);
      final storage = _storage(
        supportDirectory,
        fileProtectionRepository: const _BackupFailingFileProtection(),
      );

      await expectLater(
        storage.importVideo(
          surgeryRecordId: 'record-1',
          candidate: await verifiedVideoCandidateForFile(source),
        ),
        throwsA(
          isA<VideoImportException>()
              .having(
                (error) => error.code,
                'code',
                VideoImportErrorCode.backupExclusionFailed,
              )
              .having(
                (error) => error.phase,
                'phase',
                VideoImportPhase.destinationProtection,
              )
              .having(
                (error) => error.internalReason,
                'internalReason',
                VideoImportInternalReasonV1.backupAttributeMismatch,
              ),
        ),
      );

      expect(await source.exists(), isTrue);
      expect(await _managedFiles(supportDirectory), isEmpty);
    },
  );

  test('post-copy size mismatch maps to copyIntegrityFailed', () async {
    final source = await _source(temporaryDirectory);
    final storage = _storage(
      supportDirectory,
      postCopyFaultInjector: (_, staged) async {
        await staged.writeAsBytes(<int>[1, 2, 3], flush: true);
      },
    );

    await expectLater(
      storage.importVideo(
        surgeryRecordId: 'record-1',
        candidate: await verifiedVideoCandidateForFile(source),
      ),
      throwsA(
        isA<VideoImportException>()
            .having(
              (error) => error.code,
              'code',
              VideoImportErrorCode.copyIntegrityFailed,
            )
            .having((error) => error.phase, 'phase', VideoImportPhase.copy),
      ),
    );

    expect(await source.exists(), isTrue);
    expect(await _managedFiles(supportDirectory), isEmpty);
  });

  test(
    'post-copy source rehash read failure maps to sourceReadFailed',
    () async {
      final source = await _source(temporaryDirectory);
      final candidate = await verifiedVideoCandidateForFile(source);
      final storage = _storage(
        supportDirectory,
        postCopyFaultInjector: (source, _) async {
          await source.delete();
          await Directory(source.path).create();
        },
      );

      await expectLater(
        storage.importVideo(surgeryRecordId: 'record-1', candidate: candidate),
        throwsA(
          isA<VideoImportException>()
              .having(
                (error) => error.code,
                'code',
                VideoImportErrorCode.sourceReadFailed,
              )
              .having(
                (error) => error.phase,
                'phase',
                VideoImportPhase.sourceHash,
              )
              .having(
                (error) => error.internalReason,
                'internalReason',
                VideoImportInternalReasonV1.sourceReadIo,
              ),
        ),
      );

      expect(await _managedFiles(supportDirectory), isEmpty);
    },
  );

  test('rename failure retains the renameFailed internal reason', () async {
    final source = await _source(temporaryDirectory);
    final storage = _storage(
      supportDirectory,
      renameFile: (_, newPath) async {
        throw FileSystemException(
          'rename rejected',
          newPath,
          const OSError('permission denied', 13),
        );
      },
    );

    await expectLater(
      storage.importVideo(
        surgeryRecordId: 'record-1',
        candidate: await verifiedVideoCandidateForFile(source),
      ),
      throwsA(
        isA<VideoImportException>()
            .having(
              (error) => error.code,
              'code',
              VideoImportErrorCode.destinationWriteFailed,
            )
            .having((error) => error.phase, 'phase', VideoImportPhase.copy)
            .having(
              (error) => error.internalReason,
              'internalReason',
              VideoImportInternalReasonV1.renameFailed,
            ),
      ),
    );

    expect(await source.exists(), isTrue);
    expect(await _managedFiles(supportDirectory), isEmpty);
  });
}

LocalVideoStorageRepository _storage(
  Directory supportDirectory, {
  FileProtectionRepository? fileProtectionRepository,
  Future<void> Function(File source, File staged)? postCopyFaultInjector,
  Future<File> Function(File file, String newPath)? renameFile,
}) {
  return LocalVideoStorageRepository(
    applicationSupportDirectory: supportDirectory,
    backupExclusionRepository: const _NoopBackupExclusion(),
    playbackVerifier: const _SuccessfulPlaybackVerifier(),
    fileProtectionRepository: fileProtectionRepository,
    postCopyFaultInjector: postCopyFaultInjector,
    renameFile: renameFile,
  );
}

Future<File> _source(Directory directory) async {
  final file = File(p.join(directory.path, 'source.mp4'));
  await file.writeAsBytes(
    List<int>.generate(4096, (index) => (index * 19) % 251),
    flush: true,
  );
  return file;
}

Future<List<File>> _managedFiles(Directory supportDirectory) async {
  final videos = Directory(p.join(supportDirectory.path, 'videos'));
  if (!await videos.exists()) {
    return <File>[];
  }
  return videos
      .list(recursive: true, followLinks: false)
      .where((entity) => entity is File)
      .cast<File>()
      .toList();
}

final class _NoopBackupExclusion implements BackupExclusionRepository {
  const _NoopBackupExclusion();

  @override
  Future<void> excludeFromBackup(String path) async {}
}

final class _SuccessfulPlaybackVerifier implements VideoPlaybackVerifier {
  const _SuccessfulPlaybackVerifier();

  @override
  Future<VideoPlaybackEvidence> verify(
    File file, {
    VideoImportCancellationToken? cancellationToken,
  }) async => testVideoPlaybackEvidence;
}

final class _BackupFailingFileProtection implements FileProtectionRepository {
  const _BackupFailingFileProtection();

  @override
  Future<ProtectedStoragePaths> prepareAppStorage() async {
    return const ProtectedStoragePaths(
      applicationSupportPath: '/unused',
      databasePath: '/unused/database.sqlite',
    );
  }

  @override
  Future<void> protectDirectoryAndVerify(String path) async {}

  @override
  Future<void> protectFileAndVerify(
    String path, {
    required bool excludeFromBackup,
  }) async {
    if (excludeFromBackup) {
      throw const BackupExclusionException();
    }
  }

  @override
  Future<void> verifyDatabaseFiles() async {}
}
