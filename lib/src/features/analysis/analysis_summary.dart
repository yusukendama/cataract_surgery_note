import 'package:flutter/material.dart';

import '../../domain/duration_formatters.dart';
import '../../domain/surgery_trend.dart';

class AnalysisSummarySection extends StatelessWidget {
  const AnalysisSummarySection({required this.summary, super.key});

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
