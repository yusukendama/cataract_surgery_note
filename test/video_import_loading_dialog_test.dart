import 'dart:async';

import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/features/video_import/video_import_loading_dialog.dart';
import 'package:cataract_surgery_note/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('loading does not flash before the 500ms threshold', (
    tester,
  ) async {
    final context = await _pumpHost(tester);
    final presenter = VideoImportLoadingPresenter(
      context: context,
      onCancel: () {},
    );

    presenter.updateProgress(
      const VideoImportProgress(phase: VideoImportPhase.sourceAccess),
    );
    await tester.pump(const Duration(milliseconds: 499));
    expect(find.byType(VideoImportLoadingDialog), findsNothing);

    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(VideoImportLoadingDialog), findsOneWidget);
    expect(find.text('動画を取得しています…'), findsOneWidget);

    presenter.finish();
    await tester.pump();
    expect(find.byType(VideoImportLoadingDialog), findsNothing);
  });

  testWidgets('finishing a fast operation cancels delayed presentation', (
    tester,
  ) async {
    final context = await _pumpHost(tester);
    final presenter = VideoImportLoadingPresenter(
      context: context,
      onCancel: () {},
    );

    presenter.updateProgress(
      const VideoImportProgress(phase: VideoImportPhase.selectionPolicy),
    );
    presenter.finish();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(VideoImportLoadingDialog), findsNothing);
    expect(presenter.isFinished, isTrue);
  });

  testWidgets('phase and real fraction update without a fake percentage', (
    tester,
  ) async {
    final context = await _pumpHost(tester);
    final presenter = VideoImportLoadingPresenter(
      context: context,
      onCancel: () {},
      delay: Duration.zero,
    );

    presenter.updateProgress(
      const VideoImportProgress(
        phase: VideoImportPhase.sourceHash,
        fraction: 0.42,
      ),
    );
    await tester.pump();
    expect(find.text('動画を確認しています…'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.42,
    );

    presenter.updateProgress(
      const VideoImportProgress(phase: VideoImportPhase.copy),
    );
    await tester.pump();
    expect(find.text('動画を保存しています…'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );

    presenter.finish();
  });

  testWidgets('cancel is emitted once and late progress is ignored', (
    tester,
  ) async {
    final context = await _pumpHost(tester);
    var cancelCount = 0;
    final presenter = VideoImportLoadingPresenter(
      context: context,
      onCancel: () => cancelCount++,
      delay: Duration.zero,
    );
    presenter.updateProgress(
      const VideoImportProgress(phase: VideoImportPhase.sourcePlayback),
    );
    await tester.pump();

    await tester.tap(find.text('キャンセル'));
    await tester.pump();
    expect(cancelCount, 1);
    expect(presenter.cancelRequested, isTrue);
    expect(find.text('キャンセルしています…'), findsOneWidget);
    expect(find.text('キャンセル'), findsNothing);

    presenter.updateProgress(
      const VideoImportProgress(phase: VideoImportPhase.databaseCommit),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(cancelCount, 1);
    expect(find.text('症例へ登録しています…'), findsNothing);

    presenter.finish();
  });

  testWidgets('caller can disable cancellation for an atomic phase', (
    tester,
  ) async {
    final context = await _pumpHost(tester);
    var cancelCount = 0;
    final presenter = VideoImportLoadingPresenter(
      context: context,
      onCancel: () => cancelCount++,
      delay: Duration.zero,
    );
    presenter.updateProgress(
      const VideoImportProgress(phase: VideoImportPhase.databaseCommit),
    );
    presenter.setCancellationEnabled(false);
    await tester.pump();

    expect(find.text('症例へ登録しています…'), findsOneWidget);
    expect(find.text('キャンセル'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(cancelCount, 0);

    presenter.setCancellationEnabled(true);
    await tester.pump();
    expect(find.text('キャンセル'), findsOneWidget);
    presenter.finish();
  });

  testWidgets('run helper always removes the overlay on failure', (
    tester,
  ) async {
    final context = await _pumpHost(tester);
    final operation = Completer<void>();
    late VideoImportProgressCallback reportProgress;

    final future = runWithVideoImportLoading<void>(
      context: context,
      delay: Duration.zero,
      onCancel: () {},
      operation: (callback) {
        reportProgress = callback;
        return operation.future;
      },
    );
    reportProgress(
      const VideoImportProgress(phase: VideoImportPhase.sourcePlayback),
    );
    await tester.pump();
    expect(find.byType(VideoImportLoadingDialog), findsOneWidget);

    operation.completeError(StateError('synthetic'));
    await expectLater(future, throwsStateError);
    await tester.pump();
    expect(find.byType(VideoImportLoadingDialog), findsNothing);
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
