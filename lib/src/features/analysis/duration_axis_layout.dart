import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../domain/surgery_models.dart';
import 'duration_axis_scale.dart';

const double durationAxisMinimumChartHeight = 320;
const double durationAxisMinimumPlotWidth = 44;
const double durationAxisMinimumLabelGap = 4;
const double durationAxisCrossAxisLabelGap = 4;
const int durationAxisMaximumTickCount = 12;

typedef DurationAxisTextMeasurer = Size Function(String value);

/// プロット高さと実測ラベル高さから表示可能な主要目盛り数を返す。
int calculateDurationAxisTickCapacity({
  required double plotHeight,
  required double labelHeight,
}) {
  if (!plotHeight.isFinite || plotHeight < 0) {
    throw ArgumentError.value(plotHeight, 'plotHeight');
  }
  if (!labelHeight.isFinite || labelHeight <= 0) {
    throw ArgumentError.value(labelHeight, 'labelHeight');
  }
  final calculated =
      (plotHeight / (labelHeight + durationAxisMinimumLabelGap)).floor() + 1;
  return calculated.clamp(2, durationAxisMaximumTickCount);
}

/// Painterがそのまま使用する、1本の主要目盛りの描画情報。
@immutable
class DurationAxisTickLayout {
  const DurationAxisTickLayout({
    required this.tick,
    required this.label,
    required this.y,
    required this.labelBounds,
  });

  final Duration tick;
  final String label;
  final double y;
  final Rect labelBounds;

  @override
  bool operator ==(Object other) {
    return other is DurationAxisTickLayout &&
        other.tick == tick &&
        other.label == label &&
        other.y == y &&
        other.labelBounds == labelBounds;
  }

  @override
  int get hashCode => Object.hash(tick, label, y, labelBounds);
}

/// 時間軸の実測ラベル、表示可能数、プロット矩形および描画位置。
///
/// CustomPainterとテストが同じ結果を使うことで、Painter内部の文字を
/// Widget検索へ依存せず検証できる。
@immutable
class DurationAxisLayout {
  DurationAxisLayout._({
    required this.scale,
    required this.maximumTickCount,
    required this.labelHeight,
    required this.plotLeft,
    required this.plotRight,
    required this.plotTop,
    required this.plotBottom,
    required List<DurationAxisTickLayout> ticks,
  }) : ticks = List<DurationAxisTickLayout>.unmodifiable(ticks);

  factory DurationAxisLayout.calculate({
    required double width,
    required double height,
    required SurgicalStep step,
    required Duration maximumDuration,
    required TextStyle textStyle,
    required TextScaler textScaler,
    required ui.TextDirection textDirection,
  }) {
    return _calculate(
      width: width,
      height: height,
      step: step,
      maximumDuration: maximumDuration,
      measureText: (value) => _measureText(
        value,
        textStyle: textStyle,
        textScaler: textScaler,
        textDirection: textDirection,
      ),
    );
  }

  /// UIに依存しないchart layoutと同じ文字計測結果を共有するための境界。
  factory DurationAxisLayout.calculateWithMeasurer({
    required double width,
    required double height,
    required SurgicalStep step,
    required Duration maximumDuration,
    required DurationAxisTextMeasurer measureText,
  }) {
    return _calculate(
      width: width,
      height: height,
      step: step,
      maximumDuration: maximumDuration,
      measureText: measureText,
    );
  }

  static DurationAxisLayout _calculate({
    required double width,
    required double height,
    required SurgicalStep step,
    required Duration maximumDuration,
    required DurationAxisTextMeasurer measureText,
  }) {
    if (!width.isFinite || width < 0) {
      throw ArgumentError.value(width, 'width');
    }
    if (!height.isFinite || height < 0) {
      throw ArgumentError.value(height, 'height');
    }

    final dateLabelHeight = measureText('12/28').height;
    var scale = DurationAxisScale.forMaximum(
      step: step,
      maximumDuration: maximumDuration,
    );
    var labelHeight = _maximumLabelHeight(scale, measureText: measureText);
    var maximumTickCount = durationAxisMaximumTickCount;

    // Nが変わるとラベル列も変わり得るため、最終ラベルの実寸で収束させる。
    // Nは2〜12の有限集合で、通常の一行ラベルでは1回で収束する。
    for (
      var attempt = 0;
      attempt < durationAxisMaximumTickCount * 2;
      attempt++
    ) {
      final vertical = _verticalGeometry(
        height: height,
        axisLabelHeight: labelHeight,
        dateLabelHeight: dateLabelHeight,
      );
      final nextMaximumTickCount = calculateDurationAxisTickCapacity(
        plotHeight: vertical.plotHeight,
        labelHeight: labelHeight,
      );
      final nextScale = DurationAxisScale.forMaximum(
        step: step,
        maximumDuration: maximumDuration,
        maximumTickCount: nextMaximumTickCount,
      );
      final nextLabelHeight = _maximumLabelHeight(
        nextScale,
        measureText: measureText,
      );
      final isStable =
          nextMaximumTickCount == maximumTickCount &&
          nextScale == scale &&
          (nextLabelHeight - labelHeight).abs() < 0.001;
      maximumTickCount = nextMaximumTickCount;
      scale = nextScale;
      labelHeight = nextLabelHeight;
      if (isStable) {
        break;
      }
    }

    final vertical = _verticalGeometry(
      height: height,
      axisLabelHeight: labelHeight,
      dateLabelHeight: dateLabelHeight,
    );
    maximumTickCount = calculateDurationAxisTickCapacity(
      plotHeight: vertical.plotHeight,
      labelHeight: labelHeight,
    );
    scale = DurationAxisScale.forMaximum(
      step: step,
      maximumDuration: maximumDuration,
      maximumTickCount: maximumTickCount,
    );

    final measuredLabels = [
      for (final tick in scale.ticks)
        (
          tick: tick,
          label: scale.labelFor(tick),
          size: measureText(scale.labelFor(tick)),
        ),
    ];
    labelHeight = measuredLabels
        .map((entry) => entry.size.height)
        .fold<double>(0, math.max);

    final finalVertical = _verticalGeometry(
      height: height,
      axisLabelHeight: labelHeight,
      dateLabelHeight: dateLabelHeight,
    );
    final widestAxisLabel = measuredLabels
        .map((entry) => entry.size.width)
        .fold<double>(0, math.max);
    final plotRight = math.max(0.0, width - 24);
    final maximumPlotLeft = math.max(
      0.0,
      plotRight - durationAxisMinimumPlotWidth,
    );
    final plotLeft = math.min(
      math.max(56.0, widestAxisLabel + 16),
      maximumPlotLeft,
    );
    final ticks = [
      for (final entry in measuredLabels)
        _tickLayout(
          entry: entry,
          scale: scale,
          plotLeft: plotLeft,
          plotTop: finalVertical.plotTop,
          plotBottom: finalVertical.plotBottom,
        ),
    ];

    return DurationAxisLayout._(
      scale: scale,
      maximumTickCount: maximumTickCount,
      labelHeight: labelHeight,
      plotLeft: plotLeft,
      plotRight: plotRight,
      plotTop: finalVertical.plotTop,
      plotBottom: finalVertical.plotBottom,
      ticks: ticks,
    );
  }

  static double chartHeightFor({
    required TextStyle textStyle,
    required TextScaler textScaler,
    required ui.TextDirection textDirection,
  }) {
    final axisLabelHeight = _measureText(
      '0123456789分秒',
      textStyle: textStyle,
      textScaler: textScaler,
      textDirection: textDirection,
    ).height;
    final dateLabelHeight = _measureText(
      '12/28',
      textStyle: textStyle,
      textScaler: textScaler,
      textDirection: textDirection,
    ).height;
    final topInset = math.max(16.0, axisLabelHeight / 2 + 8);
    final bottomInset = math.max(
      42.0,
      axisLabelHeight / 2 + durationAxisCrossAxisLabelGap + dateLabelHeight,
    );
    final minimumForTwoLabels =
        topInset + bottomInset + axisLabelHeight + durationAxisMinimumLabelGap;
    return math.max(
      durationAxisMinimumChartHeight,
      math.max(
        260 + math.max(axisLabelHeight, dateLabelHeight) * 4,
        minimumForTwoLabels,
      ),
    );
  }

  final DurationAxisScale scale;
  final int maximumTickCount;
  final double labelHeight;
  final double plotLeft;
  final double plotRight;
  final double plotTop;
  final double plotBottom;
  final List<DurationAxisTickLayout> ticks;

  double get plotWidth => plotRight - plotLeft;
  double get plotHeight => plotBottom - plotTop;

  @override
  bool operator ==(Object other) {
    return other is DurationAxisLayout &&
        other.scale == scale &&
        other.maximumTickCount == maximumTickCount &&
        other.labelHeight == labelHeight &&
        other.plotLeft == plotLeft &&
        other.plotRight == plotRight &&
        other.plotTop == plotTop &&
        other.plotBottom == plotBottom &&
        _listEquals(other.ticks, ticks);
  }

  @override
  int get hashCode => Object.hash(
    scale,
    maximumTickCount,
    labelHeight,
    plotLeft,
    plotRight,
    plotTop,
    plotBottom,
    Object.hashAll(ticks),
  );
}

DurationAxisTickLayout _tickLayout({
  required ({Duration tick, String label, Size size}) entry,
  required DurationAxisScale scale,
  required double plotLeft,
  required double plotTop,
  required double plotBottom,
}) {
  final ratio = scale.ratioFor(entry.tick);
  final y = plotBottom - (plotBottom - plotTop) * ratio;
  return DurationAxisTickLayout(
    tick: entry.tick,
    label: entry.label,
    y: y,
    labelBounds: Rect.fromLTWH(
      plotLeft - 8 - entry.size.width,
      y - entry.size.height / 2,
      entry.size.width,
      entry.size.height,
    ),
  );
}

({double plotTop, double plotBottom, double plotHeight}) _verticalGeometry({
  required double height,
  required double axisLabelHeight,
  required double dateLabelHeight,
}) {
  final plotTop = math.max(16.0, axisLabelHeight / 2 + 8);
  final plotBottomInset = math.max(
    42.0,
    axisLabelHeight / 2 + durationAxisCrossAxisLabelGap + dateLabelHeight,
  );
  final plotBottom = math.max(plotTop, height - plotBottomInset);
  return (
    plotTop: plotTop,
    plotBottom: plotBottom,
    plotHeight: plotBottom - plotTop,
  );
}

double _maximumLabelHeight(
  DurationAxisScale scale, {
  required DurationAxisTextMeasurer measureText,
}) {
  return scale.ticks
      .map(scale.labelFor)
      .map(measureText)
      .map((size) => size.height)
      .fold<double>(0, math.max);
}

Size _measureText(
  String value, {
  required TextStyle textStyle,
  required TextScaler textScaler,
  required ui.TextDirection textDirection,
}) {
  final painter = TextPainter(
    text: TextSpan(text: value, style: textStyle),
    textDirection: textDirection,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();
  return painter.size;
}

bool _listEquals<T>(List<T> first, List<T> second) {
  if (identical(first, second)) {
    return true;
  }
  if (first.length != second.length) {
    return false;
  }
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) {
      return false;
    }
  }
  return true;
}
