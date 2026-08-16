import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/video_import_models.dart';
import '../../theme/app_tokens.dart';

const Duration videoImportLoadingDelay = Duration(milliseconds: 500);

/// Tracks an operation and owns its delayed modal loading overlay.
///
/// Call [updateProgress] from the app-managed operation's progress callback and
/// [finish] in a `finally` block. The delay starts with the first progress
/// event, so time spent inside the OS picker is not described as app-managed
/// loading.
class VideoImportLoadingPresenter {
  VideoImportLoadingPresenter({
    required BuildContext context,
    required VoidCallback onCancel,
    this.delay = videoImportLoadingDelay,
  }) : assert(!delay.isNegative),
       _context = context,
       _onCancel = onCancel;

  final BuildContext _context;
  final VoidCallback _onCancel;
  final Duration delay;

  Timer? _delayTimer;
  OverlayEntry? _overlayEntry;
  VideoImportProgress? _progress;
  bool _finished = false;
  bool _cancelRequested = false;
  bool _cancellationEnabled = true;

  VideoImportProgress? get progress => _progress;
  bool get isVisible => _overlayEntry?.mounted ?? false;
  bool get isFinished => _finished;
  bool get cancelRequested => _cancelRequested;

  void updateProgress(VideoImportProgress progress) {
    if (_finished || _cancelRequested) {
      return;
    }
    _progress = progress;
    final entry = _overlayEntry;
    if (entry != null) {
      entry.markNeedsBuild();
      return;
    }
    if (delay == Duration.zero) {
      _showOverlay();
      return;
    }
    _delayTimer ??= Timer(delay, _showOverlay);
  }

  /// Allows a caller to make an atomic commit phase non-cancelable.
  void setCancellationEnabled(bool enabled) {
    if (_finished || _cancellationEnabled == enabled) {
      return;
    }
    _cancellationEnabled = enabled;
    _overlayEntry?.markNeedsBuild();
  }

  void finish() {
    if (_finished) {
      return;
    }
    _finished = true;
    _delayTimer?.cancel();
    _delayTimer = null;
    final entry = _overlayEntry;
    _overlayEntry = null;
    if (entry?.mounted ?? false) {
      entry!.remove();
    }
    entry?.dispose();
  }

  void dispose() {
    finish();
  }

  void _showOverlay() {
    _delayTimer = null;
    if (_finished || _progress == null || !_context.mounted) {
      return;
    }
    final overlay = Overlay.maybeOf(_context, rootOverlay: true);
    if (overlay == null) {
      return;
    }
    final entry = OverlayEntry(
      builder: (_) => VideoImportLoadingOverlay(
        progress: _progress!,
        cancelRequested: _cancelRequested,
        onCancel: _cancellationEnabled && !_cancelRequested
            ? _requestCancel
            : null,
      ),
    );
    _overlayEntry = entry;
    overlay.insert(entry);
  }

  void _requestCancel() {
    if (_finished || _cancelRequested || !_cancellationEnabled) {
      return;
    }
    _cancelRequested = true;
    _overlayEntry?.markNeedsBuild();
    _onCancel();
  }
}

/// Convenience wrapper that guarantees removal of the delayed loading UI.
Future<T> runWithVideoImportLoading<T>({
  required BuildContext context,
  required Future<T> Function(VideoImportProgressCallback onProgress) operation,
  required VoidCallback onCancel,
  Duration delay = videoImportLoadingDelay,
}) async {
  final presenter = VideoImportLoadingPresenter(
    context: context,
    onCancel: onCancel,
    delay: delay,
  );
  try {
    return await operation(presenter.updateProgress);
  } finally {
    presenter.finish();
  }
}

class VideoImportLoadingOverlay extends StatelessWidget {
  const VideoImportLoadingOverlay({
    required this.progress,
    required this.onCancel,
    this.cancelRequested = false,
    super.key,
  });

  final VideoImportProgress progress;
  final VoidCallback? onCancel;
  final bool cancelRequested;

  @override
  Widget build(BuildContext context) {
    final cancel = onCancel;
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          cancel?.call();
        }
      },
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            const ModalBarrier(
              dismissible: false,
              color: Colors.black54,
              semanticsLabel: '動画を処理しています',
            ),
            SafeArea(
              child: Center(
                child: CallbackShortcuts(
                  bindings: <ShortcutActivator, VoidCallback>{
                    const SingleActivator(LogicalKeyboardKey.escape): () {
                      cancel?.call();
                    },
                  },
                  child: Focus(
                    autofocus: true,
                    child: VideoImportLoadingDialog(
                      progress: progress,
                      onCancel: cancel,
                      cancelRequested: cancelRequested,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class VideoImportLoadingDialog extends StatelessWidget {
  const VideoImportLoadingDialog({
    required this.progress,
    required this.onCancel,
    this.cancelRequested = false,
    super.key,
  });

  final VideoImportProgress progress;
  final VoidCallback? onCancel;
  final bool cancelRequested;

  @override
  Widget build(BuildContext context) {
    final phaseLabel = cancelRequested
        ? 'キャンセルしています…'
        : videoImportPhaseLabel(progress.phase);
    final fraction = _normalizedFraction(progress.fraction);
    final percentage = fraction == null ? null : (fraction * 100).round();

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
          padding: AppSpacing.card,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                key: ValueKey<String>(phaseLabel),
                liveRegion: true,
                label: phaseLabel,
                child: ExcludeSemantics(
                  child: Text(
                    phaseLabel,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.medium),
              Semantics(
                label: '動画処理の進捗',
                value: percentage == null ? null : '$percentage%',
                child: LinearProgressIndicator(value: fraction),
              ),
              if (percentage != null) ...[
                const SizedBox(height: AppSpacing.small),
                ExcludeSemantics(
                  child: Text(
                    '$percentage%',
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.large),
              if (onCancel case final cancel?)
                OutlinedButton(onPressed: cancel, child: const Text('キャンセル'))
              else if (cancelRequested)
                const Center(child: CircularProgressIndicator()),
            ],
          ),
        ),
      ),
    );
  }
}

String videoImportPhaseLabel(VideoImportPhase phase) {
  return switch (phase) {
    VideoImportPhase.selectionPolicy ||
    VideoImportPhase.sourceAccess => '動画を取得しています…',
    VideoImportPhase.sourceHash ||
    VideoImportPhase.sourcePlayback => '動画を確認しています…',
    VideoImportPhase.copy => '動画を保存しています…',
    VideoImportPhase.destinationProtection ||
    VideoImportPhase.destinationPlayback => '保存した動画を確認しています…',
    VideoImportPhase.databaseCommit => '症例へ登録しています…',
    VideoImportPhase.cleanup => '後処理をしています…',
  };
}

double? _normalizedFraction(double? value) {
  if (value == null || !value.isFinite) {
    return null;
  }
  return value.clamp(0, 1).toDouble();
}
