import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/features/video_import/video_import_dialogs.dart';
import 'package:cataract_surgery_note/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('non-candidate copy is honest and does not include file identity', () {
    final content = nonCandidateVideoDialogContent(
      dataInvariantSuffix: VideoImportDataInvariantSuffix.createNotRegistered,
    );

    expect(content.title, 'この拡張子のファイルは登録対象外です');
    expect(content.message, contains('正常な動画かどうかや、保護の有無は確認していません'));
    expect(content.message, contains('元のファイルは変更されていません'));
    expect(content.message, contains('症例への登録は行っていません'));
    expect(content.message, isNot(contains('patient-name')));
    expect(content.actions, const <VideoImportRecoveryAction>[
      VideoImportRecoveryAction.reselect,
      VideoImportRecoveryAction.openReferenceHelp,
      VideoImportRecoveryAction.dismiss,
    ]);
  });

  test('unplayable and timeout never expose the reference-help action', () {
    for (final code in <VideoImportErrorCode>[
      VideoImportErrorCode.unplayableMedia,
      VideoImportErrorCode.playbackVerificationTimedOut,
    ]) {
      final content = videoImportDialogContentFor(
        _error(
          code,
          secondary: const <VideoImportRecoveryAction>{
            VideoImportRecoveryAction.openReferenceHelp,
          },
        ),
        dataInvariantSuffix:
            VideoImportDataInvariantSuffix.existingRecordUnchanged,
      );

      expect(content.title, 'この動画は使用できません');
      expect(content.message, contains('可能性があります'));
      expect(content.message, contains('登録済みの動画と工程位置は変更していません'));
      expect(
        content.actions,
        isNot(contains(VideoImportRecoveryAction.openReferenceHelp)),
      );
    }
  });

  testWidgets('non-candidate dialog returns each explicit recovery action', (
    tester,
  ) async {
    final context = await _pumpHost(tester);

    var future = showNonCandidateVideoDialog(
      context: context,
      dataInvariantSuffix:
          VideoImportDataInvariantSuffix.existingRecordUnchanged,
    );
    await tester.pumpAndSettle();
    expect(find.text('別の動画を選ぶ'), findsOneWidget);
    expect(find.text('再登録できる動画の目安を見る'), findsOneWidget);
    expect(find.text('閉じる'), findsOneWidget);

    final semantics = tester.ensureSemantics();
    final alertAnnouncement = find.bySemanticsLabel(
      RegExp(
        r'^この拡張子のファイルは登録対象外です\n'
        r'原因と現在の状態: .*登録済みの動画と工程位置は変更していません。\n'
        r'次の操作: 別の動画を選ぶ、再登録できる動画の目安を見る、閉じる$',
        dotAll: true,
      ),
    );
    expect(alertAnnouncement, findsOneWidget);
    expect(
      tester.getSemantics(find.byType(Dialog)).role,
      SemanticsRole.alertDialog,
    );
    expect(
      tester
          .getSemantics(find.text('この拡張子のファイルは登録対象外です'))
          .flagsCollection
          .isHeader,
      isTrue,
    );
    expect(
      Focus.of(tester.element(find.text('この拡張子のファイルは登録対象外です'))).hasFocus,
      isTrue,
    );
    semantics.dispose();

    await tester.tap(find.text('再登録できる動画の目安を見る'));
    expect(await future, VideoImportRecoveryAction.openReferenceHelp);

    future = showNonCandidateVideoDialog(
      context: context,
      dataInvariantSuffix: VideoImportDataInvariantSuffix.createNotRegistered,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('別の動画を選ぶ'));
    expect(await future, VideoImportRecoveryAction.reselect);
  });

  testWidgets('Escape safely returns dismiss instead of a recovery action', (
    tester,
  ) async {
    final context = await _pumpHost(tester);
    final future = showNonCandidateVideoDialog(
      context: context,
      dataInvariantSuffix:
          VideoImportDataInvariantSuffix.existingRecordUnchanged,
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(await future, VideoImportRecoveryAction.dismiss);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('blocking error returns the domain recovery action', (
    tester,
  ) async {
    final context = await _pumpHost(tester);
    final future = showVideoImportExceptionDialog(
      context: context,
      error: _error(VideoImportErrorCode.videoReferenceConflict),
      dataInvariantSuffix:
          VideoImportDataInvariantSuffix.existingRecordUnchanged,
    );

    await tester.pumpAndSettle();
    expect(find.text('症例が更新されました'), findsOneWidget);
    await tester.tap(find.text('最新の状態を読み込む'));

    expect(await future, VideoImportRecoveryAction.reloadRecord);
  });

  testWidgets('none and inline presentations do not open a dialog', (
    tester,
  ) async {
    final context = await _pumpHost(tester);

    final canceled = await showVideoImportExceptionDialog(
      context: context,
      error: _error(
        VideoImportErrorCode.userCanceled,
        presentation: VideoImportPresentation.none,
      ),
    );
    final inline = await showVideoImportExceptionDialog(
      context: context,
      error: _error(
        VideoImportErrorCode.unknown,
        presentation: VideoImportPresentation.persistentInline,
      ),
    );

    expect(canceled, VideoImportRecoveryAction.dismiss);
    expect(inline, VideoImportRecoveryAction.dismiss);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('long non-candidate dialog fits a narrow high-text-scale view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(2),
          ),
          child: Builder(
            builder: (value) {
              context = value;
              return const Scaffold(body: SizedBox.expand());
            },
          ),
        ),
      ),
    );

    final future = showNonCandidateVideoDialog(
      context: context,
      dataInvariantSuffix: VideoImportDataInvariantSuffix.createNotRegistered,
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final scrollable = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);

    for (final label in <String>['別の動画を選ぶ', '再登録できる動画の目安を見る', '閉じる']) {
      final labelFinder = find.text(label);
      await tester.scrollUntilVisible(labelFinder, 120, scrollable: scrollable);
      await tester.pump();
      expect(labelFinder.hitTestable(), findsOneWidget);
      final button = find
          .ancestor(
            of: labelFinder,
            matching: find.byWidgetPredicate(
              (widget) => widget is FilledButton || widget is TextButton,
            ),
          )
          .first;
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    }

    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
    expect(await future, VideoImportRecoveryAction.dismiss);
  });
}

Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Builder(
        builder: (value) {
          context = value;
          return const Scaffold(body: SizedBox.expand());
        },
      ),
    ),
  );
  return context;
}

VideoImportException _error(
  VideoImportErrorCode code, {
  Set<VideoImportRecoveryAction> secondary =
      const <VideoImportRecoveryAction>{},
  VideoImportPresentation presentation = VideoImportPresentation.blockingDialog,
}) {
  final primary = switch (code) {
    VideoImportErrorCode.userCanceled => VideoImportRecoveryAction.dismiss,
    VideoImportErrorCode.nonCandidateExtension =>
      VideoImportRecoveryAction.reselect,
    VideoImportErrorCode.sourceNotFound ||
    VideoImportErrorCode.sourceAccessDenied ||
    VideoImportErrorCode.providerUnavailable ||
    VideoImportErrorCode.protectedMedia ||
    VideoImportErrorCode.unplayableMedia ||
    VideoImportErrorCode.sourceChanged ||
    VideoImportErrorCode.sourceReadFailed ||
    VideoImportErrorCode.copyIntegrityFailed =>
      VideoImportRecoveryAction.checkSourceAndReselect,
    VideoImportErrorCode.protectedDataUnavailable =>
      VideoImportRecoveryAction.unlockAndRetry,
    VideoImportErrorCode.playbackVerificationTimedOut ||
    VideoImportErrorCode.destinationWriteFailed ||
    VideoImportErrorCode.fileProtectionFailed ||
    VideoImportErrorCode.backupExclusionFailed ||
    VideoImportErrorCode.destinationPlaybackFailed ||
    VideoImportErrorCode.commitFailed ||
    VideoImportErrorCode.unknown => VideoImportRecoveryAction.retry,
    VideoImportErrorCode.insufficientStorage =>
      VideoImportRecoveryAction.freeStorageAndRetry,
    VideoImportErrorCode.durationConflict =>
      VideoImportRecoveryAction.resetTimingsAndAttach,
    VideoImportErrorCode.videoReferenceConflict =>
      VideoImportRecoveryAction.reloadRecord,
  };
  final reason = switch (code) {
    VideoImportErrorCode.userCanceled =>
      VideoImportInternalReasonV1.userCanceled,
    VideoImportErrorCode.nonCandidateExtension =>
      VideoImportInternalReasonV1.guidanceOnlyExtension,
    VideoImportErrorCode.sourceNotFound =>
      VideoImportInternalReasonV1.sourceMissing,
    VideoImportErrorCode.sourceAccessDenied =>
      VideoImportInternalReasonV1.sourcePermissionDenied,
    VideoImportErrorCode.providerUnavailable =>
      VideoImportInternalReasonV1.providerUnavailable,
    VideoImportErrorCode.protectedDataUnavailable =>
      VideoImportInternalReasonV1.protectedDataUnavailable,
    VideoImportErrorCode.protectedMedia =>
      VideoImportInternalReasonV1.drmSignaled,
    VideoImportErrorCode.unplayableMedia =>
      VideoImportInternalReasonV1.playerInitFailed,
    VideoImportErrorCode.playbackVerificationTimedOut =>
      VideoImportInternalReasonV1.stageTimeout,
    VideoImportErrorCode.sourceChanged =>
      VideoImportInternalReasonV1.sourceIdentityChanged,
    VideoImportErrorCode.insufficientStorage =>
      VideoImportInternalReasonV1.errnoEnospc,
    VideoImportErrorCode.sourceReadFailed =>
      VideoImportInternalReasonV1.sourceReadIo,
    VideoImportErrorCode.destinationWriteFailed =>
      VideoImportInternalReasonV1.destinationWriteIo,
    VideoImportErrorCode.copyIntegrityFailed =>
      VideoImportInternalReasonV1.destinationHashMismatch,
    VideoImportErrorCode.fileProtectionFailed =>
      VideoImportInternalReasonV1.protectionAttributeMismatch,
    VideoImportErrorCode.backupExclusionFailed =>
      VideoImportInternalReasonV1.backupAttributeMismatch,
    VideoImportErrorCode.destinationPlaybackFailed =>
      VideoImportInternalReasonV1.destinationPlayerFailed,
    VideoImportErrorCode.durationConflict =>
      VideoImportInternalReasonV1.durationBelowRecordedTiming,
    VideoImportErrorCode.videoReferenceConflict =>
      VideoImportInternalReasonV1.referenceCasMismatch,
    VideoImportErrorCode.commitFailed =>
      VideoImportInternalReasonV1.dbTransactionFailed,
    VideoImportErrorCode.unknown => VideoImportInternalReasonV1.unexpected,
  };
  return VideoImportException(
    code: code,
    phase: VideoImportPhase.sourcePlayback,
    internalReason: reason,
    primaryRecoveryAction: primary,
    secondaryRecoveryActions: secondary,
    presentation: presentation,
  );
}
