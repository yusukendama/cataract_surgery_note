import 'package:flutter/material.dart';

import '../domain/duration_formatters.dart';
import '../domain/procedure_arrival_time.dart';

final class ProcedureArrivalTimePresentation {
  const ProcedureArrivalTimePresentation({
    required this.valueText,
    required this.semanticsLabel,
    required this.detailSemanticsClause,
    this.supportingText,
  });

  factory ProcedureArrivalTimePresentation.fromResult(
    ProcedureArrivalTimeResult result,
  ) {
    return switch (result.status) {
      ProcedureArrivalTimeStatus.available => () {
        final formatted = formatProcedureArrivalDuration(result.duration!);
        return ProcedureArrivalTimePresentation(
          valueText: formatted,
          semanticsLabel: '手術開始から$formattedで開始',
          detailSemanticsClause: '手術開始から$formattedで開始。',
        );
      }(),
      ProcedureArrivalTimeStatus.notApplicable => throw ArgumentError.value(
        result,
        'result',
        '対象外工程には表示を作成できません。',
      ),
      ProcedureArrivalTimeStatus.skipped =>
        const ProcedureArrivalTimePresentation(
          valueText: '時間記録なし',
          semanticsLabel: '工程到達時間。時間記録なし。',
          detailSemanticsClause: '今回は時間を記録しません。',
        ),
      ProcedureArrivalTimeStatus.stepStartMissing =>
        const ProcedureArrivalTimePresentation(
          valueText: '未登録',
          semanticsLabel: '工程到達時間。工程開始位置は未登録です。',
          detailSemanticsClause: '工程開始位置は未登録です。',
        ),
      ProcedureArrivalTimeStatus.totalSurgeryStartMissing =>
        const ProcedureArrivalTimePresentation(
          valueText: '—',
          supportingText: '「総手術時間」の開始位置を登録すると「開始まで」が表示されます。',
          semanticsLabel: '工程到達時間。総手術時間の開始位置が未登録のため表示できません。',
          detailSemanticsClause: '総手術時間の開始位置が未登録のため、開始までの時間を表示できません。',
        ),
      ProcedureArrivalTimeStatus.stepPositionInvalid ||
      ProcedureArrivalTimeStatus.beforeTotalSurgeryStart ||
      ProcedureArrivalTimeStatus.afterTotalSurgeryEnd =>
        const ProcedureArrivalTimePresentation(
          valueText: '要確認',
          supportingText: '工程開始位置を確認してください',
          semanticsLabel: '工程到達時間。工程開始位置を確認してください。',
          detailSemanticsClause: '工程開始位置を確認してください。',
        ),
      ProcedureArrivalTimeStatus.totalSurgeryRangeInvalid =>
        const ProcedureArrivalTimePresentation(
          valueText: '要確認',
          supportingText: '総手術時間の開始・終了位置を確認してください',
          semanticsLabel: '工程到達時間。総手術時間の開始・終了位置を確認してください。',
          detailSemanticsClause: '総手術時間の開始・終了位置を確認してください。',
        ),
      ProcedureArrivalTimeStatus.timelinePositionInvalid ||
      ProcedureArrivalTimeStatus.durationOutOfRange =>
        const ProcedureArrivalTimePresentation(
          valueText: '要確認',
          supportingText: '記録位置を確認してください',
          semanticsLabel: '工程到達時間。記録位置を確認してください。',
          detailSemanticsClause: '記録位置を確認してください。',
        ),
    };
  }

  final String valueText;
  final String? supportingText;
  final String semanticsLabel;
  final String detailSemanticsClause;
}

class ProcedureArrivalTimeView extends StatelessWidget {
  const ProcedureArrivalTimeView({
    required this.result,
    this.showSupportingText = true,
    super.key,
  });

  final ProcedureArrivalTimeResult result;
  final bool showSupportingText;

  @override
  Widget build(BuildContext context) {
    if (!result.isApplicable) {
      return const SizedBox.shrink();
    }
    final presentation = ProcedureArrivalTimePresentation.fromResult(result);
    final supportingText = showSupportingText
        ? presentation.supportingText
        : null;
    return Semantics(
      container: true,
      label: presentation.semanticsLabel,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('開始まで：${presentation.valueText}'),
          if (supportingText != null) ...[
            const SizedBox(height: 4),
            Text(supportingText, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
