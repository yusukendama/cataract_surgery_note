import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

enum VideoTimelineIdentityDecision { sameUnchanged, changedOrUnknown }

Future<VideoTimelineIdentityDecision?> showVideoTimelineIdentityDialog({
  required BuildContext context,
}) {
  return showDialog<VideoTimelineIdentityDecision>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const VideoTimelineIdentityDialog(),
  );
}

class VideoTimelineIdentityDialog extends StatefulWidget {
  const VideoTimelineIdentityDialog({super.key});

  @override
  State<VideoTimelineIdentityDialog> createState() =>
      _VideoTimelineIdentityDialogState();
}

class _VideoTimelineIdentityDialogState
    extends State<VideoTimelineIdentityDialog> {
  VideoTimelineIdentityDecision? _decision;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      semanticLabel: '選択した動画について確認してください',
      scrollable: true,
      title: Focus(
        autofocus: true,
        child: Semantics(
          headingLevel: 1,
          child: const Text('選択した動画について確認してください'),
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('この症例には工程位置が記録されています。選択した動画が以前使用した動画と同じか確認してください。'),
          const SizedBox(height: AppSpacing.small),
          Text(
            '判断できない場合は、工程位置を消去する選択肢を選んでください。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.medium),
          RadioGroup<VideoTimelineIdentityDecision>(
            groupValue: _decision,
            onChanged: (value) {
              setState(() => _decision = value);
            },
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<VideoTimelineIdentityDecision>(
                  key: Key('timeline-identity-same-unchanged'),
                  value: VideoTimelineIdentityDecision.sameUnchanged,
                  title: Text('以前この症例で使用したファイルと同じで、その後変換・編集していない'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                RadioListTile<VideoTimelineIdentityDecision>(
                  key: Key('timeline-identity-changed-or-unknown'),
                  value: VideoTimelineIdentityDecision.changedOrUnknown,
                  title: Text('以前の登録後に変換・編集・再書き出しした、または同じか判断できない'),
                  subtitle: Text('この場合、記録済みの工程位置は消去されます。'),
                  isThreeLine: true,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
          ),
        ],
      ),
      actionsOverflowDirection: VerticalDirection.down,
      actionsOverflowButtonSpacing: AppSpacing.xSmall,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          key: const Key('continue-with-timeline-identity'),
          onPressed: _decision == null
              ? null
              : () => Navigator.of(context).pop(_decision),
          child: const Text('続ける'),
        ),
      ],
    );
  }
}
