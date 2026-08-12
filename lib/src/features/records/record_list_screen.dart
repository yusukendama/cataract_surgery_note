import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/surgery_video_picker.dart';
import '../../domain/surgery_models.dart';
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
        data: (items) => _RecordList(items: items),
        error: (error, _) => Center(child: Text('読み込みに失敗しました: $error')),
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('動画を選択できませんでした。写真へのアクセス権限を確認して、もう一度お試しください。'),
          ),
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

class _RecordList extends StatelessWidget {
  const _RecordList({required this.items});

  final List<SurgeryRecord> items;

  @override
  Widget build(BuildContext context) {
    final groups = groupRecordsByMonth(items);
    final scaledHeaderHeight = MediaQuery.textScalerOf(context).scale(16) + 24;
    final headerHeight = scaledHeaderHeight.clamp(48.0, 80.0);

    return CustomScrollView(
      key: const Key('record-list-scroll'),
      slivers: [
        SliverToBoxAdapter(child: _TotalRecordCount(count: items.length)),
        if (groups.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('症例がありません')),
          )
        else
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
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          key: Key('record-list-item-${record.id}'),
                          title: Text(_recordTitle(record)),
                          subtitle: Text(record.reviewStatus.label),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    RecordDetailScreen(recordId: record.id),
                              ),
                            );
                          },
                        ),
                        if (index < group.records.length - 1)
                          const Divider(height: 1),
                      ],
                    );
                  }, childCount: group.records.length),
                ),
              ],
            ),
      ],
    );
  }

  String _recordTitle(SurgeryRecord record) {
    final date = record.surgeryDate.toLocal();
    return '${date.month}月${date.day}日 ${record.eyeSide.label}';
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
