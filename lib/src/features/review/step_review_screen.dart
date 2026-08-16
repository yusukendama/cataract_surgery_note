import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../data/providers.dart';
import '../../data/record_mutation_coordinator.dart';
import '../../data/record_video_service.dart';
import '../../data/surgery_video_picker.dart';
import '../../domain/duration_formatters.dart';
import '../../domain/surgery_models.dart';
import '../../domain/video_seek_coordinator.dart';
import '../../widgets/app_confirm_dialog.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/video_surface.dart';

class _ReviewVideoResolution {
  const _ReviewVideoResolution({
    required this.record,
    required this.file,
    required this.videoState,
  });

  final SurgeryRecord? record;
  final File? file;
  final RecordVideoState? videoState;
}

final _reviewVideoResolutionProvider = FutureProvider.autoDispose
    .family<_ReviewVideoResolution, String>((ref, recordId) async {
      final record = await ref.watch(surgeryRecordProvider(recordId).future);
      if (record == null) {
        return const _ReviewVideoResolution(
          record: null,
          file: null,
          videoState: null,
        );
      }
      final service = ref.watch(recordVideoServiceProvider);
      var videoState = await service.inspectVideoState(record);
      var file = videoState.file;
      var committedRecord = record;
      if (videoState.kind == RecordVideoStateKind.availableLegacy) {
        file = await service.resolveVideoForRecord(record);
        committedRecord =
            await ref.read(surgeryRepositoryProvider).getRecord(recordId) ??
            record;
        if (committedRecord.videoPath != record.videoPath) {
          videoState = await service.inspectVideoState(committedRecord);
          file = videoState.file ?? file;
        }
      }
      return _ReviewVideoResolution(
        record: committedRecord,
        file: file,
        videoState: videoState,
      );
    });

enum _LeaveAction { cancel, discard, save }

enum _VideoSelectionAction { attach, relink, replace }

typedef SuccessHapticFeedback = Future<void> Function();

const _minimumReviewContentHeight = 96.0;
const _minimumFallbackReviewContentHeight = 48.0;
const _minimumPinnedPlayerHeight = 240.0;
const _maximumVideoHeight = 280.0;

class StepReviewScreen extends ConsumerStatefulWidget {
  const StepReviewScreen({
    required this.recordId,
    this.successHapticFeedback,
    super.key,
  });

  final String recordId;

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
  VideoPlayerController? _videoController;
  VideoSeekCoordinator? _videoSeekCoordinator;
  String? _loadedVideoPath;
  String? _videoBoundReference;
  String? _videoErrorMessage;
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

  bool get _hasPendingWrite =>
      _savingStep != null || _isSavingReview || _isSavingVideo;

  bool get _hasUsableVideoPosition {
    final controller = _videoController;
    return controller != null &&
        controller.value.isInitialized &&
        !controller.value.hasError &&
        _videoErrorMessage == null &&
        !_videoProviderLoading &&
        _videoProviderError == null &&
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
    _tabController = TabController(
      length: surgicalStepsInDisplayOrder.length + 1,
      vsync: this,
    );
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
    ref.listenManual(
      _reviewVideoResolutionProvider(widget.recordId),
      _onVideoResolutionChanged,
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
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
        if (_draftInitialized) {
          _recordWasDeleted = true;
        } else {
          _latestRecord = null;
        }
        return;
      }
      _recordWasDeleted = false;
      _latestRecord = record;
      _synchronizeDraftIfPossible();
    });
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
      _latestReviews = next.value;
      _synchronizeDraftIfPossible();
    });
  }

  void _onVideoResolutionChanged(
    AsyncValue<_ReviewVideoResolution>? previous,
    AsyncValue<_ReviewVideoResolution> next,
  ) {
    if (!mounted) {
      return;
    }
    if (next.isLoading) {
      setState(() => _videoProviderLoading = true);
      return;
    }
    if (next.hasError) {
      setState(() {
        _videoProviderLoading = false;
        _videoProviderError = next.error;
      });
      return;
    }
    final resolution = next.value!;
    final committedRecord = resolution.record;
    final file = resolution.file;
    final previousVideoPath = _latestRecord?.videoPath;
    if (file == null) {
      _disposeVideoController();
    } else {
      _ensureVideoController(file, videoReference: committedRecord?.videoPath);
    }
    setState(() {
      if (committedRecord == null) {
        if (_draftInitialized) {
          _recordWasDeleted = true;
        }
      } else {
        _recordWasDeleted = false;
        _latestRecord = committedRecord;
        _synchronizeDraftIfPossible();
      }
      _videoProviderLoading = false;
      _videoProviderError = null;
      _resolvedVideoFile = file;
      _resolvedVideoState = resolution.videoState;
    });
    if (committedRecord != null &&
        committedRecord.videoPath != previousVideoPath) {
      ref.invalidate(surgeryRecordProvider(widget.recordId));
      ref.invalidate(surgeryRecordsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = _latestRecord;
    final reviews = _latestReviews;

    final Widget body;
    if (!_draftInitialized && _recordProviderResolved && record == null) {
      body = _buildInitialLoadFailure('症例が見つかりません');
    } else if (record == null || reviews == null || !_draftInitialized) {
      final initialError = _recordRefreshError ?? _reviewsRefreshError;
      body = initialError == null
          ? const Center(child: CircularProgressIndicator())
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
                                        !_hasPendingWrite && !_recordWasDeleted
                                        ? () => _resetStep(byStep[step]!)
                                        : null,
                                    onSkip:
                                        !step.isTotalSurgeryTime &&
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
    final notices = <Widget>[
      if (_recordWasDeleted)
        _buildDeletedRecordNotice()
      else if (hasRefreshError)
        _buildRefreshFailureNotice(),
      if (_videoProviderError != null && _hasInitializedVideoPlayer)
        _buildVideoRefreshWarning(),
    ];
    if (notices.isEmpty) {
      return const [];
    }
    return notices;
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
                    onTogglePlayback: _togglePlayback,
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
    _videoSeekCoordinator = VideoSeekCoordinator(
      currentPosition: () => controller.value.position,
      videoDuration: () => controller.value.duration,
      seekTo: controller.seekTo,
    );
    controller
        .initialize()
        .then((_) async {
          if (!mounted ||
              generation != _videoControllerGeneration ||
              !identical(_videoController, controller)) {
            return;
          }
          await controller.setPlaybackSpeed(_playbackSpeed);
          if (mounted &&
              generation == _videoControllerGeneration &&
              identical(_videoController, controller)) {
            setState(() {});
          }
        })
        .catchError((Object error) {
          if (mounted &&
              generation == _videoControllerGeneration &&
              identical(_videoController, controller)) {
            setState(() {
              _videoErrorMessage = '動画を再生できませんでした。動画ファイルを確認するか、別の動画を選択してください。';
            });
          }
        });
  }

  void _disposeVideoController() {
    _videoControllerGeneration++;
    _videoSeekCoordinator?.dispose();
    _videoController?.dispose();
    _videoSeekCoordinator = null;
    _videoController = null;
    _loadedVideoPath = null;
    _videoBoundReference = null;
    _videoErrorMessage = null;
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
    if (controller == null || !controller.value.isInitialized) {
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
    final SelectedSurgeryVideo? selectedVideo;
    try {
      selectedVideo = await ref.read(surgeryVideoPickerProvider).pickVideo();
    } catch (_) {
      _showMessage('動画を選択できませんでした。もう一度お試しください。');
      return;
    }
    if (selectedVideo == null) {
      return;
    }
    final path = selectedVideo.path;
    final fileName = selectedVideo.displayName;
    final confirmed = await _confirmSelectedVideo(action);
    if (!confirmed || !mounted) {
      return;
    }
    setState(() => _isSavingVideo = true);
    try {
      final service = ref.read(recordVideoServiceProvider);
      late final SurgeryRecord committedRecord;
      switch (action) {
        case _VideoSelectionAction.attach:
          committedRecord = await service.attachVideoToRecord(
            surgeryRecordId: widget.recordId,
            sourcePath: path,
            originalFileName: fileName,
          );
          break;
        case _VideoSelectionAction.relink:
          committedRecord = await service.relinkSameVideo(
            surgeryRecordId: widget.recordId,
            expectedVideoPath: expectedVideoPath!,
            sourcePath: path,
            originalFileName: fileName,
          );
          break;
        case _VideoSelectionAction.replace:
          committedRecord = await service.replaceVideoForRecord(
            surgeryRecordId: widget.recordId,
            expectedVideoPath: expectedVideoPath!,
            sourcePath: path,
            originalFileName: fileName,
          );
          break;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _latestRecord = committedRecord;
        if (action == _VideoSelectionAction.replace) {
          _latestReviews = [
            for (final review in _latestReviews ?? const <SurgicalStepReview>[])
              review.copyWith(clearStart: true, clearEnd: true),
          ];
        }
        _markCommittedRefreshPending();
      });
      _invalidateReviewData();
      ref.invalidate(_reviewVideoResolutionProvider(widget.recordId));
      ref.invalidate(videoStorageMaintenanceProvider);
      if (service.hasPendingCleanup) {
        _showMessage(
          '保存は完了しました。動画の後処理は次回起動時に再試行します。',
          tone: AppFeedbackTone.warning,
        );
      }
    } on VideoReferenceConflictException {
      _showMessage('操作中に登録動画が変更されたため保存しませんでした。');
      _refreshAll();
    } on SurgeryRecordNotFoundException {
      if (mounted) {
        setState(() => _recordWasDeleted = true);
      }
      _showMessage('症例が別画面で削除されたため保存できません。');
    } catch (error) {
      _showMessage(_describeVideoError(error));
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
      title: '記録済み位置に対応する動画を選択',
      message:
          '工程の開始・終了位置は保持されます。'
          '必ず、これらの位置を記録した同じ手術動画を選択してください。',
      confirmLabel: '動画を選ぶ',
    );
  }

  Future<bool> _confirmSelectedVideo(_VideoSelectionAction action) {
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

  String _describeVideoError(Object error) {
    if (error is PlatformException &&
        error.code.startsWith('backup_exclusion')) {
      return '動画のバックアップ除外を確認できなかったため保存していません。もう一度お試しください。';
    }
    if (error is ArgumentError) {
      return 'この動画形式は再生できません。MP4形式などに変換してから、もう一度選択してください。';
    }
    if (error is FileSystemException) {
      return '動画を保存できませんでした。ストレージの空き容量をご確認ください。';
    }
    return '動画を保存できませんでした。もう一度お試しください。';
  }

  void _synchronizeDraftIfPossible() {
    final record = _latestRecord;
    final reviews = _latestReviews;
    if (record == null || reviews == null) {
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
    ref.invalidate(stepReviewsProvider(widget.recordId));
    ref.invalidate(surgeryRecordProvider(widget.recordId));
    ref.invalidate(surgeryRecordsProvider);
    ref.invalidate(surgeryRecordProgressProvider);
    ref.invalidate(recordVideoStateProvider(widget.recordId));
    ref.invalidate(_reviewVideoResolutionProvider(widget.recordId));
    ref.invalidate(surgeryAnalysisProvider);
  }

  void _refreshVideo() {
    ref.invalidate(_reviewVideoResolutionProvider(widget.recordId));
  }

  Widget _buildInitialLoadFailure(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
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
  final VoidCallback onTogglePlayback;

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
