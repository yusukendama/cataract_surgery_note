import 'dart:io';

import 'package:cataract_surgery_note/src/data/file_sha256.dart';
import 'package:cataract_surgery_note/src/data/record_video_service.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/legacy_database_fixtures.dart';

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
  Future<void> verify(File file) async {}
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
    expect(right.videoPath, isNull);
    expect(right.caseMemo, isEmpty);
    expect(left.eyeSide, EyeSide.left);
    expect(left.reviewStatus, ReviewStatus.draft);

    final columns = await database
        .customSelect('PRAGMA table_info(surgery_records)')
        .get();
    expect(
      columns.map((row) => row.data['name']),
      containsAll(<String>['video_path', 'video_display_name', 'case_memo']),
    );
    final rowsBeforeReviewEntry = await _tableSnapshot(
      database,
      'surgical_step_reviews',
    );
    expect(rowsBeforeReviewEntry, hasLength(3));
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

List<int> _videoBytes(int salt) {
  return List<int>.generate(8192, (index) => (index * 31 + salt) % 256);
}
