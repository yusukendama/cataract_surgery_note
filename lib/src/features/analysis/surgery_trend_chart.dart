import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../domain/duration_formatters.dart';
import '../../domain/surgery_trend.dart';
import 'date_label_layout.dart';
import 'duration_axis_scale.dart';

const double _chartHeight = 320;

class SurgeryTrendChart extends StatelessWidget {
  const SurgeryTrendChart({
    required this.points,
    required this.selectedRecordId,
    required this.onPointSelected,
    super.key,
  });

  final List<SurgeryTrendPoint> points;
  final String? selectedRecordId;
  final ValueChanged<SurgeryTrendPoint> onPointSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('推移', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(
          height: _chartHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final geometry = _ChartGeometry.fromPoints(
                width: constraints.maxWidth,
                height: _chartHeight,
                points: points,
              );
              return Stack(
                children: [
                  CustomPaint(
                    size: Size(constraints.maxWidth, _chartHeight),
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
                      bounds: geometry.hitTargetBounds(index),
                      selected: points[index].recordId == selectedRecordId,
                      onTap: () => onPointSelected(points[index]),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 症例ごとの縦帯のタップ領域。帯は隙間なく・重なりなくチャートを覆うため、
/// どこをタップしても最寄りの症例が選択される。
class _PointTarget extends StatelessWidget {
  const _PointTarget({
    required this.point,
    required this.bounds,
    required this.selected,
    required this.onTap,
  });

  final SurgeryTrendPoint point;
  final Rect bounds;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('yyyy年M月d日').format(point.surgeryDate);
    final label =
        '$date、${point.eyeSide.label}、'
        '${point.step.label} ${formatProcedureDuration(point.duration)}';
    return Positioned.fromRect(
      rect: bounds,
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
    required this.durationAxis,
    required this.pointCount,
  });

  factory _ChartGeometry.fromPoints({
    required double width,
    required double height,
    required List<SurgeryTrendPoint> points,
  }) {
    final maximumDuration = points
        .map((point) => point.duration)
        .reduce((current, next) => current > next ? current : next);
    return _ChartGeometry(
      width: width,
      height: height,
      durationAxis: DurationAxisScale.forMaximum(
        step: points.first.step,
        maximumDuration: maximumDuration,
      ),
      pointCount: points.length,
    );
  }

  final double width;
  final double height;
  final DurationAxisScale durationAxis;
  final int pointCount;

  double get plotLeft => 56;
  double get plotRight => width - 24;
  double get plotTop => 16;
  double get plotBottom => height - 42;
  double get plotWidth => plotRight - plotLeft;

  /// 隣り合うデータ点の横方向の間隔。データ点や日付ラベルの簡略化は
  /// 症例数ではなくこの実ピクセル値で判定するため、端末幅にも追従する。
  double get slotWidth =>
      pointCount <= 1 ? plotWidth : plotWidth / (pointCount - 1);

  double xFor(int index) => pointCount == 1
      ? (plotLeft + plotRight) / 2
      : plotLeft + plotWidth * index / (pointCount - 1);

  Offset offsetFor(int index, SurgeryTrendPoint point) {
    final ratio = durationAxis.ratioFor(point.duration);
    final y = plotBottom - (plotBottom - plotTop) * ratio;
    return Offset(xFor(index), y);
  }

  Rect hitTargetBounds(int index) {
    final left = index == 0 ? 0.0 : (xFor(index - 1) + xFor(index)) / 2;
    final right = index == pointCount - 1
        ? width
        : (xFor(index) + xFor(index + 1)) / 2;
    return Rect.fromLTWH(left, 0, math.max(0, right - left), height);
  }

  @override
  bool operator ==(Object other) {
    return other is _ChartGeometry &&
        other.width == width &&
        other.height == height &&
        other.durationAxis == durationAxis &&
        other.pointCount == pointCount;
  }

  @override
  int get hashCode => Object.hash(width, height, durationAxis, pointCount);
}

enum _TextAnchor { start, center, end }

class _DotStyle {
  const _DotStyle({
    required this.radius,
    required this.ringWidth,
    required this.fill,
  });

  final double radius;
  final double ringWidth;
  final Color fill;
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
    _paintGrid(canvas);
    _paintLine(canvas);
    _paintDots(canvas);
    _paintDateLabels(canvas);
  }

  void _paintGrid(Canvas canvas) {
    final gridPaint = Paint()
      ..color = colorScheme.outlineVariant
      ..strokeWidth = 1;
    for (final tick in geometry.durationAxis.ticks) {
      final ratio = geometry.durationAxis.ratioFor(tick);
      final y =
          geometry.plotBottom -
          (geometry.plotBottom - geometry.plotTop) * ratio;
      canvas.drawLine(
        Offset(geometry.plotLeft, y),
        Offset(geometry.plotRight, y),
        gridPaint,
      );
      _paintText(
        canvas,
        geometry.durationAxis.labelFor(tick),
        Offset(geometry.plotLeft - 8, y),
        anchor: _TextAnchor.end,
        centerVertically: true,
      );
    }
  }

  void _paintLine(Canvas canvas) {
    if (points.length <= 1) {
      return;
    }
    final linePaint = Paint()
      ..color = colorScheme.primary
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
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

  void _paintDots(Canvas canvas) {
    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      final style = _dotStyleFor(
        slotWidth: geometry.slotWidth,
        selected: point.recordId == selectedRecordId,
      );
      if (style == null) {
        continue;
      }
      final offset = geometry.offsetFor(index, point);
      canvas.drawCircle(
        offset,
        style.radius,
        Paint()
          ..color = style.fill
          ..style = PaintingStyle.fill,
      );
      if (style.ringWidth > 0) {
        canvas.drawCircle(
          offset,
          style.radius,
          Paint()
            ..color = colorScheme.primary
            ..strokeWidth = style.ringWidth
            ..style = PaintingStyle.stroke,
        );
      }
    }
  }

  /// 点間隔に応じたデータ点の描き方。null は「点を描かず折れ線のみ」。
  _DotStyle? _dotStyleFor({required double slotWidth, required bool selected}) {
    if (selected) {
      return _DotStyle(
        radius: 7,
        ringWidth: 3,
        fill: colorScheme.primaryContainer,
      );
    }
    if (slotWidth >= 24) {
      return _DotStyle(radius: 5, ringWidth: 2, fill: colorScheme.surface);
    }
    if (slotWidth >= 12) {
      return _DotStyle(radius: 3.5, ringWidth: 1.5, fill: colorScheme.surface);
    }
    if (slotWidth >= 6) {
      return _DotStyle(radius: 2, ringWidth: 0, fill: colorScheme.primary);
    }
    return null;
  }

  void _paintDateLabels(Canvas canvas) {
    final sample = _layoutText('12/28');
    final indices = selectDateLabelIndices(
      pointCount: points.length,
      plotWidth: geometry.plotWidth,
      minimumGap: sample.width + 8,
    );
    for (final index in indices) {
      final anchor = points.length == 1
          ? _TextAnchor.center
          : index == 0
          ? _TextAnchor.start
          : index == points.length - 1
          ? _TextAnchor.end
          : _TextAnchor.center;
      _paintText(
        canvas,
        DateFormat('M/d').format(points[index].surgeryDate),
        Offset(geometry.xFor(index), geometry.plotBottom + 10),
        anchor: anchor,
      );
    }
  }

  TextPainter _layoutText(String value) {
    return TextPainter(
      text: TextSpan(
        text: value,
        style: textStyle.copyWith(color: colorScheme.onSurfaceVariant),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
  }

  void _paintText(
    Canvas canvas,
    String value,
    Offset offset, {
    required _TextAnchor anchor,
    bool centerVertically = false,
  }) {
    final painter = _layoutText(value);
    final dx = switch (anchor) {
      _TextAnchor.start => offset.dx,
      _TextAnchor.center => offset.dx - painter.width / 2,
      _TextAnchor.end => offset.dx - painter.width,
    };
    painter.paint(
      canvas,
      Offset(dx, centerVertically ? offset.dy - painter.height / 2 : offset.dy),
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
