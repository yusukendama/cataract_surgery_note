import 'dart:convert';

import 'calendar_day.dart';
import 'duration_formatters.dart';
import 'surgery_models.dart';

class SurgeryAnalysisRecord {
  const SurgeryAnalysisRecord({
    required this.recordId,
    required this.surgeryDate,
    required this.createdAt,
    required this.rawEyeSide,
    required this.eyeSide,
    required this.caseOrdinal,
  });

  final String recordId;
  final DateTime surgeryDate;
  final DateTime createdAt;
  final String rawEyeSide;
  final EyeSide? eyeSide;
  final int caseOrdinal;

  CalendarDay get surgeryDay => CalendarDay.fromDateTime(surgeryDate);
}

class SurgeryAnalysisMeasurement {
  const SurgeryAnalysisMeasurement({
    required this.recordId,
    required this.surgeryDate,
    required this.createdAt,
    required this.eyeSide,
    required this.step,
    required this.startMilliseconds,
    required this.endMilliseconds,
    this.isSkipped = false,
  });

  final String recordId;
  final DateTime surgeryDate;
  final DateTime createdAt;
  final EyeSide? eyeSide;
  final SurgicalStep step;
  final int? startMilliseconds;
  final int? endMilliseconds;
  final bool isSkipped;

  Duration? get duration => isSkipped
      ? null
      : procedureDurationBetween(startMilliseconds, endMilliseconds);
}

class SurgeryAnalysisSnapshot {
  const SurgeryAnalysisSnapshot({
    required this.recordCount,
    required this.measurements,
    this.catalog = const [],
    this.referenceDate,
    this.timezoneIdentifier,
  });

  final int recordCount;
  final List<SurgeryAnalysisMeasurement> measurements;
  final List<SurgeryAnalysisRecord> catalog;

  /// Display context captured around the production snapshot read.
  ///
  /// They remain optional so deterministic widget fixtures can construct a
  /// snapshot without consulting the platform clock. The production provider
  /// always supplies both values.
  final DateTime? referenceDate;
  final String? timezoneIdentifier;

  SurgeryAnalysisSnapshot withDisplayContext({
    required DateTime referenceDate,
    required String timezoneIdentifier,
  }) {
    return SurgeryAnalysisSnapshot(
      recordCount: recordCount,
      measurements: measurements,
      catalog: catalog,
      referenceDate: referenceDate,
      timezoneIdentifier: timezoneIdentifier,
    );
  }

  /// Compatibility for older in-memory fixtures. Production snapshots never
  /// use this path: repository results always contain the complete catalog.
  List<SurgeryAnalysisRecord> get effectiveCatalog {
    if (catalog.isNotEmpty || recordCount == 0) {
      return catalog;
    }
    final byRecord = <String, SurgeryAnalysisMeasurement>{};
    for (final measurement in measurements) {
      byRecord.putIfAbsent(measurement.recordId, () => measurement);
    }
    final sorted = byRecord.values.toList()..sort(_compareMeasurements);
    return List.unmodifiable([
      for (var index = 0; index < sorted.length; index++)
        SurgeryAnalysisRecord(
          recordId: sorted[index].recordId,
          surgeryDate: sorted[index].surgeryDate,
          createdAt: sorted[index].createdAt,
          rawEyeSide: sorted[index].eyeSide?.name ?? 'unknown',
          eyeSide: sorted[index].eyeSide,
          caseOrdinal: index + 1,
        ),
    ]);
  }
}

class SurgeryTrendPoint {
  const SurgeryTrendPoint({
    required this.recordId,
    required this.surgeryDate,
    required this.createdAt,
    required this.eyeSide,
    required this.step,
    required this.duration,
    this.caseOrdinal = 0,
    this.registeredRecordCount = 0,
  });

  final String recordId;
  final DateTime surgeryDate;
  final DateTime createdAt;
  final EyeSide eyeSide;
  final SurgicalStep step;
  final Duration duration;
  final int caseOrdinal;
  final int registeredRecordCount;

  CalendarDay get surgeryDay => CalendarDay.fromDateTime(surgeryDate);

  @override
  bool operator ==(Object other) {
    return other is SurgeryTrendPoint &&
        other.recordId == recordId &&
        other.surgeryDate == surgeryDate &&
        other.createdAt == createdAt &&
        other.eyeSide == eyeSide &&
        other.step == step &&
        other.duration == duration &&
        other.caseOrdinal == caseOrdinal &&
        other.registeredRecordCount == registeredRecordCount;
  }

  @override
  int get hashCode => Object.hash(
    recordId,
    surgeryDate,
    createdAt,
    eyeSide,
    step,
    duration,
    caseOrdinal,
    registeredRecordCount,
  );
}

class SurgeryTrendSummary {
  const SurgeryTrendSummary({
    required this.latest,
    required this.previousAverage,
    required this.difference,
    required this.comparisonCount,
  });

  final Duration latest;
  final Duration? previousAverage;
  final Duration? difference;
  final int comparisonCount;
}

class SurgeryTrendData {
  const SurgeryTrendData({
    required this.points,
    required this.summary,
    this.registeredRecordCount = 0,
  });

  final List<SurgeryTrendPoint> points;
  final SurgeryTrendSummary? summary;
  final int registeredRecordCount;
}

class SurgeryTrendCalculator {
  const SurgeryTrendCalculator();

  SurgeryTrendData calculate(
    Iterable<SurgeryAnalysisMeasurement> measurements,
    SurgicalStep step, {
    List<SurgeryAnalysisRecord> catalog = const [],
    int? registeredRecordCount,
  }) {
    final catalogById = <String, SurgeryAnalysisRecord>{
      for (final record in catalog) record.recordId: record,
    };
    final effectiveRecordCount = registeredRecordCount ?? catalog.length;
    final points =
        measurements
            .where((measurement) => measurement.step == step)
            .map((measurement) {
              final catalogRecord = catalogById[measurement.recordId];
              final eyeSide = catalogRecord == null
                  ? measurement.eyeSide
                  : catalogRecord.eyeSide;
              if (eyeSide == null || measurement.isSkipped) {
                return null;
              }
              final duration = measurement.duration;
              if (duration == null) {
                return null;
              }
              return SurgeryTrendPoint(
                recordId: measurement.recordId,
                surgeryDate:
                    catalogRecord?.surgeryDate ?? measurement.surgeryDate,
                createdAt: catalogRecord?.createdAt ?? measurement.createdAt,
                eyeSide: eyeSide,
                step: measurement.step,
                duration: duration,
                caseOrdinal: catalogRecord?.caseOrdinal ?? 0,
                registeredRecordCount: effectiveRecordCount,
              );
            })
            .whereType<SurgeryTrendPoint>()
            .toList()
          ..sort(_comparePoints);

    if (points.isEmpty) {
      return SurgeryTrendData(
        points: const [],
        summary: null,
        registeredRecordCount: effectiveRecordCount,
      );
    }

    final latest = points.last.duration;
    final comparisonPoints = points.length <= 1
        ? const <SurgeryTrendPoint>[]
        : points.sublist(0, points.length - 1).reversed.take(5).toList();
    if (comparisonPoints.isEmpty) {
      return SurgeryTrendData(
        points: List.unmodifiable(points),
        registeredRecordCount: effectiveRecordCount,
        summary: SurgeryTrendSummary(
          latest: latest,
          previousAverage: null,
          difference: null,
          comparisonCount: 0,
        ),
      );
    }

    final totalMilliseconds = comparisonPoints.fold<int>(
      0,
      (sum, point) => sum + point.duration.inMilliseconds,
    );
    final comparisonCount = comparisonPoints.length;
    final averageQuotient = totalMilliseconds ~/ comparisonCount;
    final averageRemainder = totalMilliseconds % comparisonCount;
    // Durations are positive here. Round with integer arithmetic so valid
    // values above double's exact-integer range do not lose a millisecond.
    final roundedAverageMilliseconds =
        averageQuotient + (averageRemainder * 2 >= comparisonCount ? 1 : 0);
    final average = Duration(milliseconds: roundedAverageMilliseconds);
    return SurgeryTrendData(
      points: List.unmodifiable(points),
      registeredRecordCount: effectiveRecordCount,
      summary: SurgeryTrendSummary(
        latest: latest,
        previousAverage: average,
        difference: latest - average,
        comparisonCount: comparisonCount,
      ),
    );
  }

  static int _comparePoints(SurgeryTrendPoint a, SurgeryTrendPoint b) {
    if (a.caseOrdinal > 0 && b.caseOrdinal > 0) {
      return a.caseOrdinal.compareTo(b.caseOrdinal);
    }
    final dateComparison = CalendarDay.fromDateTime(
      a.surgeryDate,
    ).compareTo(CalendarDay.fromDateTime(b.surgeryDate));
    if (dateComparison != 0) {
      return dateComparison;
    }
    final createdAtComparison = a.createdAt.compareTo(b.createdAt);
    if (createdAtComparison != 0) {
      return createdAtComparison;
    }
    return compareBinaryStrings(a.recordId, b.recordId);
  }
}

int _compareMeasurements(
  SurgeryAnalysisMeasurement a,
  SurgeryAnalysisMeasurement b,
) {
  final dateComparison = CalendarDay.fromDateTime(
    a.surgeryDate,
  ).compareTo(CalendarDay.fromDateTime(b.surgeryDate));
  if (dateComparison != 0) {
    return dateComparison;
  }
  final createdAtComparison = a.createdAt.compareTo(b.createdAt);
  if (createdAtComparison != 0) {
    return createdAtComparison;
  }
  return compareBinaryStrings(a.recordId, b.recordId);
}

/// Matches SQLite's locale-independent BINARY ordering for valid UTF-8 text.
int compareBinaryStrings(String a, String b) {
  final aBytes = utf8.encode(a);
  final bBytes = utf8.encode(b);
  final commonLength = aBytes.length < bBytes.length
      ? aBytes.length
      : bBytes.length;
  for (var index = 0; index < commonLength; index++) {
    final comparison = aBytes[index].compareTo(bBytes[index]);
    if (comparison != 0) {
      return comparison;
    }
  }
  return aBytes.length.compareTo(bBytes.length);
}
