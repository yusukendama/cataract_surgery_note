import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../domain/duration_formatters.dart';
import '../../domain/surgery_trend.dart';

class SurgeryTrendChart extends StatelessWidget {
  const SurgeryTrendChart({
    required this.points,
    required this.selectedRecordId,
    required this.scrollController,
    required this.onPointSelected,
    super.key,
  });

  final List<SurgeryTrendPoint> points;
  final String? selectedRecordId;
  final ScrollController scrollController;
  final ValueChanged<SurgeryTrendPoint> onPointSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('推移', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(
          height: 320,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final chartWidth = math.max(
                constraints.maxWidth,
                84.0 + math.max(0, points.length - 1) * 72.0,
              );
              final geometry = _ChartGeometry.fromPoints(
                width: chartWidth,
                height: 320,
                points: points,
              );
              return SingleChildScrollView(
                key: const Key('analysis-chart-scroll'),
                controller: scrollController,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: chartWidth,
                  height: 320,
                  child: Stack(
                    children: [
                      CustomPaint(
                        size: Size(chartWidth, 320),
                        painter: _TrendChartPainter(
                          points: points,
                          geometry: geometry,
                          selectedRecordId: selectedRecordId,
                          colorScheme: Theme.of(context).colorScheme,
                          textStyle: Theme.of(context).textTheme.labelSmall!,
                        ),
                      ),
                      for (var index = 0; index < points.length; index++)
                        _PointTarget(
                          point: points[index],
                          center: geometry.offsetFor(index, points[index]),
                          selected: points[index].recordId == selectedRecordId,
                          onTap: () => onPointSelected(points[index]),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PointTarget extends StatelessWidget {
  const _PointTarget({
    required this.point,
    required this.center,
    required this.selected,
    required this.onTap,
  });

  final SurgeryTrendPoint point;
  final Offset center;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('yyyy年M月d日').format(point.surgeryDate);
    final label =
        '$date、${point.eyeSide.label}、'
        '${point.step.label} ${formatProcedureDuration(point.duration)}';
    return Positioned(
      left: center.dx - 22,
      top: center.dy - 22,
      width: 44,
      height: 44,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Tooltip(
          message: label,
          child: GestureDetector(
            key: Key('analysis-point-${point.recordId}'),
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class _ChartGeometry {
  const _ChartGeometry({
    required this.width,
    required this.height,
    required this.minimumMilliseconds,
    required this.maximumMilliseconds,
    required this.pointCount,
  });

  factory _ChartGeometry.fromPoints({
    required double width,
    required double height,
    required List<SurgeryTrendPoint> points,
  }) {
    final values = points
        .map((point) => point.duration.inMilliseconds)
        .toList();
    final minimum = values.reduce(math.min);
    final maximum = values.reduce(math.max);
    final range = maximum - minimum;
    final basePadding = range == 0
        ? math.max(5000, (maximum * 0.1).round())
        : math.max(1000, (range * 0.1).round());
    return _ChartGeometry(
      width: width,
      height: height,
      minimumMilliseconds: math.max(0, minimum - basePadding),
      maximumMilliseconds: maximum + basePadding,
      pointCount: points.length,
    );
  }

  final double width;
  final double height;
  final int minimumMilliseconds;
  final int maximumMilliseconds;
  final int pointCount;

  double get plotLeft => 56;
  double get plotRight => width - 24;
  double get plotTop => 16;
  double get plotBottom => height - 42;

  Offset offsetFor(int index, SurgeryTrendPoint point) {
    final x = pointCount == 1
        ? (plotLeft + plotRight) / 2
        : plotLeft + (plotRight - plotLeft) * index / (pointCount - 1);
    final valueRange = maximumMilliseconds - minimumMilliseconds;
    final ratio = valueRange == 0
        ? 0.5
        : (point.duration.inMilliseconds - minimumMilliseconds) / valueRange;
    final y = plotBottom - (plotBottom - plotTop) * ratio;
    return Offset(x, y);
  }
}

class _TrendChartPainter extends CustomPainter {
  const _TrendChartPainter({
    required this.points,
    required this.geometry,
    required this.selectedRecordId,
    required this.colorScheme,
    required this.textStyle,
  });

  final List<SurgeryTrendPoint> points;
  final _ChartGeometry geometry;
  final String? selectedRecordId;
  final ColorScheme colorScheme;
  final TextStyle textStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = colorScheme.outlineVariant
      ..strokeWidth = 1;
    const tickCount = 4;
    for (var tick = 0; tick <= tickCount; tick++) {
      final ratio = tick / tickCount;
      final y =
          geometry.plotBottom -
          (geometry.plotBottom - geometry.plotTop) * ratio;
      canvas.drawLine(
        Offset(geometry.plotLeft, y),
        Offset(geometry.plotRight, y),
        gridPaint,
      );
      final value =
          geometry.minimumMilliseconds +
          ((geometry.maximumMilliseconds - geometry.minimumMilliseconds) *
                  ratio)
              .round();
      _paintText(
        canvas,
        formatMinutesSeconds(Duration(milliseconds: value)),
        Offset(geometry.plotLeft - 8, y),
        textAlign: TextAlign.right,
        anchorRight: true,
        centerVertically: true,
      );
    }

    final linePaint = Paint()
      ..color = colorScheme.primary
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (points.length > 1) {
      final path = Path();
      for (var index = 0; index < points.length; index++) {
        final offset = geometry.offsetFor(index, points[index]);
        if (index == 0) {
          path.moveTo(offset.dx, offset.dy);
        } else {
          path.lineTo(offset.dx, offset.dy);
        }
      }
      canvas.drawPath(path, linePaint);
    }

    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      final offset = geometry.offsetFor(index, point);
      final selected = point.recordId == selectedRecordId;
      canvas.drawCircle(
        offset,
        selected ? 7 : 5,
        Paint()
          ..color = selected
              ? colorScheme.primaryContainer
              : colorScheme.surface
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        offset,
        selected ? 7 : 5,
        Paint()
          ..color = colorScheme.primary
          ..strokeWidth = selected ? 3 : 2
          ..style = PaintingStyle.stroke,
      );
      _paintText(
        canvas,
        DateFormat('M/d').format(point.surgeryDate),
        Offset(offset.dx, geometry.plotBottom + 10),
        textAlign: TextAlign.center,
      );
    }
  }

  void _paintText(
    Canvas canvas,
    String value,
    Offset offset, {
    required TextAlign textAlign,
    bool anchorRight = false,
    bool centerVertically = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: textStyle.copyWith(color: colorScheme.onSurfaceVariant),
      ),
      textDirection: ui.TextDirection.ltr,
      textAlign: textAlign,
    )..layout();
    painter.paint(
      canvas,
      Offset(
        anchorRight ? offset.dx - painter.width : offset.dx - painter.width / 2,
        centerVertically ? offset.dy - painter.height / 2 : offset.dy,
      ),
    );
  }

  @override
  bool shouldRepaint(_TrendChartPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.selectedRecordId != selectedRecordId ||
        oldDelegate.colorScheme != colorScheme ||
        oldDelegate.geometry != geometry;
  }
}
