import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../data/providers.dart';
import '../../data/record_mutation_coordinator.dart';
import '../../data/record_video_service.dart';
import '../../data/video_import_models.dart';
import '../../domain/duration_formatters.dart';
import '../../domain/procedure_arrival_time.dart';
import '../../domain/surgery_models.dart';
import '../../domain/video_seek_coordinator.dart';
import '../../widgets/app_confirm_dialog.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/procedure_arrival_time_view.dart';
import '../../widgets/video_surface.dart';
import '../video_import/video_import_screen_flow.dart';
import '../video_import/video_import_ui_flow.dart';
import '../video_import/video_timeline_identity_dialog.dart';

class _ReviewVideoResolution {
  const _ReviewVideoResolution({
    required this.record,
    required this.file,
    required this.videoState,
    required this.sourceVideoPath,
    required this.normalizedLegacyVideoPath,
  });

  final SurgeryRecord? record;
  final File? file;
  final RecordVideoState? videoState;
  final String? sourceVideoPath;
  final String? normalizedLegacyVideoPath;
}

final _reviewVideoResolutionProvider = FutureProvider.autoDispose
    .family<_ReviewVideoResolution, String>((ref, recordId) async {
      final repository = ref.watch(surgeryRepositoryProvider);
      final record = await repository.getRecord(recordId);
      if (record == null) {
        return const _ReviewVideoResolution(
          record: null,
          file: null,
          videoState: null,
          sourceVideoPath: null,
          normalizedLegacyVideoPath: null,
        );
      }
      final service = ref.watch(recordVideoServiceProvider);
      var videoState = await service.inspectVideoState(record);
      var file = videoState.file;
      String? normalizedLegacyVideoPath;
      if (videoState.kind == RecordVideoStateKind.availableLegacy) {
        final resolved = await service.resolveVideoForRecordWithMetadata(
          record,
        );
        file = resolved.file;
        normalizedLegacyVideoPath = resolved.normalizedLegacyVideoPath;
      }
      // Always re-read after asynchronous inspection/resolution. This keeps a
      // non-legacy replacement just as safe as a legacy migration race.
      final committedRecord = await repository.getRecord(recordId);
      if (committedRecord != null &&
          committedRecord.videoPath != record.videoPath) {
        videoState = await service.inspectVideoState(committedRecord);
        // A file resolved for the old reference must never be rebound to a
        // concurrently committed, different video reference.
        file = videoState.file;
      }
      return _ReviewVideoResolution(
        record: committedRecord,
        file: file,
        videoState: videoState,
        sourceVideoPath: record.videoPath,
        normalizedLegacyVideoPath: normalizedLegacyVideoPath,
      );
    }, retry: (retryCount, error) => null);

enum _LeaveAction { cancel, discard, save }

enum _VideoSelectionAction { attach, relink, replace }

enum _DirectJumpStatus { pending, consumed, abandoned, retryable }

class _DirectJumpSnapshot {
  const _DirectJumpSnapshot({
    required this.recordId,
    required this.step,
    required this.startMilliseconds,
    required this.videoPath,
    this.didNormalizeLegacyReference = false,
  });

  final String recordId;
  final SurgicalStep step;
  final int startMilliseconds;
  final String videoPath;
  final bool didNormalizeLegacyReference;

  _DirectJumpSnapshot withNormalizedVideoPath(String value) {
    return _DirectJumpSnapshot(
      recordId: recordId,
      step: step,
      startMilliseconds: startMilliseconds,
      videoPath: value,
      didNormalizeLegacyReference: true,
    );
  }
}

class _DirectSeekCompletion {
  const _DirectSeekCompletion.success() : error = null;

  const _DirectSeekCompletion.failure(this.error);

  final Object? error;
}

typedef SuccessHapticFeedback = Future<void> Function();

const _minimumReviewContentHeight = 96.0;
const _minimumFallbackReviewContentHeight = 48.0;
const _minimumPinnedPlayerHeight = 240.0;
const _maximumVideoHeight = 280.0;

class StepReviewScreen extends ConsumerStatefulWidget {
  const StepReviewScreen({
    required this.recordId,
    this.initialStepStorageId,
    this.successHapticFeedback,
    super.key,
  });

  final String recordId;
  final String? initialStepStorageId;

  /// Kept injectable so timing feedback can be verified without platform
  /// channels in widget tests.
  final SuccessHapticFeedback? successHapticFeedback;

  @override
  ConsumerState<StepReviewScreen> createState() => _StepReviewScreenState();
}

class _StepReviewScreenState extends ConsumerState<StepReviewScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _caseMemoController = TextEditingController();
  final Map<SurgicalStep, TextEditingController> _reflectionControllers = {};
  final Map<SurgicalStep, StepRating> _ratings = {};

  late final TabController _tabController;
  late final VideoImportUiFlow _videoImportFlow;
  final VideoImportOperationController _videoImportOperationController =
      VideoImportOperationController();
  VideoPlayerController? _videoController;
  VideoSeekCoordinator? _videoSeekCoordinator;
  String? _loadedVideoPath;
  String? _videoBoundReference;
  String? _videoErrorMessage;
  VideoImportException? _lastVideoImportError;
  _VideoSelectionAction? _lastVideoSelectionAction;
  Object? _videoProviderError;
  File? _resolvedVideoFile;
  RecordVideoState? _resolvedVideoState;
  bool _videoProviderLoading = true;
  int _videoControllerGeneration = 0;
  double _playbackSpeed = 1;
  SurgicalStep? _savingStep;
  bool _isSavingReview = false;
  bool _isSavingVideo = false;
  bool _isDirty = false;
  bool _draftInitialized = false;
  bool _isApplyingProviderState = false;
  bool _recordWasDeleted = false;
  bool _recordProviderResolved = false;
  int _videoResolutionApplicationGeneration = 0;
  final Set<String?> _directJumpObservedVideoPaths = <String?>{};
  bool _leaveDialogIsOpen = false;

  String _savedCaseMemo = '';
  final Map<SurgicalStep, String> _savedReflections = {};
  final Map<SurgicalStep, StepRating> _savedRatings = {};

  SurgeryRecord? _latestRecord;
  List<SurgicalStepReview>? _latestReviews;
  Object? _recordRefreshError;
  Object? _reviewsRefreshError;
  bool _recordRefreshPendingAfterCommit = false;
  bool _reviewsRefreshPendingAfterCommit = false;

  late final SurgicalStep? _directJumpStep;
  _DirectJumpStatus? _directJumpStatus;
  _DirectJumpSnapshot? _directJumpSnapshot;
  SurgicalStepReview? _directFreshTargetReview;
  String? _directJumpMessage;
  String? _directSeekFailureMessage;
  bool _directFreshReadComplete = false;
  bool _directInitialReviewMerged = false;
  bool _dataListenersStarted = false;
  bool _videoResolutionListenerStarted = false;
  bool _initialSeekValidationInFlight = false;
  bool _initialSeekRequestInFlight = false;
  bool _directRetryValidationInFlight = false;
  bool _suppressDirectSeekCompletion = false;
  bool _directJumpSuccessAnnounced = false;
  bool _directVideoResolutionDecisionPending = false;
  bool _hasConsumedVideoReference = false;
  String? _consumedVideoReference;
  bool _manualVideoRecoveryRequired = false;
  bool _resumeNormalLoadWhenRouteCurrent = false;
  bool _refreshDiscardedDataWhenRouteCurrent = false;
  bool _normalLoadResumeScheduled = false;
  bool _inactiveDirectDiscardScheduled = false;
  int _directJumpGeneration = 0;

  bool get _hasPendingWrite =>
      _savingStep != null || _isSavingReview || _isSavingVideo;

  bool get _hasDirectJumpIntent => _directJumpStep != null;

  bool get _isDirectJumpPreparing =>
      _directJumpStatus == _DirectJumpStatus.pending ||
      _initialSeekRequestInFlight;

  bool get _hasUsableVideoPosition {
    final controller = _videoController;
    return controller != null &&
        controller.value.isInitialized &&
        !controller.value.hasError &&
        _videoErrorMessage == null &&
        !_videoProviderLoading &&
        _videoProviderError == null &&
        !_isDirectJumpPreparing &&
        _videoBoundReference == _latestRecord?.videoPath;
  }

  bool get _hasInitializedVideoPlayer {
    final controller = _videoController;
    final aspectRatio = controller?.value.aspectRatio;
    return controller != null &&
        controller.value.isInitialized &&
        !controller.value.hasError &&
        aspectRatio != null &&
        aspectRatio.isFinite &&
        aspectRatio > 0 &&
        _videoErrorMessage == null &&
        _resolvedVideoFile != null;
  }

  int get _currentMilliseconds =>
      _videoSeekCoordinator?.effectivePosition.inMilliseconds ??
      _videoController?.value.position.inMilliseconds ??
      0;

  @override
  void initState() {
    super.initState();
    final requestedStep = widget.initialStepStorageId == null
        ? null
        : SurgicalStep.fromStorageId(widget.initialStepStorageId!);
    _directJumpStep = activeIndividualSurgicalSteps.contains(requestedStep)
        ? requestedStep
        : null;
    final directJumpStep = _directJumpStep;
    final directJumpIndex = directJumpStep == null
        ? 0
        : surgicalStepsInDisplayOrder.indexOf(directJumpStep);
    _tabController = TabController(
      length: surgicalStepsInDisplayOrder.length + 1,
      vsync: this,
      initialIndex: directJumpIndex,
    );
    _videoImportFlow = VideoImportUiFlow(
      picker: ref.read(surgeryVideoPickerProvider),
      preflight: ref.read(videoImportPreflightProvider),
    );
    if (_hasDirectJumpIntent) {
      _directJumpStatus = _DirectJumpStatus.pending;
      unawaited(_prepareDirectJump());
    } else {
      _startDataListeners();
      _startVideoResolutionListener();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routeIsCurrent = ModalRoute.isCurrentOf(context) == true;
    final status = _directJumpStatus;
    final hasActiveConsumedOperation =
        status == _DirectJumpStatus.consumed &&
        (_initialSeekValidationInFlight ||
            _initialSeekRequestInFlight ||
            _videoProviderLoading);
    if (!routeIsCurrent &&
        !_inactiveDirectDiscardScheduled &&
        (status == _DirectJumpStatus.pending ||
            (status == _DirectJumpStatus.retryable &&
                _directRetryValidationInFlight) ||
            hasActiveConsumedOperation)) {
      _inactiveDirectDiscardScheduled = true;
      final observedGeneration = _directJumpGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _inactiveDirectDiscardScheduled = false;
        if (!mounted || observedGeneration != _directJumpGeneration) {
          return;
        }
        final currentStatus = _directJumpStatus;
        if (currentStatus == _DirectJumpStatus.pending ||
            (currentStatus == _DirectJumpStatus.retryable &&
                _directRetryValidationInFlight) ||
            (currentStatus == _DirectJumpStatus.consumed &&
                (_initialSeekValidationInFlight ||
                    _initialSeekRequestInFlight ||
                    _videoProviderLoading))) {
          _discardDirectJumpForInactiveRoute(currentStatus!);
        }
      });
    }
    if (routeIsCurrent) {
      final controller = _videoController;
      if (controller != null &&
          controller.value.hasError &&
          _videoErrorMessage == null) {
        _onVideoControllerValueChanged(controller, _videoControllerGeneration);
      }
    }
    _scheduleNormalLoadResumeIfCurrent(routeIsCurrent: routeIsCurrent);
  }

  void _scheduleNormalLoadResumeIfCurrent({bool? routeIsCurrent}) {
    if ((!_resumeNormalLoadWhenRouteCurrent &&
            !_refreshDiscardedDataWhenRouteCurrent) ||
        !(routeIsCurrent ?? ModalRoute.isCurrentOf(context) == true) ||
        _normalLoadResumeScheduled) {
      return;
    }
    _normalLoadResumeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _normalLoadResumeScheduled = false;
      if (!mounted ||
          (!_resumeNormalLoadWhenRouteCurrent &&
              !_refreshDiscardedDataWhenRouteCurrent) ||
          ModalRoute.isCurrentOf(context) != true) {
        return;
      }
      final shouldResumeNormalLoad = _resumeNormalLoadWhenRouteCurrent;
      final shouldRefreshDiscardedData = _refreshDiscardedDataWhenRouteCurrent;
      _resumeNormalLoadWhenRouteCurrent = false;
      _refreshDiscardedDataWhenRouteCurrent = false;
      if (shouldResumeNormalLoad) {
        _startDataListeners();
        _startVideoResolutionListener();
      }
      if (shouldRefreshDiscardedData) {
        ref.invalidate(surgeryRecordProvider(widget.recordId));
        ref.invalidate(stepReviewsProvider(widget.recordId));
      }
    });
  }

  void _startDataListeners() {
    if (_dataListenersStarted) {
      return;
    }
    _dataListenersStarted = true;
    ref.listenManual(
      surgeryRecordProvider(widget.recordId),
      _onRecordProviderChanged,
      fireImmediately: true,
    );
    ref.listenManual(
      stepReviewsProvider(widget.recordId),
      _onReviewsProviderChanged,
      fireImmediately: true,
    );
  }

  void _startVideoResolutionListener() {
    if (_videoResolutionListenerStarted) {
      return;
    }
    _videoResolutionListenerStarted = true;
    ref.listenManual(
      _reviewVideoResolutionProvider(widget.recordId),
      _onVideoResolutionChanged,
      fireImmediately: true,
    );
  }

  Future<void> _prepareDirectJump() async {
    final step = _directJumpStep;
    if (step == null) {
      return;
    }
    final generation = ++_directJumpGeneration;
    try {
      final repository = ref.read(surgeryRepositoryProvider);
      final initialRecord = await repository.getRecord(widget.recordId);
      if (!_isCurrentDirectJump(generation)) {
        return;
      }
      final review = initialRecord == null
          ? null
          : await repository.getStepReview(
              surgeryRecordId: widget.recordId,
              step: step,
            );
      if (!_isCurrentDirectJump(generation)) {
        return;
      }
      final record = initialRecord == null
          ? null
          : await repository.getRecord(widget.recordId);
      if (!_isCurrentDirectJump(generation)) {
        return;
      }

      setState(() {
        _directFreshReadComplete = true;
        _recordProviderResolved = true;
        _latestRecord = record;
        _directFreshTargetReview = review;
        final startMilliseconds = review?.startMilliseconds;
        final videoPath = record?.videoPath;
        if (record == null) {
          _directJumpStatus = _DirectJumpStatus.abandoned;
          _directJumpMessage = '症例が削除されたため工程動画を開けませんでした。';
        } else if (review == null || startMilliseconds == null) {
          _directJumpStatus = _DirectJumpStatus.abandoned;
          _directJumpMessage = '工程の記録位置が削除されたため自動で移動できませんでした。';
        } else if (startMilliseconds < 0) {
          _directJumpStatus = _DirectJumpStatus.abandoned;
          _directJumpMessage = '記録位置が動画の範囲外のため自動で移動できませんでした。';
        } else if (videoPath == null) {
          _directJumpStatus = _DirectJumpStatus.abandoned;
          _directJumpMessage = '動画を利用できないため工程位置へ移動できませんでした。';
        } else {
          _directJumpSnapshot = _DirectJumpSnapshot(
            recordId: widget.recordId,
            step: step,
            startMilliseconds: startMilliseconds,
            videoPath: videoPath,
          );
          _directJumpObservedVideoPaths
            ..clear()
            ..add(videoPath);
          _directVideoResolutionDecisionPending = true;
        }
      });
    } catch (_) {
      if (!_isCurrentDirectJump(generation)) {
        return;
      }
      setState(() {
        _directFreshReadComplete = true;
        _directVideoResolutionDecisionPending = false;
        _directJumpStatus = _DirectJumpStatus.abandoned;
        _directJumpMessage = '工程の記録位置を確認できませんでした。もう一度お試しください。';
      });
    }
    if (!_isCurrentDirectJump(generation, requirePending: false)) {
      return;
    }
    ref.invalidate(surgeryRecordProvider(widget.recordId));
    ref.invalidate(stepReviewsProvider(widget.recordId));
    _startDataListeners();
    if (_directJumpSnapshot != null &&
        _directJumpStatus == _DirectJumpStatus.pending) {
      _startVideoResolutionListener();
    } else {
      setState(() {
        _videoProviderLoading = false;
        if (_latestRecord?.videoPath == null) {
          _resolvedVideoState = const RecordVideoState(
            RecordVideoStateKind.unregistered,
          );
        }
      });
    }
  }

  bool _isCurrentDirectJump(int generation, {bool requirePending = true}) {
    final matches =
        mounted &&
        generation == _directJumpGeneration &&
        (!requirePending || _directJumpStatus == _DirectJumpStatus.pending);
    if (!matches) {
      return false;
    }
    if (ModalRoute.of(context)?.isCurrent == true) {
      return true;
    }
    final status = _directJumpStatus;
    if (status == _DirectJumpStatus.pending ||
        status == _DirectJumpStatus.consumed ||
        status == _DirectJumpStatus.retryable) {
      _discardDirectJumpForInactiveRoute(status!);
    }
    return false;
  }

  void _abandonDirectJump(
    String message, {
    bool requiresManualVideoRecovery = false,
  }) {
    if (_directJumpStatus != _DirectJumpStatus.pending &&
        _directJumpStatus != _DirectJumpStatus.retryable) {
      return;
    }
    _directJumpStatus = _DirectJumpStatus.abandoned;
    _directVideoResolutionDecisionPending = false;
    _directJumpMessage = message;
    if (requiresManualVideoRecovery) {
      _manualVideoRecoveryRequired = true;
    }
    _directJumpGeneration++;
    _initialSeekValidationInFlight = false;
    _initialSeekRequestInFlight = false;
  }

  void _markConsumedDirectJumpChanged(String message) {
    if (_directJumpStatus != _DirectJumpStatus.consumed) {
      return;
    }
    _directJumpMessage = message;
    _suppressDirectSeekCompletion = true;
  }

  void _markDirectJumpRetryable({
    String message = '動画を準備できませんでした。動画を再確認してください。',
  }) {
    if (_directJumpStatus != _DirectJumpStatus.pending) {
      return;
    }
    _directJumpStatus = _DirectJumpStatus.retryable;
    _directVideoResolutionDecisionPending = false;
    _directJumpMessage = message;
    _initialSeekValidationInFlight = false;
    _initialSeekRequestInFlight = false;
  }

  @override
  void dispose() {
    _directJumpGeneration++;
    if (_directJumpStatus == _DirectJumpStatus.pending) {
      _directJumpStatus = _DirectJumpStatus.abandoned;
    }
    _videoImportFlow.dispose();
    _videoImportOperationController.dispose();
    _tabController.dispose();
    _disposeVideoController();
    _caseMemoController.dispose();
    for (final controller in _reflectionControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onRecordProviderChanged(
    AsyncValue<SurgeryRecord?>? previous,
    AsyncValue<SurgeryRecord?> next,
  ) {
    if (!mounted) {
      return;
    }
    if (next.isLoading) {
      return;
    }
    if (_discardOrDeferDirectDataResultForInactiveRoute()) {
      return;
    }
    if (next.hasValue) {
      final deliveredVideoPath = next.value?.videoPath;
      if (_directJumpSnapshot != null &&
          (_directJumpStatus == _DirectJumpStatus.pending ||
              _directJumpStatus == _DirectJumpStatus.retryable)) {
        _directJumpObservedVideoPaths.add(deliveredVideoPath);
      }
    }
    final previousRecord = _latestRecord;
    var shouldDisposeVideo = false;
    var shouldRefreshVideoResolution = false;
    setState(() {
      if (next.hasError) {
        _recordRefreshError = next.error;
        return;
      }
      if (!next.hasValue) {
        return;
      }
      _recordProviderResolved = true;
      _recordRefreshError = null;
      _recordRefreshPendingAfterCommit = false;
      final record = next.value;
      if (record == null) {
        shouldDisposeVideo = true;
        shouldRefreshVideoResolution = true;
        if (_draftInitialized) {
          _recordWasDeleted = true;
        } else {
          _latestRecord = null;
        }
        if (_directJumpStatus == _DirectJumpStatus.pending ||
            _directJumpStatus == _DirectJumpStatus.retryable) {
          _abandonDirectJump('症例が削除されたため工程動画を開けませんでした。');
        } else if (_directJumpStatus == _DirectJumpStatus.consumed) {
          _markConsumedDirectJumpChanged('症例が削除されたため工程動画を開けませんでした。');
          _manualVideoRecoveryRequired = true;
          _directJumpGeneration++;
        }
        return;
      }
      final snapshot = _directJumpSnapshot;
      if (snapshot != null) {
        if ((_directJumpStatus == _DirectJumpStatus.pending ||
                _directJumpStatus == _DirectJumpStatus.retryable) &&
            record.videoPath != snapshot.videoPath) {
          if (_directJumpStatus == _DirectJumpStatus.pending &&
              _directVideoResolutionDecisionPending) {
            // A legacy migration may commit its managed reference before the
            // resolver returns the exact same-video normalization metadata.
            // Defer the decision to that authoritative result.
          } else {
            _abandonDirectJump(
              '動画が更新されたため自動で移動できませんでした。',
              requiresManualVideoRecovery: true,
            );
          }
          shouldDisposeVideo = true;
        } else if (_directJumpStatus == _DirectJumpStatus.consumed &&
            record.videoPath != _currentConsumedVideoReference(snapshot)) {
          _markConsumedDirectJumpChanged('動画が更新されました。動画を再確認してください。');
          _acceptConsumedVideoReference(record.videoPath);
          _manualVideoRecoveryRequired = true;
          _directJumpGeneration++;
          shouldDisposeVideo = true;
        }
      }
      if (previousRecord != null &&
          previousRecord.videoPath != record.videoPath &&
          !(_directJumpStatus == _DirectJumpStatus.pending &&
              _directVideoResolutionDecisionPending)) {
        shouldRefreshVideoResolution = true;
      }
      _recordWasDeleted = false;
      _latestRecord = record;
      _synchronizeDraftIfPossible();
    });
    if (shouldDisposeVideo) {
      _disposeVideoController();
    }
    if (shouldRefreshVideoResolution) {
      if (!_videoResolutionListenerStarted && next.value?.videoPath != null) {
        _startVideoResolutionListener();
      }
      if (_videoResolutionListenerStarted) {
        ref.invalidate(_reviewVideoResolutionProvider(widget.recordId));
      }
    }
    _maybeApplyInitialSeek();
  }

  void _onReviewsProviderChanged(
    AsyncValue<List<SurgicalStepReview>>? previous,
    AsyncValue<List<SurgicalStepReview>> next,
  ) {
    if (!mounted) {
      return;
    }
    if (next.isLoading) {
      return;
    }
    if (_discardOrDeferDirectDataResultForInactiveRoute()) {
      return;
    }
    setState(() {
      if (next.hasError) {
        _reviewsRefreshError = next.error;
        return;
      }
      if (!next.hasValue) {
        return;
      }
      _reviewsRefreshError = null;
      _reviewsRefreshPendingAfterCommit = false;
      var reviews = next.value!;
      final directFreshReview = _directFreshTargetReview;
      if (!_directInitialReviewMerged && directFreshReview != null) {
        final providerTarget = reviews
            .where((review) => review.step == directFreshReview.step)
            .firstOrNull;
        // The invalidated provider normally completes after the direct read
        // and is therefore authoritative. Only replace a demonstrably older
        // cached row; an absent, equal-time-but-different, or newer row must be
        // preserved so a concurrent timing change/deletion abandons the intent.
        if (providerTarget != null &&
            providerTarget.updatedAt.isBefore(directFreshReview.updatedAt)) {
          reviews = [
            for (final review in reviews)
              if (review.step == directFreshReview.step)
                directFreshReview
              else
                review,
          ];
        }
        _directInitialReviewMerged = true;
        _directFreshTargetReview = null;
      }
      if (_directJumpSnapshot case final snapshot?) {
        final targetReview = reviews
            .where((review) => review.step == snapshot.step)
            .firstOrNull;
        if (targetReview?.startMilliseconds != snapshot.startMilliseconds) {
          if (_directJumpStatus == _DirectJumpStatus.pending ||
              _directJumpStatus == _DirectJumpStatus.retryable) {
            _abandonDirectJump(
              targetReview?.startMilliseconds == null
                  ? '工程の記録位置が削除されたため自動で移動できませんでした。'
                  : '工程位置が更新されました。記録済み開始位置から確認してください。',
            );
          } else if (_directJumpStatus == _DirectJumpStatus.consumed) {
            _markConsumedDirectJumpChanged(
              targetReview?.startMilliseconds == null
                  ? '工程の記録位置が削除されました。'
                  : '工程位置が更新されました。記録済み開始位置から確認してください。',
            );
          }
        }
      }
      _latestReviews = reviews;
      _synchronizeDraftIfPossible();
    });
    _maybeApplyInitialSeek();
  }

  void _onVideoResolutionChanged(
    AsyncValue<_ReviewVideoResolution>? previous,
    AsyncValue<_ReviewVideoResolution> next,
  ) {
    if (!mounted) {
      return;
    }
    // Supersede an earlier validation even when this notification is discarded
    // for an inactive route; otherwise that older Future could still apply.
    final applicationGeneration = ++_videoResolutionApplicationGeneration;
    if (_discardDirectVideoResultForInactiveRoute()) {
      return;
    }
    if (next.isLoading) {
      setState(() {
        _videoProviderLoading = true;
      });
      return;
    }
    if (next.hasError) {
      if (_abandonDirectJumpForObservedVideoChange()) {
        return;
      }
      var shouldDisposeVideo = false;
      setState(() {
        _videoProviderLoading = false;
        _videoProviderError = next.error;
        _directVideoResolutionDecisionPending = false;
        final snapshot = _directJumpSnapshot;
        if (_directJumpStatus == _DirectJumpStatus.pending &&
            snapshot != null &&
            _latestRecord?.videoPath != snapshot.videoPath) {
          _abandonDirectJump(
            '動画が更新されたため自動で移動できませんでした。',
            requiresManualVideoRecovery: true,
          );
          shouldDisposeVideo = true;
        } else {
          _markDirectJumpRetryable();
        }
      });
      if (shouldDisposeVideo) {
        _disposeVideoController();
      }
      return;
    }
    unawaited(
      _validateAndApplyVideoResolution(next.value!, applicationGeneration),
    );
  }

  Future<void> _validateAndApplyVideoResolution(
    _ReviewVideoResolution resolution,
    int applicationGeneration,
  ) async {
    SurgeryRecord? persistedRecord;
    try {
      persistedRecord = await ref
          .read(surgeryRepositoryProvider)
          .getRecord(widget.recordId);
    } catch (error) {
      if (!mounted ||
          applicationGeneration != _videoResolutionApplicationGeneration) {
        return;
      }
      if (_discardDirectVideoResultForInactiveRoute()) {
        return;
      }
      if (_abandonDirectJumpForObservedVideoChange()) {
        return;
      }
      setState(() {
        _videoProviderLoading = false;
        _videoProviderError = error;
        _directVideoResolutionDecisionPending = false;
        _markDirectJumpRetryable();
      });
      return;
    }
    if (!mounted ||
        applicationGeneration != _videoResolutionApplicationGeneration) {
      return;
    }
    if (_discardDirectVideoResultForInactiveRoute()) {
      return;
    }

    final resolvedRecord = resolution.record;
    final persistedPath = persistedRecord?.videoPath;
    final resolutionStillCommitted =
        (resolvedRecord == null && persistedRecord == null) ||
        (resolvedRecord != null &&
            persistedRecord != null &&
            resolvedRecord.videoPath == persistedPath);
    if (!resolutionStillCommitted) {
      _rejectSupersededVideoResolution(persistedRecord);
      return;
    }

    _applyValidatedVideoResolution(
      _ReviewVideoResolution(
        record: persistedRecord,
        file: resolution.file,
        videoState: resolution.videoState,
        sourceVideoPath: resolution.sourceVideoPath,
        normalizedLegacyVideoPath: resolution.normalizedLegacyVideoPath,
      ),
      applicationGeneration,
    );
  }

  bool _discardDirectVideoResultForInactiveRoute() {
    if (!mounted) {
      return true;
    }
    final directStatus = _directJumpStatus;
    if ((directStatus == _DirectJumpStatus.pending ||
            directStatus == _DirectJumpStatus.consumed ||
            (directStatus == _DirectJumpStatus.retryable &&
                _directRetryValidationInFlight)) &&
        ModalRoute.of(context)?.isCurrent != true) {
      _discardDirectJumpForInactiveRoute(directStatus!);
      return true;
    }
    return false;
  }

  bool _discardDirectControllerResultForInactiveRoute() {
    if (!mounted) {
      return true;
    }
    final directStatus = _directJumpStatus;
    final hasActiveConsumedOperation =
        directStatus == _DirectJumpStatus.consumed &&
        (_initialSeekValidationInFlight || _initialSeekRequestInFlight);
    if ((directStatus == _DirectJumpStatus.pending ||
            (directStatus == _DirectJumpStatus.retryable &&
                _directRetryValidationInFlight) ||
            hasActiveConsumedOperation) &&
        ModalRoute.isCurrentOf(context) != true) {
      _discardDirectJumpForInactiveRoute(directStatus!);
      return true;
    }
    return false;
  }

  bool _discardOrDeferDirectDataResultForInactiveRoute() {
    if (!mounted) {
      return true;
    }
    if (ModalRoute.isCurrentOf(context) == true) {
      return false;
    }
    if (_discardDirectControllerResultForInactiveRoute() ||
        _refreshDiscardedDataWhenRouteCurrent) {
      _refreshDiscardedDataWhenRouteCurrent = true;
      return true;
    }
    return false;
  }

  bool _abandonDirectJumpForObservedVideoChange() {
    final snapshot = _directJumpSnapshot;
    final observedDifferentPath =
        snapshot != null &&
        _directJumpObservedVideoPaths.any(
          (videoPath) => videoPath != snapshot.videoPath,
        );
    if (_directJumpStatus != _DirectJumpStatus.pending ||
        !observedDifferentPath) {
      return false;
    }
    setState(() {
      _videoProviderLoading = false;
      _videoProviderError = null;
      _resolvedVideoFile = null;
      _abandonDirectJump(
        '動画が更新されたため自動で移動できませんでした。',
        requiresManualVideoRecovery: true,
      );
    });
    _disposeVideoController();
    return true;
  }

  void _rejectSupersededVideoResolution(SurgeryRecord? persistedRecord) {
    final hasDirectIntent = _directJumpSnapshot != null;
    var shouldDisposeVideo = false;
    setState(() {
      _videoProviderLoading = false;
      _videoProviderError = null;
      _resolvedVideoFile = null;
      _resolvedVideoState = null;
      _recordProviderResolved = true;
      if (persistedRecord == null) {
        if (_draftInitialized) {
          _recordWasDeleted = true;
        } else {
          _latestRecord = null;
        }
      } else {
        _recordWasDeleted = false;
        _latestRecord = persistedRecord;
        _synchronizeDraftIfPossible();
      }
      if (_directJumpStatus == _DirectJumpStatus.pending ||
          _directJumpStatus == _DirectJumpStatus.retryable) {
        _abandonDirectJump(
          persistedRecord == null
              ? '症例が削除されたため工程動画を開けませんでした。'
              : '動画が更新されたため自動で移動できませんでした。',
          requiresManualVideoRecovery: persistedRecord != null,
        );
        shouldDisposeVideo = true;
      } else if (_directJumpStatus == _DirectJumpStatus.consumed) {
        _markConsumedDirectJumpChanged(
          persistedRecord == null
              ? '症例が削除されたため工程動画を開けませんでした。'
              : '動画が更新されました。動画を再確認してください。',
        );
        _acceptConsumedVideoReference(persistedRecord?.videoPath);
        _manualVideoRecoveryRequired = true;
        _directJumpGeneration++;
        shouldDisposeVideo = true;
      }
    });
    if (shouldDisposeVideo) {
      _disposeVideoController();
    }
    ref.invalidate(surgeryRecordProvider(widget.recordId));
    if (!hasDirectIntent) {
      ref.invalidate(_reviewVideoResolutionProvider(widget.recordId));
    }
  }

  void _applyValidatedVideoResolution(
    _ReviewVideoResolution resolution,
    int applicationGeneration,
  ) {
    if (!mounted ||
        applicationGeneration != _videoResolutionApplicationGeneration) {
      return;
    }
    final committedRecord = resolution.record;
    final file = resolution.file;
    if (committedRecord != null &&
        (_recordWasDeleted ||
            (_recordProviderResolved && _latestRecord == null))) {
      // A record-provider deletion is authoritative over an older resolver
      // result that completed around the same frame.
      ref.invalidate(_reviewVideoResolutionProvider(widget.recordId));
      return;
    }
    final previousVideoPath = _latestRecord?.videoPath;
    var shouldDisposeVideo = file == null;
    var shouldEnsureVideo = file != null;
    var preserveNewerRecord = false;
    var shouldRefreshResolutionAfterResult = false;
    final currentRecord = _latestRecord;
    final currentVideoPath = currentRecord?.videoPath;
    final directSnapshot = _directJumpSnapshot;
    final normalizedLegacyVideoPath = resolution.normalizedLegacyVideoPath;
    if (normalizedLegacyVideoPath != null &&
        committedRecord?.videoPath != normalizedLegacyVideoPath) {
      // The migration produced a managed-B file, but B is no longer the
      // committed reference. Never bind that stale file back to source A.
      _rejectSupersededVideoResolution(committedRecord);
      return;
    }
    final observedOnlyExpectedLegacyPaths =
        normalizedLegacyVideoPath != null &&
        _directJumpObservedVideoPaths.every(
          (videoPath) =>
              videoPath == resolution.sourceVideoPath ||
              videoPath == normalizedLegacyVideoPath,
        );
    final observedUnexpectedDirectPath =
        directSnapshot != null &&
        (normalizedLegacyVideoPath != null
            ? !observedOnlyExpectedLegacyPaths
            : _directJumpObservedVideoPaths.any(
                (videoPath) => videoPath != directSnapshot.videoPath,
              ));
    if (_directJumpStatus == _DirectJumpStatus.pending &&
        observedUnexpectedDirectPath) {
      // A direct jump never follows an A -> C -> A sequence. Returning to the
      // captured path does not restore the immutable intent once an actual
      // replacement was observed while resolution was in flight.
      setState(() {
        _videoProviderLoading = false;
        _videoProviderError = null;
        _resolvedVideoFile = null;
        _resolvedVideoState = resolution.videoState;
        _abandonDirectJump(
          '動画が更新されたため自動で移動できませんでした。',
          requiresManualVideoRecovery: true,
        );
      });
      _disposeVideoController();
      return;
    }
    final isUncontestedLegacyNormalization =
        normalizedLegacyVideoPath != null &&
        resolution.sourceVideoPath == currentVideoPath &&
        committedRecord?.videoPath == normalizedLegacyVideoPath &&
        (directSnapshot == null || observedOnlyExpectedLegacyPaths);
    if (committedRecord != null &&
        currentRecord != null &&
        currentVideoPath != committedRecord.videoPath &&
        !isUncontestedLegacyNormalization) {
      // Never let a resolver result overwrite a different provider snapshot.
      // This also rejects an unobserved A -> B -> A sequence: a non-legacy
      // resolver cannot authoritatively change the reference it captured.
      // Provider delivery order is the authority here; wall-clock updatedAt
      // values are not a monotonic concurrency token. The sole exception is
      // an exact, uncontested legacy A -> managed-B normalization.
      ref.invalidate(surgeryRecordProvider(widget.recordId));
      ref.invalidate(_reviewVideoResolutionProvider(widget.recordId));
      return;
    }
    setState(() {
      if (_directJumpStatus == _DirectJumpStatus.pending) {
        _directVideoResolutionDecisionPending = false;
      }
      if (committedRecord == null) {
        shouldDisposeVideo = true;
        if (_draftInitialized) {
          _recordWasDeleted = true;
        } else {
          _latestRecord = null;
        }
        if (_directJumpStatus == _DirectJumpStatus.pending ||
            _directJumpStatus == _DirectJumpStatus.retryable) {
          _abandonDirectJump('症例が削除されたため工程動画を開けませんでした。');
        } else if (_directJumpStatus == _DirectJumpStatus.consumed) {
          _markConsumedDirectJumpChanged('症例が削除されたため工程動画を開けませんでした。');
          _manualVideoRecoveryRequired = true;
          _directJumpGeneration++;
        }
      } else {
        final snapshot = _directJumpSnapshot;
        if (snapshot != null &&
            _directJumpStatus == _DirectJumpStatus.pending) {
          final normalizedLegacyReference =
              resolution.normalizedLegacyVideoPath != null &&
              !snapshot.didNormalizeLegacyReference &&
              resolution.sourceVideoPath == snapshot.videoPath &&
              committedRecord.videoPath == resolution.normalizedLegacyVideoPath;
          if (normalizedLegacyReference) {
            _directJumpSnapshot = snapshot.withNormalizedVideoPath(
              committedRecord.videoPath!,
            );
            _directJumpObservedVideoPaths
              ..clear()
              ..add(committedRecord.videoPath);
          }
          final latestReferenceMatches = normalizedLegacyReference
              ? _latestRecord?.videoPath == snapshot.videoPath ||
                    _latestRecord?.videoPath == committedRecord.videoPath
              : _latestRecord?.videoPath == snapshot.videoPath;
          if ((!normalizedLegacyReference &&
                  (resolution.sourceVideoPath != snapshot.videoPath ||
                      committedRecord.videoPath != snapshot.videoPath)) ||
              !latestReferenceMatches) {
            _abandonDirectJump(
              '動画が更新されたため自動で移動できませんでした。',
              requiresManualVideoRecovery: true,
            );
            shouldDisposeVideo = true;
            if (!latestReferenceMatches) {
              preserveNewerRecord = true;
              shouldRefreshResolutionAfterResult = true;
            }
          } else if (resolution.videoState?.kind ==
                  RecordVideoStateKind.checkFailed ||
              (file == null &&
                  (resolution.videoState?.kind ==
                          RecordVideoStateKind.availableManaged ||
                      resolution.videoState?.kind ==
                          RecordVideoStateKind.availableLegacy))) {
            _markDirectJumpRetryable();
            shouldEnsureVideo = false;
          } else if (file == null ||
              (resolution.videoState?.kind !=
                      RecordVideoStateKind.availableManaged &&
                  resolution.videoState?.kind !=
                      RecordVideoStateKind.availableLegacy)) {
            _abandonDirectJump('動画を利用できないため工程位置へ移動できませんでした。');
            shouldDisposeVideo = true;
          }
        } else if (snapshot != null &&
            _directJumpStatus == _DirectJumpStatus.consumed &&
            committedRecord.videoPath !=
                _currentConsumedVideoReference(snapshot)) {
          _markConsumedDirectJumpChanged('動画が更新されました。動画を再確認してください。');
          _acceptConsumedVideoReference(committedRecord.videoPath);
          _manualVideoRecoveryRequired = true;
          _directJumpGeneration++;
          shouldDisposeVideo = true;
          shouldEnsureVideo = false;
        } else if (_manualVideoRecoveryRequired) {
          shouldEnsureVideo = false;
        } else if (_directJumpStatus == _DirectJumpStatus.retryable) {
          shouldEnsureVideo = false;
        }
        _recordWasDeleted = false;
        if (!preserveNewerRecord) {
          _latestRecord = _mergeResolvedVideoRecord(
            _latestRecord,
            committedRecord,
          );
          _synchronizeDraftIfPossible();
        }
      }
      _videoProviderLoading = false;
      _videoProviderError = null;
      _resolvedVideoFile = file;
      _resolvedVideoState = resolution.videoState;
    });
    if (shouldDisposeVideo) {
      _disposeVideoController();
    } else if (shouldEnsureVideo && file != null && committedRecord != null) {
      _ensureVideoController(file, videoReference: committedRecord.videoPath);
    }
    if (shouldRefreshResolutionAfterResult) {
      ref.invalidate(_reviewVideoResolutionProvider(widget.recordId));
    }
    _maybeApplyInitialSeek();
    if (!preserveNewerRecord &&
        committedRecord != null &&
        committedRecord.videoPath != previousVideoPath) {
      ref.invalidate(surgeryRecordProvider(widget.recordId));
      ref.invalidate(surgeryRecordsProvider);
    }
  }

  String? _currentConsumedVideoReference(_DirectJumpSnapshot snapshot) {
    return _hasConsumedVideoReference
        ? _consumedVideoReference
        : snapshot.videoPath;
  }

  void _acceptConsumedVideoReference(String? videoPath) {
    _hasConsumedVideoReference = true;
    _consumedVideoReference = videoPath;
  }

  SurgeryRecord _mergeResolvedVideoRecord(
    SurgeryRecord? current,
    SurgeryRecord resolved,
  ) {
    if (current == null) {
      return resolved;
    }
    if (current.videoPath == resolved.videoPath) {
      // Video resolution is authoritative only for video availability. Keep
      // fresher case metadata already delivered by the record provider.
      return current;
    }
    return current.copyWith(
      videoPath: resolved.videoPath,
      videoDisplayName: resolved.videoDisplayName,
      clearVideo: resolved.videoPath == null,
      updatedAt: resolved.updatedAt.isAfter(current.updatedAt)
          ? resolved.updatedAt
          : current.updatedAt,
    );
  }

  @override
  Widget build(BuildContext context) {
    _scheduleNormalLoadResumeIfCurrent(
      routeIsCurrent: ModalRoute.isCurrentOf(context) == true,
    );
    final record = _latestRecord;
    final reviews = _latestReviews;

    final Widget body;
    if (!_draftInitialized && _recordProviderResolved && record == null) {
      body = _buildInitialLoadFailure('症例が見つかりません', detail: _directJumpMessage);
    } else if (record == null || reviews == null || !_draftInitialized) {
      final initialError = _recordRefreshError ?? _reviewsRefreshError;
      body = initialError == null
          ? (_isDirectJumpPreparing
                ? _buildDirectJumpPreparingState()
                : const Center(child: CircularProgressIndicator()))
          : _buildInitialLoadFailure('レビューを読み込めませんでした。');
    } else {
      body = _buildBody(record, reviews);
    }

    final readyRecord = record;
    final readyReviews = reviews;

    return PopScope<void>(
      key: const Key('review-pop-scope'),
      canPop: !_isDirty && !_hasPendingWrite,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
          return;
        }
        if (_hasPendingWrite) {
          return;
        }
        await _handleLeaveAttempt();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('手術工程の時間記録'),
          actions: [
            VideoRegistrationHelpButton(enabled: !_isDirectJumpPreparing),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                key: const Key('review-save-button'),
                onPressed:
                    (!_isDirty ||
                        _hasPendingWrite ||
                        _recordWasDeleted ||
                        readyRecord == null ||
                        readyReviews == null)
                    ? null
                    : () => _saveReview(readyReviews),
                icon: _isSavingReview
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: const Text('保存'),
              ),
            ),
          ],
        ),
        body: SafeArea(top: false, child: body),
      ),
    );
  }

  Widget _buildBody(SurgeryRecord record, List<SurgicalStepReview> reviews) {
    final byStep = {for (final review in reviews) review.step: review};
    final totalSurgeryReview = byStep[SurgicalStep.totalSurgeryTime];
    const arrivalCalculator = ProcedureArrivalTimeCalculator();
    final hasRefreshError =
        _recordRefreshError != null || _reviewsRefreshError != null;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return GestureDetector(
      key: const Key('review-body'),
      onTap: () => FocusScope.of(context).unfocus(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabBar = _buildReviewTabBar(byStep);
          final reviewNotices = _buildReviewNotices(hasRefreshError);
          final maximumPinnedPlayerHeight =
              (constraints.maxHeight -
                      tabBar.preferredSize.height -
                      _minimumReviewContentHeight)
                  .clamp(0.0, double.infinity)
                  .toDouble();
          final isPortraitLayout =
              constraints.maxHeight >= constraints.maxWidth;
          final pinsInitializedPlayer =
              bottomInset == 0 &&
              isPortraitLayout &&
              _hasInitializedVideoPlayer &&
              maximumPinnedPlayerHeight >= _minimumPinnedPlayerHeight;

          final Widget videoRegion;
          if (bottomInset > 0) {
            videoRegion = const SizedBox.shrink();
          } else if (pinsInitializedPlayer) {
            videoRegion = ConstrainedBox(
              key: const Key('review-video-player-region'),
              constraints: BoxConstraints(maxHeight: maximumPinnedPlayerHeight),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: _buildVideoSection(record),
              ),
            );
          } else {
            final maximumTopHeight =
                (constraints.maxHeight -
                        tabBar.preferredSize.height -
                        _minimumFallbackReviewContentHeight)
                    .clamp(0.0, 360.0);
            final topHeight = (constraints.maxHeight * 0.42)
                .clamp(0.0, maximumTopHeight)
                .toDouble();
            videoRegion = SizedBox(
              key: const Key('review-video-fallback-region'),
              height: topHeight,
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: _buildVideoSection(record),
                ),
              ),
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              videoRegion,
              tabBar,
              Expanded(
                child: SizedBox(
                  key: const Key('review-content-region'),
                  child: Column(
                    children: [
                      if (reviewNotices.isNotEmpty)
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxHeight: _minimumReviewContentHeight,
                          ),
                          child: SingleChildScrollView(
                            key: const Key('review-notice-region'),
                            child: Column(children: reviewNotices),
                          ),
                        ),
                      Expanded(
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            for (final step in surgicalStepsInDisplayOrder)
                              ListView(
                                key: ValueKey(
                                  'review-step-content-${step.name}',
                                ),
                                keyboardDismissBehavior:
                                    ScrollViewKeyboardDismissBehavior.onDrag,
                                padding: EdgeInsets.fromLTRB(
                                  16,
                                  16,
                                  16,
                                  16 + bottomInset,
                                ),
                                children: [
                                  ProcedureTimingCard(
                                    step: step,
                                    timing: byStep[step]!,
                                    arrivalTime: arrivalCalculator.calculate(
                                      step: step,
                                      stepReview: byStep[step],
                                      totalSurgeryReview: totalSurgeryReview,
                                    ),
                                    isSaving: _savingStep == step,
                                    videoUnavailableReason:
                                        _timingUnavailableReason(),
                                    onStart:
                                        _hasUsableVideoPosition &&
                                            !_hasPendingWrite
                                        ? () =>
                                              _startStep(byStep[step]!, reviews)
                                        : null,
                                    onEnd:
                                        _hasUsableVideoPosition &&
                                            !_hasPendingWrite
                                        ? () => _endStep(byStep[step]!)
                                        : null,
                                    onReset:
                                        !_isDirectJumpPreparing &&
                                            !_hasPendingWrite &&
                                            !_recordWasDeleted
                                        ? () => _resetStep(byStep[step]!)
                                        : null,
                                    onSkip:
                                        !step.isTotalSurgeryTime &&
                                            !_isDirectJumpPreparing &&
                                            !_hasPendingWrite &&
                                            !_recordWasDeleted
                                        ? () => _skipStep(byStep[step]!)
                                        : null,
                                    onTapStart:
                                        byStep[step]!.startMilliseconds ==
                                                null ||
                                            !_hasUsableVideoPosition
                                        ? null
                                        : () => _seekToMilliseconds(
                                            byStep[step]!.startMilliseconds!,
                                          ),
                                    onTapEnd:
                                        byStep[step]!.endMilliseconds == null ||
                                            !_hasUsableVideoPosition
                                        ? null
                                        : () => _seekToMilliseconds(
                                            byStep[step]!.endMilliseconds!,
                                          ),
                                  ),
                                  const SizedBox(height: 12),
                                  _StepNotesCard(
                                    rating:
                                        _ratings[step] ?? StepRating.unreviewed,
                                    controller: _reflectionControllers[step]!,
                                    enabled:
                                        !_isSavingReview && !_recordWasDeleted,
                                    onRatingChanged: (value) {
                                      setState(() {
                                        _ratings[step] = value;
                                        _recomputeDirty();
                                      });
                                    },
                                  ),
                                ],
                              ),
                            ListView(
                              key: const Key('review-case-memo-content'),
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              padding: EdgeInsets.fromLTRB(
                                16,
                                16,
                                16,
                                16 + bottomInset,
                              ),
                              children: [
                                TextField(
                                  controller: _caseMemoController,
                                  readOnly:
                                      _isSavingReview || _recordWasDeleted,
                                  minLines: 3,
                                  maxLines: 8,
                                  scrollPadding: EdgeInsets.only(
                                    bottom: bottomInset + 96,
                                  ),
                                  decoration: const InputDecoration(
                                    labelText: '症例全体のメモ',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  TabBar _buildReviewTabBar(Map<SurgicalStep, SurgicalStepReview> byStep) {
    return TabBar(
      controller: _tabController,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      tabs: [
        for (final step in surgicalStepsInDisplayOrder)
          Tab(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (byStep[step]!.isProcessed) ...[
                  const Icon(Icons.check, size: 14),
                  const SizedBox(width: 4),
                ] else if (byStep[step]!.isRunning) ...[
                  const Icon(Icons.timer_outlined, size: 14),
                  const SizedBox(width: 4),
                ],
                Text(step.label),
              ],
            ),
          ),
        const Tab(text: '症例メモ'),
      ],
    );
  }

  List<Widget> _buildReviewNotices(bool hasRefreshError) {
    final directJumpMessage = _directJumpMessage;
    final seekFailureMessage = _directSeekFailureMessage;
    final notices = <Widget>[
      if (_isDirectJumpPreparing) _buildDirectJumpPreparingNotice(),
      if (!_isDirectJumpPreparing && directJumpMessage != null)
        _buildDirectJumpMessageNotice(
          directJumpMessage,
          noticeKey: const Key('direct-jump-primary-notice'),
          semanticsKey: const Key('direct-jump-primary-message'),
        ),
      if (!_isDirectJumpPreparing &&
          seekFailureMessage != null &&
          seekFailureMessage != directJumpMessage)
        _buildDirectJumpMessageNotice(
          seekFailureMessage,
          noticeKey: const Key('direct-jump-seek-failure-notice'),
          semanticsKey: const Key('direct-jump-seek-failure-message'),
          showVideoRetry: true,
        ),
      if (_recordWasDeleted)
        _buildDeletedRecordNotice()
      else if (hasRefreshError)
        _buildRefreshFailureNotice(),
      if (_videoProviderError != null && _hasInitializedVideoPlayer)
        _buildVideoRefreshWarning(),
      if (_lastVideoImportError case final error?)
        VideoImportPersistentErrorNotice(
          error: error,
          onReselect: _hasPendingWrite || _recordWasDeleted
              ? null
              : () => _pickVideoFromReview(
                  _lastVideoSelectionAction ??
                      ((_latestRecord?.videoPath == null)
                          ? _VideoSelectionAction.attach
                          : _VideoSelectionAction.replace),
                ),
        ),
    ];
    if (notices.isEmpty) {
      return const [];
    }
    return notices;
  }

  Widget _buildDirectJumpPreparingState() {
    final step = _directJumpStep;
    return Center(
      key: const Key('direct-jump-preparing-state'),
      child: Semantics(
        container: true,
        liveRegion: true,
        excludeSemantics: true,
        label: '${step?.label ?? '工程'}を開いています',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDirectJumpProgressIndicator(),
            const SizedBox(height: 12),
            Text('${step?.label ?? '工程'}を開いています…'),
          ],
        ),
      ),
    );
  }

  Widget _buildDirectJumpPreparingNotice() {
    final step = _directJumpStep;
    return Card(
      key: const Key('direct-jump-preparing-notice'),
      child: Semantics(
        container: true,
        excludeSemantics: true,
        label: '${step?.label ?? '工程'}を開いています',
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _buildDirectJumpProgressIndicator(compact: true),
              const SizedBox(width: 12),
              Expanded(child: Text('${step?.label ?? '工程'}を開いています…')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDirectJumpProgressIndicator({bool compact = false}) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return Icon(
        Icons.hourglass_top,
        key: const Key('direct-jump-static-progress'),
        size: compact ? 20 : 32,
      );
    }
    if (compact) {
      return const SizedBox.square(
        key: Key('direct-jump-animated-progress'),
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return const CircularProgressIndicator(
      key: Key('direct-jump-animated-progress'),
    );
  }

  Widget _buildDirectJumpMessageNotice(
    String message, {
    required Key noticeKey,
    required Key semanticsKey,
    bool showVideoRetry = false,
  }) {
    return Card(
      key: noticeKey,
      child: Column(
        children: [
          Semantics(
            key: semanticsKey,
            container: true,
            liveRegion: true,
            excludeSemantics: true,
            label: message,
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(message),
            ),
          ),
          if (showVideoRetry)
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const Key('direct-seek-video-recheck'),
                  onPressed: _refreshVideo,
                  icon: const Icon(Icons.refresh),
                  label: const Text('動画を再確認'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildVideoSection(SurgeryRecord record) {
    final controller = _videoController;
    if (_videoProviderError != null && controller == null) {
      return _buildVideoNotice(
        '動画情報を確認できませんでした。'
        '実体なしとは判定していません。'
        'レビュー内容はそのまま編集できます。',
        showPicker: false,
        showRetry: true,
        record: record,
      );
    }
    if (_videoProviderLoading && controller == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final videoState = _resolvedVideoState;
    if (videoState?.kind == RecordVideoStateKind.unregistered) {
      return _buildVideoNotice(
        '動画が登録されていません。開始・終了時刻の設定には動画が必要です。',
        showPicker: true,
        showRetry: false,
        record: record,
      );
    }
    if (videoState?.kind == RecordVideoStateKind.missing) {
      return _buildVideoNotice(
        '登録された動画の実体が見つかりません。'
        '既存の工程記録は保持されています。',
        showPicker: true,
        showRetry: true,
        record: record,
      );
    }
    if (videoState?.kind == RecordVideoStateKind.invalidReference) {
      return _buildVideoNotice(
        '動画参照が不正なため自動で開きません。'
        '既存の工程記録は保持されています。',
        showPicker: true,
        showRetry: true,
        record: record,
      );
    }
    if (videoState?.kind == RecordVideoStateKind.checkFailed) {
      return _buildVideoNotice(
        '動画を確認できませんでした。'
        '実体なしとは判定していません。'
        '既存の工程記録は保持されています。',
        showPicker: false,
        showRetry: true,
        record: record,
      );
    }
    if (_resolvedVideoFile == null || controller == null) {
      return _buildVideoNotice(
        '動画を利用できません。'
        '既存の工程記録は保持されています。',
        showPicker: false,
        showRetry: true,
        record: record,
      );
    }
    final errorMessage = _videoErrorMessage;
    if (errorMessage != null) {
      return _buildVideoNotice(
        errorMessage,
        showPicker: true,
        showRetry: true,
        record: record,
      );
    }
    if (!controller.value.isInitialized) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (controller.value.hasError) {
      return _buildVideoNotice(
        '動画の再生中にエラーが発生しました。'
        'レビュー内容はそのまま編集できます。',
        showPicker: true,
        showRetry: true,
        record: record,
      );
    }
    final aspectRatio = controller.value.aspectRatio;
    if (!aspectRatio.isFinite || aspectRatio <= 0) {
      return _buildVideoNotice(
        '動画の表示サイズを確認できませんでした。'
        'レビュー内容はそのまま編集できます。',
        showPicker: true,
        showRetry: true,
        record: record,
      );
    }
    return _buildVideoPlayer(controller);
  }

  Widget _buildVideoNotice(
    String message, {
    required bool showPicker,
    bool showRetry = false,
    SurgeryRecord? record,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(message, textAlign: TextAlign.center),
            if (showPicker) ...[
              const SizedBox(height: 12),
              if (_isSavingVideo)
                const Center(child: CircularProgressIndicator())
              else if (record?.videoPath == null)
                FilledButton.icon(
                  onPressed: _recordWasDeleted
                      ? null
                      : () =>
                            _pickVideoFromReview(_VideoSelectionAction.attach),
                  icon: const Icon(Icons.video_call_outlined),
                  label: const Text('動画を登録'),
                )
              else
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _recordWasDeleted
                          ? null
                          : () => _pickVideoFromReview(
                              _VideoSelectionAction.relink,
                            ),
                      icon: const Icon(Icons.link),
                      label: const Text('同じ動画を再登録'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _recordWasDeleted
                          ? null
                          : () => _pickVideoFromReview(
                              _VideoSelectionAction.replace,
                            ),
                      icon: const Icon(Icons.video_file_outlined),
                      label: const Text('別の動画に差し替え'),
                    ),
                  ],
                ),
            ],
            if (showRetry) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _refreshVideo,
                icon: const Icon(Icons.refresh),
                label: const Text('動画を再確認'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildVideoPlayer(VideoPlayerController controller) {
    return LayoutBuilder(
      key: const Key('review-video-player'),
      builder: (context, constraints) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (constraints.hasBoundedHeight)
            Flexible(
              fit: FlexFit.loose,
              child: LayoutBuilder(
                builder: (context, videoConstraints) => _buildVideoViewport(
                  controller,
                  maxWidth: videoConstraints.maxWidth,
                  maxHeight: videoConstraints.maxHeight,
                ),
              ),
            )
          else
            _buildVideoViewport(
              controller,
              maxWidth: constraints.maxWidth,
              maxHeight: _maximumVideoHeight,
            ),
          const SizedBox(height: 4),
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final duration = value.duration;
              final durationMs = duration.inMilliseconds > 0
                  ? duration.inMilliseconds.toDouble()
                  : 1.0;
              final positionMs = value.position.inMilliseconds.toDouble().clamp(
                0.0,
                durationMs,
              );
              return Column(
                children: [
                  Wrap(
                    key: const Key('review-video-timeline-row'),
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      Semantics(
                        liveRegion: false,
                        label:
                            '再生位置 '
                            '${formatTimelineMilliseconds(value.position.inMilliseconds)}'
                            '、動画の長さ '
                            '${formatTimelineMilliseconds(duration.inMilliseconds)}',
                        excludeSemantics: true,
                        child: Text(
                          '${formatTimelineMilliseconds(value.position.inMilliseconds)} / '
                          '${formatTimelineMilliseconds(duration.inMilliseconds)}',
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                      PopupMenuButton<double>(
                        tooltip: '再生速度を変更',
                        initialValue: _playbackSpeed,
                        onSelected: _setPlaybackSpeed,
                        itemBuilder: (context) => [
                          for (final speed in const [
                            0.5,
                            0.75,
                            1.0,
                            1.25,
                            1.5,
                            2.0,
                          ])
                            PopupMenuItem<double>(
                              value: speed,
                              child: Text('${speed}x'),
                            ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 12,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.speed, size: 18),
                              const SizedBox(width: 4),
                              Text('速度 ${_playbackSpeed}x'),
                              const Icon(Icons.arrow_drop_down),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    key: const Key('review-video-slider'),
                    value: positionMs,
                    max: durationMs,
                    onChanged: _hasUsableVideoPosition
                        ? (position) {
                            _seekToMilliseconds(position.round());
                          }
                        : null,
                  ),
                  VideoTransportControls(
                    isPlaying: value.isPlaying,
                    onSeekBackward5: _hasUsableVideoPosition
                        ? () => _seekRelative(const Duration(seconds: -5))
                        : null,
                    onSeekForward5: _hasUsableVideoPosition
                        ? () => _seekRelative(const Duration(seconds: 5))
                        : null,
                    onSeekBackward15: _hasUsableVideoPosition
                        ? () => _seekRelative(const Duration(seconds: -15))
                        : null,
                    onSeekForward15: _hasUsableVideoPosition
                        ? () => _seekRelative(const Duration(seconds: 15))
                        : null,
                    onTogglePlayback: _hasUsableVideoPosition
                        ? _togglePlayback
                        : null,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildVideoViewport(
    VideoPlayerController controller, {
    required double maxWidth,
    required double maxHeight,
  }) {
    final aspectRatio = controller.value.aspectRatio;
    final boundedWidth = maxWidth.isFinite ? math.max(0.0, maxWidth) : 0.0;
    final boundedHeight = math.max(
      0.0,
      math.min(
        _maximumVideoHeight,
        maxHeight.isFinite ? maxHeight : _maximumVideoHeight,
      ),
    );
    if (boundedWidth == 0 || boundedHeight == 0) {
      return const SizedBox.shrink(key: Key('review-video-surface'));
    }

    final widthLimitedHeight = boundedWidth / aspectRatio;
    final videoHeight = math.min(boundedHeight, widthLimitedHeight);
    final videoWidth = videoHeight * aspectRatio;
    return SizedBox(
      key: const Key('review-video-surface'),
      width: videoWidth,
      height: videoHeight,
      child: VideoSurface(child: VideoPlayer(controller)),
    );
  }

  void _ensureVideoController(File file, {required String? videoReference}) {
    if (_loadedVideoPath == file.path &&
        _videoBoundReference == videoReference) {
      return;
    }
    _disposeVideoController();
    final generation = ++_videoControllerGeneration;
    _loadedVideoPath = file.path;
    _videoBoundReference = videoReference;
    _videoErrorMessage = null;
    final controller = VideoPlayerController.file(file);
    _videoController = controller;
    controller.addListener(
      () => _onVideoControllerValueChanged(controller, generation),
    );
    _videoSeekCoordinator = VideoSeekCoordinator(
      currentPosition: () => controller.value.position,
      videoDuration: () => controller.value.duration,
      seekTo: controller.seekTo,
    );
    unawaited(_initializeVideoController(controller, generation));
  }

  void _onVideoControllerValueChanged(
    VideoPlayerController controller,
    int generation,
  ) {
    if (!mounted ||
        generation != _videoControllerGeneration ||
        !identical(_videoController, controller) ||
        !controller.value.hasError ||
        _videoErrorMessage != null) {
      return;
    }
    if (_discardDirectControllerResultForInactiveRoute()) {
      return;
    }
    // A stable, already-consumed direct jump keeps its completed result. A
    // later playback error is normal player recovery, but it must not mutate
    // the covered route. didChangeDependencies re-applies it after this route
    // becomes current again.
    if (ModalRoute.isCurrentOf(context) != true) {
      return;
    }
    final snapshot = _directJumpSnapshot;
    final failedSeekSnapshot =
        snapshot != null &&
            _directJumpStatus == _DirectJumpStatus.consumed &&
            _initialSeekRequestInFlight
        ? snapshot
        : null;
    // Position ticks stay confined to the ValueListenableBuilder below the
    // player. Only an error transition rebuilds the outer section so the
    // recovery UI replaces the unusable player without rebuilding the form on
    // every playback update.
    setState(() {
      if (failedSeekSnapshot != null) {
        _videoErrorMessage =
            '動画を再生できない状態になったため、自動移動の完了を確認できませんでした。'
            '動画を再確認してください。';
        _directSeekFailureMessage =
            '${failedSeekSnapshot.step.label}の開始位置へ移動できませんでした。'
            'シークバーまたは記録済み開始位置から確認してください。';
        _suppressDirectSeekCompletion = true;
        _initialSeekValidationInFlight = false;
        _initialSeekRequestInFlight = false;
        // A platform seek Future may never settle after a controller error.
        // Invalidate its completion now while keeping the intent consumed.
        _directJumpGeneration++;
      } else {
        _videoErrorMessage =
            '動画の再生中にエラーが発生しました。'
            'レビュー内容はそのまま編集できます。';
        _markDirectJumpRetryable();
      }
    });
  }

  Future<void> _initializeVideoController(
    VideoPlayerController controller,
    int generation,
  ) async {
    try {
      await controller.initialize();
      if (!mounted ||
          generation != _videoControllerGeneration ||
          !identical(_videoController, controller)) {
        return;
      }
      if (_discardDirectControllerResultForInactiveRoute()) {
        return;
      }
      if (controller.value.hasError) {
        throw StateError('Video initialization completed with an error.');
      }
      if (!controller.value.isInitialized) {
        _finishUnavailableVideoDuration();
        return;
      }
      await controller.setPlaybackSpeed(_playbackSpeed);
      if (!mounted ||
          generation != _videoControllerGeneration ||
          !identical(_videoController, controller)) {
        return;
      }
      if (_discardDirectControllerResultForInactiveRoute()) {
        return;
      }
      if (controller.value.hasError) {
        return;
      }
      if (!controller.value.isInitialized) {
        _finishUnavailableVideoDuration();
        return;
      }
      setState(() {});
      _maybeApplyInitialSeek();
    } catch (_) {
      if (!mounted ||
          generation != _videoControllerGeneration ||
          !identical(_videoController, controller)) {
        return;
      }
      if (_discardDirectControllerResultForInactiveRoute()) {
        return;
      }
      setState(() {
        _videoErrorMessage = '動画を再生できませんでした。動画ファイルを確認するか、別の動画を選択してください。';
        _markDirectJumpRetryable();
      });
    }
  }

  void _finishUnavailableVideoDuration() {
    setState(() {
      _videoErrorMessage =
          '動画の長さを取得できませんでした。'
          '動画ファイルを確認するか、別の動画を選択してください。';
      if (_directJumpStatus == _DirectJumpStatus.pending ||
          _directJumpStatus == _DirectJumpStatus.retryable) {
        _abandonDirectJump('動画の長さを取得できないため自動で移動できませんでした。');
      }
    });
  }

  void _disposeVideoController() {
    _videoControllerGeneration++;
    final seekCoordinator = _videoSeekCoordinator;
    final controller = _videoController;
    _videoSeekCoordinator = null;
    _videoController = null;
    _loadedVideoPath = null;
    _videoBoundReference = null;
    _videoErrorMessage = null;
    _initialSeekValidationInFlight = false;
    _initialSeekRequestInFlight = false;
    seekCoordinator?.dispose();
    if (controller != null) {
      // Detach the controller from the widget tree before physical disposal.
      // A platform seek Future may complete after logical invalidation; giving
      // ValueListenableBuilder one frame to remove its listener prevents that
      // late value notification from targeting an already-disposed State.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_disposeVideoControllerSafely(controller));
      });
      // addPostFrameCallback alone does not request another frame when this is
      // called from an existing post-frame callback.
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  Future<void> _disposeVideoControllerSafely(
    VideoPlayerController controller,
  ) async {
    try {
      await controller.dispose();
    } catch (_) {
      // The controller has already been detached and its generation invalidated.
    }
  }

  void _maybeApplyInitialSeek() {
    final snapshot = _directJumpSnapshot;
    final controller = _videoController;
    final seekCoordinator = _videoSeekCoordinator;
    final route = ModalRoute.of(context);
    if (_directJumpStatus == _DirectJumpStatus.pending &&
        route != null &&
        !route.isCurrent) {
      _discardDirectJumpForInactiveRoute(_DirectJumpStatus.pending);
      return;
    }
    if (_directJumpStatus != _DirectJumpStatus.pending ||
        snapshot == null ||
        controller == null ||
        seekCoordinator == null ||
        _initialSeekValidationInFlight ||
        _initialSeekRequestInFlight ||
        !_draftInitialized ||
        !controller.value.isInitialized ||
        controller.value.hasError ||
        _videoProviderLoading ||
        _videoProviderError != null ||
        _videoErrorMessage != null ||
        _latestRecord?.videoPath != snapshot.videoPath ||
        _videoBoundReference != snapshot.videoPath) {
      return;
    }

    final directGeneration = _directJumpGeneration;
    final controllerGeneration = _videoControllerGeneration;
    _initialSeekValidationInFlight = true;
    unawaited(
      _revalidateAndApplyInitialSeek(
        snapshot: snapshot,
        controller: controller,
        seekCoordinator: seekCoordinator,
        directGeneration: directGeneration,
        controllerGeneration: controllerGeneration,
      ),
    );
  }

  bool _isCurrentDirectSeekCandidate({
    required _DirectJumpSnapshot snapshot,
    required VideoPlayerController controller,
    required VideoSeekCoordinator seekCoordinator,
    required int directGeneration,
    required int controllerGeneration,
    required _DirectJumpStatus status,
  }) {
    final matches =
        mounted &&
        _directJumpStatus == status &&
        _directJumpGeneration == directGeneration &&
        _videoControllerGeneration == controllerGeneration &&
        identical(_directJumpSnapshot, snapshot) &&
        identical(_videoController, controller) &&
        identical(_videoSeekCoordinator, seekCoordinator) &&
        _videoBoundReference == snapshot.videoPath;
    if (!matches) {
      return false;
    }
    if (ModalRoute.of(context)?.isCurrent == true) {
      return true;
    }
    _discardDirectJumpForInactiveRoute(status);
    return false;
  }

  void _discardDirectJumpForInactiveRoute(_DirectJumpStatus status) {
    if (!mounted || _directJumpStatus != status) {
      return;
    }
    var shouldDisposeVideo = false;
    if (_dataListenersStarted) {
      _refreshDiscardedDataWhenRouteCurrent = true;
    }
    setState(() {
      if (status == _DirectJumpStatus.pending ||
          status == _DirectJumpStatus.retryable) {
        _directRetryValidationInFlight = false;
        if (status == _DirectJumpStatus.pending &&
            _directJumpSnapshot == null &&
            !_dataListenersStarted) {
          _resumeNormalLoadWhenRouteCurrent = true;
          _directFreshReadComplete = true;
        }
        _abandonDirectJump(
          '別の画面が開かれたため自動で移動しませんでした。'
          '記録済み開始位置から確認してください。',
          requiresManualVideoRecovery: true,
        );
        _videoProviderLoading = false;
        shouldDisposeVideo = true;
      } else if (status == _DirectJumpStatus.consumed) {
        _suppressDirectSeekCompletion = true;
        _manualVideoRecoveryRequired = true;
        _directJumpGeneration++;
        _initialSeekValidationInFlight = false;
        _initialSeekRequestInFlight = false;
        _directJumpMessage =
            '別の画面が開かれたため自動移動の完了結果を破棄しました。'
            '動画を再確認してください。';
        shouldDisposeVideo = true;
      }
    });
    if (shouldDisposeVideo) {
      _disposeVideoController();
    }
    _scheduleNormalLoadResumeIfCurrent();
  }

  bool _isVideoReadyForDirectSeek(VideoPlayerController controller) {
    return controller.value.isInitialized &&
        !controller.value.hasError &&
        !_videoProviderLoading &&
        _videoProviderError == null &&
        _videoErrorMessage == null;
  }

  Future<void> _revalidateAndApplyInitialSeek({
    required _DirectJumpSnapshot snapshot,
    required VideoPlayerController controller,
    required VideoSeekCoordinator seekCoordinator,
    required int directGeneration,
    required int controllerGeneration,
  }) async {
    final repository = ref.read(surgeryRepositoryProvider);
    Future<_DirectSeekCompletion>? seekCompletion;
    Object? transactionError;
    try {
      await repository.runRecordTransaction(
        snapshot.recordId,
        () => _revalidateAndApplyInitialSeekInTransaction(
          snapshot: snapshot,
          controller: controller,
          seekCoordinator: seekCoordinator,
          directGeneration: directGeneration,
          controllerGeneration: controllerGeneration,
          onSeekIssued: (completion) => seekCompletion = completion,
        ),
      );
    } catch (error) {
      transactionError = error;
    }

    final completion = seekCompletion;
    if (completion != null) {
      await _completeInitialSeek(
        snapshot: snapshot,
        controller: controller,
        seekCoordinator: seekCoordinator,
        directGeneration: directGeneration,
        controllerGeneration: controllerGeneration,
        completion: completion,
      );
      return;
    }

    if (transactionError != null) {
      if (!_isCurrentDirectSeekCandidate(
        snapshot: snapshot,
        controller: controller,
        seekCoordinator: seekCoordinator,
        directGeneration: directGeneration,
        controllerGeneration: controllerGeneration,
        status: _DirectJumpStatus.pending,
      )) {
        return;
      }
      setState(() {
        _initialSeekValidationInFlight = false;
        _abandonDirectJump('工程の最新情報を確認できなかったため自動で移動できませんでした。');
      });
    }
  }

  Future<void> _revalidateAndApplyInitialSeekInTransaction({
    required _DirectJumpSnapshot snapshot,
    required VideoPlayerController controller,
    required VideoSeekCoordinator seekCoordinator,
    required int directGeneration,
    required int controllerGeneration,
    required void Function(Future<_DirectSeekCompletion> completion)
    onSeekIssued,
  }) async {
    SurgeryRecord? initialRecord;
    SurgicalStepReview? initialReview;
    SurgeryRecord? record;
    SurgicalStepReview? review;
    try {
      final repository = ref.read(surgeryRepositoryProvider);
      initialRecord = await repository.getRecord(snapshot.recordId);
      if (!_isCurrentDirectSeekCandidate(
        snapshot: snapshot,
        controller: controller,
        seekCoordinator: seekCoordinator,
        directGeneration: directGeneration,
        controllerGeneration: controllerGeneration,
        status: _DirectJumpStatus.pending,
      )) {
        return;
      }
      initialReview = initialRecord == null
          ? null
          : await repository.getStepReview(
              surgeryRecordId: snapshot.recordId,
              step: snapshot.step,
            );
      if (!_isCurrentDirectSeekCandidate(
        snapshot: snapshot,
        controller: controller,
        seekCoordinator: seekCoordinator,
        directGeneration: directGeneration,
        controllerGeneration: controllerGeneration,
        status: _DirectJumpStatus.pending,
      )) {
        return;
      }
      record = await repository.getRecord(snapshot.recordId);
      if (!_isCurrentDirectSeekCandidate(
        snapshot: snapshot,
        controller: controller,
        seekCoordinator: seekCoordinator,
        directGeneration: directGeneration,
        controllerGeneration: controllerGeneration,
        status: _DirectJumpStatus.pending,
      )) {
        return;
      }
      // Mirror the final record read. The surrounding record transaction keeps
      // both values stable until the seek handoff, and this final review read
      // also protects controlled/custom repositories that complete a record
      // read only after changing the target timing.
      review = record == null
          ? null
          : await repository.getStepReview(
              surgeryRecordId: snapshot.recordId,
              step: snapshot.step,
            );
    } catch (_) {
      if (!_isCurrentDirectSeekCandidate(
        snapshot: snapshot,
        controller: controller,
        seekCoordinator: seekCoordinator,
        directGeneration: directGeneration,
        controllerGeneration: controllerGeneration,
        status: _DirectJumpStatus.pending,
      )) {
        return;
      }
      setState(() {
        _initialSeekValidationInFlight = false;
        _abandonDirectJump('工程の最新情報を確認できなかったため自動で移動できませんでした。');
      });
      return;
    }

    if (!_isCurrentDirectSeekCandidate(
      snapshot: snapshot,
      controller: controller,
      seekCoordinator: seekCoordinator,
      directGeneration: directGeneration,
      controllerGeneration: controllerGeneration,
      status: _DirectJumpStatus.pending,
    )) {
      return;
    }

    final initialRecordMatches = _recordMatchesDirectSnapshot(
      initialRecord,
      snapshot,
    );
    final finalRecordMatches = _recordMatchesDirectSnapshot(record, snapshot);
    final initialReviewMatches = _reviewMatchesDirectSnapshot(
      initialReview,
      snapshot,
    );
    final finalReviewMatches = _reviewMatchesDirectSnapshot(review, snapshot);
    final recordMatches = initialRecordMatches && finalRecordMatches;
    final reviewMatches = initialReviewMatches && finalReviewMatches;
    final shouldDisposeVideo = !recordMatches;
    if (!recordMatches || !reviewMatches) {
      setState(() {
        _applyFreshDirectRead(record, review);
        _initialSeekValidationInFlight = false;
        if (initialRecord == null || record == null) {
          _abandonDirectJump(
            record == null
                ? '症例が削除されたため工程動画を開けませんでした。'
                : '症例の状態が更新されたため自動で移動できませんでした。',
            requiresManualVideoRecovery: true,
          );
        } else if (!recordMatches) {
          _abandonDirectJump(
            '動画が更新されたため自動で移動できませんでした。',
            requiresManualVideoRecovery: true,
          );
        } else if (initialReview?.startMilliseconds == null ||
            review?.startMilliseconds == null) {
          _abandonDirectJump('工程の記録位置が削除されたため自動で移動できませんでした。');
        } else {
          _abandonDirectJump('工程位置が更新されました。記録済み開始位置から確認してください。');
        }
      });
      if (shouldDisposeVideo) {
        _disposeVideoController();
      }
      return;
    }

    if (!_isVideoReadyForDirectSeek(controller)) {
      setState(() {
        _initialSeekValidationInFlight = false;
        if (!controller.value.isInitialized || controller.value.hasError) {
          _videoErrorMessage =
              '動画を再生できない状態になったため自動で移動しませんでした。'
              '動画を再確認してください。';
          _markDirectJumpRetryable();
        } else if (_videoProviderError != null || _videoErrorMessage != null) {
          _markDirectJumpRetryable();
        }
      });
      return;
    }

    setState(() => _applyFreshDirectRead(record, review));
    final durationMilliseconds = controller.value.duration.inMilliseconds;
    final startMilliseconds = snapshot.startMilliseconds;
    if (durationMilliseconds <= 0 ||
        startMilliseconds < 0 ||
        startMilliseconds >= durationMilliseconds) {
      setState(() {
        _initialSeekValidationInFlight = false;
        _abandonDirectJump('記録位置が動画の範囲外のため自動で移動できませんでした。');
      });
      return;
    }

    if (!_isCurrentDirectSeekCandidate(
      snapshot: snapshot,
      controller: controller,
      seekCoordinator: seekCoordinator,
      directGeneration: directGeneration,
      controllerGeneration: controllerGeneration,
      status: _DirectJumpStatus.pending,
    )) {
      return;
    }

    setState(() {
      _initialSeekValidationInFlight = false;
      _initialSeekRequestInFlight = true;
      _directJumpStatus = _DirectJumpStatus.consumed;
      _directVideoResolutionDecisionPending = false;
    });

    // Calling seekTo synchronously hands the request to the coordinator. Keep
    // the transaction only through this handoff; waiting for the platform
    // completion while holding the DB lock would block deletion/replacement.
    onSeekIssued(
      seekCoordinator
          .seekTo(Duration(milliseconds: snapshot.startMilliseconds))
          .then(
            (_) => const _DirectSeekCompletion.success(),
            onError: (Object error, StackTrace _) =>
                _DirectSeekCompletion.failure(error),
          ),
    );
  }

  Future<void> _completeInitialSeek({
    required _DirectJumpSnapshot snapshot,
    required VideoPlayerController controller,
    required VideoSeekCoordinator seekCoordinator,
    required int directGeneration,
    required int controllerGeneration,
    required Future<_DirectSeekCompletion> completion,
  }) async {
    try {
      final result = await completion;
      if (result.error case final error?) {
        throw error;
      }
      if (!_isCurrentDirectSeekCandidate(
        snapshot: snapshot,
        controller: controller,
        seekCoordinator: seekCoordinator,
        directGeneration: directGeneration,
        controllerGeneration: controllerGeneration,
        status: _DirectJumpStatus.consumed,
      )) {
        return;
      }
      if (!_isVideoReadyForDirectSeek(controller)) {
        _finishConsumedDirectSeekUnavailable(snapshot, controller);
        return;
      }
      await controller.pause();
    } catch (_) {
      if (!_isCurrentDirectSeekCandidate(
        snapshot: snapshot,
        controller: controller,
        seekCoordinator: seekCoordinator,
        directGeneration: directGeneration,
        controllerGeneration: controllerGeneration,
        status: _DirectJumpStatus.consumed,
      )) {
        return;
      }
      _finishConsumedDirectSeekUnavailable(snapshot, controller);
      return;
    }

    if (!_isCurrentDirectSeekCandidate(
      snapshot: snapshot,
      controller: controller,
      seekCoordinator: seekCoordinator,
      directGeneration: directGeneration,
      controllerGeneration: controllerGeneration,
      status: _DirectJumpStatus.consumed,
    )) {
      return;
    }
    if (!_isVideoReadyForDirectSeek(controller)) {
      _finishConsumedDirectSeekUnavailable(snapshot, controller);
      return;
    }
    final shouldAnnounce =
        !_suppressDirectSeekCompletion && !_directJumpSuccessAnnounced;
    setState(() {
      _initialSeekRequestInFlight = false;
      if (shouldAnnounce) {
        _directJumpSuccessAnnounced = true;
      }
    });
    if (shouldAnnounce) {
      _showMessage(
        '${snapshot.step.label}の開始位置へ移動しました',
        tone: AppFeedbackTone.success,
      );
    }
  }

  void _finishConsumedDirectSeekUnavailable(
    _DirectJumpSnapshot snapshot,
    VideoPlayerController controller,
  ) {
    setState(() {
      _initialSeekRequestInFlight = false;
      _directSeekFailureMessage =
          '${snapshot.step.label}の開始位置へ移動できませんでした。'
          'シークバーまたは記録済み開始位置から確認してください。';
      if (!controller.value.isInitialized || controller.value.hasError) {
        _videoErrorMessage =
            '動画を再生できない状態になったため、自動移動の完了を確認できませんでした。'
            '動画を再確認してください。';
      }
    });
  }

  bool _recordMatchesDirectSnapshot(
    SurgeryRecord? record,
    _DirectJumpSnapshot snapshot,
  ) {
    return record != null &&
        record.id == snapshot.recordId &&
        record.videoPath == snapshot.videoPath;
  }

  bool _reviewMatchesDirectSnapshot(
    SurgicalStepReview? review,
    _DirectJumpSnapshot snapshot,
  ) {
    return review != null &&
        review.surgeryRecordId == snapshot.recordId &&
        review.step == snapshot.step &&
        review.startMilliseconds == snapshot.startMilliseconds;
  }

  void _applyFreshDirectRead(
    SurgeryRecord? record,
    SurgicalStepReview? review,
  ) {
    _recordProviderResolved = true;
    if (record == null) {
      if (_draftInitialized) {
        _recordWasDeleted = true;
      } else {
        _latestRecord = null;
      }
    } else {
      _recordWasDeleted = false;
      _latestRecord = record;
    }
    final reviews = _latestReviews;
    if (reviews == null) {
      return;
    }
    if (review != null) {
      _latestReviews = [
        for (final current in reviews)
          if (current.step == review.step) review else current,
      ];
    } else if (_directJumpSnapshot case final snapshot?) {
      // A deleted row must not leave its old timing actionable in the UI while
      // the compatibility provider recreates the missing empty row. Preserve
      // notes in memory for draft safety, but clear the no-longer-persisted
      // position immediately.
      _latestReviews = [
        for (final current in reviews)
          if (current.step == snapshot.step)
            current.copyWith(clearStart: true, clearEnd: true, isSkipped: false)
          else
            current,
      ];
    }
    _synchronizeDraftIfPossible();
  }

  Future<void> _seekRelative(Duration offset) async {
    final controller = _videoController;
    final seekCoordinator = _videoSeekCoordinator;
    if (controller == null ||
        seekCoordinator == null ||
        !controller.value.isInitialized ||
        !_hasUsableVideoPosition) {
      return;
    }
    await seekCoordinator.seekRelative(offset);
  }

  Future<void> _seekToMilliseconds(int milliseconds) async {
    final controller = _videoController;
    final seekCoordinator = _videoSeekCoordinator;
    if (controller == null ||
        seekCoordinator == null ||
        !controller.value.isInitialized ||
        !_hasUsableVideoPosition) {
      return;
    }
    await seekCoordinator.seekTo(Duration(milliseconds: milliseconds));
  }

  void _togglePlayback() {
    final controller = _videoController;
    if (controller == null ||
        !controller.value.isInitialized ||
        !_hasUsableVideoPosition) {
      return;
    }
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    final controller = _videoController;
    setState(() => _playbackSpeed = speed);
    if (controller != null && controller.value.isInitialized) {
      await controller.setPlaybackSpeed(speed);
    }
  }

  Future<void> _pickVideoFromReview(_VideoSelectionAction action) async {
    if (_hasPendingWrite || _recordWasDeleted) {
      return;
    }
    _lastVideoSelectionAction = action;
    final expectedVideoPath = _latestRecord?.videoPath;
    if (action != _VideoSelectionAction.attach && expectedVideoPath == null) {
      _showMessage('動画情報が更新されました。再度選択してください。');
      _refreshAll();
      return;
    }
    final selectionConfirmed = await _confirmBeforeVideoSelection(action);
    if (!selectionConfirmed || !mounted) {
      return;
    }
    setState(() => _isSavingVideo = true);
    try {
      selectionLoop:
      while (mounted) {
        final candidate = await selectVerifiedVideoForScreen(
          context: context,
          flow: _videoImportFlow,
          entryPoint: action == _VideoSelectionAction.attach
              ? VideoImportEntryPoint.attach
              : action == _VideoSelectionAction.relink
              ? VideoImportEntryPoint.relink
              : VideoImportEntryPoint.replace,
          onPersistentFailure: _rememberVideoImportFailure,
          dataInvariantSuffix:
              VideoImportDataInvariantSuffix.existingRecordUnchanged,
        );
        if (candidate == null || !mounted) {
          return;
        }

        final hasRecordedTimings = _hasRecordedTiming;
        var clearsTimings = action == _VideoSelectionAction.replace;
        if (hasRecordedTimings && action != _VideoSelectionAction.replace) {
          final decision = await showVideoTimelineIdentityDialog(
            context: context,
          );
          if (decision == null || !mounted) {
            return;
          }
          clearsTimings =
              decision == VideoTimelineIdentityDecision.changedOrUnknown;
        }

        final confirmed = await _confirmSelectedVideo(
          action,
          clearsTimings: clearsTimings,
        );
        if (!confirmed || !mounted) {
          return;
        }

        while (mounted) {
          final result = await _runSelectedVideoMutation(
            candidate: candidate,
            action: action,
            expectedVideoPath: expectedVideoPath,
            clearsTimings: clearsTimings,
            hadRecordedTimingsAtConfirmation: hasRecordedTimings,
          );
          if (!mounted) {
            return;
          }
          if (result case VideoImportScreenOperationSuccess<
            VideoImportOutcome<SurgeryRecord>
          >(
            :final value,
          )) {
            _applyCommittedVideoOutcome(value, clearsTimings: clearsTimings);
            return;
          }
          if (result
              is VideoImportScreenOperationCancelled<
                VideoImportOutcome<SurgeryRecord>
              >) {
            return;
          }
          final failure =
              result
                  as VideoImportScreenOperationFailure<
                    VideoImportOutcome<SurgeryRecord>
                  >;
          final resetRequested =
              !clearsTimings &&
              failure.error.code == VideoImportErrorCode.durationConflict &&
              (failure.recoveryAction ==
                      VideoImportRecoveryAction.resetTimingsAndAttach ||
                  failure.recoveryAction ==
                      VideoImportRecoveryAction.resetTimingsAndReplace);
          if (resetRequested) {
            final resetConfirmed = await _confirmSelectedVideo(
              action,
              clearsTimings: true,
            );
            if (!resetConfirmed || !mounted) {
              return;
            }
            clearsTimings = true;
            continue;
          }
          if (videoImportRecoveryRequestsReselection(failure.recoveryAction)) {
            continue selectionLoop;
          }
          if (videoImportRecoveryRequestsRetry(failure.recoveryAction)) {
            continue;
          }
          if (failure.recoveryAction ==
              VideoImportRecoveryAction.reloadRecord) {
            _refreshAll();
          }
          return;
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isSavingVideo = false);
      }
    }
  }

  bool get _hasRecordedTiming =>
      _latestReviews?.any(
        (review) =>
            review.startMilliseconds != null || review.endMilliseconds != null,
      ) ??
      false;

  Future<bool> _confirmBeforeVideoSelection(_VideoSelectionAction action) {
    if (action != _VideoSelectionAction.attach || !_hasRecordedTiming) {
      return Future<bool>.value(true);
    }
    return showAppConfirmDialog(
      context: context,
      title: '工程位置が記録されています',
      message:
          '動画を選択した後に、同じ動画として工程位置を保持するか、'
          '工程位置を消去して登録するかを確認します。',
      confirmLabel: '動画を選ぶ',
    );
  }

  Future<bool> _confirmSelectedVideo(
    _VideoSelectionAction action, {
    required bool clearsTimings,
  }) {
    if (clearsTimings) {
      return showAppConfirmDialog(
        context: context,
        title: action == _VideoSelectionAction.attach
            ? '工程位置を消去して動画を登録'
            : '工程位置を消去して動画を差し替え',
        message:
            '総手術時間を含む全工程の開始・終了位置が削除されます。'
            '自己評価、反省点、症例メモと未保存の入力内容は残ります。',
        confirmLabel: action == _VideoSelectionAction.attach ? '登録' : '差し替え',
        isDestructive: true,
      );
    }
    return switch (action) {
      _VideoSelectionAction.attach when _hasRecordedTiming =>
        showAppConfirmDialog(
          context: context,
          title: '記録済み位置を保持して動画を登録',
          message:
              '工程の開始・終了位置は保持されます。'
              '記録に対応する同じ手術動画を選択したことを確認してください。',
          confirmLabel: 'この動画を登録',
        ),
      _VideoSelectionAction.attach => Future<bool>.value(true),
      _VideoSelectionAction.relink => showAppConfirmDialog(
        context: context,
        title: '同じ動画を再登録',
        message:
            '選択したファイルが、この症例で使っていた同じ手術動画であることを'
            '確認してください。全工程の時刻とレビューは保持されます。',
        confirmLabel: '同じ動画として再登録',
      ),
      _VideoSelectionAction.replace => showAppConfirmDialog(
        context: context,
        title: '別の動画に差し替え',
        message:
            '総手術時間を含む全工程の開始・終了位置が削除されます。'
            '自己評価、反省点、症例メモは残ります。',
        confirmLabel: '差し替える',
        isDestructive: true,
      ),
    };
  }

  Future<VideoImportScreenOperationResult<VideoImportOutcome<SurgeryRecord>>>
  _runSelectedVideoMutation({
    required VerifiedVideoCandidate candidate,
    required _VideoSelectionAction action,
    required String? expectedVideoPath,
    required bool clearsTimings,
    required bool hadRecordedTimingsAtConfirmation,
  }) {
    final service = ref.read(recordVideoServiceProvider);
    return runVideoImportOperationForScreen<VideoImportOutcome<SurgeryRecord>>(
      context: context,
      dataInvariantSuffix:
          VideoImportDataInvariantSuffix.existingRecordUnchanged,
      entryPoint: clearsTimings
          ? expectedVideoPath == null
                ? VideoImportEntryPoint.attachWithTimingReset
                : VideoImportEntryPoint.replace
          : action == _VideoSelectionAction.attach
          ? VideoImportEntryPoint.attach
          : VideoImportEntryPoint.relink,
      operationController: _videoImportOperationController,
      onPersistentFailure: _rememberVideoImportFailure,
      operation: (cancellationToken, onProgress) {
        if (clearsTimings) {
          if (expectedVideoPath == null) {
            return service.attachWithTimingReset(
              surgeryRecordId: widget.recordId,
              candidate: candidate,
              cancellationToken: cancellationToken,
              onProgress: onProgress,
            );
          }
          return service.replaceVideoForRecord(
            surgeryRecordId: widget.recordId,
            expectedVideoPath: expectedVideoPath,
            candidate: candidate,
            cancellationToken: cancellationToken,
            onProgress: onProgress,
          );
        }
        return switch (action) {
          _VideoSelectionAction.attach => service.attachVideoToRecord(
            surgeryRecordId: widget.recordId,
            candidate: candidate,
            timelineIdentityDeclaration: hadRecordedTimingsAtConfirmation
                ? VideoTimelineIdentityDeclaration.sameUnchanged
                : VideoTimelineIdentityDeclaration.noRecordedTimingsObserved,
            cancellationToken: cancellationToken,
            onProgress: onProgress,
          ),
          _VideoSelectionAction.relink => service.relinkSameVideo(
            surgeryRecordId: widget.recordId,
            expectedVideoPath: expectedVideoPath!,
            candidate: candidate,
            timelineIdentityDeclaration: hadRecordedTimingsAtConfirmation
                ? VideoTimelineIdentityDeclaration.sameUnchanged
                : VideoTimelineIdentityDeclaration.noRecordedTimingsObserved,
            cancellationToken: cancellationToken,
            onProgress: onProgress,
          ),
          _VideoSelectionAction.replace => throw StateError(
            'replace must clear timings',
          ),
        };
      },
    );
  }

  void _applyCommittedVideoOutcome(
    VideoImportOutcome<SurgeryRecord> outcome, {
    required bool clearsTimings,
  }) {
    if (!mounted) {
      return;
    }
    setState(() {
      _latestRecord = outcome.value;
      _lastVideoImportError = null;
      _manualVideoRecoveryRequired = false;
      if (_directJumpStatus == _DirectJumpStatus.consumed) {
        _acceptConsumedVideoReference(outcome.value.videoPath);
      }
      if (clearsTimings) {
        _latestReviews = [
          for (final review in _latestReviews ?? const <SurgicalStepReview>[])
            review.copyWith(clearStart: true, clearEnd: true),
        ];
      }
      _markCommittedRefreshPending();
    });
    _startVideoResolutionListener();
    _invalidateReviewData();
    ref.invalidate(_reviewVideoResolutionProvider(widget.recordId));
    ref.invalidate(videoStorageMaintenanceProvider);
    if (outcome.maintenanceOutcome == VideoMaintenanceOutcome.pending) {
      _showMessage(
        '保存は完了しました。動画の後処理は次回起動時に再試行します。',
        tone: AppFeedbackTone.warning,
      );
    }
  }

  void _rememberVideoImportFailure(VideoImportException error) {
    if (mounted) {
      setState(() => _lastVideoImportError = error);
    }
  }

  void _synchronizeDraftIfPossible() {
    final record = _latestRecord;
    final reviews = _latestReviews;
    if (record == null ||
        reviews == null ||
        (_hasDirectJumpIntent && !_directFreshReadComplete)) {
      return;
    }
    if (!_draftInitialized) {
      _isApplyingProviderState = true;
      _savedCaseMemo = _normalizeText(record.caseMemo);
      _caseMemoController.text = _savedCaseMemo;
      _caseMemoController.addListener(_recomputeDirtyFromController);
      for (final review in reviews) {
        _savedRatings[review.step] = review.rating;
        _savedReflections[review.step] = _normalizeText(review.reflection);
        _ratings[review.step] = review.rating;
        final controller = TextEditingController(
          text: _normalizeText(review.reflection),
        );
        controller.addListener(_recomputeDirtyFromController);
        _reflectionControllers[review.step] = controller;
      }
      _isApplyingProviderState = false;
      _draftInitialized = true;
      _isDirty = false;
      if (!_hasDirectJumpIntent) {
        final firstIncomplete = reviews.indexWhere(
          (review) => review.step.isTotalSurgeryTime
              ? !review.isCompleted
              : !review.isProcessed,
        );
        if (firstIncomplete > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _tabController.index == 0) {
              _tabController.index = firstIncomplete;
            }
          });
        }
      }
      return;
    }
    if (_isDirty || _hasPendingWrite) {
      return;
    }
    _applyCommittedDraft(record, reviews);
  }

  void _applyCommittedDraft(
    SurgeryRecord record,
    List<SurgicalStepReview> reviews,
  ) {
    _isApplyingProviderState = true;
    _savedCaseMemo = _normalizeText(record.caseMemo);
    _setControllerText(_caseMemoController, _savedCaseMemo);
    for (final review in reviews) {
      final normalizedReflection = _normalizeText(review.reflection);
      _savedRatings[review.step] = review.rating;
      _savedReflections[review.step] = normalizedReflection;
      _ratings[review.step] = review.rating;
      final controller = _reflectionControllers[review.step];
      if (controller != null) {
        _setControllerText(controller, normalizedReflection);
      }
    }
    _isApplyingProviderState = false;
    _isDirty = false;
  }

  void _setControllerText(TextEditingController controller, String text) {
    if (controller.text == text) {
      return;
    }
    final offset = controller.selection.baseOffset.clamp(0, text.length);
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
  }

  String _normalizeText(String value) => value.trim();

  void _recomputeDirtyFromController() {
    if (_isApplyingProviderState || !mounted) {
      return;
    }
    setState(_recomputeDirty);
  }

  void _recomputeDirty() {
    if (!_draftInitialized) {
      _isDirty = false;
      return;
    }
    if (_normalizeText(_caseMemoController.text) != _savedCaseMemo) {
      _isDirty = true;
      return;
    }
    for (final step in surgicalStepsInDisplayOrder) {
      if ((_ratings[step] ?? StepRating.unreviewed) != _savedRatings[step] ||
          _normalizeText(_reflectionControllers[step]?.text ?? '') !=
              (_savedReflections[step] ?? '')) {
        _isDirty = true;
        return;
      }
    }
    _isDirty = false;
  }

  Future<void> _startStep(
    SurgicalStepReview review,
    List<SurgicalStepReview> reviews,
  ) async {
    if (_hasPendingWrite || !_hasUsableVideoPosition) {
      return;
    }
    final conflictingRunning = reviews
        .where(
          (item) =>
              item.isRunning && !review.step.canRunConcurrentlyWith(item.step),
        )
        .firstOrNull;
    if (conflictingRunning != null) {
      _showMessage(
        '現在「${conflictingRunning.step.label}」を計測中です。'
        '先に${conflictingRunning.step.label}の計測を終了してください。',
        tone: AppFeedbackTone.warning,
      );
      return;
    }
    await _saveTiming(
      review.copyWith(startMilliseconds: _currentMilliseconds, clearEnd: true),
      requiresVideoPosition: true,
    );
  }

  Future<void> _endStep(SurgicalStepReview review) async {
    if (_hasPendingWrite || !_hasUsableVideoPosition) {
      return;
    }
    final start = review.startMilliseconds;
    if (start == null || _currentMilliseconds <= start) {
      _showMessage('終了時刻は開始時刻より後に設定してください。', tone: AppFeedbackTone.warning);
      return;
    }
    await _saveTiming(
      review.copyWith(endMilliseconds: _currentMilliseconds),
      requiresVideoPosition: true,
    );
  }

  Future<void> _resetStep(SurgicalStepReview review) async {
    if (review.recordingStatus == StepRecordingStatus.skipped) {
      await _saveSkipped(review, isSkipped: false);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('計測結果を再設定'),
        content: Text('「${review.step.label}」の計測結果を削除して、再設定しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('再設定'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _saveTiming(
        review.copyWith(clearStart: true, clearEnd: true),
        requiresVideoPosition: false,
      );
    }
  }

  Future<void> _skipStep(SurgicalStepReview review) async {
    if (_hasPendingWrite || _recordWasDeleted) {
      return;
    }
    if (review.startMilliseconds != null || review.endMilliseconds != null) {
      final confirmed = await showAppConfirmDialog(
        context: context,
        title: '時間記録なしにする',
        message: '入力中の時刻を削除して、この工程を「時間記録なし」にしますか？',
        confirmLabel: '時間記録なしにする',
        isDestructive: true,
      );
      if (!confirmed || !mounted) {
        return;
      }
    }
    await _saveSkipped(review, isSkipped: true);
  }

  Future<void> _saveSkipped(
    SurgicalStepReview review, {
    required bool isSkipped,
  }) async {
    if (_hasPendingWrite || _recordWasDeleted) {
      return;
    }
    final expectedVideoPath = _latestRecord?.videoPath;
    setState(() => _savingStep = review.step);
    try {
      final saved = await ref
          .read(surgeryRepositoryProvider)
          .saveStepSkipped(
            review: review,
            isSkipped: isSkipped,
            expectedVideoPath: expectedVideoPath,
          );
      if (!mounted) {
        return;
      }
      setState(() {
        _replaceCommittedTiming(saved);
        _markCommittedRefreshPending();
      });
      _invalidateReviewData();
      await _performSuccessHaptic();
    } on VideoReferenceConflictException {
      _showMessage('動画が変更されたため工程状態を保存しませんでした。最新状態を再確認してください。');
      _refreshAll();
    } on SurgeryRecordNotFoundException {
      if (mounted) {
        setState(() => _recordWasDeleted = true);
      }
      _showMessage('症例が別画面で削除されたため保存できません。');
    } on SurgicalStepReviewNotFoundException {
      _showMessage('工程情報が更新されたため保存できませんでした。再読み込みしてください。');
      _refreshAll();
    } catch (_) {
      _showMessage('工程状態を保存できませんでした。もう一度お試しください。');
    } finally {
      if (mounted) {
        setState(() => _savingStep = null);
      }
    }
  }

  Future<void> _saveTiming(
    SurgicalStepReview review, {
    required bool requiresVideoPosition,
  }) async {
    if (_hasPendingWrite || _recordWasDeleted) {
      return;
    }
    final expectedVideoPath = _latestRecord?.videoPath;
    if (requiresVideoPosition &&
        (!_hasUsableVideoPosition ||
            _videoBoundReference != expectedVideoPath)) {
      _showMessage('動画の確認後に、もう一度操作してください。');
      return;
    }
    setState(() => _savingStep = review.step);
    try {
      final saved = await ref
          .read(surgeryRepositoryProvider)
          .saveStepTiming(review: review, expectedVideoPath: expectedVideoPath);
      if (!mounted) {
        return;
      }
      setState(() {
        _replaceCommittedTiming(saved);
        _markCommittedRefreshPending();
      });
      _invalidateReviewData();
      await _performSuccessHaptic();
    } on VideoReferenceConflictException {
      _showMessage('動画が変更されたため時刻を保存しませんでした。動画を再確認してください。');
      _refreshAll();
    } on SurgeryRecordNotFoundException {
      if (mounted) {
        setState(() => _recordWasDeleted = true);
      }
      _showMessage('症例が別画面で削除されたため保存できません。');
    } on SurgicalStepReviewNotFoundException {
      _showMessage('工程情報が更新されたため保存できませんでした。再読み込みしてください。');
      _refreshAll();
    } catch (_) {
      _showMessage('計測結果を保存できませんでした。もう一度お試しください。');
    } finally {
      if (mounted) {
        setState(() => _savingStep = null);
      }
    }
  }

  Future<bool> _saveReview(List<SurgicalStepReview> reviews) async {
    if (_hasPendingWrite || !_isDirty || _recordWasDeleted) {
      return !_isDirty && !_recordWasDeleted;
    }
    setState(() => _isSavingReview = true);
    try {
      final normalizedCaseMemo = _normalizeText(_caseMemoController.text);
      final normalizedReviews = [
        for (final review in reviews)
          if (surgicalStepsInDisplayOrder.contains(review.step))
            review.copyWith(
              rating: _ratings[review.step] ?? review.rating,
              reflection: _normalizeText(
                _reflectionControllers[review.step]?.text ?? review.reflection,
              ),
            ),
      ];
      final changedReviews = normalizedReviews
          .where(
            (review) =>
                review.rating != _savedRatings[review.step] ||
                review.reflection != _savedReflections[review.step],
          )
          .toList(growable: false);
      final result = await ref
          .read(surgeryRepositoryProvider)
          .saveReviewContent(
            surgeryRecordId: widget.recordId,
            reviews: changedReviews,
            caseMemo: normalizedCaseMemo,
          );
      if (!mounted) {
        return true;
      }
      final committedRecord = result.record.copyWith(
        caseMemo: normalizedCaseMemo,
      );
      final committedById = {
        for (final review in result.reviews) review.id: review,
      };
      final latestById = {
        for (final review in _latestReviews ?? normalizedReviews)
          review.id: review,
      };
      final committedReviews = [
        for (final review in normalizedReviews)
          committedById[review.id] ?? latestById[review.id] ?? review,
      ];
      setState(() {
        _latestRecord = committedRecord;
        _latestReviews = committedReviews;
        _applyCommittedDraft(committedRecord, committedReviews);
        _markCommittedRefreshPending();
      });
      _invalidateReviewData();
      _showMessage('レビューを保存しました', tone: AppFeedbackTone.success);
      return true;
    } on SurgeryRecordNotFoundException {
      if (mounted) {
        setState(() => _recordWasDeleted = true);
      }
      _showMessage('症例が別画面で削除されたため保存できません。');
      return false;
    } on SurgicalStepReviewNotFoundException {
      _showMessage('工程情報が更新されたためレビューを保存できませんでした。');
      _refreshAll();
      return false;
    } catch (_) {
      _showMessage('レビューを保存できませんでした。');
      return false;
    } finally {
      if (mounted) {
        setState(() => _isSavingReview = false);
      }
    }
  }

  Future<void> _handleLeaveAttempt() async {
    if (_hasPendingWrite || _leaveDialogIsOpen) {
      return;
    }
    _leaveDialogIsOpen = true;
    final action = await showDialog<_LeaveAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存していない変更があります'),
        content: const Text('画面を閉じますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _LeaveAction.cancel),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _LeaveAction.discard),
            child: const Text('変更を破棄'),
          ),
          FilledButton(
            onPressed: _recordWasDeleted
                ? null
                : () => Navigator.pop(context, _LeaveAction.save),
            child: const Text('保存して閉じる'),
          ),
        ],
      ),
    );
    _leaveDialogIsOpen = false;
    if (!mounted || action == null || action == _LeaveAction.cancel) {
      return;
    }
    if (action == _LeaveAction.save) {
      final record = _latestRecord;
      final reviews = _latestReviews;
      if (record != null && reviews != null) {
        final saved = await _saveReview(reviews);
        if (!saved) {
          return;
        }
      } else {
        return;
      }
    }
    if (mounted) {
      setState(() => _isDirty = false);
      Navigator.of(context).pop();
    }
  }

  void _replaceCommittedTiming(SurgicalStepReview saved) {
    final current = _latestReviews;
    if (current == null) {
      return;
    }
    _latestReviews = [
      for (final review in current)
        if (review.step == saved.step) saved else review,
    ];
  }

  Future<void> _performSuccessHaptic() async {
    try {
      await (widget.successHapticFeedback ?? HapticFeedback.lightImpact)();
    } catch (_) {
      // The database commit is authoritative; unavailable haptics must not
      // turn a successful timing operation into a failure.
    }
  }

  void _invalidateReviewData() {
    ref.invalidate(stepReviewsProvider(widget.recordId));
    ref.invalidate(recordProcedureTimingSnapshotProvider(widget.recordId));
    ref.invalidate(surgeryRecordProvider(widget.recordId));
    ref.invalidate(surgeryRecordsProvider);
    ref.invalidate(surgeryRecordProgressProvider);
    ref.invalidate(recordVideoStateProvider(widget.recordId));
    ref.invalidate(surgeryAnalysisProvider);
  }

  void _markCommittedRefreshPending() {
    _recordRefreshPendingAfterCommit = true;
    _reviewsRefreshPendingAfterCommit = true;
  }

  void _refreshAll() {
    _startVideoResolutionListener();
    ref.invalidate(stepReviewsProvider(widget.recordId));
    ref.invalidate(recordProcedureTimingSnapshotProvider(widget.recordId));
    ref.invalidate(surgeryRecordProvider(widget.recordId));
    ref.invalidate(surgeryRecordsProvider);
    ref.invalidate(surgeryRecordProgressProvider);
    ref.invalidate(recordVideoStateProvider(widget.recordId));
    ref.invalidate(_reviewVideoResolutionProvider(widget.recordId));
    ref.invalidate(surgeryAnalysisProvider);
  }

  void _refreshVideo() {
    if (_directJumpStatus == _DirectJumpStatus.retryable) {
      if (_directRetryValidationInFlight) {
        return;
      }
      _directRetryValidationInFlight = true;
      unawaited(
        _retryDirectJumpVideo().whenComplete(() {
          _directRetryValidationInFlight = false;
        }),
      );
      return;
    }
    if (_videoErrorMessage != null ||
        _directSeekFailureMessage != null ||
        _manualVideoRecoveryRequired) {
      _disposeVideoController();
      setState(() {
        _manualVideoRecoveryRequired = false;
        _videoProviderLoading = true;
      });
    }
    _startVideoResolutionListener();
    ref.invalidate(_reviewVideoResolutionProvider(widget.recordId));
  }

  Future<void> _retryDirectJumpVideo() async {
    final snapshot = _directJumpSnapshot;
    if (snapshot == null || _directJumpStatus != _DirectJumpStatus.retryable) {
      return;
    }
    final validationGeneration = _directJumpGeneration;
    SurgeryRecord? initialRecord;
    SurgicalStepReview? initialReview;
    SurgeryRecord? record;
    SurgicalStepReview? review;
    try {
      final repository = ref.read(surgeryRepositoryProvider);
      initialRecord = await repository.getRecord(snapshot.recordId);
      if (!_isCurrentDirectJumpRetry(snapshot, validationGeneration)) {
        return;
      }
      initialReview = initialRecord == null
          ? null
          : await repository.getStepReview(
              surgeryRecordId: snapshot.recordId,
              step: snapshot.step,
            );
      if (!_isCurrentDirectJumpRetry(snapshot, validationGeneration)) {
        return;
      }
      record = await repository.getRecord(snapshot.recordId);
      if (!_isCurrentDirectJumpRetry(snapshot, validationGeneration)) {
        return;
      }
      review = record == null
          ? null
          : await repository.getStepReview(
              surgeryRecordId: snapshot.recordId,
              step: snapshot.step,
            );
    } catch (_) {
      if (_isCurrentDirectJumpRetry(snapshot, validationGeneration)) {
        setState(() {
          _directJumpMessage = '工程の最新情報を確認できませんでした。もう一度お試しください。';
        });
      }
      return;
    }

    if (!_isCurrentDirectJumpRetry(snapshot, validationGeneration)) {
      return;
    }

    final initialRecordMatches = _recordMatchesDirectSnapshot(
      initialRecord,
      snapshot,
    );
    final finalRecordMatches = _recordMatchesDirectSnapshot(record, snapshot);
    final initialReviewMatches = _reviewMatchesDirectSnapshot(
      initialReview,
      snapshot,
    );
    final finalReviewMatches = _reviewMatchesDirectSnapshot(review, snapshot);
    final recordMatches = initialRecordMatches && finalRecordMatches;
    final reviewMatches = initialReviewMatches && finalReviewMatches;
    if (!recordMatches || !reviewMatches) {
      final shouldDisposeVideo = !recordMatches;
      setState(() {
        _applyFreshDirectRead(record, review);
        if (initialRecord == null || record == null) {
          _abandonDirectJump(
            record == null
                ? '症例が削除されたため工程動画を開けませんでした。'
                : '症例の状態が更新されたため自動で移動できませんでした。',
            requiresManualVideoRecovery: true,
          );
        } else if (!recordMatches) {
          _abandonDirectJump(
            '動画が更新されたため自動で移動できませんでした。',
            requiresManualVideoRecovery: true,
          );
        } else if (initialReview?.startMilliseconds == null ||
            review?.startMilliseconds == null) {
          _abandonDirectJump('工程の記録位置が削除されたため自動で移動できませんでした。');
        } else {
          _abandonDirectJump('工程位置が更新されました。記録済み開始位置から確認してください。');
        }
      });
      if (shouldDisposeVideo) {
        _disposeVideoController();
      }
      return;
    }

    _directJumpGeneration++;
    _disposeVideoController();
    setState(() {
      _applyFreshDirectRead(record, review);
      _directJumpStatus = _DirectJumpStatus.pending;
      _directVideoResolutionDecisionPending = true;
      _directJumpMessage = null;
      _directSeekFailureMessage = null;
      _videoProviderError = null;
      _videoProviderLoading = true;
      _suppressDirectSeekCompletion = false;
      _initialSeekValidationInFlight = false;
      _initialSeekRequestInFlight = false;
    });
    ref.invalidate(surgeryRecordProvider(widget.recordId));
    ref.invalidate(stepReviewsProvider(widget.recordId));
    ref.invalidate(_reviewVideoResolutionProvider(widget.recordId));
  }

  bool _isCurrentDirectJumpRetry(
    _DirectJumpSnapshot snapshot,
    int validationGeneration,
  ) {
    final matches =
        mounted &&
        _directJumpStatus == _DirectJumpStatus.retryable &&
        validationGeneration == _directJumpGeneration &&
        identical(_directJumpSnapshot, snapshot);
    if (!matches) {
      return false;
    }
    if (ModalRoute.of(context)?.isCurrent == true) {
      return true;
    }
    _discardDirectJumpForInactiveRoute(_DirectJumpStatus.retryable);
    return false;
  }

  Widget _buildInitialLoadFailure(String message, {String? detail}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (detail != null) ...[
              const SizedBox(height: 8),
              Semantics(
                key: const Key('direct-jump-initial-failure-announcement'),
                container: true,
                liveRegion: true,
                label: detail,
                excludeSemantics: true,
                child: Text(detail, textAlign: TextAlign.center),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _refreshAll,
              icon: const Icon(Icons.refresh),
              label: const Text('再読み込み'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRefreshFailureNotice() {
    final committedRefreshFailed =
        (_recordRefreshPendingAfterCommit && _recordRefreshError != null) ||
        (_reviewsRefreshPendingAfterCommit && _reviewsRefreshError != null);
    return MaterialBanner(
      content: Text(
        committedRefreshFailed
            ? '保存済み・表示更新失敗。'
                  '保存した内容はそのまま保持されています。'
            : '表示の更新に失敗しました。'
                  '入力中の内容は保持されています。',
      ),
      actions: [TextButton(onPressed: _refreshAll, child: const Text('再読み込み'))],
    );
  }

  Widget _buildVideoRefreshWarning() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Expanded(child: Text('動画情報の再確認に失敗しました。')),
          TextButton(onPressed: _refreshVideo, child: const Text('再試行')),
        ],
      ),
    );
  }

  Widget _buildDeletedRecordNotice() {
    return MaterialBanner(
      content: const Text(
        '症例が別画面で削除されたため保存できません。'
        '入力内容はコピーして退避できます。',
      ),
      actions: [
        TextButton.icon(
          onPressed: _copyDraft,
          icon: const Icon(Icons.copy),
          label: const Text('ドラフトをコピー'),
        ),
        TextButton(
          onPressed: _discardDraftAndReturn,
          child: const Text('破棄して一覧へ戻る'),
        ),
      ],
    );
  }

  String _videoUnavailableReason() {
    if (_hasUsableVideoPosition) {
      return '';
    }
    if (_videoProviderLoading ||
        (_videoController != null && !_videoController!.value.isInitialized)) {
      return '動画を確認中のため利用できません';
    }
    return switch (_resolvedVideoState?.kind) {
      RecordVideoStateKind.unregistered => '動画が未登録のため利用できません',
      RecordVideoStateKind.missing => '動画の実体がないため利用できません',
      RecordVideoStateKind.invalidReference => '動画参照が不正なため利用できません',
      RecordVideoStateKind.checkFailed => '動画の確認に失敗したため利用できません',
      RecordVideoStateKind.availableManaged ||
      RecordVideoStateKind.availableLegacy ||
      null => '動画を再生できないため利用できません',
    };
  }

  String _timingUnavailableReason() {
    if (_recordWasDeleted) {
      return '症例が削除されたため利用できません';
    }
    if (_hasPendingWrite) {
      return '保存処理中のため利用できません';
    }
    return _videoUnavailableReason();
  }

  Future<void> _copyDraft() async {
    final buffer = StringBuffer();
    final memo = _normalizeText(_caseMemoController.text);
    if (memo.isNotEmpty) {
      buffer.writeln('症例メモ');
      buffer.writeln(memo);
    }
    for (final step in surgicalStepsInDisplayOrder) {
      final reflection = _normalizeText(
        _reflectionControllers[step]?.text ?? '',
      );
      final rating = _ratings[step] ?? StepRating.unreviewed;
      if (reflection.isEmpty && rating == StepRating.unreviewed) {
        continue;
      }
      if (buffer.isNotEmpty) {
        buffer.writeln();
      }
      buffer.writeln('${step.label}：${rating.label}');
      if (reflection.isNotEmpty) {
        buffer.writeln(reflection);
      }
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
    _showMessage('ドラフトをコピーしました', tone: AppFeedbackTone.success);
  }

  void _discardDraftAndReturn() {
    if (!mounted) {
      return;
    }
    setState(() => _isDirty = false);
    Navigator.of(context).pop();
  }

  void _showMessage(
    String message, {
    AppFeedbackTone tone = AppFeedbackTone.failure,
  }) {
    if (mounted) {
      showAppSnackBar(context, message: message, tone: tone);
    }
  }
}

class _StepNotesCard extends StatelessWidget {
  const _StepNotesCard({
    required this.rating,
    required this.controller,
    required this.enabled,
    required this.onRatingChanged,
  });

  final StepRating rating;
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<StepRating> onRatingChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        title: const Text('自己評価・反省点'),
        subtitle: const Text('任意'),
        maintainState: true,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<StepRating>(
                key: ValueKey<StepRating>(rating),
                initialValue: rating,
                decoration: const InputDecoration(labelText: '自己評価'),
                items: StepRating.values
                    .map(
                      (item) => DropdownMenuItem(
                        value: item,
                        child: Text(item.label),
                      ),
                    )
                    .toList(),
                onChanged: enabled
                    ? (value) {
                        if (value != null) {
                          onRatingChanged(value);
                        }
                      }
                    : null,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                readOnly: !enabled,
                minLines: 2,
                maxLines: 5,
                scrollPadding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom + 96,
                ),
                decoration: const InputDecoration(
                  labelText: '反省点',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class VideoTransportControls extends StatelessWidget {
  const VideoTransportControls({
    required this.isPlaying,
    required this.onSeekBackward5,
    required this.onSeekForward5,
    required this.onSeekBackward15,
    required this.onSeekForward15,
    required this.onTogglePlayback,
    super.key,
  });

  final bool isPlaying;
  final VoidCallback? onSeekBackward5;
  final VoidCallback? onSeekForward5;
  final VoidCallback? onSeekBackward15;
  final VoidCallback? onSeekForward15;
  final VoidCallback? onTogglePlayback;

  @override
  Widget build(BuildContext context) {
    final playbackLabel = isPlaying ? '一時停止' : '再生';
    return Row(
      children: [
        Expanded(
          child: _VideoSeekButton(
            controlKey: const Key('seek-backward-15-seconds'),
            semanticsLabel: '15秒戻る',
            secondsLabel: '15秒',
            icon: Icons.fast_rewind,
            onPressed: onSeekBackward15,
            emphasized: false,
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: _VideoSeekButton(
            controlKey: const Key('seek-backward-5-seconds'),
            semanticsLabel: '5秒戻る',
            secondsLabel: '5秒',
            icon: Icons.fast_rewind,
            onPressed: onSeekBackward5,
            emphasized: true,
          ),
        ),
        const SizedBox(width: 4),
        Semantics(
          key: const Key('toggle-video-playback'),
          label: playbackLabel,
          button: true,
          enabled: onTogglePlayback != null,
          onTap: onTogglePlayback,
          excludeSemantics: true,
          child: Tooltip(
            message: playbackLabel,
            excludeFromSemantics: true,
            child: IconButton.filled(
              style: IconButton.styleFrom(minimumSize: const Size.square(56)),
              onPressed: onTogglePlayback,
              icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: _VideoSeekButton(
            controlKey: const Key('seek-forward-5-seconds'),
            semanticsLabel: '5秒進む',
            secondsLabel: '5秒',
            icon: Icons.fast_forward,
            onPressed: onSeekForward5,
            emphasized: true,
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: _VideoSeekButton(
            controlKey: const Key('seek-forward-15-seconds'),
            semanticsLabel: '15秒進む',
            secondsLabel: '15秒',
            icon: Icons.fast_forward,
            onPressed: onSeekForward15,
            emphasized: false,
          ),
        ),
      ],
    );
  }
}

class _VideoSeekButton extends StatelessWidget {
  const _VideoSeekButton({
    required this.controlKey,
    required this.semanticsLabel,
    required this.secondsLabel,
    required this.icon,
    required this.onPressed,
    required this.emphasized,
  });

  final Key controlKey;
  final String semanticsLabel;
  final String secondsLabel;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final style = emphasized
        ? FilledButton.styleFrom(
            minimumSize: const Size(48, 64),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          )
        : OutlinedButton.styleFrom(
            minimumSize: const Size(48, 64),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          );
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20),
        const SizedBox(height: 2),
        Text(secondsLabel, maxLines: 1),
      ],
    );
    final button = emphasized
        ? FilledButton.tonal(style: style, onPressed: onPressed, child: content)
        : OutlinedButton(style: style, onPressed: onPressed, child: content);
    return Semantics(
      key: controlKey,
      label: semanticsLabel,
      button: true,
      enabled: onPressed != null,
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: onPressed == null
            ? '$semanticsLabel（動画を確認できないため利用できません）'
            : semanticsLabel,
        excludeFromSemantics: true,
        child: button,
      ),
    );
  }
}

class ProcedureTimingCard extends StatelessWidget {
  const ProcedureTimingCard({
    required this.step,
    required this.timing,
    required this.arrivalTime,
    required this.isSaving,
    required this.onStart,
    required this.onEnd,
    required this.onReset,
    this.onSkip,
    this.videoUnavailableReason = '動画を確認できないため利用できません',
    this.onTapStart,
    this.onTapEnd,
    super.key,
  });

  final SurgicalStep step;
  final SurgicalStepReview timing;
  final ProcedureArrivalTimeResult arrivalTime;
  final bool isSaving;
  final VoidCallback? onStart;
  final VoidCallback? onEnd;
  final VoidCallback? onReset;
  final VoidCallback? onSkip;
  final String videoUnavailableReason;
  final VoidCallback? onTapStart;
  final VoidCallback? onTapEnd;

  @override
  Widget build(BuildContext context) {
    final hasTimingInput =
        timing.startMilliseconds != null || timing.endMilliseconds != null;
    final status = switch (timing.recordingStatus) {
      StepRecordingStatus.skipped => const (
        label: '時間記録なし',
        icon: Icons.do_not_disturb_alt_outlined,
      ),
      StepRecordingStatus.recorded => const (
        label: '完了',
        icon: Icons.check_circle_outline,
      ),
      StepRecordingStatus.unprocessed when timing.isRunning => const (
        label: '計測中',
        icon: Icons.timer_outlined,
      ),
      StepRecordingStatus.unprocessed when hasTimingInput => const (
        label: '要再設定',
        icon: Icons.warning_amber_outlined,
      ),
      StepRecordingStatus.unprocessed => const (
        label: '未着手',
        icon: Icons.radio_button_unchecked,
      ),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    step.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Semantics(
                  label: '工程状態、${status.label}',
                  excludeSemantics: true,
                  child: Chip(
                    avatar: Icon(status.icon, size: 18),
                    label: Text(status.label),
                  ),
                ),
              ],
            ),
            if (timing.recordingStatus == StepRecordingStatus.skipped) ...[
              const SizedBox(height: 12),
            ] else if (timing.isRunning) ...[
              _TimingSeekButton(
                label:
                    '開始時刻：'
                    '${formatTimelineMilliseconds(timing.startMilliseconds)}',
                tooltip: onTapStart == null
                    ? videoUnavailableReason
                    : '動画を開始時刻へ移動',
                onPressed: onTapStart,
              ),
              const SizedBox(height: 16),
            ] else if (timing.isCompleted) ...[
              _TimingSeekButton(
                label:
                    '開始時刻：'
                    '${formatTimelineMilliseconds(timing.startMilliseconds)}',
                tooltip: onTapStart == null
                    ? videoUnavailableReason
                    : '動画を開始時刻へ移動',
                onPressed: onTapStart,
              ),
              _TimingSeekButton(
                label:
                    '終了時刻：'
                    '${formatTimelineMilliseconds(timing.endMilliseconds)}',
                tooltip: onTapEnd == null
                    ? videoUnavailableReason
                    : '動画を終了時刻へ移動',
                onPressed: onTapEnd,
              ),
              Text('所要時間：${formatProcedureDuration(timing.duration)}'),
              const SizedBox(height: 16),
            ] else
              const SizedBox(height: 12),
            if (!step.isTotalSurgeryTime) ...[
              ProcedureArrivalTimeView(result: arrivalTime),
              const SizedBox(height: 16),
            ],
            if (isSaving)
              const SizedBox(
                height: 56,
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              _buildPrimaryAction(context),
              if (timing.recordingStatus == StepRecordingStatus.unprocessed &&
                  !step.isTotalSurgeryTime) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.center,
                  child: TextButton(
                    key: const Key('procedure-skip-button'),
                    onPressed: onSkip,
                    child: const Text('今回は時間を記録しない'),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPrimaryAction(BuildContext context) {
    if (timing.isNotStarted) {
      return Tooltip(
        message: onStart == null ? videoUnavailableReason : '現在の動画位置で工程を開始',
        child: SizedBox(
          width: double.infinity,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: FilledButton.icon(
              key: const Key('procedure-start-button'),
              onPressed: onStart,
              icon: const Icon(Icons.play_arrow),
              label: const Text('この工程を開始'),
            ),
          ),
        ),
      );
    }
    if (timing.isRunning) {
      return Tooltip(
        message: onEnd == null ? videoUnavailableReason : '現在の動画位置で工程を終了',
        child: SizedBox(
          width: double.infinity,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: FilledButton.icon(
              key: const Key('procedure-end-button'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: onEnd,
              icon: const Icon(Icons.stop),
              label: const Text('この工程を終了'),
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerRight,
      child: OutlinedButton.icon(
        key: const Key('procedure-reset-button'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: onReset,
        icon: const Icon(Icons.refresh),
        label: const Text('再設定'),
      ),
    );
  }
}

class _TimingSeekButton extends StatelessWidget {
  const _TimingSeekButton({
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final String label;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: onPressed == null ? '$label、$tooltip' : label,
        button: true,
        enabled: onPressed != null,
        excludeSemantics: true,
        child: SizedBox(
          width: double.infinity,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: TextButton.icon(
              onPressed: onPressed,
              icon: const Icon(Icons.movie_filter_outlined, size: 18),
              label: Align(alignment: Alignment.centerLeft, child: Text(label)),
            ),
          ),
        ),
      ),
    );
  }
}
