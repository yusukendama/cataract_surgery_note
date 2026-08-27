import 'dart:async';

import 'package:cataract_surgery_note/src/data/analysis_time_context.dart';
import 'package:cataract_surgery_note/src/domain/calendar_day.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('platform境界はOSのtimezone identifierと注入clockを組み合わせる', () async {
    const channel = MethodChannel('test/analysis-time-context');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'timezoneIdentifier');
          return 'Asia/Tokyo';
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final source = PlatformAnalysisTimeContextSource(
      methodChannel: channel,
      now: () => DateTime(2026, 8, 27, 12, 34),
      usePlatformChannels: true,
    );

    final context = await source.read();

    expect(context.timezoneIdentifier, 'Asia/Tokyo');
    expect(context.localDay, const CalendarDay(2026, 8, 27));
  });

  test('monitorは開始時に比較し日付変更を通知して60秒以内へ再armする', () async {
    final source = _FakeTimeSource([
      _context(2026, 8, 27, 23, 59, 'Asia/Tokyo'),
      _context(2026, 8, 28, 0, 0, 'Asia/Tokyo'),
    ]);
    final scheduler = _FakeScheduler();
    final changes = <(AnalysisTimeContext, AnalysisTimeContext)>[];
    final monitor = AnalysisClockMonitor(source: source, scheduler: scheduler);
    addTearDown(() {
      monitor.dispose();
      source.dispose();
    });

    await monitor.start(
      initialContext: _context(2026, 8, 27, 23, 58, 'Asia/Tokyo'),
      onChanged: (previous, current) => changes.add((previous, current)),
    );
    expect(changes, isEmpty);
    expect(
      scheduler.active.single.delay,
      lessThanOrEqualTo(const Duration(seconds: 60)),
    );

    scheduler.active.single.fire();
    await Future<void>.delayed(Duration.zero);

    expect(changes, hasLength(1));
    expect(changes.single.$1.localDay, const CalendarDay(2026, 8, 27));
    expect(changes.single.$2.localDay, const CalendarDay(2026, 8, 28));
    expect(scheduler.active, hasLength(1));
  });

  test('native通知でtimezone変更を検知し、既存予約をcancelして再armする', () async {
    final source = _FakeTimeSource([
      _context(2026, 8, 27, 12, 0, 'Asia/Tokyo'),
      _context(2026, 8, 27, 4, 0, 'Europe/London'),
    ]);
    final scheduler = _FakeScheduler();
    final changes = <(AnalysisTimeContext, AnalysisTimeContext)>[];
    final monitor = AnalysisClockMonitor(source: source, scheduler: scheduler);
    addTearDown(() {
      monitor.dispose();
      source.dispose();
    });
    await monitor.start(
      initialContext: _context(2026, 8, 27, 12, 0, 'Asia/Tokyo'),
      onChanged: (previous, current) => changes.add((previous, current)),
    );
    final firstTask = scheduler.active.single;

    source.emitChange();
    await Future<void>.delayed(Duration.zero);

    expect(firstTask.cancelled, isTrue);
    expect(changes.single.$2.timezoneIdentifier, 'Europe/London');
    expect(scheduler.active, hasLength(1));
  });

  test('一時的なclock read失敗でもfallback予約を失わずstopで解除する', () async {
    final source = _FakeTimeSource([
      StateError('clock unavailable'),
      _context(2026, 8, 27, 12, 0, 'Asia/Tokyo'),
    ]);
    final scheduler = _FakeScheduler();
    final monitor = AnalysisClockMonitor(source: source, scheduler: scheduler);
    addTearDown(source.dispose);

    await monitor.start(
      initialContext: _context(2026, 8, 27, 11, 59, 'Asia/Tokyo'),
      onChanged: (_, _) {},
    );
    expect(scheduler.active, hasLength(1));

    monitor.stop();
    expect(scheduler.active, isEmpty);
    expect(monitor.isActive, isFalse);
  });

  test('変更callback自身がstopした場合は旧generationのtimerを再生成しない', () async {
    final source = _FakeTimeSource([_context(2026, 8, 28, 0, 1, 'Asia/Tokyo')]);
    final scheduler = _FakeScheduler();
    late final AnalysisClockMonitor monitor;
    monitor = AnalysisClockMonitor(source: source, scheduler: scheduler);
    addTearDown(() {
      monitor.dispose();
      source.dispose();
    });

    await monitor.start(
      initialContext: _context(2026, 8, 27, 23, 59, 'Asia/Tokyo'),
      onChanged: (_, _) => monitor.stop(),
    );

    expect(monitor.isActive, isFalse);
    expect(scheduler.active, isEmpty);
  });

  test('stop/start前の遅延read完了は新generationの排他を解除しない', () async {
    final source = _DeferredTimeSource();
    final scheduler = _FakeScheduler();
    final changes = <(AnalysisTimeContext, AnalysisTimeContext)>[];
    final staleChanges = <(AnalysisTimeContext, AnalysisTimeContext)>[];
    final monitor = AnalysisClockMonitor(source: source, scheduler: scheduler);
    addTearDown(() {
      monitor.dispose();
      source.dispose();
    });

    final staleStart = monitor.start(
      initialContext: _context(2026, 8, 27, 12, 0, 'Asia/Tokyo'),
      onChanged: (previous, current) => staleChanges.add((previous, current)),
    );
    await Future<void>.delayed(Duration.zero);
    expect(source.reads, hasLength(1));

    monitor.stop();
    final currentStart = monitor.start(
      initialContext: _context(2026, 8, 28, 12, 0, 'Asia/Tokyo'),
      onChanged: (previous, current) => changes.add((previous, current)),
    );
    await Future<void>.delayed(Duration.zero);
    expect(source.reads, hasLength(2));

    // The obsolete generation finishes while the current generation is still
    // reading. Its finally block must not unlock the current read.
    source.completeRead(0, _context(2026, 8, 27, 12, 1, 'Asia/Tokyo'));
    await staleStart;
    source.emitChange();
    final manualCheck = monitor.checkNow();
    await Future<void>.delayed(Duration.zero);

    expect(
      source.reads,
      hasLength(2),
      reason: 'native通知とcheckNowは同一generationのreadに合流する',
    );
    expect(staleChanges, isEmpty);

    source.completeRead(1, _context(2026, 8, 29, 0, 1, 'Asia/Tokyo'));
    await currentStart;
    await manualCheck;

    expect(changes, hasLength(1));
    expect(changes.single.$1.localDay, const CalendarDay(2026, 8, 28));
    expect(changes.single.$2.localDay, const CalendarDay(2026, 8, 29));
    expect(scheduler.active, hasLength(1));
  });
}

AnalysisTimeContext _context(
  int year,
  int month,
  int day,
  int hour,
  int minute,
  String timezone,
) {
  return AnalysisTimeContext(
    now: DateTime(year, month, day, hour, minute),
    timezoneIdentifier: timezone,
  );
}

final class _FakeTimeSource implements AnalysisTimeContextSource {
  _FakeTimeSource(this._values);

  final List<Object> _values;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  int _index = 0;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<AnalysisTimeContext> read() async {
    final index = _index < _values.length ? _index++ : _values.length - 1;
    final value = _values[index];
    if (value is AnalysisTimeContext) {
      return value;
    }
    throw value;
  }

  void emitChange() => _changes.add(null);

  void dispose() => _changes.close();
}

final class _FakeScheduler implements AnalysisScheduler {
  final List<_FakeTask> tasks = [];

  Iterable<_FakeTask> get active => tasks.where((task) => !task.cancelled);

  @override
  AnalysisScheduledTask schedule(Duration delay, void Function() callback) {
    final task = _FakeTask(delay, callback);
    tasks.add(task);
    return task;
  }
}

final class _DeferredTimeSource implements AnalysisTimeContextSource {
  final List<Completer<AnalysisTimeContext>> reads = [];
  final StreamController<void> _changes = StreamController<void>.broadcast(
    sync: true,
  );

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<AnalysisTimeContext> read() {
    final completer = Completer<AnalysisTimeContext>();
    reads.add(completer);
    return completer.future;
  }

  void completeRead(int index, AnalysisTimeContext value) {
    reads[index].complete(value);
  }

  void emitChange() => _changes.add(null);

  void dispose() => _changes.close();
}

final class _FakeTask implements AnalysisScheduledTask {
  _FakeTask(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool cancelled = false;

  void fire() {
    if (cancelled) {
      return;
    }
    cancelled = true;
    _callback();
  }

  @override
  void cancel() => cancelled = true;
}
