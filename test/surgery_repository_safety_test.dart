import 'dart:async';
import 'dart:io';

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/record_mutation_coordinator.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late SurgeryRepository repository;

  setUp(() {
    database = AppDatabase.memory();
    repository = SurgeryRepository(database);
  });

  tearDown(() => repository.close());

  test('旧DBの不足工程補完は途中失敗時に全insertをrollbackする', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final originalCcc = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    await database.customStatement('''
CREATE TRIGGER fail_step_completion
BEFORE INSERT ON surgical_step_reviews
WHEN NEW.step = 'side_port_creation'
BEGIN SELECT RAISE(ABORT, 'injected insert failure'); END
''');

    await expectLater(
      repository.ensureStepReviews(record.id),
      throwsA(anything),
    );

    final afterFailure = await _stepRows(database, record.id);
    expect(afterFailure, hasLength(1));
    expect(afterFailure.single['id'], originalCcc!.id);
    expect(
      (await repository.getRecord(record.id))!.reviewStatus,
      ReviewStatus.draft,
    );

    await database.customStatement('DROP TRIGGER fail_step_completion');
    final completed = await repository.ensureStepReviews(record.id);
    final repeated = await repository.ensureStepReviews(record.id);
    expect(completed, hasLength(11));
    expect(
      repeated.map((review) => review.id),
      completed.map((review) => review.id),
    );
    expect(
      completed
          .singleWhere((review) => review.step == SurgicalStep.capsulorhexis)
          .id,
      originalCcc.id,
    );
  });

  test('時刻保存は評価と反省点を上書きしない', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.left,
    );
    final draft = await repository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    await repository.saveReviewContent(
      surgeryRecordId: record.id,
      reviews: <SurgicalStepReview>[
        draft.copyWith(rating: StepRating.good, reflection: '保持すべき反省点'),
      ],
      caseMemo: 'メモ',
    );

    final committed = await repository.saveStepTiming(
      review: draft.copyWith(startMilliseconds: 100, endMilliseconds: 900),
      expectedVideoPath: null,
    );

    expect(committed.startMilliseconds, 100);
    expect(committed.endMilliseconds, 900);
    expect(committed.rating, StepRating.good);
    expect(committed.reflection, '保持すべき反省点');
  });

  test('saveStepTimingはversion更新失敗時に時刻・skip・症例状態を全rollbackする', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final review = await repository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    final skipped = await repository.saveStepSkipped(
      review: review,
      isSkipped: true,
      expectedVideoPath: null,
    );
    await _setRecordReviewTracking(
      database,
      record.id,
      reviewStatus: ReviewStatus.draft,
      reviewSchemaVersion: null,
    );
    await database.customStatement('''
CREATE TRIGGER fail_timing_record_version_update
BEFORE UPDATE ON surgery_records
WHEN NEW.id = '${record.id}'
BEGIN SELECT RAISE(ABORT, 'injected version update failure'); END
''');

    await expectLater(
      repository.saveStepTiming(
        review: skipped.copyWith(startMilliseconds: 100, endMilliseconds: 900),
        expectedVideoPath: null,
      ),
      throwsA(anything),
    );

    final persisted = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: review.step,
    );
    final persistedRecord = await repository.getRecord(record.id);
    expect(persisted!.startMilliseconds, isNull);
    expect(persisted.endMilliseconds, isNull);
    expect(persisted.isSkipped, isTrue);
    expect(persisted.recordingStatus, StepRecordingStatus.skipped);
    expect(persistedRecord!.reviewSchemaVersion, isNull);
    expect(persistedRecord.reviewStatus, ReviewStatus.draft);
  });

  test('saveStepSkippedは時刻消去とskip・旧症例移行を同時commitする', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final review = await repository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    final timed = await repository.saveStepTiming(
      review: review.copyWith(startMilliseconds: 100, endMilliseconds: 900),
      expectedVideoPath: null,
    );
    await _setRecordReviewTracking(
      database,
      record.id,
      reviewStatus: ReviewStatus.draft,
      reviewSchemaVersion: null,
    );

    final committed = await repository.saveStepSkipped(
      review: timed,
      isSkipped: true,
      expectedVideoPath: null,
    );
    final persisted = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: review.step,
    );
    final persistedRecord = await repository.getRecord(record.id);

    expect(committed.startMilliseconds, isNull);
    expect(committed.endMilliseconds, isNull);
    expect(committed.isSkipped, isTrue);
    expect(committed.recordingStatus, StepRecordingStatus.skipped);
    expect(persisted!.startMilliseconds, isNull);
    expect(persisted.endMilliseconds, isNull);
    expect(persisted.isSkipped, isTrue);
    expect(persisted.recordingStatus, StepRecordingStatus.skipped);
    expect(persistedRecord!.reviewStatus, ReviewStatus.reviewed);
    expect(persistedRecord.reviewSchemaVersion, 1);
  });

  test('saveStepSkippedは症例更新失敗時に時刻消去とskipをrollbackする', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.left,
    );
    final review = await repository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    final timed = await repository.saveStepTiming(
      review: review.copyWith(startMilliseconds: 100, endMilliseconds: 900),
      expectedVideoPath: null,
    );
    await _setRecordReviewTracking(
      database,
      record.id,
      reviewStatus: ReviewStatus.draft,
      reviewSchemaVersion: null,
    );
    await database.customStatement('''
CREATE TRIGGER fail_skip_record_update
BEFORE UPDATE ON surgery_records
WHEN NEW.id = '${record.id}'
BEGIN SELECT RAISE(ABORT, 'injected record update failure'); END
''');

    await expectLater(
      repository.saveStepSkipped(
        review: timed,
        isSkipped: true,
        expectedVideoPath: null,
      ),
      throwsA(anything),
    );

    final persisted = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: review.step,
    );
    final persistedRecord = await repository.getRecord(record.id);
    expect(persisted!.startMilliseconds, 100);
    expect(persisted.endMilliseconds, 900);
    expect(persisted.isSkipped, isFalse);
    expect(persisted.recordingStatus, StepRecordingStatus.recorded);
    expect(persistedRecord!.reviewStatus, ReviewStatus.draft);
    expect(persistedRecord.reviewSchemaVersion, isNull);
  });

  test('saveStepSkippedはexpectedVideoPath競合時に何も更新しない', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final oldPath = 'videos/${record.id}/old.mp4';
    final newPath = 'videos/${record.id}/new.mp4';
    await repository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: oldPath,
      videoDisplayName: 'old.mp4',
    );
    final review = await repository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    final timed = await repository.saveStepTiming(
      review: review.copyWith(startMilliseconds: 100, endMilliseconds: 900),
      expectedVideoPath: oldPath,
    );
    await _setRecordReviewTracking(
      database,
      record.id,
      reviewStatus: ReviewStatus.draft,
      reviewSchemaVersion: null,
    );
    await repository.updateVideoReferenceIfCurrent(
      surgeryRecordId: record.id,
      expectedVideoPath: oldPath,
      videoPath: newPath,
      videoDisplayName: 'new.mp4',
    );

    await expectLater(
      repository.saveStepSkipped(
        review: timed,
        isSkipped: true,
        expectedVideoPath: oldPath,
      ),
      throwsA(isA<VideoReferenceConflictException>()),
    );

    final persisted = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: review.step,
    );
    final persistedRecord = await repository.getRecord(record.id);
    expect(persisted!.startMilliseconds, 100);
    expect(persisted.endMilliseconds, 900);
    expect(persisted.isSkipped, isFalse);
    expect(persistedRecord!.videoPath, newPath);
    expect(persistedRecord.reviewStatus, ReviewStatus.draft);
    expect(persistedRecord.reviewSchemaVersion, isNull);
  });

  test('レビュー保存は時刻を上書きせずメモだけでstatusを変えない', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final review = await repository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    final timed = await repository.saveStepTiming(
      review: review.copyWith(startMilliseconds: 10, endMilliseconds: 20),
      expectedVideoPath: null,
    );
    final saved = await repository.saveReviewContent(
      surgeryRecordId: record.id,
      reviews: <SurgicalStepReview>[
        review.copyWith(rating: StepRating.fair, reflection: 'レビューのみ更新'),
      ],
      caseMemo: '症例メモ',
    );

    expect(saved.reviews.single.startMilliseconds, timed.startMilliseconds);
    expect(saved.reviews.single.endMilliseconds, timed.endMilliseconds);
    expect(saved.record.reviewStatus, ReviewStatus.reviewed);

    final memoOnlyRecord = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 16),
      eyeSide: EyeSide.left,
    );
    final memoOnly = await repository.saveReviewContent(
      surgeryRecordId: memoOnlyRecord.id,
      reviews: const <SurgicalStepReview>[],
      caseMemo: 'メモのみ',
    );
    expect(memoOnly.record.reviewStatus, ReviewStatus.draft);
  });

  test('時刻保存はcommit直後にDB読込不能でも保存済み結果を返す', () async {
    final fixtureDirectory = await Directory.systemTemp.createTemp(
      'step-timing-post-commit-',
    );
    final file = File('${fixtureDirectory.path}/fixture.sqlite');
    final faultDatabase = _CloseAfterNextCommitDatabase(file);
    final faultRepository = SurgeryRepository(faultDatabase);
    AppDatabase? reopened;
    try {
      final record = await faultRepository.createRecord(
        surgeryDate: DateTime(2026, 8, 15),
        eyeSide: EyeSide.right,
      );
      final draft = await faultRepository.ensureStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      );
      await faultRepository.saveReviewContent(
        surgeryRecordId: record.id,
        reviews: <SurgicalStepReview>[
          draft.copyWith(rating: StepRating.good, reflection: 'commit前に保持する内容'),
        ],
        caseMemo: '',
      );

      faultDatabase.closeAfterNextCommit = true;
      final committed = await faultRepository.saveStepTiming(
        review: draft.copyWith(startMilliseconds: 100, endMilliseconds: 900),
        expectedVideoPath: null,
      );

      expect(committed.startMilliseconds, 100);
      expect(committed.endMilliseconds, 900);
      expect(committed.rating, StepRating.good);
      expect(committed.reflection, 'commit前に保持する内容');

      reopened = AppDatabase.forExecutor(NativeDatabase(file));
      final persisted = await SurgeryRepository(reopened).getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      );
      expect(persisted!.startMilliseconds, 100);
      expect(persisted.endMilliseconds, 900);
      expect(persisted.rating, StepRating.good);
    } finally {
      await reopened?.close();
      await fixtureDirectory.delete(recursive: true);
    }
  });

  test('レビュー保存はcommit直後にDB読込不能でも正確な保存済み結果を返す', () async {
    final fixtureDirectory = await Directory.systemTemp.createTemp(
      'review-content-post-commit-',
    );
    final file = File('${fixtureDirectory.path}/fixture.sqlite');
    final faultDatabase = _CloseAfterNextCommitDatabase(file);
    final faultRepository = SurgeryRepository(faultDatabase);
    AppDatabase? reopened;
    try {
      final record = await faultRepository.createRecord(
        surgeryDate: DateTime(2026, 8, 15),
        eyeSide: EyeSide.left,
      );
      final review = await faultRepository.ensureStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      );
      await faultRepository.saveStepTiming(
        review: review.copyWith(startMilliseconds: 50, endMilliseconds: 250),
        expectedVideoPath: null,
      );

      faultDatabase.closeAfterNextCommit = true;
      final committed = await faultRepository.saveReviewContent(
        surgeryRecordId: record.id,
        reviews: <SurgicalStepReview>[
          review.copyWith(rating: StepRating.fair, reflection: '保存済みとして返す内容'),
        ],
        caseMemo: '保存済みメモ',
      );

      expect(committed.record.caseMemo, '保存済みメモ');
      expect(committed.record.reviewStatus, ReviewStatus.reviewed);
      expect(committed.reviews.single.startMilliseconds, 50);
      expect(committed.reviews.single.endMilliseconds, 250);
      expect(committed.reviews.single.rating, StepRating.fair);

      reopened = AppDatabase.forExecutor(NativeDatabase(file));
      final reopenedRepository = SurgeryRepository(reopened);
      final persistedRecord = await reopenedRepository.getRecord(record.id);
      final persistedReview = await reopenedRepository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      );
      expect(persistedRecord!.caseMemo, '保存済みメモ');
      expect(persistedRecord.reviewStatus, ReviewStatus.reviewed);
      expect(persistedReview!.startMilliseconds, 50);
      expect(persistedReview.endMilliseconds, 250);
      expect(persistedReview.rating, StepRating.fair);
    } finally {
      await reopened?.close();
      await fixtureDirectory.delete(recursive: true);
    }
  });

  test('複数レビューとメモは途中失敗時に全rollbackする', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final reviews = await repository.ensureStepReviews(record.id);
    final first = reviews[0];
    final second = reviews[1];
    await database.customStatement('''
CREATE TRIGGER fail_second_review
BEFORE UPDATE OF rating, reflection ON surgical_step_reviews
WHEN NEW.id = '${second.id}'
BEGIN SELECT RAISE(ABORT, 'injected review failure'); END
''');

    await expectLater(
      repository.saveReviewContent(
        surgeryRecordId: record.id,
        reviews: <SurgicalStepReview>[
          first.copyWith(rating: StepRating.good, reflection: 'first'),
          second.copyWith(rating: StepRating.fair, reflection: 'second'),
        ],
        caseMemo: '更新されてはいけない',
      ),
      throwsA(anything),
    );

    final restoredFirst = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: first.step,
    );
    expect(restoredFirst!.rating, StepRating.unreviewed);
    expect(restoredFirst.reflection, isEmpty);
    final restoredRecord = await repository.getRecord(record.id);
    expect(restoredRecord!.caseMemo, isEmpty);
    expect(restoredRecord.reviewStatus, ReviewStatus.draft);
  });

  test('destination durationと最新最大工程時刻が同値なら動画参照を更新する', () async {
    final record = await _recordWithKnownLegacyAndUnknownSteps(
      database,
      repository,
    );
    final beforeRows = await _stepRows(database, record.id);

    await repository.updateVideoReferenceIfCurrentAndTimingsFit(
      surgeryRecordId: record.id,
      expectedVideoPath: null,
      videoPath: 'videos/${record.id}/attached.mp4',
      videoDisplayName: 'attached.mp4',
      destinationDurationMilliseconds: 500,
    );

    final updated = await repository.getRecord(record.id);
    expect(updated!.videoPath, 'videos/${record.id}/attached.mp4');
    expect(updated.videoDisplayName, 'attached.mp4');
    expect(updated.caseMemo, record.caseMemo);
    expect(await _stepRows(database, record.id), beforeRows);
  });

  test('最新最大工程時刻がdestination durationを1ms超える場合は全状態を保持する', () async {
    final record = await _recordWithKnownLegacyAndUnknownSteps(
      database,
      repository,
    );
    final beforeRecord = (await repository.getRecord(record.id))!;
    final beforeRows = await _stepRows(database, record.id);

    await expectLater(
      repository.updateVideoReferenceIfCurrentAndTimingsFit(
        surgeryRecordId: record.id,
        expectedVideoPath: null,
        videoPath: 'videos/${record.id}/too-short.mp4',
        videoDisplayName: 'too-short.mp4',
        destinationDurationMilliseconds: 499,
      ),
      throwsA(
        isA<VideoDurationConflictException>()
            .having(
              (error) => error.destinationDurationMilliseconds,
              'destinationDurationMilliseconds',
              499,
            )
            .having(
              (error) => error.maximumTimingMilliseconds,
              'maximumTimingMilliseconds',
              500,
            )
            .having(
              (error) => error.hasInvalidTiming,
              'hasInvalidTiming',
              isFalse,
            ),
      ),
    );

    final afterRecord = (await repository.getRecord(record.id))!;
    expect(afterRecord.videoPath, beforeRecord.videoPath);
    expect(afterRecord.videoDisplayName, beforeRecord.videoDisplayName);
    expect(afterRecord.updatedAt, beforeRecord.updatedAt);
    expect(await _stepRows(database, record.id), beforeRows);
  });

  test('負の工程時刻が1件でもあればduration適合と推測せず全状態を保持する', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.left,
    );
    final review = await repository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    await _setRawTimingAndSkipped(
      database,
      review.id,
      startMilliseconds: -1,
      endMilliseconds: 100,
    );
    final beforeRecord = (await repository.getRecord(record.id))!;
    final beforeRows = await _stepRows(database, record.id);

    await expectLater(
      repository.updateVideoReferenceIfCurrentAndTimingsFit(
        surgeryRecordId: record.id,
        expectedVideoPath: null,
        videoPath: 'videos/${record.id}/invalid-timing.mp4',
        videoDisplayName: 'invalid-timing.mp4',
        destinationDurationMilliseconds: 1000,
      ),
      throwsA(
        isA<VideoDurationConflictException>().having(
          (error) => error.hasInvalidTiming,
          'hasInvalidTiming',
          isTrue,
        ),
      ),
    );

    final afterRecord = (await repository.getRecord(record.id))!;
    expect(afterRecord.videoPath, beforeRecord.videoPath);
    expect(afterRecord.videoDisplayName, beforeRecord.videoDisplayName);
    expect(afterRecord.updatedAt, beforeRecord.updatedAt);
    expect(await _stepRows(database, record.id), beforeRows);
  });

  test('duration適合更新でも期待videoPathとのCAS競合を成功扱いしない', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final currentPath = 'videos/${record.id}/current.mp4';
    await repository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: currentPath,
      videoDisplayName: 'current.mp4',
    );
    final beforeRecord = (await repository.getRecord(record.id))!;
    final beforeRows = await _stepRows(database, record.id);

    await expectLater(
      repository.updateVideoReferenceIfCurrentAndTimingsFit(
        surgeryRecordId: record.id,
        expectedVideoPath: 'videos/${record.id}/stale.mp4',
        videoPath: 'videos/${record.id}/new.mp4',
        videoDisplayName: 'new.mp4',
        destinationDurationMilliseconds: 1000,
      ),
      throwsA(isA<VideoReferenceConflictException>()),
    );

    final afterRecord = (await repository.getRecord(record.id))!;
    expect(afterRecord.videoPath, currentPath);
    expect(afterRecord.videoDisplayName, beforeRecord.videoDisplayName);
    expect(afterRecord.updatedAt, beforeRecord.updatedAt);
    expect(await _stepRows(database, record.id), beforeRows);
  });

  test('videoPath未登録でも動画追加と全工程時刻消去を同一transactionで行う', () async {
    final record = await _recordWithKnownLegacyAndUnknownSteps(
      database,
      repository,
    );
    final beforeRows = await _stepRows(database, record.id);

    await repository.replaceVideoReferenceAndClearTimings(
      surgeryRecordId: record.id,
      expectedVideoPath: null,
      videoPath: 'videos/${record.id}/attached-with-reset.mp4',
      videoDisplayName: 'attached-with-reset.mp4',
    );

    final updated = (await repository.getRecord(record.id))!;
    final afterRows = await _stepRows(database, record.id);
    expect(updated.videoPath, 'videos/${record.id}/attached-with-reset.mp4');
    expect(updated.videoDisplayName, 'attached-with-reset.mp4');
    expect(updated.caseMemo, record.caseMemo);
    expect(updated.reviewSchemaVersion, 1);
    expect(
      afterRows.map((row) => row['id']),
      beforeRows.map((row) => row['id']),
    );
    for (var index = 0; index < afterRows.length; index++) {
      expect(afterRows[index]['start_milliseconds'], isNull);
      expect(afterRows[index]['end_milliseconds'], isNull);
      expect(afterRows[index]['rating'], beforeRows[index]['rating']);
      expect(afterRows[index]['reflection'], beforeRows[index]['reflection']);
    }
  });

  test('動画差し替えは参照更新と全工程時刻消去を同時commitする', () async {
    final record = await _recordWithKnownLegacyAndUnknownSteps(
      database,
      repository,
    );
    await repository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: 'videos/${record.id}/old.mp4',
      videoDisplayName: 'old.mp4',
    );
    final before = await _stepRows(database, record.id);

    await repository.replaceVideoReferenceAndClearTimings(
      surgeryRecordId: record.id,
      expectedVideoPath: 'videos/${record.id}/old.mp4',
      videoPath: 'videos/${record.id}/new.mp4',
      videoDisplayName: 'new.mp4',
    );

    final updated = await repository.getRecord(record.id);
    final after = await _stepRows(database, record.id);
    expect(updated!.videoPath, 'videos/${record.id}/new.mp4');
    expect(after.map((row) => row['id']), before.map((row) => row['id']));
    for (var index = 0; index < after.length; index++) {
      expect(after[index]['start_milliseconds'], isNull);
      expect(after[index]['end_milliseconds'], isNull);
      expect(after[index]['rating'], before[index]['rating']);
      expect(after[index]['reflection'], before[index]['reflection']);
    }
  });

  test('動画置換と削除は時刻を消去しskipを保持してschema 1へ移行する', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final oldPath = 'videos/${record.id}/old.mp4';
    final newPath = 'videos/${record.id}/new.mp4';
    await repository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: oldPath,
      videoDisplayName: 'old.mp4',
    );
    final reviews = await repository.ensureStepReviews(record.id);
    final skippedReview = reviews.singleWhere(
      (review) => review.step == SurgicalStep.capsulorhexis,
    );
    final timedReview = reviews.singleWhere(
      (review) => review.step == SurgicalStep.sidePortCreation,
    );
    await repository.saveStepSkipped(
      review: skippedReview,
      isSkipped: true,
      expectedVideoPath: oldPath,
    );
    await repository.saveStepTiming(
      review: timedReview.copyWith(
        startMilliseconds: 100,
        endMilliseconds: 900,
      ),
      expectedVideoPath: oldPath,
    );
    await _setRecordReviewTracking(
      database,
      record.id,
      reviewStatus: ReviewStatus.reviewed,
      reviewSchemaVersion: null,
    );

    await repository.replaceVideoReferenceAndClearTimings(
      surgeryRecordId: record.id,
      expectedVideoPath: oldPath,
      videoPath: newPath,
      videoDisplayName: 'new.mp4',
    );

    var persistedSkipped = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: skippedReview.step,
    );
    var persistedTimed = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: timedReview.step,
    );
    var persistedRecord = await repository.getRecord(record.id);
    expect(persistedSkipped!.startMilliseconds, isNull);
    expect(persistedSkipped.endMilliseconds, isNull);
    expect(persistedSkipped.isSkipped, isTrue);
    expect(persistedTimed!.startMilliseconds, isNull);
    expect(persistedTimed.endMilliseconds, isNull);
    expect(persistedTimed.isSkipped, isFalse);
    expect(persistedRecord!.videoPath, newPath);
    expect(persistedRecord.reviewSchemaVersion, 1);

    await repository.saveStepTiming(
      review: persistedTimed.copyWith(
        startMilliseconds: 1200,
        endMilliseconds: 1800,
      ),
      expectedVideoPath: newPath,
    );
    await _setRecordReviewTracking(
      database,
      record.id,
      reviewStatus: ReviewStatus.reviewed,
      reviewSchemaVersion: null,
    );

    await repository.replaceVideoReferenceAndClearTimings(
      surgeryRecordId: record.id,
      expectedVideoPath: newPath,
      videoPath: null,
      videoDisplayName: null,
    );

    persistedSkipped = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: skippedReview.step,
    );
    persistedTimed = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: timedReview.step,
    );
    persistedRecord = await repository.getRecord(record.id);
    expect(persistedSkipped!.startMilliseconds, isNull);
    expect(persistedSkipped.endMilliseconds, isNull);
    expect(persistedSkipped.isSkipped, isTrue);
    expect(persistedTimed!.startMilliseconds, isNull);
    expect(persistedTimed.endMilliseconds, isNull);
    expect(persistedTimed.isSkipped, isFalse);
    expect(persistedRecord!.videoPath, isNull);
    expect(persistedRecord.reviewSchemaVersion, 1);
  });

  test('動画時刻消去は時刻なしskipだけ保持し時刻付きskipをfalseへ正規化する', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.left,
    );
    final oldPath = 'videos/${record.id}/old.mp4';
    await repository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: oldPath,
      videoDisplayName: 'old.mp4',
    );
    final reviews = await repository.ensureStepReviews(record.id);
    final noTimingSkipped = reviews.singleWhere(
      (review) => review.step == SurgicalStep.capsulorhexis,
    );
    final validTimingSkipped = reviews.singleWhere(
      (review) => review.step == SurgicalStep.sidePortCreation,
    );
    final startOnlySkipped = reviews.singleWhere(
      (review) => review.step == SurgicalStep.ovdInjection,
    );
    final endOnlySkipped = reviews.singleWhere(
      (review) => review.step == SurgicalStep.mainPortCreation,
    );
    await _setRawTimingAndSkipped(database, noTimingSkipped.id);
    await _setRawTimingAndSkipped(
      database,
      validTimingSkipped.id,
      startMilliseconds: 100,
      endMilliseconds: 900,
    );
    await _setRawTimingAndSkipped(
      database,
      startOnlySkipped.id,
      startMilliseconds: 1200,
    );
    await _setRawTimingAndSkipped(
      database,
      endOnlySkipped.id,
      endMilliseconds: 1800,
    );

    await repository.replaceVideoReferenceAndClearTimings(
      surgeryRecordId: record.id,
      expectedVideoPath: oldPath,
      videoPath: 'videos/${record.id}/new.mp4',
      videoDisplayName: 'new.mp4',
    );

    final persisted = <SurgicalStep, SurgicalStepReview>{};
    for (final review in <SurgicalStepReview>[
      noTimingSkipped,
      validTimingSkipped,
      startOnlySkipped,
      endOnlySkipped,
    ]) {
      persisted[review.step] = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: review.step,
      ))!;
    }
    for (final review in persisted.values) {
      expect(review.startMilliseconds, isNull);
      expect(review.endMilliseconds, isNull);
    }
    expect(persisted[noTimingSkipped.step]!.isSkipped, isTrue);
    expect(
      persisted[noTimingSkipped.step]!.recordingStatus,
      StepRecordingStatus.skipped,
    );
    expect(persisted[validTimingSkipped.step]!.isSkipped, isFalse);
    expect(persisted[startOnlySkipped.step]!.isSkipped, isFalse);
    expect(persisted[endOnlySkipped.step]!.isSkipped, isFalse);
  });

  test('工程時刻消去失敗で新動画参照もrollbackする', () async {
    final record = await _recordWithKnownLegacyAndUnknownSteps(
      database,
      repository,
    );
    final oldPath = 'videos/${record.id}/old.mp4';
    await repository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: oldPath,
      videoDisplayName: 'old.mp4',
    );
    final before = await _stepRows(database, record.id);
    await database.customStatement('''
CREATE TRIGGER fail_timing_clear
BEFORE UPDATE OF start_milliseconds, end_milliseconds
ON surgical_step_reviews
BEGIN SELECT RAISE(ABORT, 'injected timing failure'); END
''');

    await expectLater(
      repository.replaceVideoReferenceAndClearTimings(
        surgeryRecordId: record.id,
        expectedVideoPath: oldPath,
        videoPath: 'videos/${record.id}/new.mp4',
        videoDisplayName: 'new.mp4',
      ),
      throwsA(anything),
    );

    expect((await repository.getRecord(record.id))!.videoPath, oldPath);
    expect(await _stepRows(database, record.id), before);
  });

  test('同じ期待旧pathの競合更新は1件だけcommitする', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.left,
    );
    final oldPath = 'videos/${record.id}/old.mp4';
    await repository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: oldPath,
      videoDisplayName: 'old.mp4',
    );

    final outcomes = await Future.wait<Object>(
      <Future<void>>[
        repository.updateVideoReferenceIfCurrent(
          surgeryRecordId: record.id,
          expectedVideoPath: oldPath,
          videoPath: 'videos/${record.id}/one.mp4',
          videoDisplayName: 'one.mp4',
        ),
        repository.updateVideoReferenceIfCurrent(
          surgeryRecordId: record.id,
          expectedVideoPath: oldPath,
          videoPath: 'videos/${record.id}/two.mp4',
          videoDisplayName: 'two.mp4',
        ),
      ].map((future) async {
        try {
          await future;
          return 'success';
        } on Object catch (error) {
          return error;
        }
      }),
    );

    expect(outcomes.where((outcome) => outcome == 'success'), hasLength(1));
    expect(outcomes.whereType<VideoReferenceConflictException>(), hasLength(1));
  });

  test('差し替え後に旧動画由来の時刻をcommitしない', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final review = await repository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    final oldPath = 'videos/${record.id}/old.mp4';
    await repository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: oldPath,
      videoDisplayName: 'old.mp4',
    );
    await repository.replaceVideoReferenceAndClearTimings(
      surgeryRecordId: record.id,
      expectedVideoPath: oldPath,
      videoPath: 'videos/${record.id}/new.mp4',
      videoDisplayName: 'new.mp4',
    );

    await expectLater(
      repository.saveStepTiming(
        review: review.copyWith(startMilliseconds: 10, endMilliseconds: 20),
        expectedVideoPath: oldPath,
      ),
      throwsA(isA<VideoReferenceConflictException>()),
    );
    final restored = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: review.step,
    );
    expect(restored!.startMilliseconds, isNull);
    expect(restored.endMilliseconds, isNull);
  });

  test('存在しない症例の0件DELETE/UPDATEを成功扱いしない', () async {
    await expectLater(
      repository.deleteRecordChecked('missing'),
      throwsA(isA<SurgeryRecordNotFoundException>()),
    );
    await expectLater(
      repository.updateRecordDetails(
        surgeryRecordId: 'missing',
        surgeryDate: DateTime(2026, 8, 15),
        eyeSide: EyeSide.right,
      ),
      throwsA(isA<SurgeryRecordNotFoundException>()),
    );
  });

  test('症例情報更新と削除のbarrier競合は削除後の0行UPDATEを成功扱いしない', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    final deletion = repository.runRecordMutation(record.id, () async {
      entered.complete();
      await release.future;
      return repository.deleteRecordChecked(record.id);
    });
    await entered.future;
    final staleUpdate = repository.updateRecordDetails(
      surgeryRecordId: record.id,
      surgeryDate: DateTime(2026, 8, 16),
      eyeSide: EyeSide.left,
    );
    final staleExpectation = expectLater(
      staleUpdate,
      throwsA(isA<SurgeryRecordNotFoundException>()),
    );

    release.complete();
    await deletion;
    await staleExpectation;

    expect(await repository.getRecord(record.id), isNull);
  });

  test('一覧用進捗queryは工程行を追加せず旧工程を分母から除外する', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    await database.customStatement(
      '''
INSERT INTO surgical_step_reviews (
 id, surgery_record_id, step, start_milliseconds, end_milliseconds,
 rating, reflection, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
      <Object?>[
        'legacy-row',
        record.id,
        SurgicalStep.subTenonAnesthesia.storageId,
        0,
        100,
        StepRating.good.name,
        '',
        now,
        now,
      ],
    );
    final before = await _stepRows(database, record.id);

    final progress = await repository.fetchRecordProgressSnapshots();

    expect(progress.single.completedStepCount, 0);
    expect(progress.single.totalSurgeryDuration, isNull);
    expect(await _stepRows(database, record.id), before);
  });
}

class _CloseAfterNextCommitDatabase extends AppDatabase {
  _CloseAfterNextCommitDatabase(File file)
    : super.forExecutor(NativeDatabase(file));

  bool closeAfterNextCommit = false;

  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) async {
    final result = await super.transaction(action, requireNew: requireNew);
    if (closeAfterNextCommit) {
      closeAfterNextCommit = false;
      await close();
    }
    return result;
  }
}

Future<SurgeryRecord> _recordWithKnownLegacyAndUnknownSteps(
  AppDatabase database,
  SurgeryRepository repository,
) async {
  final record = await repository.createRecord(
    surgeryDate: DateTime(2026, 8, 15),
    eyeSide: EyeSide.right,
  );
  final reviews = await repository.ensureStepReviews(record.id);
  final ccc = reviews.singleWhere(
    (review) => review.step == SurgicalStep.capsulorhexis,
  );
  await repository.saveStepReview(
    ccc.copyWith(
      startMilliseconds: 100,
      endMilliseconds: 200,
      rating: StepRating.good,
      reflection: '保持',
    ),
  );
  final now = DateTime.now().millisecondsSinceEpoch;
  for (final row in <(String, String)>[
    ('legacy-id', SurgicalStep.subTenonAnesthesia.storageId),
    ('unknown-id', 'future_unknown_step'),
  ]) {
    await database.customStatement(
      '''
INSERT INTO surgical_step_reviews (
 id, surgery_record_id, step, start_milliseconds, end_milliseconds,
 rating, reflection, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
      <Object?>[
        row.$1,
        record.id,
        row.$2,
        300,
        500,
        StepRating.fair.name,
        '古い記録',
        now,
        now,
      ],
    );
  }
  await repository.updateCaseMemo(
    surgeryRecordId: record.id,
    caseMemo: '保持するメモ',
  );
  return (await repository.getRecord(record.id))!;
}

Future<List<Map<String, Object?>>> _stepRows(
  AppDatabase database,
  String recordId,
) async {
  final rows = await database
      .customSelect(
        '''
SELECT id, step, start_milliseconds, end_milliseconds, rating, reflection,
       created_at, updated_at
FROM surgical_step_reviews
WHERE surgery_record_id = ?
ORDER BY id
''',
        variables: <Variable<Object>>[Variable<String>(recordId)],
      )
      .get();
  return rows
      .map((row) => Map<String, Object?>.from(row.data))
      .toList(growable: false);
}

Future<void> _setRecordReviewTracking(
  AppDatabase database,
  String recordId, {
  required ReviewStatus reviewStatus,
  required int? reviewSchemaVersion,
}) {
  return database.customStatement(
    '''
UPDATE surgery_records
SET review_status = ?, review_schema_version = ?
WHERE id = ?
''',
    <Object?>[reviewStatus.name, reviewSchemaVersion, recordId],
  );
}

Future<void> _setRawTimingAndSkipped(
  AppDatabase database,
  String reviewId, {
  int? startMilliseconds,
  int? endMilliseconds,
}) {
  return database.customStatement(
    '''
UPDATE surgical_step_reviews
SET start_milliseconds = ?, end_milliseconds = ?, is_skipped = 1
WHERE id = ?
''',
    <Object?>[startMilliseconds, endMilliseconds, reviewId],
  );
}
