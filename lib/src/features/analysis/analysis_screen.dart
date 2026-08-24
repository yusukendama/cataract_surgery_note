import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/semantics.dart';
import 'package:intl/intl.dart';

import '../../data/providers.dart';
import '../../data/record_video_service.dart';
import '../../domain/duration_formatters.dart';
import '../../domain/surgery_models.dart';
import '../../domain/surgery_trend.dart';
import '../../widgets/app_snack_bar.dart';
import '../records/record_detail_screen.dart';
import '../review/step_review_screen.dart';
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

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _trendChartFocusKey = GlobalKey();
  final GlobalKey _emptyStateKey = GlobalKey();
  SurgicalStep _selectedStep = SurgicalStep.totalSurgeryTime;
  String? _selectedRecordId;
  bool _directJumpBusy = false;
  bool _showDirectJumpBusy = false;
  int _directJumpGeneration = 0;
  int _analysisReloadGeneration = 0;
  double? _pendingScrollOffset;
  SurgeryAnalysisSnapshot? _lastStableAnalysisSnapshot;

  @override
  void dispose() {
    _directJumpGeneration++;
    _analysisReloadGeneration++;
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(surgeryAnalysisProvider);
    final frozenSnapshot = _directJumpBusy ? _lastStableAnalysisSnapshot : null;
    final content = frozenSnapshot != null
        ? _buildContent(frozenSnapshot)
        : snapshot.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => _ErrorState(onRetry: _retry),
            data: (value) {
              _lastStableAnalysisSnapshot = value;
              return _buildContent(value);
            },
          );
    return Scaffold(
      appBar: AppBar(title: const Text('分析')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          AbsorbPointer(absorbing: _directJumpBusy, child: content),
          if (_showDirectJumpBusy) const _DirectJumpBusyIndicator(),
        ],
      ),
    );
  }

  Widget _buildContent(SurgeryAnalysisSnapshot snapshot) {
    if (snapshot.recordCount == 0) {
      return _MessageState(
        focusTargetKey: _emptyStateKey,
        icon: Icons.query_stats,
        title: 'まだ症例がありません',
        message: '症例を登録すると、手術時間の変化を確認できます。',
      );
    }

    final trend = _calculator.calculate(snapshot.measurements, _selectedStep);
    final selectedIndex = _selectedIndexFor(trend.points);
    final effectiveSelectedRecordId = selectedIndex < 0
        ? null
        : trend.points[selectedIndex].recordId;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        key: const Key('analysis-content'),
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          AnalysisMetricSelector(
            selectedStep: _selectedStep,
            onTap: _directJumpBusy
                ? null
                : () => _selectMetric(effectiveSelectedRecordId),
          ),
          const SizedBox(height: 16),
          if (trend.summary != null)
            AnalysisSummarySection(summary: trend.summary!),
          if (trend.summary != null) const SizedBox(height: 16),
          if (trend.points.isEmpty)
            _MessageState(
              focusTargetKey: _emptyStateKey,
              icon: Icons.show_chart,
              title: '「${_selectedStep.label}」の計測データがありません',
              message: '工程の開始時刻と終了時刻を記録すると、ここに表示されます。',
            )
          else ...[
            SurgeryTrendChart(
              focusTargetKey: _trendChartFocusKey,
              points: trend.points,
              selectedRecordId: effectiveSelectedRecordId,
              enabled: !_directJumpBusy,
              onPointSelected: (point) {
                if (_directJumpBusy) {
                  return;
                }
                setState(() => _selectedRecordId = point.recordId);
              },
              onPointActivated: _selectedStep.isTotalSurgeryTime
                  ? null
                  : _activateDirectJump,
            ),
            if (trend.points.length == 1) ...[
              const SizedBox(height: 8),
              const Text('あと1件記録すると推移を確認できます', textAlign: TextAlign.center),
            ],
            if (selectedIndex >= 0) ...[
              const SizedBox(height: 16),
              _SelectedPointCard(
                point: trend.points[selectedIndex],
                position: selectedIndex + 1,
                total: trend.points.length,
                onSelectPrevious: !_directJumpBusy && selectedIndex > 0
                    ? () => _selectAdjacent(trend.points, selectedIndex - 1)
                    : null,
                onSelectNext:
                    !_directJumpBusy && selectedIndex < trend.points.length - 1
                    ? () => _selectAdjacent(trend.points, selectedIndex + 1)
                    : null,
                onOpenDetails: _directJumpBusy
                    ? null
                    : () => _openRecord(trend.points[selectedIndex]),
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

  int _selectedIndexFor(List<SurgeryTrendPoint> points) {
    if (points.isEmpty) {
      return -1;
    }
    final selectedIndex = points.indexWhere(
      (point) => point.recordId == _selectedRecordId,
    );
    return selectedIndex < 0 ? points.length - 1 : selectedIndex;
  }

  Future<void> _selectMetric(String? currentlySelectedRecordId) async {
    if (_directJumpBusy) {
      return;
    }
    final selected = await showAnalysisMetricPicker(
      context: context,
      selectedStep: _selectedStep,
    );
    if (selected == null ||
        selected == _selectedStep ||
        !mounted ||
        _directJumpBusy) {
      return;
    }
    setState(() {
      _selectedStep = selected;
      // 新指標に同じ症例があれば選択を維持し、なければ
      // 次のbuildでその指標の最新症例へfallbackする。
      _selectedRecordId = currentlySelectedRecordId;
    });
  }

  void _selectAdjacent(List<SurgeryTrendPoint> points, int index) {
    if (_directJumpBusy) {
      return;
    }
    setState(() => _selectedRecordId = points[index].recordId);
  }

  Future<void> _activateDirectJump(SurgeryTrendPoint point) async {
    if (!mounted ||
        _directJumpBusy ||
        point.step.isTotalSurgeryTime ||
        !activeIndividualSurgicalSteps.contains(point.step)) {
      return;
    }
    final generation = _beginDirectJump(point);
    final repository = ref.read(surgeryRepositoryProvider);

    SurgeryRecord? record;
    SurgicalStepReview? review;
    try {
      record = await repository.getRecord(point.recordId);
      if (!_isCurrentDirectJump(generation)) {
        return;
      }
      if (record == null) {
        await _handleMissingRecord(generation);
        return;
      }

      review = await repository.getStepReview(
        surgeryRecordId: point.recordId,
        step: point.step,
      );
      if (!_isCurrentDirectJump(generation)) {
        return;
      }

      // Distinguish a missing review row from a record deleted between reads.
      final latestRecord = await repository.getRecord(point.recordId);
      if (!_isCurrentDirectJump(generation)) {
        return;
      }
      if (latestRecord == null) {
        await _handleMissingRecord(generation);
        return;
      }
      record = latestRecord;
    } on Object {
      _finishDirectJumpWithMessage(
        generation,
        point: point,
        message: '症例を確認できませんでした。もう一度お試しください。',
        retryable: true,
      );
      return;
    }

    final startMilliseconds = review?.startMilliseconds;
    if (review == null || startMilliseconds == null || startMilliseconds < 0) {
      await _pushRecordDetailFallback(
        generation,
        recordId: point.recordId,
        message: 'この工程の記録位置を取得できませんでした。',
      );
      return;
    }

    RecordVideoState videoState;
    try {
      videoState = await ref
          .read(recordVideoServiceProvider)
          .inspectVideoState(record);
    } on Object {
      _finishDirectJumpWithMessage(
        generation,
        point: point,
        message: '動画の状態を確認できませんでした。もう一度お試しください。',
        retryable: true,
      );
      return;
    }
    if (!mounted || !_isCurrentDirectJump(generation)) {
      return;
    }

    // The file check can outlive a record deletion, a video replacement, or a
    // timing edit. Never apply its result to a different persisted snapshot.
    try {
      final latestReview = await repository.getStepReview(
        surgeryRecordId: point.recordId,
        step: point.step,
      );
      if (!_isCurrentDirectJump(generation)) {
        return;
      }
      final latestRecord = await repository.getRecord(point.recordId);
      if (!_isCurrentDirectJump(generation)) {
        return;
      }
      if (latestRecord == null) {
        await _handleMissingRecord(generation);
        return;
      }
      final latestStartMilliseconds = latestReview?.startMilliseconds;
      if (latestReview == null ||
          latestStartMilliseconds == null ||
          latestStartMilliseconds < 0) {
        await _pushRecordDetailFallback(
          generation,
          recordId: point.recordId,
          message: 'この工程の記録位置を取得できませんでした。',
        );
        return;
      }
      if (latestRecord.videoPath != record.videoPath) {
        _finishDirectJumpWithMessage(
          generation,
          point: point,
          message: '動画が更新されました。もう一度お試しください。',
          retryable: true,
        );
        return;
      }
    } on Object {
      _finishDirectJumpWithMessage(
        generation,
        point: point,
        message: '症例を確認できませんでした。もう一度お試しください。',
        retryable: true,
      );
      return;
    }

    switch (videoState.kind) {
      case RecordVideoStateKind.availableManaged:
      case RecordVideoStateKind.availableLegacy:
        await _pushDirectDestination(
          generation,
          StepReviewScreen(
            recordId: point.recordId,
            initialStepStorageId: point.step.storageId,
          ),
        );
        return;
      case RecordVideoStateKind.unregistered:
        await _pushVideoFallback(generation, point, 'この症例には動画が登録されていません。');
        return;
      case RecordVideoStateKind.missing:
        await _pushVideoFallback(
          generation,
          point,
          '保存した動画が見つかりません。再登録または差し替えを行ってください。',
        );
        return;
      case RecordVideoStateKind.invalidReference:
        await _pushVideoFallback(generation, point, '動画の参照が無効です。動画を再登録してください。');
        return;
      case RecordVideoStateKind.checkFailed:
        await _pushVideoFallback(
          generation,
          point,
          '動画の状態を確認できませんでした。再確認してください。',
        );
        return;
    }
  }

  int _beginDirectJump(SurgeryTrendPoint point) {
    final generation = ++_directJumpGeneration;
    setState(() {
      _selectedRecordId = point.recordId;
      _directJumpBusy = true;
      // If the asynchronous preflight is still pending, this state is painted
      // on the very next frame. A synchronously completed preflight clears it
      // before that frame, so short operations still avoid a visible flash.
      _showDirectJumpBusy = true;
    });
    return generation;
  }

  bool _isCurrentDirectJump(int generation) {
    if (!_ownsDirectJump(generation)) {
      return false;
    }
    if (ModalRoute.of(context)?.isCurrent == true) {
      return true;
    }
    _directJumpGeneration++;
    setState(() {
      _directJumpBusy = false;
      _showDirectJumpBusy = false;
    });
    return false;
  }

  bool _ownsDirectJump(int generation) {
    return mounted && _directJumpBusy && generation == _directJumpGeneration;
  }

  void _endDirectJump(int generation) {
    if (!_ownsDirectJump(generation)) {
      return;
    }
    final currentSnapshot = ref.read(surgeryAnalysisProvider).asData?.value;
    setState(() {
      _directJumpBusy = false;
      _showDirectJumpBusy = false;
      if (currentSnapshot != null) {
        _selectedRecordId = _selectionForSnapshot(currentSnapshot);
      }
    });
  }

  void _finishDirectJumpWithMessage(
    int generation, {
    required SurgeryTrendPoint point,
    required String message,
    required bool retryable,
  }) {
    if (!_isCurrentDirectJump(generation)) {
      return;
    }
    _endDirectJump(generation);
    showAppSnackBar(
      context,
      message: message,
      tone: AppFeedbackTone.failure,
      actionLabel: retryable ? '再試行' : null,
      onAction: retryable ? () => _activateDirectJump(point) : null,
    );
  }

  Future<void> _handleMissingRecord(int generation) async {
    var reloadSucceeded = false;
    try {
      await _reloadAnalysis();
      reloadSucceeded = true;
    } on Object {
      // The provider's error state and retry affordance remain authoritative.
    }
    if (!mounted || !_isCurrentDirectJump(generation)) {
      return;
    }
    _endDirectJump(generation);
    if (reloadSucceeded) {
      // The reload intentionally defers selection/focus while direct-jump busy
      // is active. Restore focus only after ending that busy state so the
      // refreshed chart or empty-state heading can receive it.
      _restoreAccessibilityFocusAfterBuild();
    }
    showAppSnackBar(
      context,
      message: '症例が見つかりませんでした。',
      tone: AppFeedbackTone.warning,
    );
  }

  Future<void> _pushVideoFallback(
    int generation,
    SurgeryTrendPoint point,
    String message,
  ) {
    return _pushRecordDetailFallback(
      generation,
      recordId: point.recordId,
      message: message,
    );
  }

  Future<void> _pushRecordDetailFallback(
    int generation, {
    required String recordId,
    required String message,
  }) {
    if (!_isCurrentDirectJump(generation)) {
      return Future<void>.value();
    }
    // These providers are intentionally long-lived. A prior detail/review
    // visit must not leave a stale video card on the fallback destination.
    ref.invalidate(surgeryRecordProvider(recordId));
    ref.invalidate(recordVideoStateProvider(recordId));
    ref.invalidate(surgeryRecordProgressProvider);
    return _pushDirectDestination(
      generation,
      RecordDetailScreen(recordId: recordId, initialNotice: message),
    );
  }

  Future<void> _pushDirectDestination(
    int generation,
    Widget destination,
  ) async {
    if (!_isCurrentDirectJump(generation)) {
      return;
    }
    // Capture while the analysis ListView is still attached. The destination
    // can invalidate the analysis provider while this route is offstage,
    // detaching or shortening the list before the user returns.
    _captureScrollOffset();
    final routeFuture = Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => destination));
    _endDirectJump(generation);
    await routeFuture;
    if (!mounted) {
      return;
    }
    try {
      if (await _reloadAnalysis()) {
        _restoreAccessibilityFocusAfterBuild();
      }
    } on Object {
      // The provider's error state presents the retry UI.
    }
  }

  Future<void> _openRecord(SurgeryTrendPoint point) async {
    if (_directJumpBusy) {
      return;
    }
    _captureScrollOffset();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecordDetailScreen(recordId: point.recordId),
      ),
    );
    if (!mounted) {
      return;
    }
    try {
      if (await _reloadAnalysis()) {
        _restoreAccessibilityFocusAfterBuild();
      }
    } on Object {
      // The provider's error state presents the retry UI.
    }
  }

  Future<void> _refresh() async {
    if (_directJumpBusy) {
      return;
    }
    await _reloadAnalysis();
  }

  Future<bool> _reloadAnalysis() async {
    final generation = ++_analysisReloadGeneration;
    final directGeneration = _directJumpGeneration;
    _captureScrollOffset(preserveExisting: true);
    ref.invalidate(surgeryAnalysisProvider);
    final refreshed = await ref.read(surgeryAnalysisProvider.future);
    if (!mounted || generation != _analysisReloadGeneration) {
      return false;
    }
    if (_directJumpBusy || directGeneration != _directJumpGeneration) {
      _restoreScrollOffsetAfterBuild(generation: generation);
      return false;
    }
    _synchronizeSelection(refreshed);
    _restoreScrollOffsetAfterBuild(generation: generation);
    return true;
  }

  void _retry() {
    _retryAndRestoreAccessibilityFocus().ignore();
  }

  Future<void> _retryAndRestoreAccessibilityFocus() async {
    try {
      if (await _reloadAnalysis()) {
        _restoreAccessibilityFocusAfterBuild();
      }
    } on Object {
      // A subsequent retry remains available in the provider's error state.
    }
  }

  void _captureScrollOffset({bool preserveExisting = false}) {
    if (preserveExisting && _pendingScrollOffset != null) {
      return;
    }
    if (_scrollController.hasClients) {
      _pendingScrollOffset = _scrollController.offset;
    }
  }

  void _synchronizeSelection(SurgeryAnalysisSnapshot snapshot) {
    final nextSelection = _selectionForSnapshot(snapshot);
    if (_selectedRecordId != nextSelection) {
      setState(() => _selectedRecordId = nextSelection);
    }
  }

  String? _selectionForSnapshot(SurgeryAnalysisSnapshot snapshot) {
    final trend = _calculator.calculate(snapshot.measurements, _selectedStep);
    if (trend.points.isEmpty) {
      return null;
    }
    final stillSelected = trend.points.any(
      (point) => point.recordId == _selectedRecordId,
    );
    return stillSelected ? _selectedRecordId : trend.points.last.recordId;
  }

  void _restoreScrollOffsetAfterBuild({
    required int generation,
    int attempt = 0,
  }) {
    final target = _pendingScrollOffset;
    if (target == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _analysisReloadGeneration) {
        return;
      }
      if (!_scrollController.hasClients) {
        if (attempt < 2) {
          _restoreScrollOffsetAfterBuild(
            generation: generation,
            attempt: attempt + 1,
          );
        }
        return;
      }
      final position = _scrollController.position;
      _scrollController.jumpTo(
        target
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble(),
      );
      _pendingScrollOffset = null;
    });
  }

  void _restoreAccessibilityFocusAfterBuild({
    int? generation,
    int attempt = 0,
  }) {
    final expectedGeneration = generation ?? _analysisReloadGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          expectedGeneration != _analysisReloadGeneration ||
          _directJumpBusy ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final renderObject =
          _trendChartFocusKey.currentContext?.findRenderObject() ??
          _emptyStateKey.currentContext?.findRenderObject();
      if (renderObject == null) {
        if (attempt < 2) {
          _restoreAccessibilityFocusAfterBuild(
            generation: expectedGeneration,
            attempt: attempt + 1,
          );
        }
        return;
      }
      renderObject.sendSemanticsEvent(const FocusSemanticEvent());
    });
  }
}

class _DirectJumpBusyIndicator extends StatelessWidget {
  const _DirectJumpBusyIndicator();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      child: ColoredBox(
        color: colorScheme.surface.withAlpha(199),
        child: Center(
          child: FractionallySizedBox(
            widthFactor: 0.9,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Semantics(
                key: const Key('analysis-direct-jump-busy'),
                container: true,
                excludeSemantics: true,
                liveRegion: true,
                label: '工程動画を確認しています',
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    child: Row(
                      children: [
                        if (disableAnimations)
                          const SizedBox.square(
                            dimension: 24,
                            child: Icon(
                              Icons.hourglass_top_rounded,
                              key: Key('analysis-direct-jump-busy-static-icon'),
                            ),
                          )
                        else
                          const SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '工程動画を確認しています…',
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectedPointCard extends StatelessWidget {
  const _SelectedPointCard({
    required this.point,
    required this.position,
    required this.total,
    required this.onSelectPrevious,
    required this.onSelectNext,
    required this.onOpenDetails,
  });

  final SurgeryTrendPoint point;
  final int position;
  final int total;
  final VoidCallback? onSelectPrevious;
  final VoidCallback? onSelectNext;
  final VoidCallback? onOpenDetails;

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('yyyy年M月d日', 'ja_JP').format(point.surgeryDate);
    return Card(
      key: const Key('analysis-selected-point'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CaseNavigator(
              position: position,
              total: total,
              onPrevious: onSelectPrevious,
              onNext: onSelectNext,
            ),
            const SizedBox(height: 4),
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

class _CaseNavigator extends StatelessWidget {
  const _CaseNavigator({
    required this.position,
    required this.total,
    required this.onPrevious,
    required this.onNext,
  });

  final int position;
  final int total;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        IconButton(
          key: const Key('analysis-select-previous'),
          onPressed: onPrevious,
          icon: const Icon(Icons.chevron_left),
          tooltip: '前の症例',
        ),
        Expanded(
          child: Text(
            '$position / $total 症例目',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        IconButton(
          key: const Key('analysis-select-next'),
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right),
          tooltip: '次の症例',
        ),
      ],
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    required this.message,
    this.focusTargetKey,
  });

  final IconData icon;
  final String title;
  final String message;
  final Key? focusTargetKey;

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
          Semantics(
            key: focusTargetKey,
            header: true,
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
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
