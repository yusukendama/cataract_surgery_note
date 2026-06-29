import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/providers.dart';
import '../../domain/surgery_models.dart';
import 'record_detail_screen.dart';

class NewRecordScreen extends ConsumerStatefulWidget {
  const NewRecordScreen({super.key});

  @override
  ConsumerState<NewRecordScreen> createState() => _NewRecordScreenState();
}

class _NewRecordScreenState extends ConsumerState<NewRecordScreen> {
  DateTime _surgeryDate = DateTime.now();
  EyeSide _eyeSide = EyeSide.right;
  bool _isSaving = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('新規症例作成')),
      body: ListView(
        padding: const EdgeInsets.all(16),
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
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _isSaving ? null : _save,
            icon: _isSaving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            label: const Text('作成'),
          ),
        ],
      ),
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

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      final record = await ref
          .read(surgeryRepositoryProvider)
          .createRecord(surgeryDate: _surgeryDate, eyeSide: _eyeSide);
      ref.invalidate(surgeryRecordsProvider);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => RecordDetailScreen(recordId: record.id),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }
}
