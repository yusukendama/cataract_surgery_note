import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../data/providers.dart';
import '../../domain/surgery_models.dart';

enum _LeaveAction { cancel, discard, save }

class StepReviewScreen extends ConsumerStatefulWidget {
  const StepReviewScreen({required this.recordId, super.key});

  final String recordId;

  @override
  ConsumerState<StepReviewScreen> createState() => _StepReviewScreenState();
}

class _StepReviewScreenState extends ConsumerState<StepReviewScreen> {
  final TextEditingController _caseMemoController = TextEditingController();
  final Map<SurgicalStep, TextEditingController> _reflectionControllers = {};
  final Map<SurgicalStep, StepRating> _ratings = {};

  VideoPlayerController? _videoController;
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
      _videoController?.value.position.inMilliseconds ?? 0;

  @override
  void dispose() {
    _videoController?.dispose();
    _caseMemoController.dispose();
    for (final controller in _reflectionControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final record = ref.watch(surgeryRecordProvider(widget.recordId));
    final reviews = ref.watch(stepReviewsProvider(widget.recordId));
    final videoFile = ref.watch(recordVideoFileProvider(widget.recordId));

    return PopScope<void>(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
          return;
        }
        await _handleLeaveAttempt();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('手術工程の時間記録')),
        body: record.when(
          data: (item) {
            if (item == null) {
              return const Center(child: Text('症例が見つかりません'));
            }
            return reviews.when(
              data: (items) {
                _syncInitialState(item, items);
                _latestRecord = item;
                _latestReviews = items;
                return _buildBody(item, items, videoFile);
              },
              error: (error, _) => Center(child: Text('工程読み込み失敗: $error')),
              loading: () => const Center(child: CircularProgressIndicator()),
            );
          },
          error: (error, _) => Center(child: Text('症例読み込み失敗: $error')),
          loading: () => const Center(child: CircularProgressIndicator()),
        ),
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
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(16),
        children: [
          _buildVideoSection(record, videoFile),
          const SizedBox(height: 20),
          for (final step in surgicalStepsInDisplayOrder) ...[
            ProcedureTimingCard(
              step: step,
              timing: byStep[step]!,
              isSaving: _savingStep == step,
              onStart: () => _startStep(byStep[step]!, reviews),
              onEnd: () => _endStep(byStep[step]!),
              onReset: () => _resetStep(byStep[step]!),
              onTapStart: byStep[step]!.startMilliseconds == null
                  ? null
                  : () => _seekToMilliseconds(byStep[step]!.startMilliseconds!),
              onTapEnd: byStep[step]!.endMilliseconds == null
                  ? null
                  : () => _seekToMilliseconds(byStep[step]!.endMilliseconds!),
            ),
            _StepNotesTile(
              rating: _ratings[step] ?? StepRating.unreviewed,
              controller: _reflectionControllers[step]!,
              onRatingChanged: (value) {
                setState(() {
                  _ratings[step] = value;
                  _isDirty = true;
                });
              },
            ),
            const SizedBox(height: 12),
          ],
          const Divider(height: 32),
          Text('症例メモ', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _caseMemoController,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '症例全体のメモ',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _isSavingReview
                ? null
                : () => _saveReview(record, reviews),
            icon: _isSavingReview
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            label: const Text('レビューを保存'),
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
    final positionMs = position.inMilliseconds.toDouble().clamp(0.0, durationMs);

    return Column(
      children: [
        AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: ColoredBox(color: Colors.black, child: VideoPlayer(controller)),
        ),
        const SizedBox(height: 8),
        Text(
          '${formatTimelineMilliseconds(position.inMilliseconds)} / '
          '${formatTimelineMilliseconds(duration.inMilliseconds)}',
        ),
        Slider(
          value: positionMs,
          max: durationMs,
          onChanged: (value) {
            controller.seekTo(Duration(milliseconds: value.round()));
          },
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            IconButton.filledTonal(
              tooltip: '1秒戻る',
              onPressed: () => _seekRelative(const Duration(seconds: -1)),
              icon: const Icon(Icons.keyboard_double_arrow_left),
            ),
            IconButton.filledTonal(
              tooltip: '0.2秒戻る',
              onPressed: () =>
                  _seekRelative(const Duration(milliseconds: -200)),
              icon: const Icon(Icons.keyboard_arrow_left),
            ),
            IconButton.filled(
              tooltip: controller.value.isPlaying ? '一時停止' : '再生',
              onPressed: _togglePlayback,
              icon: Icon(
                controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
            ),
            IconButton.filledTonal(
              tooltip: '0.2秒進む',
              onPressed: () =>
                  _seekRelative(const Duration(milliseconds: 200)),
              icon: const Icon(Icons.keyboard_arrow_right),
            ),
            IconButton.filledTonal(
              tooltip: '1秒進む',
              onPressed: () => _seekRelative(const Duration(seconds: 1)),
              icon: const Icon(Icons.keyboard_double_arrow_right),
            ),
          ],
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<double>(
          initialValue: _playbackSpeed,
          decoration: const InputDecoration(labelText: '再生速度'),
          items: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
              .map(
                (speed) => DropdownMenuItem<double>(
                  value: speed,
                  child: Text('${speed}x'),
                ),
              )
              .toList(),
          onChanged: (speed) {
            if (speed != null) {
              _setPlaybackSpeed(speed);
            }
          },
        ),
      ],
    );
  }

  void _ensureVideoController(File file) {
    if (_loadedVideoPath == file.path) {
      return;
    }
    _loadedVideoPath = file.path;
    _videoController?.dispose();
    _videoErrorMessage = null;
    final controller = VideoPlayerController.file(file);
    _videoController = controller;
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
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    final duration = controller.value.duration;
    final current = controller.value.position;
    final target = current + offset;
    final bounded = target < Duration.zero
        ? Duration.zero
        : target > duration
        ? duration
        : target;
    await controller.seekTo(bounded);
  }

  Future<void> _seekToMilliseconds(int milliseconds) async {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    await controller.seekTo(Duration(milliseconds: milliseconds));
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

  void _syncInitialState(SurgeryRecord record, List<SurgicalStepReview> reviews) {
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
    final running = reviews.where((item) => item.isRunning).firstOrNull;
    if (running != null && running.step != review.step) {
      _showMessage(
        '現在「${running.step.label}」を計測中です。先に${running.step.label}の計測を終了してください。',
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

class _StepNotesTile extends StatelessWidget {
  const _StepNotesTile({
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
      margin: const EdgeInsets.only(top: 4),
      child: ExpansionTile(
        title: const Text('自己評価・反省点'),
        subtitle: Text(rating.label),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          DropdownButtonFormField<StepRating>(
            initialValue: rating,
            decoration: const InputDecoration(labelText: '自己評価'),
            items: StepRating.values
                .map(
                  (item) =>
                      DropdownMenuItem(value: item, child: Text(item.label)),
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
            onTapStart == null
                ? startText
                : InkWell(onTap: onTapStart, child: startText),
            onTapEnd == null
                ? endText
                : InkWell(onTap: onTapEnd, child: endText),
            Text('所要時間：${formatProcedureDuration(timing.duration)}'),
            const SizedBox(height: 10),
            if (isSaving)
              const Center(child: CircularProgressIndicator())
            else if (timing.isNotStarted)
              FilledButton(onPressed: onStart, child: const Text('開始'))
            else if (timing.isRunning)
              FilledButton(onPressed: onEnd, child: const Text('終了'))
            else
              OutlinedButton(onPressed: onReset, child: const Text('再設定')),
          ],
        ),
      ),
    );
  }
}

String formatTimelineMilliseconds(int? milliseconds) {
  if (milliseconds == null) {
    return '未設定';
  }
  final duration = Duration(milliseconds: milliseconds);
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  final tenths = (duration.inMilliseconds % 1000) ~/ 100;
  return '$minutes:${seconds.toString().padLeft(2, '0')}.$tenths';
}

String formatProcedureDuration(Duration? duration) {
  if (duration == null) {
    return '未設定';
  }
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  if (minutes == 0) {
    return '$seconds秒';
  }
  return '$minutes分${seconds.toString().padLeft(2, '0')}秒';
}
