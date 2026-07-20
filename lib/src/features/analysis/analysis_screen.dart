import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/providers.dart';
import '../../domain/duration_formatters.dart';
import '../../domain/surgery_models.dart';
import '../../domain/surgery_trend.dart';
import '../records/record_detail_screen.dart';

class AnalysisScreen extends ConsumerStatefulWidget {
  const AnalysisScreen({super.key});

  @override
  ConsumerState<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends ConsumerState<AnalysisScreen> {
  static const _calculator = SurgeryTrendCalculator();

  final ScrollController _chartScrollController = ScrollController();
  SurgicalStep _selectedStep = SurgicalStep.totalSurgeryTime;
  String? _selectedRecordId;
  bool _shouldScrollToLatest = true;

  @override
  void dispose() {
    _chartScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(surgeryAnalysisProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('分析')),
      body: snapshot.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _ErrorState(onRetry: _retry),
        data: _buildContent,
      ),
    );
  }

  Widget _buildContent(SurgeryAnalysisSnapshot snapshot) {
    if (snapshot.recordCount == 0) {
      return const _MessageState(
        icon: Icons.query_stats,
        title: 'まだ症例がありません',
        message: '症例を登録すると、手術時間の変化を確認できます。',
      );
    }

    final trend = _calculator.calculate(snapshot.measurements, _selectedStep);
    _reconcileSelectedPoint(trend.points);
    if (_shouldScrollToLatest && trend.points.isNotEmpty) {
      _scheduleScrollToLatest();
    }

    final selectedPoint = trend.points
        .where((point) => point.recordId == _selectedRecordId)
        .firstOrNull;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        key: const Key('analysis-content'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _MetricSelector(selectedStep: _selectedStep, onTap: _selectMetric),
          const SizedBox(height: 16),
          if (trend.summary != null) _SummarySection(summary: trend.summary!),
          if (trend.summary != null) const SizedBox(height: 16),
          if (trend.points.isEmpty)
            _MessageState(
              icon: Icons.show_chart,
              title: '「${_selectedStep.label}」の計測データがありません',
              message: '工程の開始時刻と終了時刻を記録すると、ここに表示されます。',
            )
          else ...[
            _TrendChart(
              points: trend.points,
              selectedRecordId: _selectedRecordId,
              scrollController: _chartScrollController,
              onPointSelected: (point) {
                setState(() => _selectedRecordId = point.recordId);
              },
            ),
            if (trend.points.length == 1) ...[
              const SizedBox(height: 8),
              const Text('あと1件記録すると推移を確認できます', textAlign: TextAlign.center),
            ],
            if (selectedPoint != null) ...[
              const SizedBox(height: 16),
              _SelectedPointCard(
                point: selectedPoint,
                onOpenDetails: () => _openRecord(selectedPoint),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              '未計測または不正な時間は、グラフと平均から除外されています。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _selectMetric() async {
    final selected = await showModalBottomSheet<SurgicalStep>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: math.min(MediaQuery.sizeOf(context).height * 0.7, 620),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  '表示する時間',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: surgicalStepsInDisplayOrder.length,
                  itemBuilder: (context, index) {
                    final step = surgicalStepsInDisplayOrder[index];
                    return ListTile(
                      key: Key('analysis-metric-${step.storageId}'),
                      title: Text(step.label),
                      trailing: step == _selectedStep
                          ? const Icon(Icons.check)
                          : null,
                      selected: step == _selectedStep,
                      onTap: () => Navigator.pop(context, step),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || selected == _selectedStep || !mounted) {
      return;
    }
    setState(() {
      _selectedStep = selected;
      _selectedRecordId = null;
      _shouldScrollToLatest = true;
    });
  }

  Future<void> _openRecord(SurgeryTrendPoint point) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecordDetailScreen(recordId: point.recordId),
      ),
    );
    if (!mounted) {
      return;
    }
    ref.invalidate(surgeryAnalysisProvider);
    try {
      final refreshed = await ref.read(surgeryAnalysisProvider.future);
      final recordStillExists = refreshed.measurements.any(
        (measurement) => measurement.recordId == point.recordId,
      );
      if (!recordStillExists && mounted) {
        setState(() => _selectedRecordId = null);
      }
    } catch (_) {
      // The provider's error state presents the retry UI.
    }
  }

  Future<void> _refresh() async {
    ref.invalidate(surgeryAnalysisProvider);
    await ref.read(surgeryAnalysisProvider.future);
  }

  void _retry() {
    ref.invalidate(surgeryAnalysisProvider);
  }

  void _reconcileSelectedPoint(List<SurgeryTrendPoint> points) {
    final selectedRecordId = _selectedRecordId;
    if (selectedRecordId == null ||
        points.any((point) => point.recordId == selectedRecordId)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _selectedRecordId == selectedRecordId) {
        setState(() => _selectedRecordId = null);
      }
    });
  }

  void _scheduleScrollToLatest() {
    _shouldScrollToLatest = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_chartScrollController.hasClients) {
        return;
      }
      _chartScrollController.jumpTo(
        _chartScrollController.position.maxScrollExtent,
      );
    });
  }
}

class _MetricSelector extends StatelessWidget {
  const _MetricSelector({required this.selectedStep, required this.onTap});

  final SurgicalStep selectedStep;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        key: const Key('analysis-metric-selector'),
        title: const Text('表示する時間'),
        subtitle: Text(selectedStep.label),
        trailing: const Icon(Icons.unfold_more),
        onTap: onTap,
      ),
    );
  }
}

class _SummarySection extends StatelessWidget {
  const _SummarySection({required this.summary});

  final SurgeryTrendSummary summary;

  @override
  Widget build(BuildContext context) {
    final previousAverage = summary.previousAverage;
    final difference = summary.difference;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('比較サマリー', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _SummaryValue(
              label: '最新',
              value: formatMinutesSeconds(summary.latest),
            ),
            if (previousAverage != null)
              _SummaryValue(
                label: '直前${summary.comparisonCount}件平均',
                value: formatMinutesSeconds(previousAverage),
              ),
            if (difference != null)
              _SummaryValue(
                label: '差',
                value: formatSignedMinutesSeconds(difference),
                detail: _differenceDescription(difference),
              ),
          ],
        ),
        if (previousAverage == null) ...[
          const SizedBox(height: 8),
          const Text('比較できる過去データがありません'),
        ],
      ],
    );
  }

  String _differenceDescription(Duration difference) {
    final seconds = difference.inMilliseconds.abs() ~/ 1000;
    if (seconds == 0) {
      return '変化なし';
    }
    return difference.isNegative ? '$seconds秒短縮' : '$seconds秒延長';
  }
}

class _SummaryValue extends StatelessWidget {
  const _SummaryValue({required this.label, required this.value, this.detail});

  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 104),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 2),
              Text(value, style: Theme.of(context).textTheme.titleLarge),
              if (detail != null)
                Text(detail!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrendChart extends StatelessWidget {
  const _TrendChart({
    required this.points,
    required this.selectedRecordId,
    required this.scrollController,
    required this.onPointSelected,
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

class _SelectedPointCard extends StatelessWidget {
  const _SelectedPointCard({required this.point, required this.onOpenDetails});

  final SurgeryTrendPoint point;
  final VoidCallback onOpenDetails;

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('yyyy年M月d日').format(point.surgeryDate);
    return Card(
      key: const Key('analysis-selected-point'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('$date ${point.eyeSide.label}'),
            const SizedBox(height: 4),
            Text(
              '${point.step.label}：${formatProcedureDuration(point.duration)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onOpenDetails,
              icon: const Icon(Icons.open_in_new),
              label: const Text('症例詳細を見る'),
            ),
          ],
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

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 48,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('分析データを読み込めませんでした'),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('再読み込み')),
          ],
        ),
      ),
    );
  }
}
