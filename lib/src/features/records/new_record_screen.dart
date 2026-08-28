import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

import '../../data/providers.dart';
import '../../data/video_import_models.dart';
import '../../domain/surgery_models.dart';
import '../../widgets/video_surface.dart';
import '../video_import/video_import_screen_flow.dart';
import '../video_import/video_import_ui_flow.dart';
import 'record_detail_screen.dart';

class NewRecordScreen extends ConsumerStatefulWidget {
  const NewRecordScreen({
    required this.initialVideo,
    this.enableVideoPreview = true,
    super.key,
  });

  final VerifiedVideoCandidate initialVideo;
  final bool enableVideoPreview;

  @override
  ConsumerState<NewRecordScreen> createState() => _NewRecordScreenState();
}

class _NewRecordScreenState extends ConsumerState<NewRecordScreen> {
  static const _previewInitializationTimeout = Duration(seconds: 10);
  static const _previewDisposalTimeout = Duration(seconds: 2);

  late VerifiedVideoCandidate _selectedVideo = widget.initialVideo;
  late final VideoImportUiFlow _videoImportFlow;
  final VideoImportOperationController _videoImportOperationController =
      VideoImportOperationController();
  DateTime? _surgeryDate;
  EyeSide? _eyeSide;
  VideoPlayerController? _videoController;
  VideoImportCancellationToken? _pendingPreviewCancellation;
  String? _videoErrorMessage;
  VideoImportException? _lastVideoImportError;
  bool _isVideoLoading = true;
  bool _isSelectingVideo = false;
  bool _isSaving = false;
  bool _isShowingDiscardDialog = false;
  bool _allowPop = false;
  bool _videoWasChanged = false;
  bool _hasAttemptedRegistration = false;
  String? _validationAnnouncement;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _dateFieldKey = GlobalKey();
  final GlobalKey _eyeFieldKey = GlobalKey();

  bool get _canAttemptRegistration => !_isSaving && !_isSelectingVideo;

  @override
  void initState() {
    super.initState();
    _videoImportFlow = VideoImportUiFlow(
      picker: ref.read(surgeryVideoPickerProvider),
      preflight: ref.read(videoImportPreflightProvider),
    );
    if (widget.enableVideoPreview) {
      final cancellationToken = VideoImportCancellationToken();
      _pendingPreviewCancellation = cancellationToken;
      unawaited(_loadInitialVideo(_selectedVideo, cancellationToken));
    } else {
      _isVideoLoading = false;
    }
  }

  @override
  void dispose() {
    _videoImportFlow.dispose();
    _videoImportOperationController.dispose();
    _pendingPreviewCancellation?.cancel();
    _scrollController.dispose();
    final controller = _videoController;
    if (controller != null) {
      controller.removeListener(_onVideoStateChanged);
      unawaited(controller.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_confirmDiscard());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('新規症例'),
          actions: const [VideoRegistrationHelpButton()],
        ),
        body: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.all(16),
          children: [
            if (_validationAnnouncement case final message?)
              Semantics(
                liveRegion: true,
                label: message,
                child: const SizedBox.shrink(),
              ),
            Text('選択した動画', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _buildVideoPreview(),
            if (_videoErrorMessage != null) ...[
              const SizedBox(height: 8),
              const Text(
                'プレビューのみ失敗しました。登録時には動画を再検証します。'
                '必要に応じて動画を変更してください。',
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _selectedVideo.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _isSaving || _isSelectingVideo
                      ? null
                      : _changeVideo,
                  icon: const Icon(Icons.video_file_outlined),
                  label: const Text('動画を変更'),
                ),
              ],
            ),
            if (_lastVideoImportError case final error?) ...[
              const SizedBox(height: 8),
              VideoImportPersistentErrorNotice(
                error: error,
                onReselect: _isSaving || _isSelectingVideo
                    ? null
                    : _changeVideo,
              ),
            ],
            if (_videoWasChanged &&
                (_surgeryDate == null || _eyeSide == null)) ...[
              const SizedBox(height: 12),
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline),
                      SizedBox(width: 8),
                      Expanded(child: Text('動画を変更したため、手術日と左右眼を再確認してください。')),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Column(
              key: _dateFieldKey,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: ListTile(
                    title: const Text('手術日（必須）'),
                    subtitle: Text(
                      _surgeryDate == null
                          ? '未選択'
                          : DateFormat(
                              'yyyy/MM/dd',
                              'ja_JP',
                            ).format(_surgeryDate!),
                    ),
                    trailing: const Icon(Icons.calendar_today),
                    onTap: _isSaving || _isSelectingVideo ? null : _pickDate,
                  ),
                ),
                if (_hasAttemptedRegistration && _surgeryDate == null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '手術日を選択してください',
                    key: const Key('surgery-date-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            Column(
              key: _eyeFieldKey,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('左右眼（必須）', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SegmentedButton<EyeSide>(
                  segments: EyeSide.values
                      .map(
                        (side) => ButtonSegment<EyeSide>(
                          value: side,
                          label: Text(side.label),
                        ),
                      )
                      .toList(),
                  selected: _eyeSide == null ? const {} : {_eyeSide!},
                  emptySelectionAllowed: true,
                  onSelectionChanged: _isSaving || _isSelectingVideo
                      ? null
                      : (selection) {
                          setState(() {
                            _eyeSide = selection.isEmpty
                                ? null
                                : selection.single;
                            _validationAnnouncement = _firstValidationMessage();
                          });
                        },
                ),
                if (_hasAttemptedRegistration && _eyeSide == null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '右眼または左眼を選択してください',
                    key: const Key('eye-side-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 28),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: FilledButton.icon(
                key: const Key('register-record-button'),
                onPressed: _canAttemptRegistration ? _save : null,
                icon: _isSaving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: Text(
                  _isSaving
                      ? '登録中…'
                      : _isSelectingVideo
                      ? '動画を確認中…'
                      : '症例を登録',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoPreview() {
    if (!widget.enableVideoPreview) {
      return const VideoSurface(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Center(child: Icon(Icons.video_file, size: 48)),
        ),
      );
    }
    if (_isVideoLoading) {
      return const VideoSurface(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('動画を確認しています…'),
              ],
            ),
          ),
        ),
      );
    }
    final error = _videoErrorMessage;
    if (error != null) {
      return VideoSurface(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 40),
                  const SizedBox(height: 8),
                  const Text('プレビューできません'),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final controller = _videoController;
    if (controller == null) {
      return const VideoSurface(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Center(child: Text('プレビューを準備しています…')),
        ),
      );
    }
    return _VideoPreview(controller: controller);
  }

  Future<void> _loadInitialVideo(
    VerifiedVideoCandidate candidate,
    VideoImportCancellationToken cancellationToken,
  ) async {
    try {
      final controller = await _initializePreviewController(
        candidate,
        cancellationToken: cancellationToken,
      );
      if (!mounted ||
          !identical(_pendingPreviewCancellation, cancellationToken)) {
        await _disposeVideoController(controller);
        return;
      }
      controller.addListener(_onVideoStateChanged);
      setState(() {
        _videoController = controller;
        _videoErrorMessage = null;
        _isVideoLoading = false;
      });
    } on Object {
      if (!mounted ||
          !identical(_pendingPreviewCancellation, cancellationToken)) {
        return;
      }
      setState(() {
        _isVideoLoading = false;
        _videoErrorMessage = 'プレビューできません';
      });
    } finally {
      if (identical(_pendingPreviewCancellation, cancellationToken)) {
        _pendingPreviewCancellation = null;
      }
    }
  }

  void _onVideoStateChanged() {
    if (!mounted) {
      return;
    }
    final controller = _videoController;
    if ((controller?.value.hasError ?? false) && _videoErrorMessage == null) {
      setState(() {
        _isVideoLoading = false;
        _videoErrorMessage = 'プレビューできません';
      });
    }
  }

  Future<void> _changeVideo() async {
    if (_isSaving || _isSelectingVideo || _videoImportFlow.isActive) {
      return;
    }
    setState(() => _isSelectingVideo = true);
    final currentController = _videoController;
    try {
      if (currentController?.value.isPlaying ?? false) {
        try {
          await currentController!.pause();
        } on Object {
          // Selection can continue even if the old platform player has ended.
        }
      }

      while (true) {
        if (!mounted) {
          return;
        }
        final candidate = await selectVerifiedVideoForScreen(
          context: context,
          flow: _videoImportFlow,
          entryPoint: VideoImportEntryPoint.create,
          onPersistentFailure: _rememberVideoImportFailure,
          dataInvariantSuffix:
              VideoImportDataInvariantSuffix.createNotRegistered,
        );
        if (candidate == null || !mounted) {
          return;
        }

        final previousCancellation = _pendingPreviewCancellation;
        _pendingPreviewCancellation = null;
        previousCancellation?.cancel();
        await _commitVideoChange(
          candidate,
          null,
          isPreviewLoading: widget.enableVideoPreview,
        );
        if (!mounted || !widget.enableVideoPreview) {
          return;
        }
        final cancellationToken = VideoImportCancellationToken();
        _pendingPreviewCancellation = cancellationToken;
        unawaited(_loadInitialVideo(candidate, cancellationToken));
        return;
      }
    } finally {
      if (mounted) {
        setState(() => _isSelectingVideo = false);
      }
    }
  }

  Future<VideoPlayerController> _initializePreviewController(
    VerifiedVideoCandidate candidate, {
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    cancellationToken?.throwIfCancelled(VideoImportPhase.sourcePlayback);
    onProgress?.call(
      const VideoImportProgress(phase: VideoImportPhase.sourcePlayback),
    );
    final controller = VideoPlayerController.file(File(candidate.path));
    try {
      await Future.any<void>([
        controller.initialize(),
        if (cancellationToken != null)
          cancellationToken.whenCancelled.then<void>((_) {
            cancellationToken.throwIfCancelled(VideoImportPhase.sourcePlayback);
          }),
      ]).timeout(
        _previewInitializationTimeout,
        onTimeout: () =>
            throw _previewFailure(VideoImportInternalReasonV1.stageTimeout),
      );
      cancellationToken?.throwIfCancelled(VideoImportPhase.sourcePlayback);
      if (!controller.value.isInitialized || controller.value.hasError) {
        throw _previewFailure(VideoImportInternalReasonV1.playerInitFailed);
      }
      if (controller.value.duration <= Duration.zero) {
        throw _previewFailure(
          VideoImportInternalReasonV1.playerInvalidDuration,
        );
      }
      return controller;
    } on VideoImportException {
      await _disposeVideoController(controller);
      rethrow;
    } on Object {
      await _disposeVideoController(controller);
      throw _previewFailure(VideoImportInternalReasonV1.playerInitFailed);
    }
  }

  Future<void> _commitVideoChange(
    VerifiedVideoCandidate candidate,
    VideoPlayerController? controller, {
    bool isPreviewLoading = false,
  }) async {
    if (!mounted) {
      if (controller != null) {
        await _disposeVideoController(controller);
      }
      return;
    }
    final previous = _videoController;
    previous?.removeListener(_onVideoStateChanged);
    controller?.addListener(_onVideoStateChanged);
    setState(() {
      _selectedVideo = candidate;
      _videoController = controller;
      _videoErrorMessage = null;
      _lastVideoImportError = null;
      _isVideoLoading = isPreviewLoading;
      _surgeryDate = null;
      _eyeSide = null;
      _videoWasChanged = true;
      _hasAttemptedRegistration = false;
      _validationAnnouncement = null;
    });
    if (previous != null) {
      await _disposeVideoController(previous);
    }
  }

  Future<void> _disposeVideoController(VideoPlayerController controller) async {
    try {
      await controller.dispose().timeout(_previewDisposalTimeout);
    } on Object {
      // Disposal is best-effort after the controller has left visible state.
    }
  }

  VideoImportException _previewFailure(VideoImportInternalReasonV1 reason) {
    return VideoImportException(
      code: VideoImportErrorCode.unplayableMedia,
      entryPoint: VideoImportEntryPoint.create,
      phase: VideoImportPhase.sourcePlayback,
      internalReason: reason,
      primaryRecoveryAction: VideoImportRecoveryAction.checkSourceAndReselect,
      dataInvariantSuffix: VideoImportDataInvariantSuffix.createNotRegistered,
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _surgeryDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null && mounted) {
      setState(() {
        _surgeryDate = picked;
        _validationAnnouncement = _firstValidationMessage();
      });
    }
  }

  String? _firstValidationMessage() {
    if (!_hasAttemptedRegistration) {
      return null;
    }
    if (_surgeryDate == null) {
      return '手術日を選択してください';
    }
    if (_eyeSide == null) {
      return '右眼または左眼を選択してください';
    }
    return null;
  }

  Future<void> _save() async {
    final surgeryDate = _surgeryDate;
    final eyeSide = _eyeSide;
    if (!_canAttemptRegistration) {
      return;
    }
    if (surgeryDate == null || eyeSide == null) {
      final firstMessage = surgeryDate == null
          ? '手術日を選択してください'
          : '右眼または左眼を選択してください';
      setState(() {
        _hasAttemptedRegistration = true;
        _validationAnnouncement = firstMessage;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        final targetContext =
            (surgeryDate == null ? _dateFieldKey : _eyeFieldKey).currentContext;
        if (targetContext != null) {
          unawaited(
            Scrollable.ensureVisible(
              targetContext,
              duration: const Duration(milliseconds: 200),
              alignment: 0.25,
            ),
          );
        }
      });
      return;
    }
    setState(() => _isSaving = true);
    var shouldReselectVideo = false;
    try {
      while (true) {
        if (!mounted) {
          return;
        }
        final result =
            await runVideoImportOperationForScreen<
              VideoImportOutcome<SurgeryRecord>
            >(
              context: context,
              entryPoint: VideoImportEntryPoint.create,
              dataInvariantSuffix:
                  VideoImportDataInvariantSuffix.createNotRegistered,
              operationController: _videoImportOperationController,
              onPersistentFailure: _rememberVideoImportFailure,
              operation: (cancellationToken, onProgress) {
                return ref
                    .read(recordVideoServiceProvider)
                    .createRecordWithVideo(
                      surgeryDate: surgeryDate,
                      eyeSide: eyeSide,
                      candidate: _selectedVideo,
                      cancellationToken: cancellationToken,
                      onProgress: onProgress,
                    );
              },
            );
        switch (result) {
          case VideoImportScreenOperationSuccess(:final value):
            final record = value.value;
            ref.invalidate(surgeryRecordsProvider);
            ref.invalidate(surgeryRecordProgressProvider);
            ref.invalidate(surgeryAnalysisProvider);
            ref.invalidate(videoStorageMaintenanceProvider);
            if (!mounted) {
              return;
            }
            if (value.maintenanceOutcome == VideoMaintenanceOutcome.pending) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('症例の登録は完了しました。動画の後処理は次回起動時に再試行します。'),
                ),
              );
            }
            setState(() => _allowPop = true);
            unawaited(
              Navigator.of(context).pushReplacement<void, void>(
                MaterialPageRoute<void>(
                  builder: (_) => RecordDetailScreen(recordId: record.id),
                ),
              ),
            );
            return;
          case VideoImportScreenOperationCancelled():
            return;
          case VideoImportScreenOperationFailure(:final recoveryAction):
            shouldReselectVideo = videoImportRecoveryRequestsReselection(
              recoveryAction,
            );
            if (shouldReselectVideo) {
              break;
            }
            if (_retriesImport(recoveryAction)) {
              continue;
            }
            return;
        }
        break;
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
    if (shouldReselectVideo && mounted) {
      await _changeVideo();
    }
  }

  bool _retriesImport(VideoImportRecoveryAction action) {
    return action == VideoImportRecoveryAction.retry ||
        action == VideoImportRecoveryAction.unlockAndRetry ||
        action == VideoImportRecoveryAction.freeStorageAndRetry;
  }

  void _rememberVideoImportFailure(VideoImportException error) {
    if (mounted) {
      setState(() => _lastVideoImportError = error);
    }
  }

  Future<void> _confirmDiscard() async {
    if (_isSaving || _isSelectingVideo || _isShowingDiscardDialog) {
      return;
    }
    _isShowingDiscardDialog = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('入力内容を破棄しますか？'),
        content: const Text('症例はまだ登録されていません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('破棄'),
          ),
        ],
      ),
    );
    _isShowingDiscardDialog = false;
    if (discard == true && mounted) {
      setState(() => _allowPop = true);
      Navigator.of(context).pop();
    }
  }
}

class _VideoPreview extends StatefulWidget {
  const _VideoPreview({required this.controller});

  final VideoPlayerController controller;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  double? _dragMilliseconds;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final durationMilliseconds = value.duration.inMilliseconds;
        final maximum = durationMilliseconds > 0
            ? durationMilliseconds.toDouble()
            : 1.0;
        final position = (_dragMilliseconds ?? value.position.inMilliseconds)
            .clamp(0, maximum)
            .toDouble();
        final displayPosition = Duration(milliseconds: position.round());
        final aspectRatio = value.aspectRatio > 0 ? value.aspectRatio : 16 / 9;
        return VideoSurface(
          child: Column(
            children: [
              AspectRatio(
                aspectRatio: aspectRatio,
                child: VideoPlayer(widget.controller),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Column(
                  children: [
                    Slider(
                      key: const Key('new-record-video-slider'),
                      value: position,
                      max: maximum,
                      semanticFormatterCallback: (_) =>
                          '${_formatPosition(displayPosition)} / '
                          '${_formatPosition(value.duration)}',
                      onChangeStart: (newValue) {
                        setState(() => _dragMilliseconds = newValue);
                      },
                      onChanged: (newValue) {
                        setState(() => _dragMilliseconds = newValue);
                      },
                      onChangeEnd: (newValue) =>
                          unawaited(_commitSeek(newValue)),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${_formatPosition(displayPosition)} / '
                            '${_formatPosition(value.duration)}',
                            key: const Key('new-record-video-position'),
                          ),
                        ),
                        IconButton.filled(
                          tooltip: value.isPlaying ? '一時停止' : '再生',
                          onPressed: () {
                            value.isPlaying
                                ? unawaited(widget.controller.pause())
                                : unawaited(widget.controller.play());
                          },
                          icon: Icon(
                            value.isPlaying ? Icons.pause : Icons.play_arrow,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _commitSeek(double milliseconds) async {
    final controller = widget.controller;
    setState(() => _dragMilliseconds = milliseconds);
    try {
      await controller.seekTo(Duration(milliseconds: milliseconds.round()));
    } finally {
      if (mounted && identical(controller, widget.controller)) {
        setState(() => _dragMilliseconds = null);
      }
    }
  }

  String _formatPosition(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
