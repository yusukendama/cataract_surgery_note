import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/surgery_models.dart';
import 'protected_storage.dart';
import 'record_mutation_coordinator.dart';
import 'surgery_repository.dart';
import 'surgery_video_picker.dart';
import 'video_import_models.dart';
import 'video_import_preflight.dart';
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

/// The file selected for playback and the exact managed reference produced by
/// a successful legacy migration, when one occurred.
///
/// Callers must compare [normalizedLegacyVideoPath] with a fresh record before
/// treating a reference change as the same-video migration exception. The
/// record may have been replaced again after the migration CAS committed.
class ResolvedRecordVideo {
  const ResolvedRecordVideo({
    required this.file,
    this.normalizedLegacyVideoPath,
  });

  final File? file;
  final String? normalizedLegacyVideoPath;
}

class _LegacyVideoMigrationResult {
  const _LegacyVideoMigrationResult({
    required this.record,
    required this.committedVideoPath,
  });

  final SurgeryRecord record;
  final String committedVideoPath;
}

class RecordVideoService {
  RecordVideoService({
    required SurgeryRepository surgeryRepository,
    required VideoStorageRepository videoStorageRepository,
    required VideoImportPreflight videoImportPreflight,
  }) : _surgeryRepository = surgeryRepository,
       _videoStorageRepository = videoStorageRepository,
       _videoImportPreflight = videoImportPreflight;

  final SurgeryRepository _surgeryRepository;
  final VideoStorageRepository _videoStorageRepository;
  final VideoImportPreflight _videoImportPreflight;

  VideoStorageMaintenanceReport? _lastMaintenanceReport;

  VideoStorageMaintenanceReport? get lastMaintenanceReport =>
      _lastMaintenanceReport;

  bool get hasPendingCleanup =>
      _lastMaintenanceReport?.hasPendingCleanup ?? false;

  Future<VideoStorageMaintenanceReport?> initialize() =>
      reconcileManagedStorage();

  Future<VideoImportOutcome<SurgeryRecord>> createRecordWithVideo({
    required DateTime surgeryDate,
    required EyeSide eyeSide,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    final recordId = _surgeryRepository.allocateRecordId();
    final storedVideo = await _stageCandidate(
      surgeryRecordId: recordId,
      candidate: candidate,
      entryPoint: VideoImportEntryPoint.create,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
    try {
      cancellationToken?.throwIfCancelled(VideoImportPhase.databaseCommit);
      onProgress?.call(
        const VideoImportProgress(phase: VideoImportPhase.databaseCommit),
      );
      final record = await _surgeryRepository.createRecordWithVideoReference(
        surgeryRecordId: recordId,
        surgeryDate: surgeryDate,
        eyeSide: eyeSide,
        videoPath: storedVideo.relativePath,
        videoDisplayName: storedVideo.originalFileName,
        ensureMutationAllowed: cancellationToken == null
            ? null
            : () => cancellationToken.throwIfCancelled(
                VideoImportPhase.databaseCommit,
              ),
      );
      await _finishImportWithoutThrowing(storedVideo.relativePath);
      final maintenance = await _maintainWithoutThrowing();
      return VideoImportOutcome(value: record, maintenanceOutcome: maintenance);
    } on Object catch (error, stackTrace) {
      final maintenance = await _compensateFailedCommit(storedVideo);
      Error.throwWithStackTrace(
        _mapServiceError(
          error,
          entryPoint: VideoImportEntryPoint.create,
          invariant: VideoImportDataInvariantSuffix.createNotRegistered,
          maintenanceOutcome: maintenance,
        ),
        stackTrace,
      );
    }
  }

  Future<VideoImportOutcome<SurgeryRecord>> attachVideoToRecord({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoTimelineIdentityDeclaration timelineIdentityDeclaration =
        VideoTimelineIdentityDeclaration.sameUnchanged,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    return _preservingVideoMutation(
      surgeryRecordId: surgeryRecordId,
      candidate: candidate,
      requireUnregistered: true,
      entryPoint: VideoImportEntryPoint.attach,
      timelineIdentityDeclaration: timelineIdentityDeclaration,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  Future<VideoImportOutcome<SurgeryRecord>> relinkSameVideo({
    required String surgeryRecordId,
    required String expectedVideoPath,
    required VerifiedVideoCandidate candidate,
    VideoTimelineIdentityDeclaration timelineIdentityDeclaration =
        VideoTimelineIdentityDeclaration.sameUnchanged,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    return _preservingVideoMutation(
      surgeryRecordId: surgeryRecordId,
      candidate: candidate,
      requireUnregistered: false,
      expectedExistingPath: expectedVideoPath,
      entryPoint: VideoImportEntryPoint.relink,
      timelineIdentityDeclaration: timelineIdentityDeclaration,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  Future<VideoImportOutcome<SurgeryRecord>> _preservingVideoMutation({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    required bool requireUnregistered,
    required VideoImportEntryPoint entryPoint,
    required VideoTimelineIdentityDeclaration timelineIdentityDeclaration,
    String? expectedExistingPath,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    late SurgeryRecord record;
    try {
      record = await _requireRecord(surgeryRecordId);
    } on SurgeryRecordNotFoundException {
      throw _referenceConflict(entryPoint);
    }
    final expectedPath = record.videoPath;
    if (requireUnregistered && expectedPath != null) {
      throw _referenceConflict(entryPoint);
    }
    if (!requireUnregistered &&
        (expectedPath == null || expectedPath != expectedExistingPath)) {
      throw _referenceConflict(entryPoint);
    }

    final storedVideo = await _stageCandidate(
      surgeryRecordId: surgeryRecordId,
      candidate: candidate,
      entryPoint: entryPoint,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
    try {
      cancellationToken?.throwIfCancelled(VideoImportPhase.databaseCommit);
      onProgress?.call(
        const VideoImportProgress(phase: VideoImportPhase.databaseCommit),
      );
      await _surgeryRepository.updateVideoReferenceIfCurrentAndTimingsFit(
        surgeryRecordId: surgeryRecordId,
        expectedVideoPath: expectedPath,
        videoPath: storedVideo.relativePath,
        videoDisplayName: storedVideo.originalFileName,
        destinationDurationMilliseconds:
            storedVideo.playbackEvidence.durationMilliseconds,
        requireNoRecordedTimings:
            timelineIdentityDeclaration ==
            VideoTimelineIdentityDeclaration.noRecordedTimingsObserved,
        ensureMutationAllowed: cancellationToken == null
            ? null
            : () => cancellationToken.throwIfCancelled(
                VideoImportPhase.databaseCommit,
              ),
      );
      await _finishImportWithoutThrowing(storedVideo.relativePath);
      final maintenance = await _maintainWithoutThrowing();
      final committed = await _committedRecordFallback(
        before: record,
        videoPath: storedVideo.relativePath,
        videoDisplayName: storedVideo.originalFileName,
      );
      return VideoImportOutcome(
        value: committed,
        maintenanceOutcome: maintenance,
      );
    } on Object catch (error, stackTrace) {
      final maintenance = await _compensateFailedCommit(storedVideo);
      Error.throwWithStackTrace(
        _mapServiceError(
          error,
          entryPoint: entryPoint,
          invariant: VideoImportDataInvariantSuffix.existingRecordUnchanged,
          maintenanceOutcome: maintenance,
        ),
        stackTrace,
      );
    }
  }

  Future<VideoImportOutcome<SurgeryRecord>> attachWithTimingReset({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    return _resettingVideoMutation(
      surgeryRecordId: surgeryRecordId,
      expectedVideoPath: null,
      candidate: candidate,
      entryPoint: VideoImportEntryPoint.attachWithTimingReset,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  Future<VideoImportOutcome<SurgeryRecord>> replaceVideoForRecord({
    required String surgeryRecordId,
    required String expectedVideoPath,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    return _resettingVideoMutation(
      surgeryRecordId: surgeryRecordId,
      expectedVideoPath: expectedVideoPath,
      candidate: candidate,
      entryPoint: VideoImportEntryPoint.replace,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  Future<VideoImportOutcome<SurgeryRecord>> _resettingVideoMutation({
    required String surgeryRecordId,
    required String? expectedVideoPath,
    required VerifiedVideoCandidate candidate,
    required VideoImportEntryPoint entryPoint,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    late SurgeryRecord record;
    try {
      record = await _requireRecord(surgeryRecordId);
    } on SurgeryRecordNotFoundException {
      throw _referenceConflict(entryPoint);
    }
    if (record.videoPath != expectedVideoPath) {
      throw _referenceConflict(entryPoint);
    }
    final storedVideo = await _stageCandidate(
      surgeryRecordId: surgeryRecordId,
      candidate: candidate,
      entryPoint: entryPoint,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
    try {
      cancellationToken?.throwIfCancelled(VideoImportPhase.databaseCommit);
      onProgress?.call(
        const VideoImportProgress(phase: VideoImportPhase.databaseCommit),
      );
      await _surgeryRepository.replaceVideoReferenceAndClearTimings(
        surgeryRecordId: surgeryRecordId,
        expectedVideoPath: expectedVideoPath,
        videoPath: storedVideo.relativePath,
        videoDisplayName: storedVideo.originalFileName,
        ensureMutationAllowed: cancellationToken == null
            ? null
            : () => cancellationToken.throwIfCancelled(
                VideoImportPhase.databaseCommit,
              ),
      );
      await _finishImportWithoutThrowing(storedVideo.relativePath);
      final maintenance = await _maintainWithoutThrowing();
      final committed = await _committedRecordFallback(
        before: record,
        videoPath: storedVideo.relativePath,
        videoDisplayName: storedVideo.originalFileName,
        reviewSchemaVersion: 1,
      );
      return VideoImportOutcome(
        value: committed,
        maintenanceOutcome: maintenance,
      );
    } on Object catch (error, stackTrace) {
      final maintenance = await _compensateFailedCommit(storedVideo);
      Error.throwWithStackTrace(
        _mapServiceError(
          error,
          entryPoint: entryPoint,
          invariant: VideoImportDataInvariantSuffix.existingRecordUnchanged,
          maintenanceOutcome: maintenance,
        ),
        stackTrace,
      );
    }
  }

  Future<SurgeryRecord> migrateLegacyVideoForRecord(
    SurgeryRecord record,
  ) async {
    return (await _migrateLegacyVideoForRecord(record)).record;
  }

  Future<_LegacyVideoMigrationResult> _migrateLegacyVideoForRecord(
    SurgeryRecord record,
  ) async {
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
    final selection = SelectedSurgeryVideo(
      path: sourcePath,
      displayName: current.videoDisplayName ?? p.basename(sourcePath),
    );
    final preflightResult = await _videoImportPreflight.inspectSelection(
      selection,
      selectionGeneration: -1,
    );
    if (preflightResult is! VideoSelectionReady) {
      throw const VideoImportException(
        code: VideoImportErrorCode.nonCandidateExtension,
        phase: VideoImportPhase.selectionPolicy,
        internalReason: VideoImportInternalReasonV1.guidanceOnlyExtension,
        primaryRecoveryAction: VideoImportRecoveryAction.reselect,
      );
    }
    final storedVideo = await _stageCandidate(
      surgeryRecordId: current.id,
      candidate: preflightResult.candidate,
      entryPoint: VideoImportEntryPoint.legacyMigration,
    );
    try {
      await _surgeryRepository.updateVideoReferenceIfCurrent(
        surgeryRecordId: current.id,
        expectedVideoPath: sourcePath,
        videoPath: storedVideo.relativePath,
        videoDisplayName: storedVideo.originalFileName,
      );
    } on Object {
      await _compensateFailedCommit(storedVideo);
      rethrow;
    }
    // The legacy external original is deliberately never deleted.
    await _finishImportWithoutThrowing(storedVideo.relativePath);
    await _maintainWithoutThrowing();
    final committedRecord = await _committedRecordFallback(
      before: current,
      videoPath: storedVideo.relativePath,
      videoDisplayName: storedVideo.originalFileName,
    );
    return _LegacyVideoMigrationResult(
      record: committedRecord,
      committedVideoPath: storedVideo.relativePath,
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

  Future<ResolvedRecordVideo> resolveVideoForRecordWithMetadata(
    SurgeryRecord record,
  ) async {
    final state = await inspectVideoState(record);
    if (state.kind == RecordVideoStateKind.availableManaged) {
      return ResolvedRecordVideo(file: state.file);
    }
    if (state.kind != RecordVideoStateKind.availableLegacy) {
      return const ResolvedRecordVideo(file: null);
    }

    // Migration is a best-effort optimization. Failure must never prevent the
    // existing external original from being played.
    try {
      final migration = await _migrateLegacyVideoForRecord(record);
      final migratedPath = migration.committedVideoPath;
      final resolved = await _videoStorageRepository.resolveVideo(migratedPath);
      if (resolved != null) {
        return ResolvedRecordVideo(
          file: resolved,
          normalizedLegacyVideoPath: migratedPath,
        );
      }
    } on Object {
      return ResolvedRecordVideo(file: state.file);
    }
    return ResolvedRecordVideo(file: state.file);
  }

  Future<File?> resolveVideoForRecord(SurgeryRecord record) async {
    final resolution = await resolveVideoForRecordWithMetadata(record);
    final file = resolution.file;
    if (file == null) {
      return null;
    }

    // A legacy migration can commit A -> B and then lose a race to an
    // independent replacement C before resolution completes. The metadata API
    // exposes B so consistency-sensitive callers can make their own decision;
    // this compatibility API has no way to return the reference together with
    // the file, so fail closed unless a fresh DB read still names that file.
    final resolvedVideoPath =
        resolution.normalizedLegacyVideoPath ?? record.videoPath;
    try {
      final latest = await _surgeryRepository.getRecord(record.id);
      if (latest?.videoPath != resolvedVideoPath) {
        return null;
      }
    } on Object {
      // Returning an unverified file could bind playback to a replaced or
      // deleted video. Callers may refresh and resolve the latest record again.
      return null;
    }
    return file;
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

  Future<StoredVideo> _stageCandidate({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    required VideoImportEntryPoint entryPoint,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    try {
      return await _videoImportPreflight.withRevalidatedImport(
        candidate,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
        operation: (admittedCandidate) {
          return _videoStorageRepository.importVideo(
            surgeryRecordId: surgeryRecordId,
            candidate: admittedCandidate,
            cancellationToken: cancellationToken,
            onProgress: onProgress,
          );
        },
      );
    } on Object catch (error, stackTrace) {
      final invariant = entryPoint == VideoImportEntryPoint.create
          ? VideoImportDataInvariantSuffix.createNotRegistered
          : VideoImportDataInvariantSuffix.existingRecordUnchanged;
      Error.throwWithStackTrace(
        _mapServiceError(
          error,
          entryPoint: entryPoint,
          invariant: invariant,
          maintenanceOutcome: error is VideoImportFailure
              ? error.maintenanceOutcome
              : VideoMaintenanceOutcome.complete,
        ),
        stackTrace,
      );
    }
  }

  VideoImportException _referenceConflict(VideoImportEntryPoint entryPoint) {
    return VideoImportException(
      code: VideoImportErrorCode.videoReferenceConflict,
      entryPoint: entryPoint,
      phase: VideoImportPhase.databaseCommit,
      internalReason: VideoImportInternalReasonV1.referenceCasMismatch,
      primaryRecoveryAction: VideoImportRecoveryAction.reloadRecord,
      dataInvariantSuffix:
          VideoImportDataInvariantSuffix.existingRecordUnchanged,
    );
  }

  Object _mapServiceError(
    Object error, {
    required VideoImportEntryPoint entryPoint,
    required VideoImportDataInvariantSuffix invariant,
    required VideoMaintenanceOutcome maintenanceOutcome,
  }) {
    final sourceError = error is VideoImportFailure ? error.error : error;
    final combinedMaintenance =
        error is VideoImportFailure ||
            maintenanceOutcome == VideoMaintenanceOutcome.pending
        ? VideoMaintenanceOutcome.pending
        : VideoMaintenanceOutcome.complete;

    late final VideoImportException mapped;
    if (sourceError is VideoImportException) {
      mapped = sourceError.withContext(
        entryPoint: entryPoint,
        dataInvariantSuffix: invariant,
      );
    } else if (sourceError is VideoDurationConflictException) {
      mapped = VideoImportException(
        code: VideoImportErrorCode.durationConflict,
        entryPoint: entryPoint,
        phase: VideoImportPhase.databaseCommit,
        internalReason: VideoImportInternalReasonV1.durationBelowRecordedTiming,
        primaryRecoveryAction: entryPoint == VideoImportEntryPoint.attach
            ? VideoImportRecoveryAction.resetTimingsAndAttach
            : VideoImportRecoveryAction.resetTimingsAndReplace,
        secondaryRecoveryActions: const <VideoImportRecoveryAction>{
          VideoImportRecoveryAction.reselect,
          VideoImportRecoveryAction.dismiss,
        },
        dataInvariantSuffix: invariant,
      );
    } else if (sourceError is ProtectedDataUnavailableException) {
      mapped = VideoImportException(
        code: VideoImportErrorCode.protectedDataUnavailable,
        entryPoint: entryPoint,
        phase: VideoImportPhase.databaseCommit,
        internalReason: VideoImportInternalReasonV1.protectedDataUnavailable,
        primaryRecoveryAction: VideoImportRecoveryAction.unlockAndRetry,
        dataInvariantSuffix: invariant,
      );
    } else if (sourceError is FileProtectionException) {
      mapped = VideoImportException(
        code: VideoImportErrorCode.fileProtectionFailed,
        entryPoint: entryPoint,
        phase: VideoImportPhase.databaseCommit,
        internalReason: VideoImportInternalReasonV1.protectionAttributeMismatch,
        primaryRecoveryAction: VideoImportRecoveryAction.retry,
        dataInvariantSuffix: invariant,
      );
    } else if (sourceError is VideoReferenceConflictException ||
        sourceError is VideoTimelineIdentityConflictException ||
        sourceError is SurgeryRecordNotFoundException) {
      mapped = _referenceConflict(entryPoint);
    } else {
      mapped = VideoImportException(
        code: VideoImportErrorCode.commitFailed,
        entryPoint: entryPoint,
        phase: VideoImportPhase.databaseCommit,
        internalReason: VideoImportInternalReasonV1.dbTransactionFailed,
        primaryRecoveryAction: VideoImportRecoveryAction.retry,
        dataInvariantSuffix: invariant,
      );
    }
    return combinedMaintenance == VideoMaintenanceOutcome.pending
        ? VideoImportFailure(
            error: mapped,
            maintenanceOutcome: combinedMaintenance,
          )
        : mapped;
  }

  Future<VideoMaintenanceOutcome> _compensateFailedCommit(
    StoredVideo storedVideo,
  ) async {
    final deleted = await _deleteStagedWithoutThrowing(
      storedVideo.relativePath,
    );
    await _finishImportWithoutThrowing(storedVideo.relativePath);
    final maintenance = await _maintainWithoutThrowing();
    return deleted ? maintenance : VideoMaintenanceOutcome.pending;
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

  Future<bool> _deleteStagedWithoutThrowing(String relativePath) async {
    try {
      await _videoStorageRepository.deleteVideo(relativePath);
      return true;
    } on Object {
      // The unreferenced staged file is intentionally left for reconciliation.
      return false;
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

  Future<VideoMaintenanceOutcome> _maintainWithoutThrowing() async {
    try {
      final report = await reconcileManagedStorage();
      if (report == null) {
        return VideoMaintenanceOutcome.complete;
      }
      return report.hasPendingCleanup || !report.backupExclusionVerified
          ? VideoMaintenanceOutcome.pending
          : VideoMaintenanceOutcome.complete;
    } on Object {
      // A maintenance failure must not alter the already-determined logical
      // result of a mutation. Keep an explicit pending state so the UI can
      // distinguish "committed, cleanup pending" and initialization can retry.
      _lastMaintenanceReport = const VideoStorageMaintenanceReport(
        snapshotComplete: false,
        deletedPaths: <String>[],
        backupExclusionFailures: <String>[],
      );
      return VideoMaintenanceOutcome.pending;
    }
  }
}
