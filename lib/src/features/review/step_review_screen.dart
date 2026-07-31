import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../data/providers.dart';
import '../../domain/duration_formatters.dart';
import '../../domain/surgery_models.dart';
import '../../domain/video_seek_coordinator.dart';

enum _LeaveAction { cancel, discard, save }

class StepReviewScreen extends ConsumerStatefulWidget {
  const StepReviewScreen({required this.recordId, super.key});

  final String recordId;

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
  String? _loadedRecordId;
  String? _videoErrorMessage;
  double _playbackSpeed = 1;
  SurgicalStep? _savingStep;
  bool _isSavingReview = false;
  bool _isDirty = false;

  SurgeryRecord? _latestRecord;
  List<SurgicalStepReview>? _latestReviews;

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
  }

  @override
  void dispose() {
    _tabController.dispose();
    _videoSeekCoordinator?.dispose();
    _videoController?.dispose();
    _caseMemoController.dispose();
    for (final controller in _reflectionControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recordAsync = ref.watch(surgeryRecordProvider(widget.recordId));
    final reviewsAsync = ref.watch(stepReviewsProvider(widget.recordId));
    final videoFile = ref.watch(recordVideoFileProvider(widget.recordId));

    final record = recordAsync.hasValue ? recordAsync.value : null;
    final reviews = reviewsAsync.hasValue ? reviewsAsync.value : null;

    final Widget body;
    if (recordAsync.hasError) {
      body = Center(child: Text('症例読み込み失敗: ${recordAsync.error}'));
    } else if (reviewsAsync.hasError) {
      body = Center(child: Text('工程読み込み失敗: ${reviewsAsync.error}'));
    } else if (record == null || reviews == null) {
      if (recordAsync.hasValue && record == null) {
        body = const Center(child: Text('症例が見つかりません'));
      } else {
        body = const Center(child: CircularProgressIndicator());
      }
    } else {
      _syncInitialState(record, reviews);
      _latestRecord = record;
      _latestReviews = reviews;
      body = _buildBody(record, reviews, videoFile);
    }

    final readyRecord = record;
    final readyReviews = reviews;

    return PopScope<void>(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
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
                onPressed:
                    (_isSavingReview ||
                        readyRecord == null ||
                        readyReviews == null)
                    ? null
                    : () => _saveReview(readyRecord, readyReviews),
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
        body: body,
      ),
    );
  }

  Widget _buildBody(
    SurgeryRecord record,
    List<SurgicalStepReview> reviews,
    AsyncValue<File?> videoFile,
  ) {
    final byStep = {for (final review in reviews) review.step: review};

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _buildVideoSection(record, videoFile),
          ),
          TabBar(
            controller: _tabController,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              for (final step in surgicalStepsInDisplayOrder)
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (byStep[step]!.isCompleted) ...[
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
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                for (final step in surgicalStepsInDisplayOrder)
                  ListView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.all(16),
                    children: [
                      ProcedureTimingCard(
                        step: step,
                        timing: byStep[step]!,
                        isSaving: _savingStep == step,
                        onStart: () => _startStep(byStep[step]!, reviews),
                        onEnd: () => _endStep(byStep[step]!),
                        onReset: () => _resetStep(byStep[step]!),
                        onTapStart: byStep[step]!.startMilliseconds == null
                            ? null
                            : () => _seekToMilliseconds(
                                byStep[step]!.startMilliseconds!,
                              ),
                        onTapEnd: byStep[step]!.endMilliseconds == null
                            ? null
                            : () => _seekToMilliseconds(
                                byStep[step]!.endMilliseconds!,
                              ),
                      ),
                      const SizedBox(height: 12),
                      _StepNotesCard(
                        rating: _ratings[step] ?? StepRating.unreviewed,
                        controller: _reflectionControllers[step]!,
                        onRatingChanged: (value) {
                          setState(() {
                            _ratings[step] = value;
                            _isDirty = true;
                          });
                        },
                      ),
                    ],
                  ),
                ListView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.all(16),
                  children: [
                    TextField(
                      controller: _caseMemoController,
                      minLines: 3,
                      maxLines: 8,
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
    );
  }

  Widget _buildVideoSection(SurgeryRecord record, AsyncValue<File?> videoFile) {
    return videoFile.when(
      data: (file) {
        if (file == null) {
          final message = record.videoPath == null
              ? '動画が登録されていません。動画を選択してください。'
              : '保存された動画が見つかりません。動画を再選択してください。';
          return _buildVideoNotice(message, showPicker: true);
        }
        _ensureVideoController(file);
        final errorMessage = _videoErrorMessage;
        if (errorMessage != null) {
          return _buildVideoNotice(errorMessage, showPicker: true);
        }
        final controller = _videoController;
        if (controller == null || !controller.value.isInitialized) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (controller.value.hasError) {
          return _buildVideoNotice(
            '動画の再生中にエラーが発生しました。別の動画を選択するか、もう一度お試しください。',
            showPicker: true,
          );
        }
        return _buildVideoPlayer(controller);
      },
      error: (error, _) =>
          _buildVideoNotice('動画情報の読み込みに失敗しました。', showPicker: false),
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Widget _buildVideoNotice(String message, {required bool showPicker}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(message, textAlign: TextAlign.center),
            if (showPicker) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _pickVideoFromReview,
                icon: const Icon(Icons.video_call_outlined),
                label: const Text('動画を選択'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildVideoPlayer(VideoPlayerController controller) {
    final position = controller.value.position;
    final duration = controller.value.duration;
    final durationMs = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final positionMs = position.inMilliseconds.toDouble().clamp(
      0.0,
      durationMs,
    );

    return Column(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: Center(
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: ColoredBox(
                color: Colors.black,
                child: VideoPlayer(controller),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                '${formatTimelineMilliseconds(position.inMilliseconds)} / '
                '${formatTimelineMilliseconds(duration.inMilliseconds)}',
              ),
            ),
            PopupMenuButton<double>(
              tooltip: '再生速度を変更',
              initialValue: _playbackSpeed,
              onSelected: _setPlaybackSpeed,
              itemBuilder: (context) => [
                for (final speed in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                  PopupMenuItem<double>(value: speed, child: Text('${speed}x')),
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
          value: positionMs,
          max: durationMs,
          onChanged: (value) {
            _seekToMilliseconds(value.round());
          },
        ),
        VideoTransportControls(
          isPlaying: controller.value.isPlaying,
          onSeekBackward5: () => _seekRelative(const Duration(seconds: -5)),
          onSeekForward5: () => _seekRelative(const Duration(seconds: 5)),
          onSeekBackward15: () => _seekRelative(const Duration(seconds: -15)),
          onSeekForward15: () => _seekRelative(const Duration(seconds: 15)),
          onTogglePlayback: _togglePlayback,
        ),
      ],
    );
  }

  void _ensureVideoController(File file) {
    if (_loadedVideoPath == file.path) {
      return;
    }
    _loadedVideoPath = file.path;
    _videoSeekCoordinator?.dispose();
    _videoController?.dispose();
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
        .then((_) {
          controller.setPlaybackSpeed(_playbackSpeed);
          if (mounted) {
            setState(() {});
          }
        })
        .catchError((Object error) {
          if (mounted) {
            setState(() {
              _videoErrorMessage = '動画を再生できませんでした。動画ファイルを確認するか、別の動画を選択してください。';
            });
          }
        });
    controller.addListener(_onVideoPositionChanged);
  }

  void _onVideoPositionChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _seekRelative(Duration offset) async {
    final controller = _videoController;
    final seekCoordinator = _videoSeekCoordinator;
    if (controller == null ||
        seekCoordinator == null ||
        !controller.value.isInitialized) {
      return;
    }
    await seekCoordinator.seekRelative(offset);
  }

  Future<void> _seekToMilliseconds(int milliseconds) async {
    final controller = _videoController;
    final seekCoordinator = _videoSeekCoordinator;
    if (controller == null ||
        seekCoordinator == null ||
        !controller.value.isInitialized) {
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

  Future<void> _pickVideoFromReview() async {
    final FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['mp4', 'mov', 'm4v'],
      );
    } catch (_) {
      _showMessage('動画を選択できませんでした。もう一度お試しください。');
      return;
    }
    final path = result?.files.single.path;
    if (result == null || path == null) {
      return;
    }
    final fileName = result.files.single.name;
    try {
      await ref
          .read(recordVideoServiceProvider)
          .importVideoForRecord(
            surgeryRecordId: widget.recordId,
            sourcePath: path,
            originalFileName: fileName,
          );
      ref.invalidate(recordVideoFileProvider(widget.recordId));
      ref.invalidate(surgeryRecordProvider(widget.recordId));
      ref.invalidate(surgeryRecordsProvider);
      ref.invalidate(stepReviewsProvider(widget.recordId));
      ref.invalidate(surgeryAnalysisProvider);
    } catch (error) {
      _showMessage(_describeVideoError(error));
    }
  }

  String _describeVideoError(Object error) {
    if (error is ArgumentError) {
      return 'この動画形式は再生できません。MP4形式などに変換してから、もう一度選択してください。';
    }
    if (error is FileSystemException) {
      return '動画を保存できませんでした。ストレージの空き容量をご確認ください。';
    }
    return '動画を保存できませんでした。もう一度お試しください。';
  }

  void _syncInitialState(
    SurgeryRecord record,
    List<SurgicalStepReview> reviews,
  ) {
    if (_loadedRecordId != widget.recordId) {
      _loadedRecordId = widget.recordId;
      _caseMemoController.text = record.caseMemo;
      _caseMemoController.addListener(_markDirty);
      for (final review in reviews) {
        _ratings[review.step] = review.rating;
        final controller = TextEditingController(text: review.reflection);
        controller.addListener(_markDirty);
        _reflectionControllers[review.step] = controller;
      }
      _isDirty = false;
      final firstIncomplete = reviews.indexWhere(
        (review) => !review.isCompleted,
      );
      if (firstIncomplete > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _tabController.index == 0) {
            _tabController.index = firstIncomplete;
          }
        });
      }
    }
  }

  void _markDirty() {
    if (!_isDirty) {
      setState(() => _isDirty = true);
    }
  }

  Future<void> _startStep(
    SurgicalStepReview review,
    List<SurgicalStepReview> reviews,
  ) async {
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
      );
      return;
    }
    await _saveTiming(
      review.copyWith(startMilliseconds: _currentMilliseconds, clearEnd: true),
    );
  }

  Future<void> _endStep(SurgicalStepReview review) async {
    final start = review.startMilliseconds;
    if (start == null || _currentMilliseconds <= start) {
      _showMessage('終了時刻は開始時刻より後に設定してください。');
      return;
    }
    await _saveTiming(review.copyWith(endMilliseconds: _currentMilliseconds));
  }

  Future<void> _resetStep(SurgicalStepReview review) async {
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
      await _saveTiming(review.copyWith(clearStart: true, clearEnd: true));
    }
  }

  Future<void> _saveTiming(SurgicalStepReview review) async {
    if (_savingStep != null) {
      return;
    }
    setState(() => _savingStep = review.step);
    try {
      await ref.read(surgeryRepositoryProvider).saveStepReview(review);
      ref.invalidate(stepReviewsProvider(widget.recordId));
      ref.invalidate(surgeryRecordProvider(widget.recordId));
      ref.invalidate(surgeryRecordsProvider);
      ref.invalidate(surgeryAnalysisProvider);
    } catch (_) {
      _showMessage('計測結果を保存できませんでした。もう一度お試しください。');
    } finally {
      if (mounted) {
        setState(() => _savingStep = null);
      }
    }
  }

  Future<void> _saveReview(
    SurgeryRecord record,
    List<SurgicalStepReview> reviews,
  ) async {
    setState(() => _isSavingReview = true);
    try {
      for (final review in reviews) {
        final rating = _ratings[review.step] ?? review.rating;
        final reflection =
            _reflectionControllers[review.step]?.text.trim() ??
            review.reflection;
        if (rating != review.rating || reflection != review.reflection) {
          await ref
              .read(surgeryRepositoryProvider)
              .saveStepReview(
                review.copyWith(rating: rating, reflection: reflection),
              );
        }
      }
      await ref
          .read(surgeryRepositoryProvider)
          .updateCaseMemo(
            surgeryRecordId: widget.recordId,
            caseMemo: _caseMemoController.text.trim(),
          );
      ref.invalidate(stepReviewsProvider(widget.recordId));
      ref.invalidate(surgeryRecordProvider(widget.recordId));
      ref.invalidate(surgeryRecordsProvider);
      if (mounted) {
        setState(() => _isDirty = false);
      }
      _showMessage('レビューを保存しました');
    } catch (_) {
      _showMessage('レビューを保存できませんでした。');
    } finally {
      if (mounted) {
        setState(() => _isSavingReview = false);
      }
    }
  }

  Future<void> _handleLeaveAttempt() async {
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
            onPressed: () => Navigator.pop(context, _LeaveAction.save),
            child: const Text('保存して閉じる'),
          ),
        ],
      ),
    );
    if (!mounted || action == null || action == _LeaveAction.cancel) {
      return;
    }
    if (action == _LeaveAction.save) {
      final record = _latestRecord;
      final reviews = _latestReviews;
      if (record != null && reviews != null) {
        await _saveReview(record, reviews);
      }
    }
    if (mounted) {
      setState(() => _isDirty = false);
      Navigator.of(context).pop();
    }
  }

  void _showMessage(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class _StepNotesCard extends StatelessWidget {
  const _StepNotesCard({
    required this.rating,
    required this.controller,
    required this.onRatingChanged,
  });

  final StepRating rating;
  final TextEditingController controller;
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
                onChanged: (value) {
                  if (value != null) {
                    onRatingChanged(value);
                  }
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                minLines: 2,
                maxLines: 5,
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
  final VoidCallback onSeekBackward5;
  final VoidCallback onSeekForward5;
  final VoidCallback onSeekBackward15;
  final VoidCallback onSeekForward15;
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
  final VoidCallback onPressed;
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
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: semanticsLabel,
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
    this.onTapStart,
    this.onTapEnd,
    super.key,
  });

  final SurgicalStep step;
  final SurgicalStepReview timing;
  final bool isSaving;
  final VoidCallback onStart;
  final VoidCallback onEnd;
  final VoidCallback onReset;
  final VoidCallback? onTapStart;
  final VoidCallback? onTapEnd;

  @override
  Widget build(BuildContext context) {
    final startText = Text(
      '開始時刻：${formatTimelineMilliseconds(timing.startMilliseconds)}',
    );
    final endText = Text(
      '終了時刻：${formatTimelineMilliseconds(timing.endMilliseconds)}',
    );
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
                if (timing.isRunning)
                  const Chip(
                    avatar: Icon(Icons.timer_outlined, size: 18),
                    label: Text('計測中'),
                  ),
              ],
            ),
            if (timing.isRunning) ...[
              onTapStart == null
                  ? startText
                  : InkWell(onTap: onTapStart, child: startText),
              const SizedBox(height: 16),
            ] else if (timing.isCompleted) ...[
              onTapStart == null
                  ? startText
                  : InkWell(onTap: onTapStart, child: startText),
              onTapEnd == null
                  ? endText
                  : InkWell(onTap: onTapEnd, child: endText),
              Text('所要時間：${formatProcedureDuration(timing.duration)}'),
              const SizedBox(height: 16),
            ] else
              const SizedBox(height: 12),
            if (isSaving)
              const SizedBox(
                height: 56,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (timing.isNotStarted)
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton.icon(
                  key: const Key('procedure-start-button'),
                  onPressed: onStart,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('この工程を開始'),
                ),
              )
            else if (timing.isRunning)
              SizedBox(
                width: double.infinity,
                height: 56,
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
              )
            else
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: onReset,
                  icon: const Icon(Icons.refresh),
                  label: const Text('再設定'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
