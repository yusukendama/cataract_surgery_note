import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/providers.dart';
import '../../domain/surgery_models.dart';
import '../review/video_review_screen.dart';

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
  bool _isImporting = false;
  bool _isDeleting = false;

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final videoFile = ref.watch(recordVideoFileProvider(record.id));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '${DateFormat('yyyy/MM/dd').format(record.surgeryDate)} ${record.eyeSide.label}',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text('状態: ${record.reviewStatus.label}'),
        const SizedBox(height: 24),
        videoFile.when(
          data: (file) {
            final hasVideo = file != null;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(hasVideo ? Icons.movie : Icons.movie_outlined),
              title: Text(record.videoDisplayName ?? '動画未選択'),
              subtitle: Text(
                record.videoPath == null
                    ? '動画を選択してください。'
                    : hasVideo
                    ? record.videoPath!
                    : '保存された動画が見つかりません。動画を再選択してください。',
              ),
            );
          },
          error: (_, _) => const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.movie_outlined),
            title: Text('動画を確認できません'),
            subtitle: Text('動画を再選択してください。'),
          ),
          loading: () => const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            title: Text('動画を確認しています'),
          ),
        ),
        const SizedBox(height: 12),
        if (_isImporting) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          const Text('動画をアプリ内に保存しています'),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          onPressed: _isImporting ? null : () => _pickVideo(context),
          icon: _isImporting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.video_file),
          label: Text(record.videoPath == null ? '動画を選択' : '動画を変更'),
        ),
        const SizedBox(height: 12),
        videoFile.when(
          data: (file) => OutlinedButton.icon(
            onPressed: file == null || _isImporting
                ? null
                : () {
                    ref.invalidate(recordVideoFileProvider(record.id));
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => VideoReviewScreen(recordId: record.id),
                      ),
                    );
                  },
            icon: const Icon(Icons.play_arrow),
            label: const Text('動画レビューを開始'),
          ),
          error: (_, _) => OutlinedButton.icon(
            onPressed: null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('動画レビューを開始'),
          ),
          loading: () => OutlinedButton.icon(
            onPressed: null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('動画レビューを開始'),
          ),
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

  Future<void> _pickVideo(BuildContext context) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mov', 'm4v'],
      allowMultiple: false,
    );
    final file = result?.files.single;
    final path = file?.path;
    if (path == null) {
      return;
    }
    setState(() => _isImporting = true);
    try {
      await ref
          .read(recordVideoServiceProvider)
          .importVideoForRecord(
            surgeryRecordId: widget.record.id,
            sourcePath: path,
            originalFileName: file?.name ?? path.split('/').last,
          );
      ref.invalidate(surgeryRecordProvider(widget.record.id));
      ref.invalidate(recordVideoFileProvider(widget.record.id));
      ref.invalidate(surgeryRecordsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('動画を保存しました')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('動画保存に失敗しました: $error')));
      }
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
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
}
