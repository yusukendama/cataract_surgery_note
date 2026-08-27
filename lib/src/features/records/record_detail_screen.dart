import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/providers.dart';
import '../../data/record_mutation_coordinator.dart';
import '../../data/record_video_service.dart';
import '../../data/surgery_repository.dart';
import '../../data/video_import_models.dart';
import '../../domain/duration_formatters.dart';
import '../../domain/procedure_arrival_time.dart';
import '../../domain/surgery_models.dart';
import '../../widgets/app_confirm_dialog.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/app_states.dart';
import '../../widgets/procedure_arrival_time_view.dart';
import '../review/step_review_screen.dart';
import '../video_import/video_import_dialogs.dart';
import '../video_import/video_import_screen_flow.dart';
import '../video_import/video_import_ui_flow.dart';
import '../video_import/video_timeline_identity_dialog.dart';

enum _VideoMutation { attach, relink, replace }

class RecordDetailScreen extends ConsumerStatefulWidget {
  const RecordDetailScreen({
    required this.recordId,
    this.initialNotice,
    super.key,
  });

  final String recordId;
  final String? initialNotice;

  @override
  ConsumerState<RecordDetailScreen> createState() => _RecordDetailScreenState();
}

class _RecordDetailScreenState extends ConsumerState<RecordDetailScreen> {
  @override
  void initState() {
    super.initState();
    final notice = widget.initialNotice;
    if (notice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ModalRoute.of(context)?.isCurrent != true) {
          return;
        }
        showAppSnackBar(
          context,
          message: notice,
          tone: AppFeedbackTone.warning,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = ref.watch(surgeryRecordProvider(widget.recordId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('症例詳細'),
        actions: const [VideoRegistrationHelpButton()],
      ),
      body: record.when(
        data: (item) {
          if (item == null) {
            return const AppEmptyState(
              icon: Icons.search_off,
              title: '症例が見つかりません',
              message: '別の画面で削除された可能性があります。',
            );
          }
          return _RecordDetailBody(record: item);
        },
        error: (_, _) => AppErrorState(
          message: '症例詳細を読み込めませんでした。',
          onRetry: () => ref.invalidate(surgeryRecordProvider(widget.recordId)),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _RecordDetailBody extends ConsumerStatefulWidget {
  const _RecordDetailBody({required this.record});

  final SurgeryRecord record;

  @override
  ConsumerState<_RecordDetailBody> createState() => _RecordDetailBodyState();
}

class _RecordDetailBodyState extends ConsumerState<_RecordDetailBody> {
  late final VideoImportUiFlow _videoImportFlow;
  final VideoImportOperationController _videoImportOperationController =
      VideoImportOperationController();

  bool _isDeleting = false;
  bool _isUpdatingVideo = false;
  bool _isUpdatingDetails = false;
  VideoImportException? _lastVideoImportError;
  _VideoMutation? _lastVideoMutation;

  bool get _hasPendingMutation =>
      _isDeleting || _isUpdatingVideo || _isUpdatingDetails;

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
    _videoImportOperationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final videoState = ref.watch(recordVideoStateProvider(record.id));
    final progressSnapshot = ref.watch(surgeryRecordProgressProvider);
    final procedureTimingSnapshot = ref.watch(
      recordProcedureTimingSnapshotProvider(record.id),
    );
    SurgeryRecordProgress? progress;
    for (final item
        in progressSnapshot.asData?.value ?? const <SurgeryRecordProgress>[]) {
      if (item.record.id == record.id) {
        progress = item;
        break;
      }
    }

    return PopScope<void>(
      key: const Key('record-detail-pop-scope'),
      canPop: !_hasPendingMutation,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const _SectionTitle('症例情報'),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${DateFormat('yyyy/MM/dd', 'ja_JP').format(record.surgeryDate)} ${record.eyeSide.label}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '手術日・左右眼を変更',
                    onPressed: _hasPendingMutation ? null : _editRecordDetails,
                    icon: _isUpdatingDetails
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.edit_outlined),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const _SectionTitle('動画'),
          const SizedBox(height: 8),
          if (_lastVideoImportError case final error?) ...[
            VideoImportPersistentErrorNotice(
              error: error,
              onReselect: _hasPendingMutation
                  ? null
                  : () => _pickVideo(
                      _lastVideoMutation ??
                          (record.videoPath == null
                              ? _VideoMutation.attach
                              : _VideoMutation.replace),
                    ),
            ),
            const SizedBox(height: 8),
          ],
          ..._buildVideoSection(record, videoState),
          const SizedBox(height: 24),
          const _SectionTitle('工程記録'),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ProgressSummary(
                    progress: progress,
                    isLoading: progressSnapshot.isLoading,
                    hasError: progressSnapshot.hasError,
                    onRetry: () =>
                        ref.invalidate(surgeryRecordProgressProvider),
                  ),
                  const SizedBox(height: 16),
                  _ProcedureTimesExpansion(
                    snapshot: procedureTimingSnapshot,
                    onRetry: () => ref.invalidate(
                      recordProcedureTimingSnapshotProvider(record.id),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _hasPendingMutation
                        ? null
                        : () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    StepReviewScreen(recordId: record.id),
                              ),
                            );
                          },
                    icon: const Icon(Icons.rate_review_outlined),
                    label: const Text('工程記録を開く'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),
          Align(
            alignment: Alignment.center,
            child: TextButton.icon(
              key: const Key('delete-record-button'),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: _hasPendingMutation ? null : _deleteRecord,
              icon: _isDeleting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_outline),
              label: const Text('症例を削除'),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds every video-reference state without treating an unavailable or
  /// unsafe reference as a usable file (for example after a device restore).
  List<Widget> _buildVideoSection(
    SurgeryRecord record,
    AsyncValue<RecordVideoState> videoState,
  ) {
    return videoState.when(
      data: (state) => switch (state.kind) {
        RecordVideoStateKind.unregistered => [
          _VideoStatusCard(
            icon: Icons.movie_outlined,
            title: '動画未登録',
            message: '動画がなくても工程記録は閲覧・編集できます。',
          ),
          const SizedBox(height: 12),
          _videoActionButton('動画を登録', _VideoMutation.attach),
        ],
        RecordVideoStateKind.availableManaged => [
          _VideoStatusCard(
            icon: Icons.movie_outlined,
            title: record.videoDisplayName ?? '登録済みの動画',
            message: 'アプリ管理動画・利用可能',
          ),
          const _BackupExclusionStatus(),
          const SizedBox(height: 12),
          _videoActionWrap([
            _videoActionButton('別の動画に差し替え', _VideoMutation.replace),
            _deleteVideoButton(),
          ]),
        ],
        RecordVideoStateKind.availableLegacy => [
          _VideoStatusCard(
            icon: Icons.video_library_outlined,
            title: record.videoDisplayName ?? '旧形式の動画',
            message: '旧形式動画・利用可能。外部原本は削除しません。',
          ),
          const SizedBox(height: 12),
          _videoActionWrap([
            FilledButton.icon(
              onPressed: _hasPendingMutation ? null : _migrateLegacyVideo,
              icon: const Icon(Icons.move_to_inbox_outlined),
              label: const Text('アプリ内へ安全に移行'),
            ),
            _videoActionButton('別の動画に差し替え', _VideoMutation.replace),
            _deleteVideoButton(),
          ]),
        ],
        RecordVideoStateKind.missing => _recoveryVideoWidgets(
          record,
          '保存した動画の実体が見つかりません。工程記録は保持されています。',
        ),
        RecordVideoStateKind.invalidReference => _recoveryVideoWidgets(
          record,
          '動画参照が不正なため自動で開きません。工程記録は保持されています。',
        ),
        RecordVideoStateKind.checkFailed => [
          _VideoStatusCard(
            icon: Icons.error_outline,
            title: record.videoDisplayName ?? '動画',
            message: '動画を確認できませんでした。実体なしとは判定していません。',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _hasPendingMutation
                ? null
                : () => ref.invalidate(recordVideoStateProvider(record.id)),
            icon: const Icon(Icons.refresh),
            label: const Text('もう一度確認'),
          ),
        ],
      },
      loading: () => [
        _VideoStatusCard(
          icon: Icons.movie_outlined,
          title: record.videoDisplayName ?? '動画',
          message: '動画を確認しています…',
          loading: true,
        ),
      ],
      error: (_, _) => [
        _VideoStatusCard(
          icon: Icons.error_outline,
          title: record.videoDisplayName ?? '動画',
          message: '動画を確認できませんでした。実体なしとは判定していません。',
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _hasPendingMutation
              ? null
              : () => ref.invalidate(recordVideoStateProvider(record.id)),
          icon: const Icon(Icons.refresh),
          label: const Text('もう一度確認'),
        ),
      ],
    );
  }

  List<Widget> _recoveryVideoWidgets(SurgeryRecord record, String message) {
    return [
      _VideoStatusCard(
        icon: Icons.warning_amber_outlined,
        title: record.videoDisplayName ?? '動画',
        message: message,
      ),
      const SizedBox(height: 12),
      _videoActionWrap([
        _videoActionButton('同じ動画を再登録', _VideoMutation.relink),
        _videoActionButton('別の動画に差し替え', _VideoMutation.replace),
        _deleteVideoButton(),
      ]),
    ];
  }

  Widget _videoActionWrap(List<Widget> children) {
    return Wrap(spacing: 8, runSpacing: 8, children: children);
  }

  Widget _videoActionButton(String label, _VideoMutation mutation) {
    return FilledButton.icon(
      onPressed: _hasPendingMutation ? null : () => _pickVideo(mutation),
      icon: _isUpdatingVideo
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.video_call_outlined),
      label: Text(label),
    );
  }

  Widget _deleteVideoButton() {
    return OutlinedButton.icon(
      onPressed: _hasPendingMutation ? null : _deleteVideo,
      icon: const Icon(Icons.delete_outline),
      label: const Text('動画を削除'),
    );
  }

  Future<void> _editRecordDetails() async {
    final record = widget.record;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _EditRecordDialog(
        initialDate: record.surgeryDate,
        initialEyeSide: record.eyeSide,
        onSave: (surgeryDate, eyeSide) async {
          if (mounted) {
            setState(() => _isUpdatingDetails = true);
          }
          try {
            await ref
                .read(surgeryRepositoryProvider)
                .updateRecordDetails(
                  surgeryRecordId: record.id,
                  surgeryDate: surgeryDate,
                  eyeSide: eyeSide,
                );
            return null;
          } on SurgeryRecordNotFoundException {
            ref.invalidate(surgeryRecordProvider(record.id));
            return '症例が別の画面で削除されたため保存できません。';
          } on Object {
            return '変更を保存できませんでした。入力内容を保持しています。';
          } finally {
            if (mounted) {
              setState(() => _isUpdatingDetails = false);
            }
          }
        },
      ),
    );
    if (saved == true && mounted) {
      ref.invalidate(surgeryRecordProvider(record.id));
      ref.invalidate(surgeryRecordsProvider);
      ref.invalidate(surgeryRecordProgressProvider);
      ref.invalidate(surgeryAnalysisProvider);
      _showMessage('症例情報を変更しました', tone: AppFeedbackTone.success);
    }
  }

  Future<void> _pickVideo(_VideoMutation mutation) async {
    _lastVideoMutation = mutation;
    final record = widget.record;
    final expectedVideoPath = record.videoPath;
    if (mutation != _VideoMutation.attach && expectedVideoPath == null) {
      _invalidateRecordProviders();
      return;
    }
    setState(() => _isUpdatingVideo = true);
    try {
      selectionLoop:
      while (mounted) {
        final candidate = await selectVerifiedVideoForScreen(
          context: context,
          flow: _videoImportFlow,
          entryPoint: mutation == _VideoMutation.attach
              ? VideoImportEntryPoint.attach
              : mutation == _VideoMutation.relink
              ? VideoImportEntryPoint.relink
              : VideoImportEntryPoint.replace,
          onPersistentFailure: _rememberVideoImportFailure,
          dataInvariantSuffix:
              VideoImportDataInvariantSuffix.existingRecordUnchanged,
        );
        if (candidate == null || !mounted) {
          return;
        }

        var hasRecordedTimings = false;
        if (mutation != _VideoMutation.replace) {
          final timingState = await _readHasRecordedTimings(mutation);
          if (timingState == null || !mounted) {
            return;
          }
          hasRecordedTimings = timingState;
        }

        var clearsTimings = mutation == _VideoMutation.replace;
        if (hasRecordedTimings && mutation != _VideoMutation.replace) {
          final decision = await showVideoTimelineIdentityDialog(
            context: context,
          );
          if (decision == null || !mounted) {
            return;
          }
          clearsTimings =
              decision == VideoTimelineIdentityDecision.changedOrUnknown;
        }

        final confirmed = await _confirmSelectedVideo(
          mutation,
          clearsTimings: clearsTimings,
          hasRecordedTimings: hasRecordedTimings,
          hasExistingVideo: expectedVideoPath != null,
        );
        if (!confirmed || !mounted) {
          return;
        }

        while (mounted) {
          final result = await _runSelectedVideoMutation(
            candidate: candidate,
            mutation: mutation,
            expectedVideoPath: expectedVideoPath,
            clearsTimings: clearsTimings,
            hadRecordedTimingsAtConfirmation: hasRecordedTimings,
          );
          if (!mounted) {
            return;
          }
          if (result case VideoImportScreenOperationSuccess<
            VideoImportOutcome<SurgeryRecord>
          >(
            :final value,
          )) {
            _applyCommittedVideoOutcome(
              value,
              clearsTimings: clearsTimings,
              hadExistingVideo: expectedVideoPath != null,
            );
            return;
          }
          if (result
              is VideoImportScreenOperationCancelled<
                VideoImportOutcome<SurgeryRecord>
              >) {
            return;
          }
          final failure =
              result
                  as VideoImportScreenOperationFailure<
                    VideoImportOutcome<SurgeryRecord>
                  >;
          final resetRequested =
              !clearsTimings &&
              failure.error.code == VideoImportErrorCode.durationConflict &&
              (failure.recoveryAction ==
                      VideoImportRecoveryAction.resetTimingsAndAttach ||
                  failure.recoveryAction ==
                      VideoImportRecoveryAction.resetTimingsAndReplace);
          if (resetRequested) {
            final resetConfirmed = await _confirmSelectedVideo(
              mutation,
              clearsTimings: true,
              hasRecordedTimings: hasRecordedTimings,
              hasExistingVideo: expectedVideoPath != null,
            );
            if (!resetConfirmed || !mounted) {
              return;
            }
            clearsTimings = true;
            continue;
          }
          if (videoImportRecoveryRequestsReselection(failure.recoveryAction)) {
            continue selectionLoop;
          }
          if (videoImportRecoveryRequestsRetry(failure.recoveryAction)) {
            continue;
          }
          if (failure.recoveryAction ==
              VideoImportRecoveryAction.reloadRecord) {
            _invalidateRecordProviders();
          }
          return;
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isUpdatingVideo = false);
      }
    }
  }

  Future<bool?> _readHasRecordedTimings(_VideoMutation mutation) async {
    while (mounted) {
      try {
        return await ref
            .read(surgeryRepositoryProvider)
            .hasRecordedTimings(widget.record.id);
      } on Object {
        if (!mounted) {
          return null;
        }
        final action = await showVideoImportExceptionDialog(
          context: context,
          error: VideoImportException(
            code: VideoImportErrorCode.unknown,
            entryPoint: mutation == _VideoMutation.attach
                ? VideoImportEntryPoint.attach
                : VideoImportEntryPoint.relink,
            phase: VideoImportPhase.databaseCommit,
            internalReason: VideoImportInternalReasonV1.unexpected,
            primaryRecoveryAction: VideoImportRecoveryAction.retry,
            dataInvariantSuffix:
                VideoImportDataInvariantSuffix.existingRecordUnchanged,
          ),
        );
        if (action != VideoImportRecoveryAction.retry &&
            action != VideoImportRecoveryAction.unlockAndRetry) {
          return null;
        }
      }
    }
    return null;
  }

  Future<bool> _confirmSelectedVideo(
    _VideoMutation mutation, {
    required bool clearsTimings,
    required bool hasRecordedTimings,
    required bool hasExistingVideo,
  }) {
    if (clearsTimings) {
      return showAppConfirmDialog(
        context: context,
        title: hasExistingVideo ? '工程位置を消去して動画を差し替え' : '工程位置を消去して動画を登録',
        message:
            '総手術時間を含む全工程の開始・終了位置が削除されます。'
            '自己評価、反省点、症例メモは残ります。',
        confirmLabel: hasExistingVideo ? '差し替え' : '登録',
        isDestructive: true,
      );
    }
    return switch (mutation) {
      _VideoMutation.attach when hasRecordedTimings => showAppConfirmDialog(
        context: context,
        title: '記録済み位置を保持して動画を登録',
        message:
            '工程の開始・終了位置は保持されます。'
            '記録に対応する同じ手術動画を選択したことを確認してください。',
        confirmLabel: 'この動画を登録',
      ),
      _VideoMutation.attach => Future<bool>.value(true),
      _VideoMutation.relink => showAppConfirmDialog(
        context: context,
        title: '同じ動画を再登録',
        message:
            '選択したファイルが、この症例で使っていた同じ手術動画であることを'
            '確認してください。全工程の時刻とレビューは保持されます。',
        confirmLabel: '同じ動画として再登録',
      ),
      _VideoMutation.replace => showAppConfirmDialog(
        context: context,
        title: '工程位置を消去して動画を差し替え',
        message:
            '総手術時間を含む全工程の開始・終了位置が削除されます。'
            '自己評価、反省点、症例メモは残ります。',
        confirmLabel: '差し替え',
        isDestructive: true,
      ),
    };
  }

  Future<VideoImportScreenOperationResult<VideoImportOutcome<SurgeryRecord>>>
  _runSelectedVideoMutation({
    required VerifiedVideoCandidate candidate,
    required _VideoMutation mutation,
    required String? expectedVideoPath,
    required bool clearsTimings,
    required bool hadRecordedTimingsAtConfirmation,
  }) {
    final service = ref.read(recordVideoServiceProvider);
    return runVideoImportOperationForScreen<VideoImportOutcome<SurgeryRecord>>(
      context: context,
      dataInvariantSuffix:
          VideoImportDataInvariantSuffix.existingRecordUnchanged,
      entryPoint: clearsTimings
          ? expectedVideoPath == null
                ? VideoImportEntryPoint.attachWithTimingReset
                : VideoImportEntryPoint.replace
          : mutation == _VideoMutation.attach
          ? VideoImportEntryPoint.attach
          : VideoImportEntryPoint.relink,
      operationController: _videoImportOperationController,
      onPersistentFailure: _rememberVideoImportFailure,
      operation: (cancellationToken, onProgress) {
        if (clearsTimings) {
          if (expectedVideoPath == null) {
            return service.attachWithTimingReset(
              surgeryRecordId: widget.record.id,
              candidate: candidate,
              cancellationToken: cancellationToken,
              onProgress: onProgress,
            );
          }
          return service.replaceVideoForRecord(
            surgeryRecordId: widget.record.id,
            expectedVideoPath: expectedVideoPath,
            candidate: candidate,
            cancellationToken: cancellationToken,
            onProgress: onProgress,
          );
        }
        return switch (mutation) {
          _VideoMutation.attach => service.attachVideoToRecord(
            surgeryRecordId: widget.record.id,
            candidate: candidate,
            timelineIdentityDeclaration: hadRecordedTimingsAtConfirmation
                ? VideoTimelineIdentityDeclaration.sameUnchanged
                : VideoTimelineIdentityDeclaration.noRecordedTimingsObserved,
            cancellationToken: cancellationToken,
            onProgress: onProgress,
          ),
          _VideoMutation.relink => service.relinkSameVideo(
            surgeryRecordId: widget.record.id,
            expectedVideoPath: expectedVideoPath!,
            candidate: candidate,
            timelineIdentityDeclaration: hadRecordedTimingsAtConfirmation
                ? VideoTimelineIdentityDeclaration.sameUnchanged
                : VideoTimelineIdentityDeclaration.noRecordedTimingsObserved,
            cancellationToken: cancellationToken,
            onProgress: onProgress,
          ),
          _VideoMutation.replace => throw StateError(
            'replace must clear timings',
          ),
        };
      },
    );
  }

  void _applyCommittedVideoOutcome(
    VideoImportOutcome<SurgeryRecord> outcome, {
    required bool clearsTimings,
    required bool hadExistingVideo,
  }) {
    if (mounted) {
      setState(() => _lastVideoImportError = null);
    }
    _invalidateRecordProviders();
    if (outcome.maintenanceOutcome == VideoMaintenanceOutcome.pending) {
      _showMessage(
        '保存は完了しました。動画の後処理は次回起動時に再試行します。',
        tone: AppFeedbackTone.warning,
      );
      return;
    }
    _showMessage(
      clearsTimings
          ? hadExistingVideo
                ? '動画を差し替え、工程位置を削除しました'
                : '動画を登録し、工程位置を削除しました'
          : '動画を登録し、記録済みの内容を保持しました',
      tone: AppFeedbackTone.success,
    );
  }

  void _rememberVideoImportFailure(VideoImportException error) {
    if (mounted) {
      setState(() => _lastVideoImportError = error);
    }
  }

  Future<void> _migrateLegacyVideo() async {
    final confirmed = await showAppConfirmDialog(
      context: context,
      title: '旧形式動画を移行',
      message: '同じ動画をアプリ管理領域へ安全にコピーします。全工程位置とレビューは保持し、外部原本は削除しません。',
      confirmLabel: '安全に移行',
    );
    if (!confirmed || !mounted) {
      return;
    }
    setState(() => _isUpdatingVideo = true);
    try {
      final service = ref.read(recordVideoServiceProvider);
      await service.migrateLegacyVideoForRecord(widget.record);
      _invalidateRecordProviders();
      if (service.hasPendingCleanup) {
        _showMessage(
          '旧形式動画の移行は完了しました。動画ファイルの後処理は次回起動時に再試行します。',
          tone: AppFeedbackTone.warning,
        );
      } else {
        _showMessage('旧形式動画を移行し、全工程記録を保持しました', tone: AppFeedbackTone.success);
      }
    } catch (error) {
      _recoverFromVideoError(
        error,
        fallback: '動画を移行できませんでした。外部原本と工程記録は保持されています。',
      );
    } finally {
      if (mounted) {
        setState(() => _isUpdatingVideo = false);
      }
    }
  }

  Future<void> _deleteVideo() async {
    final expectedVideoPath = widget.record.videoPath;
    if (expectedVideoPath == null) {
      _invalidateRecordProviders();
      return;
    }
    final confirmed = await showAppConfirmDialog(
      context: context,
      title: '動画を削除',
      message:
          '動画参照と、総手術時間を含む全工程の開始・終了位置を削除します。自己評価、反省点、症例メモは残ります。旧形式の外部原本は削除しません。',
      confirmLabel: '動画と工程位置を削除',
      isDestructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }

    setState(() => _isUpdatingVideo = true);
    try {
      final service = ref.read(recordVideoServiceProvider);
      await service.removeVideoForRecord(
        widget.record.id,
        expectedVideoPath: expectedVideoPath,
      );
      _invalidateRecordProviders();
      if (service.hasPendingCleanup) {
        _showMessage(
          '動画参照と全工程位置の削除は完了しました。動画ファイルの後処理は次回起動時に再試行します。',
          tone: AppFeedbackTone.warning,
        );
      } else {
        _showMessage('動画と全工程位置を削除しました', tone: AppFeedbackTone.success);
      }
    } catch (error) {
      _recoverFromVideoError(
        error,
        fallback: '動画を削除できませんでした。動画参照と工程記録は保持されています。',
      );
    } finally {
      if (mounted) {
        setState(() => _isUpdatingVideo = false);
      }
    }
  }

  void _invalidateRecordProviders() {
    ref.invalidate(surgeryRecordProvider(widget.record.id));
    ref.invalidate(surgeryRecordsProvider);
    ref.invalidate(surgeryRecordProgressProvider);
    ref.invalidate(recordVideoStateProvider(widget.record.id));
    ref.invalidate(recordVideoFileProvider(widget.record.id));
    ref.invalidate(videoStorageMaintenanceProvider);
    ref.invalidate(stepReviewsProvider(widget.record.id));
    ref.invalidate(recordProcedureTimingSnapshotProvider(widget.record.id));
    ref.invalidate(surgeryAnalysisProvider);
  }

  void _recoverFromVideoError(Object error, {String? fallback}) {
    if (error is VideoReferenceConflictException) {
      _invalidateRecordProviders();
      _showMessage(
        '操作中に動画が変更されたため保存しませんでした。最新状態を読み込みます。',
        tone: AppFeedbackTone.warning,
      );
      return;
    }
    if (error is SurgeryRecordNotFoundException) {
      _invalidateRecordProviders();
      _showMessage('症例が別の画面で削除されたため操作できません。', tone: AppFeedbackTone.warning);
      return;
    }
    _showMessage(
      fallback ?? '操作を完了できませんでした。もう一度お試しください。',
      tone: AppFeedbackTone.failure,
    );
  }

  Future<void> _deleteRecord() async {
    final confirmed = await showAppConfirmDialog(
      context: context,
      title: 'この症例を削除しますか？',
      message:
          'この症例の記録（総手術時間、工程記録、自己評価、反省点、症例メモ）と、アプリ内に保存された動画を削除します。アプリ外の元動画は削除されません。この操作は元に戻せません。',
      confirmLabel: '削除',
      isDestructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    setState(() => _isDeleting = true);
    try {
      final service = ref.read(recordVideoServiceProvider);
      await service.deleteRecordAndManagedVideos(widget.record.id);
      ref.invalidate(surgeryRecordsProvider);
      ref.invalidate(surgeryRecordProgressProvider);
      ref.invalidate(recordProcedureTimingSnapshotProvider(widget.record.id));
      ref.invalidate(surgeryAnalysisProvider);
      ref.invalidate(videoStorageMaintenanceProvider);
      if (mounted) {
        if (service.hasPendingCleanup) {
          _showMessage(
            '症例の削除は完了しました。動画ファイルの後処理は次回起動時に再試行します。',
            tone: AppFeedbackTone.warning,
          );
        } else {
          _showMessage('症例を削除しました', tone: AppFeedbackTone.success);
        }
        Navigator.of(context).pop();
      }
    } catch (_) {
      _showMessage(
        '症例を削除できませんでした。症例と動画、工程記録は保持されています。',
        tone: AppFeedbackTone.failure,
      );
    } finally {
      if (mounted) {
        setState(() => _isDeleting = false);
      }
    }
  }

  void _showMessage(
    String message, {
    AppFeedbackTone tone = AppFeedbackTone.neutral,
  }) {
    if (mounted) {
      showAppSnackBar(context, message: message, tone: tone);
    }
  }
}

class _BackupExclusionStatus extends ConsumerWidget {
  const _BackupExclusionStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maintenance = ref.watch(videoStorageMaintenanceProvider);
    return maintenance.when(
      data: (report) {
        final verified =
            report != null &&
            report.snapshotComplete &&
            report.backupExclusionVerified;
        if (verified) {
          return const SizedBox.shrink(key: Key('backup-exclusion-hidden'));
        }
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _BackupExclusionWarning(
            onRetry: () => ref.invalidate(videoStorageMaintenanceProvider),
          ),
        );
      },
      loading: () => const SizedBox.shrink(key: Key('backup-exclusion-hidden')),
      error: (_, _) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: _BackupExclusionWarning(
          onRetry: () => ref.invalidate(videoStorageMaintenanceProvider),
        ),
      ),
    );
  }
}

class _BackupExclusionWarning extends StatelessWidget {
  const _BackupExclusionWarning({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Card(
        key: const Key('backup-exclusion-warning'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              const Icon(Icons.privacy_tip_outlined),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('バックアップ除外を確認できませんでした。動画は閲覧できます。もう一度確認してください。'),
              ),
              TextButton(onPressed: onRetry, child: const Text('再確認')),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
    );
  }
}

class _ProgressSummary extends StatelessWidget {
  const _ProgressSummary({
    required this.progress,
    required this.isLoading,
    required this.hasError,
    required this.onRetry,
  });

  final SurgeryRecordProgress? progress;
  final bool isLoading;
  final bool hasError;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final snapshot = progress;
    if (snapshot == null && isLoading) {
      return const Row(
        children: [
          SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 12),
          Expanded(child: Text('工程情報を確認しています…')),
        ],
      );
    }
    if (snapshot == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            hasError ? '工程情報を確認できませんでした。工程記録はそのまま開けます。' : '工程情報がまだ反映されていません。',
          ),
          if (hasError) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('再読み込み'),
              ),
            ),
          ],
        ],
      );
    }
    final completedLabel = snapshot.completedStepCount == 0
        ? '未記録'
        : '工程 ${snapshot.completedStepCount}/10';
    final progressLabel =
        '$completedLabel${snapshot.hasRunningStep ? '・計測中' : ''}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.fact_check_outlined),
            const SizedBox(width: 8),
            Expanded(child: Text(progressLabel)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(Icons.timer_outlined),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                snapshot.totalSurgeryDuration == null
                    ? '総手術時間：未記録'
                    : '総手術時間：'
                          '${formatProcedureDuration(snapshot.totalSurgeryDuration!)}',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ProcedureTimesExpansion extends StatefulWidget {
  const _ProcedureTimesExpansion({
    required this.snapshot,
    required this.onRetry,
  });

  final AsyncValue<RecordProcedureTimingSnapshot> snapshot;
  final VoidCallback onRetry;

  @override
  State<_ProcedureTimesExpansion> createState() =>
      _ProcedureTimesExpansionState();
}

class _ProcedureTimesExpansionState extends State<_ProcedureTimesExpansion> {
  bool _isExpanded = false;

  void _toggle() {
    setState(() => _isExpanded = !_isExpanded);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          key: const Key('procedure-times-expansion-toggle'),
          label: '工程別時間',
          button: true,
          expanded: _isExpanded,
          onTap: _toggle,
          excludeSemantics: true,
          child: InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '工程別時間',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Icon(_isExpanded ? Icons.expand_less : Icons.expand_more),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_isExpanded) ...[
          const SizedBox(height: 8),
          widget.snapshot.when(
            skipLoadingOnRefresh: false,
            data: (snapshot) => _ProcedureTimesList(snapshot: snapshot),
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Expanded(child: Text('工程別時間を読み込んでいます…')),
                ],
              ),
            ),
            error: (_, _) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('工程別時間を読み込めませんでした。'),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('procedure-times-retry'),
                      onPressed: widget.onRetry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('再読み込み'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ProcedureTimesList extends StatelessWidget {
  const _ProcedureTimesList({required this.snapshot});

  static const _arrivalCalculator = ProcedureArrivalTimeCalculator();

  final RecordProcedureTimingSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final totalSurgery = snapshot.reviewFor(SurgicalStep.totalSurgeryTime);
    final results = <SurgicalStep, ProcedureArrivalTimeResult>{
      for (final step in activeIndividualSurgicalSteps)
        step: _arrivalCalculator.calculate(
          step: step,
          stepReview: snapshot.reviewFor(step),
          totalSurgeryReview: totalSurgery,
        ),
    };
    final needsTotalStartExplanation = results.values.any(
      (result) =>
          result.status == ProcedureArrivalTimeStatus.totalSurgeryStartMissing,
    );

    return Column(
      key: const Key('procedure-times-list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (
          var index = 0;
          index < activeIndividualSurgicalSteps.length;
          index++
        ) ...[
          if (index > 0) const Divider(height: 24),
          _ProcedureTimeRow(
            step: activeIndividualSurgicalSteps[index],
            review: snapshot.reviewFor(activeIndividualSurgicalSteps[index]),
            arrivalTime: results[activeIndividualSurgicalSteps[index]]!,
          ),
        ],
        if (needsTotalStartExplanation) ...[
          const SizedBox(height: 12),
          Text(
            '「総手術時間」の開始位置を登録すると「開始まで」が表示されます。',
            key: const Key('procedure-times-total-start-help'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _ProcedureTimeRow extends StatelessWidget {
  const _ProcedureTimeRow({
    required this.step,
    required this.review,
    required this.arrivalTime,
  });

  final SurgicalStep step;
  final SurgicalStepReview? review;
  final ProcedureArrivalTimeResult arrivalTime;

  @override
  Widget build(BuildContext context) {
    final presentation = ProcedureArrivalTimePresentation.fromResult(
      arrivalTime,
    );
    final durationText = _durationText(review);
    final semanticsLabel = arrivalTime.isAvailable
        ? '${step.label}。${presentation.detailSemanticsClause}'
              '${_durationSemantics(review)}'
        : '${step.label}。${presentation.detailSemanticsClause}';
    final repeatsTotalStartHelp =
        arrivalTime.status ==
        ProcedureArrivalTimeStatus.totalSurgeryStartMissing;

    return Semantics(
      key: ValueKey('procedure-time-row-${step.name}'),
      container: true,
      label: semanticsLabel,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(step.label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text('所要時間：$durationText'),
          const SizedBox(height: 2),
          ProcedureArrivalTimeView(
            result: arrivalTime,
            showSupportingText: !repeatsTotalStartHelp,
          ),
        ],
      ),
    );
  }

  static String _durationText(SurgicalStepReview? review) {
    if (review == null) {
      return '未登録';
    }
    if (review.recordingStatus == StepRecordingStatus.skipped) {
      return '時間記録なし';
    }
    final duration = review.duration;
    if (duration != null) {
      return formatProcedureDuration(duration);
    }
    if (review.isRunning) {
      return '計測中';
    }
    if (review.isNotStarted) {
      return '未登録';
    }
    return '要再設定';
  }

  static String _durationSemantics(SurgicalStepReview? review) {
    if (review == null || review.isNotStarted) {
      return '所要時間は未登録です。';
    }
    if (review.recordingStatus == StepRecordingStatus.skipped) {
      return '今回は時間を記録しません。';
    }
    final duration = review.duration;
    if (duration != null) {
      return '所要時間${formatProcedureDuration(duration)}。';
    }
    if (review.isRunning) {
      return '所要時間は計測中です。';
    }
    return '所要時間を再設定してください。';
  }
}

class _VideoStatusCard extends StatelessWidget {
  const _VideoStatusCard({
    required this.icon,
    required this.title,
    required this.message,
    this.loading = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(message),
        trailing: loading
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
      ),
    );
  }
}

typedef _SaveRecordDetails =
    Future<String?> Function(DateTime surgeryDate, EyeSide eyeSide);

class _EditRecordDialog extends StatefulWidget {
  const _EditRecordDialog({
    required this.initialDate,
    required this.initialEyeSide,
    required this.onSave,
  });

  final DateTime initialDate;
  final EyeSide initialEyeSide;
  final _SaveRecordDetails onSave;

  @override
  State<_EditRecordDialog> createState() => _EditRecordDialogState();
}

class _EditRecordDialogState extends State<_EditRecordDialog> {
  late DateTime _surgeryDate = widget.initialDate;
  late EyeSide _eyeSide = widget.initialEyeSide;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: !_isSaving,
      child: AlertDialog(
        title: const Text('手術日・左右眼を変更'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('手術日'),
                subtitle: Text(
                  DateFormat('yyyy/MM/dd', 'ja_JP').format(_surgeryDate),
                ),
                trailing: const Icon(Icons.calendar_today),
                onTap: _isSaving ? null : _pickDate,
              ),
              const SizedBox(height: 12),
              SegmentedButton<EyeSide>(
                segments: EyeSide.values
                    .map(
                      (side) => ButtonSegment<EyeSide>(
                        value: side,
                        label: Text(side.label),
                      ),
                    )
                    .toList(),
                selected: {_eyeSide},
                onSelectionChanged: _isSaving
                    ? null
                    : (selection) {
                        setState(() => _eyeSide = selection.single);
                      },
              ),
              if (_errorMessage case final message?) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    message,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: _isSaving ? null : _save,
            child: _isSaving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    final error = await widget.onSave(_surgeryDate, _eyeSide);
    if (!mounted) {
      return;
    }
    if (error == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _isSaving = false;
      _errorMessage = error;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _surgeryDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() => _surgeryDate = picked);
    }
  }
}
