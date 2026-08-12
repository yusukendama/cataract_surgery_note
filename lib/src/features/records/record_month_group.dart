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

/// Groups records by their surgery month in the device's local time zone.
///
/// Groups and records are both newest-first. Records on the same surgery date
/// are ordered by creation time, while otherwise identical records keep their
/// input order.
List<RecordMonthGroup> groupRecordsByMonth(Iterable<SurgeryRecord> records) {
  final indexedRecords =
      records
          .toList()
          .asMap()
          .entries
          .map((entry) => _IndexedRecord(index: entry.key, record: entry.value))
          .toList()
        ..sort(_compareRecords);

  final groupedRecords = <RecordMonth, List<SurgeryRecord>>{};
  for (final indexedRecord in indexedRecords) {
    final localDate = indexedRecord.record.surgeryDate.toLocal();
    final month = RecordMonth(year: localDate.year, month: localDate.month);
    groupedRecords.putIfAbsent(month, () => []).add(indexedRecord.record);
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

int _compareRecords(_IndexedRecord left, _IndexedRecord right) {
  final leftDate = left.record.surgeryDate.toLocal();
  final rightDate = right.record.surgeryDate.toLocal();
  final bySurgeryDate = _dateKey(rightDate).compareTo(_dateKey(leftDate));
  if (bySurgeryDate != 0) {
    return bySurgeryDate;
  }

  final byCreationDate = right.record.createdAt.compareTo(
    left.record.createdAt,
  );
  if (byCreationDate != 0) {
    return byCreationDate;
  }
  return left.index.compareTo(right.index);
}

int _dateKey(DateTime date) => date.year * 10000 + date.month * 100 + date.day;

class _IndexedRecord {
  const _IndexedRecord({required this.index, required this.record});

  final int index;
  final SurgeryRecord record;
}
