import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/providers.dart';
import '../../data/surgery_video_picker.dart';
import '../../domain/surgery_models.dart';
import '../analysis/analysis_screen.dart';
import 'new_record_screen.dart';
import 'record_detail_screen.dart';

typedef NewRecordScreenBuilder = Widget Function(SelectedSurgeryVideo video);

class RecordListScreen extends ConsumerWidget {
  const RecordListScreen({this.newRecordScreenBuilder, super.key});

  final NewRecordScreenBuilder? newRecordScreenBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(surgeryRecordsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('白内障執刀ノート'),
        actions: [
          IconButton(
            tooltip: '分析',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AnalysisScreen()),
              );
            },
            icon: const Icon(Icons.show_chart, semanticLabel: '分析'),
          ),
        ],
      ),
      body: records.when(
        data: (items) {
          if (items.isEmpty) {
            return const Center(child: Text('症例がありません'));
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final record = items[index];
              return ListTile(
                title: Text(_recordTitle(record)),
                subtitle: Text(record.reviewStatus.label),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RecordDetailScreen(recordId: record.id),
                    ),
                  );
                },
              );
            },
          );
        },
        error: (error, _) => Center(child: Text('読み込みに失敗しました: $error')),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _startNewRecord(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('新規症例'),
      ),
    );
  }

  Future<void> _startNewRecord(BuildContext context, WidgetRef ref) async {
    final SelectedSurgeryVideo? selectedVideo;
    try {
      selectedVideo = await ref.read(surgeryVideoPickerProvider).pickVideo();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('動画を選択できませんでした。写真へのアクセス権限を確認して、もう一度お試しください。'),
          ),
        );
      }
      return;
    }
    if (!context.mounted || selectedVideo == null) {
      return;
    }
    final video = selectedVideo;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            newRecordScreenBuilder?.call(video) ??
            NewRecordScreen(initialVideo: video),
      ),
    );
  }

  String _recordTitle(SurgeryRecord record) {
    final date = DateFormat('yyyy/MM/dd').format(record.surgeryDate);
    return '$date ${record.eyeSide.label}';
  }
}
