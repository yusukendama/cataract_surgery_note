import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

import '../../data/providers.dart';
import '../../data/surgery_video_picker.dart';
import '../../domain/surgery_models.dart';
import 'record_detail_screen.dart';

class NewRecordScreen extends ConsumerStatefulWidget {
  const NewRecordScreen({
    required this.initialVideo,
    this.enableVideoPreview = true,
    super.key,
  });

  final SelectedSurgeryVideo initialVideo;
  final bool enableVideoPreview;

  @override
  ConsumerState<NewRecordScreen> createState() => _NewRecordScreenState();
}

class _NewRecordScreenState extends ConsumerState<NewRecordScreen> {
  late SelectedSurgeryVideo _selectedVideo = widget.initialVideo;
  DateTime? _surgeryDate;
  EyeSide? _eyeSide;
  VideoPlayerController? _videoController;
  String? _videoErrorMessage;
  bool _isVideoLoading = true;
  bool _isSaving = false;
  bool _allowPop = false;
  bool _videoWasChanged = false;

  bool get _canRegister =>
      !_isSaving &&
      !_isVideoLoading &&
      _videoErrorMessage == null &&
      (!widget.enableVideoPreview ||
          (_videoController?.value.isInitialized ?? false)) &&
      _surgeryDate != null &&
      _eyeSide != null;

  @override
  void initState() {
    super.initState();
    if (widget.enableVideoPreview) {
      unawaited(_loadVideo(_selectedVideo));
    } else {
      _isVideoLoading = false;
    }
  }

  @override
  void dispose() {
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
        appBar: AppBar(title: const Text('新規症例')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('選択した動画', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _buildVideoPreview(),
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
                  onPressed: _isSaving ? null : _changeVideo,
                  icon: const Icon(Icons.video_file_outlined),
                  label: const Text('動画を変更'),
                ),
              ],
            ),
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
            Card(
              child: ListTile(
                title: const Text('手術日（必須）'),
                subtitle: Text(
                  _surgeryDate == null
                      ? '未選択'
                      : DateFormat('yyyy/MM/dd').format(_surgeryDate!),
                ),
                trailing: const Icon(Icons.calendar_today),
                onTap: _isSaving ? null : _pickDate,
              ),
            ),
            const SizedBox(height: 16),
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
              onSelectionChanged: _isSaving
                  ? null
                  : (selection) {
                      setState(() {
                        _eyeSide = selection.isEmpty ? null : selection.single;
                      });
                    },
            ),
            if (_eyeSide == null) ...[
              const SizedBox(height: 6),
              Text(
                '右眼または左眼を選択してください',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 28),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                key: const Key('register-record-button'),
                onPressed: _canRegister ? _save : null,
                icon: _isSaving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: const Text('症例を登録'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoPreview() {
    if (!widget.enableVideoPreview) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Center(
            child: Icon(Icons.video_file, color: Colors.white, size: 48),
          ),
        ),
      );
    }
    if (_isVideoLoading) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    final error = _videoErrorMessage;
    if (error != null) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
      );
    }
    final controller = _videoController!;
    final duration = controller.value.duration;
    final position = controller.value.position;
    final maxMilliseconds = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    return Column(
      children: [
        AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: ColoredBox(
            color: Colors.black,
            child: VideoPlayer(controller),
          ),
        ),
        Slider(
          value: position.inMilliseconds.toDouble().clamp(0, maxMilliseconds),
          max: maxMilliseconds,
          onChanged: (value) {
            controller.seekTo(Duration(milliseconds: value.round()));
          },
        ),
        IconButton.filled(
          tooltip: controller.value.isPlaying ? '一時停止' : '再生',
          onPressed: () {
            controller.value.isPlaying ? controller.pause() : controller.play();
          },
          icon: Icon(
            controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
          ),
        ),
      ],
    );
  }

  Future<void> _loadVideo(SelectedSurgeryVideo selectedVideo) async {
    final previous = _videoController;
    if (previous != null) {
      previous.removeListener(_onVideoStateChanged);
      await previous.dispose();
    }
    final controller = VideoPlayerController.file(File(selectedVideo.path));
    _videoController = controller;
    _videoErrorMessage = null;
    _isVideoLoading = true;
    controller.addListener(_onVideoStateChanged);
    if (mounted) {
      setState(() {});
    }
    try {
      await controller.initialize();
      if (!mounted || _videoController != controller) {
        return;
      }
      setState(() => _isVideoLoading = false);
    } catch (_) {
      if (!mounted || _videoController != controller) {
        return;
      }
      setState(() {
        _isVideoLoading = false;
        _videoErrorMessage = '動画を再生できませんでした。動画を変更して、もう一度お試しください。';
      });
    }
  }

  void _onVideoStateChanged() {
    if (!mounted) {
      return;
    }
    final controller = _videoController;
    setState(() {
      if (controller?.value.hasError ?? false) {
        _isVideoLoading = false;
        _videoErrorMessage = '動画を再生できませんでした。動画を変更して、もう一度お試しください。';
      }
    });
  }

  Future<void> _changeVideo() async {
    final SelectedSurgeryVideo? selectedVideo;
    try {
      selectedVideo = await ref.read(surgeryVideoPickerProvider).pickVideo();
    } catch (_) {
      _showMessage('動画を選択できませんでした。写真へのアクセス権限を確認してください。');
      return;
    }
    if (selectedVideo == null || !mounted) {
      return;
    }
    setState(() {
      _selectedVideo = selectedVideo!;
      _surgeryDate = null;
      _eyeSide = null;
      _videoWasChanged = true;
    });
    if (widget.enableVideoPreview) {
      await _loadVideo(selectedVideo);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _surgeryDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null && mounted) {
      setState(() => _surgeryDate = picked);
    }
  }

  Future<void> _save() async {
    final surgeryDate = _surgeryDate;
    final eyeSide = _eyeSide;
    if (!_canRegister || surgeryDate == null || eyeSide == null) {
      return;
    }
    setState(() => _isSaving = true);
    try {
      final record = await ref
          .read(recordVideoServiceProvider)
          .createRecordWithVideo(
            surgeryDate: surgeryDate,
            eyeSide: eyeSide,
            sourcePath: _selectedVideo.path,
            originalFileName: _selectedVideo.displayName,
          );
      ref.invalidate(surgeryRecordsProvider);
      if (!mounted) {
        return;
      }
      setState(() => _allowPop = true);
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => RecordDetailScreen(recordId: record.id),
        ),
      );
    } catch (error) {
      _showMessage(_describeSaveError(error));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  String _describeSaveError(Object error) {
    if (error is ArgumentError) {
      return 'この動画形式は登録できません。MP4、MOV、M4V形式の動画を選択してください。';
    }
    if (error is FileSystemException) {
      return '動画を保存できませんでした。ストレージの空き容量と動画ファイルを確認してください。';
    }
    return '症例を登録できませんでした。入力内容は保持されています。もう一度お試しください。';
  }

  Future<void> _confirmDiscard() async {
    if (_isSaving) {
      return;
    }
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
    if (discard == true && mounted) {
      setState(() => _allowPop = true);
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
