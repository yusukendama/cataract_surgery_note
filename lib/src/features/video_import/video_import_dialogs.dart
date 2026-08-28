import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/video_import_models.dart';
import '../../theme/app_tokens.dart';

const String _nonCandidateTitle = 'この拡張子のファイルは登録対象外です';
const String _nonCandidateMessage = '''選択したファイルの拡張子は、現在の白内障執刀ノートでは登録対象外です。

ファイルが正常な動画かどうかや、保護の有無は確認していません。選択元で正常に利用できる動画であることを確認してください。

必要な場合は、所属施設が承認した方法で、再登録できる設定の別ファイルを用意し、あらためて選択してください。

手術動画を、所属施設が承認していないWebサイトやクラウドサービスへアップロードしないでください。

元のファイルは変更されていません。''';

@immutable
class VideoImportDialogContent {
  const VideoImportDialogContent({
    required this.title,
    required this.message,
    required this.actions,
  });

  final String title;
  final String message;
  final List<VideoImportRecoveryAction> actions;
}

/// Presents the registration-policy dialog without including a filename or
/// implying that the selected file itself was opened or inspected.
Future<VideoImportRecoveryAction> showNonCandidateVideoDialog({
  required BuildContext context,
  required VideoImportDataInvariantSuffix dataInvariantSuffix,
}) async {
  final result = await showDialog<VideoImportRecoveryAction>(
    context: context,
    barrierDismissible: false,
    builder: (_) => VideoImportAlertDialog(
      content: nonCandidateVideoDialogContent(
        dataInvariantSuffix: dataInvariantSuffix,
      ),
    ),
  );
  return result ?? VideoImportRecoveryAction.dismiss;
}

/// Presents a blocking domain error. Non-dialog presentations are returned as
/// dismissals so callers remain responsible for persistent inline rendering.
Future<VideoImportRecoveryAction> showVideoImportExceptionDialog({
  required BuildContext context,
  required VideoImportException error,
  VideoImportDataInvariantSuffix? dataInvariantSuffix,
}) async {
  if (error.code == VideoImportErrorCode.userCanceled ||
      error.presentation != VideoImportPresentation.blockingDialog) {
    return VideoImportRecoveryAction.dismiss;
  }

  final result = await showDialog<VideoImportRecoveryAction>(
    context: context,
    barrierDismissible: false,
    builder: (_) => VideoImportAlertDialog(
      content: videoImportDialogContentFor(
        error,
        dataInvariantSuffix: dataInvariantSuffix,
      ),
    ),
  );
  return result ?? VideoImportRecoveryAction.dismiss;
}

VideoImportDialogContent nonCandidateVideoDialogContent({
  required VideoImportDataInvariantSuffix dataInvariantSuffix,
}) {
  return VideoImportDialogContent(
    title: _nonCandidateTitle,
    message: _appendInvariant(_nonCandidateMessage, dataInvariantSuffix),
    actions: const <VideoImportRecoveryAction>[
      VideoImportRecoveryAction.reselect,
      VideoImportRecoveryAction.openReferenceHelp,
      VideoImportRecoveryAction.dismiss,
    ],
  );
}

VideoImportDialogContent videoImportDialogContentFor(
  VideoImportException error, {
  VideoImportDataInvariantSuffix? dataInvariantSuffix,
}) {
  final suffix = dataInvariantSuffix ?? error.dataInvariantSuffix;
  final copy = switch (error.code) {
    VideoImportErrorCode.userCanceled => const _DialogCopy(
      title: '',
      message: '',
    ),
    VideoImportErrorCode.nonCandidateExtension => const _DialogCopy(
      title: _nonCandidateTitle,
      message: _nonCandidateMessage,
    ),
    VideoImportErrorCode.unplayableMedia ||
    VideoImportErrorCode.playbackVerificationTimedOut => const _DialogCopy(
      title: 'この動画は使用できません',
      message:
          'この動画を白内障執刀ノートで再生できることを確認できませんでした。\n\n'
          '動画形式やコーデックに対応していないか、ファイルが破損している可能性があります。\n\n'
          '選択元で動画を確認してください。',
    ),
    VideoImportErrorCode.sourceNotFound ||
    VideoImportErrorCode.sourceAccessDenied ||
    VideoImportErrorCode.providerUnavailable ||
    VideoImportErrorCode.sourceReadFailed => const _DialogCopy(
      title: '動画を読み込めませんでした',
      message:
          'ファイルへのアクセスが終了したか、選択元から動画を取得できなかった可能性があります。\n\n'
          '「ファイル」アプリでファイルを利用できることを確認して、もう一度選択してください。',
    ),
    VideoImportErrorCode.protectedDataUnavailable => const _DialogCopy(
      title: '端末のロックを解除してください',
      message: '保護された動画と症例データを利用できません。端末のロックを解除して、もう一度お試しください。',
    ),
    VideoImportErrorCode.protectedMedia => const _DialogCopy(
      title: 'この動画は利用できません',
      message:
          'この動画は保護されているため利用できません。\n\n'
          '利用可能な動画について、所属施設の担当者へ確認してください。',
    ),
    VideoImportErrorCode.sourceChanged ||
    VideoImportErrorCode.copyIntegrityFailed => const _DialogCopy(
      title: '動画が変更されています',
      message:
          '選択後にファイルが変更されたか、同じファイルであることを確認できませんでした。'
          '選択元を確認して、もう一度選択してください。',
    ),
    VideoImportErrorCode.insufficientStorage => const _DialogCopy(
      title: '動画を保存できませんでした',
      message: '端末の空き容量を増やしてから、もう一度お試しください。',
    ),
    VideoImportErrorCode.destinationWriteFailed ||
    VideoImportErrorCode.fileProtectionFailed ||
    VideoImportErrorCode.backupExclusionFailed ||
    VideoImportErrorCode.destinationPlaybackFailed => const _DialogCopy(
      title: '動画を安全に保存できませんでした',
      message: '動画の保存または保存後の確認を完了できなかったため、登録していません。もう一度お試しください。',
    ),
    VideoImportErrorCode.durationConflict => const _DialogCopy(
      title: '工程位置を保持できません',
      message:
          '選択した動画は、記録済みの工程位置より短いため、その位置を保持したまま登録できません。'
          '工程位置を消去して登録し直すか、同じ動画を選択してください。',
    ),
    VideoImportErrorCode.videoReferenceConflict => const _DialogCopy(
      title: '症例が更新されました',
      message: '操作中にこの症例の動画が更新されました。最新の状態を読み込んで、もう一度お試しください。',
    ),
    VideoImportErrorCode.commitFailed => const _DialogCopy(
      title: '症例に動画を登録できませんでした',
      message: '症例データの更新を完了できませんでした。',
    ),
    VideoImportErrorCode.unknown => const _DialogCopy(
      title: '操作を完了できませんでした',
      message:
          '原因を確認できませんでした。もう一度お試しください。'
          '繰り返し発生する場合は、実際の患者動画を添付せずサポートへ連絡してください。',
    ),
  };

  return VideoImportDialogContent(
    title: copy.title,
    message: _appendInvariant(copy.message, suffix),
    actions: _actionsFor(error),
  );
}

class VideoImportAlertDialog extends StatelessWidget {
  const VideoImportAlertDialog({required this.content, super.key});

  final VideoImportDialogContent content;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Navigator.of(context).pop(VideoImportRecoveryAction.dismiss);
        },
      },
      child: AlertDialog(
        semanticLabel: _alertSemanticLabel(content),
        scrollable: true,
        title: Focus(
          key: const ValueKey<String>('video-import-dialog-title-focus'),
          autofocus: true,
          child: Semantics(header: true, child: Text(content.title)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(content.message),
            const SizedBox(height: AppSpacing.medium),
            Semantics(
              container: true,
              explicitChildNodes: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (var index = 0; index < content.actions.length; index++)
                    Padding(
                      padding: EdgeInsets.only(
                        top: index == 0 ? 0 : AppSpacing.xSmall,
                      ),
                      child: _RecoveryActionButton(
                        action: content.actions[index],
                        isPrimary:
                            index == 0 &&
                            content.actions[index] !=
                                VideoImportRecoveryAction.dismiss,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecoveryActionButton extends StatelessWidget {
  const _RecoveryActionButton({required this.action, required this.isPrimary});

  final VideoImportRecoveryAction action;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    void onPressed() => Navigator.of(context).pop(action);

    final label = _recoveryActionLabel(action);
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
    );
    final Widget button;
    if (isPrimary) {
      button = FilledButton(
        style: style,
        onPressed: onPressed,
        child: Text(label),
      );
    } else {
      button = TextButton(
        style: style,
        onPressed: onPressed,
        child: Text(label),
      );
    }
    return SizedBox(width: double.infinity, child: button);
  }
}

String _alertSemanticLabel(VideoImportDialogContent content) {
  final actions = content.actions.map(_recoveryActionLabel).join('、');
  return '${content.title}\n'
      '原因と現在の状態: ${content.message}\n'
      '次の操作: $actions';
}

List<VideoImportRecoveryAction> _actionsFor(VideoImportException error) {
  if (error.code == VideoImportErrorCode.userCanceled) {
    return const <VideoImportRecoveryAction>[VideoImportRecoveryAction.dismiss];
  }
  if (error.code == VideoImportErrorCode.nonCandidateExtension) {
    return const <VideoImportRecoveryAction>[
      VideoImportRecoveryAction.reselect,
      VideoImportRecoveryAction.openReferenceHelp,
      VideoImportRecoveryAction.dismiss,
    ];
  }

  final actions = <VideoImportRecoveryAction>[error.primaryRecoveryAction];
  final secondary = error.secondaryRecoveryActions.toList()
    ..sort((left, right) => left.index.compareTo(right.index));
  for (final action in secondary) {
    // Cause-uncertain playback errors must not link directly to conversion
    // guidance, even if a malformed error includes that secondary action.
    if (action == VideoImportRecoveryAction.openReferenceHelp) {
      continue;
    }
    if (!actions.contains(action)) {
      actions.add(action);
    }
  }
  if (!actions.contains(VideoImportRecoveryAction.dismiss)) {
    actions.add(VideoImportRecoveryAction.dismiss);
  }
  return List<VideoImportRecoveryAction>.unmodifiable(actions);
}

String _appendInvariant(String message, VideoImportDataInvariantSuffix suffix) {
  final invariant = switch (suffix) {
    VideoImportDataInvariantSuffix.createNotRegistered => '症例への登録は行っていません。',
    VideoImportDataInvariantSuffix.existingRecordUnchanged =>
      '登録済みの動画と工程位置は変更していません。',
    VideoImportDataInvariantSuffix.none => '',
  };
  if (invariant.isEmpty || message.contains(invariant)) {
    return message;
  }
  return '$message\n\n$invariant';
}

String _recoveryActionLabel(VideoImportRecoveryAction action) {
  return switch (action) {
    VideoImportRecoveryAction.dismiss => '閉じる',
    VideoImportRecoveryAction.reselect ||
    VideoImportRecoveryAction.checkSourceAndReselect => '別の動画を選ぶ',
    VideoImportRecoveryAction.retry ||
    VideoImportRecoveryAction.unlockAndRetry ||
    VideoImportRecoveryAction.freeStorageAndRetry => 'もう一度試す',
    VideoImportRecoveryAction.reloadRecord => '最新の状態を読み込む',
    VideoImportRecoveryAction.resetTimingsAndAttach => '工程位置を消去して動画を登録',
    VideoImportRecoveryAction.resetTimingsAndReplace => '工程位置を消去して動画を差し替え',
    VideoImportRecoveryAction.contactSupport => 'サポートへ連絡',
    VideoImportRecoveryAction.openReferenceHelp => '登録できる動画の目安を見る',
  };
}

class _DialogCopy {
  const _DialogCopy({required this.title, required this.message});

  final String title;
  final String message;
}
