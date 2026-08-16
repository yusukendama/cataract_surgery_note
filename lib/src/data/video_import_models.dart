import 'dart:async';

import 'package:path/path.dart' as p;

const Set<String> registrationCandidateExtensions = <String>{
  'mp4',
  'mov',
  'm4v',
};

const Set<String> guidanceOnlyExtensions = <String>{
  'mpg',
  'mpeg',
  'mts',
  'm2ts',
  'avi',
  'mkv',
  'wmv',
  'webm',
};

const List<String> selectableVideoExtensions = <String>[
  'mp4',
  'mov',
  'm4v',
  'mpg',
  'mpeg',
  'mts',
  'm2ts',
  'avi',
  'mkv',
  'wmv',
  'webm',
];

enum VideoSelectionPolicyKind { registrationCandidate, nonCandidate }

class VideoSelectionPolicy {
  const VideoSelectionPolicy();

  String normalizeExtension(String displayName) {
    final extension = p.extension(displayName).toLowerCase();
    return extension.startsWith('.') ? extension.substring(1) : extension;
  }

  VideoSelectionPolicyKind classify(String displayName) {
    final extension = normalizeExtension(displayName);
    return registrationCandidateExtensions.contains(extension)
        ? VideoSelectionPolicyKind.registrationCandidate
        : VideoSelectionPolicyKind.nonCandidate;
  }
}

enum VideoImportEntryPoint {
  create,
  attach,
  relink,
  attachWithTimingReset,
  replace,
  legacyMigration,
}

/// The user-facing basis on which an attach/relink operation may preserve
/// existing timeline positions.
///
/// When the UI observed no timings, the repository must prove that this is
/// still true inside the commit transaction. A positive declaration is only
/// produced after the explicit same-and-unchanged choice.
enum VideoTimelineIdentityDeclaration {
  noRecordedTimingsObserved,
  sameUnchanged,
}

enum VideoImportPhase {
  selectionPolicy,
  sourceAccess,
  sourceHash,
  sourcePlayback,
  copy,
  destinationProtection,
  destinationPlayback,
  databaseCommit,
  cleanup,
}

enum VideoImportErrorCode {
  userCanceled,
  nonCandidateExtension,
  sourceNotFound,
  sourceAccessDenied,
  providerUnavailable,
  protectedDataUnavailable,
  protectedMedia,
  unplayableMedia,
  playbackVerificationTimedOut,
  sourceChanged,
  insufficientStorage,
  sourceReadFailed,
  destinationWriteFailed,
  copyIntegrityFailed,
  fileProtectionFailed,
  backupExclusionFailed,
  destinationPlaybackFailed,
  durationConflict,
  videoReferenceConflict,
  commitFailed,
  unknown,
}

enum VideoImportRecoveryAction {
  dismiss,
  reselect,
  checkSourceAndReselect,
  retry,
  unlockAndRetry,
  freeStorageAndRetry,
  reloadRecord,
  resetTimingsAndAttach,
  resetTimingsAndReplace,
  contactSupport,
  openReferenceHelp,
}

enum VideoImportPresentation { none, blockingDialog, persistentInline }

enum VideoImportDataInvariantSuffix {
  createNotRegistered,
  existingRecordUnchanged,
  none,
}

enum VideoImportLocalizationKey {
  none,
  nonCandidateExtension,
  sourceUnavailable,
  protectedDataUnavailable,
  protectedMedia,
  unplayableMedia,
  insufficientStorage,
  sourceChanged,
  safeStorageVerification,
  durationConflict,
  videoReferenceConflict,
  commitFailed,
  unknown,
}

enum VideoImportInternalReasonV1 {
  guidanceOnlyExtension,
  pickerContractViolation,
  sourceMissing,
  sourcePermissionDenied,
  providerUnavailable,
  protectedDataUnavailable,
  drmSignaled,
  playerInitFailed,
  playerInvalidDuration,
  playerInvalidDimensions,
  playerNoProgress,
  playerSeekFailed,
  stageTimeout,
  sourceIdentityChanged,
  sourceStatChanged,
  sourceHashMismatch,
  destinationHashMismatch,
  errnoEnospc,
  errnoEdquot,
  sourceReadIo,
  destinationWriteIo,
  renameFailed,
  protectionAttributeMismatch,
  backupAttributeMismatch,
  destinationPlayerFailed,
  durationBelowRecordedTiming,
  referenceCasMismatch,
  dbTransactionFailed,
  userCanceled,
  unexpected,
}

class VideoImportException implements Exception {
  const VideoImportException({
    required this.code,
    required this.phase,
    required this.internalReason,
    required this.primaryRecoveryAction,
    this.entryPoint,
    this.secondaryRecoveryActions = const <VideoImportRecoveryAction>{},
    this.presentation = VideoImportPresentation.blockingDialog,
    this.dataInvariantSuffix = VideoImportDataInvariantSuffix.none,
  }) : assert(
         (code == VideoImportErrorCode.userCanceled &&
                 internalReason == VideoImportInternalReasonV1.userCanceled) ||
             (code == VideoImportErrorCode.nonCandidateExtension &&
                 (internalReason ==
                         VideoImportInternalReasonV1.guidanceOnlyExtension ||
                     internalReason ==
                         VideoImportInternalReasonV1
                             .pickerContractViolation)) ||
             (code == VideoImportErrorCode.sourceNotFound &&
                 internalReason == VideoImportInternalReasonV1.sourceMissing) ||
             (code == VideoImportErrorCode.sourceAccessDenied &&
                 internalReason ==
                     VideoImportInternalReasonV1.sourcePermissionDenied) ||
             (code == VideoImportErrorCode.providerUnavailable &&
                 internalReason ==
                     VideoImportInternalReasonV1.providerUnavailable) ||
             (code == VideoImportErrorCode.protectedDataUnavailable &&
                 internalReason ==
                     VideoImportInternalReasonV1.protectedDataUnavailable) ||
             (code == VideoImportErrorCode.protectedMedia &&
                 internalReason == VideoImportInternalReasonV1.drmSignaled) ||
             (code == VideoImportErrorCode.unplayableMedia &&
                 (internalReason ==
                         VideoImportInternalReasonV1.playerInitFailed ||
                     internalReason ==
                         VideoImportInternalReasonV1.playerInvalidDuration ||
                     internalReason ==
                         VideoImportInternalReasonV1.playerInvalidDimensions ||
                     internalReason ==
                         VideoImportInternalReasonV1.playerNoProgress ||
                     internalReason ==
                         VideoImportInternalReasonV1.playerSeekFailed)) ||
             (code == VideoImportErrorCode.playbackVerificationTimedOut &&
                 internalReason == VideoImportInternalReasonV1.stageTimeout) ||
             (code == VideoImportErrorCode.sourceChanged &&
                 (internalReason ==
                         VideoImportInternalReasonV1.sourceIdentityChanged ||
                     internalReason ==
                         VideoImportInternalReasonV1.sourceStatChanged ||
                     internalReason ==
                         VideoImportInternalReasonV1.sourceHashMismatch)) ||
             (code == VideoImportErrorCode.insufficientStorage &&
                 (internalReason == VideoImportInternalReasonV1.errnoEnospc ||
                     internalReason ==
                         VideoImportInternalReasonV1.errnoEdquot)) ||
             (code == VideoImportErrorCode.sourceReadFailed &&
                 internalReason == VideoImportInternalReasonV1.sourceReadIo) ||
             (code == VideoImportErrorCode.destinationWriteFailed &&
                 (internalReason ==
                         VideoImportInternalReasonV1.destinationWriteIo ||
                     internalReason ==
                         VideoImportInternalReasonV1.renameFailed)) ||
             (code == VideoImportErrorCode.copyIntegrityFailed &&
                 internalReason ==
                     VideoImportInternalReasonV1.destinationHashMismatch) ||
             (code == VideoImportErrorCode.fileProtectionFailed &&
                 internalReason ==
                     VideoImportInternalReasonV1.protectionAttributeMismatch) ||
             (code == VideoImportErrorCode.backupExclusionFailed &&
                 internalReason ==
                     VideoImportInternalReasonV1.backupAttributeMismatch) ||
             (code == VideoImportErrorCode.destinationPlaybackFailed &&
                 internalReason ==
                     VideoImportInternalReasonV1.destinationPlayerFailed) ||
             (code == VideoImportErrorCode.durationConflict &&
                 internalReason ==
                     VideoImportInternalReasonV1.durationBelowRecordedTiming) ||
             (code == VideoImportErrorCode.videoReferenceConflict &&
                 internalReason ==
                     VideoImportInternalReasonV1.referenceCasMismatch) ||
             (code == VideoImportErrorCode.commitFailed &&
                 internalReason ==
                     VideoImportInternalReasonV1.dbTransactionFailed) ||
             (code == VideoImportErrorCode.unknown &&
                 internalReason == VideoImportInternalReasonV1.unexpected),
         'VideoImportInternalReasonV1 must map to exactly one domain code.',
       );

  final VideoImportErrorCode code;
  final VideoImportPhase phase;
  final VideoImportInternalReasonV1 internalReason;
  final VideoImportRecoveryAction primaryRecoveryAction;
  final VideoImportEntryPoint? entryPoint;
  final Set<VideoImportRecoveryAction> secondaryRecoveryActions;
  final VideoImportPresentation presentation;
  final VideoImportDataInvariantSuffix dataInvariantSuffix;

  VideoImportLocalizationKey get localizationKey => switch (code) {
    VideoImportErrorCode.userCanceled => VideoImportLocalizationKey.none,
    VideoImportErrorCode.nonCandidateExtension =>
      VideoImportLocalizationKey.nonCandidateExtension,
    VideoImportErrorCode.sourceNotFound ||
    VideoImportErrorCode.sourceAccessDenied ||
    VideoImportErrorCode.providerUnavailable ||
    VideoImportErrorCode.sourceReadFailed =>
      VideoImportLocalizationKey.sourceUnavailable,
    VideoImportErrorCode.protectedDataUnavailable =>
      VideoImportLocalizationKey.protectedDataUnavailable,
    VideoImportErrorCode.protectedMedia =>
      VideoImportLocalizationKey.protectedMedia,
    VideoImportErrorCode.unplayableMedia ||
    VideoImportErrorCode.playbackVerificationTimedOut =>
      VideoImportLocalizationKey.unplayableMedia,
    VideoImportErrorCode.insufficientStorage =>
      VideoImportLocalizationKey.insufficientStorage,
    VideoImportErrorCode.sourceChanged ||
    VideoImportErrorCode.copyIntegrityFailed =>
      VideoImportLocalizationKey.sourceChanged,
    VideoImportErrorCode.destinationWriteFailed ||
    VideoImportErrorCode.fileProtectionFailed ||
    VideoImportErrorCode.backupExclusionFailed ||
    VideoImportErrorCode.destinationPlaybackFailed =>
      VideoImportLocalizationKey.safeStorageVerification,
    VideoImportErrorCode.durationConflict =>
      VideoImportLocalizationKey.durationConflict,
    VideoImportErrorCode.videoReferenceConflict =>
      VideoImportLocalizationKey.videoReferenceConflict,
    VideoImportErrorCode.commitFailed =>
      VideoImportLocalizationKey.commitFailed,
    VideoImportErrorCode.unknown => VideoImportLocalizationKey.unknown,
  };

  VideoImportException withInvariant(VideoImportDataInvariantSuffix suffix) {
    return VideoImportException(
      code: code,
      phase: phase,
      internalReason: internalReason,
      primaryRecoveryAction: primaryRecoveryAction,
      entryPoint: entryPoint,
      secondaryRecoveryActions: secondaryRecoveryActions,
      presentation: presentation,
      dataInvariantSuffix: suffix,
    );
  }

  VideoImportException withContext({
    required VideoImportEntryPoint entryPoint,
    required VideoImportDataInvariantSuffix dataInvariantSuffix,
  }) {
    return VideoImportException(
      code: code,
      phase: phase,
      internalReason: internalReason,
      primaryRecoveryAction: primaryRecoveryAction,
      entryPoint: entryPoint,
      secondaryRecoveryActions: secondaryRecoveryActions,
      presentation: presentation,
      dataInvariantSuffix: dataInvariantSuffix,
    );
  }

  @override
  String toString() => 'Video import failed.';
}

class VideoPlaybackEvidence {
  const VideoPlaybackEvidence({
    required this.duration,
    required this.width,
    required this.height,
  });

  final Duration duration;
  final double width;
  final double height;

  double get aspectRatio => width / height;
  int get durationMilliseconds => duration.inMilliseconds;
}

class VerifiedVideoCandidate {
  const VerifiedVideoCandidate({
    required this.path,
    required this.displayName,
    required this.normalizedExtension,
    required this.selectionGeneration,
    required this.sourceSize,
    required this.sourceModifiedAt,
    required this.sha256,
    required this.playbackEvidence,
    this.sourceIdentifier,
  });

  final String path;
  final String displayName;
  final String normalizedExtension;
  final int selectionGeneration;
  final int sourceSize;
  final DateTime sourceModifiedAt;
  final String sha256;
  final VideoPlaybackEvidence playbackEvidence;
  final String? sourceIdentifier;

  VerifiedVideoCandidate withFreshEvidence({
    required int sourceSize,
    required DateTime sourceModifiedAt,
    required VideoPlaybackEvidence playbackEvidence,
  }) {
    return VerifiedVideoCandidate(
      path: path,
      displayName: displayName,
      normalizedExtension: normalizedExtension,
      selectionGeneration: selectionGeneration,
      sourceSize: sourceSize,
      sourceModifiedAt: sourceModifiedAt,
      sha256: sha256,
      playbackEvidence: playbackEvidence,
      sourceIdentifier: sourceIdentifier,
    );
  }
}

sealed class VideoSelectionPreflightResult {
  const VideoSelectionPreflightResult();
}

class VideoSelectionReady extends VideoSelectionPreflightResult {
  const VideoSelectionReady(this.candidate);

  final VerifiedVideoCandidate candidate;
}

class VideoSelectionNonCandidate extends VideoSelectionPreflightResult {
  const VideoSelectionNonCandidate({required this.normalizedExtension});

  final String normalizedExtension;
}

class VideoImportProgress {
  const VideoImportProgress({required this.phase, this.fraction});

  final VideoImportPhase phase;
  final double? fraction;
}

typedef VideoImportProgressCallback = void Function(VideoImportProgress value);

class VideoImportCancellationToken {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }

  void throwIfCancelled(VideoImportPhase phase) {
    if (isCancelled) {
      throw VideoImportException(
        code: VideoImportErrorCode.userCanceled,
        phase: phase,
        internalReason: VideoImportInternalReasonV1.userCanceled,
        primaryRecoveryAction: VideoImportRecoveryAction.dismiss,
        presentation: VideoImportPresentation.none,
      );
    }
  }
}

enum VideoMaintenanceOutcome { complete, pending }

/// Secondary cleanup state for a failed logical operation.
///
/// The domain error intentionally contains no maintenance information. This
/// wrapper is only needed when cleanup remains pending; ordinary failures are
/// thrown as [VideoImportException] directly.
class VideoImportFailure implements Exception {
  const VideoImportFailure({
    required this.error,
    required this.maintenanceOutcome,
  }) : assert(maintenanceOutcome == VideoMaintenanceOutcome.pending);

  final VideoImportException error;
  final VideoMaintenanceOutcome maintenanceOutcome;

  @override
  String toString() => 'Video import operation failed.';
}

class VideoImportOutcome<T> {
  const VideoImportOutcome({
    required this.value,
    required this.maintenanceOutcome,
  });

  final T value;
  final VideoMaintenanceOutcome maintenanceOutcome;
}
