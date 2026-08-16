import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'file_sha256.dart';
import 'protected_storage.dart';
import 'surgery_video_picker.dart';
import 'video_import_models.dart';
import 'video_source_access_repository.dart';

abstract interface class VideoImportPreflight {
  Future<VideoSelectionPreflightResult> inspectSelection(
    SelectedSurgeryVideo selection, {
    required int selectionGeneration,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  });

  Future<VerifiedVideoCandidate> revalidateForImport(
    VerifiedVideoCandidate candidate, {
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  });

  /// Reacquires the source, repeats every admission check and keeps that
  /// access lease alive until [operation] has finished reading the source.
  Future<T> withRevalidatedImport<T>(
    VerifiedVideoCandidate candidate, {
    required Future<T> Function(VerifiedVideoCandidate admittedCandidate)
    operation,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  });
}

abstract interface class VideoPlaybackProbe {
  Future<VideoPlaybackEvidence> probe(
    File file, {
    VideoImportCancellationToken? cancellationToken,
  });
}

/// The small part of [VideoPlayerController] needed by the playback probe.
///
/// Keeping the platform controller behind this boundary makes the admission
/// checks deterministic in unit tests without weakening the production path.
abstract interface class VideoPlaybackController {
  bool get isInitialized;
  bool get hasError;
  Duration get duration;
  Duration get position;
  double get width;
  double get height;
  double get aspectRatio;

  Future<void> initialize();
  Future<void> setVolume(double volume);
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration position);
  Future<void> dispose();
}

typedef VideoPlaybackControllerFactory =
    VideoPlaybackController Function(File file);

enum VideoPlaybackProbeFailureReason {
  initialization,
  invalidDuration,
  invalidDimensions,
  noProgress,
  seek,
  protectedMedia,
  timedOut,
}

class VideoPlaybackProbeException implements Exception {
  const VideoPlaybackProbeException(this.reason);

  final VideoPlaybackProbeFailureReason reason;
}

class VideoPlayerPlaybackProbe implements VideoPlaybackProbe {
  const VideoPlayerPlaybackProbe({
    VideoPlaybackControllerFactory? controllerFactory,
    Duration initializationTimeout = defaultInitializationTimeout,
    Duration progressTimeout = defaultProgressTimeout,
    Duration seekTimeout = defaultSeekTimeout,
    Duration totalTimeout = defaultTotalTimeout,
    Duration progressPollInterval = const Duration(milliseconds: 50),
    Duration cleanupTimeout = const Duration(milliseconds: 500),
  }) : _controllerFactory = controllerFactory,
       _initializationTimeout = initializationTimeout,
       _progressTimeout = progressTimeout,
       _seekTimeout = seekTimeout,
       _totalTimeout = totalTimeout,
       _progressPollInterval = progressPollInterval,
       _cleanupTimeout = cleanupTimeout;

  static const Duration defaultInitializationTimeout = Duration(seconds: 10);
  static const Duration defaultProgressTimeout = Duration(seconds: 3);
  static const Duration defaultSeekTimeout = Duration(seconds: 5);
  static const Duration defaultTotalTimeout = Duration(seconds: 20);

  final VideoPlaybackControllerFactory? _controllerFactory;
  final Duration _initializationTimeout;
  final Duration _progressTimeout;
  final Duration _seekTimeout;
  final Duration _totalTimeout;
  final Duration _progressPollInterval;
  final Duration _cleanupTimeout;

  @override
  Future<VideoPlaybackEvidence> probe(
    File file, {
    VideoImportCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled(VideoImportPhase.sourcePlayback);
    final elapsed = Stopwatch()..start();
    late VideoPlaybackController controller;
    try {
      controller = (_controllerFactory ?? _createPlatformController)(file);
    } on PlatformException catch (error) {
      if (_isExplicitProtectedMediaError(error.code)) {
        throw const VideoPlaybackProbeException(
          VideoPlaybackProbeFailureReason.protectedMedia,
        );
      }
      throw const VideoPlaybackProbeException(
        VideoPlaybackProbeFailureReason.initialization,
      );
    } on Object {
      throw const VideoPlaybackProbeException(
        VideoPlaybackProbeFailureReason.initialization,
      );
    }

    final runGuard = _PlaybackProbeRunGuard();
    try {
      return await _probeController(
        controller,
        runGuard: runGuard,
        cancellationToken: cancellationToken,
      ).timeout(
        _totalTimeout,
        onTimeout: () {
          runGuard.abort();
          throw const VideoPlaybackProbeException(
            VideoPlaybackProbeFailureReason.timedOut,
          );
        },
      );
    } finally {
      runGuard.abort();
      await _disposeControllerWithinTotalDeadline(controller, elapsed);
      elapsed.stop();
    }
  }

  Future<VideoPlaybackEvidence> _probeController(
    VideoPlaybackController controller, {
    required _PlaybackProbeRunGuard runGuard,
    VideoImportCancellationToken? cancellationToken,
  }) async {
    try {
      await _awaitControllerStage(
        controller.initialize,
        timeout: _initializationTimeout,
        token: cancellationToken,
        runGuard: runGuard,
        failureReason: VideoPlaybackProbeFailureReason.initialization,
      );
      if (!controller.isInitialized || controller.hasError) {
        throw const VideoPlaybackProbeException(
          VideoPlaybackProbeFailureReason.initialization,
        );
      }
      final duration = controller.duration;
      if (duration <= Duration.zero) {
        throw const VideoPlaybackProbeException(
          VideoPlaybackProbeFailureReason.invalidDuration,
        );
      }
      final width = controller.width;
      final height = controller.height;
      final aspectRatio = controller.aspectRatio;
      if (!width.isFinite ||
          !height.isFinite ||
          width <= 0 ||
          height <= 0 ||
          !aspectRatio.isFinite ||
          aspectRatio <= 0) {
        throw const VideoPlaybackProbeException(
          VideoPlaybackProbeFailureReason.invalidDimensions,
        );
      }

      cancellationToken?.throwIfCancelled(VideoImportPhase.sourcePlayback);
      await _awaitControllerStage(
        () => controller.setVolume(0),
        timeout: _progressTimeout,
        token: cancellationToken,
        runGuard: runGuard,
        failureReason: VideoPlaybackProbeFailureReason.noProgress,
      );
      await _awaitControllerStage(
        controller.play,
        timeout: _progressTimeout,
        token: cancellationToken,
        runGuard: runGuard,
        failureReason: VideoPlaybackProbeFailureReason.noProgress,
      );
      await _waitForProgress(
        controller,
        duration: duration,
        token: cancellationToken,
        runGuard: runGuard,
      );
      await _awaitControllerStage(
        controller.pause,
        timeout: _progressTimeout,
        token: cancellationToken,
        runGuard: runGuard,
        failureReason: VideoPlaybackProbeFailureReason.noProgress,
      );

      if (duration > const Duration(seconds: 2)) {
        final halfway = Duration(microseconds: duration.inMicroseconds ~/ 2);
        final target = halfway < const Duration(seconds: 5)
            ? halfway
            : const Duration(seconds: 5);
        await _awaitControllerStage(
          () => controller.seekTo(target),
          timeout: _seekTimeout,
          token: cancellationToken,
          runGuard: runGuard,
          failureReason: VideoPlaybackProbeFailureReason.seek,
        );
        if (controller.hasError) {
          throw const VideoPlaybackProbeException(
            VideoPlaybackProbeFailureReason.seek,
          );
        }
      }

      return VideoPlaybackEvidence(
        duration: duration,
        width: width,
        height: height,
      );
    } on _PlaybackProbeAborted {
      throw const VideoPlaybackProbeException(
        VideoPlaybackProbeFailureReason.timedOut,
      );
    } on TimeoutException {
      throw const VideoPlaybackProbeException(
        VideoPlaybackProbeFailureReason.timedOut,
      );
    } on PlatformException catch (error) {
      if (_isExplicitProtectedMediaError(error.code)) {
        throw const VideoPlaybackProbeException(
          VideoPlaybackProbeFailureReason.protectedMedia,
        );
      }
      throw const VideoPlaybackProbeException(
        VideoPlaybackProbeFailureReason.initialization,
      );
    }
  }

  Future<void> _disposeControllerWithinTotalDeadline(
    VideoPlaybackController controller,
    Stopwatch elapsed,
  ) async {
    var remaining = _remainingTotalBudget(elapsed);
    final pauseFuture = _startCleanupOperation(controller.pause);
    await _awaitCleanup(pauseFuture, _boundedCleanupBudget(remaining));

    remaining = _remainingTotalBudget(elapsed);
    final disposeFuture = _startCleanupOperation(controller.dispose);
    await _awaitCleanup(disposeFuture, _boundedCleanupBudget(remaining));
  }

  Future<void>? _startCleanupOperation(Future<void> Function() operation) {
    try {
      return operation();
    } on Object {
      return null;
    }
  }

  Future<void> _awaitCleanup(Future<void>? operation, Duration budget) async {
    if (operation == null) {
      return;
    }
    if (budget <= Duration.zero) {
      unawaited(operation.then<void>((_) {}, onError: (_) {}));
      return;
    }
    try {
      await operation.timeout(budget);
    } on Object {
      // Cleanup is best effort, bounded, and never masks the probe result.
    }
  }

  Duration _remainingTotalBudget(Stopwatch elapsed) {
    final remaining = _totalTimeout - elapsed.elapsed;
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  Duration _boundedCleanupBudget(Duration remaining) {
    return remaining < _cleanupTimeout ? remaining : _cleanupTimeout;
  }

  Future<void> _waitForProgress(
    VideoPlaybackController controller, {
    required Duration duration,
    required _PlaybackProbeRunGuard runGuard,
    VideoImportCancellationToken? token,
  }) async {
    final thresholdMicroseconds = math.max(
      1,
      math.min(100000, duration.inMicroseconds ~/ 4),
    );
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < _progressTimeout) {
      runGuard.throwIfAborted();
      token?.throwIfCancelled(VideoImportPhase.sourcePlayback);
      if (controller.hasError) {
        throw const VideoPlaybackProbeException(
          VideoPlaybackProbeFailureReason.noProgress,
        );
      }
      if (controller.position.inMicroseconds >= thresholdMicroseconds) {
        return;
      }
      final remaining = _progressTimeout - elapsed.elapsed;
      final delay = remaining < _progressPollInterval
          ? remaining
          : _progressPollInterval;
      await _awaitPollDelay(delay, token: token, runGuard: runGuard);
    }
    elapsed.stop();
    throw const VideoPlaybackProbeException(
      VideoPlaybackProbeFailureReason.noProgress,
    );
  }

  Future<void> _awaitControllerStage(
    Future<void> Function() startOperation, {
    required Duration timeout,
    required VideoPlaybackProbeFailureReason failureReason,
    required _PlaybackProbeRunGuard runGuard,
    VideoImportCancellationToken? token,
  }) async {
    runGuard.throwIfAborted();
    token?.throwIfCancelled(VideoImportPhase.sourcePlayback);
    try {
      final operation = startOperation();
      final completed = Completer<void>();
      void completeError(Object error, StackTrace stackTrace) {
        if (!completed.isCompleted) {
          completed.completeError(error, stackTrace);
        }
      }

      operation.then<void>((_) {
        if (!completed.isCompleted) {
          completed.complete();
        }
      }, onError: completeError);
      runGuard.whenAborted.then<void>((_) {
        completeError(const _PlaybackProbeAborted(), StackTrace.current);
      });
      token?.whenCancelled.then<void>((_) {
        completeError(_cancellationException(), StackTrace.current);
      });
      final stageTimer = Timer(timeout, () {
        completeError(
          TimeoutException('Playback verification stage timed out.'),
          StackTrace.current,
        );
      });
      try {
        await completed.future;
      } finally {
        stageTimer.cancel();
      }
    } on TimeoutException {
      rethrow;
    } on _PlaybackProbeAborted {
      rethrow;
    } on VideoImportException {
      rethrow;
    } on VideoPlaybackProbeException {
      rethrow;
    } on PlatformException catch (error) {
      if (_isExplicitProtectedMediaError(error.code)) {
        rethrow;
      }
      throw VideoPlaybackProbeException(failureReason);
    } on Object {
      throw VideoPlaybackProbeException(failureReason);
    }
  }

  Future<void> _awaitPollDelay(
    Duration delay, {
    required _PlaybackProbeRunGuard runGuard,
    VideoImportCancellationToken? token,
  }) async {
    final completed = Completer<void>();
    void completeError(Object error, StackTrace stackTrace) {
      if (!completed.isCompleted) {
        completed.completeError(error, stackTrace);
      }
    }

    runGuard.whenAborted.then<void>((_) {
      completeError(const _PlaybackProbeAborted(), StackTrace.current);
    });
    token?.whenCancelled.then<void>((_) {
      completeError(_cancellationException(), StackTrace.current);
    });
    final pollTimer = Timer(delay, () {
      if (!completed.isCompleted) {
        completed.complete();
      }
    });
    try {
      await completed.future;
    } finally {
      pollTimer.cancel();
    }
  }

  VideoImportException _cancellationException() {
    return const VideoImportException(
      code: VideoImportErrorCode.userCanceled,
      phase: VideoImportPhase.sourcePlayback,
      internalReason: VideoImportInternalReasonV1.userCanceled,
      primaryRecoveryAction: VideoImportRecoveryAction.dismiss,
      presentation: VideoImportPresentation.none,
    );
  }

  bool _isExplicitProtectedMediaError(String code) {
    final normalized = code.toLowerCase();
    return normalized.contains('drm') ||
        normalized.contains('protected_content') ||
        normalized.contains('content_protected');
  }

  static VideoPlaybackController _createPlatformController(File file) {
    return _VideoPlayerPlaybackController(VideoPlayerController.file(file));
  }
}

final class _VideoPlayerPlaybackController implements VideoPlaybackController {
  _VideoPlayerPlaybackController(this._controller);

  final VideoPlayerController _controller;

  @override
  bool get isInitialized => _controller.value.isInitialized;

  @override
  bool get hasError => _controller.value.hasError;

  @override
  Duration get duration => _controller.value.duration;

  @override
  Duration get position => _controller.value.position;

  @override
  double get width => _controller.value.size.width;

  @override
  double get height => _controller.value.size.height;

  @override
  double get aspectRatio => _controller.value.aspectRatio;

  @override
  Future<void> initialize() => _controller.initialize();

  @override
  Future<void> setVolume(double volume) => _controller.setVolume(volume);

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> seekTo(Duration position) => _controller.seekTo(position);

  @override
  Future<void> dispose() => _controller.dispose();
}

final class _PlaybackProbeRunGuard {
  final Completer<void> _aborted = Completer<void>();

  Future<void> get whenAborted => _aborted.future;

  void abort() {
    if (!_aborted.isCompleted) {
      _aborted.complete();
    }
  }

  void throwIfAborted() {
    if (_aborted.isCompleted) {
      throw const _PlaybackProbeAborted();
    }
  }
}

final class _PlaybackProbeAborted implements Exception {
  const _PlaybackProbeAborted();
}

class DefaultVideoImportPreflight implements VideoImportPreflight {
  const DefaultVideoImportPreflight({
    VideoSelectionPolicy selectionPolicy = const VideoSelectionPolicy(),
    VideoPlaybackProbe playbackProbe = const VideoPlayerPlaybackProbe(),
    VideoSourceAccessRepository sourceAccessRepository =
        const PlatformVideoSourceAccessRepository(),
    ProtectedDataRepository? protectedDataRepository,
  }) : _selectionPolicy = selectionPolicy,
       _playbackProbe = playbackProbe,
       _sourceAccessRepository = sourceAccessRepository,
       _protectedDataRepository = protectedDataRepository;

  final VideoSelectionPolicy _selectionPolicy;
  final VideoPlaybackProbe _playbackProbe;
  final VideoSourceAccessRepository _sourceAccessRepository;
  final ProtectedDataRepository? _protectedDataRepository;

  @override
  Future<VideoSelectionPreflightResult> inspectSelection(
    SelectedSurgeryVideo selection, {
    required int selectionGeneration,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    cancellationToken?.throwIfCancelled(VideoImportPhase.selectionPolicy);
    onProgress?.call(
      const VideoImportProgress(phase: VideoImportPhase.selectionPolicy),
    );
    final extension = _selectionPolicy.normalizeExtension(
      selection.displayName,
    );
    if (_selectionPolicy.classify(selection.displayName) ==
        VideoSelectionPolicyKind.nonCandidate) {
      return VideoSelectionNonCandidate(normalizedExtension: extension);
    }

    // Guidance-only formats never touch the source URL or protected app data.
    // This keeps the policy decision immediate even while the device is locked
    // or an external File Provider is unavailable.
    await _requireProtectedData(VideoImportPhase.sourceAccess);

    final candidate = await _withSourceLease(
      selection,
      operation: (lease) => _verifySource(
        file: lease.file,
        sourceIdentifier: lease.sourceIdentifier,
        displayName: selection.displayName,
        normalizedExtension: extension,
        selectionGeneration: selectionGeneration,
        expectedCandidate: null,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      ),
    );
    return VideoSelectionReady(candidate);
  }

  @override
  Future<VerifiedVideoCandidate> revalidateForImport(
    VerifiedVideoCandidate candidate, {
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    return withRevalidatedImport(
      candidate,
      operation: (admittedCandidate) async => admittedCandidate,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  @override
  Future<T> withRevalidatedImport<T>(
    VerifiedVideoCandidate candidate, {
    required Future<T> Function(VerifiedVideoCandidate admittedCandidate)
    operation,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    await _requireProtectedData(VideoImportPhase.sourceAccess);
    final selection = SelectedSurgeryVideo(
      path: candidate.path,
      displayName: candidate.displayName,
    );
    return _withSourceLease(
      selection,
      operation: (lease) async {
        final admitted = await _verifySource(
          file: lease.file,
          sourceIdentifier: lease.sourceIdentifier,
          displayName: candidate.displayName,
          normalizedExtension: candidate.normalizedExtension,
          selectionGeneration: candidate.selectionGeneration,
          expectedCandidate: candidate,
          cancellationToken: cancellationToken,
          onProgress: onProgress,
        );
        cancellationToken?.throwIfCancelled(VideoImportPhase.copy);
        return operation(admitted);
      },
    );
  }

  Future<void> _requireProtectedData(VideoImportPhase phase) async {
    final repository = _protectedDataRepository;
    if (repository == null) {
      return;
    }
    try {
      await repository.requireAvailable();
    } on ProtectedDataUnavailableException {
      throw VideoImportException(
        code: VideoImportErrorCode.protectedDataUnavailable,
        phase: phase,
        internalReason: VideoImportInternalReasonV1.protectedDataUnavailable,
        primaryRecoveryAction: VideoImportRecoveryAction.unlockAndRetry,
      );
    } on FileProtectionException {
      throw VideoImportException(
        code: VideoImportErrorCode.fileProtectionFailed,
        phase: phase,
        internalReason: VideoImportInternalReasonV1.protectionAttributeMismatch,
        primaryRecoveryAction: VideoImportRecoveryAction.retry,
      );
    }
  }

  Future<T> _withSourceLease<T>(
    SelectedSurgeryVideo selection, {
    required Future<T> Function(VideoSourceAccessLease lease) operation,
  }) async {
    late VideoSourceAccessLease lease;
    try {
      lease = await _sourceAccessRepository.acquire(selection);
    } on VideoSourceAccessException catch (error) {
      throw switch (error.reason) {
        VideoSourceAccessFailureReason.protectedDataUnavailable =>
          _protectedDataUnavailable(),
        VideoSourceAccessFailureReason.sourceNotFound => _sourceNotFound(),
        VideoSourceAccessFailureReason.accessDenied => _sourceAccessDenied(),
        VideoSourceAccessFailureReason.providerUnavailable =>
          _providerUnavailable(),
      };
    }
    try {
      return await operation(lease);
    } finally {
      await lease.release();
    }
  }

  Future<VerifiedVideoCandidate> _verifySource({
    required File file,
    required String? sourceIdentifier,
    required String displayName,
    required String normalizedExtension,
    required int selectionGeneration,
    required VerifiedVideoCandidate? expectedCandidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    cancellationToken?.throwIfCancelled(VideoImportPhase.sourceAccess);
    onProgress?.call(
      const VideoImportProgress(phase: VideoImportPhase.sourceAccess),
    );
    final currentExtension = _selectionPolicy.normalizeExtension(displayName);
    if (currentExtension != normalizedExtension ||
        !registrationCandidateExtensions.contains(currentExtension)) {
      throw _sourceChanged(VideoImportInternalReasonV1.sourceIdentityChanged);
    }

    late FileStat before;
    try {
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        throw _sourceNotFound();
      }
      if (type != FileSystemEntityType.file) {
        throw _sourceAccessDenied();
      }
      before = await file.stat();
    } on VideoImportException {
      rethrow;
    } on FileSystemException catch (error) {
      throw _mapSourceFileError(error);
    }
    if (before.size <= 0) {
      throw _unplayable(VideoImportInternalReasonV1.playerInvalidDuration);
    }
    if (expectedCandidate != null &&
        (before.size != expectedCandidate.sourceSize ||
            before.modified != expectedCandidate.sourceModifiedAt)) {
      throw _sourceChanged(VideoImportInternalReasonV1.sourceStatChanged);
    }
    if (expectedCandidate?.sourceIdentifier != null &&
        sourceIdentifier != expectedCandidate!.sourceIdentifier) {
      throw _sourceChanged(VideoImportInternalReasonV1.sourceIdentityChanged);
    }

    onProgress?.call(
      const VideoImportProgress(phase: VideoImportPhase.sourceHash),
    );
    late String sourceHash;
    try {
      sourceHash = await sha256OfFile(
        file,
        isCancelled: () => cancellationToken?.isCancelled ?? false,
        cancellationSignal: cancellationToken?.whenCancelled,
        onProgress: (bytesRead, totalBytes) {
          cancellationToken?.throwIfCancelled(VideoImportPhase.sourceHash);
          final fraction = totalBytes <= 0 ? null : bytesRead / totalBytes;
          onProgress?.call(
            VideoImportProgress(
              phase: VideoImportPhase.sourceHash,
              fraction: fraction?.clamp(0, 1).toDouble(),
            ),
          );
        },
      );
    } on VideoImportException {
      rethrow;
    } on FileSystemException catch (error) {
      cancellationToken?.throwIfCancelled(VideoImportPhase.sourceHash);
      throw _mapSourceFileError(error);
    }
    if (expectedCandidate != null && sourceHash != expectedCandidate.sha256) {
      throw _sourceChanged(VideoImportInternalReasonV1.sourceHashMismatch);
    }

    cancellationToken?.throwIfCancelled(VideoImportPhase.sourcePlayback);
    onProgress?.call(
      const VideoImportProgress(phase: VideoImportPhase.sourcePlayback),
    );
    late VideoPlaybackEvidence playbackEvidence;
    try {
      playbackEvidence = await _playbackProbe.probe(
        file,
        cancellationToken: cancellationToken,
      );
    } on VideoImportException {
      rethrow;
    } on VideoPlaybackProbeException catch (error) {
      throw _mapProbeFailure(error.reason);
    } on Object {
      throw _unplayable(VideoImportInternalReasonV1.playerInitFailed);
    }

    try {
      final after = await file.stat();
      if (after.size != before.size || after.modified != before.modified) {
        throw _sourceChanged(VideoImportInternalReasonV1.sourceStatChanged);
      }
    } on VideoImportException {
      rethrow;
    } on FileSystemException catch (error) {
      throw _mapSourceFileError(error);
    }

    return VerifiedVideoCandidate(
      path: file.path,
      displayName: displayName,
      normalizedExtension: normalizedExtension,
      selectionGeneration: selectionGeneration,
      sourceSize: before.size,
      sourceModifiedAt: before.modified,
      sha256: sourceHash,
      playbackEvidence: playbackEvidence,
      sourceIdentifier: sourceIdentifier,
    );
  }

  VideoImportException _mapProbeFailure(
    VideoPlaybackProbeFailureReason reason,
  ) {
    return switch (reason) {
      VideoPlaybackProbeFailureReason.timedOut => VideoImportException(
        code: VideoImportErrorCode.playbackVerificationTimedOut,
        phase: VideoImportPhase.sourcePlayback,
        internalReason: VideoImportInternalReasonV1.stageTimeout,
        primaryRecoveryAction: VideoImportRecoveryAction.retry,
      ),
      VideoPlaybackProbeFailureReason.protectedMedia => VideoImportException(
        code: VideoImportErrorCode.protectedMedia,
        phase: VideoImportPhase.sourcePlayback,
        internalReason: VideoImportInternalReasonV1.drmSignaled,
        primaryRecoveryAction: VideoImportRecoveryAction.checkSourceAndReselect,
      ),
      VideoPlaybackProbeFailureReason.invalidDuration => _unplayable(
        VideoImportInternalReasonV1.playerInvalidDuration,
      ),
      VideoPlaybackProbeFailureReason.invalidDimensions => _unplayable(
        VideoImportInternalReasonV1.playerInvalidDimensions,
      ),
      VideoPlaybackProbeFailureReason.noProgress => _unplayable(
        VideoImportInternalReasonV1.playerNoProgress,
      ),
      VideoPlaybackProbeFailureReason.seek => _unplayable(
        VideoImportInternalReasonV1.playerSeekFailed,
      ),
      VideoPlaybackProbeFailureReason.initialization => _unplayable(
        VideoImportInternalReasonV1.playerInitFailed,
      ),
    };
  }

  VideoImportException _mapSourceFileError(FileSystemException error) {
    final code = error.osError?.errorCode;
    if (code == 2) {
      return _sourceNotFound();
    }
    if (code == 1 || code == 13) {
      return _sourceAccessDenied();
    }
    return const VideoImportException(
      code: VideoImportErrorCode.sourceReadFailed,
      phase: VideoImportPhase.sourceAccess,
      internalReason: VideoImportInternalReasonV1.sourceReadIo,
      primaryRecoveryAction: VideoImportRecoveryAction.checkSourceAndReselect,
    );
  }

  VideoImportException _sourceNotFound() {
    return const VideoImportException(
      code: VideoImportErrorCode.sourceNotFound,
      phase: VideoImportPhase.sourceAccess,
      internalReason: VideoImportInternalReasonV1.sourceMissing,
      primaryRecoveryAction: VideoImportRecoveryAction.checkSourceAndReselect,
    );
  }

  VideoImportException _sourceAccessDenied() {
    return const VideoImportException(
      code: VideoImportErrorCode.sourceAccessDenied,
      phase: VideoImportPhase.sourceAccess,
      internalReason: VideoImportInternalReasonV1.sourcePermissionDenied,
      primaryRecoveryAction: VideoImportRecoveryAction.checkSourceAndReselect,
    );
  }

  VideoImportException _providerUnavailable() {
    return const VideoImportException(
      code: VideoImportErrorCode.providerUnavailable,
      phase: VideoImportPhase.sourceAccess,
      internalReason: VideoImportInternalReasonV1.providerUnavailable,
      primaryRecoveryAction: VideoImportRecoveryAction.checkSourceAndReselect,
    );
  }

  VideoImportException _protectedDataUnavailable() {
    return const VideoImportException(
      code: VideoImportErrorCode.protectedDataUnavailable,
      phase: VideoImportPhase.sourceAccess,
      internalReason: VideoImportInternalReasonV1.protectedDataUnavailable,
      primaryRecoveryAction: VideoImportRecoveryAction.unlockAndRetry,
    );
  }

  VideoImportException _sourceChanged(
    VideoImportInternalReasonV1 internalReason,
  ) {
    return VideoImportException(
      code: VideoImportErrorCode.sourceChanged,
      phase: VideoImportPhase.sourceAccess,
      internalReason: internalReason,
      primaryRecoveryAction: VideoImportRecoveryAction.checkSourceAndReselect,
    );
  }

  VideoImportException _unplayable(VideoImportInternalReasonV1 internalReason) {
    return VideoImportException(
      code: VideoImportErrorCode.unplayableMedia,
      phase: VideoImportPhase.sourcePlayback,
      internalReason: internalReason,
      primaryRecoveryAction: VideoImportRecoveryAction.checkSourceAndReselect,
    );
  }
}
