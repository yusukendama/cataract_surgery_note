import 'duration_formatters.dart';
import 'surgery_models.dart';

class SurgeryAnalysisMeasurement {
  const SurgeryAnalysisMeasurement({
    required this.recordId,
    required this.surgeryDate,
    required this.createdAt,
    required this.eyeSide,
    required this.step,
    required this.startMilliseconds,
    required this.endMilliseconds,
  });

  final String recordId;
  final DateTime surgeryDate;
  final DateTime createdAt;
  final EyeSide eyeSide;
  final SurgicalStep step;
  final int? startMilliseconds;
  final int? endMilliseconds;

  Duration? get duration =>
      procedureDurationBetween(startMilliseconds, endMilliseconds);
}

class SurgeryAnalysisSnapshot {
  const SurgeryAnalysisSnapshot({
    required this.recordCount,
    required this.measurements,
  });

  final int recordCount;
  final List<SurgeryAnalysisMeasurement> measurements;
}

class SurgeryTrendPoint {
  const SurgeryTrendPoint({
    required this.recordId,
    required this.surgeryDate,
    required this.createdAt,
    required this.eyeSide,
    required this.step,
    required this.duration,
  });

  final String recordId;
  final DateTime surgeryDate;
  final DateTime createdAt;
  final EyeSide eyeSide;
  final SurgicalStep step;
  final Duration duration;
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
  const SurgeryTrendData({required this.points, required this.summary});

  final List<SurgeryTrendPoint> points;
  final SurgeryTrendSummary? summary;
}

class SurgeryTrendCalculator {
  const SurgeryTrendCalculator();

  SurgeryTrendData calculate(
    Iterable<SurgeryAnalysisMeasurement> measurements,
    SurgicalStep step,
  ) {
    final points =
        measurements
            .where((measurement) => measurement.step == step)
            .map((measurement) {
              final duration = measurement.duration;
              if (duration == null) {
                return null;
              }
              return SurgeryTrendPoint(
                recordId: measurement.recordId,
                surgeryDate: measurement.surgeryDate,
                createdAt: measurement.createdAt,
                eyeSide: measurement.eyeSide,
                step: measurement.step,
                duration: duration,
              );
            })
            .whereType<SurgeryTrendPoint>()
            .toList()
          ..sort(_comparePoints);

    if (points.isEmpty) {
      return const SurgeryTrendData(points: [], summary: null);
    }

    final latest = points.last.duration;
    final comparisonPoints = points.length <= 1
        ? const <SurgeryTrendPoint>[]
        : points.sublist(0, points.length - 1).reversed.take(5).toList();
    if (comparisonPoints.isEmpty) {
      return SurgeryTrendData(
        points: List.unmodifiable(points),
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
      summary: SurgeryTrendSummary(
        latest: latest,
        previousAverage: average,
        difference: latest - average,
        comparisonCount: comparisonCount,
      ),
    );
  }

  static int _comparePoints(SurgeryTrendPoint a, SurgeryTrendPoint b) {
    final dateComparison = a.surgeryDate.compareTo(b.surgeryDate);
    if (dateComparison != 0) {
      return dateComparison;
    }
    final createdAtComparison = a.createdAt.compareTo(b.createdAt);
    if (createdAtComparison != 0) {
      return createdAtComparison;
    }
    return a.recordId.compareTo(b.recordId);
  }
}
