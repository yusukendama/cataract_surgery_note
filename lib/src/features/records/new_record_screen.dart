import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

import '../../data/providers.dart';
import '../../data/surgery_video_picker.dart';
import '../../domain/surgery_models.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/video_surface.dart';
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
  bool _isShowingDiscardDialog = false;
  bool _allowPop = false;
  bool _videoWasChanged = false;
  bool _hasAttemptedRegistration = false;
  String? _validationAnnouncement;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _dateFieldKey = GlobalKey();
  final GlobalKey _eyeFieldKey = GlobalKey();

  bool get _canAttemptRegistration =>
      !_isSaving &&
      !_isVideoLoading &&
      _videoErrorMessage == null &&
      (!widget.enableVideoPreview ||
          (_videoController?.value.isInitialized ?? false));

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
        appBar: AppBar(title: const Text('新規症例')),
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
                    onTap: _isSaving ? null : _pickDate,
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
                  onSelectionChanged: _isSaving
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
                      : _isVideoLoading
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
                  Text(error, textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return _VideoPreview(controller: _videoController!);
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
      if (controller.value.duration <= Duration.zero ||
          controller.value.hasError) {
        throw StateError('再生可能な動画ではありません');
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
    if ((controller?.value.hasError ?? false) && _videoErrorMessage == null) {
      setState(() {
        _isVideoLoading = false;
        _videoErrorMessage = '動画を再生できませんでした。動画を変更して、もう一度お試しください。';
      });
    }
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
      _hasAttemptedRegistration = false;
      _validationAnnouncement = null;
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
      ref.invalidate(surgeryRecordProgressProvider);
      ref.invalidate(surgeryAnalysisProvider);
      ref.invalidate(videoStorageMaintenanceProvider);
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
    if (error is PlatformException &&
        error.code.startsWith('backup_exclusion')) {
      return '動画のバックアップ除外を確認できませんでした。症例は登録していません。もう一度お試しください。';
    }
    if (error is ArgumentError) {
      return 'この動画形式は登録できません。MP4、MOV、M4V形式の動画を選択してください。';
    }
    if (error is FileSystemException) {
      return '動画を保存できませんでした。ストレージの空き容量と動画ファイルを確認してください。';
    }
    return '症例を登録できませんでした。入力内容は保持されています。もう一度お試しください。';
  }

  Future<void> _confirmDiscard() async {
    if (_isSaving || _isShowingDiscardDialog) {
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

  void _showMessage(String message) {
    if (mounted) {
      showAppSnackBar(context, message: message, tone: AppFeedbackTone.failure);
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
