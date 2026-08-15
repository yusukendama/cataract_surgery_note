import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/record_video_service.dart';
import '../../data/surgery_repository.dart';
import '../../data/surgery_video_picker.dart';
import '../../domain/duration_formatters.dart';
import '../../domain/surgery_models.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/app_states.dart';
import '../analysis/analysis_screen.dart';
import 'new_record_screen.dart';
import 'record_detail_screen.dart';
import 'record_month_group.dart';

typedef NewRecordScreenBuilder = Widget Function(SelectedSurgeryVideo video);

class RecordListScreen extends ConsumerWidget {
  const RecordListScreen({this.newRecordScreenBuilder, super.key});

  final NewRecordScreenBuilder? newRecordScreenBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(surgeryRecordsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('白内障執刀ノート'),
        actions: [
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
      body: records.when(
        data: (items) => _RecordList(
          items: items,
          onCreateRecord: () => _startNewRecord(context, ref),
        ),
        error: (_, _) => AppErrorState(
          message: '症例一覧を読み込めませんでした。',
          onRetry: () => ref.invalidate(surgeryRecordsProvider),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _startNewRecord(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('新規症例'),
      ),
    );
  }

  Future<void> _startNewRecord(BuildContext context, WidgetRef ref) async {
    final SelectedSurgeryVideo? selectedVideo;
    try {
      selectedVideo = await ref.read(surgeryVideoPickerProvider).pickVideo();
    } catch (_) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          message: '動画を選択できませんでした。写真へのアクセス権限を確認して、もう一度お試しください。',
          tone: AppFeedbackTone.failure,
        );
      }
      return;
    }
    if (!context.mounted || selectedVideo == null) {
      return;
    }
    final video = selectedVideo;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            newRecordScreenBuilder?.call(video) ??
            NewRecordScreen(initialVideo: video),
      ),
    );
  }
}

class _RecordList extends ConsumerWidget {
  const _RecordList({required this.items, required this.onCreateRecord});

  final List<SurgeryRecord> items;
  final VoidCallback onCreateRecord;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = groupRecordsByMonth(items);
    final progress = ref.watch(surgeryRecordProgressProvider);
    final progressByRecordId = <String, SurgeryRecordProgress>{
      for (final item
          in progress.asData?.value ?? const <SurgeryRecordProgress>[])
        item.record.id: item,
    };
    final scaledHeaderHeight = MediaQuery.textScalerOf(context).scale(16) + 24;
    final headerHeight = scaledHeaderHeight.clamp(48.0, 80.0);

    return CustomScrollView(
      key: const Key('record-list-scroll'),
      slivers: [
        if (groups.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: AppEmptyState(
              icon: Icons.note_add_outlined,
              title: 'まだ症例がありません',
              message: '手術動画を選び、工程時間と振り返りを記録しましょう。',
              actionLabel: '最初の症例を登録',
              onAction: onCreateRecord,
            ),
          )
        else ...[
          SliverToBoxAdapter(child: _TotalRecordCount(count: items.length)),
          if (progress.hasError)
            SliverToBoxAdapter(
              child: _SupportingDataWarning(
                onRetry: () => ref.invalidate(surgeryRecordProgressProvider),
              ),
            ),
          for (final group in groups)
            SliverMainAxisGroup(
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _MonthHeaderDelegate(
                    month: group.month,
                    count: group.records.length,
                    height: headerHeight,
                  ),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final record = group.records[index];
                    return _RecordListItem(
                      record: record,
                      progress: progressByRecordId[record.id],
                      progressPending: progress.isLoading,
                    );
                  }, childCount: group.records.length),
                ),
              ],
            ),
        ],
      ],
    );
  }
}

class _RecordListItem extends ConsumerWidget {
  const _RecordListItem({
    required this.record,
    required this.progress,
    required this.progressPending,
  });

  final SurgeryRecord record;
  final SurgeryRecordProgress? progress;
  final bool progressPending;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final videoState = ref.watch(recordVideoStateProvider(record.id));
    final progressLabel = _progressLabel;
    final totalDuration = progress?.totalSurgeryDuration;
    final videoLabel = videoState.when(
      data: _videoStateLabel,
      loading: () => '動画を確認中…',
      error: (_, _) => '動画を確認できません',
    );
    final dateLabel = _dateLabel(record.surgeryDate.toLocal());
    final semanticsLabel = <String>[
      dateLabel,
      record.eyeSide.label,
      progressLabel,
      if (totalDuration != null)
        '総手術時間 ${formatProcedureDuration(totalDuration)}',
      videoLabel,
    ].join('、');
    final colorScheme = Theme.of(context).colorScheme;
    void openRecord() {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RecordDetailScreen(recordId: record.id),
        ),
      );
    }

    return Semantics(
      key: Key('record-list-semantics-${record.id}'),
      button: true,
      label: semanticsLabel,
      onTap: openRecord,
      child: ExcludeSemantics(
        child: Card(
          key: Key('record-list-item-${record.id}'),
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: openRecord,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          dateLabel,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          record.eyeSide.label,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 8),
                        _RecordMetadataLine(
                          icon: Icons.fact_check_outlined,
                          text: progressLabel,
                        ),
                        if (totalDuration != null) ...[
                          const SizedBox(height: 4),
                          _RecordMetadataLine(
                            icon: Icons.timer_outlined,
                            text:
                                '総手術時間 ${formatProcedureDuration(totalDuration)}',
                          ),
                        ],
                        const SizedBox(height: 4),
                        _RecordMetadataLine(
                          icon: _videoStateIcon(videoState.asData?.value.kind),
                          text: videoLabel,
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
    );
  }

  String get _progressLabel {
    final snapshot = progress;
    if (snapshot == null) {
      return progressPending ? '工程を確認中…' : '工程情報を確認できません';
    }
    final completed = snapshot.completedStepCount == 0
        ? '未記録'
        : '工程 ${snapshot.completedStepCount}/10';
    final running = snapshot.hasRunningStep ? '・計測中' : '';
    return '$completed$running';
  }

  String _dateLabel(DateTime date) {
    const weekdays = <String>['月', '火', '水', '木', '金', '土', '日'];
    return '${date.month}月${date.day}日（${weekdays[date.weekday - 1]}）';
  }

  String _videoStateLabel(RecordVideoState state) => switch (state.kind) {
    RecordVideoStateKind.unregistered => '動画未登録',
    RecordVideoStateKind.availableManaged => '動画あり',
    RecordVideoStateKind.availableLegacy => '旧形式動画あり',
    RecordVideoStateKind.missing => '動画の実体なし',
    RecordVideoStateKind.invalidReference => '動画参照エラー',
    RecordVideoStateKind.checkFailed => '動画を確認できません',
  };

  IconData _videoStateIcon(RecordVideoStateKind? kind) => switch (kind) {
    RecordVideoStateKind.availableManaged ||
    RecordVideoStateKind.availableLegacy => Icons.videocam_outlined,
    RecordVideoStateKind.missing ||
    RecordVideoStateKind.invalidReference ||
    RecordVideoStateKind.checkFailed => Icons.warning_amber_outlined,
    RecordVideoStateKind.unregistered || null => Icons.videocam_off_outlined,
  };
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

class _TotalRecordCount extends StatelessWidget {
  const _TotalRecordCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      label: '総手術件数 $count件',
      child: ExcludeSemantics(
        child: Card(
          key: const Key('record-total-count'),
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          elevation: 0,
          color: colorScheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              children: [
                Flexible(child: Text('総手術件数', style: textTheme.titleMedium)),
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
      ),
    );
  }
}

class _MonthHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _MonthHeaderDelegate({
    required this.month,
    required this.count,
    required this.height,
  });

  final RecordMonth month;
  final int count;
  final double height;

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
    return Material(
      key: Key('record-month-header-${month.year}-${month.month}'),
      color: theme.colorScheme.surfaceContainer,
      elevation: overlapsContent ? 1 : 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Align(
          alignment: Alignment.centerLeft,
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
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _MonthHeaderDelegate oldDelegate) {
    return oldDelegate.month != month ||
        oldDelegate.count != count ||
        oldDelegate.height != height;
  }
}
