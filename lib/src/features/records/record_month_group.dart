import 'package:flutter/foundation.dart';

import '../../domain/surgery_models.dart';

@immutable
class RecordMonth {
  const RecordMonth({required this.year, required this.month});

  final int year;
  final int month;

  String get label => '$year年$month月';

  @override
  bool operator ==(Object other) {
    return other is RecordMonth && other.year == year && other.month == month;
  }

  @override
  int get hashCode => Object.hash(year, month);
}

@immutable
class RecordMonthGroup {
  const RecordMonthGroup({required this.month, required this.records});

  final RecordMonth month;
  final List<SurgeryRecord> records;
}

/// Groups records by the calendar components of their registered surgery date.
///
/// Groups and records are both newest-first. Records on the same surgery date
/// are ordered by creation time, then by their stable record ID.
List<RecordMonthGroup> groupRecordsByMonth(Iterable<SurgeryRecord> records) {
  final sortedRecords = records.toList()..sort(_compareRecords);

  final groupedRecords = <RecordMonth, List<SurgeryRecord>>{};
  for (final record in sortedRecords) {
    final surgeryDate = record.surgeryDate;
    final month = RecordMonth(year: surgeryDate.year, month: surgeryDate.month);
    groupedRecords.putIfAbsent(month, () => []).add(record);
  }

  return List.unmodifiable(
    groupedRecords.entries.map(
      (entry) => RecordMonthGroup(
        month: entry.key,
        records: List.unmodifiable(entry.value),
      ),
    ),
  );
}

int _compareRecords(SurgeryRecord left, SurgeryRecord right) {
  final leftDate = left.surgeryDate;
  final rightDate = right.surgeryDate;
  final bySurgeryDate = _dateKey(rightDate).compareTo(_dateKey(leftDate));
  if (bySurgeryDate != 0) {
    return bySurgeryDate;
  }

  final byCreationDate = right.createdAt.compareTo(left.createdAt);
  if (byCreationDate != 0) {
    return byCreationDate;
  }
  return left.id.compareTo(right.id);
}

int _dateKey(DateTime date) => date.year * 10000 + date.month * 100 + date.day;
