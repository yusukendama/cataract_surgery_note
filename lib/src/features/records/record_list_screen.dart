import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/record_video_service.dart';
import '../../data/surgery_repository.dart';
import '../../data/video_import_models.dart';
import '../../domain/duration_formatters.dart';
import '../../domain/surgery_models.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/app_states.dart';
import '../analysis/analysis_screen.dart';
import '../video_import/video_import_screen_flow.dart';
import '../video_import/video_import_ui_flow.dart';
import 'new_record_screen.dart';
import 'record_detail_screen.dart';
import 'record_list_help_button.dart';
import 'record_month_group.dart';

typedef NewRecordScreenBuilder =
    Widget Function(VerifiedVideoCandidate candidate);

class RecordListScreen extends ConsumerStatefulWidget {
  const RecordListScreen({this.newRecordScreenBuilder, super.key});

  final NewRecordScreenBuilder? newRecordScreenBuilder;

  @override
  ConsumerState<RecordListScreen> createState() => _RecordListScreenState();
}

class _RecordListScreenState extends ConsumerState<RecordListScreen> {
  List<SurgeryRecord>? _lastSuccessfulItems;
  late final VideoImportUiFlow _videoImportFlow;
  bool _isSelectingVideo = false;
  VideoImportException? _lastVideoImportError;

  @override
  void initState() {
    super.initState();
    _videoImportFlow = VideoImportUiFlow(
      picker: ref.read(surgeryVideoPickerProvider),
      preflight: ref.read(videoImportPreflightProvider),
    );
  }

  @override
  void dispose() {
    _videoImportFlow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final records = ref.watch(surgeryRecordsProvider);
    final latestItems = records.asData?.value;
    if (latestItems != null) {
      _lastSuccessfulItems = latestItems;
    }
    final retainedItems = _lastSuccessfulItems;
    final recordsBody = retainedItems == null
        ? records.when(
            data: (_) => const SizedBox.shrink(),
            error: (_, _) => AppErrorState(
              message: '症例一覧を読み込めませんでした。',
              onRetry: () => ref.invalidate(surgeryRecordsProvider),
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
          )
        : _RecordList(
            items: retainedItems,
            recordsLoadFailed: records.hasError,
            onRetryRecords: () => ref.invalidate(surgeryRecordsProvider),
            onCreateRecord: _isSelectingVideo ? null : _startNewRecord,
          );

    return Scaffold(
      appBar: AppBar(
        title: const Text('白内障執刀ノート'),
        actions: [
          const RecordListHelpButton(),
          IconButton(
            tooltip: '分析',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AnalysisScreen()),
              );
            },
            icon: const Icon(Icons.show_chart, semanticLabel: '分析'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_lastVideoImportError case final error?)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: VideoImportPersistentErrorNotice(
                error: error,
                onReselect: _isSelectingVideo ? null : _startNewRecord,
              ),
            ),
          Expanded(child: recordsBody),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isSelectingVideo ? null : _startNewRecord,
        icon: const Icon(Icons.add),
        label: const Text('新規症例'),
      ),
    );
  }

  Future<void> _startNewRecord() async {
    if (_isSelectingVideo || _videoImportFlow.isActive) {
      return;
    }
    setState(() => _isSelectingVideo = true);
    VerifiedVideoCandidate? candidate;
    try {
      candidate = await selectVerifiedVideoForScreen(
        context: context,
        flow: _videoImportFlow,
        entryPoint: VideoImportEntryPoint.create,
        onPersistentFailure: _rememberVideoImportFailure,
        dataInvariantSuffix: VideoImportDataInvariantSuffix.createNotRegistered,
      );
    } finally {
      if (mounted) {
        setState(() => _isSelectingVideo = false);
      }
    }
    if (!mounted || candidate == null) {
      return;
    }
    setState(() => _lastVideoImportError = null);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            widget.newRecordScreenBuilder?.call(candidate!) ??
            NewRecordScreen(initialVideo: candidate!),
      ),
    );
  }

  void _rememberVideoImportFailure(VideoImportException error) {
    if (mounted) {
      setState(() => _lastVideoImportError = error);
    }
  }
}

class _RecordList extends ConsumerStatefulWidget {
  const _RecordList({
    required this.items,
    required this.recordsLoadFailed,
    required this.onRetryRecords,
    required this.onCreateRecord,
  });

  final List<SurgeryRecord> items;
  final bool recordsLoadFailed;
  final VoidCallback onRetryRecords;
  final VoidCallback? onCreateRecord;

  @override
  ConsumerState<_RecordList> createState() => _RecordListState();
}

class _RecordListState extends ConsumerState<_RecordList> {
  final Set<RecordMonth> _expandedMonths = <RecordMonth>{};
  bool _showNeedsAttentionOnly = false;
  bool _monthStateInitialized = false;
  bool _expandFilteredMonthWhenReady = false;
  RecordMonth? _latestMonth;

  @override
  void initState() {
    super.initState();
    _synchronizeMonthState(widget.items);
  }

  @override
  void didUpdateWidget(covariant _RecordList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _synchronizeMonthState(widget.items);
  }

  @override
  Widget build(BuildContext context) {
    final allGroups = groupRecordsByMonth(widget.items);
    final progress = ref.watch(surgeryRecordProgressProvider);
    final progressByRecordId = <String, SurgeryRecordProgress>{
      for (final item
          in progress.asData?.value ?? const <SurgeryRecordProgress>[])
        item.record.id: item,
    };
    final videoStatesByRecordId = <String, AsyncValue<RecordVideoState>>{};
    if (_showNeedsAttentionOnly) {
      for (final record in widget.items) {
        videoStatesByRecordId[record.id] = ref.watch(
          recordVideoStateByReferenceProvider(RecordVideoStateRequest(record)),
        );
      }
    }
    final attentionByRecordId = <String, _AttentionResolution>{
      for (final record in widget.items)
        record.id: _resolveAttention(
          record: record,
          progress: progressByRecordId[record.id],
          progressPending: progress.isLoading,
          videoState: videoStatesByRecordId[record.id],
        ),
    };
    final visibleItems = _showNeedsAttentionOnly
        ? widget.items
              .where(
                (record) =>
                    attentionByRecordId[record.id] ==
                    _AttentionResolution.needsAttention,
              )
              .toList(growable: false)
        : widget.items;
    final visibleGroups = _showNeedsAttentionOnly
        ? groupRecordsByMonth(visibleItems)
        : allGroups;
    _ensureFilteredMonthExpansion(visibleGroups);

    final progressSnapshotMissing =
        progress.asData != null &&
        widget.items.any(
          (record) => !progressByRecordId.containsKey(record.id),
        );
    final supportingDataFailed = progress.hasError || progressSnapshotMissing;
    final attentionPending =
        _showNeedsAttentionOnly &&
        attentionByRecordId.values.contains(_AttentionResolution.pending);
    final attentionFailed =
        _showNeedsAttentionOnly &&
        attentionByRecordId.values.contains(_AttentionResolution.failed);
    final scaledHeaderHeight = MediaQuery.textScalerOf(context).scale(16) + 24;
    final headerHeight = scaledHeaderHeight.clamp(48.0, 80.0);

    return CustomScrollView(
      key: const Key('record-list-scroll'),
      slivers: [
        if (widget.recordsLoadFailed)
          SliverToBoxAdapter(
            child: _RecordListLoadWarning(onRetry: widget.onRetryRecords),
          ),
        if (allGroups.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: AppEmptyState(
              icon: Icons.note_add_outlined,
              title: 'まだ症例がありません',
              message: '手術動画を選び、工程時間と振り返りを記録しましょう。',
              actionLabel: widget.onCreateRecord == null ? null : '最初の症例を登録',
              onAction: widget.onCreateRecord,
            ),
          )
        else ...[
          SliverToBoxAdapter(
            child: _TotalRecordCount(
              count: widget.items.length,
              showNeedsAttentionOnly: _showNeedsAttentionOnly,
              onFilterChanged: _setNeedsAttentionFilter,
            ),
          ),
          if (supportingDataFailed)
            SliverToBoxAdapter(
              child: _SupportingDataWarning(
                onRetry: () => ref.invalidate(surgeryRecordProgressProvider),
              ),
            ),
          if (_showNeedsAttentionOnly &&
              attentionPending &&
              visibleGroups.isNotEmpty)
            const SliverToBoxAdapter(child: _AttentionCheckPending()),
          if (_showNeedsAttentionOnly && visibleGroups.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _FilteredEmptyState(
                isPending: attentionPending,
                hasFailure: attentionFailed,
              ),
            )
          else
            for (final group in visibleGroups)
              if (_expandedMonths.contains(group.month))
                SliverMainAxisGroup(
                  slivers: [
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _MonthHeaderDelegate(
                        month: group.month,
                        count: group.records.length,
                        height: headerHeight,
                        isExpanded: true,
                        onTap: () => _toggleMonth(group.month),
                      ),
                    ),
                    SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final record = group.records[index];
                        return _RecordListItem(
                          record: record,
                          progress: progressByRecordId[record.id],
                          progressPending: progress.isLoading,
                          prefetchedVideoState:
                              videoStatesByRecordId[record.id],
                        );
                      }, childCount: group.records.length),
                    ),
                  ],
                )
              else
                SliverPersistentHeader(
                  pinned: false,
                  delegate: _MonthHeaderDelegate(
                    month: group.month,
                    count: group.records.length,
                    height: headerHeight,
                    isExpanded: false,
                    onTap: () => _toggleMonth(group.month),
                  ),
                ),
        ],
      ],
    );
  }

  void _synchronizeMonthState(List<SurgeryRecord> items) {
    final groups = groupRecordsByMonth(items);
    final availableMonths = groups.map((group) => group.month).toSet();
    _expandedMonths.retainWhere(availableMonths.contains);

    final latest = groups.firstOrNull?.month;
    if (!_monthStateInitialized) {
      _monthStateInitialized = true;
      if (latest != null) {
        _expandedMonths.add(latest);
      }
    } else if (latest != null) {
      final previousLatest = _latestMonth;
      if (previousLatest == null ||
          _monthSortValue(latest) > _monthSortValue(previousLatest)) {
        _expandedMonths.add(latest);
      }
    }
    _latestMonth = latest;
  }

  void _ensureFilteredMonthExpansion(List<RecordMonthGroup> visibleGroups) {
    if (!_showNeedsAttentionOnly ||
        !_expandFilteredMonthWhenReady ||
        visibleGroups.isEmpty) {
      return;
    }
    final hasExpandedVisibleMonth = visibleGroups.any(
      (group) => _expandedMonths.contains(group.month),
    );
    if (!hasExpandedVisibleMonth) {
      _expandedMonths.add(visibleGroups.first.month);
    }
    _expandFilteredMonthWhenReady = false;
  }

  void _setNeedsAttentionFilter(bool selected) {
    setState(() {
      _showNeedsAttentionOnly = selected;
      _expandFilteredMonthWhenReady = selected;
    });
  }

  void _toggleMonth(RecordMonth month) {
    setState(() {
      if (!_expandedMonths.remove(month)) {
        _expandedMonths.add(month);
      }
      _expandFilteredMonthWhenReady = false;
    });
  }

  int _monthSortValue(RecordMonth month) => month.year * 100 + month.month;

  _AttentionResolution _resolveAttention({
    required SurgeryRecord record,
    required SurgeryRecordProgress? progress,
    required bool progressPending,
    required AsyncValue<RecordVideoState>? videoState,
  }) {
    final reviewResolution = switch (record.reviewSchemaVersion) {
      1 when progress != null => switch (progress.timingReviewStatus) {
        CaseTimingReviewStatus.notStarted ||
        CaseTimingReviewStatus.inProgress =>
          _AttentionResolution.needsAttention,
        CaseTimingReviewStatus.completed => _AttentionResolution.notNeeded,
        null => _AttentionResolution.failed,
      },
      1 when progressPending => _AttentionResolution.pending,
      1 => _AttentionResolution.failed,
      _ => _AttentionResolution.notNeeded,
    };
    final resolvedVideoState = videoState;
    final videoResolution = switch (resolvedVideoState) {
      null => _AttentionResolution.notNeeded,
      AsyncValue<RecordVideoState>(hasError: true) =>
        _AttentionResolution.needsAttention,
      AsyncValue<RecordVideoState>(isLoading: true) =>
        _AttentionResolution.pending,
      AsyncData<RecordVideoState>(:final value) => switch (value.kind) {
        RecordVideoStateKind.availableManaged ||
        RecordVideoStateKind.availableLegacy => _AttentionResolution.notNeeded,
        RecordVideoStateKind.unregistered ||
        RecordVideoStateKind.missing ||
        RecordVideoStateKind.invalidReference ||
        RecordVideoStateKind.checkFailed => _AttentionResolution.needsAttention,
      },
      _ => _AttentionResolution.pending,
    };

    if (reviewResolution == _AttentionResolution.needsAttention ||
        videoResolution == _AttentionResolution.needsAttention) {
      return _AttentionResolution.needsAttention;
    }
    if (reviewResolution == _AttentionResolution.failed ||
        videoResolution == _AttentionResolution.failed) {
      return _AttentionResolution.failed;
    }
    if (reviewResolution == _AttentionResolution.pending ||
        videoResolution == _AttentionResolution.pending) {
      return _AttentionResolution.pending;
    }
    return _AttentionResolution.notNeeded;
  }
}

enum _AttentionResolution { needsAttention, notNeeded, pending, failed }

class _RecordListItem extends ConsumerWidget {
  const _RecordListItem({
    required this.record,
    required this.progress,
    required this.progressPending,
    this.prefetchedVideoState,
  });

  final SurgeryRecord record;
  final SurgeryRecordProgress? progress;
  final bool progressPending;
  final AsyncValue<RecordVideoState>? prefetchedVideoState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<RecordVideoState> videoState;
    final prefetchedState = prefetchedVideoState;
    if (prefetchedState != null) {
      videoState = prefetchedState;
    } else {
      videoState = ref.watch(
        recordVideoStateByReferenceProvider(RecordVideoStateRequest(record)),
      );
    }
    final totalDurationLabel = _totalDurationLabel;
    final issues = _issues(videoState);
    final passiveIssues = issues
        .where((issue) => !issue.canRetry)
        .toList(growable: false);
    final retryIssues = issues
        .where((issue) => issue.canRetry)
        .toList(growable: false);
    final dateLabel = _dateLabel(record.surgeryDate);
    final semanticsLabel = <String>[
      dateLabel,
      record.eyeSide.label,
      totalDurationLabel,
      ...passiveIssues.map((issue) => issue.label),
    ].join('、');
    final colorScheme = Theme.of(context).colorScheme;
    void openRecord() {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RecordDetailScreen(recordId: record.id),
        ),
      );
    }

    return Card(
      key: Key('record-list-item-${record.id}'),
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            key: Key('record-list-semantics-${record.id}'),
            button: true,
            label: semanticsLabel,
            onTap: openRecord,
            child: ExcludeSemantics(
              child: InkWell(
                onTap: openRecord,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    16,
                    16,
                    issues.isEmpty ? 16 : 8,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 12,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  dateLabel,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                Text(
                                  record.eyeSide.label,
                                  style: Theme.of(context).textTheme.bodyLarge,
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            _RecordMetadataLine(
                              icon: Icons.timer_outlined,
                              text: totalDurationLabel,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.chevron_right,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (issues.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final issue in passiveIssues)
                    ExcludeSemantics(child: _RecordStatusChip(issue: issue)),
                  for (final issue in retryIssues)
                    _RetryVideoStatusChip(
                      recordId: record.id,
                      issue: issue,
                      onRetry: () => ref.invalidate(
                        recordVideoStateByReferenceProvider(
                          RecordVideoStateRequest(record),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String get _totalDurationLabel {
    final snapshot = progress;
    if (snapshot == null) {
      return progressPending ? '総手術時間 確認中…' : '総手術時間を確認できません';
    }
    final duration = snapshot.totalSurgeryDuration;
    return duration == null
        ? '総手術時間 未登録'
        : '総手術時間 ${formatProcedureDuration(duration)}';
  }

  String _dateLabel(DateTime date) {
    const weekdays = <String>['月', '火', '水', '木', '金', '土', '日'];
    return '${date.month}月${date.day}日（${weekdays[date.weekday - 1]}）';
  }

  List<_RecordIssue> _issues(AsyncValue<RecordVideoState> videoState) {
    final issues = <_RecordIssue>[];
    switch (progress?.timingReviewStatus) {
      case CaseTimingReviewStatus.notStarted:
        issues.add(const _RecordIssue('未レビュー', _RecordIssueTone.warning));
        break;
      case CaseTimingReviewStatus.inProgress:
        issues.add(const _RecordIssue('レビュー中', _RecordIssueTone.warning));
        break;
      case CaseTimingReviewStatus.completed:
      case null:
        break;
    }

    if (videoState.hasError) {
      issues.add(
        const _RecordIssue(
          '動画状態を確認できません',
          _RecordIssueTone.error,
          canRetry: true,
        ),
      );
      return issues;
    }
    final state = videoState.asData?.value;
    switch (state?.kind) {
      case RecordVideoStateKind.unregistered:
        issues.add(const _RecordIssue('動画なし', _RecordIssueTone.neutral));
        break;
      case RecordVideoStateKind.missing:
      case RecordVideoStateKind.invalidReference:
        issues.add(const _RecordIssue('動画を開けません', _RecordIssueTone.error));
        break;
      case RecordVideoStateKind.checkFailed:
        issues.add(
          const _RecordIssue(
            '動画状態を確認できません',
            _RecordIssueTone.error,
            canRetry: true,
          ),
        );
        break;
      case RecordVideoStateKind.availableManaged:
      case RecordVideoStateKind.availableLegacy:
      case null:
        break;
    }
    return issues;
  }
}

enum _RecordIssueTone { neutral, warning, error }

class _RecordIssue {
  const _RecordIssue(this.label, this.tone, {this.canRetry = false});

  final String label;
  final _RecordIssueTone tone;
  final bool canRetry;
}

class _RecordStatusChip extends StatelessWidget {
  const _RecordStatusChip({required this.issue});

  final _RecordIssue issue;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final semanticColors = context.semanticColors;
    final (backgroundColor, foregroundColor) = switch (issue.tone) {
      _RecordIssueTone.neutral => (
        colorScheme.surfaceContainerHighest,
        colorScheme.onSurfaceVariant,
      ),
      _RecordIssueTone.warning => (
        semanticColors.warningContainer,
        semanticColors.onWarningContainer,
      ),
      _RecordIssueTone.error => (
        colorScheme.errorContainer,
        colorScheme.onErrorContainer,
      ),
    };
    return Chip(
      label: Text(issue.label),
      labelStyle: TextStyle(color: foregroundColor),
      backgroundColor: backgroundColor,
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _RetryVideoStatusChip extends StatelessWidget {
  const _RetryVideoStatusChip({
    required this.recordId,
    required this.issue,
    required this.onRetry,
  });

  final String recordId;
  final _RecordIssue issue;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      key: Key('record-video-state-retry-$recordId'),
      label: '${issue.label}、再試行',
      button: true,
      onTap: onRetry,
      child: ExcludeSemantics(
        child: Tooltip(
          message: '動画状態を再確認',
          child: ActionChip(
            avatar: const Icon(Icons.refresh, size: 18),
            label: Text(issue.label),
            onPressed: onRetry,
            backgroundColor: colorScheme.errorContainer,
            labelStyle: TextStyle(color: colorScheme.onErrorContainer),
            side: BorderSide.none,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
    );
  }
}

class _RecordMetadataLine extends StatelessWidget {
  const _RecordMetadataLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

class _RecordListLoadWarning extends StatelessWidget {
  const _RecordListLoadWarning({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('record-list-load-warning'),
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.sync_problem_outlined),
            const SizedBox(width: 8),
            const Expanded(child: Text('症例一覧を更新できませんでした。')),
            TextButton(onPressed: onRetry, child: const Text('再読み込み')),
          ],
        ),
      ),
    );
  }
}

class _SupportingDataWarning extends StatelessWidget {
  const _SupportingDataWarning({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.info_outline),
            const SizedBox(width: 8),
            const Expanded(child: Text('工程情報を読み込めませんでした。')),
            TextButton(onPressed: onRetry, child: const Text('再読み込み')),
          ],
        ),
      ),
    );
  }
}

class _AttentionCheckPending extends StatelessWidget {
  const _AttentionCheckPending();

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('record-attention-check-pending'),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Expanded(child: Text('要対応の症例を確認しています…')),
          ],
        ),
      ),
    );
  }
}

class _FilteredEmptyState extends StatelessWidget {
  const _FilteredEmptyState({
    required this.isPending,
    required this.hasFailure,
  });

  final bool isPending;
  final bool hasFailure;

  @override
  Widget build(BuildContext context) {
    final (icon, message) = switch ((isPending, hasFailure)) {
      (true, _) => (Icons.hourglass_top_outlined, '要対応の症例を確認しています…'),
      (_, true) => (Icons.error_outline, '要対応状態を確認できませんでした。再読み込みしてください。'),
      _ => (Icons.check_circle_outline, '要対応の症例はありません'),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 36,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              key: const Key('record-attention-empty-state'),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalRecordCount extends StatelessWidget {
  const _TotalRecordCount({
    required this.count,
    required this.showNeedsAttentionOnly,
    required this.onFilterChanged,
  });

  final int count;
  final bool showNeedsAttentionOnly;
  final ValueChanged<bool> onFilterChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      key: const Key('record-total-count'),
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 8,
          children: [
            Semantics(
              container: true,
              label: '総手術件数 $count件',
              child: ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('総手術件数', style: textTheme.titleMedium),
                    const SizedBox(width: 16),
                    Text(
                      '$count件',
                      key: const Key('record-total-count-value'),
                      style: textTheme.headlineSmall?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Semantics(
              label: '要対応のみ',
              button: true,
              selected: showNeedsAttentionOnly,
              onTap: () => onFilterChanged(!showNeedsAttentionOnly),
              child: ExcludeSemantics(
                child: FilterChip(
                  key: const Key('record-needs-attention-filter'),
                  label: const Text('要対応のみ'),
                  selected: showNeedsAttentionOnly,
                  onSelected: onFilterChanged,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _MonthHeaderDelegate({
    required this.month,
    required this.count,
    required this.height,
    required this.isExpanded,
    required this.onTap,
  });

  final RecordMonth month;
  final int count;
  final double height;
  final bool isExpanded;
  final VoidCallback onTap;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    final expansionLabel = isExpanded ? '展開中' : '折りたたみ中';
    return Semantics(
      key: Key('record-month-header-${month.year}-${month.month}'),
      label: '${month.label}、$count件、$expansionLabel',
      button: true,
      onTap: onTap,
      child: ExcludeSemantics(
        child: SizedBox.expand(
          child: Material(
            color: theme.colorScheme.surfaceContainer,
            elevation: overlapsContent ? 1 : 0,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(
                      isExpanded ? Icons.expand_more : Icons.chevron_right,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${month.label}　$count件',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _MonthHeaderDelegate oldDelegate) {
    return oldDelegate.month != month ||
        oldDelegate.count != count ||
        oldDelegate.height != height ||
        oldDelegate.isExpanded != isExpanded;
  }
}
