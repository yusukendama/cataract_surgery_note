import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/providers.dart';
import '../../domain/duration_formatters.dart';
import '../../domain/surgery_models.dart';
import '../../domain/surgery_trend.dart';
import '../records/record_detail_screen.dart';
import 'analysis_metric_selector.dart';
import 'analysis_summary.dart';
import 'surgery_trend_chart.dart';

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
          AnalysisMetricSelector(
            selectedStep: _selectedStep,
            onTap: _selectMetric,
          ),
          const SizedBox(height: 16),
          if (trend.summary != null)
            AnalysisSummarySection(summary: trend.summary!),
          if (trend.summary != null) const SizedBox(height: 16),
          if (trend.points.isEmpty)
            _MessageState(
              icon: Icons.show_chart,
              title: '「${_selectedStep.label}」の計測データがありません',
              message: '工程の開始時刻と終了時刻を記録すると、ここに表示されます。',
            )
          else ...[
            SurgeryTrendChart(
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
    final selected = await showAnalysisMetricPicker(
      context: context,
      selectedStep: _selectedStep,
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
    try {
      final refreshed = await _reloadAnalysis();
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
    await _reloadAnalysis();
  }

  Future<SurgeryAnalysisSnapshot> _reloadAnalysis() {
    ref.invalidate(surgeryAnalysisProvider);
    return ref.read(surgeryAnalysisProvider.future);
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
