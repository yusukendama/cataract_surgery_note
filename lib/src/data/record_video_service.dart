import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/surgery_models.dart';
import 'surgery_repository.dart';
import 'video_storage_repository.dart';

class RecordVideoService {
  const RecordVideoService({
    required SurgeryRepository surgeryRepository,
    required VideoStorageRepository videoStorageRepository,
  }) : _surgeryRepository = surgeryRepository,
       _videoStorageRepository = videoStorageRepository;

  final SurgeryRepository _surgeryRepository;
  final VideoStorageRepository _videoStorageRepository;

  Future<SurgeryRecord> importVideoForRecord({
    required String surgeryRecordId,
    required String sourcePath,
    required String originalFileName,
  }) async {
    final record = await _surgeryRepository.getRecord(surgeryRecordId);
    if (record == null) {
      throw StateError('Surgery record not found.');
    }

    final oldVideoPath = record.videoPath;
    final storedVideo = await _videoStorageRepository.importVideo(
      surgeryRecordId: surgeryRecordId,
      sourcePath: sourcePath,
      originalFileName: originalFileName,
    );

    try {
      await _surgeryRepository.updateVideoReference(
        surgeryRecordId: surgeryRecordId,
        videoPath: storedVideo.relativePath,
        videoDisplayName: storedVideo.originalFileName,
      );
    } catch (_) {
      await _videoStorageRepository.deleteVideo(storedVideo.relativePath);
      rethrow;
    }

    if (oldVideoPath != null && isManagedVideoPath(oldVideoPath)) {
      await _deleteWithoutThrowing(oldVideoPath);
    }

    final updated = await _surgeryRepository.getRecord(surgeryRecordId);
    if (updated == null) {
      throw StateError('Surgery record not found after video import.');
    }
    return updated;
  }

  Future<File?> resolveVideoForRecord(SurgeryRecord record) async {
    final videoPath = record.videoPath;
    if (videoPath == null) {
      return null;
    }
    if (isManagedVideoPath(videoPath)) {
      return _videoStorageRepository.resolveVideo(videoPath);
    }

    final legacyExternalFile = File(videoPath);
    if (!p.isAbsolute(videoPath) || !await legacyExternalFile.exists()) {
      return null;
    }

    await importVideoForRecord(
      surgeryRecordId: record.id,
      sourcePath: videoPath,
      originalFileName: record.videoDisplayName ?? p.basename(videoPath),
    );
    final migrated = await _surgeryRepository.getRecord(record.id);
    final migratedPath = migrated?.videoPath;
    if (migratedPath == null) {
      return null;
    }
    return _videoStorageRepository.resolveVideo(migratedPath);
  }

  Future<void> deleteRecordAndManagedVideos(String surgeryRecordId) async {
    try {
      await _videoStorageRepository.deleteVideosForRecord(surgeryRecordId);
    } on Object {
      // Orphaned managed files are preferable to a half-deleted DB state.
    }
    await _surgeryRepository.deleteRecord(surgeryRecordId);
  }

  Future<void> _deleteWithoutThrowing(String relativePath) async {
    try {
      await _videoStorageRepository.deleteVideo(relativePath);
    } on Object {
      // A failed cleanup should not roll back a successful DB update.
    }
  }
}
