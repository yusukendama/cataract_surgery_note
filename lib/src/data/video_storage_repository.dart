import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import 'file_sha256.dart';
import 'video_path_classifier.dart';

export 'video_path_classifier.dart';

class StoredVideo {
  const StoredVideo({
    required this.relativePath,
    required this.originalFileName,
    required this.sizeBytes,
    required this.sha256,
  });

  final String relativePath;
  final String originalFileName;
  final int sizeBytes;
  final String sha256;
}

abstract interface class VideoStorageRepository {
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required String sourcePath,
    required String originalFileName,
  });

  /// Returns `null` only when a valid managed reference has no file on disk.
  ///
  /// Invalid references and filesystem safety/check failures are surfaced as
  /// errors so callers can distinguish them from a genuinely missing file.
  Future<File?> resolveVideo(String relativePath);

  Future<void> deleteVideo(String relativePath);

  Future<void> deleteVideosForRecord(String surgeryRecordId);
}

/// Extended operations used by the production storage implementation.
///
/// Kept separate from [VideoStorageRepository] so lightweight test and preview
/// implementations do not acquire filesystem maintenance responsibilities.
abstract interface class ManagedVideoStorageRepository
    implements VideoStorageRepository {
  Future<T> runStorageTransaction<T>(Future<T> Function() action);

  /// Releases the in-process protection held for an imported final file once
  /// its DB commit or compensation has completed.
  Future<void> finishImport(String relativePath);

  Future<VideoStorageMaintenanceReport> maintainManagedStorage(
    Future<RecordVideoReferenceSnapshot> Function() loadReferences,
  );
}

class RecordVideoReference {
  const RecordVideoReference({required this.recordId, required this.videoPath});

  final String recordId;
  final String? videoPath;
}

/// An explicit completeness proof for one consistent DB reference read.
///
/// A plain list cannot distinguish "there are no references" from "the DB
/// reader returned only part of the rows". Cleanup must fail closed in the
/// latter case, so callers have to positively mark a snapshot complete.
class RecordVideoReferenceSnapshot {
  const RecordVideoReferenceSnapshot.complete(this.references)
    : isComplete = true;

  const RecordVideoReferenceSnapshot.incomplete([
    this.references = const <RecordVideoReference>[],
  ]) : isComplete = false;

  final List<RecordVideoReference> references;
  final bool isComplete;
}

class VideoStorageMaintenanceReport {
  const VideoStorageMaintenanceReport({
    required this.snapshotComplete,
    required this.deletedPaths,
    required this.backupExclusionFailures,
    this.cleanupFailures = const <String>[],
  });

  final bool snapshotComplete;
  final List<String> deletedPaths;
  final List<String> backupExclusionFailures;
  final List<String> cleanupFailures;

  bool get backupExclusionVerified =>
      snapshotComplete && backupExclusionFailures.isEmpty;
  bool get hasPendingCleanup => !snapshotComplete || cleanupFailures.isNotEmpty;
}

abstract interface class BackupExclusionRepository {
  /// Must return only after setting and reading back the exclusion attribute.
  Future<void> excludeFromBackup(String path);
}

class MethodChannelBackupExclusionRepository
    implements BackupExclusionRepository {
  const MethodChannelBackupExclusionRepository();

  static const MethodChannel _channel = MethodChannel(
    'cataract_surgery_note/backup',
  );

  @override
  Future<void> excludeFromBackup(String path) async {
    final verified = await _channel.invokeMethod<bool>(
      'excludeFromBackup',
      <String, Object>{'path': path},
    );
    if (verified != true) {
      throw PlatformException(
        code: 'backup_exclusion_not_verified',
        message: 'バックアップ除外属性を確認できませんでした。',
      );
    }
  }
}

abstract interface class VideoPlaybackVerifier {
  Future<void> verify(File file);
}

class VideoPlayerPlaybackVerifier implements VideoPlaybackVerifier {
  const VideoPlayerPlaybackVerifier();

  @override
  Future<void> verify(File file) async {
    final controller = VideoPlayerController.file(file);
    try {
      await controller.initialize();
      final value = controller.value;
      if (!value.isInitialized ||
          value.duration <= Duration.zero ||
          value.hasError) {
        throw const FileSystemException('動画を再生できません。');
      }
      await controller.play();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (controller.value.hasError) {
        throw const FileSystemException('動画のデコードに失敗しました。');
      }
      await controller.pause();
    } finally {
      await controller.dispose();
    }
  }
}

class LocalVideoStorageRepository implements ManagedVideoStorageRepository {
  LocalVideoStorageRepository({
    Directory? applicationSupportDirectory,
    Uuid? uuid,
    BackupExclusionRepository? backupExclusionRepository,
    VideoPlaybackVerifier? playbackVerifier,
    DateTime Function()? clock,
    Future<void> Function(File file)? deleteFile,
    String Function()? idGenerator,
    Future<void> Function(File source, File staged)? postCopyFaultInjector,
  }) : _applicationSupportDirectory = applicationSupportDirectory,
       _idGenerator = idGenerator ?? (() => (uuid ?? const Uuid()).v4()),
       _backupExclusionRepository =
           backupExclusionRepository ??
           const MethodChannelBackupExclusionRepository(),
       _playbackVerifier =
           playbackVerifier ?? const VideoPlayerPlaybackVerifier(),
       _clock = clock ?? DateTime.now,
       _deleteFile = deleteFile ?? _defaultDeleteFile,
       _postCopyFaultInjector = postCopyFaultInjector;

  static final _AsyncMutex _storageMutex = _AsyncMutex();
  static final Set<String> _importsAwaitingDatabaseCommit = <String>{};
  static const Set<String> _supportedExtensions = <String>{
    '.mp4',
    '.mov',
    '.m4v',
  };

  final Directory? _applicationSupportDirectory;
  final String Function() _idGenerator;
  final BackupExclusionRepository _backupExclusionRepository;
  final VideoPlaybackVerifier _playbackVerifier;
  final DateTime Function() _clock;
  final Future<void> Function(File file) _deleteFile;
  final Future<void> Function(File source, File staged)? _postCopyFaultInjector;

  @override
  Future<T> runStorageTransaction<T>(Future<T> Function() action) {
    return _storageMutex.synchronized(action);
  }

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required String sourcePath,
    required String originalFileName,
  }) {
    return _storageMutex.synchronized(() async {
      if (!isValidRecordId(surgeryRecordId)) {
        throw ArgumentError.value(
          surgeryRecordId,
          'surgeryRecordId',
          '不正な症例IDです。',
        );
      }
      final source = File(sourcePath);
      final sourceType = await FileSystemEntity.type(
        source.path,
        followLinks: true,
      );
      if (sourceType != FileSystemEntityType.file) {
        throw const FileSystemException('選択した動画が存在しません。');
      }

      final extension = p.extension(originalFileName).toLowerCase();
      if (!_supportedExtensions.contains(extension)) {
        throw ArgumentError('対応している動画形式は mp4 / mov / m4v です。');
      }

      final videosRoot = await _ensureSafeVideosRoot();
      // No video byte may be written until this call has set and read back the
      // directory's exclusion attribute.
      await _backupExclusionRepository.excludeFromBackup(videosRoot.path);
      final recordDirectory = await _ensureSafeRecordDirectory(
        videosRoot,
        surgeryRecordId,
      );

      final paths = await _allocateUnusedPaths(recordDirectory, extension);
      final temporary = paths.temporary;
      final destination = paths.destination;
      var destinationCreated = false;
      try {
        final sourceSizeBefore = await source.length();
        final sourceHashBefore = await sha256OfFile(source);
        await _copyFileExclusively(source, temporary);
        await _postCopyFaultInjector?.call(source, temporary);

        if (await FileSystemEntity.type(temporary.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw const FileSystemException('動画の一時コピーを確認できません。');
        }
        final sourceSizeAfter = await source.length();
        final copiedSize = await temporary.length();
        final sourceHashAfter = await sha256OfFile(source);
        final copiedHash = await sha256OfFile(temporary);
        if (sourceSizeBefore != sourceSizeAfter ||
            copiedSize != sourceSizeBefore ||
            sourceHashBefore != sourceHashAfter ||
            copiedHash != sourceHashBefore) {
          throw const FileSystemException('動画コピーの完全性を確認できませんでした。');
        }

        await _assertSafeNewTarget(videosRoot, recordDirectory, destination);
        if (await FileSystemEntity.type(destination.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const FileSystemException('動画の保存先が競合しました。');
        }
        await temporary.rename(destination.path);
        destinationCreated = true;
        await _assertSafeManagedFile(
          videosRoot: videosRoot,
          recordId: surgeryRecordId,
          file: destination,
        );
        await _backupExclusionRepository.excludeFromBackup(destination.path);
        await _playbackVerifier.verify(destination);
        _importsAwaitingDatabaseCommit.add(
          await destination.resolveSymbolicLinks(),
        );

        return StoredVideo(
          relativePath: p.url.join(
            'videos',
            surgeryRecordId,
            p.basename(destination.path),
          ),
          originalFileName: originalFileName,
          sizeBytes: copiedSize,
          sha256: copiedHash,
        );
      } catch (_) {
        await _deleteKnownStagedFile(temporary);
        if (destinationCreated) {
          await _deleteKnownStagedFile(destination);
        }
        rethrow;
      }
    });
  }

  @override
  Future<void> finishImport(String relativePath) {
    return _storageMutex.synchronized(() async {
      final segments = relativePath.split('/');
      if (segments.length != 3 ||
          classifyVideoPath(
                recordId: segments[1],
                videoPath: relativePath,
              ).kind !=
              VideoPathKind.managed) {
        return;
      }
      final root = await _safeExistingVideosRoot();
      if (root == null) {
        return;
      }
      final file = File(p.join(root.path, segments[1], segments[2]));
      try {
        _importsAwaitingDatabaseCommit.remove(
          await file.resolveSymbolicLinks(),
        );
      } on FileSystemException {
        _importsAwaitingDatabaseCommit.remove(file.path);
      }
    });
  }

  @override
  Future<File?> resolveVideo(String relativePath) {
    return _storageMutex.synchronized(() async {
      final segments = relativePath.split('/');
      if (segments.length != 3) {
        throw const FileSystemException('不正な管理動画参照です。');
      }
      final recordId = segments[1];
      if (classifyVideoPath(recordId: recordId, videoPath: relativePath).kind !=
          VideoPathKind.managed) {
        throw const FileSystemException('不正な管理動画参照です。');
      }
      final videosRoot = await _safeExistingVideosRoot();
      if (videosRoot == null) {
        return null;
      }
      final recordDirectory = Directory(p.join(videosRoot.path, recordId));
      final recordDirectoryType = await FileSystemEntity.type(
        recordDirectory.path,
        followLinks: false,
      );
      if (recordDirectoryType == FileSystemEntityType.notFound) {
        return null;
      }
      await _assertSafeRecordDirectory(videosRoot, recordId, recordDirectory);

      final file = File(p.join(recordDirectory.path, segments[2]));
      final fileType = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      if (fileType == FileSystemEntityType.notFound) {
        return null;
      }
      await _assertSafeManagedFile(
        videosRoot: videosRoot,
        recordId: recordId,
        file: file,
      );
      return file;
    });
  }

  @override
  Future<void> deleteVideo(String relativePath) {
    return _storageMutex.synchronized(() async {
      final segments = relativePath.split('/');
      if (segments.length != 3 ||
          classifyVideoPath(
                recordId: segments[1],
                videoPath: relativePath,
              ).kind !=
              VideoPathKind.managed) {
        throw const FileSystemException('不正な管理動画参照です。');
      }
      final videosRoot = await _safeExistingVideosRoot();
      if (videosRoot == null) {
        return;
      }
      final file = File(p.join(videosRoot.path, segments[1], segments[2]));
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return;
      }
      await _assertSafeManagedFile(
        videosRoot: videosRoot,
        recordId: segments[1],
        file: file,
      );
      await _deleteFile(file);
    });
  }

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) {
    return _storageMutex.synchronized(() async {
      if (!isValidRecordId(surgeryRecordId)) {
        throw ArgumentError.value(surgeryRecordId, 'surgeryRecordId');
      }
      final videosRoot = await _safeExistingVideosRoot();
      if (videosRoot == null) {
        return;
      }
      final directory = Directory(p.join(videosRoot.path, surgeryRecordId));
      final type = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        return;
      }
      await _assertSafeRecordDirectory(videosRoot, surgeryRecordId, directory);
      await _assertTreeContainsNoLinks(directory);
      await directory.delete(recursive: true);
    });
  }

  @override
  Future<VideoStorageMaintenanceReport> maintainManagedStorage(
    Future<RecordVideoReferenceSnapshot> Function() loadReferences,
  ) {
    return _storageMutex.synchronized(() async {
      late RecordVideoReferenceSnapshot firstRead;
      try {
        firstRead = await loadReferences();
      } on Object {
        return const VideoStorageMaintenanceReport(
          snapshotComplete: false,
          deletedPaths: <String>[],
          backupExclusionFailures: <String>[],
        );
      }
      if (!firstRead.isComplete) {
        return const VideoStorageMaintenanceReport(
          snapshotComplete: false,
          deletedPaths: <String>[],
          backupExclusionFailures: <String>[],
        );
      }
      final firstSnapshot = firstRead.references;

      late Directory videosRoot;
      try {
        videosRoot = await _ensureSafeVideosRoot();
      } on Object {
        return const VideoStorageMaintenanceReport(
          snapshotComplete: false,
          deletedPaths: <String>[],
          backupExclusionFailures: <String>[],
        );
      }

      final firstProtection = await _buildProtectionSet(
        firstSnapshot,
        videosRoot,
      );
      if (firstProtection == null) {
        return const VideoStorageMaintenanceReport(
          snapshotComplete: false,
          deletedPaths: <String>[],
          backupExclusionFailures: <String>[],
        );
      }

      final backupFailures = <String>[];
      try {
        await _backupExclusionRepository.excludeFromBackup(videosRoot.path);
      } on Object {
        backupFailures.add(videosRoot.path);
      }
      for (final reference in firstSnapshot) {
        final classification = classifyVideoPath(
          recordId: reference.recordId,
          videoPath: reference.videoPath,
        );
        if (classification.kind != VideoPathKind.managed) {
          continue;
        }
        final relativePath = classification.path!;
        final segments = relativePath.split('/');
        final file = File(
          p.join(videosRoot.path, reference.recordId, segments[2]),
        );
        try {
          await _assertSafeManagedFile(
            videosRoot: videosRoot,
            recordId: reference.recordId,
            file: file,
          );
          await _backupExclusionRepository.excludeFromBackup(file.path);
        } on Object {
          backupFailures.add(relativePath);
        }
      }

      late RecordVideoReferenceSnapshot secondRead;
      try {
        secondRead = await loadReferences();
      } on Object {
        return VideoStorageMaintenanceReport(
          snapshotComplete: false,
          deletedPaths: const <String>[],
          backupExclusionFailures: List<String>.unmodifiable(backupFailures),
        );
      }
      if (!secondRead.isComplete) {
        return VideoStorageMaintenanceReport(
          snapshotComplete: false,
          deletedPaths: const <String>[],
          backupExclusionFailures: List<String>.unmodifiable(backupFailures),
        );
      }
      final secondSnapshot = secondRead.references;
      final secondProtection = await _buildProtectionSet(
        secondSnapshot,
        videosRoot,
      );
      if (secondProtection == null) {
        return VideoStorageMaintenanceReport(
          snapshotComplete: false,
          deletedPaths: const <String>[],
          backupExclusionFailures: List<String>.unmodifiable(backupFailures),
        );
      }

      final protectedTargets = <String>{
        ...firstProtection,
        ...secondProtection,
      };
      final deleted = <String>[];
      final cleanupFailures = <String>[];
      await for (final recordEntity in videosRoot.list(followLinks: false)) {
        if (recordEntity is! Directory ||
            !isValidRecordId(p.basename(recordEntity.path))) {
          continue;
        }
        final recordId = p.basename(recordEntity.path);
        try {
          await _assertSafeRecordDirectory(videosRoot, recordId, recordEntity);
        } on Object {
          continue;
        }
        await for (final entity in recordEntity.list(followLinks: false)) {
          if (entity is! File) {
            continue;
          }
          final type = await FileSystemEntity.type(
            entity.path,
            followLinks: false,
          );
          if (type != FileSystemEntityType.file) {
            continue;
          }
          final canonical = await entity.resolveSymbolicLinks();
          if (protectedTargets.contains(canonical) ||
              _importsAwaitingDatabaseCommit.contains(canonical)) {
            continue;
          }
          final isTemporary = p.basename(entity.path).endsWith('.tmp');
          if (isTemporary) {
            final modified = await entity.lastModified();
            if (_clock().difference(modified) <= const Duration(hours: 24)) {
              continue;
            }
          }
          try {
            await _assertSafeManagedFile(
              videosRoot: videosRoot,
              recordId: recordId,
              file: entity,
              allowTemporary: true,
            );
            await _deleteFile(entity);
            deleted.add(entity.path);
          } on Object {
            // A race or an unexpected filesystem entry is left for diagnosis.
            cleanupFailures.add(entity.path);
          }
        }
      }
      return VideoStorageMaintenanceReport(
        snapshotComplete: true,
        deletedPaths: List<String>.unmodifiable(deleted),
        backupExclusionFailures: List<String>.unmodifiable(backupFailures),
        cleanupFailures: List<String>.unmodifiable(cleanupFailures),
      );
    });
  }

  Future<Set<String>?> _buildProtectionSet(
    List<RecordVideoReference> references,
    Directory videosRoot,
  ) async {
    final protected = <String>{};
    final canonicalRoot = await videosRoot.resolveSymbolicLinks();
    for (final reference in references) {
      final classification = classifyVideoPath(
        recordId: reference.recordId,
        videoPath: reference.videoPath,
      );
      switch (classification.kind) {
        case VideoPathKind.unregistered:
          break;
        case VideoPathKind.invalidReference:
          // The target of an invalid reference cannot be proven. Cleanup must
          // fail closed rather than guessing which managed file it denotes.
          return null;
        case VideoPathKind.managed:
          final segments = classification.path!.split('/');
          final recordDirectory = Directory(
            p.join(videosRoot.path, reference.recordId),
          );
          final recordDirectoryType = await FileSystemEntity.type(
            recordDirectory.path,
            followLinks: false,
          );
          if (recordDirectoryType == FileSystemEntityType.notFound) {
            break;
          }
          if (recordDirectoryType != FileSystemEntityType.directory) {
            return null;
          }
          final file = File(
            p.join(videosRoot.path, reference.recordId, segments[2]),
          );
          final fileType = await FileSystemEntity.type(
            file.path,
            followLinks: false,
          );
          if (fileType == FileSystemEntityType.notFound) {
            break;
          }
          if (fileType != FileSystemEntityType.file) {
            return null;
          }
          try {
            await _assertSafeManagedFile(
              videosRoot: videosRoot,
              recordId: reference.recordId,
              file: file,
            );
            protected.add(await file.resolveSymbolicLinks());
          } on FileSystemException {
            return null;
          }
        case VideoPathKind.legacyExternal:
          final external = File(classification.path!);
          if (!await external.exists()) {
            break;
          }
          try {
            final target = await external.resolveSymbolicLinks();
            if (p.isWithin(canonicalRoot, target)) {
              protected.add(target);
            }
          } on FileSystemException {
            return null;
          }
      }
    }
    return protected;
  }

  Future<({File destination, File temporary})> _allocateUnusedPaths(
    Directory recordDirectory,
    String extension,
  ) async {
    for (var attempt = 0; attempt < 16; attempt++) {
      final baseName = '${_idGenerator()}$extension';
      final destination = File(p.join(recordDirectory.path, baseName));
      final temporary = File(
        p.join(recordDirectory.path, '$baseName.${_idGenerator()}.tmp'),
      );
      final destinationType = await FileSystemEntity.type(
        destination.path,
        followLinks: false,
      );
      final temporaryType = await FileSystemEntity.type(
        temporary.path,
        followLinks: false,
      );
      if (destinationType == FileSystemEntityType.notFound &&
          temporaryType == FileSystemEntityType.notFound) {
        return (destination: destination, temporary: temporary);
      }
    }
    throw const FileSystemException('動画の安全な保存名を作成できませんでした。');
  }

  Future<Directory> _ensureSafeVideosRoot() async {
    final supportDirectory = await _supportDirectory();
    await supportDirectory.create(recursive: true);
    final root = Directory(p.join(supportDirectory.path, 'videos'));
    final existingType = await FileSystemEntity.type(
      root.path,
      followLinks: false,
    );
    if (existingType == FileSystemEntityType.notFound) {
      await root.create();
    } else if (existingType != FileSystemEntityType.directory) {
      throw const FileSystemException('動画保存ルートが安全なディレクトリではありません。');
    }
    final canonicalSupport = await supportDirectory.resolveSymbolicLinks();
    final canonicalRoot = await root.resolveSymbolicLinks();
    if (p.dirname(canonicalRoot) != canonicalSupport ||
        p.basename(canonicalRoot) != 'videos') {
      throw const FileSystemException('動画保存ルートが管理領域外です。');
    }
    return Directory(canonicalRoot);
  }

  Future<Directory?> _safeExistingVideosRoot() async {
    final supportDirectory = await _supportDirectory();
    final root = Directory(p.join(supportDirectory.path, 'videos'));
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return null;
    }
    if (type != FileSystemEntityType.directory) {
      throw const FileSystemException('動画保存ルートが安全ではありません。');
    }
    final canonicalSupport = await supportDirectory.resolveSymbolicLinks();
    final canonicalRoot = await root.resolveSymbolicLinks();
    if (p.dirname(canonicalRoot) != canonicalSupport ||
        p.basename(canonicalRoot) != 'videos') {
      throw const FileSystemException('動画保存ルートが管理領域外です。');
    }
    return Directory(canonicalRoot);
  }

  Future<Directory> _ensureSafeRecordDirectory(
    Directory videosRoot,
    String recordId,
  ) async {
    final directory = Directory(p.join(videosRoot.path, recordId));
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      await directory.create();
    } else if (type != FileSystemEntityType.directory) {
      throw const FileSystemException('症例の動画保存先が安全ではありません。');
    }
    await _assertSafeRecordDirectory(videosRoot, recordId, directory);
    return directory;
  }

  Future<void> _assertSafeRecordDirectory(
    Directory videosRoot,
    String recordId,
    Directory directory,
  ) async {
    if (!isValidRecordId(recordId) ||
        await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const FileSystemException('症例の動画保存先が安全ではありません。');
    }
    final canonicalRoot = await videosRoot.resolveSymbolicLinks();
    final canonicalDirectory = await directory.resolveSymbolicLinks();
    if (p.dirname(canonicalDirectory) != canonicalRoot ||
        p.basename(canonicalDirectory) != recordId) {
      throw const FileSystemException('症例の動画保存先が管理領域外です。');
    }
  }

  Future<void> _assertSafeNewTarget(
    Directory videosRoot,
    Directory recordDirectory,
    File target,
  ) async {
    await _assertSafeRecordDirectory(
      videosRoot,
      p.basename(recordDirectory.path),
      recordDirectory,
    );
    if (p.dirname(target.path) != recordDirectory.path ||
        p.basename(target.path).isEmpty ||
        p.basename(target.path).contains('/') ||
        p.basename(target.path).contains('\\')) {
      throw const FileSystemException('動画の保存先が不正です。');
    }
  }

  Future<void> _assertSafeManagedFile({
    required Directory videosRoot,
    required String recordId,
    required File file,
    bool allowTemporary = false,
  }) async {
    final recordDirectory = Directory(p.join(videosRoot.path, recordId));
    await _assertSafeRecordDirectory(videosRoot, recordId, recordDirectory);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw const FileSystemException('管理動画が通常ファイルではありません。');
    }
    final basename = p.basename(file.path);
    if ((!allowTemporary && basename.endsWith('.tmp')) ||
        p.dirname(file.path) != recordDirectory.path) {
      throw const FileSystemException('管理動画のパスが不正です。');
    }
    final canonicalRoot = await videosRoot.resolveSymbolicLinks();
    final canonicalFile = await file.resolveSymbolicLinks();
    if (!p.isWithin(canonicalRoot, canonicalFile) ||
        p.dirname(canonicalFile) != recordDirectory.path) {
      throw const FileSystemException('管理動画が管理領域外です。');
    }
  }

  Future<void> _assertTreeContainsNoLinks(Directory directory) async {
    await for (final entity in directory.list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const FileSystemException('リンクを含む動画保存先は削除できません。');
      }
      if (entity is Directory) {
        await _assertTreeContainsNoLinks(entity);
      }
    }
  }

  Future<void> _deleteKnownStagedFile(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      await _deleteFile(file);
    }
  }

  Future<void> _copyFileExclusively(File source, File destination) async {
    await destination.create(exclusive: true);
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FileSystemException('動画の一時ファイルを安全に作成できません。');
    }
    final output = await destination.open(mode: FileMode.writeOnly);
    try {
      await for (final chunk in source.openRead()) {
        await output.writeFrom(chunk);
      }
      await output.flush();
    } finally {
      await output.close();
    }
  }

  Future<Directory> _supportDirectory() async {
    return _applicationSupportDirectory ?? getApplicationSupportDirectory();
  }

  static Future<void> _defaultDeleteFile(File file) => file.delete();
}

class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> synchronized<T>(Future<T> Function() action) async {
    if (Zone.current[this] == true) {
      return action();
    }
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    try {
      await previous.catchError((Object _) {});
      return await runZoned(action, zoneValues: <Object?, Object?>{this: true});
    } finally {
      release.complete();
    }
  }
}
