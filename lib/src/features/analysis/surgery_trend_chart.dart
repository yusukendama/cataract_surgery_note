import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../domain/duration_formatters.dart';
import '../../domain/surgery_trend.dart';
import 'date_label_layout.dart';
import 'duration_axis_scale.dart';

const double _minimumChartHeight = 320;

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
    assert(points.isNotEmpty);
    final selectedIndex = _selectedIndex;
    final selectedPoint = points[selectedIndex];
    final textScaler = MediaQuery.textScalerOf(context);
    final textStyle = Theme.of(context).textTheme.labelSmall!;
    final textDirection = Directionality.of(context);
    final chartHeight = _chartHeightFor(
      textScaler: textScaler,
      textStyle: textStyle,
      textDirection: textDirection,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('推移', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Semantics(
          key: const Key('analysis-trend-adjustable'),
          container: true,
          excludeSemantics: true,
          label: '${selectedPoint.step.label}の推移',
          value: _semanticValue(selectedIndex),
          increasedValue: selectedIndex < points.length - 1
              ? _semanticValue(selectedIndex + 1)
              : _semanticValue(selectedIndex),
          decreasedValue: selectedIndex > 0
              ? _semanticValue(selectedIndex - 1)
              : _semanticValue(selectedIndex),
          hint: _semanticHint(selectedIndex),
          // VoiceOverでadjustable controlとして一貫して操作できるよう、
          // 端点でもactionは残し、不可能な方向は状態を変えない。
          onIncrease: () {
            if (selectedIndex < points.length - 1) {
              onPointSelected(points[selectedIndex + 1]);
            }
          },
          onDecrease: () {
            if (selectedIndex > 0) {
              onPointSelected(points[selectedIndex - 1]);
            }
          },
          child: SizedBox(
            height: chartHeight,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final geometry = _ChartGeometry.fromPoints(
                  width: constraints.maxWidth,
                  height: chartHeight,
                  points: points,
                  textScaler: textScaler,
                  textStyle: textStyle,
                  textDirection: textDirection,
                );
                return Stack(
                  children: [
                    CustomPaint(
                      size: Size(constraints.maxWidth, chartHeight),
                      painter: _TrendChartPainter(
                        points: points,
                        geometry: geometry,
                        selectedRecordId: selectedPoint.recordId,
                        colorScheme: Theme.of(context).colorScheme,
                        textStyle: textStyle,
                        textScaler: textScaler,
                        textDirection: textDirection,
                      ),
                    ),
                    for (var index = 0; index < points.length; index++)
                      _PointTarget(
                        point: points[index],
                        bounds: geometry.hitTargetBounds(index),
                        onTap: () => onPointSelected(points[index]),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  int get _selectedIndex {
    final index = points.indexWhere(
      (point) => point.recordId == selectedRecordId,
    );
    return index < 0 ? points.length - 1 : index;
  }

  String _semanticValue(int index) {
    final point = points[index];
    final date = DateFormat('yyyy年M月d日', 'ja_JP').format(point.surgeryDate);
    return '全${points.length}件中${index + 1}件目、$date、${point.eyeSide.label}、'
        '${point.step.label}、${formatProcedureDuration(point.duration)}';
  }

  String _semanticHint(int index) {
    if (points.length == 1) {
      return 'この指標の症例は1件だけです';
    }
    if (index == 0) {
      return '最も古い症例です。増加操作で新しい症例へ移動します';
    }
    if (index == points.length - 1) {
      return '最新の症例です。減少操作で古い症例へ移動します';
    }
    return '増加操作で新しい症例、減少操作で古い症例へ移動します';
  }

  double _chartHeightFor({
    required TextScaler textScaler,
    required TextStyle textStyle,
    required ui.TextDirection textDirection,
  }) {
    final sample = TextPainter(
      text: TextSpan(text: '12/28', style: textStyle),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();
    return math.max(_minimumChartHeight, 260 + sample.height * 4);
  }
}

/// 症例ごとの縦帯のタップ領域。帯は隙間なく・重なりなくチャートを覆うため、
/// どこをタップしても最寄りの症例が選択される。
class _PointTarget extends StatelessWidget {
  const _PointTarget({
    required this.point,
    required this.bounds,
    required this.onTap,
  });

  final SurgeryTrendPoint point;
  final Rect bounds;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('yyyy年M月d日', 'ja_JP').format(point.surgeryDate);
    final label =
        '$date、${point.eyeSide.label}、'
        '${point.step.label} ${formatProcedureDuration(point.duration)}';
    return Positioned.fromRect(
      rect: bounds,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          key: Key('analysis-point-${point.recordId}'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: const SizedBox.expand(),
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
    required this.plotLeft,
    required this.plotTop,
    required this.plotBottomInset,
  });

  factory _ChartGeometry.fromPoints({
    required double width,
    required double height,
    required List<SurgeryTrendPoint> points,
    required TextScaler textScaler,
    required TextStyle textStyle,
    required ui.TextDirection textDirection,
  }) {
    final maximumDuration = points
        .map((point) => point.duration)
        .reduce((current, next) => current > next ? current : next);
    final durationAxis = DurationAxisScale.forMaximum(
      step: points.first.step,
      maximumDuration: maximumDuration,
    );
    double textWidth(String value) {
      final painter = TextPainter(
        text: TextSpan(text: value, style: textStyle),
        textDirection: textDirection,
        textScaler: textScaler,
      )..layout();
      return painter.width;
    }

    final labelPainter = TextPainter(
      text: TextSpan(text: '12/28', style: textStyle),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();
    final labelHeight = labelPainter.height;
    final widestAxisLabel = durationAxis.ticks
        .map(durationAxis.labelFor)
        .map(textWidth)
        .fold<double>(0, math.max);
    return _ChartGeometry(
      width: width,
      height: height,
      durationAxis: durationAxis,
      pointCount: points.length,
      plotLeft: math.max(56, widestAxisLabel + 16),
      plotTop: math.max(16, labelHeight / 2 + 8),
      plotBottomInset: math.max(42, labelHeight + 20),
    );
  }

  final double width;
  final double height;
  final DurationAxisScale durationAxis;
  final int pointCount;
  final double plotLeft;
  final double plotTop;
  final double plotBottomInset;

  double get plotRight => width - 24;
  double get plotBottom => height - plotBottomInset;
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
        other.pointCount == pointCount &&
        other.plotLeft == plotLeft &&
        other.plotTop == plotTop &&
        other.plotBottomInset == plotBottomInset;
  }

  @override
  int get hashCode => Object.hash(
    width,
    height,
    durationAxis,
    pointCount,
    plotLeft,
    plotTop,
    plotBottomInset,
  );
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
    required this.textScaler,
    required this.textDirection,
  });

  final List<SurgeryTrendPoint> points;
  final _ChartGeometry geometry;
  final String? selectedRecordId;
  final ColorScheme colorScheme;
  final TextStyle textStyle;
  final TextScaler textScaler;
  final ui.TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    _paintGrid(canvas);
    _paintLine(canvas);
    _paintDots(canvas);
    _paintDateLabels(canvas);
  }

  void _paintGrid(Canvas canvas) {
    final gridPaint = Paint()
      // Grid lines communicate the duration scale, so they use the stronger
      // opaque outline role instead of the decorative outlineVariant role.
      ..color = colorScheme.outline
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
        DateFormat('M/d', 'ja_JP').format(points[index].surgeryDate),
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
      textDirection: textDirection,
      textScaler: textScaler,
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
        oldDelegate.textStyle != textStyle ||
        oldDelegate.textScaler != textScaler ||
        oldDelegate.textDirection != textDirection ||
        oldDelegate.geometry != geometry;
  }
}
