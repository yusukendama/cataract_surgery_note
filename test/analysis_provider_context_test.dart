import 'dart:async';

import 'package:cataract_surgery_note/src/data/analysis_time_context.dart';
import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_trend.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Snapshot途中のtimezone変更は結果を破棄して一度だけ再取得する', () async {
    final database = AppDatabase.memory();
    final repository = _CountingRepository(database);
    final source = _SequenceTimeSource([
      _context('Asia/Tokyo'),
      _context('Europe/London'),
      _context('Europe/London'),
      _context('Europe/London'),
    ]);
    final container = ProviderContainer(
      overrides: [
        surgeryRepositoryProvider.overrideWithValue(repository),
        analysisTimeContextSourceProvider.overrideWithValue(source),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final snapshot = await container.read(surgeryAnalysisProvider.future);

    expect(repository.readCount, 2);
    expect(snapshot.timezoneIdentifier, 'Europe/London');
    expect(snapshot.referenceDate, DateTime(2026, 8, 27));
  });

  test('再取得中にもtimezoneが変われば再試行可能なerrorにする', () async {
    final database = AppDatabase.memory();
    final repository = _CountingRepository(database);
    final source = _SequenceTimeSource([
      _context('Asia/Tokyo'),
      _context('Europe/London'),
      _context('America/New_York'),
      _context('UTC'),
    ]);
    final container = ProviderContainer(
      overrides: [
        surgeryRepositoryProvider.overrideWithValue(repository),
        analysisTimeContextSourceProvider.overrideWithValue(source),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await expectLater(
      container.read(surgeryAnalysisProvider.future),
      throwsA(isA<StateError>()),
    );
    expect(repository.readCount, 2);
  });
}

AnalysisTimeContext _context(String timezoneIdentifier) {
  return AnalysisTimeContext(
    now: DateTime(2026, 8, 27, 12),
    timezoneIdentifier: timezoneIdentifier,
  );
}

final class _SequenceTimeSource implements AnalysisTimeContextSource {
  _SequenceTimeSource(this.values);

  final List<AnalysisTimeContext> values;
  int index = 0;

  @override
  Stream<void> get changes => const Stream.empty();

  @override
  Future<AnalysisTimeContext> read() async => values[index++];
}

final class _CountingRepository extends SurgeryRepository {
  _CountingRepository(super.database);

  int readCount = 0;

  @override
  Future<SurgeryAnalysisSnapshot> fetchAnalysisSnapshot() async {
    readCount++;
    return const SurgeryAnalysisSnapshot(recordCount: 0, measurements: []);
  }
}
