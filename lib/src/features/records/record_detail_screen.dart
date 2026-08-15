import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/providers.dart';
import '../../data/record_mutation_coordinator.dart';
import '../../data/record_video_service.dart';
import '../../data/surgery_repository.dart';
import '../../data/surgery_video_picker.dart';
import '../../domain/duration_formatters.dart';
import '../../domain/surgery_models.dart';
import '../../widgets/app_confirm_dialog.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/app_states.dart';
import '../review/step_review_screen.dart';

enum _VideoMutation { attach, relink, replace }

class RecordDetailScreen extends ConsumerWidget {
  const RecordDetailScreen({required this.recordId, super.key});

  final String recordId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final record = ref.watch(surgeryRecordProvider(recordId));

    return Scaffold(
      appBar: AppBar(title: const Text('症例詳細')),
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
          onRetry: () => ref.invalidate(surgeryRecordProvider(recordId)),
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
  bool _isDeleting = false;
  bool _isUpdatingVideo = false;
  bool _isUpdatingDetails = false;

  bool get _hasPendingMutation =>
      _isDeleting || _isUpdatingVideo || _isUpdatingDetails;

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final videoState = ref.watch(recordVideoStateProvider(record.id));
    final progressSnapshot = ref.watch(surgeryRecordProgressProvider);
    SurgeryRecordProgress? progress;
    for (final item
        in progressSnapshot.asData?.value ?? const <SurgeryRecordProgress>[]) {
      if (item.record.id == record.id) {
        progress = item;
        break;
      }
    }

    return PopScope<void>(
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
          const _SectionTitle('危険操作'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
              side: BorderSide(color: Theme.of(context).colorScheme.error),
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
          const SizedBox(height: 8),
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
    final record = widget.record;
    final expectedVideoPath = record.videoPath;
    if (mutation != _VideoMutation.attach && expectedVideoPath == null) {
      _invalidateRecordProviders();
      return;
    }
    final preselectionConfirmed = await showAppConfirmDialog(
      context: context,
      title: switch (mutation) {
        _VideoMutation.attach => '記録に対応する動画を選択',
        _VideoMutation.relink => '同じ動画を再登録',
        _VideoMutation.replace => '別の動画に差し替え',
      },
      message: switch (mutation) {
        _VideoMutation.attach => '記録済みの工程位置を保持するため、対応する同じ手術動画を選んでください。',
        _VideoMutation.relink => '記録済みの位置は保持されます。必ず同じ手術動画を選んでください。',
        _VideoMutation.replace =>
          '総手術時間を含む全工程の開始・終了位置が削除されます。自己評価、反省点、症例メモは残ります。',
      },
      confirmLabel: '動画を選ぶ',
      isDestructive: mutation == _VideoMutation.replace,
    );
    if (!preselectionConfirmed || !mounted) {
      return;
    }

    final SelectedSurgeryVideo? selectedVideo;
    try {
      selectedVideo = await ref.read(surgeryVideoPickerProvider).pickVideo();
    } catch (_) {
      _showMessage(
        '動画を選択できませんでした。写真へのアクセス権限を確認してください。',
        tone: AppFeedbackTone.failure,
      );
      return;
    }
    if (selectedVideo == null || !mounted) {
      return;
    }
    final path = selectedVideo.path;
    final fileName = selectedVideo.displayName;
    final finalConfirmed = await showAppConfirmDialog(
      context: context,
      title: switch (mutation) {
        _VideoMutation.attach => 'この動画を登録しますか？',
        _VideoMutation.relink => '同じ動画ですか？',
        _VideoMutation.replace => 'この動画に差し替えますか？',
      },
      message: switch (mutation) {
        _VideoMutation.attach => '$fileName\n\n記録済みの全工程位置とレビューは保持されます。',
        _VideoMutation.relink =>
          '$fileName\n\n記録時と同じ手術動画であることを確認してください。全工程位置は保持されます。',
        _VideoMutation.replace =>
          '$fileName\n\n総手術時間を含む全工程の開始・終了位置を削除します。自己評価、反省点、症例メモは残ります。',
      },
      confirmLabel: switch (mutation) {
        _VideoMutation.attach => '登録',
        _VideoMutation.relink => '同じ動画として登録',
        _VideoMutation.replace => '差し替え',
      },
      isDestructive: mutation == _VideoMutation.replace,
    );
    if (!finalConfirmed || !mounted) {
      return;
    }

    setState(() => _isUpdatingVideo = true);
    try {
      final service = ref.read(recordVideoServiceProvider);
      switch (mutation) {
        case _VideoMutation.attach:
          await service.attachVideoToRecord(
            surgeryRecordId: record.id,
            sourcePath: path,
            originalFileName: fileName,
          );
          break;
        case _VideoMutation.relink:
          await service.relinkSameVideo(
            surgeryRecordId: record.id,
            expectedVideoPath: expectedVideoPath!,
            sourcePath: path,
            originalFileName: fileName,
          );
          break;
        case _VideoMutation.replace:
          await service.replaceVideoForRecord(
            surgeryRecordId: record.id,
            expectedVideoPath: expectedVideoPath!,
            sourcePath: path,
            originalFileName: fileName,
          );
          break;
      }
      _invalidateRecordProviders();
      if (service.hasPendingCleanup) {
        _showMessage(
          '動画の保存は完了しました。動画ファイルの後処理は次回起動時に再試行します。',
          tone: AppFeedbackTone.warning,
        );
      } else {
        _showMessage(
          mutation == _VideoMutation.replace
              ? '動画を差し替え、工程位置を削除しました'
              : '動画を登録し、記録済みの内容を保持しました',
          tone: AppFeedbackTone.success,
        );
      }
    } catch (error) {
      _recoverFromVideoError(error);
    } finally {
      if (mounted) {
        setState(() => _isUpdatingVideo = false);
      }
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
    ref.invalidate(surgeryAnalysisProvider);
  }

  String _videoErrorMessage(Object error) {
    if (error is PlatformException &&
        error.code.startsWith('backup_exclusion')) {
      return '動画のバックアップ除外を確認できなかったため保存していません。もう一度お試しください。';
    }
    if (error is ArgumentError) {
      return 'この動画形式は再生できません。MP4形式などに変換してから、もう一度選択してください。';
    }
    if (error is FileSystemException) {
      return '動画を保存できませんでした。ストレージの空き容量をご確認ください。';
    }
    return '動画を保存できませんでした。もう一度お試しください。';
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
      fallback ?? _videoErrorMessage(error),
      tone: AppFeedbackTone.failure,
    );
  }

  Future<void> _deleteRecord() async {
    final confirmed = await showAppConfirmDialog(
      context: context,
      title: '症例を削除',
      message:
          'この症例、総手術時間を含む全工程記録、自己評価、反省点、症例メモを削除します。アプリ管理動画も削除しますが、旧形式の外部原本は削除しません。この操作は元に戻せません。',
      confirmLabel: '症例を削除',
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
          return Text(
            'バックアップ除外を確認済みです。選択元の動画も別途保管してください。',
            key: const Key('backup-exclusion-verified'),
            style: Theme.of(context).textTheme.bodySmall,
          );
        }
        return _BackupExclusionWarning(
          onRetry: () => ref.invalidate(videoStorageMaintenanceProvider),
        );
      },
      loading: () => const Row(
        key: Key('backup-exclusion-checking'),
        children: [
          SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Expanded(child: Text('バックアップ除外を確認しています…')),
        ],
      ),
      error: (_, _) => _BackupExclusionWarning(
        onRetry: () => ref.invalidate(videoStorageMaintenanceProvider),
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
