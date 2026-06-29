import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class StoredVideo {
  const StoredVideo({
    required this.relativePath,
    required this.originalFileName,
    required this.sizeBytes,
  });

  final String relativePath;
  final String originalFileName;
  final int sizeBytes;
}

abstract interface class VideoStorageRepository {
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required String sourcePath,
    required String originalFileName,
  });

  Future<File?> resolveVideo(String relativePath);

  Future<void> deleteVideo(String relativePath);

  Future<void> deleteVideosForRecord(String surgeryRecordId);
}

abstract interface class BackupExclusionRepository {
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
    try {
      await _channel.invokeMethod<void>('excludeFromBackup', {'path': path});
    } on Object {
      // Backup exclusion must not make video import fail.
    }
  }
}

class LocalVideoStorageRepository implements VideoStorageRepository {
  LocalVideoStorageRepository({
    Directory? applicationSupportDirectory,
    Uuid? uuid,
    BackupExclusionRepository? backupExclusionRepository,
  }) : _applicationSupportDirectory = applicationSupportDirectory,
       _uuid = uuid ?? const Uuid(),
       _backupExclusionRepository =
           backupExclusionRepository ??
           const MethodChannelBackupExclusionRepository();

  final Directory? _applicationSupportDirectory;
  final Uuid _uuid;
  final BackupExclusionRepository _backupExclusionRepository;

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required String sourcePath,
    required String originalFileName,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const FileSystemException('Selected video does not exist.');
    }

    final extension = p.extension(originalFileName).toLowerCase();
    if (!const {'.mp4', '.mov', '.m4v'}.contains(extension)) {
      throw ArgumentError('対応している動画形式は mp4 / mov / m4v です。');
    }

    final supportDirectory = await _supportDirectory();
    final videosDirectory = Directory(
      p.join(supportDirectory.path, 'videos', surgeryRecordId),
    );
    await videosDirectory.create(recursive: true);
    await _backupExclusionRepository.excludeFromBackup(
      p.join(supportDirectory.path, 'videos'),
    );

    final fileName = '${_uuid.v4()}$extension';
    final relativePath = p.url.join('videos', surgeryRecordId, fileName);
    final destination = File(p.join(videosDirectory.path, fileName));
    final temporary = File('${destination.path}.tmp');

    try {
      if (await temporary.exists()) {
        await temporary.delete();
      }
      await source.copy(temporary.path);

      final sourceSize = await source.length();
      final copiedExists = await temporary.exists();
      final copiedSize = copiedExists ? await temporary.length() : -1;
      if (!copiedExists || copiedSize != sourceSize) {
        throw const FileSystemException('Copied video size mismatch.');
      }

      if (await destination.exists()) {
        await destination.delete();
      }
      await temporary.rename(destination.path);
      await _backupExclusionRepository.excludeFromBackup(destination.path);

      return StoredVideo(
        relativePath: relativePath,
        originalFileName: originalFileName,
        sizeBytes: sourceSize,
      );
    } catch (_) {
      if (await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }
  }

  @override
  Future<File?> resolveVideo(String relativePath) async {
    if (p.isAbsolute(relativePath) || relativePath.split('/').contains('..')) {
      return null;
    }
    final supportDirectory = await _supportDirectory();
    final file = File(
      p.joinAll([supportDirectory.path, ...p.url.split(relativePath)]),
    );
    if (await file.exists()) {
      return file;
    }
    return null;
  }

  @override
  Future<void> deleteVideo(String relativePath) async {
    final file = await resolveVideo(relativePath);
    if (file != null && await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) async {
    final supportDirectory = await _supportDirectory();
    final directory = Directory(
      p.join(supportDirectory.path, 'videos', surgeryRecordId),
    );
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<Directory> _supportDirectory() async {
    return _applicationSupportDirectory ?? getApplicationSupportDirectory();
  }
}

bool isManagedVideoPath(String path) {
  return !p.isAbsolute(path) &&
      p.url.split(path).length == 3 &&
      p.url.split(path).first == 'videos';
}
