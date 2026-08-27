import 'dart:math' as math;
import 'dart:ui';

import '../../domain/analysis_horizontal_axis.dart';
import '../../domain/calendar_day.dart';
import '../../domain/surgery_trend.dart';
import 'duration_axis_layout.dart';
import 'duration_axis_scale.dart';

const double minimumVisibleMarkerDistance = 6;
const double _minimumHorizontalLabelGap = 8;

typedef ChartTextMeasurer = Size Function(String value);

final class SurgeryTrendPointLayout {
  const SurgeryTrendPointLayout({
    required this.point,
    required this.offset,
    required this.caseOrdinal,
    required this.markerVisible,
  });

  final SurgeryTrendPoint point;
  final Offset offset;
  final int caseOrdinal;
  final bool markerVisible;

  @override
  bool operator ==(Object other) {
    return other is SurgeryTrendPointLayout &&
        other.point == point &&
        other.offset == offset &&
        other.caseOrdinal == caseOrdinal &&
        other.markerVisible == markerVisible;
  }

  @override
  int get hashCode => Object.hash(point, offset, caseOrdinal, markerVisible);
}

final class SurgeryTrendTickLayout {
  const SurgeryTrendTickLayout({
    required this.value,
    required this.x,
    required this.labelBounds,
  });

  final AnalysisHorizontalTickValue value;
  final double x;
  final Rect labelBounds;

  @override
  bool operator ==(Object other) {
    return other is SurgeryTrendTickLayout &&
        other.value.xRatio == value.xRatio &&
        other.value.label == value.label &&
        other.x == x &&
        other.labelBounds == labelBounds;
  }

  @override
  int get hashCode => Object.hash(value.xRatio, value.label, x, labelBounds);
}

/// Pure geometry shared by paint, pointer selection, and deterministic tests.
final class SurgeryTrendChartLayout {
  const SurgeryTrendChartLayout._({
    required this.width,
    required this.height,
    required this.durationAxisLayout,
    required this.horizontalAxis,
    required this.points,
    required this.horizontalTicks,
  });

  factory SurgeryTrendChartLayout.calculate({
    required double width,
    required double height,
    required List<SurgeryTrendPoint> points,
    required AnalysisHorizontalAxis horizontalAxis,
    required ChartTextMeasurer measureText,
  }) {
    if (points.isEmpty) {
      throw ArgumentError.value(points, 'points', '1点以上必要です');
    }
    final maximumDuration = points
        .map((point) => point.duration)
        .reduce((current, next) => current > next ? current : next);
    final durationAxisLayout = DurationAxisLayout.calculateWithMeasurer(
      width: width,
      height: height,
      step: points.first.step,
      maximumDuration: maximumDuration,
      measureText: measureText,
    );
    final durationAxis = durationAxisLayout.scale;
    final plotLeft = durationAxisLayout.plotLeft;
    final plotRight = durationAxisLayout.plotRight;
    final plotTop = durationAxisLayout.plotTop;
    final plotBottom = durationAxisLayout.plotBottom;
    final plotWidth = plotRight - plotLeft;

    final provisional = <SurgeryTrendPointLayout>[];
    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      final caseOrdinal = point.caseOrdinal > 0 ? point.caseOrdinal : index + 1;
      final xRatio = _ratioForPoint(
        horizontalAxis,
        point,
        fallbackCaseOrdinal: caseOrdinal,
      );
      final yRatio = durationAxis.ratioFor(point.duration);
      provisional.add(
        SurgeryTrendPointLayout(
          point: point,
          caseOrdinal: caseOrdinal,
          offset: Offset(
            plotLeft + plotWidth * xRatio,
            plotBottom - (plotBottom - plotTop) * yRatio,
          ),
          markerVisible: true,
        ),
      );
    }
    final markerVisibility = _markerVisibility(provisional);
    final pointLayouts = List<SurgeryTrendPointLayout>.unmodifiable([
      for (var index = 0; index < provisional.length; index++)
        SurgeryTrendPointLayout(
          point: provisional[index].point,
          offset: provisional[index].offset,
          caseOrdinal: provisional[index].caseOrdinal,
          markerVisible: markerVisibility[index],
        ),
    ]);
    final ticks = _selectTicks(
      axis: horizontalAxis,
      chartWidth: width,
      plotLeft: plotLeft,
      plotRight: plotRight,
      labelTop: plotBottom + 10,
      measureText: measureText,
    );
    return SurgeryTrendChartLayout._(
      width: width,
      height: height,
      durationAxisLayout: durationAxisLayout,
      horizontalAxis: horizontalAxis,
      points: pointLayouts,
      horizontalTicks: ticks,
    );
  }

  final double width;
  final double height;
  final DurationAxisLayout durationAxisLayout;
  final AnalysisHorizontalAxis horizontalAxis;
  final List<SurgeryTrendPointLayout> points;
  final List<SurgeryTrendTickLayout> horizontalTicks;

  DurationAxisScale get durationAxis => durationAxisLayout.scale;
  double get plotLeft => durationAxisLayout.plotLeft;
  double get plotRight => durationAxisLayout.plotRight;
  double get plotTop => durationAxisLayout.plotTop;
  double get plotBottom => durationAxisLayout.plotBottom;
  double get plotWidth => durationAxisLayout.plotWidth;
  Rect get interactionRectangle => Rect.fromLTWH(0, 0, width, height);
  Rect get plotRectangle =>
      Rect.fromLTRB(plotLeft, plotTop, plotRight, plotBottom);

  SurgeryTrendPoint? selectPoint({
    required Offset localPosition,
    required String? selectedRecordId,
  }) {
    if (!interactionRectangle.contains(localPosition) || points.isEmpty) {
      return null;
    }
    final clamped = Offset(
      localPosition.dx.clamp(plotLeft, plotRight).toDouble(),
      localPosition.dy.clamp(plotTop, plotBottom).toDouble(),
    );
    return switch (horizontalAxis.mode) {
      AnalysisHorizontalAxisMode.caseOrder => _selectCaseOrderPoint(
        clamped,
        selectedRecordId,
      ),
      AnalysisHorizontalAxisMode.chronological => _selectChronologicalPoint(
        clamped,
        selectedRecordId,
      ),
    };
  }

  SurgeryTrendPoint _selectCaseOrderPoint(
    Offset position,
    String? selectedRecordId,
  ) {
    var candidates = <SurgeryTrendPointLayout>[];
    var minimumDistance = double.infinity;
    for (final point in points) {
      final distance = (point.offset.dx - position.dx).abs();
      if (distance < minimumDistance - 1e-9) {
        minimumDistance = distance;
        candidates = [point];
      } else if ((distance - minimumDistance).abs() <= 1e-9) {
        candidates.add(point);
      }
    }
    final selected = candidates.where(
      (candidate) => candidate.point.recordId == selectedRecordId,
    );
    if (selected.isNotEmpty) {
      return selected.first.point;
    }
    candidates.sort((a, b) => a.caseOrdinal.compareTo(b.caseOrdinal));
    return candidates.last.point;
  }

  SurgeryTrendPoint _selectChronologicalPoint(
    Offset position,
    String? selectedRecordId,
  ) {
    final clusters = <CalendarDay, List<SurgeryTrendPointLayout>>{};
    for (final point in points) {
      clusters.putIfAbsent(point.point.surgeryDay, () => []).add(point);
    }
    CalendarDay? selectedDay;
    var minimumXDistance = double.infinity;
    for (final entry in clusters.entries) {
      final distance = (entry.value.first.offset.dx - position.dx).abs();
      if (distance < minimumXDistance - 1e-9 ||
          ((distance - minimumXDistance).abs() <= 1e-9 &&
              (selectedDay == null || entry.key.isAfter(selectedDay)))) {
        minimumXDistance = distance;
        selectedDay = entry.key;
      }
    }
    final cluster = clusters[selectedDay]!;
    var candidates = <SurgeryTrendPointLayout>[];
    var minimumYDistance = double.infinity;
    for (final point in cluster) {
      final distance = (point.offset.dy - position.dy).abs();
      if (distance < minimumYDistance - 1e-9) {
        minimumYDistance = distance;
        candidates = [point];
      } else if ((distance - minimumYDistance).abs() <= 1e-9) {
        candidates.add(point);
      }
    }
    final current = candidates.where(
      (candidate) => candidate.point.recordId == selectedRecordId,
    );
    if (current.isNotEmpty) {
      return current.first.point;
    }
    candidates.sort((a, b) => a.caseOrdinal.compareTo(b.caseOrdinal));
    return candidates.last.point;
  }

  @override
  bool operator ==(Object other) {
    return other is SurgeryTrendChartLayout &&
        other.width == width &&
        other.height == height &&
        other.durationAxisLayout == durationAxisLayout &&
        other.horizontalAxis.mode == horizontalAxis.mode &&
        other.horizontalAxis.referenceDate == horizontalAxis.referenceDate &&
        _listEquals(other.points, points) &&
        _listEquals(other.horizontalTicks, horizontalTicks);
  }

  @override
  int get hashCode => Object.hash(
    width,
    height,
    durationAxisLayout,
    horizontalAxis.mode,
    horizontalAxis.referenceDate,
    Object.hashAll(points),
    Object.hashAll(horizontalTicks),
  );
}

double _ratioForPoint(
  AnalysisHorizontalAxis axis,
  SurgeryTrendPoint point, {
  required int fallbackCaseOrdinal,
}) {
  if (axis.containsRecordId(point.recordId)) {
    return axis.xRatioForRecordId(point.recordId);
  }
  if (axis.mode == AnalysisHorizontalAxisMode.caseOrder) {
    if (axis.recordCount <= 1) {
      return 0.5;
    }
    return (fallbackCaseOrdinal - 1) / (axis.recordCount - 1);
  }
  final start = axis.domainStart.ordinal;
  final end = axis.domainEnd.ordinal;
  return start == end
      ? 0.5
      : (point.surgeryDay.ordinal - start) / (end - start);
}

List<bool> _markerVisibility(List<SurgeryTrendPointLayout> points) {
  if (points.length <= 1) {
    return List<bool>.filled(points.length, true);
  }
  const cellSize = minimumVisibleMarkerDistance / 2;
  final cells = <(int, int), List<int>>{};
  final visible = List<bool>.filled(points.length, true);
  for (var index = 0; index < points.length; index++) {
    final offset = points[index].offset;
    final cell = (
      (offset.dx / cellSize).floor(),
      (offset.dy / cellSize).floor(),
    );
    cells.putIfAbsent(cell, () => []).add(index);
  }

  // A 3px cell has a diagonal below 6px. Every member of a non-singleton
  // cell is therefore dense without comparing all pairs in that cell.
  for (final bucket in cells.values) {
    if (bucket.length > 1) {
      for (final index in bucket) {
        visible[index] = false;
      }
    }
  }

  // Only singleton cells can still need classification. A cell has at most
  // 24 relevant neighbours, and a dense neighbour is scanned only until the
  // first point within the threshold is found. This remains linear for the
  // fixed-size chart grid even when thousands of points coincide.
  for (final entry in cells.entries) {
    final bucket = entry.value;
    if (bucket.length != 1 || !visible[bucket.single]) {
      continue;
    }
    final index = bucket.single;
    final offset = points[index].offset;
    var found = false;
    for (var dx = -2; dx <= 2; dx++) {
      for (var dy = -2; dy <= 2; dy++) {
        final neighbour = cells[(entry.key.$1 + dx, entry.key.$2 + dy)];
        if (neighbour == null || (dx == 0 && dy == 0)) {
          continue;
        }
        for (final otherIndex in neighbour) {
          if ((points[otherIndex].offset - offset).distance <
              minimumVisibleMarkerDistance) {
            visible[index] = false;
            visible[otherIndex] = false;
            found = true;
            break;
          }
        }
        if (found) {
          break;
        }
      }
      if (found) {
        break;
      }
    }
  }
  return visible;
}

List<SurgeryTrendTickLayout> _selectTicks({
  required AnalysisHorizontalAxis axis,
  required double chartWidth,
  required double plotLeft,
  required double plotRight,
  required double labelTop,
  required ChartTextMeasurer measureText,
}) {
  switch (axis.mode) {
    case AnalysisHorizontalAxisMode.caseOrder:
      for (final interval in oneTwoFiveSequence()) {
        final candidate = caseOrderTickCandidate(
          recordCount: axis.recordCount,
          interval: interval,
        );
        if (candidate != null) {
          final layout = _layoutCandidate(
            candidate,
            chartWidth: chartWidth,
            plotLeft: plotLeft,
            plotRight: plotRight,
            labelTop: labelTop,
            measureText: measureText,
          );
          if (layout != null) {
            return layout;
          }
        }
        if (interval >= axis.recordCount) {
          break;
        }
      }
      final fallback = AnalysisHorizontalTickValue(
        xRatio: axis.recordCount == 1 ? 0.5 : 1,
        label: '${axis.recordCount}',
        caseOrdinal: axis.recordCount,
      );
      return _layoutCandidate(
            [fallback],
            chartWidth: chartWidth,
            plotLeft: plotLeft,
            plotRight: plotRight,
            labelTop: labelTop,
            measureText: measureText,
          ) ??
          const [];
    case AnalysisHorizontalAxisMode.chronological:
      final candidates = <AnalysisTimeTickInterval>[
        const AnalysisTimeTickInterval(AnalysisTimeTickUnit.day, 1),
        const AnalysisTimeTickInterval(AnalysisTimeTickUnit.week, 1),
        const AnalysisTimeTickInterval(AnalysisTimeTickUnit.month, 1),
        const AnalysisTimeTickInterval(AnalysisTimeTickUnit.month, 3),
        const AnalysisTimeTickInterval(AnalysisTimeTickUnit.month, 6),
        const AnalysisTimeTickInterval(AnalysisTimeTickUnit.year, 1),
        const AnalysisTimeTickInterval(AnalysisTimeTickUnit.year, 2),
        const AnalysisTimeTickInterval(AnalysisTimeTickUnit.year, 5),
      ];
      for (final years in oneTwoFiveSequence(minimum: 10)) {
        candidates.add(
          AnalysisTimeTickInterval(AnalysisTimeTickUnit.year, years),
        );
        if (years > (axis.domainEnd.year - axis.domainStart.year).abs() + 1) {
          break;
        }
      }
      for (final interval in candidates) {
        final candidate = chronologicalTickCandidate(
          axis: axis,
          interval: interval,
        );
        if (candidate == null) {
          continue;
        }
        final layout = _layoutCandidate(
          candidate,
          chartWidth: chartWidth,
          plotLeft: plotLeft,
          plotRight: plotRight,
          labelTop: labelTop,
          measureText: measureText,
        );
        if (layout != null) {
          return layout;
        }
      }
      final current = AnalysisHorizontalTickValue(
        xRatio: axis.domainStart == axis.domainEnd
            ? 0.5
            : (axis.referenceDate.ordinal - axis.domainStart.ordinal) /
                  (axis.domainEnd.ordinal - axis.domainStart.ordinal),
        label: '現在',
        day: axis.referenceDate,
      );
      return _layoutCandidate(
            [current],
            chartWidth: chartWidth,
            plotLeft: plotLeft,
            plotRight: plotRight,
            labelTop: labelTop,
            measureText: measureText,
          ) ??
          const [];
  }
}

List<SurgeryTrendTickLayout>? _layoutCandidate(
  List<AnalysisHorizontalTickValue> values, {
  required double chartWidth,
  required double plotLeft,
  required double plotRight,
  required double labelTop,
  required ChartTextMeasurer measureText,
}) {
  final plotWidth = plotRight - plotLeft;
  final result = <SurgeryTrendTickLayout>[];
  for (final value in values) {
    final size = measureText(value.label);
    if (size.width > chartWidth) {
      return null;
    }
    final x = plotLeft + plotWidth * value.xRatio;
    final left = (x - size.width / 2)
        .clamp(0.0, math.max(0.0, chartWidth - size.width))
        .toDouble();
    result.add(
      SurgeryTrendTickLayout(
        value: value,
        x: x,
        labelBounds: Rect.fromLTWH(left, labelTop, size.width, size.height),
      ),
    );
  }
  result.sort((a, b) => a.x.compareTo(b.x));
  for (var index = 1; index < result.length; index++) {
    if (result[index].labelBounds.left - result[index - 1].labelBounds.right <
        _minimumHorizontalLabelGap) {
      return null;
    }
  }
  return List.unmodifiable(result);
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) {
      return false;
    }
  }
  return true;
}
