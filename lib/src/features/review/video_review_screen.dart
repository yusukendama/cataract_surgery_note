import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../data/providers.dart';
import '../../domain/ccc_review_rules.dart';
import '../../domain/surgery_models.dart';

class VideoReviewScreen extends ConsumerStatefulWidget {
  const VideoReviewScreen({required this.recordId, super.key});

  final String recordId;

  @override
  ConsumerState<VideoReviewScreen> createState() => _VideoReviewScreenState();
}

class _VideoReviewScreenState extends ConsumerState<VideoReviewScreen> {
  final TextEditingController _reflectionController = TextEditingController();
  final CccReviewRules _rules = const CccReviewRules();
  VideoPlayerController? _videoController;
  String? _loadedVideoPath;
  String? _loadedReviewId;
  int? _startMilliseconds;
  int? _endMilliseconds;
  StepRating _rating = StepRating.unreviewed;
  double _playbackSpeed = 1;
  bool _isSaving = false;

  @override
  void dispose() {
    _reflectionController.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final record = ref.watch(surgeryRecordProvider(widget.recordId));
    final review = ref.watch(cccReviewProvider(widget.recordId));
    final videoFile = ref.watch(recordVideoFileProvider(widget.recordId));

    return Scaffold(
      appBar: AppBar(title: const Text('CCC動画レビュー')),
      body: record.when(
        data: (item) {
          if (item == null) {
            return const Center(child: Text('症例が見つかりません'));
          }
          return videoFile.when(
            data: (file) {
              if (file == null) {
                return const Center(
                  child: Text('保存された動画が見つかりません。\n動画を再選択してください。'),
                );
              }
              _ensureVideoController(file);
              return review.when(
                data: (stepReview) {
                  _syncReview(stepReview);
                  return _ReviewBody(
                    videoController: _videoController,
                    startMilliseconds: _startMilliseconds,
                    endMilliseconds: _endMilliseconds,
                    rating: _rating,
                    reflectionController: _reflectionController,
                    playbackSpeed: _playbackSpeed,
                    isSaving: _isSaving,
                    onSeekRelative: _seekRelative,
                    onSetStart: _setStart,
                    onSetEnd: _setEnd,
                    onJumpToStart: _jumpToStart,
                    onPlaybackSpeedChanged: _setPlaybackSpeed,
                    onRatingChanged: (rating) =>
                        setState(() => _rating = rating),
                    onSave: () => _save(stepReview),
                  );
                },
                error: (error, _) => Center(child: Text('レビュー読み込み失敗: $error')),
                loading: () => const Center(child: CircularProgressIndicator()),
              );
            },
            error: (error, _) => Center(child: Text('動画読み込み失敗: $error')),
            loading: () => const Center(child: CircularProgressIndicator()),
          );
        },
        error: (error, _) => Center(child: Text('症例読み込み失敗: $error')),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  void _ensureVideoController(File file) {
    if (_loadedVideoPath == file.path) {
      return;
    }
    _loadedVideoPath = file.path;
    _videoController?.dispose();
    final controller = VideoPlayerController.file(file);
    _videoController = controller;
    controller.initialize().then((_) {
      controller.setPlaybackSpeed(_playbackSpeed);
      if (mounted) {
        setState(() {});
      }
    });
    controller.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  void _syncReview(SurgicalStepReview review) {
    if (_loadedReviewId == review.id) {
      return;
    }
    _loadedReviewId = review.id;
    _startMilliseconds = review.startMilliseconds;
    _endMilliseconds = review.endMilliseconds;
    _rating = review.rating;
    _reflectionController.text = review.reflection;
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

  void _setStart() {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    setState(() {
      _startMilliseconds = controller.value.position.inMilliseconds;
    });
  }

  void _setEnd() {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    setState(() {
      _endMilliseconds = controller.value.position.inMilliseconds;
    });
  }

  Future<void> _jumpToStart() async {
    final start = _startMilliseconds;
    final controller = _videoController;
    if (start == null ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }
    await controller.seekTo(Duration(milliseconds: start));
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    final controller = _videoController;
    setState(() => _playbackSpeed = speed);
    if (controller != null && controller.value.isInitialized) {
      await controller.setPlaybackSpeed(speed);
    }
  }

  Future<void> _save(SurgicalStepReview review) async {
    final error = _rules.validateRange(
      startMilliseconds: _startMilliseconds,
      endMilliseconds: _endMilliseconds,
    );
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    setState(() => _isSaving = true);
    try {
      await ref
          .read(surgeryRepositoryProvider)
          .saveStepReview(
            review.copyWith(
              startMilliseconds: _startMilliseconds,
              endMilliseconds: _endMilliseconds,
              rating: _rating,
              reflection: _reflectionController.text.trim(),
            ),
          );
      ref.invalidate(cccReviewProvider(widget.recordId));
      ref.invalidate(surgeryRecordProvider(widget.recordId));
      ref.invalidate(surgeryRecordsProvider);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('CCCレビューを保存しました')));
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }
}

class _ReviewBody extends StatelessWidget {
  const _ReviewBody({
    required this.videoController,
    required this.startMilliseconds,
    required this.endMilliseconds,
    required this.rating,
    required this.reflectionController,
    required this.playbackSpeed,
    required this.isSaving,
    required this.onSeekRelative,
    required this.onSetStart,
    required this.onSetEnd,
    required this.onJumpToStart,
    required this.onPlaybackSpeedChanged,
    required this.onRatingChanged,
    required this.onSave,
  });

  final VideoPlayerController? videoController;
  final int? startMilliseconds;
  final int? endMilliseconds;
  final StepRating rating;
  final TextEditingController reflectionController;
  final double playbackSpeed;
  final bool isSaving;
  final Future<void> Function(Duration offset) onSeekRelative;
  final VoidCallback onSetStart;
  final VoidCallback onSetEnd;
  final Future<void> Function() onJumpToStart;
  final ValueChanged<double> onPlaybackSpeedChanged;
  final ValueChanged<StepRating> onRatingChanged;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final controller = videoController;
    final initialized = controller?.value.isInitialized ?? false;
    final position = initialized ? controller!.value.position : Duration.zero;
    final duration = initialized ? controller!.value.duration : Duration.zero;
    final rules = const CccReviewRules();
    final cccDuration = rules.calculateDuration(
      startMilliseconds: startMilliseconds,
      endMilliseconds: endMilliseconds,
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        AspectRatio(
          aspectRatio: initialized ? controller!.value.aspectRatio : 16 / 9,
          child: ColoredBox(
            color: Colors.black,
            child: initialized
                ? VideoPlayer(controller!)
                : const Center(child: CircularProgressIndicator()),
          ),
        ),
        const SizedBox(height: 12),
        Text('${_formatDuration(position)} / ${_formatDuration(duration)}'),
        Slider(
          value: initialized ? position.inMilliseconds.toDouble() : 0,
          max: initialized && duration.inMilliseconds > 0
              ? duration.inMilliseconds.toDouble()
              : 1,
          onChanged: initialized
              ? (value) {
                  controller!.seekTo(Duration(milliseconds: value.round()));
                }
              : null,
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            IconButton.filledTonal(
              tooltip: '5秒戻る',
              onPressed: initialized
                  ? () => onSeekRelative(const Duration(seconds: -5))
                  : null,
              icon: const Icon(Icons.keyboard_double_arrow_left),
            ),
            IconButton.filledTonal(
              tooltip: '1秒戻る',
              onPressed: initialized
                  ? () => onSeekRelative(const Duration(seconds: -1))
                  : null,
              icon: const Icon(Icons.keyboard_arrow_left),
            ),
            IconButton.filled(
              tooltip: controller?.value.isPlaying ?? false ? '一時停止' : '再生',
              onPressed: initialized
                  ? () {
                      controller!.value.isPlaying
                          ? controller.pause()
                          : controller.play();
                    }
                  : null,
              icon: Icon(
                controller?.value.isPlaying ?? false
                    ? Icons.pause
                    : Icons.play_arrow,
              ),
            ),
            IconButton.filledTonal(
              tooltip: '1秒進む',
              onPressed: initialized
                  ? () => onSeekRelative(const Duration(seconds: 1))
                  : null,
              icon: const Icon(Icons.keyboard_arrow_right),
            ),
            IconButton.filledTonal(
              tooltip: '5秒進む',
              onPressed: initialized
                  ? () => onSeekRelative(const Duration(seconds: 5))
                  : null,
              icon: const Icon(Icons.keyboard_double_arrow_right),
            ),
          ],
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<double>(
          initialValue: playbackSpeed,
          decoration: const InputDecoration(labelText: '再生速度'),
          items: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
              .map(
                (speed) => DropdownMenuItem<double>(
                  value: speed,
                  child: Text('${speed}x'),
                ),
              )
              .toList(),
          onChanged: initialized
              ? (speed) {
                  if (speed != null) {
                    onPlaybackSpeedChanged(speed);
                  }
                }
              : null,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: initialized ? onSetStart : null,
              icon: const Icon(Icons.flag),
              label: const Text('CCC開始を設定'),
            ),
            FilledButton.tonalIcon(
              onPressed: initialized ? onSetEnd : null,
              icon: const Icon(Icons.sports_score),
              label: const Text('CCC終了を設定'),
            ),
            OutlinedButton.icon(
              onPressed: startMilliseconds == null ? null : onJumpToStart,
              icon: const Icon(Icons.replay),
              label: const Text('CCC開始位置へ移動'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text('CCC開始: ${_formatMilliseconds(startMilliseconds)}'),
        Text('CCC終了: ${_formatMilliseconds(endMilliseconds)}'),
        Text('CCC所要時間: ${_formatDurationOrEmpty(cccDuration)}'),
        const SizedBox(height: 16),
        DropdownButtonFormField<StepRating>(
          initialValue: rating,
          decoration: const InputDecoration(labelText: 'CCC自己評価'),
          items: StepRating.values
              .map(
                (item) => DropdownMenuItem<StepRating>(
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
        const SizedBox(height: 16),
        TextField(
          controller: reflectionController,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: 'CCC反省点',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: isSaving ? null : onSave,
          icon: isSaving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save),
          label: const Text('保存'),
        ),
      ],
    );
  }

  String _formatMilliseconds(int? milliseconds) {
    if (milliseconds == null) {
      return '-';
    }
    return _formatDuration(Duration(milliseconds: milliseconds));
  }

  String _formatDurationOrEmpty(Duration? duration) {
    if (duration == null) {
      return '-';
    }
    return _formatDuration(duration);
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    final milliseconds = duration.inMilliseconds % 1000;
    return '$minutes:${seconds.toString().padLeft(2, '0')}.${(milliseconds ~/ 100).toString()}';
  }
}
