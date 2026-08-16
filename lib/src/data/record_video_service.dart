import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/surgery_models.dart';
import 'record_mutation_coordinator.dart';
import 'surgery_repository.dart';
import 'video_storage_repository.dart';

enum RecordVideoStateKind {
  unregistered,
  availableManaged,
  availableLegacy,
  missing,
  invalidReference,
  checkFailed,
}

class RecordVideoState {
  const RecordVideoState(this.kind, {this.file, this.error});

  final RecordVideoStateKind kind;
  final File? file;
  final Object? error;
}

class RecordVideoService {
  RecordVideoService({
    required SurgeryRepository surgeryRepository,
    required VideoStorageRepository videoStorageRepository,
  }) : _surgeryRepository = surgeryRepository,
       _videoStorageRepository = videoStorageRepository;

  final SurgeryRepository _surgeryRepository;
  final VideoStorageRepository _videoStorageRepository;

  VideoStorageMaintenanceReport? _lastMaintenanceReport;

  VideoStorageMaintenanceReport? get lastMaintenanceReport =>
      _lastMaintenanceReport;

  bool get hasPendingCleanup =>
      _lastMaintenanceReport?.hasPendingCleanup ?? false;

  Future<VideoStorageMaintenanceReport?> initialize() =>
      reconcileManagedStorage();

  Future<SurgeryRecord> createRecordWithVideo({
    required DateTime surgeryDate,
    required EyeSide eyeSide,
    required String sourcePath,
    required String originalFileName,
  }) async {
    final recordId = _surgeryRepository.allocateRecordId();
    return _surgeryRepository.runRecordMutation(
      recordId,
      () => _runStorageMutation(() async {
        final storedVideo = await _videoStorageRepository.importVideo(
          surgeryRecordId: recordId,
          sourcePath: sourcePath,
          originalFileName: originalFileName,
        );
        try {
          final record = await _surgeryRepository
              .createRecordWithVideoReference(
                surgeryRecordId: recordId,
                surgeryDate: surgeryDate,
                eyeSide: eyeSide,
                videoPath: storedVideo.relativePath,
                videoDisplayName: storedVideo.originalFileName,
              );
          await _finishImportWithoutThrowing(storedVideo.relativePath);
          await _maintainWithoutThrowing();
          return record;
        } catch (_) {
          await _deleteStagedWithoutThrowing(storedVideo.relativePath);
          await _finishImportWithoutThrowing(storedVideo.relativePath);
          await _maintainWithoutThrowing();
          rethrow;
        }
      }),
    );
  }

  /// Compatibility entry point. New callers must select the semantic action
  /// explicitly with [attachVideoToRecord], [relinkSameVideo], or
  /// [replaceVideoForRecord].
  Future<SurgeryRecord> importVideoForRecord({
    required String surgeryRecordId,
    required String sourcePath,
    required String originalFileName,
  }) async {
    final record = await _surgeryRepository.getRecord(surgeryRecordId);
    if (record == null) {
      throw SurgeryRecordNotFoundException(surgeryRecordId);
    }
    if (record.videoPath == null) {
      return attachVideoToRecord(
        surgeryRecordId: surgeryRecordId,
        sourcePath: sourcePath,
        originalFileName: originalFileName,
      );
    }
    return replaceVideoForRecord(
      surgeryRecordId: surgeryRecordId,
      expectedVideoPath: record.videoPath!,
      sourcePath: sourcePath,
      originalFileName: originalFileName,
    );
  }

  Future<SurgeryRecord> attachVideoToRecord({
    required String surgeryRecordId,
    required String sourcePath,
    required String originalFileName,
  }) {
    return _preservingVideoMutation(
      surgeryRecordId: surgeryRecordId,
      sourcePath: sourcePath,
      originalFileName: originalFileName,
      requireUnregistered: true,
    );
  }

  Future<SurgeryRecord> relinkSameVideo({
    required String surgeryRecordId,
    required String expectedVideoPath,
    required String sourcePath,
    required String originalFileName,
  }) {
    return _preservingVideoMutation(
      surgeryRecordId: surgeryRecordId,
      sourcePath: sourcePath,
      originalFileName: originalFileName,
      requireUnregistered: false,
      expectedExistingPath: expectedVideoPath,
    );
  }

  Future<SurgeryRecord> _preservingVideoMutation({
    required String surgeryRecordId,
    required String sourcePath,
    required String originalFileName,
    required bool requireUnregistered,
    String? expectedExistingPath,
  }) {
    return _surgeryRepository.runRecordMutation(
      surgeryRecordId,
      () => _runStorageMutation(() async {
        final record = await _requireRecord(surgeryRecordId);
        final expectedPath = record.videoPath;
        if (requireUnregistered && expectedPath != null) {
          throw VideoReferenceConflictException(
            expectedPath: null,
            currentPath: expectedPath,
          );
        }
        if (!requireUnregistered && expectedPath == null) {
          throw VideoReferenceConflictException(
            expectedPath: '<existing video>',
            currentPath: null,
          );
        }
        if (!requireUnregistered && expectedPath != expectedExistingPath) {
          throw VideoReferenceConflictException(
            expectedPath: expectedExistingPath,
            currentPath: expectedPath,
          );
        }

        final storedVideo = await _videoStorageRepository.importVideo(
          surgeryRecordId: surgeryRecordId,
          sourcePath: sourcePath,
          originalFileName: originalFileName,
        );
        try {
          await _surgeryRepository.updateVideoReferenceIfCurrent(
            surgeryRecordId: surgeryRecordId,
            expectedVideoPath: expectedPath,
            videoPath: storedVideo.relativePath,
            videoDisplayName: storedVideo.originalFileName,
          );
        } catch (_) {
          await _deleteStagedWithoutThrowing(storedVideo.relativePath);
          await _finishImportWithoutThrowing(storedVideo.relativePath);
          await _maintainWithoutThrowing();
          rethrow;
        }

        await _finishImportWithoutThrowing(storedVideo.relativePath);
        await _maintainWithoutThrowing();
        return _committedRecordFallback(
          before: record,
          videoPath: storedVideo.relativePath,
          videoDisplayName: storedVideo.originalFileName,
        );
      }),
    );
  }

  Future<SurgeryRecord> replaceVideoForRecord({
    required String surgeryRecordId,
    required String expectedVideoPath,
    required String sourcePath,
    required String originalFileName,
  }) {
    return _surgeryRepository.runRecordMutation(
      surgeryRecordId,
      () => _runStorageMutation(() async {
        final record = await _requireRecord(surgeryRecordId);
        final expectedPath = record.videoPath;
        if (expectedPath == null) {
          throw VideoReferenceConflictException(
            expectedPath: '<existing video>',
            currentPath: null,
          );
        }
        if (expectedPath != expectedVideoPath) {
          throw VideoReferenceConflictException(
            expectedPath: expectedVideoPath,
            currentPath: expectedPath,
          );
        }
        final storedVideo = await _videoStorageRepository.importVideo(
          surgeryRecordId: surgeryRecordId,
          sourcePath: sourcePath,
          originalFileName: originalFileName,
        );
        try {
          await _surgeryRepository.replaceVideoReferenceAndClearTimings(
            surgeryRecordId: surgeryRecordId,
            expectedVideoPath: expectedPath,
            videoPath: storedVideo.relativePath,
            videoDisplayName: storedVideo.originalFileName,
          );
        } catch (_) {
          await _deleteStagedWithoutThrowing(storedVideo.relativePath);
          await _finishImportWithoutThrowing(storedVideo.relativePath);
          await _maintainWithoutThrowing();
          rethrow;
        }

        await _finishImportWithoutThrowing(storedVideo.relativePath);
        await _maintainWithoutThrowing();
        return _committedRecordFallback(
          before: record,
          videoPath: storedVideo.relativePath,
          videoDisplayName: storedVideo.originalFileName,
          reviewSchemaVersion: 1,
        );
      }),
    );
  }

  Future<SurgeryRecord> migrateLegacyVideoForRecord(SurgeryRecord record) {
    return _surgeryRepository.runRecordMutation(
      record.id,
      () => _runStorageMutation(() async {
        final current = await _requireRecord(record.id);
        if (current.videoPath != record.videoPath) {
          throw VideoReferenceConflictException(
            expectedPath: record.videoPath,
            currentPath: current.videoPath,
          );
        }
        final classification = classifyVideoPath(
          recordId: current.id,
          videoPath: current.videoPath,
        );
        if (classification.kind != VideoPathKind.legacyExternal) {
          throw const FileSystemException('旧形式の動画参照ではありません。');
        }
        final sourcePath = classification.path!;
        if (await FileSystemEntity.type(sourcePath, followLinks: true) !=
            FileSystemEntityType.file) {
          throw const FileSystemException('旧形式の動画が見つかりません。');
        }
        final storedVideo = await _videoStorageRepository.importVideo(
          surgeryRecordId: current.id,
          sourcePath: sourcePath,
          originalFileName: current.videoDisplayName ?? p.basename(sourcePath),
        );
        try {
          await _surgeryRepository.updateVideoReferenceIfCurrent(
            surgeryRecordId: current.id,
            expectedVideoPath: sourcePath,
            videoPath: storedVideo.relativePath,
            videoDisplayName: storedVideo.originalFileName,
          );
        } catch (_) {
          await _deleteStagedWithoutThrowing(storedVideo.relativePath);
          await _finishImportWithoutThrowing(storedVideo.relativePath);
          await _maintainWithoutThrowing();
          rethrow;
        }
        // The legacy external original is deliberately never deleted.
        await _finishImportWithoutThrowing(storedVideo.relativePath);
        await _maintainWithoutThrowing();
        return _committedRecordFallback(
          before: current,
          videoPath: storedVideo.relativePath,
          videoDisplayName: storedVideo.originalFileName,
        );
      }),
    );
  }

  /// Side-effect-free state inspection used by list/detail supporting data.
  Future<RecordVideoState> inspectVideoState(SurgeryRecord record) async {
    final classification = classifyVideoPath(
      recordId: record.id,
      videoPath: record.videoPath,
    );
    switch (classification.kind) {
      case VideoPathKind.unregistered:
        return const RecordVideoState(RecordVideoStateKind.unregistered);
      case VideoPathKind.invalidReference:
        return const RecordVideoState(RecordVideoStateKind.invalidReference);
      case VideoPathKind.managed:
        try {
          final file = await _videoStorageRepository.resolveVideo(
            classification.path!,
          );
          return file == null
              ? const RecordVideoState(RecordVideoStateKind.missing)
              : RecordVideoState(
                  RecordVideoStateKind.availableManaged,
                  file: file,
                );
        } on Object catch (error) {
          return RecordVideoState(
            RecordVideoStateKind.checkFailed,
            error: error,
          );
        }
      case VideoPathKind.legacyExternal:
        try {
          final file = File(classification.path!);
          final type = await FileSystemEntity.type(
            file.path,
            followLinks: true,
          );
          return type == FileSystemEntityType.file
              ? RecordVideoState(
                  RecordVideoStateKind.availableLegacy,
                  file: file,
                )
              : const RecordVideoState(RecordVideoStateKind.missing);
        } on Object catch (error) {
          return RecordVideoState(
            RecordVideoStateKind.checkFailed,
            error: error,
          );
        }
    }
  }

  Future<File?> resolveVideoForRecord(SurgeryRecord record) async {
    final state = await inspectVideoState(record);
    if (state.kind == RecordVideoStateKind.availableManaged) {
      return state.file;
    }
    if (state.kind != RecordVideoStateKind.availableLegacy) {
      return null;
    }

    // Migration is a best-effort optimization. Failure must never prevent the
    // existing external original from being played.
    try {
      final migrated = await migrateLegacyVideoForRecord(record);
      final migratedPath = migrated.videoPath;
      if (migratedPath != null) {
        final resolved = await _videoStorageRepository.resolveVideo(
          migratedPath,
        );
        if (resolved != null) {
          return resolved;
        }
      }
    } on Object {
      return state.file;
    }
    return state.file;
  }

  Future<SurgeryRecord> removeVideoForRecord(
    String surgeryRecordId, {
    required String expectedVideoPath,
  }) {
    return _surgeryRepository.runRecordMutation(
      surgeryRecordId,
      () => _runStorageMutation(() async {
        final record = await _requireRecord(surgeryRecordId);
        final oldVideoPath = record.videoPath;
        if (oldVideoPath == null) {
          throw VideoReferenceConflictException(
            expectedPath: '<existing video>',
            currentPath: null,
          );
        }
        if (oldVideoPath != expectedVideoPath) {
          throw VideoReferenceConflictException(
            expectedPath: expectedVideoPath,
            currentPath: oldVideoPath,
          );
        }
        await _surgeryRepository.replaceVideoReferenceAndClearTimings(
          surgeryRecordId: surgeryRecordId,
          expectedVideoPath: oldVideoPath,
          videoPath: null,
          videoDisplayName: null,
        );
        await _maintainWithoutThrowing();
        return _committedRecordFallback(
          before: record,
          videoPath: null,
          videoDisplayName: null,
          clearVideo: true,
          reviewSchemaVersion: 1,
        );
      }),
    );
  }

  Future<void> deleteRecordAndManagedVideos(String surgeryRecordId) {
    if (!isValidRecordId(surgeryRecordId)) {
      throw InvalidRecordIdentifierException(surgeryRecordId);
    }
    return _surgeryRepository.runRecordMutation(
      surgeryRecordId,
      () => _runStorageMutation(() async {
        // The database commit and its exact affected-row check happen first.
        await _surgeryRepository.deleteRecordChecked(surgeryRecordId);
        // Reconciliation, rather than recursive deletion, protects a file that
        // another record still references through a legacy absolute/symlink path.
        await _maintainWithoutThrowing();
      }),
    );
  }

  Future<VideoStorageMaintenanceReport?> reconcileManagedStorage() async {
    final storage = _videoStorageRepository;
    if (storage is! ManagedVideoStorageRepository) {
      return null;
    }
    final report = await storage.maintainManagedStorage(() async {
      final rows = await _surgeryRepository.fetchAllVideoReferencesWithIds();
      return RecordVideoReferenceSnapshot.complete(
        rows
            .map(
              (row) => RecordVideoReference(
                recordId: row.recordId,
                videoPath: row.videoPath,
              ),
            )
            .toList(growable: false),
      );
    });
    _lastMaintenanceReport = report;
    return report;
  }

  Future<SurgeryRecord> _requireRecord(String surgeryRecordId) async {
    final record = await _surgeryRepository.getRecord(surgeryRecordId);
    if (record == null) {
      throw SurgeryRecordNotFoundException(surgeryRecordId);
    }
    return record;
  }

  Future<SurgeryRecord> _committedRecordFallback({
    required SurgeryRecord before,
    required String? videoPath,
    required String? videoDisplayName,
    bool clearVideo = false,
    int? reviewSchemaVersion,
  }) async {
    try {
      final updated = await _surgeryRepository.getRecord(before.id);
      if (updated != null) {
        return updated;
      }
    } on Object {
      // The logical commit already succeeded. A refresh problem must not be
      // represented as a failed mutation or trigger destructive compensation.
    }
    return before.copyWith(
      videoPath: videoPath,
      videoDisplayName: videoDisplayName,
      clearVideo: clearVideo,
      reviewSchemaVersion: reviewSchemaVersion,
      updatedAt: DateTime.now(),
    );
  }

  Future<void> _deleteStagedWithoutThrowing(String relativePath) async {
    try {
      await _videoStorageRepository.deleteVideo(relativePath);
    } on Object {
      // The unreferenced staged file is intentionally left for reconciliation.
    }
  }

  Future<void> _finishImportWithoutThrowing(String relativePath) async {
    final storage = _videoStorageRepository;
    if (storage is! ManagedVideoStorageRepository) {
      return;
    }
    try {
      await storage.finishImport(relativePath);
    } on Object {
      // In-flight protection is an additional process-local guard. The DB
      // reference snapshot remains authoritative for later reconciliation.
    }
  }

  Future<T> _runStorageMutation<T>(Future<T> Function() action) {
    final storage = _videoStorageRepository;
    if (storage is ManagedVideoStorageRepository) {
      return storage.runStorageTransaction(action);
    }
    return action();
  }

  Future<void> _maintainWithoutThrowing() async {
    try {
      await reconcileManagedStorage();
    } on Object {
      // A maintenance failure must not alter the already-determined logical
      // result of a mutation. Keep an explicit pending state so the UI can
      // distinguish "committed, cleanup pending" and initialization can retry.
      _lastMaintenanceReport = const VideoStorageMaintenanceReport(
        snapshotComplete: false,
        deletedPaths: <String>[],
        backupExclusionFailures: <String>[],
      );
    }
  }
}
