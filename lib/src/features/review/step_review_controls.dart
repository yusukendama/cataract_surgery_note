import 'package:flutter/material.dart';

import '../../domain/duration_formatters.dart';
import '../../domain/procedure_arrival_time.dart';
import '../../domain/surgery_models.dart';
import '../../widgets/procedure_arrival_time_view.dart';

class VideoTransportControls extends StatelessWidget {
  const VideoTransportControls({
    required this.isPlaying,
    required this.onSeekBackward5,
    required this.onSeekForward5,
    required this.onSeekBackward15,
    required this.onSeekForward15,
    required this.onTogglePlayback,
    super.key,
  });

  final bool isPlaying;
  final VoidCallback? onSeekBackward5;
  final VoidCallback? onSeekForward5;
  final VoidCallback? onSeekBackward15;
  final VoidCallback? onSeekForward15;
  final VoidCallback? onTogglePlayback;

  @override
  Widget build(BuildContext context) {
    final playbackLabel = isPlaying ? '一時停止' : '再生';
    return Row(
      children: [
        Expanded(
          child: _VideoSeekButton(
            controlKey: const Key('seek-backward-15-seconds'),
            semanticsLabel: '15秒戻る',
            secondsLabel: '15秒',
            icon: Icons.fast_rewind,
            onPressed: onSeekBackward15,
            emphasized: false,
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: _VideoSeekButton(
            controlKey: const Key('seek-backward-5-seconds'),
            semanticsLabel: '5秒戻る',
            secondsLabel: '5秒',
            icon: Icons.fast_rewind,
            onPressed: onSeekBackward5,
            emphasized: true,
          ),
        ),
        const SizedBox(width: 4),
        Semantics(
          key: const Key('toggle-video-playback'),
          label: playbackLabel,
          button: true,
          enabled: onTogglePlayback != null,
          onTap: onTogglePlayback,
          excludeSemantics: true,
          child: Tooltip(
            message: playbackLabel,
            excludeFromSemantics: true,
            child: IconButton.filled(
              style: IconButton.styleFrom(minimumSize: const Size.square(56)),
              onPressed: onTogglePlayback,
              icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: _VideoSeekButton(
            controlKey: const Key('seek-forward-5-seconds'),
            semanticsLabel: '5秒進む',
            secondsLabel: '5秒',
            icon: Icons.fast_forward,
            onPressed: onSeekForward5,
            emphasized: true,
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: _VideoSeekButton(
            controlKey: const Key('seek-forward-15-seconds'),
            semanticsLabel: '15秒進む',
            secondsLabel: '15秒',
            icon: Icons.fast_forward,
            onPressed: onSeekForward15,
            emphasized: false,
          ),
        ),
      ],
    );
  }
}

class _VideoSeekButton extends StatelessWidget {
  const _VideoSeekButton({
    required this.controlKey,
    required this.semanticsLabel,
    required this.secondsLabel,
    required this.icon,
    required this.onPressed,
    required this.emphasized,
  });

  final Key controlKey;
  final String semanticsLabel;
  final String secondsLabel;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final style = emphasized
        ? FilledButton.styleFrom(
            minimumSize: const Size(48, 64),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          )
        : OutlinedButton.styleFrom(
            minimumSize: const Size(48, 64),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          );
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20),
        const SizedBox(height: 2),
        Text(secondsLabel, maxLines: 1),
      ],
    );
    final button = emphasized
        ? FilledButton.tonal(style: style, onPressed: onPressed, child: content)
        : OutlinedButton(style: style, onPressed: onPressed, child: content);
    return Semantics(
      key: controlKey,
      label: semanticsLabel,
      button: true,
      enabled: onPressed != null,
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: onPressed == null
            ? '$semanticsLabel（動画を確認できないため利用できません）'
            : semanticsLabel,
        excludeFromSemantics: true,
        child: button,
      ),
    );
  }
}

class ProcedureTimingCard extends StatelessWidget {
  const ProcedureTimingCard({
    required this.step,
    required this.timing,
    required this.arrivalTime,
    required this.isSaving,
    required this.onStart,
    required this.onEnd,
    required this.onReset,
    this.onSkip,
    this.videoUnavailableReason = '動画を確認できないため利用できません',
    this.onTapStart,
    this.onTapEnd,
    super.key,
  });

  final SurgicalStep step;
  final SurgicalStepReview timing;
  final ProcedureArrivalTimeResult arrivalTime;
  final bool isSaving;
  final VoidCallback? onStart;
  final VoidCallback? onEnd;
  final VoidCallback? onReset;
  final VoidCallback? onSkip;
  final String videoUnavailableReason;
  final VoidCallback? onTapStart;
  final VoidCallback? onTapEnd;

  @override
  Widget build(BuildContext context) {
    final hasTimingInput =
        timing.startMilliseconds != null || timing.endMilliseconds != null;
    final status = switch (timing.recordingStatus) {
      StepRecordingStatus.skipped => const (
        label: '時間記録なし',
        icon: Icons.do_not_disturb_alt_outlined,
      ),
      StepRecordingStatus.recorded => const (
        label: '完了',
        icon: Icons.check_circle_outline,
      ),
      StepRecordingStatus.unprocessed when timing.isRunning => const (
        label: '計測中',
        icon: Icons.timer_outlined,
      ),
      StepRecordingStatus.unprocessed when hasTimingInput => const (
        label: '要再設定',
        icon: Icons.warning_amber_outlined,
      ),
      StepRecordingStatus.unprocessed => const (
        label: '未着手',
        icon: Icons.radio_button_unchecked,
      ),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    step.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Semantics(
                  label: '工程状態、${status.label}',
                  excludeSemantics: true,
                  child: Chip(
                    avatar: Icon(status.icon, size: 18),
                    label: Text(status.label),
                  ),
                ),
              ],
            ),
            if (timing.recordingStatus == StepRecordingStatus.skipped) ...[
              const SizedBox(height: 12),
            ] else if (timing.isRunning) ...[
              _TimingSeekButton(
                label:
                    '開始時刻：'
                    '${formatTimelineMilliseconds(timing.startMilliseconds)}',
                tooltip: onTapStart == null
                    ? videoUnavailableReason
                    : '動画を開始時刻へ移動',
                onPressed: onTapStart,
              ),
              const SizedBox(height: 16),
            ] else if (timing.isCompleted) ...[
              _TimingSeekButton(
                label:
                    '開始時刻：'
                    '${formatTimelineMilliseconds(timing.startMilliseconds)}',
                tooltip: onTapStart == null
                    ? videoUnavailableReason
                    : '動画を開始時刻へ移動',
                onPressed: onTapStart,
              ),
              _TimingSeekButton(
                label:
                    '終了時刻：'
                    '${formatTimelineMilliseconds(timing.endMilliseconds)}',
                tooltip: onTapEnd == null
                    ? videoUnavailableReason
                    : '動画を終了時刻へ移動',
                onPressed: onTapEnd,
              ),
              Text('所要時間：${formatProcedureDuration(timing.duration)}'),
              const SizedBox(height: 16),
            ] else
              const SizedBox(height: 12),
            if (!step.isTotalSurgeryTime) ...[
              ProcedureArrivalTimeView(result: arrivalTime),
              const SizedBox(height: 16),
            ],
            if (isSaving)
              const SizedBox(
                height: 56,
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              _buildPrimaryAction(context),
              if (timing.recordingStatus == StepRecordingStatus.unprocessed &&
                  !step.isTotalSurgeryTime) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.center,
                  child: TextButton(
                    key: const Key('procedure-skip-button'),
                    onPressed: onSkip,
                    child: const Text('今回は時間を記録しない'),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPrimaryAction(BuildContext context) {
    if (timing.isNotStarted) {
      return Tooltip(
        message: onStart == null ? videoUnavailableReason : '現在の動画位置で工程を開始',
        child: SizedBox(
          width: double.infinity,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: FilledButton.icon(
              key: const Key('procedure-start-button'),
              onPressed: onStart,
              icon: const Icon(Icons.play_arrow),
              label: const Text('この工程を開始'),
            ),
          ),
        ),
      );
    }
    if (timing.isRunning) {
      return Tooltip(
        message: onEnd == null ? videoUnavailableReason : '現在の動画位置で工程を終了',
        child: SizedBox(
          width: double.infinity,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: FilledButton.icon(
              key: const Key('procedure-end-button'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: onEnd,
              icon: const Icon(Icons.stop),
              label: const Text('この工程を終了'),
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerRight,
      child: OutlinedButton.icon(
        key: const Key('procedure-reset-button'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: onReset,
        icon: const Icon(Icons.refresh),
        label: const Text('再設定'),
      ),
    );
  }
}

class _TimingSeekButton extends StatelessWidget {
  const _TimingSeekButton({
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final String label;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: onPressed == null ? '$label、$tooltip' : label,
        button: true,
        enabled: onPressed != null,
        excludeSemantics: true,
        child: SizedBox(
          width: double.infinity,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: TextButton.icon(
              onPressed: onPressed,
              icon: const Icon(Icons.movie_filter_outlined, size: 18),
              label: Align(alignment: Alignment.centerLeft, child: Text(label)),
            ),
          ),
        ),
      ),
    );
  }
}
