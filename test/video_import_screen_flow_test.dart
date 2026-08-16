import 'dart:async';

import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/features/video_import/video_import_screen_flow.dart';
import 'package:cataract_surgery_note/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'error dialog publishes its notice after close and restores the origin',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const _FocusRestorationHost(removeOriginOnFailure: false),
        ),
      );

      await tester.tap(find.text('動画取込を開始'));
      await tester.pumpAndSettle();

      expect(find.text('症例に動画を登録できませんでした'), findsOneWidget);
      expect(find.text('別の動画を選ぶ'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('別の動画を選ぶ'), findsOneWidget);
      expect(Focus.of(tester.element(find.text('動画取込を開始'))).hasFocus, isTrue);
    },
  );

  testWidgets(
    'error dialog falls back to the persistent reselect action when origin is gone',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const _FocusRestorationHost(removeOriginOnFailure: true),
        ),
      );

      await tester.tap(find.text('動画取込を開始'));
      await tester.pumpAndSettle();
      expect(find.text('別の動画を選ぶ'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('動画取込を開始'), findsNothing);
      final reselectLabel = find.text('別の動画を選ぶ');
      expect(reselectLabel, findsOneWidget);
      expect(
        Focus.of(tester.element(reselectLabel)).hasFocus,
        isTrue,
        reason: FocusManager.instance.primaryFocus?.toStringDeep(),
      );
    },
  );

  testWidgets(
    'VideoImportFailure keeps domain error and maintenance outcome separate',
    (tester) async {
      final context = await _pumpHost(tester);
      VideoImportException? persistentError;
      const domainError = VideoImportException(
        code: VideoImportErrorCode.commitFailed,
        phase: VideoImportPhase.databaseCommit,
        internalReason: VideoImportInternalReasonV1.dbTransactionFailed,
        primaryRecoveryAction: VideoImportRecoveryAction.retry,
      );

      final future = runVideoImportOperationForScreen<void>(
        context: context,
        entryPoint: VideoImportEntryPoint.attach,
        dataInvariantSuffix:
            VideoImportDataInvariantSuffix.existingRecordUnchanged,
        onPersistentFailure: (error) => persistentError = error,
        operation: (_, _) async {
          throw const VideoImportFailure(
            error: domainError,
            maintenanceOutcome: VideoMaintenanceOutcome.pending,
          );
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('症例に動画を登録できませんでした'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      final result = await future;
      expect(result, isA<VideoImportScreenOperationFailure<void>>());
      final failure = result as VideoImportScreenOperationFailure<void>;
      expect(failure.error, isA<VideoImportException>());
      expect(failure.error.code, VideoImportErrorCode.commitFailed);
      expect(
        failure.error.internalReason,
        VideoImportInternalReasonV1.dbTransactionFailed,
      );
      expect(failure.error.entryPoint, VideoImportEntryPoint.attach);
      expect(
        failure.error.dataInvariantSuffix,
        VideoImportDataInvariantSuffix.existingRecordUnchanged,
      );
      expect(failure.recoveryAction, VideoImportRecoveryAction.dismiss);
      expect(failure.maintenanceOutcome, VideoMaintenanceOutcome.pending);
      expect(persistentError, same(failure.error));
    },
  );

  group('VideoImportOperationController', () {
    test('begin cancels the superseded token and stale end is harmless', () {
      final controller = VideoImportOperationController();
      final first = controller.begin();
      final second = controller.begin();

      expect(first.isCancelled, isTrue);
      expect(second.isCancelled, isFalse);

      controller.end(first);
      controller.cancelActive();
      expect(second.isCancelled, isTrue);
    });

    test('end clears only the matching active token', () {
      final controller = VideoImportOperationController();
      final token = controller.begin();

      controller.end(token);
      controller.cancelActive();

      expect(token.isCancelled, isFalse);
    });

    test('cancelActive is idempotent and completes cancellation', () async {
      final controller = VideoImportOperationController();
      final token = controller.begin();

      controller.cancelActive();
      controller.cancelActive();

      await expectLater(token.whenCancelled, completes);
      expect(token.isCancelled, isTrue);
    });

    test(
      'dispose cancels active work and prevents token resurrection',
      () async {
        final controller = VideoImportOperationController();
        final active = controller.begin();

        controller.dispose();
        controller.dispose();

        await expectLater(active.whenCancelled, completes);
        expect(active.isCancelled, isTrue);
        final afterDispose = controller.begin();
        expect(afterDispose.isCancelled, isTrue);
        await expectLater(afterDispose.whenCancelled, completes);
      },
    );
  });

  testWidgets('logical success remains success after a late cancel request', (
    tester,
  ) async {
    final context = await _pumpHost(tester);
    final finishOperation = Completer<void>();
    VideoImportCancellationToken? token;

    final future = runVideoImportOperationForScreen<String>(
      context: context,
      entryPoint: VideoImportEntryPoint.create,
      dataInvariantSuffix: VideoImportDataInvariantSuffix.createNotRegistered,
      operation: (cancellationToken, onProgress) async {
        token = cancellationToken;
        onProgress(
          const VideoImportProgress(phase: VideoImportPhase.sourceHash),
        );
        await finishOperation.future;
        return 'committed';
      },
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('キャンセル'));
    await tester.pump();
    expect(token?.isCancelled, isTrue);

    finishOperation.complete();
    final result = await future;
    await tester.pump();

    expect(result, isA<VideoImportScreenOperationSuccess<String>>());
    expect(
      (result as VideoImportScreenOperationSuccess<String>).value,
      'committed',
    );
  });

  testWidgets('database commit phase keeps cancellation reachable', (
    tester,
  ) async {
    final context = await _pumpHost(tester);
    final enterCommit = Completer<void>();
    final finishCommit = Completer<void>();

    final future = runVideoImportOperationForScreen<int>(
      context: context,
      entryPoint: VideoImportEntryPoint.create,
      dataInvariantSuffix: VideoImportDataInvariantSuffix.createNotRegistered,
      operation: (cancellationToken, onProgress) async {
        onProgress(const VideoImportProgress(phase: VideoImportPhase.copy));
        await enterCommit.future;
        onProgress(
          const VideoImportProgress(phase: VideoImportPhase.databaseCommit),
        );
        await finishCommit.future;
        return 42;
      },
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('キャンセル'), findsOneWidget);

    enterCommit.complete();
    await tester.pump();
    expect(find.text('症例へ登録しています…'), findsOneWidget);
    expect(find.text('キャンセル'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pump();

    finishCommit.complete();
    final result = await future;
    await tester.pump();
    expect((result as VideoImportScreenOperationSuccess<int>).value, 42);
  });

  testWidgets(
    'typed user cancellation closes loading without an error dialog',
    (tester) async {
      final context = await _pumpHost(tester);

      final future = runVideoImportOperationForScreen<void>(
        context: context,
        entryPoint: VideoImportEntryPoint.create,
        dataInvariantSuffix: VideoImportDataInvariantSuffix.createNotRegistered,
        operation: (cancellationToken, onProgress) async {
          onProgress(
            const VideoImportProgress(phase: VideoImportPhase.sourcePlayback),
          );
          await cancellationToken.whenCancelled;
          cancellationToken.throwIfCancelled(VideoImportPhase.sourcePlayback);
        },
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('キャンセル'));
      final result = await future;
      await tester.pump();

      expect(result, isA<VideoImportScreenOperationCancelled<void>>());
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}

class _FocusRestorationHost extends StatefulWidget {
  const _FocusRestorationHost({required this.removeOriginOnFailure});

  final bool removeOriginOnFailure;

  @override
  State<_FocusRestorationHost> createState() => _FocusRestorationHostState();
}

class _FocusRestorationHostState extends State<_FocusRestorationHost> {
  final FocusNode _originFocus = FocusNode(debugLabel: 'video-import-origin');
  VideoImportException? _persistentError;
  bool _showOrigin = true;
  bool _operationActive = false;

  @override
  void dispose() {
    _originFocus.dispose();
    super.dispose();
  }

  Future<void> _startImport() async {
    if (_operationActive) {
      return;
    }
    _operationActive = true;
    _originFocus.requestFocus();
    try {
      await runVideoImportOperationForScreen<void>(
        context: context,
        entryPoint: VideoImportEntryPoint.attach,
        dataInvariantSuffix:
            VideoImportDataInvariantSuffix.existingRecordUnchanged,
        onPersistentFailure: (error) {
          if (!mounted) {
            return;
          }
          setState(() {
            _persistentError = error;
            if (widget.removeOriginOnFailure) {
              _showOrigin = false;
            }
          });
        },
        operation: (_, _) async {
          throw const VideoImportException(
            code: VideoImportErrorCode.commitFailed,
            phase: VideoImportPhase.databaseCommit,
            internalReason: VideoImportInternalReasonV1.dbTransactionFailed,
            primaryRecoveryAction: VideoImportRecoveryAction.retry,
          );
        },
      );
    } finally {
      _operationActive = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: <Widget>[
          if (_showOrigin)
            FilledButton(
              focusNode: _originFocus,
              onPressed: () => unawaited(_startImport()),
              child: const Text('動画取込を開始'),
            ),
          if (_persistentError case final error?)
            VideoImportPersistentErrorNotice(error: error, onReselect: () {}),
        ],
      ),
    );
  }
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
