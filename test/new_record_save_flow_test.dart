import 'dart:io';

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/record_video_service.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/surgery_video_picker.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/features/records/new_record_screen.dart';
import 'package:cataract_surgery_note/src/features/records/record_detail_screen.dart';
import 'package:cataract_surgery_note/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/video_import_test_support.dart';

void main() {
  late AppDatabase database;
  late SurgeryRepository repository;
  late Directory tempDirectory;

  setUp(() async {
    database = AppDatabase.memory();
    repository = SurgeryRepository(database);
    tempDirectory = await Directory.systemTemp.createTemp(
      'new_record_save_flow_',
    );
  });

  tearDown(() async {
    await database.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  testWidgets(
    'save passes the verified candidate and navigates with outcome.value',
    (tester) async {
      final candidate = (await tester.runAsync(
        () => _candidate(tempDirectory),
      ))!;
      final service = _CapturingCreateService(repository);
      await _pumpScreen(
        tester,
        candidate: candidate,
        service: service,
        database: database,
      );
      await _enterRequiredFieldsAndSave(tester);
      await tester.pump(const Duration(seconds: 1));

      expect(service.receivedCandidate, same(candidate));
      expect(find.byType(RecordDetailScreen), findsOneWidget);
      expect(
        (await repository.watchableListSnapshot()).single.id,
        'created-from-outcome',
      );
    },
  );

  testWidgets('copy cancellation preserves candidate and entered fields', (
    tester,
  ) async {
    final candidate = (await tester.runAsync(() => _candidate(tempDirectory)))!;
    final service = _CapturingCreateService(
      repository,
      waitForCancellation: true,
    );
    await _pumpScreen(
      tester,
      candidate: candidate,
      service: service,
      database: database,
    );

    await _enterRequiredFieldsAndSave(tester, settleAfterSave: false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('動画を保存しています…'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();

    expect(find.byType(NewRecordScreen), findsOneWidget);
    expect(find.text('surgery.mp4'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(_selectedEye(tester), <EyeSide>{EyeSide.right});
    expect(find.text('未選択'), findsNothing);
    expect(await repository.watchableListSnapshot(), isEmpty);
  });

  testWidgets(
    'dialog retry action reruns admission without losing form state',
    (tester) async {
      final candidate = (await tester.runAsync(
        () => _candidate(tempDirectory),
      ))!;
      final service = _CapturingCreateService(
        repository,
        failFirstAttempt: true,
      );
      await _pumpScreen(
        tester,
        candidate: candidate,
        service: service,
        database: database,
      );

      await _enterRequiredFieldsAndSave(tester, settleAfterSave: false);
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('症例に動画を登録できませんでした'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('もう一度試す'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(service.callCount, 2);
      expect(find.byType(RecordDetailScreen), findsOneWidget);
    },
  );

  testWidgets(
    'dismissed failure remains visible with reselect and offline help actions',
    (tester) async {
      final candidate = (await tester.runAsync(
        () => _candidate(tempDirectory),
      ))!;
      final service = _CapturingCreateService(
        repository,
        failFirstAttempt: true,
      );
      await _pumpScreen(
        tester,
        candidate: candidate,
        service: service,
        database: database,
      );

      await _enterRequiredFieldsAndSave(tester, settleAfterSave: false);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.text('閉じる'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('症例に動画を登録できませんでした'), findsOneWidget);
      expect(find.text('別の動画を選ぶ'), findsOneWidget);
      expect(find.text('登録できる動画の目安'), findsWidgets);
      expect(find.text('surgery.mp4'), findsOneWidget);
      expect(service.callCount, 1);
    },
  );

  testWidgets(
    'logical success keeps maintenance pending as a secondary warning',
    (tester) async {
      final candidate = (await tester.runAsync(
        () => _candidate(tempDirectory),
      ))!;
      final service = _CapturingCreateService(
        repository,
        maintenanceOutcome: VideoMaintenanceOutcome.pending,
      );
      await _pumpScreen(
        tester,
        candidate: candidate,
        service: service,
        database: database,
      );

      await _enterRequiredFieldsAndSave(tester);

      expect(find.byType(RecordDetailScreen), findsOneWidget);
      expect(find.text('症例の登録は完了しました。動画の後処理は次回起動時に再試行します。'), findsOneWidget);
    },
  );
}

Future<VerifiedVideoCandidate> _candidate(Directory directory) async {
  final file = File('${directory.path}/surgery.mp4');
  await file.writeAsBytes(List<int>.filled(64, 1));
  return verifiedVideoCandidateForFile(file);
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required VerifiedVideoCandidate candidate,
  required RecordVideoService service,
  required AppDatabase database,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        surgeryVideoPickerProvider.overrideWithValue(
          const _CancelingVideoPicker(),
        ),
        videoImportPreflightProvider.overrideWithValue(
          const PassThroughVideoImportPreflight(),
        ),
        recordVideoServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: NewRecordScreen(
          initialVideo: candidate,
          enableVideoPreview: false,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _enterRequiredFieldsAndSave(
  WidgetTester tester, {
  bool settleAfterSave = true,
}) async {
  await tester.drag(find.byType(ListView), const Offset(0, -500));
  await tester.pumpAndSettle();
  await tester.tap(find.text('手術日（必須）'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('右眼'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('register-record-button')));
  if (settleAfterSave) {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  } else {
    await tester.pump();
  }
}

Set<EyeSide> _selectedEye(WidgetTester tester) {
  return tester
      .widget<SegmentedButton<EyeSide>>(
        find.byWidgetPredicate((widget) => widget is SegmentedButton<EyeSide>),
      )
      .selected;
}

class _CapturingCreateService extends RecordVideoService {
  _CapturingCreateService(
    this.repository, {
    this.waitForCancellation = false,
    this.failFirstAttempt = false,
    this.maintenanceOutcome = VideoMaintenanceOutcome.complete,
  }) : super(
         surgeryRepository: repository,
         videoStorageRepository: const _NoopVideoStorage(),
         videoImportPreflight: const PassThroughVideoImportPreflight(),
       );

  final SurgeryRepository repository;
  final bool waitForCancellation;
  final bool failFirstAttempt;
  final VideoMaintenanceOutcome maintenanceOutcome;
  VerifiedVideoCandidate? receivedCandidate;
  int callCount = 0;

  @override
  Future<VideoImportOutcome<SurgeryRecord>> createRecordWithVideo({
    required DateTime surgeryDate,
    required EyeSide eyeSide,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    callCount++;
    receivedCandidate = candidate;
    if (waitForCancellation) {
      onProgress?.call(const VideoImportProgress(phase: VideoImportPhase.copy));
      await cancellationToken!.whenCancelled;
      cancellationToken.throwIfCancelled(VideoImportPhase.copy);
    }
    if (failFirstAttempt && callCount == 1) {
      throw const VideoImportException(
        code: VideoImportErrorCode.commitFailed,
        entryPoint: VideoImportEntryPoint.create,
        phase: VideoImportPhase.databaseCommit,
        internalReason: VideoImportInternalReasonV1.dbTransactionFailed,
        primaryRecoveryAction: VideoImportRecoveryAction.retry,
        dataInvariantSuffix: VideoImportDataInvariantSuffix.createNotRegistered,
      );
    }
    onProgress?.call(
      const VideoImportProgress(phase: VideoImportPhase.databaseCommit),
    );
    final record = await repository.createRecordWithVideoReference(
      surgeryRecordId: 'created-from-outcome',
      surgeryDate: surgeryDate,
      eyeSide: eyeSide,
      videoPath: 'videos/created-from-outcome/video.mp4',
      videoDisplayName: candidate.displayName,
    );
    return VideoImportOutcome<SurgeryRecord>(
      value: record,
      maintenanceOutcome: maintenanceOutcome,
    );
  }
}

class _CancelingVideoPicker implements SurgeryVideoPicker {
  const _CancelingVideoPicker();

  @override
  Future<SelectedSurgeryVideo?> pickVideo() async => null;
}

class _NoopVideoStorage implements VideoStorageRepository {
  const _NoopVideoStorage();

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<File?> resolveVideo(String relativePath) async => null;

  @override
  Future<void> deleteVideo(String relativePath) async {}

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) async {}
}
