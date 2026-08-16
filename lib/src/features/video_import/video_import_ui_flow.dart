import 'dart:io';

import '../../data/surgery_video_picker.dart';
import '../../data/video_import_models.dart';
import '../../data/video_import_preflight.dart';

/// Result of one picker and source-preflight generation.
///
/// The flow deliberately returns domain results instead of presenting UI so
/// callers can choose dialogs, inline states, and navigation independently.
sealed class VideoImportUiFlowResult {
  const VideoImportUiFlowResult({required this.selectionGeneration});

  final int selectionGeneration;
}

class VideoImportUiReady extends VideoImportUiFlowResult {
  VideoImportUiReady(this.candidate)
    : super(selectionGeneration: candidate.selectionGeneration);

  final VerifiedVideoCandidate candidate;
}

class VideoImportUiNonCandidate extends VideoImportUiFlowResult {
  const VideoImportUiNonCandidate({
    required super.selectionGeneration,
    required this.normalizedExtension,
  });

  final String normalizedExtension;
}

class VideoImportUiCancelled extends VideoImportUiFlowResult {
  const VideoImportUiCancelled({required super.selectionGeneration});
}

class VideoImportUiFailure extends VideoImportUiFlowResult {
  const VideoImportUiFailure({
    required super.selectionGeneration,
    required this.error,
  });

  final VideoImportException error;
}

/// Returned immediately when another selection generation is already active.
class VideoImportUiBusy extends VideoImportUiFlowResult {
  const VideoImportUiBusy({required super.selectionGeneration});
}

/// Coordinates the Files picker and [VideoImportPreflight.inspectSelection].
///
/// At most one generation is active. Canceling invalidates the generation
/// before signaling the lower-level token, so a late picker or preflight
/// callback cannot become the current candidate.
class VideoImportUiFlow {
  VideoImportUiFlow({
    required SurgeryVideoPicker picker,
    required VideoImportPreflight preflight,
  }) : _picker = picker,
       _preflight = preflight;

  final SurgeryVideoPicker _picker;
  final VideoImportPreflight _preflight;

  int _lastIssuedGeneration = 0;
  _ActiveVideoSelection? _activeSelection;

  bool get isActive => _activeSelection != null;

  int? get activeGeneration => _activeSelection?.generation;

  int get lastIssuedGeneration => _lastIssuedGeneration;

  Future<VideoImportUiFlowResult> selectAndInspect({
    VideoImportProgressCallback? onProgress,
  }) async {
    final existing = _activeSelection;
    if (existing != null) {
      return VideoImportUiBusy(selectionGeneration: existing.generation);
    }

    final active = _ActiveVideoSelection(
      generation: ++_lastIssuedGeneration,
      cancellationToken: VideoImportCancellationToken(),
    );
    _activeSelection = active;

    try {
      late SelectedSurgeryVideo? selection;
      try {
        selection = await _picker.pickVideo();
      } on VideoImportException catch (error) {
        if (!_isCurrent(active) ||
            error.code == VideoImportErrorCode.userCanceled) {
          return VideoImportUiCancelled(selectionGeneration: active.generation);
        }
        return VideoImportUiFailure(
          selectionGeneration: active.generation,
          error: error,
        );
      } on FileSystemException {
        if (!_isCurrent(active)) {
          return VideoImportUiCancelled(selectionGeneration: active.generation);
        }
        return VideoImportUiFailure(
          selectionGeneration: active.generation,
          error: _pickerProviderUnavailable(),
        );
      } on Object {
        if (!_isCurrent(active)) {
          return VideoImportUiCancelled(selectionGeneration: active.generation);
        }
        return VideoImportUiFailure(
          selectionGeneration: active.generation,
          error: _unknownPickerFailure(),
        );
      }

      if (!_isCurrent(active) || selection == null) {
        return VideoImportUiCancelled(selectionGeneration: active.generation);
      }

      late VideoSelectionPreflightResult inspected;
      try {
        inspected = await _preflight.inspectSelection(
          selection,
          selectionGeneration: active.generation,
          cancellationToken: active.cancellationToken,
          onProgress: (progress) {
            if (!_isCurrent(active)) {
              return;
            }
            // Presentation callbacks must not change the preflight result.
            try {
              onProgress?.call(progress);
            } on Object {
              // The flow intentionally does not log media-related state.
            }
          },
        );
      } on VideoImportException catch (error) {
        if (!_isCurrent(active) ||
            error.code == VideoImportErrorCode.userCanceled) {
          return VideoImportUiCancelled(selectionGeneration: active.generation);
        }
        return VideoImportUiFailure(
          selectionGeneration: active.generation,
          error: error,
        );
      } on Object {
        if (!_isCurrent(active)) {
          return VideoImportUiCancelled(selectionGeneration: active.generation);
        }
        return VideoImportUiFailure(
          selectionGeneration: active.generation,
          error: _unknownPreflightFailure(),
        );
      }

      if (!_isCurrent(active)) {
        return VideoImportUiCancelled(selectionGeneration: active.generation);
      }

      return switch (inspected) {
        VideoSelectionReady(:final candidate) => VideoImportUiReady(candidate),
        VideoSelectionNonCandidate(:final normalizedExtension) =>
          VideoImportUiNonCandidate(
            selectionGeneration: active.generation,
            normalizedExtension: normalizedExtension,
          ),
      };
    } finally {
      if (identical(_activeSelection, active)) {
        _activeSelection = null;
      }
    }
  }

  /// Invalidates and cancels the active generation.
  ///
  /// Returns false when there is no active operation. A new generation may be
  /// started immediately; late completion from the canceled generation is
  /// converted to [VideoImportUiCancelled].
  bool cancelActive() {
    final active = _activeSelection;
    if (active == null) {
      return false;
    }
    _activeSelection = null;
    active.cancellationToken.cancel();
    return true;
  }

  void dispose() {
    cancelActive();
  }

  bool _isCurrent(_ActiveVideoSelection active) {
    return identical(_activeSelection, active) &&
        !active.cancellationToken.isCancelled;
  }

  VideoImportException _pickerProviderUnavailable() {
    return const VideoImportException(
      code: VideoImportErrorCode.providerUnavailable,
      phase: VideoImportPhase.sourceAccess,
      internalReason: VideoImportInternalReasonV1.providerUnavailable,
      primaryRecoveryAction: VideoImportRecoveryAction.checkSourceAndReselect,
    );
  }

  VideoImportException _unknownPickerFailure() {
    return const VideoImportException(
      code: VideoImportErrorCode.unknown,
      phase: VideoImportPhase.selectionPolicy,
      internalReason: VideoImportInternalReasonV1.unexpected,
      primaryRecoveryAction: VideoImportRecoveryAction.retry,
    );
  }

  VideoImportException _unknownPreflightFailure() {
    return const VideoImportException(
      code: VideoImportErrorCode.unknown,
      phase: VideoImportPhase.sourcePlayback,
      internalReason: VideoImportInternalReasonV1.unexpected,
      primaryRecoveryAction: VideoImportRecoveryAction.retry,
    );
  }
}

class _ActiveVideoSelection {
  const _ActiveVideoSelection({
    required this.generation,
    required this.cancellationToken,
  });

  final int generation;
  final VideoImportCancellationToken cancellationToken;
}
