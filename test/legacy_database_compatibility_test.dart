import 'dart:io';

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/file_sha256.dart';
import 'package:cataract_surgery_note/src/data/record_video_service.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/legacy_database_fixtures.dart';
import 'support/video_import_test_support.dart';

class _RecordingBackupExclusion implements BackupExclusionRepository {
  _RecordingBackupExclusion({this.failPathSuffixOnce});

  final String? failPathSuffixOnce;
  final List<String> verifiedPaths = <String>[];
  var _hasFailed = false;

  @override
  Future<void> excludeFromBackup(String path) async {
    if (!_hasFailed &&
        failPathSuffixOnce != null &&
        path.endsWith(failPathSuffixOnce!)) {
      _hasFailed = true;
      throw const FileSystemException('除外属性のread-back失敗');
    }
    verifiedPaths.add(path);
  }
}

class _NoopPlaybackVerifier implements VideoPlaybackVerifier {
  const _NoopPlaybackVerifier();

  @override
  Future<VideoPlaybackEvidence> verify(
    File file, {
    VideoImportCancellationToken? cancellationToken,
  }) async {
    return testVideoPlaybackEvidence;
  }
}

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'legacy_database_fixture_',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('1.0.0+1相当のfile-backed DBを値を変えず開き不足列だけ補完する', () async {
    final fixture = File(p.join(temporaryDirectory.path, 'build-1.sqlite'));
    await createBuild1Fixture(fixture);
    expect(await fixture.length(), greaterThan(0));

    var database = openFixtureWithCurrentCompatibility(fixture);
    var repository = SurgeryRepository(database);
    expect(await _integrityCheck(database), 'ok');
    final records = await repository.watchableListSnapshot();
    expect(records, hasLength(2));
    final right = records.singleWhere(
      (record) => record.id == build1RightRecordId,
    );
    final left = records.singleWhere(
      (record) => record.id == build1LeftRecordId,
    );
    expect(right.eyeSide, EyeSide.right);
    expect(right.reviewStatus, ReviewStatus.reviewed);
    expect(right.reviewSchemaVersion, isNull);
    expect(right.videoPath, isNull);
    expect(right.caseMemo, isEmpty);
    expect(left.eyeSide, EyeSide.left);
    expect(left.reviewStatus, ReviewStatus.draft);
    expect(left.reviewSchemaVersion, isNull);

    final columns = await database
        .customSelect('PRAGMA table_info(surgery_records)')
        .get();
    expect(
      columns.map((row) => row.data['name']),
      containsAll(<String>[
        'video_path',
        'video_display_name',
        'case_memo',
        'review_schema_version',
        'surgery_day',
      ]),
    );
    final migratedDays = await database.customSelect('''
SELECT id, surgery_date, surgery_day
FROM surgery_records
ORDER BY id
''').get();
    for (final row in migratedDays) {
      final legacyDisplayDate = DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('surgery_date'),
        isUtc: true,
      ).toLocal();
      expect(
        row.read<int>('surgery_day'),
        SurgeryDayCodec.encode(legacyDisplayDate),
      );
    }
    final reviewColumns = await database
        .customSelect('PRAGMA table_info(surgical_step_reviews)')
        .get();
    expect(
      reviewColumns.map((row) => row.data['name']),
      contains('is_skipped'),
    );
    final rowsBeforeReviewEntry = await _tableSnapshot(
      database,
      'surgical_step_reviews',
    );
    expect(rowsBeforeReviewEntry, hasLength(3));
    expect(
      rowsBeforeReviewEntry.every((row) => row['is_skipped'] == 0),
      isTrue,
    );
    expect(
      rowsBeforeReviewEntry.singleWhere(
        (row) => row['id'] == 'build1-ccc-complete',
      ),
      containsPair('reflection', '円形を保てた。'),
    );

    final completed = await repository.ensureStepReviews(build1RightRecordId);
    expect(completed, hasLength(11));
    final preservedCcc = completed.singleWhere(
      (review) => review.step == SurgicalStep.capsulorhexis,
    );
    expect(preservedCcc.id, 'build1-ccc-complete');
    expect(preservedCcc.startMilliseconds, 1000);
    expect(preservedCcc.endMilliseconds, 5500);
    expect(preservedCcc.isSkipped, isFalse);
    expect(preservedCcc.rating, StepRating.good);
    expect(preservedCcc.reflection, '円形を保てた。');
    final legacyRows = await database
        .customSelect(
          '''
SELECT * FROM surgical_step_reviews
WHERE surgery_record_id = ? AND step = ?
''',
          variables: <Variable<Object>>[
            const Variable<String>(build1RightRecordId),
            Variable<String>(SurgicalStep.subTenonAnesthesia.storageId),
          ],
        )
        .get();
    expect(legacyRows.single.data['id'], 'build1-legacy-complete');
    expect(
      (await repository.getRecord(build1RightRecordId))!.reviewSchemaVersion,
      isNull,
      reason: '工程行の補完だけで旧症例を移行しない',
    );

    await repository.close();
    database = openFixtureWithCurrentCompatibility(fixture);
    repository = SurgeryRepository(database);
    expect(await _integrityCheck(database), 'ok');
    final concurrentCompletion =
        await Future.wait(<Future<List<SurgicalStepReview>>>[
          repository.ensureStepReviews(build1RightRecordId),
          repository.ensureStepReviews(build1RightRecordId),
        ]);
    expect(concurrentCompletion[0], hasLength(11));
    expect(concurrentCompletion[1], hasLength(11));
    expect(
      concurrentCompletion[0].map((review) => review.id).toSet(),
      concurrentCompletion[1].map((review) => review.id).toSet(),
    );
    expect(
      await _countRows(database, 'surgical_step_reviews', build1RightRecordId),
      12,
      reason: '11表示項目＋保持した旧工程',
    );
    expect(
      (await repository.getRecord(build1RightRecordId))!.reviewSchemaVersion,
      isNull,
    );
    expect(
      (await repository.getStepReview(
        surgeryRecordId: build1RightRecordId,
        step: SurgicalStep.capsulorhexis,
      ))!.isSkipped,
      isFalse,
    );
    await repository.close();
  });

  test('legacy手術日のbackfillは非NULLのcivil値を再openで上書きしない', () async {
    final fixture = File(p.join(temporaryDirectory.path, 'civil-day.sqlite'));
    await createBuild1Fixture(fixture);

    var database = openFixtureWithCurrentCompatibility(fixture);
    await database.customSelect('SELECT 1').getSingle();
    final initiallyMigrated = await database
        .customSelect(
          'SELECT surgery_day FROM surgery_records WHERE id = ?',
          variables: const [Variable<String>(build1RightRecordId)],
        )
        .getSingle();
    expect(initiallyMigrated.read<int?>('surgery_day'), isNotNull);
    await database.customStatement(
      'UPDATE surgery_records SET surgery_day = ? WHERE id = ?',
      [19991231, build1RightRecordId],
    );
    await database.close();

    database = openFixtureWithCurrentCompatibility(fixture);
    final repository = SurgeryRepository(database);
    final reopened = await repository.getRecord(build1RightRecordId);
    expect(reopened!.surgeryDate, DateTime(1999, 12, 31));
    expect(
      (await database
              .customSelect(
                'SELECT surgery_day FROM surgery_records WHERE id = ?',
                variables: const [Variable<String>(build1RightRecordId)],
              )
              .getSingle())
          .read<int>('surgery_day'),
      19991231,
    );
    await repository.close();
  });

  test('1.0.0+14相当fixtureの全値と動画SHA-256を読取り前後で保持する', () async {
    final fixture = File(p.join(temporaryDirectory.path, 'build-14.sqlite'));
    final legacyVideo = File(p.join(temporaryDirectory.path, 'legacy.mov'));
    await legacyVideo.writeAsBytes(_videoBytes(11));
    await createBuild14Fixture(fixture, legacyVideoPath: legacyVideo.path);
    final support = Directory(p.join(temporaryDirectory.path, 'support'));
    final managedVideo = File(
      p.join(support.path, 'videos', build14ManagedRecordId, 'managed.mp4'),
    );
    await managedVideo.parent.create(recursive: true);
    await managedVideo.writeAsBytes(_videoBytes(29));
    final managedHashBefore = await sha256OfFile(managedVideo);

    final database = openFixtureWithCurrentCompatibility(fixture);
    final repository = SurgeryRepository(database);
    expect(await _integrityCheck(database), 'ok');
    final recordsBefore = await _tableSnapshot(database, 'surgery_records');
    final reviewsBefore = await _tableSnapshot(
      database,
      'surgical_step_reviews',
    );
    expect(recordsBefore, hasLength(3));
    expect(reviewsBefore, hasLength(16));

    final list = await repository.watchableListSnapshot();
    final progress = await repository.fetchRecordProgressSnapshots();
    final analysis = await repository.fetchAnalysisSnapshot();
    expect(list, hasLength(3));
    expect(
      list
          .singleWhere((record) => record.id == build14LegacyRecordId)
          .videoPath,
      legacyVideo.path,
    );
    final managedProgress = progress.singleWhere(
      (item) => item.record.id == build14ManagedRecordId,
    );
    expect(managedProgress.completedStepCount, 2);
    expect(managedProgress.hasRunningStep, isTrue);
    expect(managedProgress.totalSurgeryDuration, const Duration(minutes: 2));
    expect(
      analysis.measurements.any(
        (measurement) =>
            measurement.step == SurgicalStep.subTenonAnesthesia ||
            measurement.step == SurgicalStep.dexartSubconjunctivalInjection,
      ),
      isFalse,
    );
    expect(
      reviewsBefore.any((row) => row['step'] == 'future_unknown_step'),
      isTrue,
    );

    final storage = LocalVideoStorageRepository(
      applicationSupportDirectory: support,
      backupExclusionRepository: _RecordingBackupExclusion(),
      playbackVerifier: const _NoopPlaybackVerifier(),
    );
    final service = RecordVideoService(
      surgeryRepository: repository,
      videoStorageRepository: storage,
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );
    final states = <String, RecordVideoState>{};
    for (final record in list) {
      states[record.id] = await service.inspectVideoState(record);
    }
    expect(
      states[build14ManagedRecordId]!.kind,
      RecordVideoStateKind.availableManaged,
    );
    expect(
      states[build14LegacyRecordId]!.kind,
      RecordVideoStateKind.availableLegacy,
    );
    expect(states[build14MissingRecordId]!.kind, RecordVideoStateKind.missing);

    expect(await _tableSnapshot(database, 'surgery_records'), recordsBefore);
    expect(
      await _tableSnapshot(database, 'surgical_step_reviews'),
      reviewsBefore,
    );
    expect(await sha256OfFile(managedVideo), managedHashBefore);
    expect(
      await managedVideo.parent.list().where((entity) => entity is File).length,
      1,
      reason: '一覧/状態確認は動画をcopyしない',
    );
    await repository.close();
  });

  test('旧fixtureは参照・補完・評価で移行せず明示的な時刻/skipでversion 1を保持する', () async {
    final fixture = File(
      p.join(temporaryDirectory.path, 'review-version.sqlite'),
    );
    await createBuild14Fixture(fixture);

    var database = openFixtureWithCurrentCompatibility(fixture);
    var repository = SurgeryRepository(database);
    expect(await _integrityCheck(database), 'ok');

    final recordColumns = await database
        .customSelect('PRAGMA table_info(surgery_records)')
        .get();
    final reviewColumns = await database
        .customSelect('PRAGMA table_info(surgical_step_reviews)')
        .get();
    expect(
      recordColumns.map((row) => row.data['name']),
      contains('review_schema_version'),
    );
    expect(
      reviewColumns.map((row) => row.data['name']),
      contains('is_skipped'),
    );

    final recordsBefore = await _tableSnapshot(database, 'surgery_records');
    final reviewsBefore = await _tableSnapshot(
      database,
      'surgical_step_reviews',
    );
    expect(
      recordsBefore.every((row) => row['review_schema_version'] == null),
      isTrue,
      reason: '旧症例はスキーマ補完だけでversion 1にしない',
    );
    expect(
      reviewsBefore.every((row) => row['is_skipped'] == 0),
      isTrue,
      reason: '旧行の追加列は非skipとして読む',
    );

    final records = await repository.watchableListSnapshot();
    final progress = await repository.fetchRecordProgressSnapshots();
    final analysis = await repository.fetchAnalysisSnapshot();
    expect(records, hasLength(3));
    expect(
      records.every((record) => record.reviewSchemaVersion == null),
      isTrue,
    );
    expect(
      progress.every(
        (snapshot) =>
            snapshot.record.reviewSchemaVersion == null &&
            snapshot.timingReviewStatus == null,
      ),
      isTrue,
    );
    expect(analysis.recordCount, 3);

    final ensured = await repository.ensureStepReviews(build14ManagedRecordId);
    expect(ensured, hasLength(11));
    expect(ensured.every((review) => review.isSkipped == false), isTrue);
    expect(
      await _tableSnapshot(database, 'surgery_records'),
      recordsBefore,
      reason: '読み取りと工程補完は旧症例の列を更新しない',
    );
    expect(
      await _tableSnapshot(database, 'surgical_step_reviews'),
      reviewsBefore,
      reason: '既に現行工程が揃うfixtureへのensureは既存値を変えない',
    );

    final managedCcc = ensured.singleWhere(
      (review) => review.step == SurgicalStep.capsulorhexis,
    );
    final contentResult = await repository.saveReviewContent(
      surgeryRecordId: build14ManagedRecordId,
      reviews: <SurgicalStepReview>[
        managedCcc.copyWith(
          rating: StepRating.needsImprovement,
          reflection: '評価と反省点だけ更新。',
        ),
      ],
      caseMemo: '症例メモだけ更新。',
    );
    expect(contentResult.record.reviewSchemaVersion, isNull);
    final managedAfterContent = (await repository.getRecord(
      build14ManagedRecordId,
    ))!;
    expect(managedAfterContent.reviewSchemaVersion, isNull);
    expect(managedAfterContent.caseMemo, '症例メモだけ更新。');
    final managedCccAfterContent = (await repository.getStepReview(
      surgeryRecordId: build14ManagedRecordId,
      step: SurgicalStep.capsulorhexis,
    ))!;
    expect(managedCccAfterContent.startMilliseconds, 3000);
    expect(managedCccAfterContent.endMilliseconds, 3600);
    expect(managedCccAfterContent.isSkipped, isFalse);
    expect(managedCccAfterContent.rating, StepRating.needsImprovement);
    expect(managedCccAfterContent.reflection, '評価と反省点だけ更新。');

    final legacyCcc = (await repository.getStepReview(
      surgeryRecordId: build14LegacyRecordId,
      step: SurgicalStep.capsulorhexis,
    ))!;
    final savedTiming = await repository.saveStepTiming(
      review: legacyCcc.copyWith(
        startMilliseconds: 3500,
        endMilliseconds: 7500,
      ),
      expectedVideoPath: build14LegacyVideoPath,
    );
    expect(savedTiming.startMilliseconds, 3500);
    expect(savedTiming.endMilliseconds, 7500);
    expect(savedTiming.isSkipped, isFalse);
    expect(savedTiming.rating, StepRating.fair);
    expect(savedTiming.reflection, '旧動画のCCC。');
    expect(
      (await repository.getRecord(build14LegacyRecordId))!.reviewSchemaVersion,
      1,
    );

    final missingCcc = (await repository.getStepReview(
      surgeryRecordId: build14MissingRecordId,
      step: SurgicalStep.capsulorhexis,
    ))!;
    final savedSkip = await repository.saveStepSkipped(
      review: missingCcc,
      isSkipped: true,
      expectedVideoPath: 'videos/$build14MissingRecordId/missing.mp4',
    );
    expect(savedSkip.startMilliseconds, isNull);
    expect(savedSkip.endMilliseconds, isNull);
    expect(savedSkip.isSkipped, isTrue);
    expect(savedSkip.rating, StepRating.good);
    expect(savedSkip.reflection, '動画がなくても読み込む。');
    expect(
      (await repository.getRecord(build14MissingRecordId))!.reviewSchemaVersion,
      1,
    );
    expect(
      (await repository.getRecord(build14ManagedRecordId))!.reviewSchemaVersion,
      isNull,
      reason: '評価・反省点・メモのみを更新した症例は非移行',
    );

    await repository.close();
    database = openFixtureWithCurrentCompatibility(fixture);
    repository = SurgeryRepository(database);
    expect(await _integrityCheck(database), 'ok');

    final reopenedRecords = await _tableSnapshot(database, 'surgery_records');
    final reopenedReviews = await _tableSnapshot(
      database,
      'surgical_step_reviews',
    );
    final managedRecordRowBefore = _rowWithId(
      recordsBefore,
      build14ManagedRecordId,
    );
    final legacyRecordRowBefore = _rowWithId(
      recordsBefore,
      build14LegacyRecordId,
    );
    final missingRecordRowBefore = _rowWithId(
      recordsBefore,
      build14MissingRecordId,
    );
    final managedRecordRowAfter = _rowWithId(
      reopenedRecords,
      build14ManagedRecordId,
    );
    final legacyRecordRowAfter = _rowWithId(
      reopenedRecords,
      build14LegacyRecordId,
    );
    final missingRecordRowAfter = _rowWithId(
      reopenedRecords,
      build14MissingRecordId,
    );
    expect(managedRecordRowAfter['review_schema_version'], isNull);
    expect(legacyRecordRowAfter['review_schema_version'], 1);
    expect(missingRecordRowAfter['review_schema_version'], 1);
    expect(
      _withoutKeys(managedRecordRowAfter, const <String>{
        'case_memo',
        'updated_at',
      }),
      _withoutKeys(managedRecordRowBefore, const <String>{
        'case_memo',
        'updated_at',
      }),
    );
    expect(
      _withoutKeys(legacyRecordRowAfter, const <String>{
        'review_status',
        'review_schema_version',
        'updated_at',
      }),
      _withoutKeys(legacyRecordRowBefore, const <String>{
        'review_status',
        'review_schema_version',
        'updated_at',
      }),
    );
    expect(
      _withoutKeys(missingRecordRowAfter, const <String>{
        'review_schema_version',
        'updated_at',
      }),
      _withoutKeys(missingRecordRowBefore, const <String>{
        'review_schema_version',
        'updated_at',
      }),
    );

    final managedReviewRowBefore = _rowWithId(reviewsBefore, 'b14-display-2');
    final legacyReviewRowBefore = _rowWithId(
      reviewsBefore,
      'b14-legacy-record-ccc',
    );
    final missingReviewRowBefore = _rowWithId(
      reviewsBefore,
      'b14-missing-record-ccc',
    );
    final managedReviewRowAfter = _rowWithId(reopenedReviews, 'b14-display-2');
    final legacyReviewRowAfter = _rowWithId(
      reopenedReviews,
      'b14-legacy-record-ccc',
    );
    final missingReviewRowAfter = _rowWithId(
      reopenedReviews,
      'b14-missing-record-ccc',
    );
    expect(
      _withoutKeys(managedReviewRowAfter, const <String>{
        'rating',
        'reflection',
        'updated_at',
      }),
      _withoutKeys(managedReviewRowBefore, const <String>{
        'rating',
        'reflection',
        'updated_at',
      }),
    );
    expect(legacyReviewRowAfter['start_milliseconds'], 3500);
    expect(legacyReviewRowAfter['end_milliseconds'], 7500);
    expect(legacyReviewRowAfter['is_skipped'], 0);
    expect(
      _withoutKeys(legacyReviewRowAfter, const <String>{
        'start_milliseconds',
        'end_milliseconds',
        'updated_at',
      }),
      _withoutKeys(legacyReviewRowBefore, const <String>{
        'start_milliseconds',
        'end_milliseconds',
        'updated_at',
      }),
    );
    expect(missingReviewRowAfter['start_milliseconds'], isNull);
    expect(missingReviewRowAfter['end_milliseconds'], isNull);
    expect(missingReviewRowAfter['is_skipped'], 1);
    expect(
      _withoutKeys(missingReviewRowAfter, const <String>{
        'start_milliseconds',
        'end_milliseconds',
        'is_skipped',
        'updated_at',
      }),
      _withoutKeys(missingReviewRowBefore, const <String>{
        'start_milliseconds',
        'end_milliseconds',
        'is_skipped',
        'updated_at',
      }),
    );
    expect(
      _rowWithId(reopenedReviews, 'b14-unknown'),
      _rowWithId(reviewsBefore, 'b14-unknown'),
      reason: '未知工程の既存値は一切変更しない',
    );

    final reopenedManaged = (await repository.getRecord(
      build14ManagedRecordId,
    ))!;
    final reopenedLegacy = (await repository.getStepReview(
      surgeryRecordId: build14LegacyRecordId,
      step: SurgicalStep.capsulorhexis,
    ))!;
    final reopenedMissing = (await repository.getStepReview(
      surgeryRecordId: build14MissingRecordId,
      step: SurgicalStep.capsulorhexis,
    ))!;
    expect(reopenedManaged.reviewSchemaVersion, isNull);
    expect(reopenedManaged.caseMemo, '症例メモだけ更新。');
    expect(reopenedLegacy.startMilliseconds, 3500);
    expect(reopenedLegacy.endMilliseconds, 7500);
    expect(reopenedLegacy.isSkipped, isFalse);
    expect(reopenedMissing.startMilliseconds, isNull);
    expect(reopenedMissing.endMilliseconds, isNull);
    expect(reopenedMissing.isSkipped, isTrue);
    await repository.close();
  });

  test('旧fixtureの既存管理動画へ除外属性を再設定し失敗後も非破壊で再試行できる', () async {
    final fixture = File(p.join(temporaryDirectory.path, 'build-14.sqlite'));
    await createBuild14Fixture(fixture);
    final support = Directory(p.join(temporaryDirectory.path, 'support'));
    final managedVideo = File(
      p.join(support.path, 'videos', build14ManagedRecordId, 'managed.mp4'),
    );
    await managedVideo.parent.create(recursive: true);
    await managedVideo.writeAsBytes(_videoBytes(47));
    final hashBefore = await sha256OfFile(managedVideo);
    final database = openFixtureWithCurrentCompatibility(fixture);
    final repository = SurgeryRepository(database);
    final rowsBefore = await _tableSnapshot(database, 'surgery_records');

    final failingBackup = _RecordingBackupExclusion(
      failPathSuffixOnce: '/managed.mp4',
    );
    final failingService = RecordVideoService(
      surgeryRepository: repository,
      videoStorageRepository: LocalVideoStorageRepository(
        applicationSupportDirectory: support,
        backupExclusionRepository: failingBackup,
        playbackVerifier: const _NoopPlaybackVerifier(),
      ),
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );
    final failedReport = await failingService.initialize();
    expect(failedReport!.backupExclusionVerified, isFalse);
    expect(
      failedReport.backupExclusionFailures,
      contains('videos/$build14ManagedRecordId/managed.mp4'),
    );
    expect(await managedVideo.exists(), isTrue);
    expect(await sha256OfFile(managedVideo), hashBefore);
    expect(await _tableSnapshot(database, 'surgery_records'), rowsBefore);

    final retryBackup = _RecordingBackupExclusion();
    final retryService = RecordVideoService(
      surgeryRepository: repository,
      videoStorageRepository: LocalVideoStorageRepository(
        applicationSupportDirectory: support,
        backupExclusionRepository: retryBackup,
        playbackVerifier: const _NoopPlaybackVerifier(),
      ),
      videoImportPreflight: const PassThroughVideoImportPreflight(),
    );
    final retryReport = await retryService.initialize();
    expect(
      retryReport!.backupExclusionFailures,
      contains('videos/$build14MissingRecordId/missing.mp4'),
      reason: '意図的な欠損fixtureは属性確認不能として残る',
    );
    expect(
      retryReport.backupExclusionFailures,
      isNot(contains('videos/$build14ManagedRecordId/managed.mp4')),
    );
    expect(retryBackup.verifiedPaths, contains(endsWith('/videos')));
    expect(retryBackup.verifiedPaths, contains(endsWith('/managed.mp4')));
    expect(
      retryBackup.verifiedPaths.any((path) => path == build14LegacyVideoPath),
      isFalse,
    );
    expect(await sha256OfFile(managedVideo), hashBefore);
    expect(await _tableSnapshot(database, 'surgery_records'), rowsBefore);
    await repository.close();
  });
}

Future<String> _integrityCheck(dynamic database) async {
  final row = await database.customSelect('PRAGMA integrity_check').getSingle();
  return row.data.values.single as String;
}

Future<List<Map<String, Object?>>> _tableSnapshot(
  dynamic database,
  String table,
) async {
  if (table != 'surgery_records' && table != 'surgical_step_reviews') {
    throw ArgumentError.value(table, 'table');
  }
  final List<QueryRow> rows = await database
      .customSelect('SELECT * FROM $table ORDER BY id')
      .get();
  return rows
      .map((row) => Map<String, Object?>.from(row.data))
      .toList(growable: false);
}

Future<int> _countRows(dynamic database, String table, String recordId) async {
  final row = await database
      .customSelect(
        'SELECT COUNT(*) AS count FROM $table WHERE surgery_record_id = ?',
        variables: <Variable<Object>>[Variable<String>(recordId)],
      )
      .getSingle();
  return row.data['count']! as int;
}

Map<String, Object?> _rowWithId(List<Map<String, Object?>> rows, String id) {
  return rows.singleWhere((row) => row['id'] == id);
}

Map<String, Object?> _withoutKeys(
  Map<String, Object?> row,
  Set<String> excludedKeys,
) {
  return Map<String, Object?>.fromEntries(
    row.entries.where((entry) => !excludedKeys.contains(entry.key)),
  );
}

List<int> _videoBytes(int salt) {
  return List<int>.generate(8192, (index) => (index * 31 + salt) % 256);
}
