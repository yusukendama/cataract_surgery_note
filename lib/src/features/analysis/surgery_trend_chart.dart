import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../domain/analysis_horizontal_axis.dart';
import '../../domain/calendar_day.dart';
import '../../domain/duration_formatters.dart';
import '../../domain/surgery_trend.dart';
import 'duration_axis_layout.dart';
import 'surgery_trend_chart_layout.dart';

class SurgeryTrendChart extends StatelessWidget {
  const SurgeryTrendChart({
    required this.points,
    required this.selectedRecordId,
    required this.onPointSelected,
    this.horizontalAxis,
    this.showProcessVideoHint = false,
    this.showSameDayHint = false,
    this.enabled = true,
    this.focusTargetKey,
    super.key,
  });

  final List<SurgeryTrendPoint> points;
  final String? selectedRecordId;
  final ValueChanged<SurgeryTrendPoint> onPointSelected;
  final AnalysisHorizontalAxis? horizontalAxis;
  final bool showProcessVideoHint;
  final bool showSameDayHint;
  final bool enabled;
  final Key? focusTargetKey;

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
    final axis = horizontalAxis ?? _fallbackHorizontalAxis();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('推移', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            Size measureText(String value) {
              final painter = TextPainter(
                text: TextSpan(text: value, style: textStyle),
                textDirection: textDirection,
                textScaler: textScaler,
              )..layout();
              return painter.size;
            }

            final layout = SurgeryTrendChartLayout.calculate(
              width: constraints.maxWidth,
              height: chartHeight,
              points: points,
              horizontalAxis: axis,
              measureText: measureText,
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KeyedSubtree(
                  key: const Key('analysis-trend-adjustable'),
                  child: Semantics(
                    key: focusTargetKey,
                    container: true,
                    excludeSemantics: true,
                    label: '${selectedPoint.step.label}の推移',
                    value: _semanticValue(selectedIndex, axis, layout),
                    increasedValue: selectedIndex < points.length - 1
                        ? _semanticValue(selectedIndex + 1, axis, layout)
                        : _semanticValue(selectedIndex, axis, layout),
                    decreasedValue: selectedIndex > 0
                        ? _semanticValue(selectedIndex - 1, axis, layout)
                        : _semanticValue(selectedIndex, axis, layout),
                    hint: _semanticHint(selectedIndex),
                    onIncrease: !enabled
                        ? null
                        : () {
                            if (selectedIndex < points.length - 1) {
                              onPointSelected(points[selectedIndex + 1]);
                            }
                          },
                    onDecrease: !enabled
                        ? null
                        : () {
                            if (selectedIndex > 0) {
                              onPointSelected(points[selectedIndex - 1]);
                            }
                          },
                    child: SizedBox(
                      height: chartHeight,
                      child: _ChartInteractionSurface(
                        key: const Key('analysis-chart-interaction'),
                        enabled: enabled,
                        layout: layout,
                        selectedRecordId: selectedRecordId,
                        onPointSelected: onPointSelected,
                        child: CustomPaint(
                          size: Size(constraints.maxWidth, chartHeight),
                          painter: TrendChartPainter(
                            layout: layout,
                            selectedRecordId: selectedPoint.recordId,
                            colorScheme: Theme.of(context).colorScheme,
                            textStyle: textStyle,
                            textScaler: textScaler,
                            textDirection: textDirection,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (showProcessVideoHint || showSameDayHint) ...[
                  const SizedBox(height: 8),
                  Text(
                    _visibleHint(),
                    key: const Key('analysis-chart-direct-hint'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            );
          },
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

  String _semanticValue(
    int index,
    AnalysisHorizontalAxis axis,
    SurgeryTrendChartLayout layout,
  ) {
    final point = points[index];
    final pointLayout = layout.points.firstWhere(
      (candidate) => candidate.point.recordId == point.recordId,
    );
    final date = DateFormat('yyyy年M月d日', 'ja_JP').format(point.surgeryDate);
    return '横軸は${axis.mode.label}。アプリ内の登録${axis.recordCount}症例を'
        '手術日順に並べた${pointLayout.caseOrdinal}番。'
        'この指標${points.length}件中${index + 1}件目。$date、${point.eyeSide.label}、'
        '${point.step.label}、${formatProcedureDuration(point.duration)}';
  }

  String _semanticHint(int index) {
    final selectionHint = _selectionSemanticHint(index);
    if (!showProcessVideoHint) {
      return selectionHint;
    }
    return '$selectionHint。選択後、症例詳細を見るボタンからこの工程の動画を開けます';
  }

  String _selectionSemanticHint(int index) {
    if (points.length == 1) {
      return 'この指標の計測済み症例は1件だけです';
    }
    if (index == 0) {
      return '最初の計測済み症例です。上下スワイプで次の計測済み症例へ移動します';
    }
    if (index == points.length - 1) {
      return '最後の計測済み症例です。上下スワイプで前の計測済み症例へ移動します';
    }
    return '上下スワイプで前後の計測済み症例を選択します';
  }

  String _visibleHint() {
    final parts = <String>[];
    if (showProcessVideoHint) {
      parts.add(
        'グラフをタップして症例を選び、「症例詳細を見る」から'
        '選択した工程の動画を確認します。',
      );
    }
    if (showSameDayHint) {
      parts.add('同日の症例は同じ横位置に表示されます。前後のボタンで各症例を確認できます。');
    }
    return parts.join(' ');
  }

  AnalysisHorizontalAxis _fallbackHorizontalAxis() {
    final catalog = <SurgeryAnalysisRecord>[
      for (var index = 0; index < points.length; index++)
        SurgeryAnalysisRecord(
          recordId: points[index].recordId,
          surgeryDate: points[index].surgeryDate,
          createdAt: points[index].createdAt,
          rawEyeSide: points[index].eyeSide.name,
          eyeSide: points[index].eyeSide,
          caseOrdinal: points[index].caseOrdinal > 0
              ? points[index].caseOrdinal
              : index + 1,
        ),
    ];
    final count = points.first.registeredRecordCount > 0
        ? points.first.registeredRecordCount
        : catalog.length;
    return AnalysisHorizontalAxis(
      mode: AnalysisHorizontalAxisMode.caseOrder,
      catalog: catalog,
      recordCount: count,
      referenceDate: CalendarDay.fromDateTime(points.last.surgeryDate),
    );
  }

  double _chartHeightFor({
    required TextScaler textScaler,
    required TextStyle textStyle,
    required ui.TextDirection textDirection,
  }) {
    return DurationAxisLayout.chartHeightFor(
      textStyle: textStyle,
      textScaler: textScaler,
      textDirection: textDirection,
    );
  }
}

/// Accepts completed single-pointer taps only. Raw pointer events merely
/// suppress taps that were part of a multi-pointer scale gesture.
class _ChartInteractionSurface extends StatefulWidget {
  const _ChartInteractionSurface({
    required this.enabled,
    required this.layout,
    required this.selectedRecordId,
    required this.onPointSelected,
    required this.child,
    super.key,
  });

  final bool enabled;
  final SurgeryTrendChartLayout layout;
  final String? selectedRecordId;
  final ValueChanged<SurgeryTrendPoint> onPointSelected;
  final Widget child;

  @override
  State<_ChartInteractionSurface> createState() =>
      _ChartInteractionSurfaceState();
}

class _ChartInteractionSurfaceState extends State<_ChartInteractionSurface> {
  int _activePointerCount = 0;
  int _resetGeneration = 0;
  bool _hadMultiplePointers = false;

  void _handlePointerDown(PointerDownEvent event) {
    _activePointerCount++;
    if (_activePointerCount > 1) {
      _hadMultiplePointers = true;
    }
  }

  void _handlePointerEnd(PointerEvent event) {
    _activePointerCount = math.max(0, _activePointerCount - 1);
    if (_activePointerCount != 0) {
      return;
    }
    final generation = ++_resetGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          generation == _resetGeneration &&
          _activePointerCount == 0) {
        _hadMultiplePointers = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerEnd,
      onPointerCancel: _handlePointerEnd,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: !widget.enabled
            ? null
            : (details) {
                if (_hadMultiplePointers) {
                  return;
                }
                final selected = widget.layout.selectPoint(
                  localPosition: details.localPosition,
                  selectedRecordId: widget.selectedRecordId,
                );
                if (selected != null) {
                  widget.onPointSelected(selected);
                }
              },
        onLongPress: !widget.enabled ? null : () {},
        child: widget.child,
      ),
    );
  }
}

/// Deterministic drawing commands consumed directly by [TrendChartPainter].
///
/// Tests inspect the same commands that drive the canvas, avoiding a parallel
/// reconstruction of line, marker, tick, or label geometry.
final class TrendChartLineVertexPaintCommand {
  const TrendChartLineVertexPaintCommand({
    required this.recordId,
    required this.offset,
  });

  final String recordId;
  final Offset offset;
}

final class TrendChartLinePaintCommand {
  TrendChartLinePaintCommand(List<TrendChartLineVertexPaintCommand> vertices)
    : vertices = List.unmodifiable(vertices);

  final List<TrendChartLineVertexPaintCommand> vertices;
}

enum TrendChartMarkerPaintKind { unselected, selected }

final class TrendChartMarkerPaintCommand {
  const TrendChartMarkerPaintCommand({
    required this.recordId,
    required this.center,
    required this.kind,
    required this.radius,
    required this.ringWidth,
  });

  final String recordId;
  final Offset center;
  final TrendChartMarkerPaintKind kind;
  final double radius;
  final double ringWidth;
}

final class TrendChartTickMarkPaintCommand {
  const TrendChartTickMarkPaintCommand({
    required this.start,
    required this.end,
  });

  final Offset start;
  final Offset end;
}

final class TrendChartLabelPaintCommand {
  const TrendChartLabelPaintCommand({required this.text, required this.origin});

  final String text;
  final Offset origin;
}

final class TrendChartPaintCommands {
  TrendChartPaintCommands({
    required this.line,
    required List<TrendChartMarkerPaintCommand> markers,
    required List<TrendChartTickMarkPaintCommand> horizontalTickMarks,
    required List<TrendChartLabelPaintCommand> horizontalLabels,
  }) : markers = List.unmodifiable(markers),
       horizontalTickMarks = List.unmodifiable(horizontalTickMarks),
       horizontalLabels = List.unmodifiable(horizontalLabels);

  final TrendChartLinePaintCommand? line;
  final List<TrendChartMarkerPaintCommand> markers;
  final List<TrendChartTickMarkPaintCommand> horizontalTickMarks;
  final List<TrendChartLabelPaintCommand> horizontalLabels;
}

TrendChartPaintCommands trendChartPaintCommands({
  required SurgeryTrendChartLayout layout,
  required String? selectedRecordId,
}) {
  final line = layout.points.length <= 1
      ? null
      : TrendChartLinePaintCommand([
          for (final pointLayout in layout.points)
            TrendChartLineVertexPaintCommand(
              recordId: pointLayout.point.recordId,
              offset: pointLayout.offset,
            ),
        ]);
  final markers = <TrendChartMarkerPaintCommand>[];
  for (final pointLayout in layout.points) {
    final selected = pointLayout.point.recordId == selectedRecordId;
    if (!selected && !pointLayout.markerVisible) {
      continue;
    }
    markers.add(
      TrendChartMarkerPaintCommand(
        recordId: pointLayout.point.recordId,
        center: pointLayout.offset,
        kind: selected
            ? TrendChartMarkerPaintKind.selected
            : TrendChartMarkerPaintKind.unselected,
        radius: selected ? 7 : 3.5,
        ringWidth: selected ? 3 : 1.5,
      ),
    );
  }
  return TrendChartPaintCommands(
    line: line,
    markers: markers,
    horizontalTickMarks: [
      for (final tick in layout.horizontalTicks)
        TrendChartTickMarkPaintCommand(
          start: Offset(tick.x, layout.plotBottom),
          end: Offset(tick.x, layout.plotBottom + 5),
        ),
    ],
    horizontalLabels: [
      for (final tick in layout.horizontalTicks)
        TrendChartLabelPaintCommand(
          text: tick.value.label,
          origin: tick.labelBounds.topLeft,
        ),
    ],
  );
}

class TrendChartPainter extends CustomPainter {
  const TrendChartPainter({
    required this.layout,
    required this.selectedRecordId,
    required this.colorScheme,
    required this.textStyle,
    required this.textScaler,
    required this.textDirection,
  });

  final SurgeryTrendChartLayout layout;
  final String? selectedRecordId;
  final ColorScheme colorScheme;
  final TextStyle textStyle;
  final TextScaler textScaler;
  final ui.TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final commands = trendChartPaintCommands(
      layout: layout,
      selectedRecordId: selectedRecordId,
    );
    _paintGrid(canvas);
    _paintLine(canvas, commands.line);
    _paintDots(canvas, commands.markers);
    _paintHorizontalLabels(
      canvas,
      commands.horizontalTickMarks,
      commands.horizontalLabels,
    );
  }

  void _paintGrid(Canvas canvas) {
    final gridPaint = Paint()
      ..color = colorScheme.outline
      ..strokeWidth = 1;
    for (final tick in layout.durationAxisLayout.ticks) {
      canvas.drawLine(
        Offset(layout.plotLeft, tick.y),
        Offset(layout.plotRight, tick.y),
        gridPaint,
      );
      _layoutText(tick.label).paint(canvas, tick.labelBounds.topLeft);
    }
  }

  void _paintLine(Canvas canvas, TrendChartLinePaintCommand? command) {
    if (command == null) {
      return;
    }
    final linePaint = Paint()
      ..color = colorScheme.primary
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    for (var index = 0; index < command.vertices.length; index++) {
      final offset = command.vertices[index].offset;
      if (index == 0) {
        path.moveTo(offset.dx, offset.dy);
      } else {
        path.lineTo(offset.dx, offset.dy);
      }
    }
    canvas.drawPath(path, linePaint);
  }

  void _paintDots(Canvas canvas, List<TrendChartMarkerPaintCommand> commands) {
    for (final command in commands) {
      final selected = command.kind == TrendChartMarkerPaintKind.selected;
      canvas.drawCircle(
        command.center,
        command.radius,
        Paint()
          ..color = selected
              ? colorScheme.primaryContainer
              : colorScheme.surface
          ..style = PaintingStyle.fill,
      );
      if (command.ringWidth > 0) {
        canvas.drawCircle(
          command.center,
          command.radius,
          Paint()
            ..color = colorScheme.primary
            ..strokeWidth = command.ringWidth
            ..style = PaintingStyle.stroke,
        );
      }
    }
  }

  void _paintHorizontalLabels(
    Canvas canvas,
    List<TrendChartTickMarkPaintCommand> tickMarks,
    List<TrendChartLabelPaintCommand> labels,
  ) {
    final tickPaint = Paint()
      ..color = colorScheme.outline
      ..strokeWidth = 1.5;
    for (final command in tickMarks) {
      canvas.drawLine(command.start, command.end, tickPaint);
    }
    for (final command in labels) {
      final painter = _layoutText(command.text);
      painter.paint(canvas, command.origin);
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

  @override
  bool shouldRepaint(TrendChartPainter oldDelegate) {
    return oldDelegate.selectedRecordId != selectedRecordId ||
        oldDelegate.colorScheme != colorScheme ||
        oldDelegate.textStyle != textStyle ||
        oldDelegate.textScaler != textScaler ||
        oldDelegate.textDirection != textDirection ||
        oldDelegate.layout != layout;
  }
}
