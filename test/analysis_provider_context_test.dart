import 'dart:async';

import 'package:cataract_surgery_note/src/data/analysis_time_context.dart';
import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_trend.dart';
import 'package:cataract_surgery_note/src/features/analysis/analysis_screen.dart';
import 'package:flutter/material.dart';
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

  testWidgets('AnalysisScreenを破棄して開き直すと新しい時刻contextをcommitする', (tester) async {
    final database = AppDatabase.memory();
    final repository = _CountingRepository(database);
    final source = _MutableTimeSource(
      AnalysisTimeContext(
        now: DateTime(2026, 8, 27, 23, 59),
        timezoneIdentifier: 'Asia/Tokyo',
      ),
    );
    addTearDown(database.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          surgeryRepositoryProvider.overrideWithValue(repository),
          analysisTimeContextSourceProvider.overrideWithValue(source),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  key: const Key('open-analysis'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AnalysisScreen(),
                    ),
                  ),
                  child: const Text('分析を開く'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('open-analysis')));
    await tester.pumpAndSettle();
    expect(repository.readCount, 1);
    var snapshot = _visibleSnapshot(tester);
    expect(snapshot.referenceDate, DateTime(2026, 8, 27));
    expect(snapshot.timezoneIdentifier, 'Asia/Tokyo');

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pump();
    expect(find.byType(AnalysisScreen), findsNothing);
    source.current = AnalysisTimeContext(
      now: DateTime(2026, 8, 28, 0, 1),
      timezoneIdentifier: 'America/Los_Angeles',
    );
    source.deferNextRead();

    await tester.tap(find.byKey(const Key('open-analysis')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.byType(AnalysisScreen), findsOneWidget);
    expect(repository.readCount, 1);
    expect(
      find.byType(CircularProgressIndicator),
      findsOneWidget,
      reason: '新routeの最初のframeで旧Snapshotを同期再表示しない',
    );
    source.completeDeferredRead();
    await tester.pumpAndSettle();

    expect(repository.readCount, 2, reason: '新routeは旧provider cacheを再利用しない');
    snapshot = _visibleSnapshot(tester);
    expect(snapshot.referenceDate, DateTime(2026, 8, 28));
    expect(snapshot.timezoneIdentifier, 'America/Los_Angeles');
  });
}

SurgeryAnalysisSnapshot _visibleSnapshot(WidgetTester tester) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(AnalysisScreen)),
  );
  return container.read(surgeryAnalysisProvider).asData!.value;
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

final class _MutableTimeSource implements AnalysisTimeContextSource {
  _MutableTimeSource(this.current);

  AnalysisTimeContext current;
  Completer<AnalysisTimeContext>? _nextDeferredRead;
  Completer<AnalysisTimeContext>? _inFlightDeferredRead;

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<AnalysisTimeContext> read() {
    final deferred = _nextDeferredRead;
    if (deferred != null) {
      _nextDeferredRead = null;
      _inFlightDeferredRead = deferred;
      return deferred.future;
    }
    return Future<AnalysisTimeContext>.value(current);
  }

  void deferNextRead() {
    _nextDeferredRead = Completer<AnalysisTimeContext>();
  }

  void completeDeferredRead() {
    final deferred = _inFlightDeferredRead;
    if (deferred == null) {
      throw StateError('待機中のclock readがありません。');
    }
    _inFlightDeferredRead = null;
    deferred.complete(current);
  }
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
