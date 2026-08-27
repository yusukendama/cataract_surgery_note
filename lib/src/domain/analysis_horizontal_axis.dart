import 'calendar_day.dart';
import 'surgery_trend.dart';

enum AnalysisHorizontalAxisMode {
  caseOrder('症例順'),
  chronological('時系列');

  const AnalysisHorizontalAxisMode(this.label);

  final String label;
}

/// A mode-specific horizontal domain shared by every analysis metric.
final class AnalysisHorizontalAxis {
  AnalysisHorizontalAxis({
    required this.mode,
    required this.catalog,
    required this.referenceDate,
    int? recordCount,
  }) : recordCount = recordCount ?? catalog.length,
       _recordsById = {for (final record in catalog) record.recordId: record},
       domainStart = _domainStart(catalog, referenceDate),
       domainEnd = _domainEnd(catalog, referenceDate);

  final AnalysisHorizontalAxisMode mode;
  final List<SurgeryAnalysisRecord> catalog;
  final CalendarDay referenceDate;
  final int recordCount;
  final Map<String, SurgeryAnalysisRecord> _recordsById;
  final CalendarDay domainStart;
  final CalendarDay domainEnd;

  bool containsRecordId(String recordId) => _recordsById.containsKey(recordId);

  double xRatioForRecordId(String recordId) {
    final record = _recordsById[recordId];
    if (record == null) {
      throw StateError('分析catalogに存在しない症例です。');
    }
    return xRatioForRecord(record);
  }

  double xRatioForRecord(SurgeryAnalysisRecord record) {
    switch (mode) {
      case AnalysisHorizontalAxisMode.caseOrder:
        if (recordCount <= 1) {
          return 0.5;
        }
        return (record.caseOrdinal - 1) / (recordCount - 1);
      case AnalysisHorizontalAxisMode.chronological:
        final start = domainStart.ordinal;
        final end = domainEnd.ordinal;
        if (start == end) {
          return 0.5;
        }
        return (record.surgeryDay.ordinal - start) / (end - start);
    }
  }

  static CalendarDay _domainStart(
    List<SurgeryAnalysisRecord> records,
    CalendarDay referenceDate,
  ) {
    if (records.isEmpty || !records.first.surgeryDay.isBefore(referenceDate)) {
      return referenceDate;
    }
    return records.first.surgeryDay;
  }

  static CalendarDay _domainEnd(
    List<SurgeryAnalysisRecord> records,
    CalendarDay referenceDate,
  ) {
    if (records.isEmpty || !records.last.surgeryDay.isAfter(referenceDate)) {
      return referenceDate;
    }
    return records.last.surgeryDay;
  }
}

enum AnalysisTimeTickUnit { day, week, month, year }

final class AnalysisTimeTickInterval {
  const AnalysisTimeTickInterval(this.unit, this.amount);

  final AnalysisTimeTickUnit unit;
  final int amount;
}

final class AnalysisHorizontalTickValue {
  const AnalysisHorizontalTickValue({
    required this.xRatio,
    required this.label,
    this.caseOrdinal,
    this.day,
  });

  final double xRatio;
  final String label;
  final int? caseOrdinal;
  final CalendarDay? day;
}

/// Generates at most 32 values for a case-order interval.
List<AnalysisHorizontalTickValue>? caseOrderTickCandidate({
  required int recordCount,
  required int interval,
}) {
  if (recordCount <= 0 || interval <= 0) {
    return const [];
  }
  if (recordCount == 1) {
    return const [
      AnalysisHorizontalTickValue(xRatio: 0.5, label: '1', caseOrdinal: 1),
    ];
  }

  // Internal multiples satisfy 1 < mI < R. Determine the count without
  // materialising an unbounded 1...R list.
  final firstMultiplier = interval == 1 ? 2 : 1;
  final lastMultiplier = (recordCount - 1) ~/ interval;
  final internalCount = lastMultiplier < firstMultiplier
      ? 0
      : lastMultiplier - firstMultiplier + 1;
  final uniqueCount = 2 + internalCount;
  if (uniqueCount > 32) {
    return null;
  }

  final ordinals = <int>{1, recordCount};
  for (
    var multiplier = firstMultiplier;
    multiplier <= lastMultiplier;
    multiplier++
  ) {
    ordinals.add(multiplier * interval);
  }
  final sorted = ordinals.toList()..sort();
  return List.unmodifiable([
    for (final ordinal in sorted)
      AnalysisHorizontalTickValue(
        xRatio: (ordinal - 1) / (recordCount - 1),
        label: '$ordinal',
        caseOrdinal: ordinal,
      ),
  ]);
}

Iterable<int> oneTwoFiveSequence({int minimum = 1}) sync* {
  var scale = 1;
  while (true) {
    for (final multiplier in const [1, 2, 5]) {
      final value = multiplier * scale;
      if (value >= minimum) {
        yield value;
      }
    }
    if (scale > 922337203685477580) {
      return;
    }
    scale *= 10;
  }
}

/// Generates a bounded reference-anchored chronological tick candidate.
///
/// A null result means that more than 32 ticks would be required.
List<AnalysisHorizontalTickValue>? chronologicalTickCandidate({
  required AnalysisHorizontalAxis axis,
  required AnalysisTimeTickInterval interval,
}) {
  final pastCount = _availableTickMultiples(axis, interval, -1);
  final futureCount = _availableTickMultiples(axis, interval, 1);
  if (1 + pastCount + futureCount > 32) {
    return null;
  }
  final ticks = <AnalysisHorizontalTickValue>[
    AnalysisHorizontalTickValue(
      xRatio: _ratioForDay(axis, axis.referenceDate),
      label: '現在',
      day: axis.referenceDate,
    ),
  ];

  for (final (direction, count) in [(-1, pastCount), (1, futureCount)]) {
    for (var multiple = 1; multiple <= count; multiple++) {
      final day = _moveFromReference(
        axis.referenceDate,
        interval,
        multiple * direction,
      );
      final quantity = multiple * interval.amount;
      ticks.add(
        AnalysisHorizontalTickValue(
          xRatio: _ratioForDay(axis, day),
          label: _relativeLabel(interval.unit, quantity, direction),
          day: day,
        ),
      );
    }
  }
  ticks.sort((a, b) => a.xRatio.compareTo(b.xRatio));
  return List.unmodifiable(ticks);
}

int _availableTickMultiples(
  AnalysisHorizontalAxis axis,
  AnalysisTimeTickInterval interval,
  int direction,
) {
  final reference = axis.referenceDate;
  final boundary = direction < 0 ? axis.domainStart : axis.domainEnd;
  final distance = direction < 0
      ? reference.ordinal - boundary.ordinal
      : boundary.ordinal - reference.ordinal;
  var estimate = switch (interval.unit) {
    AnalysisTimeTickUnit.day => distance ~/ interval.amount,
    AnalysisTimeTickUnit.week => distance ~/ (interval.amount * 7),
    AnalysisTimeTickUnit.month =>
      ((boundary.year - reference.year) * 12 + boundary.month - reference.month)
              .abs() ~/
          interval.amount,
    AnalysisTimeTickUnit.year =>
      (boundary.year - reference.year).abs() ~/ interval.amount,
  };
  bool within(int multiple) {
    final candidate = _moveFromReference(
      reference,
      interval,
      multiple * direction,
    );
    return direction < 0
        ? !candidate.isBefore(boundary)
        : !candidate.isAfter(boundary);
  }

  while (estimate > 0 && !within(estimate)) {
    estimate--;
  }
  while (within(estimate + 1)) {
    estimate++;
  }
  return estimate;
}

CalendarDay _moveFromReference(
  CalendarDay reference,
  AnalysisTimeTickInterval interval,
  int signedMultiple,
) {
  final amount = interval.amount * signedMultiple;
  return switch (interval.unit) {
    AnalysisTimeTickUnit.day => reference.addDays(amount),
    AnalysisTimeTickUnit.week => reference.addDays(amount * 7),
    AnalysisTimeTickUnit.month => reference.addMonths(amount),
    AnalysisTimeTickUnit.year => reference.addYears(amount),
  };
}

double _ratioForDay(AnalysisHorizontalAxis axis, CalendarDay day) {
  final start = axis.domainStart.ordinal;
  final end = axis.domainEnd.ordinal;
  return start == end ? 0.5 : (day.ordinal - start) / (end - start);
}

String _relativeLabel(AnalysisTimeTickUnit unit, int quantity, int direction) {
  final suffix = direction < 0 ? '前' : '後';
  final unitLabel = switch (unit) {
    AnalysisTimeTickUnit.day => '日',
    AnalysisTimeTickUnit.week => '週間',
    AnalysisTimeTickUnit.month => 'か月',
    AnalysisTimeTickUnit.year => '年',
  };
  return '$quantity$unitLabel$suffix';
}
