import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/video_import_models.dart';
import 'video_import_dialogs.dart';
import 'video_import_loading_dialog.dart';
import 'video_import_ui_flow.dart';
import 'video_registration_guidance_screen.dart';

/// Runs picker and source preflight until the user either obtains a verified
/// candidate or explicitly leaves the flow.
Future<VerifiedVideoCandidate?> selectVerifiedVideoForScreen({
  required BuildContext context,
  required VideoImportUiFlow flow,
  required VideoImportEntryPoint entryPoint,
  required VideoImportDataInvariantSuffix dataInvariantSuffix,
  ValueChanged<VideoImportException>? onPersistentFailure,
}) async {
  while (true) {
    if (!context.mounted) {
      return null;
    }
    final result = await runWithVideoImportLoading<VideoImportUiFlowResult>(
      context: context,
      onCancel: flow.cancelActive,
      operation: (onProgress) => flow.selectAndInspect(onProgress: onProgress),
    );
    if (!context.mounted) {
      return null;
    }

    switch (result) {
      case VideoImportUiReady(:final candidate):
        return candidate;
      case VideoImportUiCancelled() || VideoImportUiBusy():
        return null;
      case VideoImportUiNonCandidate():
        final error = VideoImportException(
          code: VideoImportErrorCode.nonCandidateExtension,
          entryPoint: entryPoint,
          phase: VideoImportPhase.selectionPolicy,
          internalReason: VideoImportInternalReasonV1.guidanceOnlyExtension,
          primaryRecoveryAction: VideoImportRecoveryAction.reselect,
          secondaryRecoveryActions: const <VideoImportRecoveryAction>{
            VideoImportRecoveryAction.openReferenceHelp,
          },
          dataInvariantSuffix: dataInvariantSuffix,
        );
        final shouldReselect = await _presentNonCandidate(
          context: context,
          error: error,
          dataInvariantSuffix: dataInvariantSuffix,
          onPersistentFailure: onPersistentFailure,
        );
        if (!shouldReselect) {
          return null;
        }
        continue;
      case VideoImportUiFailure(:final error):
        final contextualError = error.withContext(
          entryPoint: entryPoint,
          dataInvariantSuffix: dataInvariantSuffix,
        );
        final action = await _presentVideoImportDialogForScreen(
          context: context,
          error: contextualError,
          onPersistentFailure: onPersistentFailure,
          present: () => showVideoImportExceptionDialog(
            context: context,
            error: contextualError,
            dataInvariantSuffix: dataInvariantSuffix,
          ),
        );
        if (!_restartsSelection(action)) {
          return null;
        }
    }
  }
}

Future<bool> _presentNonCandidate({
  required BuildContext context,
  required VideoImportException error,
  required VideoImportDataInvariantSuffix dataInvariantSuffix,
  ValueChanged<VideoImportException>? onPersistentFailure,
}) async {
  while (true) {
    if (!context.mounted) {
      return false;
    }
    final action = await _presentVideoImportDialogForScreen(
      context: context,
      error: error,
      present: () => showNonCandidateVideoDialog(
        context: context,
        dataInvariantSuffix: dataInvariantSuffix,
      ),
    );
    if (!context.mounted) {
      return false;
    }
    if (action != VideoImportRecoveryAction.openReferenceHelp) {
      // Help returns to this same modal loop. Publish only when the modal flow
      // actually ends so a durable notice never sits behind the reopened
      // dialog with a duplicate title/announcement.
      onPersistentFailure?.call(error);
    }
    switch (action) {
      case VideoImportRecoveryAction.reselect:
        return true;
      case VideoImportRecoveryAction.openReferenceHelp:
        await openVideoRegistrationGuidance(context);
        continue;
      case VideoImportRecoveryAction.dismiss ||
          VideoImportRecoveryAction.checkSourceAndReselect ||
          VideoImportRecoveryAction.retry ||
          VideoImportRecoveryAction.unlockAndRetry ||
          VideoImportRecoveryAction.freeStorageAndRetry ||
          VideoImportRecoveryAction.reloadRecord ||
          VideoImportRecoveryAction.resetTimingsAndAttach ||
          VideoImportRecoveryAction.resetTimingsAndReplace ||
          VideoImportRecoveryAction.contactSupport:
        return false;
    }
  }
}

Future<VideoImportRecoveryAction> _presentVideoImportDialogForScreen({
  required BuildContext context,
  required VideoImportException error,
  required Future<VideoImportRecoveryAction> Function() present,
  ValueChanged<VideoImportException>? onPersistentFailure,
}) async {
  final originFocus = FocusManager.instance.primaryFocus;
  final originRoute = ModalRoute.of(context);
  final action = await present();
  if (!context.mounted) {
    return action;
  }

  // The durable notice belongs to the state after the modal interaction. Do
  // not place it behind the dialog while the title owns accessibility focus.
  onPersistentFailure?.call(error);
  _scheduleVideoImportFocusRestoration(
    context: context,
    originFocus: originFocus,
    originRoute: originRoute,
  );
  return action;
}

void _scheduleVideoImportFocusRestoration({
  required BuildContext context,
  required FocusNode? originFocus,
  required ModalRoute<Object?>? originRoute,
  int remainingAttempts = 20,
}) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted || (originRoute != null && !originRoute.isCurrent)) {
      return;
    }

    final currentFocus = FocusManager.instance.primaryFocus;
    final currentContext = currentFocus?.context;
    if (currentContext != null) {
      final currentRoute = ModalRoute.of(currentContext);
      if (currentRoute != null && !identical(currentRoute, originRoute)) {
        if (!currentRoute.isCurrent && remainingAttempts > 0) {
          // The dismissed dialog can retain primary focus for its reverse
          // transition. Wait for detachment before selecting the fallback.
          _scheduleVideoImportFocusRestoration(
            context: context,
            originFocus: originFocus,
            originRoute: originRoute,
            remainingAttempts: remainingAttempts - 1,
          );
        }
        // A newer current dialog or route already owns focus; do not steal it.
        return;
      }
    }
    if (identical(currentFocus, originFocus) &&
        currentFocus?.hasFocus == true) {
      return;
    }
    if (_requestFocusIfAvailable(originFocus)) {
      return;
    }

    final focusScope = FocusScope.of(context);
    for (final node
        in focusScope.descendants.whereType<_VideoImportReselectFocusNode>()) {
      if (_requestFocusIfAvailable(node)) {
        return;
      }
    }

    // Callers commonly re-enable the origin or persistent action in their
    // async finally block. Allow those state changes to settle without leaving
    // an unbounded focus task behind.
    if (remainingAttempts > 0) {
      _scheduleVideoImportFocusRestoration(
        context: context,
        originFocus: originFocus,
        originRoute: originRoute,
        remainingAttempts: remainingAttempts - 1,
      );
    }
  });
}

bool _requestFocusIfAvailable(FocusNode? node) {
  // FocusNode keeps its last BuildContext after its Focus widget detaches.
  // A non-null parent is therefore the reliable public signal that the node
  // still belongs to the active focus tree.
  if (node == null ||
      node.context == null ||
      node.parent == null ||
      !node.canRequestFocus) {
    return false;
  }
  node.requestFocus();
  return true;
}

bool videoImportRecoveryRequestsReselection(VideoImportRecoveryAction action) {
  return switch (action) {
    VideoImportRecoveryAction.reselect ||
    VideoImportRecoveryAction.checkSourceAndReselect => true,
    VideoImportRecoveryAction.dismiss ||
    VideoImportRecoveryAction.retry ||
    VideoImportRecoveryAction.unlockAndRetry ||
    VideoImportRecoveryAction.freeStorageAndRetry ||
    VideoImportRecoveryAction.reloadRecord ||
    VideoImportRecoveryAction.resetTimingsAndAttach ||
    VideoImportRecoveryAction.resetTimingsAndReplace ||
    VideoImportRecoveryAction.contactSupport ||
    VideoImportRecoveryAction.openReferenceHelp => false,
  };
}

bool videoImportRecoveryRequestsRetry(VideoImportRecoveryAction action) {
  return switch (action) {
    VideoImportRecoveryAction.retry ||
    VideoImportRecoveryAction.unlockAndRetry ||
    VideoImportRecoveryAction.freeStorageAndRetry => true,
    VideoImportRecoveryAction.dismiss ||
    VideoImportRecoveryAction.reselect ||
    VideoImportRecoveryAction.checkSourceAndReselect ||
    VideoImportRecoveryAction.reloadRecord ||
    VideoImportRecoveryAction.resetTimingsAndAttach ||
    VideoImportRecoveryAction.resetTimingsAndReplace ||
    VideoImportRecoveryAction.contactSupport ||
    VideoImportRecoveryAction.openReferenceHelp => false,
  };
}

bool _restartsSelection(VideoImportRecoveryAction action) =>
    videoImportRecoveryRequestsReselection(action) ||
    videoImportRecoveryRequestsRetry(action);

typedef VideoImportScreenOperation<T> =
    Future<T> Function(
      VideoImportCancellationToken cancellationToken,
      VideoImportProgressCallback onProgress,
    );

/// Owns an admission/import cancellation token for the lifetime of a screen.
/// Disposing the screen invalidates any in-flight copy before it can reach a
/// cancellable database boundary.
class VideoImportOperationController {
  VideoImportCancellationToken? _activeToken;
  bool _disposed = false;

  VideoImportCancellationToken begin() {
    final token = VideoImportCancellationToken();
    if (_disposed) {
      token.cancel();
      return token;
    }
    _activeToken?.cancel();
    _activeToken = token;
    return token;
  }

  void end(VideoImportCancellationToken token) {
    if (identical(_activeToken, token)) {
      _activeToken = null;
    }
  }

  void cancelActive() => _activeToken?.cancel();

  void dispose() {
    _disposed = true;
    cancelActive();
    _activeToken = null;
  }
}

sealed class VideoImportScreenOperationResult<T> {
  const VideoImportScreenOperationResult();
}

class VideoImportScreenOperationSuccess<T>
    extends VideoImportScreenOperationResult<T> {
  const VideoImportScreenOperationSuccess(this.value);

  final T value;
}

class VideoImportScreenOperationCancelled<T>
    extends VideoImportScreenOperationResult<T> {
  const VideoImportScreenOperationCancelled();
}

class VideoImportScreenOperationFailure<T>
    extends VideoImportScreenOperationResult<T> {
  const VideoImportScreenOperationFailure({
    required this.error,
    required this.recoveryAction,
    this.maintenanceOutcome = VideoMaintenanceOutcome.complete,
  });

  final VideoImportException error;
  final VideoImportRecoveryAction recoveryAction;
  final VideoMaintenanceOutcome maintenanceOutcome;
}

/// Runs an admission/copy operation with cancelable loading and presents any
/// domain failure after dismissing the loading overlay.
Future<VideoImportScreenOperationResult<T>>
runVideoImportOperationForScreen<T>({
  required BuildContext context,
  required VideoImportScreenOperation<T> operation,
  required VideoImportDataInvariantSuffix dataInvariantSuffix,
  required VideoImportEntryPoint entryPoint,
  VideoImportOperationController? operationController,
  ValueChanged<VideoImportException>? onPersistentFailure,
}) async {
  final cancellationToken =
      operationController?.begin() ?? VideoImportCancellationToken();
  var lastPhase = VideoImportPhase.sourceAccess;
  final loading = VideoImportLoadingPresenter(
    context: context,
    onCancel: cancellationToken.cancel,
  );

  try {
    final value = await operation(cancellationToken, (progress) {
      lastPhase = progress.phase;
      loading.updateProgress(progress);
    });
    return VideoImportScreenOperationSuccess<T>(value);
  } on VideoImportFailure catch (failure) {
    loading.finish();
    if (!context.mounted) {
      return VideoImportScreenOperationCancelled<T>();
    }
    final contextualError = failure.error.withContext(
      entryPoint: entryPoint,
      dataInvariantSuffix: dataInvariantSuffix,
    );
    final action = await _presentVideoImportDialogForScreen(
      context: context,
      error: contextualError,
      onPersistentFailure: onPersistentFailure,
      present: () => showVideoImportExceptionDialog(
        context: context,
        error: contextualError,
        dataInvariantSuffix: dataInvariantSuffix,
      ),
    );
    return VideoImportScreenOperationFailure<T>(
      error: contextualError,
      recoveryAction: action,
      maintenanceOutcome: failure.maintenanceOutcome,
    );
  } on VideoImportException catch (error) {
    loading.finish();
    if (error.code == VideoImportErrorCode.userCanceled || !context.mounted) {
      return VideoImportScreenOperationCancelled<T>();
    }
    final contextualError = error.withContext(
      entryPoint: entryPoint,
      dataInvariantSuffix: dataInvariantSuffix,
    );
    final action = await _presentVideoImportDialogForScreen(
      context: context,
      error: contextualError,
      onPersistentFailure: onPersistentFailure,
      present: () => showVideoImportExceptionDialog(
        context: context,
        error: contextualError,
        dataInvariantSuffix: dataInvariantSuffix,
      ),
    );
    return VideoImportScreenOperationFailure<T>(
      error: contextualError,
      recoveryAction: action,
    );
  } on Object {
    loading.finish();
    if (!context.mounted) {
      return VideoImportScreenOperationCancelled<T>();
    }
    final error = VideoImportException(
      code: VideoImportErrorCode.unknown,
      entryPoint: entryPoint,
      phase: lastPhase,
      internalReason: VideoImportInternalReasonV1.unexpected,
      primaryRecoveryAction: VideoImportRecoveryAction.retry,
      dataInvariantSuffix: dataInvariantSuffix,
    );
    final action = await _presentVideoImportDialogForScreen(
      context: context,
      error: error,
      onPersistentFailure: onPersistentFailure,
      present: () =>
          showVideoImportExceptionDialog(context: context, error: error),
    );
    return VideoImportScreenOperationFailure<T>(
      error: error,
      recoveryAction: action,
    );
  } finally {
    loading.finish();
    operationController?.end(cancellationToken);
  }
}

/// Compact, durable recovery state shown after the blocking dialog closes.
/// Detailed copy remains in the scrollable dialog; this card only restores
/// the two continuing entry points required by the import flow.
class VideoImportPersistentErrorNotice extends StatefulWidget {
  const VideoImportPersistentErrorNotice({
    required this.error,
    required this.onReselect,
    super.key,
  });

  final VideoImportException error;
  final VoidCallback? onReselect;

  @override
  State<VideoImportPersistentErrorNotice> createState() =>
      _VideoImportPersistentErrorNoticeState();
}

final class _VideoImportReselectFocusNode extends FocusNode {
  _VideoImportReselectFocusNode()
    : super(debugLabel: 'video-import-persistent-reselect');
}

class _VideoImportPersistentErrorNoticeState
    extends State<VideoImportPersistentErrorNotice> {
  late final _VideoImportReselectFocusNode _reselectFocusNode;

  @override
  void initState() {
    super.initState();
    _reselectFocusNode = _VideoImportReselectFocusNode();
  }

  @override
  void dispose() {
    _reselectFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = videoImportDialogContentFor(widget.error).title;
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.error_outline),
                const SizedBox(width: 8),
                Expanded(child: Text(title)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  focusNode: _reselectFocusNode,
                  onPressed: widget.onReselect,
                  icon: const Icon(Icons.video_file_outlined),
                  label: const Text('別の動画を選ぶ'),
                ),
                TextButton.icon(
                  onPressed: () => openVideoRegistrationGuidance(context),
                  icon: const Icon(Icons.help_outline),
                  label: const Text('再登録できる動画の目安'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class VideoRegistrationHelpButton extends StatelessWidget {
  const VideoRegistrationHelpButton({this.enabled = true, super.key});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '再登録できる動画の目安',
      onPressed: enabled
          ? () {
              unawaited(openVideoRegistrationGuidance(context));
            }
          : null,
      icon: const Icon(Icons.help_outline),
    );
  }
}
