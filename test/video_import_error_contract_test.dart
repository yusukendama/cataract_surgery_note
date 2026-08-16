import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every code/internalReason combination follows the closed contract', () {
    final contract = <VideoImportErrorCode, Set<VideoImportInternalReasonV1>>{
      VideoImportErrorCode.userCanceled: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.userCanceled,
      },
      VideoImportErrorCode.nonCandidateExtension: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.guidanceOnlyExtension,
        VideoImportInternalReasonV1.pickerContractViolation,
      },
      VideoImportErrorCode.sourceNotFound: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.sourceMissing,
      },
      VideoImportErrorCode.sourceAccessDenied: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.sourcePermissionDenied,
      },
      VideoImportErrorCode.providerUnavailable: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.providerUnavailable,
      },
      VideoImportErrorCode.protectedDataUnavailable:
          <VideoImportInternalReasonV1>{
            VideoImportInternalReasonV1.protectedDataUnavailable,
          },
      VideoImportErrorCode.protectedMedia: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.drmSignaled,
      },
      VideoImportErrorCode.unplayableMedia: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.playerInitFailed,
        VideoImportInternalReasonV1.playerInvalidDuration,
        VideoImportInternalReasonV1.playerInvalidDimensions,
        VideoImportInternalReasonV1.playerNoProgress,
        VideoImportInternalReasonV1.playerSeekFailed,
      },
      VideoImportErrorCode.playbackVerificationTimedOut:
          <VideoImportInternalReasonV1>{
            VideoImportInternalReasonV1.stageTimeout,
          },
      VideoImportErrorCode.sourceChanged: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.sourceIdentityChanged,
        VideoImportInternalReasonV1.sourceStatChanged,
        VideoImportInternalReasonV1.sourceHashMismatch,
      },
      VideoImportErrorCode.insufficientStorage: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.errnoEnospc,
        VideoImportInternalReasonV1.errnoEdquot,
      },
      VideoImportErrorCode.sourceReadFailed: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.sourceReadIo,
      },
      VideoImportErrorCode.destinationWriteFailed:
          <VideoImportInternalReasonV1>{
            VideoImportInternalReasonV1.destinationWriteIo,
            VideoImportInternalReasonV1.renameFailed,
          },
      VideoImportErrorCode.copyIntegrityFailed: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.destinationHashMismatch,
      },
      VideoImportErrorCode.fileProtectionFailed: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.protectionAttributeMismatch,
      },
      VideoImportErrorCode.backupExclusionFailed: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.backupAttributeMismatch,
      },
      VideoImportErrorCode.destinationPlaybackFailed:
          <VideoImportInternalReasonV1>{
            VideoImportInternalReasonV1.destinationPlayerFailed,
          },
      VideoImportErrorCode.durationConflict: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.durationBelowRecordedTiming,
      },
      VideoImportErrorCode.videoReferenceConflict:
          <VideoImportInternalReasonV1>{
            VideoImportInternalReasonV1.referenceCasMismatch,
          },
      VideoImportErrorCode.commitFailed: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.dbTransactionFailed,
      },
      VideoImportErrorCode.unknown: <VideoImportInternalReasonV1>{
        VideoImportInternalReasonV1.unexpected,
      },
    };

    expect(contract.keys.toSet(), VideoImportErrorCode.values.toSet());

    final owners = <VideoImportInternalReasonV1, Set<VideoImportErrorCode>>{};
    for (final entry in contract.entries) {
      for (final reason in entry.value) {
        owners
            .putIfAbsent(reason, () => <VideoImportErrorCode>{})
            .add(entry.key);
      }
    }
    expect(owners.keys.toSet(), VideoImportInternalReasonV1.values.toSet());
    for (final reason in VideoImportInternalReasonV1.values) {
      expect(
        owners[reason],
        hasLength(1),
        reason: '$reason must belong to exactly one domain code.',
      );
    }

    for (final code in VideoImportErrorCode.values) {
      for (final internalReason in VideoImportInternalReasonV1.values) {
        VideoImportException construct() => VideoImportException(
          code: code,
          phase: VideoImportPhase.sourceAccess,
          internalReason: internalReason,
          primaryRecoveryAction: VideoImportRecoveryAction.dismiss,
        );

        if (contract[code]!.contains(internalReason)) {
          expect(
            construct,
            returnsNormally,
            reason: '$code must accept $internalReason.',
          );
        } else {
          expect(
            construct,
            throwsA(isA<AssertionError>()),
            reason: '$code must reject $internalReason.',
          );
        }
      }
    }
  });

  test('maintenance wrapper accepts pending state only', () {
    const error = VideoImportException(
      code: VideoImportErrorCode.commitFailed,
      phase: VideoImportPhase.databaseCommit,
      internalReason: VideoImportInternalReasonV1.dbTransactionFailed,
      primaryRecoveryAction: VideoImportRecoveryAction.retry,
    );

    expect(
      () => VideoImportFailure(
        error: error,
        maintenanceOutcome: VideoMaintenanceOutcome.pending,
      ),
      returnsNormally,
    );
    expect(
      () => VideoImportFailure(
        error: error,
        maintenanceOutcome: VideoMaintenanceOutcome.complete,
      ),
      throwsA(isA<AssertionError>()),
    );
  });
}
