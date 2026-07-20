import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/providers.dart';
import '../../domain/surgery_models.dart';
import '../review/step_review_screen.dart';

class RecordDetailScreen extends ConsumerWidget {
  const RecordDetailScreen({required this.recordId, super.key});

  final String recordId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final record = ref.watch(surgeryRecordProvider(recordId));

    return Scaffold(
      appBar: AppBar(title: const Text('症例詳細')),
      body: record.when(
        data: (item) {
          if (item == null) {
            return const Center(child: Text('症例が見つかりません'));
          }
          return _RecordDetailBody(record: item);
        },
        error: (error, _) => Center(child: Text('読み込みに失敗しました: $error')),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _RecordDetailBody extends ConsumerStatefulWidget {
  const _RecordDetailBody({required this.record});

  final SurgeryRecord record;

  @override
  ConsumerState<_RecordDetailBody> createState() => _RecordDetailBodyState();
}

class _RecordDetailBodyState extends ConsumerState<_RecordDetailBody> {
  bool _isDeleting = false;
  bool _isUpdatingVideo = false;
  bool _isUpdatingDetails = false;

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final videoFile = ref.watch(recordVideoFileProvider(record.id));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${DateFormat('yyyy/MM/dd').format(record.surgeryDate)} ${record.eyeSide.label}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            IconButton(
              tooltip: '手術日・左右眼を変更',
              onPressed: _isUpdatingDetails ? null : _editRecordDetails,
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('状態: ${record.reviewStatus.label}'),
        const SizedBox(height: 24),
        ..._buildVideoSection(context, record, videoFile),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => StepReviewScreen(recordId: record.id),
              ),
            );
          },
          icon: const Icon(Icons.rate_review),
          label: const Text('工程の時間記録を開始'),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: _isDeleting ? null : _deleteRecord,
          icon: _isDeleting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.delete_outline),
          label: const Text('症例を削除'),
        ),
      ],
    );
  }

  /// Builds the video area, distinguishing four states so the screen never
  /// claims a video is available when its file is gone (e.g. after an
  /// iCloud restore, which keeps the database but not the excluded videos):
  /// unregistered, checking, registered-and-present, and registered-but-missing.
  List<Widget> _buildVideoSection(
    BuildContext context,
    SurgeryRecord record,
    AsyncValue<File?> videoFile,
  ) {
    if (record.videoPath == null) {
      return [
        const Card(
          child: ListTile(
            leading: Icon(Icons.movie_outlined),
            title: Text('動画未登録'),
            subtitle: Text('動画が登録されていません'),
          ),
        ),
        const SizedBox(height: 12),
        _pickVideoButton('動画を選択'),
      ];
    }

    return videoFile.when(
      data: (file) {
        if (file != null) {
          return [
            Card(
              child: ListTile(
                leading: const Icon(Icons.movie),
                title: Text(record.videoDisplayName ?? '登録済みの動画'),
                subtitle: const Text('登録済みの動画'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                'アプリ内に保存した動画はバックアップされません。元の動画は別途保管してください。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [_pickVideoButton('動画を変更'), _deleteVideoButton()],
            ),
          ];
        }
        return [
          Card(
            child: ListTile(
              isThreeLine: true,
              leading: const Icon(Icons.error_outline),
              title: Text(record.videoDisplayName ?? '動画'),
              subtitle: const Text(
                '保存した動画が見つかりません。機種変更や端末の復元後は、元の動画を選び直してください。',
              ),
            ),
          ),
          const SizedBox(height: 12),
          _pickVideoButton('動画を再選択'),
        ];
      },
      loading: () => [
        Card(
          child: ListTile(
            leading: const Icon(Icons.movie),
            title: Text(record.videoDisplayName ?? '動画'),
            subtitle: const Text('動画を確認しています…'),
            trailing: const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ],
      error: (_, _) => [
        Card(
          child: ListTile(
            leading: const Icon(Icons.error_outline),
            title: Text(record.videoDisplayName ?? '動画'),
            subtitle: const Text('動画を確認できませんでした。もう一度お試しください。'),
          ),
        ),
        const SizedBox(height: 12),
        _pickVideoButton('動画を再選択'),
      ],
    );
  }

  Widget _pickVideoButton(String label) {
    return FilledButton.icon(
      onPressed: _isUpdatingVideo ? null : _pickVideo,
      icon: _isUpdatingVideo
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.video_call_outlined),
      label: Text(label),
    );
  }

  Widget _deleteVideoButton() {
    return OutlinedButton.icon(
      onPressed: _isUpdatingVideo ? null : _deleteVideo,
      icon: const Icon(Icons.delete_outline),
      label: const Text('動画を削除'),
    );
  }

  Future<void> _editRecordDetails() async {
    final record = widget.record;
    final result = await showDialog<(DateTime, EyeSide)>(
      context: context,
      builder: (_) => _EditRecordDialog(
        initialDate: record.surgeryDate,
        initialEyeSide: record.eyeSide,
      ),
    );
    if (result == null) {
      return;
    }

    setState(() => _isUpdatingDetails = true);
    try {
      await ref
          .read(surgeryRepositoryProvider)
          .updateRecordDetails(
            surgeryRecordId: record.id,
            surgeryDate: result.$1,
            eyeSide: result.$2,
          );
      ref.invalidate(surgeryRecordProvider(record.id));
      ref.invalidate(surgeryRecordsProvider);
    } catch (_) {
      _showMessage('変更を保存できませんでした。もう一度お試しください。');
    } finally {
      if (mounted) {
        setState(() => _isUpdatingDetails = false);
      }
    }
  }

  Future<void> _pickVideo() async {
    final record = widget.record;
    if (record.videoPath != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('動画を差し替える'),
          content: const Text('動画を差し替えると、現在設定されている工程位置が新しい動画と一致しなくなる可能性があります。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('差し替える'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
    }

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

    setState(() => _isUpdatingVideo = true);
    try {
      await ref
          .read(recordVideoServiceProvider)
          .importVideoForRecord(
            surgeryRecordId: record.id,
            sourcePath: path,
            originalFileName: fileName,
          );
      _invalidateRecordProviders();
    } catch (error) {
      _showMessage(_videoErrorMessage(error));
    } finally {
      if (mounted) {
        setState(() => _isUpdatingVideo = false);
      }
    }
  }

  Future<void> _deleteVideo() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('動画を削除'),
        content: const Text('登録されている動画を削除します。工程の開始・終了位置もあわせて削除されます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    setState(() => _isUpdatingVideo = true);
    try {
      await ref
          .read(recordVideoServiceProvider)
          .removeVideoForRecord(widget.record.id);
      _invalidateRecordProviders();
    } catch (_) {
      _showMessage('動画を削除できませんでした。もう一度お試しください。');
    } finally {
      if (mounted) {
        setState(() => _isUpdatingVideo = false);
      }
    }
  }

  void _invalidateRecordProviders() {
    ref.invalidate(surgeryRecordProvider(widget.record.id));
    ref.invalidate(surgeryRecordsProvider);
    ref.invalidate(recordVideoFileProvider(widget.record.id));
    ref.invalidate(stepReviewsProvider(widget.record.id));
  }

  String _videoErrorMessage(Object error) {
    if (error is ArgumentError) {
      return 'この動画形式は再生できません。MP4形式などに変換してから、もう一度選択してください。';
    }
    if (error is FileSystemException) {
      return '動画を保存できませんでした。ストレージの空き容量をご確認ください。';
    }
    return '動画を保存できませんでした。もう一度お試しください。';
  }

  Future<void> _deleteRecord() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('症例を削除'),
        content: const Text('この症例とアプリ内に保存した動画を削除します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    setState(() => _isDeleting = true);
    try {
      await ref
          .read(recordVideoServiceProvider)
          .deleteRecordAndManagedVideos(widget.record.id);
      ref.invalidate(surgeryRecordsProvider);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) {
        setState(() => _isDeleting = false);
      }
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

class _EditRecordDialog extends StatefulWidget {
  const _EditRecordDialog({
    required this.initialDate,
    required this.initialEyeSide,
  });

  final DateTime initialDate;
  final EyeSide initialEyeSide;

  @override
  State<_EditRecordDialog> createState() => _EditRecordDialogState();
}

class _EditRecordDialogState extends State<_EditRecordDialog> {
  late DateTime _surgeryDate = widget.initialDate;
  late EyeSide _eyeSide = widget.initialEyeSide;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('手術日・左右眼を変更'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('手術日'),
            subtitle: Text(DateFormat('yyyy/MM/dd').format(_surgeryDate)),
            trailing: const Icon(Icons.calendar_today),
            onTap: _pickDate,
          ),
          const SizedBox(height: 12),
          SegmentedButton<EyeSide>(
            segments: EyeSide.values
                .map(
                  (side) => ButtonSegment<EyeSide>(
                    value: side,
                    label: Text(side.label),
                  ),
                )
                .toList(),
            selected: {_eyeSide},
            onSelectionChanged: (selection) {
              setState(() => _eyeSide = selection.single);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (_surgeryDate, _eyeSide)),
          child: const Text('保存'),
        ),
      ],
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _surgeryDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() => _surgeryDate = picked);
    }
  }
}
