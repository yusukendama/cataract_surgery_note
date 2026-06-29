import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/providers.dart';
import '../../domain/surgery_models.dart';
import 'new_record_screen.dart';
import 'record_detail_screen.dart';

class RecordListScreen extends ConsumerWidget {
  const RecordListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(surgeryRecordsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('白内障執刀ノート')),
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
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const NewRecordScreen()),
          );
        },
        icon: const Icon(Icons.add),
        label: const Text('新規症例'),
      ),
    );
  }

  String _recordTitle(SurgeryRecord record) {
    final date = DateFormat('yyyy/MM/dd').format(record.surgeryDate);
    return '$date ${record.eyeSide.label}';
  }
}
